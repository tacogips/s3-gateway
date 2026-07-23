import Crypto
import Darwin
import Foundation
import Testing
@testable import AppCore

@Test func nioTransportStreamsRequestAndResponseOnLoopback() async throws {
  let limits = GatewayLimits(
    maximumHeaderBytes: 8_192,
    maximumXMLBytes: 8_192,
    maximumObjectBytes: 1_024 * 1_024,
    maximumChunkBytes: 64 * 1_024,
    maximumInFlightBytes: 128 * 1_024,
    maximumConcurrentRequests: 8,
    requestTimeoutSeconds: 10
  )
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      developmentPlaintext: true
    ),
    limits: limits
  )
  let received = TransportDataCollector()
  try await transport.start { request in
    do {
      try await request.body.consume { await received.append($0) }
      return HTTPTransportResponse(status: 200, data: Data("response".utf8))
    } catch {
      return HTTPTransportResponse(status: 500)
    }
  }
  let port = try #require(await transport.localPort)
  let url = try #require(URL(string: "http://127.0.0.1:\(port)/bucket/key?x=1"))
  var request = URLRequest(url: url)
  request.httpMethod = "PUT"
  request.httpBody = Data("request-body".utf8)
  request.setValue("100-continue", forHTTPHeaderField: "Expect")
  let (data, response) = try await URLSession.shared.data(for: request)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  #expect(data == Data("response".utf8))
  #expect(await received.data == Data("request-body".utf8))
  try await transport.stop()
}

@Test func nioTransportPreservesRawTargetAndRejectsAmbiguousFraming() async throws {
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      developmentPlaintext: true
    ),
    limits: GatewayLimits(
      maximumHeaderBytes: 8_192,
      maximumXMLBytes: 8_192,
      maximumObjectBytes: 1_024 * 1_024,
      maximumChunkBytes: 4_096,
      maximumInFlightBytes: 4_096,
      maximumConcurrentRequests: 2,
      requestTimeoutSeconds: 10
    )
  )
  let recorder = RawTransportRequestRecorder()
  try await transport.start { request in
    await recorder.record(request)
    return HTTPTransportResponse(status: 204)
  }
  let port = try #require(await transport.localPort)
  let rawTarget = "/bucket/a%2fb//c?z=%2f&a=1&a=%31"
  let validOutput = try sendRawHTTPRequest(
    port: port,
    request:
      "GET \(rawTarget) HTTP/1.1\r\n" +
      "Host: Example.TEST:\(port)\r\n" +
      "X-Signed: alpha\t beta\r\n" +
      "Connection: close\r\n\r\n"
  )
  let validText = String(data: validOutput, encoding: .utf8) ?? ""
  if !validText.contains("HTTP/1.1 204") {
    Issue.record("Unexpected raw HTTP response: \(validText)")
  }
  let observed = try #require(await recorder.requests.first)
  #expect(observed.method == "GET")
  #expect(observed.rawPath == "/bucket/a%2fb//c")
  #expect(observed.rawQuery == "z=%2f&a=1&a=%31")
  #expect(observed.host == "Example.TEST:\(port)")
  #expect(observed.signedHeader == "alpha\t beta")

  let invalidOutput = try sendRawHTTPRequest(
    port: port,
    request:
      "PUT /bucket/key HTTP/1.1\r\n" +
      "Host: localhost\r\n" +
      "Content-Length: 4\r\n" +
      "Transfer-Encoding: chunked\r\n" +
      "Connection: close\r\n\r\n" +
      "0\r\n\r\n"
  )
  #expect(
    String(data: invalidOutput, encoding: .utf8)?
      .contains("400 Bad Request") == true
  )
  #expect(await recorder.requests.count == 1)
  try await transport.stop()
}

