import Crypto
import Darwin
import Foundation

public actor POSIXBackend: ObjectStoreBackend {
  public nonisolated let kind: BackendKind = .posix

  private let configuration: POSIXBackendConfiguration
  private let mapper: POSIXPathMapper
  private let metadataStore: POSIXMetadataStore
  private let maximumChunkBytes: Int
  private let faultInjector: POSIXFaultInjector

  public init(
    configuration: POSIXBackendConfiguration,
    maximumChunkBytes: Int = 64 * 1_024,
    fileSystem: FileSystemInspecting = LocalFileSystemInspector()
  ) throws {
    try self.init(
      configuration: configuration,
      maximumChunkBytes: maximumChunkBytes,
      fileSystem: fileSystem,
      faultInjector: POSIXFaultInjector()
    )
  }

  init(
    configuration: POSIXBackendConfiguration,
    maximumChunkBytes: Int,
    fileSystem: FileSystemInspecting = LocalFileSystemInspector(),
    faultInjector: POSIXFaultInjector
  ) throws {
    try configuration.validate(fileSystem: fileSystem)
    self.configuration = configuration
    self.maximumChunkBytes = maximumChunkBytes
    self.faultInjector = faultInjector
    var rootInformation = stat()
    guard lstat(configuration.rootPath, &rootInformation) == 0 else {
      throw ConfigurationError.unreadable(path: configuration.rootPath)
    }
    mapper = POSIXPathMapper(
      rootURL: URL(fileURLWithPath: configuration.rootPath, isDirectory: true),
      sidecarURL: URL(fileURLWithPath: configuration.sidecarPath, isDirectory: true),
      bucketDirectories: configuration.bucketDirectories,
      policy: configuration.layoutPolicy,
      rootDevice: UInt64(rootInformation.st_dev),
      durability: configuration.durability
    )
    metadataStore = POSIXMetadataStore(mapper: mapper, faultInjector: faultInjector)
    try metadataStore.recoverPendingCommits()
    try mapper.cleanupAbandonedTemporaryFiles()
    for relative in configuration.bucketDirectories.values {
      try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: configuration.rootPath).appendingPathComponent(relative),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o750]
      )
    }
  }

  public func capabilities() async -> BackendCapabilities {
    var values: Set<BackendCapability> = [
      .rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256
    ]
    if configuration.layoutPolicy == .managedPrivateLayout {
      values.formUnion([.conditionalWrite, .strongReadAfterWrite])
    }
    return BackendCapabilities(
      supported: values,
      checksumAlgorithms: [.sha256],
      consistencyDescription: configuration.layoutPolicy == .managedPrivateLayout
        ? "gateway-controlled read-after-write; page-consistent listing"
        : "on-access local reconciliation; external writers may race requests"
    )
  }

  public func readinessCheck(deadline: Date) async throws {
    guard deadline > Date() else {
      throw BackendError.deadlineExceeded
    }
    try mapper.readinessCheck()
  }

  public func getObject(_ request: GetObjectRequest, context: RequestContext) async throws -> GetObjectResult {
    try checkContext(context)
    for _ in 0..<2 {
      let metadata = try metadata(
        bucket: request.bucket,
        key: request.key,
        deadline: context.deadline
      )
      let (validationFile, identity) = try mapper.openObjectForReading(bucket: request.bucket, key: request.key)
      try? validationFile.close()
      guard metadata.versionToken == identity.versionToken else { continue }
      try evaluateReadConditions(request.conditions, metadata: metadata)
      if let range = request.range {
        guard range.lowerBound < metadata.contentLength else { throw BackendError.rangeNotSatisfiable }
      }
      let body = Self.fileBodyStream(
        mapper: mapper,
        bucket: request.bucket,
        key: request.key,
        identity: identity,
        range: request.range,
        maximumChunkBytes: maximumChunkBytes,
        deadline: context.deadline
      )
      return GetObjectResult(metadata: metadata, body: body, servedRange: request.range)
    }
    throw BackendError.consistencyFailure
  }

  public func headObject(_ request: HeadObjectRequest, context: RequestContext) async throws -> ObjectMetadata {
    try checkContext(context)
    let result = try metadata(
      bucket: request.bucket,
      key: request.key,
      deadline: context.deadline
    )
    try evaluateReadConditions(request.conditions, metadata: result)
    return result
  }

  public func putObject(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult {
    try checkContext(context)
    if configuration.layoutPolicy == .sharedLocalDirectory,
       request.conditions.ifMatch != nil || request.conditions.requireAbsent {
      throw BackendError.unsupported(.conditionalWrite)
    }
    if configuration.layoutPolicy == .managedPrivateLayout {
      try evaluateWriteConditions(
        request.conditions,
        bucket: request.bucket,
        key: request.key,
        deadline: context.deadline
      )
    }
    let temporary = try mapper.createTemporaryFile(bucket: request.bucket, key: request.key)
    var commitRecord: POSIXCommitRecord?
    defer {
      close(temporary.temporaryParentDescriptor)
      close(temporary.destinationParentDescriptor)
    }
    do {
      let accumulator = POSIXWriteAccumulator(
        file: temporary.handle,
        expectedLength: request.knownContentLength,
        deadline: context.deadline,
        faultInjector: faultInjector
      )
      try await request.body.consume { chunk in
        try await accumulator.append(chunk)
      }
      let digest = try await accumulator.finish(durability: configuration.durability)
      let shaValue = digest.sha256Base64
      try verifyChecksums(request.expectedChecksums, sha256: shaValue)
      if let expected = request.expectedContentMD5, expected != digest.md5Base64 {
        throw BackendError.checksumMismatch
      }
      if configuration.layoutPolicy == .managedPrivateLayout {
        try evaluateWriteConditions(
          request.conditions,
          bucket: request.bucket,
          key: request.key,
          deadline: context.deadline
        )
      }
      let beforeRename = try mapper.identity(
        parentDescriptor: temporary.temporaryParentDescriptor,
        name: temporary.temporaryName
      )
      guard let entityTag = EntityTag(rawValue: "\"\(digest.md5Hex)\"") else { throw BackendError.consistencyFailure }
      let metadata = ObjectMetadata(
        contentType: request.contentType,
        contentLength: digest.length,
        lastModified: beforeRename.date,
        entityTag: entityTag,
        userMetadata: request.userMetadata,
        checksums: [ObjectChecksum(algorithm: .sha256, base64Value: shaValue)],
        versionToken: beforeRename.versionToken
      )
      let record = POSIXCommitRecord(
        version: 1,
        bucket: request.bucket,
        key: request.key,
        temporaryName: temporary.temporaryName,
        identity: beforeRename,
        previousIdentity: try mapper.objectIdentity(
          bucket: request.bucket,
          key: request.key
        ),
        metadata: metadata
      )
      try metadataStore.prepareCommit(record)
      commitRecord = record
      try mapper.publish(temporary, durability: configuration.durability)
      let finalIdentity = try mapper.identity(
        parentDescriptor: temporary.destinationParentDescriptor,
        name: temporary.destinationName
      )
      guard finalIdentity == beforeRename else {
        throw BackendError.consistencyFailure
      }
      try metadataStore.finishCommit(record)
      return PutObjectResult(metadata: metadata)
    } catch is CancellationError {
      mapper.removeTemporary(temporary)
      if let commitRecord {
        try? metadataStore.resolveCommit(commitRecord)
      }
      throw BackendError.cancelled
    } catch {
      mapper.removeTemporary(temporary)
      if let commitRecord {
        try? metadataStore.resolveCommit(commitRecord)
      }
      throw error
    }
  }

  public func deleteObject(_ request: DeleteObjectRequest, context: RequestContext) async throws {
    try checkContext(context)
    if configuration.layoutPolicy == .sharedLocalDirectory,
       request.conditions.ifMatch != nil || request.conditions.requireAbsent {
      throw BackendError.unsupported(.conditionalWrite)
    }
    if configuration.layoutPolicy == .managedPrivateLayout {
      try evaluateWriteConditions(
        request.conditions,
        bucket: request.bucket,
        key: request.key,
        deadline: context.deadline
      )
    }
    do {
      try mapper.removeObject(bucket: request.bucket, key: request.key)
      metadataStore.remove(bucket: request.bucket, key: request.key)
    } catch BackendError.notFound {
      return
    }
  }

  public func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result {
    try checkContext(context)
    guard (0...1_000).contains(request.maximumKeys) else {
      throw BackendError.invalidRequest("max-keys must be between 0 and 1000.")
    }
    if request.maximumKeys == 0 {
      return ListObjectsV2Result(objects: [], commonPrefixes: [], nextContinuationToken: nil)
    }
    let entries = try discoverListEntries(
      bucket: request.bucket,
      prefix: request.prefix,
      delimiter: request.delimiter.flatMap { $0.isEmpty ? nil : $0 },
      after: request.continuationToken,
      limit: request.maximumKeys + 1,
      deadline: context.deadline
    )
    let page = entries.prefix(request.maximumKeys)
    var objects: [ListedObject] = []
    var prefixes: [String] = []
    for entry in page {
      switch entry {
      case .object(let key):
        let value = try metadata(
          bucket: request.bucket,
          key: key,
          deadline: context.deadline
        )
        objects.append(
          ListedObject(key: key, size: value.contentLength, lastModified: value.lastModified, entityTag: value.entityTag)
        )
      case .prefix(let prefix):
        prefixes.append(prefix)
      }
    }
    return ListObjectsV2Result(
      objects: objects,
      commonPrefixes: prefixes,
      nextContinuationToken: entries.count > request.maximumKeys
        ? page.last?.orderingValue
        : nil
    )
  }

  private func metadata(
    bucket: BucketName,
    key: ObjectKey,
    deadline: Date
  ) throws -> ObjectMetadata {
    for _ in 0..<2 {
      try Task.checkCancellation()
      guard Date() <= deadline else { throw BackendError.deadlineExceeded }
      let (file, before) = try mapper.openObjectForReading(bucket: bucket, key: key)
      if let cached = try metadataStore.load(bucket: bucket, key: key, identity: before) {
        try? file.close()
        return cached
      }
      let calculated = try Self.calculateMetadata(
        file: file,
        identity: before,
        deadline: deadline
      )
      let after = try identityForDescriptor(file.fileDescriptor)
      try? file.close()
      guard before == after else { continue }
      try metadataStore.store(bucket: bucket, key: key, identity: after, metadata: calculated)
      return calculated
    }
    throw BackendError.consistencyFailure
  }

  private func discoverListEntries(
    bucket: BucketName,
    prefix: String,
    delimiter: String?,
    after: String?,
    limit: Int,
    deadline: Date
  ) throws -> [POSIXListEntry] {
    var entries: [POSIXListEntry] = []
    var identifiers = Set<String>()
    try mapper.enumerateRegularFiles(bucket: bucket) { url in
      try Task.checkCancellation()
      guard Date() <= deadline else { throw BackendError.deadlineExceeded }
      if url.lastPathComponent.hasPrefix(".swift-s3-gateway-") { return }
      guard let key = try mapper.logicalKey(bucket: bucket, fileURL: url) else {
        return
      }
      let (file, _) = try mapper.openObjectForReading(bucket: bucket, key: key)
      try? file.close()
      guard key.rawValue.hasPrefix(prefix) else { return }
      let entry: POSIXListEntry
      if let delimiter,
         let range = key.rawValue.dropFirst(prefix.count).range(of: delimiter) {
        entry = .prefix(
          prefix + String(key.rawValue.dropFirst(prefix.count)[..<range.upperBound])
        )
      } else {
        entry = .object(key)
      }
      guard after.map({ Self.isOrdered(entry.orderingValue, after: $0) }) ?? true,
            !identifiers.contains(entry.identifier) else {
        return
      }
      if entries.count == limit,
         let largest = entries.last,
         !POSIXListEntry.isOrdered(entry, largest) {
        return
      }
      identifiers.insert(entry.identifier)
      entries.append(entry)
      entries.sort(by: POSIXListEntry.isOrdered)
      if entries.count > limit, let removed = entries.popLast() {
        identifiers.remove(removed.identifier)
      }
    }
    return entries
  }

  private func evaluateReadConditions(_ conditions: ReadConditions, metadata: ObjectMetadata) throws {
    let modifiedSeconds = floor(metadata.lastModified.timeIntervalSince1970)
    if !conditions.ifMatchAny, conditions.ifMatch.isEmpty,
       let date = conditions.ifUnmodifiedSince,
       modifiedSeconds > floor(date.timeIntervalSince1970) {
      throw BackendError.conditionFailed
    }
    if !conditions.ifMatch.isEmpty, !conditions.ifMatch.contains(metadata.entityTag) {
      throw BackendError.conditionFailed
    }
    if conditions.ifNoneMatchAny || conditions.ifNoneMatch.contains(metadata.entityTag) {
      throw BackendError.notModified
    }
    if !conditions.ifNoneMatchAny, conditions.ifNoneMatch.isEmpty,
       let date = conditions.ifModifiedSince,
       modifiedSeconds <= floor(date.timeIntervalSince1970) {
      throw BackendError.notModified
    }
  }

  private func evaluateWriteConditions(
    _ conditions: WriteConditions,
    bucket: BucketName,
    key: ObjectKey,
    deadline: Date
  ) throws {
    let existing = try? metadata(bucket: bucket, key: key, deadline: deadline)
    if conditions.requireAbsent, existing != nil { throw BackendError.conditionFailed }
    if let expected = conditions.ifMatch, existing?.entityTag != expected { throw BackendError.conditionFailed }
  }

  private func verifyChecksums(_ expected: [ObjectChecksum], sha256: String) throws {
    for checksum in expected {
      guard checksum.algorithm == .sha256 else { throw BackendError.unsupported(.checksumCRC32C) }
      guard checksum.base64Value == sha256 else { throw BackendError.checksumMismatch }
    }
  }

  private static func isOrdered(_ value: String, after previous: String) -> Bool {
    previous.utf8.lexicographicallyPrecedes(value.utf8)
  }

  private func checkContext(_ context: RequestContext) throws {
    if Task.isCancelled { throw BackendError.cancelled }
    if context.deadline < Date() { throw BackendError.deadlineExceeded }
  }

  private static func calculateMetadata(
    file: FileHandle,
    identity: FileIdentity,
    deadline: Date
  ) throws -> ObjectMetadata {
    var md5 = Insecure.MD5()
    var sha256 = SHA256()
    while let data = try file.read(upToCount: 64 * 1_024), !data.isEmpty {
      try Task.checkCancellation()
      guard Date() <= deadline else { throw BackendError.deadlineExceeded }
      md5.update(data: data)
      sha256.update(data: data)
    }
    let md5Value = Data(md5.finalize()).map { String(format: "%02x", $0) }.joined()
    guard let entityTag = EntityTag(rawValue: "\"\(md5Value)\"") else { throw BackendError.consistencyFailure }
    return ObjectMetadata(
      contentType: nil,
      contentLength: identity.size,
      lastModified: identity.date,
      entityTag: entityTag,
      checksums: [ObjectChecksum(algorithm: .sha256, base64Value: Data(sha256.finalize()).base64EncodedString())],
      versionToken: identity.versionToken
    )
  }

  private static func fileBodyStream(
    mapper: POSIXPathMapper,
    bucket: BucketName,
    key: ObjectKey,
    identity: FileIdentity,
    range: ByteRange?,
    maximumChunkBytes: Int,
    deadline: Date
  ) -> ObjectBodyStream {
    let source = POSIXFileBodySource(
      mapper: mapper,
      bucket: bucket,
      key: key,
      identity: identity,
      range: range,
      maximumChunkBytes: maximumChunkBytes,
      deadline: deadline
    )
    return ObjectBodyStream(
      maximumChunkBytes: maximumChunkBytes,
      stream: AsyncThrowingStream(unfolding: { try await source.next() })
    )
  }
}

