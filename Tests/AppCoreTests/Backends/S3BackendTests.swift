import Crypto
import Foundation
import Testing
@testable import AppCore

@Test func s3BackendResignsGetAndStreamsResponse() async throws {
  let client = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(
        status: 200,
        headers: [
          "content-length": ["5"],
          "content-type": ["text/plain"],
          "etag": ["\"abc\""],
          "last-modified": ["Wed, 23 Jul 2026 00:00:00 GMT"]
        ],
        body: Data("hello".utf8)
      )
    ]
  )
  let backend = try makeS3Backend(client: client)
  let result = try await backend.getObject(
    GetObjectRequest(
      bucket: try #require(BucketName(rawValue: "my-bucket")),
      key: try ObjectKey(validating: "nested/file.txt")
    ),
    context: try s3Context()
  )
  let collector = S3TestCollector()
  try await result.body.consume { await collector.append($0) }
  #expect(await collector.data == Data("hello".utf8))
  let request = try #require(await client.requests.first)
  #expect(request.url.path == "/upstream-bucket/nested/file.txt")
  #expect(request.headers.contains { $0.0 == "authorization" && $0.1.hasPrefix("AWS4-HMAC-SHA256") })
  #expect(!request.headers.contains { $0.1.contains("inbound-secret") })
}

@Test func s3BackendReadinessUsesSignedHeadBucketProbe() async throws {
  let client = RecordingUpstreamClient(
    responses: [UpstreamResponseSpec(status: 200, headers: [:], body: Data())]
  )
  let backend = try makeS3Backend(client: client)
  try await backend.readinessCheck()
  let request = try #require(await client.requests.first)
  #expect(request.method == "HEAD")
  #expect(request.url.path == "/upstream-bucket")
  #expect(request.headers.contains { $0.0 == "authorization" })
}

@Test func s3BackendReadinessFailsForRejectedBucketProbe() async throws {
  let client = RecordingUpstreamClient(
    responses: [UpstreamResponseSpec(status: 403, headers: [:], body: Data())]
  )
  let backend = try makeS3Backend(client: client)
  await #expect(throws: BackendError.unavailable(retryable: false)) {
    try await backend.readinessCheck()
  }
}

@Test func s3BackendPreservesTotalObjectLengthForRangeResponses() async throws {
  let client = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(
        status: 206,
        headers: [
          "content-length": ["5"],
          "content-range": ["bytes 10-14/100"],
          "etag": ["\"abc\""],
          "last-modified": ["Wed, 23 Jul 2026 00:00:00 GMT"],
          "x-amz-checksum-crc32c": ["AAAAAA=="]
        ],
        body: Data("hello".utf8)
      )
    ]
  )
  let backend = try makeS3Backend(client: client)
  let result = try await backend.getObject(
    GetObjectRequest(
      bucket: try #require(BucketName(rawValue: "my-bucket")),
      key: try ObjectKey(validating: "range.bin"),
      range: try ByteRange(lowerBound: 10, upperBound: 14)
    ),
    context: try s3Context()
  )
  #expect(result.metadata.contentLength == 100)
  #expect(result.metadata.checksums.contains { $0.algorithm == .crc32c })
}

@Test func s3BackendRejectsAmbiguousOrIncompleteMetadataHeaders() async throws {
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "ambiguous.bin")
  let duplicateClient = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(
        status: 200,
        headers: [
          "content-length": ["5"],
          "etag": ["\"first\"", "\"second\""],
          "last-modified": ["Wed, 23 Jul 2026 00:00:00 GMT"]
        ],
        body: Data("hello".utf8)
      )
    ]
  )
  let duplicateBackend = try makeS3Backend(client: duplicateClient)
  await #expect(throws: BackendError.consistencyFailure) {
    _ = try await duplicateBackend.getObject(
      GetObjectRequest(bucket: bucket, key: key),
      context: s3Context()
    )
  }

  let missingClient = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(
        status: 200,
        headers: [
          "content-length": ["5"],
          "etag": ["\"etag\""]
        ],
        body: Data("hello".utf8)
      )
    ]
  )
  let missingBackend = try makeS3Backend(client: missingClient)
  await #expect(throws: BackendError.consistencyFailure) {
    _ = try await missingBackend.headObject(
      HeadObjectRequest(bucket: bucket, key: key),
      context: s3Context()
    )
  }
}