@Test func nioTransportDisconnectCancelsDownstreamBodyConsumption() async throws {
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      developmentPlaintext: true
    ),
    limits: .defaults
  )
  let completion = TransportBodyCompletionRecorder()
  try await transport.start { request in
    await completion.markStarted()
    do {
      try await request.body.consume { _ in }
      await completion.record(completedNormally: true)
    } catch {
      await completion.record(completedNormally: false)
    }
    return HTTPTransportResponse(status: 500)
  }
  let port = try #require(await transport.localPort)
  let descriptor = try openRawHTTPRequest(
    port: port,
    request:
      "PUT /bucket/interrupted HTTP/1.1\r\n" +
      "Host: localhost\r\n" +
      "Content-Length: 1048576\r\n" +
      "Connection: close\r\n\r\n" +
      String(repeating: "x", count: 4_096)
  )
  await completion.waitUntilStarted()
  close(descriptor)
  #expect(await completion.waitForResult() == false)
  try await transport.stop()
}

@Test func nioTransportCompletesNativeTLSHandshake() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let key = directory.appendingPathComponent("key.pem")
  let certificate = directory.appendingPathComponent("certificate.pem")
  _ = try runProcess(
    executable: "/usr/bin/openssl",
    arguments: [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", key.path, "-out", certificate.path, "-days", "1", "-subj", "/CN=localhost"
    ]
  )
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      tls: TLSConfiguration(certificateChainPath: certificate.path, privateKeyPath: key.path)
    ),
    limits: .defaults
  )
  try await transport.start { _ in HTTPTransportResponse(status: 200, data: Data("tls-ok".utf8)) }
  let port = try #require(await transport.localPort)
  await #expect(throws: (any Error).self) {
    _ = try await Task.detached {
      try runProcess(
        executable: "/usr/bin/openssl",
        arguments: ["s_client", "-tls1", "-connect", "127.0.0.1:\(port)", "-servername", "localhost", "-quiet"],
        input: Data("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
      )
    }.value
  }
  let output = try await Task.detached {
    try runProcess(
      executable: "/usr/bin/openssl",
      arguments: ["s_client", "-tls1_2", "-connect", "127.0.0.1:\(port)", "-servername", "localhost", "-quiet"],
      input: Data("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
    )
  }.value
  #expect(String(data: output, encoding: .utf8)?.contains("tls-ok") == true)
  try await transport.stop()
}

@Test func nioTransportRejectsInvalidTLSMaterial() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let key = directory.appendingPathComponent("key.pem")
  let certificate = directory.appendingPathComponent("certificate.pem")
  try Data("not a private key".utf8).write(to: key)
  try Data("not a certificate".utf8).write(to: certificate)
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      tls: TLSConfiguration(certificateChainPath: certificate.path, privateKeyPath: key.path)
    ),
    limits: .defaults
  )
  await #expect(throws: (any Error).self) {
    try await transport.start { _ in HTTPTransportResponse(status: 200) }
  }
  try await transport.stop()
}

@Test func nioTransportActivatesCertificateRotationOnControlledRestart() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let key = directory.appendingPathComponent("key.pem")
  let certificate = directory.appendingPathComponent("certificate.pem")

  func generateCertificate(commonName: String) throws -> Data {
    _ = try runProcess(
      executable: "/usr/bin/openssl",
      arguments: [
        "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", key.path, "-out", certificate.path, "-days", "1",
        "-subj", "/CN=\(commonName)"
      ]
    )
    return try runProcess(
      executable: "/usr/bin/openssl",
      arguments: ["x509", "-in", certificate.path, "-noout", "-fingerprint", "-sha256"]
    )
  }

  let firstFingerprint = try generateCertificate(commonName: "first.local")
  let listener = ListenerConfiguration(
    host: "127.0.0.1",
    port: 0,
    tls: TLSConfiguration(certificateChainPath: certificate.path, privateKeyPath: key.path)
  )
  let firstTransport = NIOHTTPTransport(configuration: listener, limits: .defaults)
  try await firstTransport.start { _ in HTTPTransportResponse(status: 200, data: Data("first".utf8)) }
  let firstPort = try #require(await firstTransport.localPort)
  let firstResponse = try await tlsRequest(port: firstPort, serverName: "first.local")
  #expect(String(data: firstResponse, encoding: .utf8)?.contains("first") == true)
  try await firstTransport.stop()

  let secondFingerprint = try generateCertificate(commonName: "second.local")
  #expect(secondFingerprint != firstFingerprint)
  let secondTransport = NIOHTTPTransport(configuration: listener, limits: .defaults)
  try await secondTransport.start { _ in HTTPTransportResponse(status: 200, data: Data("second".utf8)) }
  let secondPort = try #require(await secondTransport.localPort)
  let secondResponse = try await tlsRequest(port: secondPort, serverName: "second.local")
  #expect(String(data: secondResponse, encoding: .utf8)?.contains("second") == true)
  try await secondTransport.stop()
}

