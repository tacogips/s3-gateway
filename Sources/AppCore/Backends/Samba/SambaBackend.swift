import Crypto
import Darwin
import Foundation
import SwiftSMB

private struct SambaCredentialFile: Decodable {
  let version: Int
  let username: String
  let password: String
  let domain: String?
}

private struct SambaObjectSidecar: Codable {
  let contentType: String?
  let userMetadata: [String: String]
  let sha256Base64: String
  let md5Hex: String
  let objectVersion: String
}

private struct SambaObjectDigests {
  let sha256Base64: String
  let md5Hex: String
  let md5Base64: String
  let length: Int64
}

private actor SambaObjectDigester {
  private var sha256 = SHA256()
  private var md5 = Insecure.MD5()
  private var length: Int64 = 0

  func append(_ data: Data) {
    sha256.update(data: data)
    md5.update(data: data)
    length += Int64(data.count)
  }

  func finish() -> SambaObjectDigests {
    let sha = Data(sha256.finalize()).base64EncodedString()
    let md5Bytes = Data(md5.finalize())
    let md5Value = md5Bytes.map { String(format: "%02x", $0) }.joined()
    return SambaObjectDigests(
      sha256Base64: sha,
      md5Hex: md5Value,
      md5Base64: md5Bytes.base64EncodedString(),
      length: length
    )
  }
}