private enum POSIXListEntry {
  case object(ObjectKey)
  case prefix(String)

  var orderingValue: String {
    switch self {
    case .object(let key): key.rawValue
    case .prefix(let value): value
    }
  }

  var identifier: String {
    switch self {
    case .object(let key): "object:\(key.rawValue)"
    case .prefix(let value): "prefix:\(value)"
    }
  }

  static func isOrdered(_ lhs: Self, _ rhs: Self) -> Bool {
    if lhs.orderingValue == rhs.orderingValue {
      return lhs.identifier.utf8.lexicographicallyPrecedes(rhs.identifier.utf8)
    }
    return lhs.orderingValue.utf8.lexicographicallyPrecedes(rhs.orderingValue.utf8)
  }
}

private func identityForDescriptor(_ descriptor: Int32) throws -> FileIdentity {
  var value = stat()
  guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink == 1 else {
    throw BackendError.consistencyFailure
  }
  return FileIdentity(value)
}

private struct POSIXWriteDigest: Sendable {
  let length: Int64
  let md5Hex: String
  let md5Base64: String
  let sha256Base64: String
}

private actor POSIXWriteAccumulator {
  private let file: FileHandle
  private let expectedLength: Int64?
  private let deadline: Date
  private let faultInjector: POSIXFaultInjector
  private var length: Int64 = 0
  private var md5 = Insecure.MD5()
  private var sha256 = SHA256()

  init(
    file: FileHandle,
    expectedLength: Int64?,
    deadline: Date,
    faultInjector: POSIXFaultInjector
  ) {
    self.file = file
    self.expectedLength = expectedLength
    self.deadline = deadline
    self.faultInjector = faultInjector
  }

  func append(_ chunk: Data) throws {
    try Task.checkCancellation()
    guard Date() <= deadline else { throw BackendError.deadlineExceeded }
    length += Int64(chunk.count)
    if let expectedLength, length > expectedLength {
      throw BackendError.invalidRequest("Body exceeds Content-Length.")
    }
    md5.update(data: chunk)
    sha256.update(data: chunk)
    try file.write(contentsOf: chunk)
  }

  func finish(durability: DurabilityMode) throws -> POSIXWriteDigest {
    guard Date() <= deadline else { throw BackendError.deadlineExceeded }
    if let expectedLength, length != expectedLength {
      throw BackendError.invalidRequest("Body length does not match Content-Length.")
    }
    switch durability {
    case .relaxed: break
    case .data:
      try faultInjector.inject(.dataSynchronization)
      try file.synchronize()
    case .strict:
      try faultInjector.inject(.dataSynchronization)
      try file.synchronize()
      guard fcntl(file.fileDescriptor, F_FULLFSYNC) == 0 else { throw BackendError.consistencyFailure }
    }
    try file.close()
    let md5Data = Data(md5.finalize())
    return POSIXWriteDigest(
      length: length,
      md5Hex: md5Data.map { String(format: "%02x", $0) }.joined(),
      md5Base64: md5Data.base64EncodedString(),
      sha256Base64: Data(sha256.finalize()).base64EncodedString()
    )
  }
}

