import Crypto
import Foundation
import Testing
@testable import AppCore

@Test func paginationTokensAreAuthenticatedAndScopeBound() async throws {
  let provider = TestPaginationProvider()
  let service = PaginationTokenService(provider: provider, maximumLifetime: 300)
  let scope = AuthorizedScope(
    principalID: try #require(PrincipalID(rawValue: "reader")),
    operation: .listObjectsV2,
    bucket: try #require(BucketName(rawValue: "my-bucket")),
    grantPrefix: "allowed",
    requestedPrefix: "allowed/child"
  )
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let token = try await service.issue(
    backend: .posix,
    scope: scope,
    requestedPrefix: "allowed/child",
    delimiter: "/",
    orderingState: "last-key",
    now: now
  )
  let encryptedPart = try #require(token.split(separator: ".").last)
  let encryptedBytes = try #require(decodeBase64URL(String(encryptedPart)))
  let visibleEnvelope = String(data: encryptedBytes, encoding: .utf8) ?? ""
  #expect(!visibleEnvelope.contains("last-key"))
  #expect(!visibleEnvelope.contains("my-bucket"))
  let payload = try await service.verify(
    token,
    expectedBackend: .posix,
    expectedScope: scope,
    requestedPrefix: "allowed/child",
    delimiter: "/",
    now: now.addingTimeInterval(10)
  )
  #expect(payload.orderingState == "last-key")

  await #expect(throws: PaginationTokenError.scopeMismatch) {
    _ = try await service.verify(
      token,
      expectedBackend: .posix,
      expectedScope: scope,
      requestedPrefix: "other",
      delimiter: "/",
      now: now.addingTimeInterval(10)
    )
  }
}

@Test func paginationTokenTamperingFailsBeforeUse() async throws {
  let provider = TestPaginationProvider()
  let service = PaginationTokenService(provider: provider, maximumLifetime: 300)
  let scope = AuthorizedScope(
    principalID: try #require(PrincipalID(rawValue: "reader")),
    operation: .listObjectsV2,
    bucket: try #require(BucketName(rawValue: "my-bucket")),
    grantPrefix: nil,
    requestedPrefix: ""
  )
  let token = try await service.issue(
    backend: .posix,
    scope: scope,
    requestedPrefix: "",
    delimiter: nil,
    orderingState: "x"
  )
  let tampered = token.dropLast() + (token.last == "A" ? "B" : "A")
  await #expect(throws: (any Error).self) {
    _ = try await service.verify(
      String(tampered),
      expectedBackend: .posix,
      expectedScope: scope,
      requestedPrefix: "",
      delimiter: nil
    )
  }
}

@Test func paginationTokensSurviveRotationOverlapAndExpireOrRetire() async throws {
  let old = PaginationSigningKey(
    keyID: "old-key",
    key: SymmetricKey(data: Data(repeating: 4, count: 32))
  )
  let new = PaginationSigningKey(
    keyID: "new-key",
    key: SymmetricKey(data: Data(repeating: 5, count: 32))
  )
  let provider = RotatingPaginationProvider(active: old)
  let scope = AuthorizedScope(
    principalID: try #require(PrincipalID(rawValue: "reader")),
    operation: .listObjectsV2,
    bucket: try #require(BucketName(rawValue: "my-bucket")),
    grantPrefix: nil,
    requestedPrefix: ""
  )
  let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
  let firstService = PaginationTokenService(
    provider: provider,
    maximumLifetime: 300
  )
  let oldToken = try await firstService.issue(
    backend: .posix,
    scope: scope,
    requestedPrefix: "",
    delimiter: nil,
    orderingState: "old-state",
    now: issuedAt
  )
  await provider.rotate(to: new, retainPrevious: true)
  let restartedService = PaginationTokenService(
    provider: provider,
    maximumLifetime: 300
  )
  let overlapped = try await restartedService.verify(
    oldToken,
    expectedBackend: .posix,
    expectedScope: scope,
    requestedPrefix: "",
    delimiter: nil,
    now: issuedAt.addingTimeInterval(10)
  )
  #expect(overlapped.orderingState == "old-state")
  let newToken = try await restartedService.issue(
    backend: .posix,
    scope: scope,
    requestedPrefix: "",
    delimiter: nil,
    orderingState: "new-state",
    now: issuedAt.addingTimeInterval(10)
  )
  #expect(newToken != oldToken)

  await #expect(throws: PaginationTokenError.expired) {
    _ = try await restartedService.verify(
      oldToken,
      expectedBackend: .posix,
      expectedScope: scope,
      requestedPrefix: "",
      delimiter: nil,
      now: issuedAt.addingTimeInterval(301)
    )
  }
  await provider.rotate(to: new, retainPrevious: false)
  await #expect(throws: PaginationTokenError.malformed) {
    _ = try await restartedService.verify(
      oldToken,
      expectedBackend: .posix,
      expectedScope: scope,
      requestedPrefix: "",
      delimiter: nil,
      now: issuedAt.addingTimeInterval(20)
    )
  }
  await #expect(throws: PaginationTokenError.malformed) {
    _ = try await restartedService.verify(
      String(repeating: "A", count: 16 * 1_024 + 1),
      expectedBackend: .posix,
      expectedScope: scope,
      requestedPrefix: "",
      delimiter: nil,
      now: issuedAt
    )
  }
}

private func decodeBase64URL(_ value: String) -> Data? {
  var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
  return Data(base64Encoded: base64)
}

private struct TestPaginationProvider: PaginationKeyProviding {
  private let signingKey = PaginationSigningKey(
    keyID: "test-key",
    key: SymmetricKey(data: Data(repeating: 9, count: 32))
  )

  func activeKey() async -> PaginationSigningKey { signingKey }

  func key(for keyID: String) async -> PaginationSigningKey? {
    keyID == signingKey.keyID ? signingKey : nil
  }
}

private actor RotatingPaginationProvider: PaginationKeyProviding {
  private var active: PaginationSigningKey
  private var keys: [String: PaginationSigningKey]

  init(active: PaginationSigningKey) {
    self.active = active
    keys = [active.keyID: active]
  }

  func activeKey() -> PaginationSigningKey {
    active
  }

  func key(for keyID: String) -> PaginationSigningKey? {
    keys[keyID]
  }

  func rotate(
    to key: PaginationSigningKey,
    retainPrevious: Bool
  ) {
    active = key
    keys = retainPrevious
      ? keys.merging([key.keyID: key]) { _, replacement in replacement }
      : [key.keyID: key]
  }
}
