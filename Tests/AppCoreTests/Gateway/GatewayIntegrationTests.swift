import Crypto
import Foundation
import Testing
@testable import AppCore

@Test func signedGatewayPutAndGetReachPOSIXBackend() async throws {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let root = base.appendingPathComponent("data", isDirectory: true)
  let bucketDirectory = root.appendingPathComponent("bucket", isDirectory: true)
  let metadata = base.appendingPathComponent("metadata", isDirectory: true)
  try FileManager.default.createDirectory(at: bucketDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: metadata.path)
  defer { try? FileManager.default.removeItem(at: base) }

  let backend = try POSIXBackend(
    configuration: POSIXBackendConfiguration(
      rootPath: root.path,
      bucketDirectories: ["my-bucket": "bucket"],
      layoutPolicy: .sharedLocalDirectory,
      sidecarPath: metadata.path,
      durability: .data
    )
  )
  let service = try await GatewayService(backend: backend)
  let healthClassifier = HealthRouteClassifier(
    configuration: HealthEndpointConfiguration()
  )
  let principal = PrincipalAuthorization(
    principalID: "client-principal",
    grants: [
      AuthorizationGrant(operations: [.putObject, .getObject, .headObject], bucket: "my-bucket")
    ]
  )
  let telemetry = IntegrationTelemetrySink()
  let application = S3GatewayApplication(
    router: S3OperationRouter(resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])),
    verifier: SigV4Verifier(credentials: IntegrationInboundCredentials(), acceptedRegions: ["us-east-1"]),
    authorization: try AuthorizationPolicy(principals: [principal]),
    pagination: PaginationTokenService(provider: IntegrationPaginationKeys(), maximumLifetime: 300),
    service: service,
    limits: .defaults,
    healthClassifier: healthClassifier,
    telemetry: telemetry
  )
  let healthResponse = await application.handle(
    HTTPTransportRequest(
      method: "GET",
      rawPath: "/.well-known/s3-gateway/ready",
      rawQuery: "",
      headers: [:],
      body: ObjectBodyStream(data: Data()),
      healthClassifier: healthClassifier
    )
  )
  #expect(healthResponse.status == 200)
  #expect(healthResponse.headers.contains { $0.0 == "cache-control" && $0.1 == "no-store" })
  let bytes = Data("gateway-body".utf8)
  let put = try signedTransportRequest(method: "PUT", path: "/my-bucket/file.txt", body: bytes)
  let putResponse = await application.handle(put)
  #expect(putResponse.status == 200)

  let get = try signedTransportRequest(method: "GET", path: "/my-bucket/file.txt", body: Data())
  let getResponse = await application.handle(get)
  #expect(getResponse.status == 200)
  let collector = GatewayDataCollector()
  try await #require(getResponse.body).consume { await collector.append($0) }
  #expect(await collector.data == bytes)

  let missingHead = try signedTransportRequest(method: "HEAD", path: "/my-bucket/missing.txt", body: Data())
  let missingHeadResponse = await application.handle(missingHead)
  #expect(missingHeadResponse.status == 404)
  #expect(missingHeadResponse.body == nil)
  let events = await telemetry.events
  #expect(events.count == 4)
  #expect(events.map(\.method) == [.get, .put, .get, .head])
  #expect(events.map(\.status) == [200, 200, 200, 404])
}

@Test func readinessRouteReturnsUnavailableWhenBackendProbeFails() async throws {
  let service = try await GatewayService(backend: UnreadyIntegrationBackend())
  let healthClassifier = HealthRouteClassifier(
    configuration: HealthEndpointConfiguration()
  )
  let application = S3GatewayApplication(
    router: S3OperationRouter(resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])),
    verifier: SigV4Verifier(credentials: IntegrationInboundCredentials(), acceptedRegions: ["us-east-1"]),
    authorization: try AuthorizationPolicy(principals: []),
    pagination: PaginationTokenService(provider: IntegrationPaginationKeys(), maximumLifetime: 300),
    service: service,
    limits: .defaults,
    healthClassifier: healthClassifier
  )
  let response = await application.handle(
    HTTPTransportRequest(
      method: "GET",
      rawPath: "/.well-known/s3-gateway/ready",
      rawQuery: "",
      headers: [:],
      body: ObjectBodyStream(data: Data()),
      healthClassifier: healthClassifier
    )
  )
  #expect(response.status == 503)
  let collector = GatewayDataCollector()
  try await #require(response.body).consume { await collector.append($0) }
  #expect(String(data: await collector.data, encoding: .utf8)?.contains("not-ready") == true)
}

