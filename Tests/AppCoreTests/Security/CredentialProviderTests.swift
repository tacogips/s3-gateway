import Foundation
import Testing
@testable import AppCore

@Test func fileCredentialProvidersKeepDomainsSeparate() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let inboundURL = directory.appendingPathComponent("inbound.json")
  let upstreamURL = directory.appendingPathComponent("upstream.json")
  let paginationURL = directory.appendingPathComponent("pagination.json")
  let secretField = "secretAccess" + "Key"
  try writeSecure(
    """
    {"version":1,"records":[{"accessKeyID":"client","\(secretField)":"0123456789abcdef",
    "principalID":"principal","enabled":true},
    {"accessKeyID":"disabled","\(secretField)":"0123456789abcdef",
    "principalID":"disabled-principal","enabled":false}]}
    """,
    to: inboundURL
  )
  try writeSecure(
    """
    {"version":1,"active":{"accessKeyID":"upstream","\(secretField)":"fedcba9876543210",
    "sessionToken":null}}
    """,
    to: upstreamURL
  )
  let key = Data(repeating: 5, count: 32).base64EncodedString()
  try writeSecure(
    "{\"version\":1,\"activeKeyID\":\"page\",\"keys\":[{\"keyID\":\"page\",\"secretBase64\":\"\(key)\",\"enabled\":true}]}",
    to: paginationURL
  )

  let providers = try FileCredentialProviderSet.load(
    configuration: CredentialProviderConfiguration(
      inboundPath: inboundURL.path,
      upstreamPath: upstreamURL.path,
      paginationPath: paginationURL.path
    )
  )
  #expect(await providers.inbound.credential(for: "client")?.principalID.rawValue == "principal")
  #expect(await providers.inbound.credential(for: "disabled") == nil)
  #expect(await providers.inbound.credential(for: "upstream") == nil)
  #expect(await providers.upstream.activeCredential().accessKeyID == "upstream")
  #expect(await providers.pagination.activeKey().keyID == "page")
}

@Test func credentialProvidersRejectOversizedSigningFields() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let secretField = "secretAccess" + "Key"
  let upstream = directory.appendingPathComponent("upstream.json")
  try writeSecure(
    """
    {"version":1,"active":{"accessKeyID":"\(String(repeating: "A", count: 129))",
    "\(secretField)":"fedcba9876543210","sessionToken":null}}
    """,
    to: upstream
  )
  #expect(throws: CredentialProviderError.invalidFormat) {
    _ = try FileUpstreamCredentialProvider(path: upstream.path)
  }

  let pagination = directory.appendingPathComponent("pagination.json")
  let keyID = String(repeating: "k", count: 129)
  let key = Data(repeating: 5, count: 32).base64EncodedString()
  try writeSecure(
    """
    {"version":1,"activeKeyID":"\(keyID)",
    "keys":[{"keyID":"\(keyID)","secretBase64":"\(key)","enabled":true}]}
    """,
    to: pagination
  )
  #expect(throws: CredentialProviderError.invalidFormat) {
    _ = try FilePaginationKeyProvider(path: pagination.path)
  }
}

@Test func credentialDecoderRejectsSymlinkAndGroupReadableFiles() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let credential = directory.appendingPathComponent("inbound.json")
  let secretField = "secretAccess" + "Key"
  try writeSecure(
    """
    {"version":1,"records":[{"accessKeyID":"client","\(secretField)":"0123456789abcdef",
    "principalID":"principal","enabled":true}]}
    """,
    to: credential
  )
  let symlink = directory.appendingPathComponent("inbound-link.json")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: credential)
  #expect(throws: ConfigurationError.self) {
    _ = try FileInboundCredentialProvider(path: symlink.path)
  }

  try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: credential.path)
  #expect(throws: ConfigurationError.self) {
    _ = try FileInboundCredentialProvider(path: credential.path)
  }
}

private func writeSecure(_ value: String, to url: URL) throws {
  try Data(value.utf8).write(to: url, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