@Test func upstreamNIOClientValidatesConfiguredPrivateCAAndStreamsResponse() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let key = directory.appendingPathComponent("key.pem")
  let certificate = directory.appendingPathComponent("certificate.pem")
  _ = try runProcess(
    executable: "/usr/bin/openssl",
    arguments: [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", key.path, "-out", certificate.path, "-days", "1",
      "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"
    ]
  )
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      tls: TLSConfiguration(certificateChainPath: certificate.path, privateKeyPath: key.path)
    ),
    limits: .defaults
  )
  try await transport.start { request in
    switch request.rawPath {
    case "/upstream-check":
      return HTTPTransportResponse(status: 200, data: Data("trusted-response".utf8))
    case "/slow-upstream":
      return HTTPTransportResponse(status: 200, data: Data(repeating: 17, count: 128 * 1_024))
    case "/delayed":
      try? await Task.sleep(for: .milliseconds(250))
      return HTTPTransportResponse(status: 200, data: Data("late".utf8))
    default:
      return HTTPTransportResponse(status: 404)
    }
  }
  let port = try #require(await transport.localPort)
  let client = try NIOUpstreamHTTPClient(
    maximumChunkBytes: 4_096,
    maximumInFlightBytes: 4_096,
    maximumHeaderBytes: 8_192,
    requestTimeoutSeconds: 10,
    trustedCAPath: certificate.path
  )
  let response = try await client.execute(
    UpstreamHTTPRequest(
      method: "GET",
      url: try #require(URL(string: "https://localhost:\(port)/upstream-check")),
      headers: [],
      body: nil
    )
  )
  #expect(response.status == 200)
  let received = TransportDataCollector()
  try await response.body.consume { await received.append($0) }
  #expect(await received.data == Data("trusted-response".utf8))
  let slowResponse = try await client.execute(
    UpstreamHTTPRequest(
      method: "GET",
      url: try #require(URL(string: "https://localhost:\(port)/slow-upstream")),
      headers: [],
      body: nil
    )
  )
  let slowReceived = TransportDataCollector()
  try await slowResponse.body.consume { chunk in
    try await Task.sleep(for: .milliseconds(2))
    await slowReceived.append(chunk)
  }
  #expect(await slowReceived.data == Data(repeating: 17, count: 128 * 1_024))
  await #expect(throws: BackendError.deadlineExceeded) {
    _ = try await client.execute(
      UpstreamHTTPRequest(
        method: "GET",
        url: try #require(URL(string: "https://localhost:\(port)/delayed")),
        headers: [],
        body: nil,
        deadline: Date().addingTimeInterval(0.05)
      )
    )
  }
  await #expect(throws: (any Error).self) {
    _ = try await client.execute(
      UpstreamHTTPRequest(
        method: "GET",
        url: try #require(URL(string: "https://127.0.0.1:\(port)/wrong-host")),
        headers: [],
        body: nil
      )
    )
  }
  try await transport.stop()
}

