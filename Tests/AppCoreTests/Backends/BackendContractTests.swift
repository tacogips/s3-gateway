import Crypto
import Foundation
import Testing
@testable import AppCore

@Test func posixBackendPassesSharedStageOneContract() async throws {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let root = base.appendingPathComponent("root", isDirectory: true)
  let sidecars = base.appendingPathComponent("sidecars", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sidecars.path)
  defer { try? FileManager.default.removeItem(at: base) }

  let backend = try POSIXBackend(
    configuration: POSIXBackendConfiguration(
      rootPath: root.path,
      bucketDirectories: ["contract-bucket": "managed"],
      layoutPolicy: .managedPrivateLayout,
      sidecarPath: sidecars.path,
      durability: .data
    ),
    maximumChunkBytes: 4_096
  )
  try await runSharedStageOneBackendContract(backend)
}

@Test func s3BackendPassesSharedStageOneContract() async throws {
  let upstream = ContractS3Upstream()
  let backend = S3Backend(
    configuration: UpstreamS3Configuration(
      endpoint: try #require(URL(string: "https://contract.example.test")),
      region: "us-east-1",
      addressingStyle: .path,
      bucketMappings: ["contract-bucket": "remote-contract"]
    ),
    credentials: ContractS3Credentials(),
    client: upstream,
    maximumChunkBytes: 4_096
  )
  try await runSharedStageOneBackendContract(backend)
}

private func runSharedStageOneBackendContract(
  _ backend: any ObjectStoreBackend
) async throws {
  let bucket = try #require(BucketName(rawValue: "contract-bucket"))
  let key = try ObjectKey(validating: "nested/object.bin")
  let body = Data((0..<32_768).map { UInt8($0 % 251) })
  let checksum = Data(SHA256.hash(data: body)).base64EncodedString()
  let context = RequestContext(
    requestID: UUID().uuidString,
    principalID: try #require(PrincipalID(rawValue: "contract")),
    deadline: Date().addingTimeInterval(30)
  )

  try await backend.readinessCheck(deadline: Date().addingTimeInterval(30))
  let put = try await backend.putObject(
    PutObjectRequest(
      bucket: bucket,
      key: key,
      body: ObjectBodyStream(data: body, maximumChunkBytes: 4_096),
      knownContentLength: Int64(body.count),
      contentType: "application/octet-stream",
      userMetadata: ["suite": "shared-contract"],
      expectedChecksums: [
        ObjectChecksum(algorithm: .sha256, base64Value: checksum)
      ],
      conditions: WriteConditions(requireAbsent: true)
    ),
    context: context
  )
  #expect(put.metadata.contentLength == Int64(body.count))
  #expect(put.metadata.userMetadata["suite"] == "shared-contract")

  let head = try await backend.headObject(
    HeadObjectRequest(
      bucket: bucket,
      key: key,
      conditions: ReadConditions(ifMatch: [put.metadata.entityTag])
    ),
    context: context
  )
  #expect(head.entityTag == put.metadata.entityTag)
  #expect(head.contentLength == Int64(body.count))

  let full = try await backend.getObject(
    GetObjectRequest(bucket: bucket, key: key),
    context: context
  )
  #expect(try await collectContractBody(full.body) == body)

  let expectedRange = try ByteRange(lowerBound: 1_024, upperBound: 2_047)
  let range = try await backend.getObject(
    GetObjectRequest(
      bucket: bucket,
      key: key,
      range: expectedRange
    ),
    context: context
  )
  #expect(range.servedRange == expectedRange)
  #expect(try await collectContractBody(range.body) == body.subdata(in: 1_024..<2_048))

  let listed = try await backend.listObjectsV2(
    ListObjectsV2Request(
      bucket: bucket,
      prefix: "nested/",
      maximumKeys: 1
    ),
    context: context
  )
  #expect(listed.objects.map(\.key) == [key])

  try await backend.deleteObject(
    DeleteObjectRequest(
      bucket: bucket,
      key: key,
      conditions: WriteConditions(ifMatch: put.metadata.entityTag)
    ),
    context: context
  )
  await #expect(throws: BackendError.notFound) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: key),
      context: context
    )
  }
}

private func collectContractBody(_ body: ObjectBodyStream) async throws -> Data {
  let collector = ContractBodyCollector()
  try await body.consume { await collector.append($0) }
  return await collector.data
}

private actor ContractBodyCollector {
  private(set) var data = Data()

  func append(_ chunk: Data) {
    data.append(chunk)
  }
}

