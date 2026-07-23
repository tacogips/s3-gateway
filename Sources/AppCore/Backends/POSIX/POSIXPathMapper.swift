import Crypto
import Darwin
import Foundation

struct POSIXPathMapper: Sendable {
  let rootURL: URL
  let sidecarURL: URL
  let bucketDirectories: [String: String]
  let policy: POSIXLayoutPolicy
  let rootDevice: UInt64
  let durability: DurabilityMode

  func bucketURL(_ bucket: BucketName) throws -> URL {
    guard let relative = bucketDirectories[bucket.rawValue] else { throw BackendError.notFound }
    return rootURL.appendingPathComponent(relative, isDirectory: true)
  }

  func objectURL(bucket: BucketName, key: ObjectKey) throws -> URL {
    let bucket = try bucketURL(bucket)
    switch policy {
    case .managedPrivateLayout:
      let root = bucket.appendingPathComponent(".swift-s3-gateway-objects", isDirectory: true)
      return managedComponents(key).reduce(root) { partial, component in
        partial.appendingPathComponent(component, isDirectory: false)
      }
    case .sharedLocalDirectory:
      let components = try sharedComponents(key)
      return components.reduce(bucket) { $0.appendingPathComponent($1, isDirectory: false) }
    }
  }

  func logicalKey(bucket: BucketName, fileURL: URL) throws -> ObjectKey? {
    let bucketURL = try bucketURL(bucket).standardizedFileURL
    let path = fileURL.standardizedFileURL.path
    guard path.hasPrefix(bucketURL.path + "/") else { return nil }
    let relative = String(path.dropFirst(bucketURL.path.count + 1))
    switch policy {
    case .sharedLocalDirectory:
      return ObjectKey(rawValue: relative)
    case .managedPrivateLayout:
      let marker = ".swift-s3-gateway-objects/"
      let components = relative.dropFirst(marker.count).split(separator: "/", omittingEmptySubsequences: false)
      guard relative.hasPrefix(marker),
            !components.isEmpty,
            components.dropLast().allSatisfy({ $0.hasPrefix("d-") }),
            components.last?.hasPrefix("f-") == true else {
        return nil
      }
      let encoded = components.map { String($0.dropFirst(2)) }.joined()
      guard let data = Self.decodeBase64URL(encoded),
            let value = String(data: data, encoding: .utf8) else {
        return nil
      }
      return ObjectKey(rawValue: value)
    }
  }

  func sidecarFileURL(bucket: BucketName, key: ObjectKey) -> URL {
    let digest = keyDigest(key)
    return sidecarURL
      .appendingPathComponent(bucket.rawValue, isDirectory: true)
      .appendingPathComponent(digest + ".json", isDirectory: false)
  }

  func commitFileURL(bucket: BucketName, key: ObjectKey) -> URL {
    sidecarURL
      .appendingPathComponent(".swift-s3-gateway-commits", isDirectory: true)
      .appendingPathComponent(bucket.rawValue, isDirectory: true)
      .appendingPathComponent(keyDigest(key) + ".json", isDirectory: false)
  }

