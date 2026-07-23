import Foundation
import Testing
@testable import AppCore

@Test func gatewayServiceRejectsMissingStageOneBaselineAtStartup() async {
  let backend = CapabilityBackend(supported: [.rangeRead])
  await #expect(throws: BackendError.self) {
    _ = try await GatewayService(backend: backend)
  }
}

@Test func gatewayServiceRejectsUnsupportedChecksumBeforeBackendInvocation() async throws {
  let backend = CapabilityBackend(
    supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256]
  )
  let service = try await GatewayService(backend: backend)
  await #expect(throws: BackendError.unsupported(.checksumCRC32C)) {
    _ = try await service.put(
      PutObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "object"),
        body: ObjectBodyStream(data: Data("body".utf8)),
        expectedChecksums: [ObjectChecksum(algorithm: .crc32c, base64Value: "AAAAAA==")]
      ),
      context: RequestContext(
        requestID: "request",
        principalID: try #require(PrincipalID(rawValue: "principal")),
        deadline: Date().addingTimeInterval(30)
      )
    )
  }
  #expect(await backend.putInvocations == 0)
}

@Test func gatewayServicePropagatesBackendReadinessFailure() async throws {
  let backend = CapabilityBackend(
    supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256],
    readinessError: .unavailable(retryable: true)
  )
  let service = try await GatewayService(backend: backend)
  await #expect(throws: BackendError.unavailable(retryable: true)) {
    try await service.readinessCheck(deadline: Date().addingTimeInterval(30))
  }
}

@Test func gatewayServiceRejectsExpiredReadinessBeforeBackendInvocation() async throws {
  let backend = CapabilityBackend(
    supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256]
  )
  let service = try await GatewayService(backend: backend)

  await #expect(throws: BackendError.deadlineExceeded) {
    try await service.readinessCheck(deadline: Date().addingTimeInterval(-1))
  }
  #expect(await backend.readinessInvocations == 0)
}

@Test func gatewayServiceCancelsBackendWorkAtRequestDeadline() async throws {
  let backend = CapabilityBackend(
    supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256],
    putDelay: .seconds(30)
  )
  let service = try await GatewayService(backend: backend)
  let context = RequestContext(
    requestID: "deadline",
    principalID: try #require(PrincipalID(rawValue: "principal")),
    deadline: Date().addingTimeInterval(0.05)
  )
  await #expect(throws: BackendError.deadlineExceeded) {
    _ = try await service.put(
      PutObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "object"),
        body: ObjectBodyStream(data: Data())
      ),
      context: context
    )
  }
  #expect(await backend.cancelledPutInvocations == 1)
}

@Test func gatewayServiceRejectsBackendMetadataHeaderInjection() async throws {
  let backend = CapabilityBackend(
    supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256],
    headMetadata: ObjectMetadata(
      contentType: "text/plain",
      contentLength: 1,
      lastModified: Date(),
      entityTag: try #require(EntityTag(rawValue: "\"safe\"")),
      userMetadata: ["unsafe": "value\r\ninjected: true"],
      versionToken: ObjectVersionToken(rawValue: "version")
    )
  )
  let service = try await GatewayService(backend: backend)
  await #expect(throws: BackendError.consistencyFailure) {
    _ = try await service.head(
      HeadObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "object")
      ),
      context: RequestContext(
        requestID: "metadata",
        principalID: try #require(PrincipalID(rawValue: "principal")),
        deadline: Date().addingTimeInterval(1)
      )
    )
  }
}

private actor CapabilityBackend: ObjectStoreBackend {
  nonisolated let kind: BackendKind = .posix
  private let supported: Set<BackendCapability>
  private let readinessError: BackendError?
  private let putDelay: Duration?
  private let headMetadata: ObjectMetadata?
  private(set) var readinessInvocations = 0
  private(set) var putInvocations = 0
  private(set) var cancelledPutInvocations = 0

  init(
    supported: Set<BackendCapability>,
    readinessError: BackendError? = nil,
    putDelay: Duration? = nil,
    headMetadata: ObjectMetadata? = nil
  ) {
    self.supported = supported
    self.readinessError = readinessError
    self.putDelay = putDelay
    self.headMetadata = headMetadata
  }

  func capabilities() -> BackendCapabilities {
    BackendCapabilities(supported: supported, consistencyDescription: "test")
  }

  func readinessCheck(deadline: Date) throws {
    guard deadline > Date() else {
      throw BackendError.deadlineExceeded
    }
    readinessInvocations += 1
    if let readinessError { throw readinessError }
  }

  func getObject(_ request: GetObjectRequest, context: RequestContext) throws -> GetObjectResult {
    throw BackendError.notFound
  }

  func headObject(_ request: HeadObjectRequest, context: RequestContext) throws -> ObjectMetadata {
    if let headMetadata { return headMetadata }
    throw BackendError.notFound
  }

  func putObject(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult {
    putInvocations += 1
    if let putDelay {
      do {
        try await Task.sleep(for: putDelay)
      } catch {
        cancelledPutInvocations += 1
        throw BackendError.cancelled
      }
    }
    throw BackendError.consistencyFailure
  }

  func deleteObject(_ request: DeleteObjectRequest, context: RequestContext) throws {}

  func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) throws -> ListObjectsV2Result {
    ListObjectsV2Result(objects: [], commonPrefixes: [], nextContinuationToken: nil)
  }
}
