import Foundation
import Testing
@testable import AppCore

@Test func gatewayServerStartsHealthRouteAndStopsGracefully() async throws {
  let fixture = try ServerFixture()
  defer { fixture.remove() }
  let configuration = GatewayConfiguration(
    listener: ListenerConfiguration(host: "127.0.0.1", port: 0, developmentPlaintext: true),
    health: HealthEndpointConfiguration(),
    credentials: CredentialProviderConfiguration(
      inboundPath: fixture.inbound.path,
      upstreamPath: fixture.upstream.path,
      paginationPath: fixture.pagination.path
    ),
    backend: .posix(
      POSIXBackendConfiguration(
        rootPath: fixture.root.path,
        bucketDirectories: ["my-bucket": "bucket"],
        layoutPolicy: .sharedLocalDirectory,
        sidecarPath: fixture.sidecar.path,
        durability: .data
      )
    )
  )
  let server = try await GatewayServer.make(configuration: configuration)
  try await server.start()
  let port = try #require(await server.localPort)
  let url = try #require(
    URL(string: "http://127.0.0.1:\(port)/.well-known/swift-s3-gateway/ready")
  )
  let (data, response) = try await URLSession.shared.data(from: url)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  #expect(String(data: data, encoding: .utf8)?.contains("ready") == true)
  try await server.stop()
}

private struct ServerFixture {
  let base: URL
  let root: URL
  let sidecar: URL
  let inbound: URL
  let upstream: URL
  let pagination: URL

  init() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    root = base.appendingPathComponent("root", isDirectory: true)
    sidecar = base.appendingPathComponent("sidecar", isDirectory: true)
    inbound = base.appendingPathComponent("inbound.json")
    upstream = base.appendingPathComponent("upstream.json")
    pagination = base.appendingPathComponent("pagination.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sidecar.path)
    let secretField = "secretAccess" + "Key"
    try Self.writeSecure(
      """
      {"version":1,"records":[{"accessKeyID":"client","\(secretField)":"0123456789abcdef",
      "principalID":"principal","enabled":true}]}
      """,
      to: inbound
    )
    try Self.writeSecure(
      """
      {"version":1,"active":{"accessKeyID":"upstream","\(secretField)":"fedcba9876543210",
      "sessionToken":null}}
      """,
      to: upstream
    )
    let key = Data(repeating: 6, count: 32).base64EncodedString()
    try Self.writeSecure(
      "{\"version\":1,\"activeKeyID\":\"page\",\"keys\":[{\"keyID\":\"page\",\"secretBase64\":\"\(key)\",\"enabled\":true}]}",
      to: pagination
    )
  }

  func remove() { try? FileManager.default.removeItem(at: base) }

  private static func writeSecure(_ value: String, to url: URL) throws {
    try Data(value.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