@Test func s3BackendRetryBackoffCannotOutliveRequestDeadline() async throws {
  let client = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(status: 503, headers: [:], body: Data()),
      UpstreamResponseSpec(status: 503, headers: [:], body: Data())
    ]
  )
  let backend = try makeS3Backend(client: client)
  let context = RequestContext(
    requestID: UUID().uuidString,
    principalID: try #require(PrincipalID(rawValue: "test")),
    deadline: Date().addingTimeInterval(0.02)
  )
  let started = ContinuousClock.now
  await #expect(throws: BackendError.deadlineExceeded) {
    _ = try await backend.getObject(
      GetObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "deadline.bin")
      ),
      context: context
    )
  }
  let elapsed = started.duration(to: ContinuousClock.now)
  #expect(elapsed < .milliseconds(100))
  #expect(await client.requests.count < 3)
}

@Test func s3BackendStagesAndVerifiesBeforeUpstreamPut() async throws {
  let client = RecordingUpstreamClient(
    responses: [UpstreamResponseSpec(status: 200, headers: ["etag": ["\"put-etag\""]], body: Data())]
  )
  let backend = try makeS3Backend(client: client)
  let bytes = Data(repeating: 4, count: 150_000)
  let checksum = Data(SHA256.hash(data: bytes)).base64EncodedString()
  let result = try await backend.putObject(
    PutObjectRequest(
      bucket: try #require(BucketName(rawValue: "my-bucket")),
      key: try ObjectKey(validating: "large.bin"),
      body: ObjectBodyStream(data: bytes, maximumChunkBytes: 4_096),
      knownContentLength: Int64(bytes.count),
      expectedChecksums: [ObjectChecksum(algorithm: .sha256, base64Value: checksum)]
    ),
    context: try s3Context()
  )
  #expect(result.metadata.contentLength == Int64(bytes.count))
  #expect(await client.requests.first?.body == bytes)
  let payloadHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  #expect(await client.requests.first?.headers.contains { $0.0 == "x-amz-content-sha256" && $0.1 == payloadHash } == true)
}

@Test func s3BackendRetriesStagedPutWithAReplayableBody() async throws {
  let client = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(status: 503, headers: [:], body: Data("retry".utf8)),
      UpstreamResponseSpec(status: 200, headers: ["etag": ["\"put-etag\""]], body: Data())
    ]
  )
  let backend = try makeS3Backend(client: client)
  let bytes = Data(repeating: 7, count: 70_000)
  _ = try await backend.putObject(
    PutObjectRequest(
      bucket: try #require(BucketName(rawValue: "my-bucket")),
      key: try ObjectKey(validating: "retry.bin"),
      body: ObjectBodyStream(data: bytes, maximumChunkBytes: 4_096),
      knownContentLength: Int64(bytes.count)
    ),
    context: try s3Context()
  )
  let requests = await client.requests
  #expect(requests.count == 2)
  #expect(requests.allSatisfy { $0.body == bytes })
}

@Test func s3BackendDoesNotPublishChecksumMismatch() async throws {
  let client = RecordingUpstreamClient(responses: [])
  let backend = try makeS3Backend(client: client)
  await #expect(throws: BackendError.checksumMismatch) {
    _ = try await backend.putObject(
      PutObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "bad.bin"),
        body: ObjectBodyStream(data: Data("bytes".utf8)),
        expectedChecksums: [ObjectChecksum(algorithm: .sha256, base64Value: Data(repeating: 0, count: 32).base64EncodedString())]
      ),
      context: s3Context()
    )
  }
  #expect(await client.requests.isEmpty)
}

@Test func s3BackendDoesNotRetryExplicitlyNonretryableFailure() async throws {
  let client = RecordingUpstreamClient(responses: [])
  let backend = try makeS3Backend(client: client)
  await #expect(throws: BackendError.unavailable(retryable: false)) {
    _ = try await backend.getObject(
      GetObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "object")
      ),
      context: s3Context()
    )
  }
  #expect(await client.requests.count == 1)
}