@Test func readinessCancellationReleasesDedicatedAdmissionWithoutAffectingObjectWork() async throws {
  let backend = BlockingReadinessIntegrationBackend()
  let service = try await GatewayService(backend: backend)
  let healthClassifier = HealthRouteClassifier(
    configuration: HealthEndpointConfiguration()
  )
  let application = S3GatewayApplication(
    router: S3OperationRouter(
      resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
    ),
    verifier: SigV4Verifier(
      credentials: IntegrationInboundCredentials(),
      acceptedRegions: ["us-east-1"]
    ),
    authorization: try AuthorizationPolicy(principals: []),
    pagination: PaginationTokenService(
      provider: IntegrationPaginationKeys(),
      maximumLifetime: 300
    ),
    service: service,
    limits: .defaults,
    healthClassifier: healthClassifier
  )
  let readinessRequest = HTTPTransportRequest(
    method: "GET",
    rawPath: "/.well-known/s3-gateway/ready",
    rawQuery: "",
    headers: [:],
    body: ObjectBodyStream(data: Data()),
    healthClassifier: healthClassifier,
    deadline: Date().addingTimeInterval(30)
  )
  let firstProbe = Task {
    await application.handle(readinessRequest)
  }
  await backend.waitUntilStarted()

  let saturatedResponse = await application.handle(readinessRequest)
  #expect(saturatedResponse.status == 503)
  let saturatedBody = GatewayDataCollector()
  try await #require(saturatedResponse.body).consume {
    await saturatedBody.append($0)
  }
  #expect(await saturatedBody.data == Data("{\"status\":\"not-ready\"}\n".utf8))
  #expect(await backend.readinessInvocations == 1)

  firstProbe.cancel()
  #expect(await firstProbe.value.status == 503)
  await backend.waitUntilCancelled()
  #expect(await backend.cancelledInvocations == 1)

  let recoveredResponse = await application.handle(readinessRequest)
  #expect(recoveredResponse.status == 200)
  #expect(await backend.readinessInvocations == 2)
}

@Test func forgedHealthAdmissionFailsClosedBeforeBackendOrAuthentication() async throws {
  let backend = BlockingReadinessIntegrationBackend()
  let service = try await GatewayService(backend: backend)
  let healthClassifier = HealthRouteClassifier(
    configuration: HealthEndpointConfiguration()
  )
  let application = S3GatewayApplication(
    router: S3OperationRouter(
      resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
    ),
    verifier: SigV4Verifier(
      credentials: IntegrationInboundCredentials(),
      acceptedRegions: ["us-east-1"]
    ),
    authorization: try AuthorizationPolicy(principals: []),
    pagination: PaginationTokenService(
      provider: IntegrationPaginationKeys(),
      maximumLifetime: 300
    ),
    service: service,
    limits: .defaults,
    healthClassifier: healthClassifier
  )
  let response = await application.handle(
    HTTPTransportRequest(
      method: "GET",
      rawPath: "/.well-known/s3-gateway/ready",
      rawQuery: "",
      headers: [:],
      body: ObjectBodyStream(data: Data())
    )
  )

  #expect(response.status == 500)
  #expect(response.body == nil)
  #expect(await backend.readinessInvocations == 0)
}