  func openObjectForReading(bucket: BucketName, key: ObjectKey) throws -> (FileHandle, FileIdentity) {
    let components = try storageComponents(bucket: bucket, key: key)
    guard let name = components.last else { throw BackendError.invalidRequest("The storage path is invalid.") }
    let parent = try openParentDirectory(components: components, create: false)
    defer { close(parent) }
    let descriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ENOENT { throw BackendError.notFound }
      throw BackendError.accessDenied
    }
    do {
      let identity = try identity(descriptor: descriptor)
      return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), identity)
    } catch {
      close(descriptor)
      throw error
    }
  }

  func createTemporaryFile(bucket: BucketName, key: ObjectKey) throws -> SecureTemporaryFile {
    let components = try storageComponents(bucket: bucket, key: key)
    let destinationParent = try openParentDirectory(components: components, create: true)
    let temporaryParent: Int32
    do {
      temporaryParent = try openStagingDirectory(bucket: bucket)
    } catch {
      close(destinationParent)
      throw error
    }
    let temporaryName = ".swift-s3-gateway-\(UUID().uuidString).tmp"
    let descriptor = openat(
      temporaryParent,
      temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
      mode_t(0o600)
    )
    guard descriptor >= 0 else {
      close(temporaryParent)
      close(destinationParent)
      throw BackendError.accessDenied
    }
    return SecureTemporaryFile(
      temporaryParentDescriptor: temporaryParent,
      destinationParentDescriptor: destinationParent,
      temporaryName: temporaryName,
      destinationName: components.last ?? "",
      handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    )
  }

  func identity(parentDescriptor: Int32, name: String) throws -> FileIdentity {
    let descriptor = openat(parentDescriptor, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw BackendError.consistencyFailure }
    defer { close(descriptor) }
    return try identity(descriptor: descriptor)
  }

  func publish(_ temporary: SecureTemporaryFile, durability: DurabilityMode) throws {
    guard renameat(
      temporary.temporaryParentDescriptor,
      temporary.temporaryName,
      temporary.destinationParentDescriptor,
      temporary.destinationName
    ) == 0 else {
      throw BackendError.consistencyFailure
    }
    if durability == .strict {
      guard fsync(temporary.destinationParentDescriptor) == 0,
            fsync(temporary.temporaryParentDescriptor) == 0 else {
        throw BackendError.consistencyFailure
      }
    }
  }

  func recoverCommit(_ record: POSIXCommitRecord) throws -> POSIXCommitRecovery {
    guard bucketDirectories[record.bucket.rawValue] != nil,
          Self.isTemporaryName(record.temporaryName) else {
      throw BackendError.consistencyFailure
    }
    let components = try storageComponents(bucket: record.bucket, key: record.key)
    guard let destinationName = components.last else {
      throw BackendError.consistencyFailure
    }
    let destinationParent = try openParentDirectory(components: components, create: true)
    defer { close(destinationParent) }
    let temporaryParent = try openStagingDirectory(bucket: record.bucket)
    defer { close(temporaryParent) }
    let current = try optionalIdentity(
      parentDescriptor: destinationParent,
      name: destinationName
    )
    if current == record.identity {
      return .published
    }
    let staged = try optionalIdentity(
      parentDescriptor: temporaryParent,
      name: record.temporaryName
    )
    if staged == record.identity {
      guard current == record.previousIdentity else {
        throw BackendError.consistencyFailure
      }
      guard renameat(
        temporaryParent,
        record.temporaryName,
        destinationParent,
        destinationName
      ) == 0 else {
        throw BackendError.consistencyFailure
      }
      if durability == .strict {
        guard fsync(destinationParent) == 0, fsync(temporaryParent) == 0 else {
          throw BackendError.consistencyFailure
        }
      }
      guard try optionalIdentity(
        parentDescriptor: destinationParent,
        name: destinationName
      ) == record.identity else {
        throw BackendError.consistencyFailure
      }
      return .published
    }
    guard staged == nil, current == record.previousIdentity else {
      throw BackendError.consistencyFailure
    }
    return .rolledBack
  }

  func objectIdentity(bucket: BucketName, key: ObjectKey) throws -> FileIdentity? {
    do {
      let (file, identity) = try openObjectForReading(bucket: bucket, key: key)
      try? file.close()
      return identity
    } catch BackendError.notFound {
      return nil
    }
  }

  func removeTemporary(_ temporary: SecureTemporaryFile) {
    unlinkat(temporary.temporaryParentDescriptor, temporary.temporaryName, 0)
  }

  func removeObject(bucket: BucketName, key: ObjectKey) throws {
    let components = try storageComponents(bucket: bucket, key: key)
    guard let name = components.last else { throw BackendError.invalidRequest("The storage path is invalid.") }
    let parent = try openParentDirectory(components: components, create: false)
    defer { close(parent) }
    guard unlinkat(parent, name, 0) == 0 else {
      if errno == ENOENT { throw BackendError.notFound }
      throw BackendError.accessDenied
    }
  }

  func cleanupAbandonedTemporaryFiles() throws {
    for bucketText in bucketDirectories.keys {
      guard let bucket = BucketName(rawValue: bucketText) else { continue }
      let directory = try openStagingDirectory(bucket: bucket)
      defer { close(directory) }
      let url = sidecarURL
        .appendingPathComponent(".swift-s3-gateway-staging", isDirectory: true)
        .appendingPathComponent(bucketText, isDirectory: true)
      let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
      for name in names where Self.isTemporaryName(name) {
        guard (try? identity(parentDescriptor: directory, name: name)) != nil else { continue }
        guard unlinkat(directory, name, 0) == 0 else { throw BackendError.consistencyFailure }
      }
      if durability == .strict, fsync(directory) != 0 { throw BackendError.consistencyFailure }
    }
  }

  func readinessCheck() throws {
    let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw BackendError.unavailable(retryable: true) }
    defer { close(root) }
    let sidecar = open(sidecarURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard sidecar >= 0 else { throw BackendError.unavailable(retryable: true) }
    defer { close(sidecar) }
    do {
      try validateDirectoryDevice(root)
      try validateDirectoryDevice(sidecar)
    } catch {
      throw BackendError.unavailable(retryable: true)
    }
    guard faccessat(sidecar, ".", R_OK | W_OK, 0) == 0 else {
      throw BackendError.unavailable(retryable: true)
    }
    for relative in bucketDirectories.values {
      do {
        let bucket = try openMappedDirectory(
          rootDescriptor: root,
          relativePath: relative
        )
        defer { close(bucket) }
        guard faccessat(bucket, ".", R_OK | W_OK, 0) == 0 else {
          throw BackendError.unavailable(retryable: true)
        }
      } catch {
        throw BackendError.unavailable(retryable: true)
      }
    }
  }

  func validateExistingRegularFile(_ url: URL) throws -> FileIdentity {
    try validateAncestors(of: url)
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      if errno == ENOENT { throw BackendError.notFound }
      throw BackendError.accessDenied
    }
    guard value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
      throw BackendError.accessDenied
    }
    return FileIdentity(value)
  }

  func validateAncestors(of url: URL) throws {
    let rootPath = rootURL.standardizedFileURL.path
    let targetPath = url.standardizedFileURL.path
    guard targetPath.hasPrefix(rootPath + "/") else { throw BackendError.accessDenied }
    var current = rootURL
    let relative = targetPath.dropFirst(rootPath.count + 1)
    for component in relative.split(separator: "/").dropLast() {
      current.appendPathComponent(String(component), isDirectory: true)
      var value = stat()
      if lstat(current.path, &value) != 0 {
        if errno == ENOENT { return }
        throw BackendError.accessDenied
      }
      guard value.st_mode & S_IFMT == S_IFDIR else { throw BackendError.accessDenied }
    }
  }

  func enumerateRegularFiles(
    bucket: BucketName,
    visit: (URL) throws -> Void
  ) throws {
    guard let relativePath = bucketDirectories[bucket.rawValue] else {
      throw BackendError.notFound
    }
    let root = open(
      rootURL.path,
      O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard root >= 0 else { throw BackendError.accessDenied }
    defer { close(root) }
    try validateDirectoryDevice(root)
    let bucketDescriptor = try openMappedDirectory(
      rootDescriptor: root,
      relativePath: relativePath
    )
    defer { close(bucketDescriptor) }
    try enumerateDirectory(
      descriptor: bucketDescriptor,
      relativeComponents: [],
      bucketURL: try bucketURL(bucket),
      visit: visit
    )
  }

  private func enumerateDirectory(
    descriptor: Int32,
    relativeComponents: [String],
    bucketURL: URL,
    visit: (URL) throws -> Void
  ) throws {
    let duplicated = dup(descriptor)
    guard duplicated >= 0, let directory = fdopendir(duplicated) else {
      if duplicated >= 0 { close(duplicated) }
      throw BackendError.accessDenied
    }
    defer { closedir(directory) }
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(
          to: CChar.self,
          capacity: Int(NAME_MAX) + 1
        ) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      var information = stat()
      guard fstatat(
        descriptor,
        name,
        &information,
        AT_SYMLINK_NOFOLLOW
      ) == 0 else {
        throw BackendError.consistencyFailure
      }
      guard UInt64(information.st_dev) == rootDevice else { continue }
      let components = relativeComponents + [name]
      let relativeBytes = components.reduce(0) {
        $0 + $1.utf8.count + ($0 == 0 ? 0 : 1)
      }
      guard relativeBytes <= 4_096 else { continue }
      switch information.st_mode & S_IFMT {
      case S_IFDIR:
        let child = openat(
          descriptor,
          name,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard child >= 0 else { throw BackendError.consistencyFailure }
        do {
          try validateDirectoryDevice(child)
          var openedInformation = stat()
          guard fstat(child, &openedInformation) == 0,
                Self.sameFile(openedInformation, information) else {
            throw BackendError.consistencyFailure
          }
          try enumerateDirectory(
            descriptor: child,
            relativeComponents: components,
            bucketURL: bucketURL,
            visit: visit
          )
          var finalInformation = stat()
          guard fstatat(
            descriptor,
            name,
            &finalInformation,
            AT_SYMLINK_NOFOLLOW
          ) == 0,
          finalInformation.st_mode & S_IFMT == S_IFDIR,
          Self.sameFile(finalInformation, information) else {
            throw BackendError.consistencyFailure
          }
          close(child)
        } catch {
          close(child)
          throw error
        }
      case S_IFREG where information.st_nlink == 1:
        let url = components.reduce(bucketURL) {
          $0.appendingPathComponent($1, isDirectory: false)
        }
        try visit(url)
      default:
        continue
      }
    }
  }

  private func sharedComponents(_ key: ObjectKey) throws -> [String] {
    let components = key.rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty,
          components.allSatisfy({ component in
            !component.isEmpty &&
              component != "." &&
              component != ".." &&
              component.utf8.count <= 255 &&
              component == component.precomposedStringWithCanonicalMapping
          }) else {
      throw BackendError.invalidRequest("The object key is not representable by the shared local filesystem.")
    }
    return components
  }

  private func storageComponents(bucket: BucketName, key: ObjectKey) throws -> [String] {
    guard let bucketPath = bucketDirectories[bucket.rawValue] else { throw BackendError.notFound }
    let bucketComponents = bucketPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    switch policy {
    case .managedPrivateLayout:
      return bucketComponents + [".swift-s3-gateway-objects"] + managedComponents(key)
    case .sharedLocalDirectory:
      return bucketComponents + (try sharedComponents(key))
    }
  }

  private func managedComponents(_ key: ObjectKey) -> [String] {
    let encoded = Self.base64URL(Data(key.rawValue.utf8))
    var chunks: [String] = []
    var index = encoded.startIndex
    while index < encoded.endIndex {
      let end = encoded.index(index, offsetBy: min(200, encoded.distance(from: index, to: encoded.endIndex)))
      chunks.append(String(encoded[index..<end]))
      index = end
    }
    if chunks.isEmpty { chunks = [""] }
    return chunks.enumerated().map { offset, chunk in
      (offset == chunks.count - 1 ? "f-" : "d-") + chunk
    }
  }

  private func openParentDirectory(components: [String], create: Bool) throws -> Int32 {
    guard components.count >= 2 else { throw BackendError.invalidRequest("The storage path is invalid.") }
    var current = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else { throw BackendError.accessDenied }
    do {
      try validateDirectoryDevice(current)
      for component in components.dropLast() {
        var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if next < 0, errno == ENOENT, create {
          guard mkdirat(current, component, mode_t(0o750)) == 0 || errno == EEXIST else {
            throw BackendError.accessDenied
          }
          if durability == .strict, fsync(current) != 0 { throw BackendError.consistencyFailure }
          next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard next >= 0 else {
          if errno == ENOENT { throw BackendError.notFound }
          throw BackendError.accessDenied
        }
        try validateDirectoryDevice(next)
        close(current)
        current = next
      }
      return current
    } catch {
      close(current)
      throw error
    }
  }

  private func openStagingDirectory(bucket: BucketName) throws -> Int32 {
    var current = open(sidecarURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard current >= 0 else { throw BackendError.accessDenied }
    do {
      try validateDirectoryDevice(current)
      for component in [".swift-s3-gateway-staging", bucket.rawValue] {
        var next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if next < 0, errno == ENOENT {
          guard mkdirat(current, component, mode_t(0o700)) == 0 || errno == EEXIST else {
            throw BackendError.accessDenied
          }
          if durability == .strict, fsync(current) != 0 { throw BackendError.consistencyFailure }
          next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard next >= 0 else { throw BackendError.accessDenied }
        try validateDirectoryDevice(next)
        close(current)
        current = next
      }
      return current
    } catch {
      close(current)
      throw error
    }
  }

  private func openMappedDirectory(
    rootDescriptor: Int32,
    relativePath: String
  ) throws -> Int32 {
    var current = dup(rootDescriptor)
    guard current >= 0 else { throw BackendError.accessDenied }
    do {
      for component in relativePath.split(separator: "/", omittingEmptySubsequences: true) {
        let next = openat(
          current,
          String(component),
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard next >= 0 else { throw BackendError.accessDenied }
        try validateDirectoryDevice(next)
        close(current)
        current = next
      }
      return current
    } catch {
      close(current)
      throw error
    }
  }

  private func identity(descriptor: Int32) throws -> FileIdentity {
    var value = stat()
    guard fstat(descriptor, &value) == 0,
          value.st_mode & S_IFMT == S_IFREG,
          value.st_nlink == 1,
          UInt64(value.st_dev) == rootDevice else {
      throw BackendError.accessDenied
    }
    return FileIdentity(value)
  }

  private func optionalIdentity(parentDescriptor: Int32, name: String) throws -> FileIdentity? {
    let descriptor = openat(
      parentDescriptor,
      name,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw BackendError.consistencyFailure
    }
    defer { close(descriptor) }
    return try identity(descriptor: descriptor)
  }

  private func validateDirectoryDevice(_ descriptor: Int32) throws {
    var value = stat()
    guard fstat(descriptor, &value) == 0,
          value.st_mode & S_IFMT == S_IFDIR,
          UInt64(value.st_dev) == rootDevice else {
      throw BackendError.accessDenied
    }
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    return Data(base64Encoded: base64)
  }

  private func keyDigest(_ key: ObjectKey) -> String {
    SHA256.hash(data: Data(key.rawValue.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func isTemporaryName(_ value: String) -> Bool {
    let prefix = ".swift-s3-gateway-"
    let suffix = ".tmp"
    guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return false }
    let start = value.index(value.startIndex, offsetBy: prefix.count)
    let end = value.index(value.endIndex, offsetBy: -suffix.count)
    return UUID(uuidString: String(value[start..<end])) != nil
  }

  private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }
}

enum POSIXCommitRecovery {
  case published
  case rolledBack
}

struct SecureTemporaryFile {
  let temporaryParentDescriptor: Int32
  let destinationParentDescriptor: Int32
  let temporaryName: String
  let destinationName: String
  let handle: FileHandle
}

struct FileIdentity: Codable, Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanoseconds: Int64

  init(_ value: stat) {
    device = UInt64(value.st_dev)
    inode = UInt64(value.st_ino)
    size = value.st_size
    modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
    modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
  }

  var date: Date {
    Date(timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
  }

  var versionToken: ObjectVersionToken {
    ObjectVersionToken(rawValue: "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds)")
  }
}