@Test func s3BackendRejectsRedirectAndRetriesThrottle() async throws {
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "status.bin")
  let redirectClient = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(
        status: 301,
        headers: ["location": ["https://other.example.test/object"]],
        body: Data()
      )
    ]
  )
  let redirectBackend = try makeS3Backend(client: redirectClient)
  await #expect(
    throws: BackendError.invalidRequest(
      "The upstream S3 service rejected the request."
    )
  ) {
    _ = try await redirectBackend.getObject(
      GetObjectRequest(bucket: bucket, key: key),
      context: s3Context()
    )
  }
  #expect(await redirectClient.requests.count == 1)

  let throttleClient = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(status: 429, headers: [:], body: Data()),
      UpstreamResponseSpec(
        status: 200,
        headers: [
          "content-length": ["2"],
          "etag": ["\"ok\""],
          "last-modified": ["Wed, 23 Jul 2026 00:00:00 GMT"]
        ],
        body: Data("ok".utf8)
      )
    ]
  )
  let throttleBackend = try makeS3Backend(client: throttleClient)
  let result = try await throttleBackend.getObject(
    GetObjectRequest(bucket: bucket, key: key),
    context: s3Context()
  )
  let collector = S3TestCollector()
  try await result.body.consume { await collector.append($0) }
  #expect(await collector.data == Data("ok".utf8))
  #expect(await throttleClient.requests.count == 2)
}

@Test func s3BackendBoundsUpstreamListDocument() async throws {
  let client = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(
        status: 200,
        headers: [:],
        body: Data(repeating: 65, count: 65)
      )
    ]
  )
  let backend = try makeS3Backend(client: client, maximumXMLBytes: 64)
  await #expect(throws: BackendError.capacityExceeded) {
    _ = try await backend.listObjectsV2(
      ListObjectsV2Request(
        bucket: try #require(BucketName(rawValue: "my-bucket"))
      ),
      context: s3Context()
    )
  }
}

@Test func s3CapacityFailureRemovesStageAndNeverContactsUpstream() async throws {
  let staging = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: staging) }
  let client = RecordingUpstreamClient(responses: [])
  let backend = try makeS3Backend(
    client: client,
    stagingDirectory: staging.path
  )
  let pair = AsyncThrowingStream<Data, any Error>.makeStream(
    bufferingPolicy: .bufferingOldest(1)
  )
  pair.continuation.yield(Data(repeating: 3, count: 4_096))
  pair.continuation.finish(throwing: BackendError.capacityExceeded)
  await #expect(throws: BackendError.capacityExceeded) {
    _ = try await backend.putObject(
      PutObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "capacity.bin"),
        body: ObjectBodyStream(
          maximumChunkBytes: 4_096,
          stream: pair.stream
        )
      ),
      context: s3Context()
    )
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
  #expect(await client.requests.isEmpty)
}

@Test func s3BackendParsesListPagination() async throws {
  let xml = """
  <?xml version="1.0" encoding="UTF-8"?>
  <ListBucketResult><Prefix></Prefix><Contents><Key>a.txt</Key>
  <LastModified>2026-07-23T00:00:00Z</LastModified><ETag>"a"</ETag><Size>3</Size>
  </Contents><CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes>
  <NextContinuationToken>next</NextContinuationToken></ListBucketResult>
  """
  let client = RecordingUpstreamClient(
    responses: [UpstreamResponseSpec(status: 200, headers: [:], body: Data(xml.utf8))]
  )
  let backend = try makeS3Backend(client: client)
  let result = try await backend.listObjectsV2(
    ListObjectsV2Request(bucket: try #require(BucketName(rawValue: "my-bucket"))),
    context: try s3Context()
  )
  #expect(result.objects.map(\.key.rawValue) == ["a.txt"])
  #expect(result.commonPrefixes == ["dir/"])
  #expect(result.nextContinuationToken == "next")
}

@Test func cancellingS3PutRemovesStagingAndNeverContactsUpstream() async throws {
  let staging = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: staging) }
  let client = RecordingUpstreamClient(responses: [])
  let backend = try makeS3Backend(client: client, stagingDirectory: staging.path)
  let pair = AsyncThrowingStream<Data, any Error>.makeStream(
    bufferingPolicy: .bufferingOldest(1)
  )
  pair.continuation.yield(Data(repeating: 5, count: 1_024))
  let task = Task {
    try await backend.putObject(
      PutObjectRequest(
        bucket: try #require(BucketName(rawValue: "my-bucket")),
        key: try ObjectKey(validating: "cancelled.bin"),
        body: ObjectBodyStream(maximumChunkBytes: 1_024, stream: pair.stream)
      ),
      context: s3Context()
    )
  }
  try await Task.sleep(for: .milliseconds(50))
  task.cancel()
  await #expect(throws: BackendError.cancelled) {
    _ = try await task.value
  }
  pair.continuation.finish()
  #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
  #expect(await client.requests.isEmpty)
}