@Test func gatewayFailsClosedWhenBackendListEscapesAuthorizedScope() async throws {
  let service = try await GatewayService(backend: EscapingListIntegrationBackend())
  let principal = PrincipalAuthorization(
    principalID: "client-principal",
    grants: [
      AuthorizationGrant(
        operations: [.listObjectsV2],
        bucket: "my-bucket",
        keyPrefix: "allowed"
      )
    ]
  )
  let application = S3GatewayApplication(
    router: S3OperationRouter(resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])),
    verifier: SigV4Verifier(credentials: IntegrationInboundCredentials(), acceptedRegions: ["us-east-1"]),
    authorization: try AuthorizationPolicy(principals: [principal]),
    pagination: PaginationTokenService(provider: IntegrationPaginationKeys(), maximumLifetime: 300),
    service: service,
    limits: .defaults
  )
  let request = try signedTransportRequest(
    method: "GET",
    path: "/my-bucket",
    rawQuery: "list-type=2&prefix=allowed%2F",
    body: Data()
  )
  let response = await application.handle(request)
  #expect(response.status == 500)
}

@Test func signedGatewayGetTraversesTheS3BackendBoundary() async throws {
  let upstream = IntegrationUpstreamClient()
  let backend = S3Backend(
    configuration: UpstreamS3Configuration(
      endpoint: try #require(URL(string: "https://upstream.example.test")),
      region: "us-east-1",
      addressingStyle: .path,
      bucketMappings: ["my-bucket": "remote-bucket"]
    ),
    credentials: IntegrationUpstreamCredentials(),
    client: upstream,
    maximumChunkBytes: 1_024
  )
  let service = try await GatewayService(backend: backend)
  let principal = PrincipalAuthorization(
    principalID: "client-principal",
    grants: [
      AuthorizationGrant(
        operations: [.getObject],
        bucket: "my-bucket"
      )
    ]
  )
  let application = S3GatewayApplication(
    router: S3OperationRouter(resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])),
    verifier: SigV4Verifier(credentials: IntegrationInboundCredentials(), acceptedRegions: ["us-east-1"]),
    authorization: try AuthorizationPolicy(principals: [principal]),
    pagination: PaginationTokenService(provider: IntegrationPaginationKeys(), maximumLifetime: 300),
    service: service,
    limits: .defaults
  )
  let response = await application.handle(
    try signedTransportRequest(
      method: "GET",
      path: "/my-bucket/nested/file.txt",
      body: Data()
    )
  )
  #expect(response.status == 200)
  let collector = GatewayDataCollector()
  try await #require(response.body).consume { await collector.append($0) }
  #expect(await collector.data == Data("from-upstream".utf8))
  let request = try #require(await upstream.requests.first)
  #expect(request.url.path == "/remote-bucket/nested/file.txt")
  #expect(request.headers.contains {
    $0.0 == "authorization" && $0.1.hasPrefix("AWS4-HMAC-SHA256")
  })
  #expect(!request.headers.contains { $0.1.contains("integration-secret-value") })
}

@Test func signedVirtualHostRequestReachesAuthorizedObject() async throws {
  let backend = VirtualHostIntegrationBackend()
  let service = try await GatewayService(backend: backend)
  let application = S3GatewayApplication(
    router: S3OperationRouter(
      resolver: S3AddressingResolver(
        styles: [.virtualHost],
        virtualHostSuffixes: ["s3.localhost"]
      )
    ),
    verifier: SigV4Verifier(
      credentials: IntegrationInboundCredentials(),
      acceptedRegions: ["us-east-1"]
    ),
    authorization: try AuthorizationPolicy(
      principals: [
        PrincipalAuthorization(
          principalID: "client-principal",
          grants: [
            AuthorizationGrant(
              operations: [.getObject],
              bucket: "my-bucket"
            )
          ]
        )
      ]
    ),
    pagination: PaginationTokenService(
      provider: IntegrationPaginationKeys(),
      maximumLifetime: 300
    ),
    service: service,
    limits: .defaults
  )
  let response = await application.handle(
    try signedTransportRequest(
      method: "GET",
      path: "/nested/object.txt",
      host: "my-bucket.s3.localhost",
      body: Data()
    )
  )
  #expect(response.status == 200)
  let observed = try #require(await backend.lastGet)
  #expect(observed.bucket.rawValue == "my-bucket")
  #expect(observed.key.rawValue == "nested/object.txt")
}