@Test func nioTransportAppliesBackpressureToSlowRequestConsumers() async throws {
  let limits = GatewayLimits(
    maximumHeaderBytes: 8_192,
    maximumXMLBytes: 8_192,
    maximumObjectBytes: 1_024 * 1_024,
    maximumChunkBytes: 1_024,
    maximumInFlightBytes: 1_024,
    maximumConcurrentRequests: 2,
    requestTimeoutSeconds: 10
  )
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      developmentPlaintext: true
    ),
    limits: limits
  )
  let received = TransportDataCollector()
  try await transport.start { request in
    do {
      try await request.body.consume { chunk in
        try await Task.sleep(for: .milliseconds(2))
        await received.append(chunk)
      }
      return HTTPTransportResponse(status: 200)
    } catch {
      return HTTPTransportResponse(status: 500)
    }
  }
  let port = try #require(await transport.localPort)
  let url = try #require(URL(string: "http://127.0.0.1:\(port)/slow-consumer"))
  let payload = Data(repeating: 42, count: 256 * 1_024)
  var request = URLRequest(url: url)
  request.httpMethod = "PUT"
  request.httpBody = payload
  let (_, response) = try await URLSession.shared.data(for: request)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  #expect(await received.data == payload)
  try await transport.stop()
}

@Test func s3BackendCompletesStageOneOperationsAgainstControlledTLSEndpoint() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let staging = directory.appendingPathComponent("staging", isDirectory: true)
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
  defer { try? FileManager.default.removeItem(at: directory) }
  let keyFile = directory.appendingPathComponent("key.pem")
  let certificate = directory.appendingPathComponent("certificate.pem")
  _ = try runProcess(
    executable: "/usr/bin/openssl",
    arguments: [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes",
      "-keyout", keyFile.path, "-out", certificate.path, "-days", "1",
      "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost"
    ]
  )
  let recorder = ControlledS3Recorder()
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      tls: TLSConfiguration(
        certificateChainPath: certificate.path,
        privateKeyPath: keyFile.path
      )
    ),
    limits: .defaults
  )
  try await transport.start { request in
    do {
      return try await recorder.response(for: request)
    } catch {
      return HTTPTransportResponse(
        status: 500,
        headers: [("content-length", "0")]
      )
    }
  }
  let port = try #require(await transport.localPort)
  let backend = try S3Backend(
    configuration: UpstreamS3Configuration(
      endpoint: try #require(URL(string: "https://localhost:\(port)")),
      region: "us-east-1",
      addressingStyle: .path,
      bucketMappings: ["my-bucket": "remote-bucket"],
      stagingDirectory: staging.path,
      trustedCAPath: certificate.path
    ),
    credentials: ControlledS3Credentials(),
    maximumChunkBytes: 4_096,
    maximumInFlightBytes: 16 * 1_024,
    maximumHeaderBytes: 8_192,
    maximumXMLBytes: 64 * 1_024,
    requestTimeoutSeconds: 10
  )
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "nested/file.txt")
  let context = try controlledS3Context()

  try await backend.readinessCheck(deadline: Date().addingTimeInterval(30))
  let uploaded = Data(repeating: 23, count: 96 * 1_024)
  let put = try await backend.putObject(
    PutObjectRequest(
      bucket: bucket,
      key: key,
      body: ObjectBodyStream(data: uploaded, maximumChunkBytes: 4_096),
      knownContentLength: Int64(uploaded.count),
      contentType: "application/octet-stream",
      userMetadata: ["origin": "network-test"]
    ),
    context: context
  )
  #expect(put.metadata.contentLength == Int64(uploaded.count))

  let head = try await backend.headObject(
    HeadObjectRequest(bucket: bucket, key: key),
    context: context
  )
  #expect(head.contentLength == Int64(uploaded.count))
  #expect(head.userMetadata["origin"] == "network-test")

  let get = try await backend.getObject(
    GetObjectRequest(bucket: bucket, key: key),
    context: context
  )
  let downloaded = TransportDataCollector()
  try await get.body.consume { await downloaded.append($0) }
  #expect(await downloaded.data == uploaded)

  let listed = try await backend.listObjectsV2(
    ListObjectsV2Request(bucket: bucket, prefix: "nested/"),
    context: context
  )
  #expect(listed.objects.map(\.key.rawValue) == [key.rawValue])

  try await backend.deleteObject(
    DeleteObjectRequest(bucket: bucket, key: key),
    context: context
  )
  let requests = await recorder.requests
  #expect(requests.map(\.method) == ["HEAD", "PUT", "HEAD", "GET", "GET", "DELETE"])
  #expect(requests.allSatisfy {
    $0.headers.contains { name, value in
      name == "authorization" && value.hasPrefix("AWS4-HMAC-SHA256")
    }
  })
  #expect(!requests.flatMap(\.headers).contains {
    $0.1.contains("controlled-upstream-secret")
  })
  try await transport.stop()
}