public actor SambaBackend: ObjectStoreBackend {
  public nonisolated let kind: BackendKind = .samba

  private let configuration: SambaBackendConfiguration
  private let connection: SMB.Connection
  private let maximumChunkBytes: Int

  public init(configuration: SambaBackendConfiguration, maximumChunkBytes: Int = 64 * 1_024) throws {
    try configuration.validate(fileSystem: LocalFileSystemInspector())
    guard maximumChunkBytes > 0 else {
      throw ConfigurationError.invalid(field: "limits.maximumChunkBytes", reason: "must be positive")
    }
    self.configuration = configuration
    self.maximumChunkBytes = maximumChunkBytes
    let credentialData = try Self.readCredentialFile(path: configuration.credentialsPath)
    let credentialFile = try JSONDecoder().decode(SambaCredentialFile.self, from: credentialData)
    guard credentialFile.version == 1, !credentialFile.username.isEmpty, !credentialFile.password.isEmpty else {
      throw CredentialProviderError.invalidFormat
    }
    let server = SMB.Server(host: configuration.host, port: configuration.port, domain: credentialFile.domain)
    let credentials = SMB.Credentials(user: credentialFile.username, password: credentialFile.password, domain: credentialFile.domain)
    let smbConfiguration = SMB.Configuration(timeout: configuration.timeoutSeconds)
    connection = try SMB.connect(server: server, credentials: credentials, share: configuration.share, configuration: smbConfiguration)
    for path in configuration.bucketDirectories.values {
      try Self.makeDirectoryIfNeeded(connection: connection, path: path, makePath: true)
    }
  }

  public func capabilities() async -> BackendCapabilities {
    BackendCapabilities(
      supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256],
      checksumAlgorithms: [.sha256],
      consistencyDescription: "object data and S3 metadata stored on the SMB share; conditional writes are unavailable"
    )
  }

  public func readinessCheck(deadline: Date) async throws {
    try checkDeadline(deadline)
    do { _ = try connection.echo() } catch { throw BackendError.unavailable(retryable: true) }
  }

  public func getObject(_ request: GetObjectRequest, context: RequestContext) async throws -> GetObjectResult {
    try check(context)
    let path = try objectPath(bucket: request.bucket, key: request.key)
    let stat = try smbStat(path)
    guard stat.type == .file else { throw BackendError.notFound }
    let metadata = try makeMetadata(stat, sidecar: try loadSidecar(for: path))
    try evaluateReadConditions(request.conditions, metadata: metadata)
    if let range = request.range, range.lowerBound >= metadata.contentLength { throw BackendError.rangeNotSatisfiable }
    let file = try smbOpenFile(at: path)
    let offset = request.range?.lowerBound ?? 0
    _ = try file.seek(offset: offset, from: .start)
    let maximumLength: Int64?
    if let range = request.range {
      let end = min(range.upperBound ?? metadata.contentLength - 1, metadata.contentLength - 1)
      maximumLength = end - offset + 1
    } else {
      maximumLength = nil
    }
    let maximumChunkBytes = self.maximumChunkBytes
    let deadline = context.deadline
    let body = ObjectBodyStream(maximumChunkBytes: maximumChunkBytes) {
      AsyncThrowingStream { continuation in
        let reader = Task {
          defer { try? file.close() }
          do {
            var remaining = maximumLength
            while remaining.map({ $0 > 0 }) ?? true {
              try Task.checkCancellation()
              guard deadline > Date() else { throw BackendError.deadlineExceeded }
              let amount = min(Int64(maximumChunkBytes), remaining ?? Int64(maximumChunkBytes))
              let chunk = try file.read(upTo: amount, transferChunkSize: amount)
              if chunk.isEmpty { break }
              continuation.yield(chunk)
              remaining = remaining.map { $0 - Int64(chunk.count) }
            }
            continuation.finish()
          } catch { continuation.finish(throwing: self.map(error)) }
        }
        continuation.onTermination = { _ in reader.cancel() }
      }
    }
    return GetObjectResult(metadata: metadata, body: body, servedRange: request.range)
  }

  public func headObject(_ request: HeadObjectRequest, context: RequestContext) async throws -> ObjectMetadata {
    try check(context)
    let path = try objectPath(bucket: request.bucket, key: request.key)
    let metadata = try makeMetadata(try smbStat(path), sidecar: try loadSidecar(for: path))
    try evaluateReadConditions(request.conditions, metadata: metadata)
    return metadata
  }

  public func putObject(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult {
    try check(context)
    guard request.expectedChecksums.allSatisfy({ $0.algorithm == .sha256 }) else {
      throw BackendError.unsupported(.checksumCRC32C)
    }
    guard request.conditions == WriteConditions() else { throw BackendError.unsupported(.conditionalWrite) }
    let destination = try objectPath(bucket: request.bucket, key: request.key)
    try createParentDirectories(for: destination)
    let temporary = ".s3-gateway-tmp-\(UUID().uuidString)"
    let temporaryPath = parentPath(destination).map { "\($0)/\(temporary)" } ?? temporary
    let file = try smbOpenFile(at: temporaryPath, accessMode: .writeOnly, options: [.create, .exclusive])
    let digester = SambaObjectDigester()
    let maximumChunkBytes = self.maximumChunkBytes
    do {
      try await request.body.consume { chunk in
        if Task.isCancelled { throw BackendError.cancelled }
        if context.deadline <= Date() { throw BackendError.deadlineExceeded }
        _ = try file.write(chunk, transferChunkSize: Int64(maximumChunkBytes))
        await digester.append(chunk)
      }
      try file.sync()
      try file.close()
      let digest = await digester.finish()
      if let expectedLength = request.knownContentLength, expectedLength != digest.length {
        throw BackendError.invalidRequest("The request body length did not match Content-Length.")
      }
      guard request.expectedChecksums.allSatisfy({ $0.base64Value == digest.sha256Base64 }) else {
        throw BackendError.checksumMismatch
      }
      if let expectedMD5 = request.expectedContentMD5, digest.md5Base64 != expectedMD5 {
        throw BackendError.checksumMismatch
      }
      try check(context)
      if try smbItemExists(at: destination) == .file {
        try smbRemoveFile(at: destination)
      }
      try smbMove(from: temporaryPath, to: destination)
      let publishedStat = try smbStat(destination)
      let sidecar = SambaObjectSidecar(
        contentType: request.contentType,
        userMetadata: request.userMetadata,
        sha256Base64: digest.sha256Base64,
        md5Hex: digest.md5Hex,
        objectVersion: Self.objectVersion(publishedStat)
      )
      try saveSidecar(sidecar, for: destination)
      return PutObjectResult(metadata: try makeMetadata(publishedStat, sidecar: sidecar))
    } catch {
      try? file.close()
      try? smbRemoveFile(at: temporaryPath)
      throw map(error)
    }
  }

  public func deleteObject(_ request: DeleteObjectRequest, context: RequestContext) async throws {
    try check(context)
    guard request.conditions == WriteConditions() else { throw BackendError.unsupported(.conditionalWrite) }
    let path = try objectPath(bucket: request.bucket, key: request.key)
    do {
      try smbRemoveFile(at: path)
      try? smbRemoveFile(at: sidecarPath(for: path))
    } catch {
      if map(error) != .notFound { throw map(error) }
    }
  }

  public func listObjectsV2(_ request: ListObjectsV2Request, context: RequestContext) async throws -> ListObjectsV2Result {
    try check(context)
    guard (0...1_000).contains(request.maximumKeys) else { throw BackendError.invalidRequest("max-keys must be between 0 and 1000.") }
    let bucketRoot = try bucketPath(request.bucket)
    var objects: [ListedObject] = []
    try collect(path: bucketRoot, prefix: nil, request: request, objects: &objects, deadline: context.deadline)
    let keys = objects.map(\.key.rawValue).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    var prefixes = Set<String>()
    var objectKeys = [String]()
    for key in keys where key.hasPrefix(request.prefix) {
      if let delimiter = request.delimiter, !delimiter.isEmpty,
         let separator = key.dropFirst(request.prefix.count).range(of: delimiter) {
        prefixes.insert(String(key[..<separator.upperBound]))
      } else {
        objectKeys.append(key)
      }
    }
    let prefixValues = prefixes.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    let combined = (objectKeys.map { (key: $0, isPrefix: false) } + prefixValues.map { (key: $0, isPrefix: true) })
      .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    let start = request.continuationToken.map { token in combined.firstIndex { $0.key == token }.map { $0 + 1 } ?? 0 } ?? 0
    let page = Array(combined.dropFirst(start).prefix(request.maximumKeys))
    let pageKeys = Set(page.filter { !$0.isPrefix }.map(\.key))
    let pagePrefixes = page.filter(\.isPrefix).map(\.key)
    let pageObjects = objects.filter { pageKeys.contains($0.key.rawValue) }
    let next = start + page.count < combined.count ? page.last?.key : nil
    return ListObjectsV2Result(objects: pageObjects, commonPrefixes: pagePrefixes, nextContinuationToken: next)
  }

  private func collect(path: String, prefix: String?, request: ListObjectsV2Request, objects: inout [ListedObject], deadline: Date) throws {
    try checkDeadline(deadline)
    for entry in try smbListDirectory(at: path) where entry.name != "." && entry.name != ".." {
      guard let decodedName = Self.decodeComponent(entry.name) else { continue }
      let key = prefix.map { "\($0)/\(decodedName)" } ?? decodedName
      if entry.stat.type == .directory {
        try collect(path: "\(path)/\(entry.name)", prefix: key, request: request, objects: &objects, deadline: deadline)
      } else if entry.stat.type == .file, key.hasPrefix(request.prefix),
                !entry.name.hasPrefix(".s3-gateway-tmp-") {
        guard let objectKey = ObjectKey(rawValue: key) else { continue }
        let childPath = "\(path)/\(entry.name)"
        let metadata = try makeMetadata(entry.stat, sidecar: try loadSidecar(for: childPath))
        objects.append(ListedObject(key: objectKey, size: metadata.contentLength, lastModified: metadata.lastModified, entityTag: metadata.entityTag))
      }
    }
  }

  private func bucketPath(_ bucket: BucketName) throws -> String {
    guard let path = configuration.bucketDirectories[bucket.rawValue] else { throw BackendError.notFound }
    return path
  }

  private func objectPath(bucket: BucketName, key: ObjectKey) throws -> String {
    let root = try bucketPath(bucket)
    let components = key.rawValue.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ $0.utf8.count <= 255 }) else {
      throw BackendError.invalidRequest("An SMB path component exceeds 255 bytes.")
    }
    return ([root] + components.map { Self.encodeComponent(String($0)) }).joined(separator: "/")
  }

  private static func encodeComponent(_ component: String) -> String {
    guard component.isEmpty || component == "." || component == ".." ||
      component.hasPrefix("~") || component.hasPrefix(".s3-gateway-tmp-") else {
      return component
    }
    let encoded = Data(component.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return "~s3-\(encoded)"
  }

  private static func decodeComponent(_ component: String) -> String? {
    guard component.hasPrefix("~s3-") else { return component }
    var encoded = String(component.dropFirst(4))
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while encoded.count % 4 != 0 { encoded.append("=") }
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func smbStat(_ path: String) throws -> SMB.Stat {
    do {
      return try connection.stat(at: path)
    } catch {
      throw map(error)
    }
  }

  private func smbOpenFile(
    at path: String,
    accessMode: SMB.File.AccessMode = .readOnly,
    options: SMB.File.OpenOptions = []
  ) throws -> SMB.File {
    do {
      return try connection.openFile(at: path, accessMode: accessMode, options: options)
    } catch { throw map(error) }
  }

  private func smbItemExists(at path: String) throws -> SMB.ItemExistence {
    do {
      return try connection.itemExists(at: path)
    } catch { throw map(error) }
  }

  private func smbRemoveFile(at path: String) throws {
    do {
      try connection.removeFile(at: path)
    } catch { throw map(error) }
  }

  private func smbMove(from oldPath: String, to newPath: String) throws {
    do {
      try connection.move(from: oldPath, to: newPath)
    } catch { throw map(error) }
  }

  private func smbListDirectory(at path: String) throws -> [SMB.DirectoryEntry] {
    do {
      return try connection.listDirectory(at: path)
    } catch { throw map(error) }
  }

  private func smbMakeDirectory(at path: String, makePath: Bool) throws {
    do {
      try Self.makeDirectoryIfNeeded(connection: connection, path: path, makePath: makePath)
    } catch {
      throw map(error)
    }
  }

  private static func makeDirectoryIfNeeded(
    connection: SMB.Connection,
    path: String,
    makePath: Bool
  ) throws {
    switch try connection.itemExists(at: path) {
    case .directory:
      return
    case .false:
      do {
        try connection.makeDirectory(at: path, makePath: makePath)
      } catch {
        if (try? connection.itemExists(at: path)) == .directory { return }
        throw error
      }
    case .file, .link, .other:
      throw ConfigurationError.invalid(field: "backend.samba.bucketDirectories", reason: "a mapped directory path is occupied by a non-directory")
    }
  }

  private func makeMetadata(_ stat: SMB.Stat, sidecar: SambaObjectSidecar? = nil) throws -> ObjectMetadata {
    let modified = stat.modificationTime
    let version = Self.objectVersion(stat)
    let matchingSidecar = sidecar?.objectVersion == version ? sidecar : nil
    let tag = matchingSidecar.map { "\"\($0.md5Hex)\"" } ?? "\"smb-\(Data(version.utf8).base64EncodedString())\""
    guard let entityTag = EntityTag(rawValue: tag) else { throw BackendError.consistencyFailure }
    return ObjectMetadata(
      contentType: matchingSidecar?.contentType,
      contentLength: Int64(clamping: stat.size),
      lastModified: modified,
      entityTag: entityTag,
      userMetadata: matchingSidecar?.userMetadata ?? [:],
      checksums: matchingSidecar.map { [ObjectChecksum(algorithm: .sha256, base64Value: $0.sha256Base64)] } ?? [],
      versionToken: ObjectVersionToken(rawValue: version)
    )
  }

  private static func objectVersion(_ stat: SMB.Stat) -> String {
    "\(stat.inode):\(stat.size):\(stat.modificationTimeSeconds):\(stat.modificationTimeNanoseconds)"
  }

  private static func readCredentialFile(path: String) throws -> Data {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ConfigurationError.unreadable(path: path) }
    defer { close(descriptor) }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
          information.st_mode & S_IFMT == S_IFREG,
          information.st_uid == geteuid(),
          information.st_mode & 0o077 == 0,
          information.st_size <= 65_536 else {
      throw ConfigurationError.insecureCredentialFile(path: path)
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    let data = try file.read(upToCount: 65_537) ?? Data()
    guard data.count <= 65_536 else { throw CredentialProviderError.recordLimitExceeded }
    return data
  }

  private func sidecarPath(for objectPath: String) -> String {
    let identifier = Data(objectPath.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    return ".s3-gateway/metadata/\(identifier).json"
  }

  private func loadSidecar(for objectPath: String) throws -> SambaObjectSidecar? {
    let path = sidecarPath(for: objectPath)
    do {
      let file = try smbOpenFile(at: path)
      defer { try? file.close() }
      let data = try file.read(upTo: 65_536)
      return try JSONDecoder().decode(SambaObjectSidecar.self, from: data)
    } catch {
      if map(error) == .notFound { return nil }
      throw map(error)
    }
  }

  private func saveSidecar(_ sidecar: SambaObjectSidecar, for objectPath: String) throws {
    let path = sidecarPath(for: objectPath)
    try smbMakeDirectory(at: ".s3-gateway/metadata", makePath: true)
    let temporary = "\(path).tmp-\(UUID().uuidString)"
    let file = try smbOpenFile(at: temporary, accessMode: .writeOnly, options: [.create, .exclusive])
    do {
      try file.write(JSONEncoder().encode(sidecar))
      try file.sync()
      try file.close()
      if try smbItemExists(at: path) == .file { try smbRemoveFile(at: path) }
      try smbMove(from: temporary, to: path)
    } catch {
      try? file.close()
      try? smbRemoveFile(at: temporary)
      throw map(error)
    }
  }

  private func createParentDirectories(for path: String) throws {
    guard let parent = parentPath(path) else { return }
    try smbMakeDirectory(at: parent, makePath: true)
  }

  private func parentPath(_ path: String) -> String? {
    guard let separator = path.lastIndex(of: "/") else { return nil }
    return String(path[..<separator])
  }

  private func evaluateReadConditions(_ conditions: ReadConditions, metadata: ObjectMetadata) throws {
    let modified = floor(metadata.lastModified.timeIntervalSince1970)
    if !conditions.ifMatchAny, conditions.ifMatch.isEmpty, let date = conditions.ifUnmodifiedSince,
       modified > floor(date.timeIntervalSince1970) { throw BackendError.conditionFailed }
    if !conditions.ifMatch.isEmpty, !conditions.ifMatch.contains(metadata.entityTag) { throw BackendError.conditionFailed }
    if conditions.ifNoneMatchAny || conditions.ifNoneMatch.contains(metadata.entityTag) { throw BackendError.notModified }
    if !conditions.ifNoneMatchAny, conditions.ifNoneMatch.isEmpty, let date = conditions.ifModifiedSince,
       modified <= floor(date.timeIntervalSince1970) { throw BackendError.notModified }
  }

  private func check(_ context: RequestContext) throws { try checkDeadline(context.deadline) }

  private func checkDeadline(_ deadline: Date) throws {
    if Task.isCancelled { throw BackendError.cancelled }
    if deadline <= Date() { throw BackendError.deadlineExceeded }
  }

  private nonisolated func map(_ error: any Error) -> BackendError {
    if let backendError = error as? BackendError { return backendError }
    if let smbError = error as? SMB.Error {
      switch smbError {
      case .ntStatus(.noSuchFile, _, _, _), .ntStatus(.objectNameNotFound, _, _, _),
           .ntStatus(.objectPathNotFound, _, _, _), .posix(code: 2, operation: _, message: _):
        return .notFound
      case .ntStatus(.accessDenied, _, _, _), .posix(code: 13, operation: _, message: _):
        return .accessDenied
      case .ntStatus(.diskFull, _, _, _), .ntStatus(.quotaExceeded, _, _, _),
           .posix(code: 28, operation: _, message: _):
        return .capacityExceeded
      default:
        break
      }
    }
    return .unavailable(retryable: true)
  }
}