@Test func authorizationDenialDoesNotCallBackendOrRevealExistence() async throws {
  let backend = VirtualHostIntegrationBackend()
  let service = try await GatewayService(backend: backend)
  let application = S3GatewayApplication(
    router: S3OperationRouter(
      resolver: S3AddressingResolver(
        styles: [.path],
        virtualHostSuffixes: []
      )
    ),
    verifier: SigV4Verifier(
      credentials: IntegrationInboundCredentials(),
      acceptedRegions: ["us-east-1"]
    ),
    authorization: try AuthorizationPolicy(principals: []),
    pagination: PaginationTokenService(
      provider: IntegrationPaginationKeys(),
      maximumLifetime: 300
    ),
    service: service,
    limits: .defaults
  )
  let existingShape = await application.handle(
    try signedTransportRequest(
      method: "GET",
      path: "/my-bucket/existing.txt",
      body: Data()
    )
  )
  let missingShape = await application.handle(
    try signedTransportRequest(
      method: "GET",
      path: "/my-bucket/missing.txt",
      body: Data()
    )
  )
  #expect(existingShape.status == 403)
  #expect(missingShape.status == 403)
  #expect(existingShape.headers.map(\.0) == missingShape.headers.map(\.0))
  #expect(await backend.getCount == 0)
}

@Test func signedPayloadAndExplicitSHA256MergeWithoutDuplicateBackendChecksums() async throws {
  let backend = ChecksumCaptureIntegrationBackend()
  let service = try await GatewayService(backend: backend)
  let application = S3GatewayApplication(
    router: S3OperationRouter(
      resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
    ),
    verifier: SigV4Verifier(
      credentials: IntegrationInboundCredentials(),
      acceptedRegions: ["us-east-1"]
    ),
    authorization: try AuthorizationPolicy(
      principals: [
        PrincipalAuthorization(
          principalID: "client-principal",
          grants: [
            AuthorizationGrant(
              operations: [.putObject],
              bucket: "test-bucket"
            )
          ]
        )
      ]
    ),
    pagination: PaginationTokenService(
      provider: IntegrationPaginationKeys(),
      maximumLifetime: 300
    ),
    service: service,
    limits: .defaults
  )
  let body = Data("checksum-body".utf8)
  let payloadHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
  let checksum = Data(SHA256.hash(data: body)).base64EncodedString()
  let request = try signedTransportRequest(
    method: "PUT",
    path: "/test-bucket/checksum.bin",
    body: body,
    additionalHeaders: [("x-amz-checksum-sha256", checksum)],
    payloadHash: payloadHash
  )
  let response = await application.handle(request)
  #expect(response.status == 200)
  #expect(await backend.capturedChecksums == [
    ObjectChecksum(algorithm: .sha256, base64Value: checksum)
  ])

  let conflicting = try signedTransportRequest(
    method: "PUT",
    path: "/test-bucket/conflicting.bin",
    body: body,
    additionalHeaders: [
      ("x-amz-checksum-sha256", Data(repeating: 7, count: 32).base64EncodedString())
    ],
    payloadHash: payloadHash
  )
  let conflictingResponse = await application.handle(conflicting)
  #expect(conflictingResponse.status == 400)
  let collector = GatewayDataCollector()
  try await #require(conflictingResponse.body).consume { await collector.append($0) }
  #expect(String(data: await collector.data, encoding: .utf8)?.contains("BadDigest") == true)
  #expect(await backend.putCount == 1)
}