private actor TransportDataCollector {
  private(set) var data = Data()

  func append(_ chunk: Data) { data.append(chunk) }
}

private actor ControlledS3Recorder {
  struct Request: Sendable {
    let method: String
    let headers: [(String, String)]
  }

  private(set) var requests: [Request] = []
  private var object = Data()
  private var contentType = "application/octet-stream"
  private var userMetadata: [String: String] = [:]

  func response(for request: HTTPTransportRequest) async throws -> HTTPTransportResponse {
    let collector = TransportDataCollector()
    try await request.body.consume { await collector.append($0) }
    requests.append(
      Request(
        method: request.method,
        headers: request.headers.flatMap { name, values in
          values.map { (name.lowercased(), $0) }
        }
      )
    )
    if request.method == "HEAD", request.rawPath == "/remote-bucket" {
      return HTTPTransportResponse(status: 200, headers: [("content-length", "0")])
    }
    if request.method == "PUT" {
      object = await collector.data
      contentType = request.header("content-type").first ?? "application/octet-stream"
      userMetadata = request.headers.reduce(into: [:]) { result, field in
        guard field.key.lowercased().hasPrefix("x-amz-meta-"),
              let value = field.value.first else { return }
        result[String(field.key.lowercased().dropFirst(11))] = value
      }
      return HTTPTransportResponse(
        status: 200,
        headers: [("etag", "\"controlled\""), ("content-length", "0")]
      )
    }
    if request.method == "HEAD" {
      return HTTPTransportResponse(status: 200, headers: objectHeaders())
    }
    if request.method == "GET", request.rawQuery.contains("list-type=2") {
      let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult><Contents><Key>nested/file.txt</Key>
      <LastModified>2026-07-23T00:00:00Z</LastModified>
      <ETag>"controlled"</ETag><Size>\(object.count)</Size></Contents>
      </ListBucketResult>
      """
      let data = Data(xml.utf8)
      return HTTPTransportResponse(
        status: 200,
        headers: [("content-length", String(data.count))],
        data: data
      )
    }
    if request.method == "GET" {
      return HTTPTransportResponse(
        status: 200,
        headers: objectHeaders(),
        body: ObjectBodyStream(data: object, maximumChunkBytes: 4_096)
      )
    }
    if request.method == "DELETE" {
      object = Data()
      return HTTPTransportResponse(status: 204, headers: [("content-length", "0")])
    }
    return HTTPTransportResponse(status: 404, headers: [("content-length", "0")])
  }

  private func objectHeaders() -> [(String, String)] {
    [
      ("content-length", String(object.count)),
      ("content-type", contentType),
      ("etag", "\"controlled\""),
      ("last-modified", "Wed, 23 Jul 2026 00:00:00 GMT")
    ] + userMetadata.map { ("x-amz-meta-\($0.key)", $0.value) }
  }
}

private struct ControlledS3Credentials: UpstreamCredentialProviding {
  func activeCredential() async -> UpstreamSigningCredential {
    UpstreamSigningCredential(
      accessKeyID: "CONTROLLEDKEY",
      sessionToken: nil,
      signingSecret: SymmetricKey(data: Data("controlled-upstream-secret".utf8))
    )
  }
}

private func controlledS3Context() throws -> RequestContext {
  RequestContext(
    requestID: UUID().uuidString,
    principalID: try #require(PrincipalID(rawValue: "network-test")),
    deadline: Date().addingTimeInterval(30)
  )
}

private func runProcess(executable: String, arguments: [String], input: Data? = nil) throws -> Data {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let output = Pipe()
  let errors = Pipe()
  process.standardOutput = output
  process.standardError = errors
  if let input {
    let standardInput = Pipe()
    process.standardInput = standardInput
    try process.run()
    try standardInput.fileHandleForWriting.write(contentsOf: input)
    try standardInput.fileHandleForWriting.close()
  } else {
    try process.run()
  }
  let data = try output.fileHandleForReading.readToEnd() ?? Data()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else {
    let errorData = try errors.fileHandleForReading.readToEnd() ?? Data()
    throw ProcessTestError.failed(String(data: errorData, encoding: .utf8) ?? "non-UTF-8 process error")
  }
  return data
}

private func tlsRequest(port: Int, serverName: String) async throws -> Data {
  try await Task.detached {
    try runProcess(
      executable: "/usr/bin/openssl",
      arguments: [
        "s_client", "-tls1_2", "-connect", "127.0.0.1:\(port)",
        "-servername", serverName, "-quiet"
      ],
      input: Data("GET / HTTP/1.1\r\nHost: \(serverName)\r\nConnection: close\r\n\r\n".utf8)
    )
  }.value
}

private enum ProcessTestError: Error {
  case failed(String)
}

private func sendRawHTTPRequest(
  port: Int,
  request: String,
  readResponse: Bool = true
) throws -> Data {
  let descriptor = try openRawHTTPRequest(port: port, request: request)
  defer { close(descriptor) }
  guard readResponse else { return Data() }
  var result = Data()
  var buffer = [UInt8](repeating: 0, count: 4_096)
  while true {
    let count = Darwin.read(descriptor, &buffer, buffer.count)
    guard count >= 0 else {
      throw ProcessTestError.failed("read failed")
    }
    if count == 0 { break }
    result.append(contentsOf: buffer.prefix(count))
  }
  return result
}

private func openRawHTTPRequest(
  port: Int,
  request: String
) throws -> Int32 {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    throw ProcessTestError.failed("socket failed")
  }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(port).bigEndian
  guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
    close(descriptor)
    throw ProcessTestError.failed("inet_pton failed")
  }
  let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(
        descriptor,
        $0,
        socklen_t(MemoryLayout<sockaddr_in>.size)
      )
    }
  }
  guard connected == 0 else {
    close(descriptor)
    throw ProcessTestError.failed("connect failed")
  }
  let bytes = Data(request.utf8)
  try bytes.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else { return }
    var offset = 0
    while offset < rawBuffer.count {
      let written = Darwin.write(
        descriptor,
        baseAddress.advanced(by: offset),
        rawBuffer.count - offset
      )
      guard written > 0 else {
        close(descriptor)
        throw ProcessTestError.failed("write failed")
      }
      offset += written
    }
  }
  return descriptor
}

private struct RawObservedTransportRequest: Sendable {
  let method: String
  let rawPath: String
  let rawQuery: String
  let host: String?
  let signedHeader: String?
}

private actor RawTransportRequestRecorder {
  private(set) var requests: [RawObservedTransportRequest] = []

  func record(_ request: HTTPTransportRequest) {
    requests.append(
      RawObservedTransportRequest(
        method: request.method,
        rawPath: request.rawPath,
        rawQuery: request.rawQuery,
        host: request.header("host").first,
        signedHeader: request.header("x-signed").first
      )
    )
  }
}

private actor TransportBodyCompletionRecorder {
  private(set) var completedNormally: Bool?
  private var started = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var resultWaiters: [CheckedContinuation<Bool, Never>] = []

  func markStarted() {
    started = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  func record(completedNormally: Bool) {
    self.completedNormally = completedNormally
    let waiters = resultWaiters
    resultWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: completedNormally)
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

  func waitForResult() async -> Bool {
    if let completedNormally {
      return completedNormally
    }
    return await withCheckedContinuation {
      resultWaiters.append($0)
    }
  }
}
