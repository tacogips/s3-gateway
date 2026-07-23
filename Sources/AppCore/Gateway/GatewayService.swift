import Foundation

public actor GatewayService {
  private let backend: any ObjectStoreBackend
  private let capabilities: BackendCapabilities

  public init(backend: any ObjectStoreBackend) async throws {
    self.backend = backend
    capabilities = await backend.capabilities()
    let baseline: Set<BackendCapability> = [
      .rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256
    ]
    if let missing = baseline.subtracting(capabilities.supported).first {
      throw BackendError.unsupported(missing)
    }
  }

  public var backendKind: BackendKind { backend.kind }

  public func get(_ request: GetObjectRequest, context: RequestContext) async throws -> GetObjectResult {
    if request.range != nil { try require(.rangeRead) }
    if request.conditions != ReadConditions() { try require(.conditionalRead) }
    let result = try await withDeadline(context.deadline) {
      try await self.backend.getObject(request, context: context)
    }
    try validate(result.metadata)
    return result
  }

  public func head(_ request: HeadObjectRequest, context: RequestContext) async throws -> ObjectMetadata {
    if request.conditions != ReadConditions() { try require(.conditionalRead) }
    let metadata = try await withDeadline(context.deadline) {
      try await self.backend.headObject(request, context: context)
    }
    try validate(metadata)
    return metadata
  }

  public func put(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult {
    if request.conditions.ifMatch != nil || request.conditions.requireAbsent { try require(.conditionalWrite) }
    if !request.userMetadata.isEmpty { try require(.userMetadata) }
    for checksum in request.expectedChecksums {
      switch checksum.algorithm {
      case .sha256: try require(.checksumSHA256)
      case .crc32c: try require(.checksumCRC32C)
      }
    }
    let result = try await withDeadline(context.deadline) {
      try await self.backend.putObject(request, context: context)
    }
    try validate(result.metadata)
    return result
  }

  public func delete(_ request: DeleteObjectRequest, context: RequestContext) async throws {
    if request.conditions.ifMatch != nil || request.conditions.requireAbsent { try require(.conditionalWrite) }
    try await withDeadline(context.deadline) {
      try await self.backend.deleteObject(request, context: context)
    }
  }

  public func list(_ request: ListObjectsV2Request, context: RequestContext) async throws -> ListObjectsV2Result {
    try require(.listPagination)
    let result = try await withDeadline(context.deadline) {
      try await self.backend.listObjectsV2(request, context: context)
    }
    try validate(result)
    return result
  }

  public func capabilityReport() -> BackendCapabilities { capabilities }

  public func readinessCheck() async throws {
    try await backend.readinessCheck()
  }

  private func require(_ capability: BackendCapability) throws {
    guard capabilities.supported.contains(capability) else { throw BackendError.unsupported(capability) }
  }

  private func validate(_ metadata: ObjectMetadata) throws {
    guard metadata.contentLength >= 0,
          metadata.lastModified.timeIntervalSince1970.isFinite,
          Self.isSafeHeaderValue(metadata.entityTag.rawValue),
          metadata.entityTag.rawValue.utf8.count <= 1_024,
          metadata.contentType.map({
            !$0.isEmpty &&
              $0.utf8.count <= 1_024 &&
              Self.isSafeHeaderValue($0)
          }) ?? true,
          metadata.versionToken.rawValue.utf8.count <= 2_048,
          Self.isSafeHeaderValue(metadata.versionToken.rawValue),
          metadata.userMetadata.count <= 128 else {
      throw BackendError.consistencyFailure
    }
    var metadataBytes = 0
    for (name, value) in metadata.userMetadata {
      guard !name.isEmpty,
            name.utf8.count <= 128,
            name.utf8.allSatisfy(Self.isHeaderTokenByte),
            Self.isSafeHeaderValue(value) else {
        throw BackendError.consistencyFailure
      }
      metadataBytes += name.utf8.count + value.utf8.count
    }
    guard metadataBytes <= 8 * 1_024,
          Set(metadata.checksums.map(\.algorithm)).count == metadata.checksums.count else {
      throw BackendError.consistencyFailure
    }
    for checksum in metadata.checksums {
      let expectedBytes = checksum.algorithm == .sha256 ? 32 : 4
      guard let decoded = Data(base64Encoded: checksum.base64Value),
            decoded.count == expectedBytes,
            decoded.base64EncodedString() == checksum.base64Value else {
        throw BackendError.consistencyFailure
      }
    }
  }

  private func validate(_ result: ListObjectsV2Result) throws {
    guard result.objects.count + result.commonPrefixes.count <= 1_000,
          result.nextContinuationToken.map({ $0.utf8.count <= 12 * 1_024 }) ?? true,
          result.commonPrefixes.allSatisfy({
            $0.utf8.count <= 1_024 &&
              !$0.unicodeScalars.contains(where: {
                $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              })
          }) else {
      throw BackendError.consistencyFailure
    }
    for object in result.objects {
      guard object.size >= 0,
            object.lastModified.timeIntervalSince1970.isFinite,
            object.entityTag.rawValue.utf8.count <= 1_024,
            Self.isSafeHeaderValue(object.entityTag.rawValue) else {
        throw BackendError.consistencyFailure
      }
    }
  }

  private static func isSafeHeaderValue(_ value: String) -> Bool {
    value.utf8.allSatisfy { byte in
      byte == 9 || byte >= 32 && byte != 127
    }
  }

  private static func isHeaderTokenByte(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) ||
      (97...122).contains(byte) ||
      (48...57).contains(byte) ||
      [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
  }

  private func withDeadline<Value: Sendable>(
    _ deadline: Date,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { throw BackendError.deadlineExceeded }
    return try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask {
        try await operation()
      }
      group.addTask {
        try await Task.sleep(
          for: .nanoseconds(max(1, Int64(remaining * 1_000_000_000)))
        )
        throw BackendError.deadlineExceeded
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else {
        throw BackendError.cancelled
      }
      return result
    }
  }
}