private func signedTransportRequest(
  method: String,
  path: String,
  rawQuery: String = "",
  host: String = "localhost",
  body: Data,
  additionalHeaders: [(String, String)] = [],
  payloadHash explicitPayloadHash: String? = nil
) throws -> HTTPTransportRequest {
  let now = Date()
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
  let date = formatter.string(from: now)
  let payloadHash = explicitPayloadHash ??
    SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
  var headers: [String: [String]] = [
    "host": [host],
    "x-amz-content-sha256": [payloadHash],
    "x-amz-date": [date]
  ]
  for (name, value) in additionalHeaders {
    headers[name.lowercased(), default: []].append(value)
  }
  let signedHeaders = headers.keys.sorted()
  let canonical = try SigV4Canonicalizer.canonicalRequest(
    request: SigV4Request(
      method: method,
      rawPath: path,
      rawQuery: rawQuery,
      headers: headers,
      payloadHash: payloadHash
    ),
    signedHeaders: signedHeaders
  )
  let shortDate = String(date.prefix(8))
  let scope = "\(shortDate)/us-east-1/s3/aws4_request"
  let stringToSign = ["AWS4-HMAC-SHA256", date, scope, SigV4Canonicalizer.sha256Hex(canonical)].joined(separator: "\n")
  let key = SigV4Verifier.deriveSigningKey(
    secret: SymmetricKey(data: Data("integration-secret-value".utf8)),
    date: shortDate,
    region: "us-east-1",
    service: "s3"
  )
  let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
    .map { String(format: "%02x", $0) }.joined()
  headers["authorization"] = [
    "AWS4-HMAC-SHA256 Credential=INTEGRATIONKEY/\(scope), SignedHeaders=\(signedHeaders.joined(separator: ";")), Signature=\(signature)"
  ]
  headers["content-length"] = [String(body.count)]
  return HTTPTransportRequest(
    method: method,
    rawPath: path,
    rawQuery: rawQuery,
    headers: headers,
    body: ObjectBodyStream(data: body)
  )
}

private actor ChecksumCaptureIntegrationBackend: ObjectStoreBackend {
  nonisolated let kind: BackendKind = .s3
  private(set) var capturedChecksums: [ObjectChecksum] = []
  private(set) var putCount = 0

  nonisolated func capabilities() -> BackendCapabilities {
    BackendCapabilities(
      supported: [
        .rangeRead,
        .conditionalRead,
        .listPagination,
        .userMetadata,
        .checksumSHA256
      ],
      consistencyDescription: "test"
    )
  }

  func getObject(
    _ request: GetObjectRequest,
    context: RequestContext
  ) async throws -> GetObjectResult {
    throw BackendError.notFound
  }

  func headObject(
    _ request: HeadObjectRequest,
    context: RequestContext
  ) async throws -> ObjectMetadata {
    throw BackendError.notFound
  }

  func putObject(
    _ request: PutObjectRequest,
    context: RequestContext
  ) async throws -> PutObjectResult {
    putCount += 1
    capturedChecksums = request.expectedChecksums
    guard let entityTag = EntityTag(rawValue: "\"checksum\"") else {
      throw BackendError.consistencyFailure
    }
    return PutObjectResult(
      metadata: ObjectMetadata(
        contentType: request.contentType,
        contentLength: request.knownContentLength ?? 0,
        lastModified: Date(timeIntervalSince1970: 0),
        entityTag: entityTag,
        userMetadata: request.userMetadata,
        checksums: request.expectedChecksums,
        versionToken: ObjectVersionToken(rawValue: "checksum")
      )
    )
  }

  func deleteObject(
    _ request: DeleteObjectRequest,
    context: RequestContext
  ) async throws {}

  func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result {
    ListObjectsV2Result(objects: [], commonPrefixes: [], nextContinuationToken: nil)
  }
}