private actor POSIXFileBodySource {
  private let mapper: POSIXPathMapper
  private let bucket: BucketName
  private let key: ObjectKey
  private let identity: FileIdentity
  private let lowerBound: Int64
  private let requestedEnd: Int64
  private let maximumChunkBytes: Int
  private let deadline: Date
  private var file: FileHandle?
  private var position: Int64
  private var completed = false

  init(
    mapper: POSIXPathMapper,
    bucket: BucketName,
    key: ObjectKey,
    identity: FileIdentity,
    range: ByteRange?,
    maximumChunkBytes: Int,
    deadline: Date
  ) {
    self.mapper = mapper
    self.bucket = bucket
    self.key = key
    self.identity = identity
    lowerBound = range?.lowerBound ?? 0
    requestedEnd = range?.upperBound.map { min($0 + 1, identity.size) } ?? identity.size
    self.maximumChunkBytes = maximumChunkBytes
    self.deadline = deadline
    position = lowerBound
  }

  deinit {
    try? file?.close()
  }

  func next() throws -> Data? {
    guard !completed else { return nil }
    do {
      try Task.checkCancellation()
      guard Date() <= deadline else { throw BackendError.deadlineExceeded }
      let file = try openIfNeeded()
      guard position < requestedEnd else {
        guard try identityForDescriptor(file.fileDescriptor) == identity else {
          throw BackendError.consistencyFailure
        }
        try file.close()
        self.file = nil
        completed = true
        return nil
      }
      let count = min(maximumChunkBytes, Int(requestedEnd - position))
      guard let data = try file.read(upToCount: count), !data.isEmpty else {
        throw BackendError.consistencyFailure
      }
      position += Int64(data.count)
      return data
    } catch {
      try? file?.close()
      file = nil
      completed = true
      throw error
    }
  }

  private func openIfNeeded() throws -> FileHandle {
    if let file { return file }
    let (openedFile, openedIdentity) = try mapper.openObjectForReading(
      bucket: bucket,
      key: key
    )
    guard openedIdentity == identity else {
      try? openedFile.close()
      throw BackendError.consistencyFailure
    }
    try openedFile.seek(toOffset: UInt64(lowerBound))
    file = openedFile
    return openedFile
  }
}
