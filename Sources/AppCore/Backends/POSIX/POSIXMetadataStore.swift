import Darwin
import Foundation

struct POSIXMetadataRecord: Codable, Sendable {
  let version: Int
  let identity: FileIdentity
  let metadata: ObjectMetadata
}

struct POSIXCommitRecord: Codable, Sendable {
  let version: Int
  let bucket: BucketName
  let key: ObjectKey
  let temporaryName: String
  let identity: FileIdentity
  let previousIdentity: FileIdentity?
  let metadata: ObjectMetadata
}

struct POSIXMetadataStore: Sendable {
  let mapper: POSIXPathMapper
  let faultInjector: POSIXFaultInjector

  init(
    mapper: POSIXPathMapper,
    faultInjector: POSIXFaultInjector = POSIXFaultInjector()
  ) {
    self.mapper = mapper
    self.faultInjector = faultInjector
  }

  func load(bucket: BucketName, key: ObjectKey, identity: FileIdentity) throws -> ObjectMetadata? {
    guard !FileManager.default.fileExists(
      atPath: mapper.commitFileURL(bucket: bucket, key: key).path
    ) else {
      throw BackendError.consistencyFailure
    }
    let url = mapper.sidecarFileURL(bucket: bucket, key: key)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    guard let data = Self.readBounded(url, expectedDevice: mapper.rootDevice),
          let record = try? decoder.decode(POSIXMetadataRecord.self, from: data),
          record.version == 1,
          record.identity == identity else {
      return nil
    }
    return record.metadata
  }

  private static func readBounded(
    _ url: URL,
    expectedDevice: UInt64
  ) -> Data? {
    let descriptor = open(
      url.path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else { return nil }
    var information = stat()
    guard fstat(descriptor, &information) == 0,
          information.st_mode & S_IFMT == S_IFREG,
          information.st_nlink == 1,
          UInt64(information.st_dev) == expectedDevice,
          information.st_size <= 1_048_576 else {
      close(descriptor)
      return nil
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    guard let data = try? file.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
    return data
  }

  func store(bucket: BucketName, key: ObjectKey, identity: FileIdentity, metadata: ObjectMetadata) throws {
    let destination = mapper.sidecarFileURL(bucket: bucket, key: key)
    try write(
      POSIXMetadataRecord(version: 1, identity: identity, metadata: metadata),
      to: destination
    )
  }

  func prepareCommit(_ record: POSIXCommitRecord) throws {
    try faultInjector.inject(.commitRecord)
    try write(record, to: mapper.commitFileURL(bucket: record.bucket, key: record.key))
  }

  func finishCommit(_ record: POSIXCommitRecord) throws {
    try faultInjector.inject(.metadataPublication)
    try store(
      bucket: record.bucket,
      key: record.key,
      identity: record.identity,
      metadata: record.metadata
    )
    try removeCommit(record)
  }

  func recoverPendingCommits(maximumRecords: Int = 10_000) throws {
    let root = mapper.sidecarURL
      .appendingPathComponent(".s3-gateway-commits", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    ) else {
      throw BackendError.consistencyFailure
    }
    var processed = 0
    for case let url as URL in enumerator {
      let values = try url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
      guard values.isSymbolicLink != true else {
        throw BackendError.consistencyFailure
      }
      guard values.isRegularFile == true else { continue }
      processed += 1
      guard processed <= maximumRecords,
            let data = Self.readBounded(
              url,
              expectedDevice: mapper.rootDevice
            ) else {
        throw BackendError.consistencyFailure
      }
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .millisecondsSince1970
      guard let record = try? decoder.decode(POSIXCommitRecord.self, from: data),
            record.version == 1,
            mapper.commitFileURL(bucket: record.bucket, key: record.key)
              .standardizedFileURL == url.standardizedFileURL else {
        throw BackendError.consistencyFailure
      }
      try resolveCommit(record)
    }
  }

  func resolveCommit(_ record: POSIXCommitRecord) throws {
    switch try mapper.recoverCommit(record) {
    case .published:
      try finishCommit(record)
    case .rolledBack:
      try removeCommit(record)
    }
  }

  private func write<Value: Encodable>(_ value: Value, to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= 1_048_576 else {
      throw BackendError.consistencyFailure
    }
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(".\(UUID().uuidString).tmp")
    var temporaryExists = true
    defer {
      if temporaryExists { try? FileManager.default.removeItem(at: temporary) }
    }
    try data.write(to: temporary)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    if mapper.durability != .relaxed {
      let file = try FileHandle(forWritingTo: temporary)
      defer { try? file.close() }
      try file.synchronize()
      if mapper.durability == .strict, fcntl(file.fileDescriptor, F_FULLFSYNC) != 0 {
        throw BackendError.consistencyFailure
      }
    }
    if rename(temporary.path, destination.path) != 0 {
      throw BackendError.consistencyFailure
    }
    temporaryExists = false
    if mapper.durability == .strict {
      let directory = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard directory >= 0 else { throw BackendError.consistencyFailure }
      defer { close(directory) }
      guard fsync(directory) == 0 else { throw BackendError.consistencyFailure }
    }
  }

  private func removeCommit(_ record: POSIXCommitRecord) throws {
    let url = mapper.commitFileURL(bucket: record.bucket, key: record.key)
    if unlink(url.path) != 0, errno != ENOENT {
      throw BackendError.consistencyFailure
    }
    if mapper.durability == .strict {
      let directory = open(
        url.deletingLastPathComponent().path,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
      )
      guard directory >= 0 else {
        throw BackendError.consistencyFailure
      }
      defer { close(directory) }
      guard fsync(directory) == 0 else {
        throw BackendError.consistencyFailure
      }
    }
  }

  func remove(bucket: BucketName, key: ObjectKey) {
    try? FileManager.default.removeItem(at: mapper.sidecarFileURL(bucket: bucket, key: key))
  }
}