private actor VirtualHostIntegrationBackend: ObjectStoreBackend {
  nonisolated let kind: BackendKind = .posix
  private(set) var lastGet: GetObjectRequest?
  private(set) var getCount = 0

  nonisolated func capabilities() -> BackendCapabilities {
    BackendCapabilities(
      supported: [
        .rangeRead,
        .conditionalRead,
        .listPagination,
        .userMetadata,
        .checksumSHA256
      ],
      consistencyDescription: "test"
    )
  }

  func getObject(
    _ request: GetObjectRequest,
    context: RequestContext
  ) async throws -> GetObjectResult {
    getCount += 1
    lastGet = request
    guard let entityTag = EntityTag(rawValue: "\"virtual\"") else {
      throw BackendError.consistencyFailure
    }
    return GetObjectResult(
      metadata: ObjectMetadata(
        contentType: "text/plain",
        contentLength: 7,
        lastModified: Date(timeIntervalSince1970: 0),
        entityTag: entityTag,
        checksums: [],
        versionToken: ObjectVersionToken(rawValue: "virtual")
      ),
      body: ObjectBodyStream(data: Data("virtual".utf8)),
      servedRange: nil
    )
  }

  func headObject(
    _ request: HeadObjectRequest,
    context: RequestContext
  ) async throws -> ObjectMetadata {
    throw BackendError.notFound
  }

  func putObject(
    _ request: PutObjectRequest,
    context: RequestContext
  ) async throws -> PutObjectResult {
    throw BackendError.unsupported(.conditionalWrite)
  }

  func deleteObject(
    _ request: DeleteObjectRequest,
    context: RequestContext
  ) async throws {}

  func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result {
    ListObjectsV2Result(
      objects: [],
      commonPrefixes: [],
      nextContinuationToken: nil
    )
  }
}

private struct IntegrationInboundCredentials: InboundCredentialProviding {
  func credential(for accessKeyID: String) async -> InboundVerificationCredential? {
    guard accessKeyID == "INTEGRATIONKEY", let principal = PrincipalID(rawValue: "client-principal") else { return nil }
    return InboundVerificationCredential(
      accessKeyID: accessKeyID,
      principalID: principal,
      signingSecret: SymmetricKey(data: Data("integration-secret-value".utf8))
    )
  }
}

private struct IntegrationPaginationKeys: PaginationKeyProviding {
  let value = PaginationSigningKey(
    keyID: "page",
    key: SymmetricKey(data: Data(repeating: 3, count: 32))
  )

  func activeKey() async -> PaginationSigningKey { value }
  func key(for keyID: String) async -> PaginationSigningKey? { keyID == value.keyID ? value : nil }
}

private actor GatewayDataCollector {
  private(set) var data = Data()
  func append(_ chunk: Data) { data.append(chunk) }
}

private actor IntegrationTelemetrySink: GatewayTelemetrySink {
  private(set) var events: [GatewayTelemetryEvent] = []

  func record(_ event: GatewayTelemetryEvent) {
    events.append(event)
  }
}

private struct UnreadyIntegrationBackend: ObjectStoreBackend {
  let kind: BackendKind = .posix

  func capabilities() -> BackendCapabilities {
    BackendCapabilities(
      supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256],
      consistencyDescription: "test"
    )
  }

  func readinessCheck(deadline: Date) async throws {
    guard deadline > Date() else {
      throw BackendError.deadlineExceeded
    }
    throw BackendError.unavailable(retryable: true)
  }

  func getObject(_ request: GetObjectRequest, context: RequestContext) async throws -> GetObjectResult {
    throw BackendError.notFound
  }

  func headObject(_ request: HeadObjectRequest, context: RequestContext) async throws -> ObjectMetadata {
    throw BackendError.notFound
  }

  func putObject(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult {
    throw BackendError.unavailable(retryable: true)
  }

  func deleteObject(_ request: DeleteObjectRequest, context: RequestContext) async throws {}

  func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result {
    throw BackendError.unavailable(retryable: true)
  }
}