private actor ContractS3Upstream: UpstreamHTTPClient {
  private struct StoredObject: Sendable {
    let body: Data
    let contentType: String
    let metadata: [String: String]
    let entityTag: String
    let checksum: String
  }

  private var objects: [String: StoredObject] = [:]

  func execute(_ request: UpstreamHTTPRequest) async throws -> UpstreamHTTPResponse {
    let path = request.url.path
    if request.method == "HEAD", path == "/remote-contract" {
      return response(status: 200, headers: [("content-length", "0")])
    }
    if request.method == "PUT" {
      if header(request, "if-none-match") == "*", objects[path] != nil {
        return response(status: 412)
      }
      let collector = ContractBodyCollector()
      if let body = request.body {
        try await body.consume { await collector.append($0) }
      }
      let data = await collector.data
      let entityTag = "\"\(Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())\""
      let checksum = Data(SHA256.hash(data: data)).base64EncodedString()
      let metadata = request.headers.reduce(into: [String: String]()) { result, field in
        guard field.0.lowercased().hasPrefix("x-amz-meta-") else { return }
        result[String(field.0.lowercased().dropFirst(11))] = field.1
      }
      objects[path] = StoredObject(
        body: data,
        contentType: header(request, "content-type") ?? "application/octet-stream",
        metadata: metadata,
        entityTag: entityTag,
        checksum: checksum
      )
      return response(
        status: 200,
        headers: [
          ("etag", entityTag),
          ("x-amz-checksum-sha256", checksum),
          ("content-length", "0")
        ]
      )
    }
    if request.method == "GET", request.url.query?.contains("list-type=2") == true {
      return listResponse()
    }
    guard let object = objects[path] else {
      return response(status: 404)
    }
    if let match = header(request, "if-match"), match != object.entityTag {
      return response(status: 412)
    }
    if request.method == "DELETE" {
      if let match = header(request, "if-match"), match != object.entityTag {
        return response(status: 412)
      }
      objects[path] = nil
      return response(status: 204, headers: [("content-length", "0")])
    }
    if request.method == "HEAD" {
      return response(status: 200, headers: objectHeaders(object))
    }
    if request.method == "GET" {
      if let range = header(request, "range"), range == "bytes=1024-2047" {
        let selected = object.body.subdata(in: 1_024..<2_048)
        return response(
          status: 206,
          headers: objectHeaders(
            object,
            contentLength: selected.count,
            extra: [("content-range", "bytes 1024-2047/\(object.body.count)")]
          ),
          body: selected
        )
      }
      return response(
        status: 200,
        headers: objectHeaders(object),
        body: object.body
      )
    }
    return response(status: 400)
  }

  private func header(_ request: UpstreamHTTPRequest, _ name: String) -> String? {
    request.headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
  }

  private func objectHeaders(
    _ object: StoredObject,
    contentLength: Int? = nil,
    extra: [(String, String)] = []
  ) -> [(String, String)] {
    [
      ("content-length", String(contentLength ?? object.body.count)),
      ("content-type", object.contentType),
      ("etag", object.entityTag),
      ("last-modified", "Wed, 23 Jul 2026 00:00:00 GMT"),
      ("x-amz-checksum-sha256", object.checksum)
    ] + object.metadata.map { ("x-amz-meta-\($0.key)", $0.value) } + extra
  }

  private func listResponse() -> UpstreamHTTPResponse {
    let contents = objects.sorted { $0.key < $1.key }.map { path, object in
      let key = path.replacingOccurrences(of: "/remote-contract/", with: "")
      return """
      <Contents><Key>\(key)</Key><LastModified>2026-07-23T00:00:00Z</LastModified>
      <ETag>\(object.entityTag)</ETag><Size>\(object.body.count)</Size></Contents>
      """
    }.joined()
    let data = Data(
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult>\(contents)</ListBucketResult>".utf8
    )
    return response(
      status: 200,
      headers: [("content-length", String(data.count))],
      body: data
    )
  }

  private func response(
    status: Int,
    headers: [(String, String)] = [],
    body: Data = Data()
  ) -> UpstreamHTTPResponse {
    var grouped: [String: [String]] = [:]
    for (name, value) in headers {
      grouped[name, default: []].append(value)
    }
    return UpstreamHTTPResponse(
      status: status,
      headers: grouped,
      body: ObjectBodyStream(data: body, maximumChunkBytes: 4_096)
    )
  }
}

private struct ContractS3Credentials: UpstreamCredentialProviding {
  func activeCredential() async -> UpstreamSigningCredential {
    UpstreamSigningCredential(
      accessKeyID: "CONTRACTKEY",
      sessionToken: nil,
      signingSecret: SymmetricKey(data: Data("contract-secret-value".utf8))
    )
  }
}