@Test func s3BackendRejectsMalformedListEntriesInsteadOfDroppingThem() async throws {
  let xml = """
  <?xml version="1.0" encoding="UTF-8"?>
  <ListBucketResult><Contents><Key>missing-etag.txt</Key>
  <LastModified>2026-07-23T00:00:00Z</LastModified><Size>3</Size>
  </Contents></ListBucketResult>
  """
  let client = RecordingUpstreamClient(
    responses: [
      UpstreamResponseSpec(
        status: 200,
        headers: [:],
        body: Data(xml.utf8)
      )
    ]
  )
  let backend = try makeS3Backend(client: client)
  await #expect(throws: BackendError.consistencyFailure) {
    _ = try await backend.listObjectsV2(
      ListObjectsV2Request(
        bucket: try #require(BucketName(rawValue: "my-bucket"))
      ),
      context: s3Context()
    )
  }
}

private func makeS3Backend(
  client: RecordingUpstreamClient,
  stagingDirectory: String? = nil,
  maximumXMLBytes: Int = 1 * 1_024 * 1_024
) throws -> S3Backend {
  S3Backend(
    configuration: UpstreamS3Configuration(
      endpoint: try #require(URL(string: "https://s3.example.test")),
      region: "us-east-1",
      addressingStyle: .path,
      bucketMappings: ["my-bucket": "upstream-bucket"],
      stagingDirectory: stagingDirectory
    ),
    credentials: TestUpstreamCredentials(),
    client: client,
    maximumChunkBytes: 4_096,
    maximumXMLBytes: maximumXMLBytes
  )
}

private struct TestUpstreamCredentials: UpstreamCredentialProviding {
  func activeCredential() async -> UpstreamSigningCredential {
    UpstreamSigningCredential(
      accessKeyID: "UPSTREAMKEY",
      sessionToken: nil,
      signingSecret: SymmetricKey(data: Data("upstream-secret-value".utf8))
    )
  }
}

private struct UpstreamResponseSpec: Sendable {
  let status: Int
  let headers: [String: [String]]
  let body: Data
}

private struct CapturedUpstreamRequest: Sendable {
  let method: String
  let url: URL
  let headers: [(String, String)]
  let body: Data
}

private actor RecordingUpstreamClient: UpstreamHTTPClient {
  private var responses: [UpstreamResponseSpec]
  private(set) var requests: [CapturedUpstreamRequest] = []

  init(responses: [UpstreamResponseSpec]) { self.responses = responses }

  func execute(_ request: UpstreamHTTPRequest) async throws -> UpstreamHTTPResponse {
    let collector = S3TestCollector()
    if let body = request.body { try await body.consume { await collector.append($0) } }
    requests.append(
      CapturedUpstreamRequest(
        method: request.method,
        url: request.url,
        headers: request.headers,
        body: await collector.data
      )
    )
    guard !responses.isEmpty else { throw BackendError.unavailable(retryable: false) }
    let response = responses.removeFirst()
    return UpstreamHTTPResponse(
      status: response.status,
      headers: response.headers,
      body: ObjectBodyStream(data: response.body, maximumChunkBytes: 4_096)
    )
  }
}

private actor S3TestCollector {
  private(set) var data = Data()
  func append(_ chunk: Data) { data.append(chunk) }
}

private func s3Context() throws -> RequestContext {
  RequestContext(
    requestID: UUID().uuidString,
    principalID: try #require(PrincipalID(rawValue: "test")),
    deadline: Date().addingTimeInterval(30)
  )
}