private actor BlockingReadinessIntegrationBackend: ObjectStoreBackend {
  nonisolated let kind: BackendKind = .posix
  private(set) var readinessInvocations = 0
  private(set) var cancelledInvocations = 0
  private var started = false
  private var cancelled = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

  nonisolated func capabilities() -> BackendCapabilities {
    BackendCapabilities(
      supported: [
        .rangeRead,
        .conditionalRead,
        .listPagination,
        .userMetadata,
        .checksumSHA256
      ],
      consistencyDescription: "test"
    )
  }

  func readinessCheck(deadline: Date) async throws {
    guard deadline > Date() else {
      throw BackendError.deadlineExceeded
    }
    readinessInvocations += 1
    guard readinessInvocations == 1 else {
      return
    }
    started = true
    let startWaiters = self.startWaiters
    self.startWaiters.removeAll()
    for waiter in startWaiters {
      waiter.resume()
    }
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      cancelledInvocations += 1
      cancelled = true
      let cancellationWaiters = self.cancellationWaiters
      self.cancellationWaiters.removeAll()
      for waiter in cancellationWaiters {
        waiter.resume()
      }
      throw BackendError.cancelled
    }
  }

  func waitUntilStarted() async {
    guard !started else {
      return
    }
    await withCheckedContinuation {
      startWaiters.append($0)
    }
  }

  func waitUntilCancelled() async {
    guard !cancelled else {
      return
    }
    await withCheckedContinuation {
      cancellationWaiters.append($0)
    }
  }

  func getObject(
    _ request: GetObjectRequest,
    context: RequestContext
  ) async throws -> GetObjectResult {
    throw BackendError.notFound
  }

  func headObject(
    _ request: HeadObjectRequest,
    context: RequestContext
  ) async throws -> ObjectMetadata {
    throw BackendError.notFound
  }

  func putObject(
    _ request: PutObjectRequest,
    context: RequestContext
  ) async throws -> PutObjectResult {
    throw BackendError.unavailable(retryable: false)
  }

  func deleteObject(
    _ request: DeleteObjectRequest,
    context: RequestContext
  ) async throws {}

  func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result {
    ListObjectsV2Result(
      objects: [],
      commonPrefixes: [],
      nextContinuationToken: nil
    )
  }
}

private struct EscapingListIntegrationBackend: ObjectStoreBackend {
  let kind: BackendKind = .s3

  func capabilities() -> BackendCapabilities {
    BackendCapabilities(
      supported: [.rangeRead, .conditionalRead, .listPagination, .userMetadata, .checksumSHA256],
      consistencyDescription: "test"
    )
  }

  func getObject(_ request: GetObjectRequest, context: RequestContext) async throws -> GetObjectResult {
    throw BackendError.notFound
  }

  func headObject(_ request: HeadObjectRequest, context: RequestContext) async throws -> ObjectMetadata {
    throw BackendError.notFound
  }

  func putObject(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult {
    throw BackendError.unavailable(retryable: false)
  }

  func deleteObject(_ request: DeleteObjectRequest, context: RequestContext) async throws {}

  func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result {
    guard let leakedETag = EntityTag(rawValue: "\"leaked\"") else {
      throw BackendError.consistencyFailure
    }
    let leaked = ListedObject(
      key: try ObjectKey(validating: "private/leaked.txt"),
      size: 1,
      lastModified: Date(timeIntervalSince1970: 0),
      entityTag: leakedETag
    )
    return ListObjectsV2Result(
      objects: [leaked],
      commonPrefixes: [],
      nextContinuationToken: "upstream-token"
    )
  }
}

private actor IntegrationUpstreamClient: UpstreamHTTPClient {
  private(set) var requests: [UpstreamHTTPRequest] = []

  func execute(_ request: UpstreamHTTPRequest) async throws -> UpstreamHTTPResponse {
    requests.append(request)
    return UpstreamHTTPResponse(
      status: 200,
      headers: [
        "content-length": ["13"],
        "etag": ["\"remote\""],
        "last-modified": ["Wed, 23 Jul 2026 00:00:00 GMT"]
      ],
      body: ObjectBodyStream(
        data: Data("from-upstream".utf8),
        maximumChunkBytes: 1_024
      )
    )
  }
}

private struct IntegrationUpstreamCredentials: UpstreamCredentialProviding {
  func activeCredential() async -> UpstreamSigningCredential {
    UpstreamSigningCredential(
      accessKeyID: "REMOTEKEY",
      sessionToken: nil,
      signingSecret: SymmetricKey(data: Data("remote-secret-value".utf8))
    )
  }
}
