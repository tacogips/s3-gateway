import Crypto
import Foundation

public struct PaginationTokenPayload: Codable, Equatable, Sendable {
  public let version: Int
  public let keyID: String
  public let backend: BackendKind
  public let principalID: String
  public let operation: GatewayOperation
  public let bucket: String
  public let grantPrefix: String?
  public let requestedPrefix: String
  public let delimiter: String?
  public let orderingState: String
  public let issuedAt: Date
  public let expiresAt: Date
}

public enum PaginationTokenError: Error, Equatable, Sendable {
  case malformed
  case unauthenticated
  case expired
  case scopeMismatch
}

public struct PaginationTokenService: Sendable {
  private let provider: any PaginationKeyProviding
  private let maximumLifetime: TimeInterval

  public init(provider: any PaginationKeyProviding, maximumLifetime: TimeInterval) {
    self.provider = provider
    self.maximumLifetime = maximumLifetime
  }

  public func issue(
    backend: BackendKind,
    scope: AuthorizedScope,
    requestedPrefix: String,
    delimiter: String?,
    orderingState: String,
    now: Date = Date()
  ) async throws -> String {
    let key = await provider.activeKey()
    let payload = PaginationTokenPayload(
      version: 1,
      keyID: key.keyID,
      backend: backend,
      principalID: scope.principalID.rawValue,
      operation: scope.operation,
      bucket: scope.bucket.rawValue,
      grantPrefix: scope.grantPrefix,
      requestedPrefix: requestedPrefix,
      delimiter: delimiter,
      orderingState: orderingState,
      issuedAt: now,
      expiresAt: now.addingTimeInterval(maximumLifetime)
    )
    let body = try Self.makeEncoder().encode(payload)
    let sealed = try AES.GCM.seal(body, using: key.key)
    guard let combined = sealed.combined else { throw PaginationTokenError.malformed }
    return Self.base64URL(Data(key.keyID.utf8)) + "." + Self.base64URL(combined)
  }

  public func verify(
    _ token: String,
    expectedBackend: BackendKind,
    expectedScope: AuthorizedScope,
    requestedPrefix: String,
    delimiter: String?,
    now: Date = Date()
  ) async throws -> PaginationTokenPayload {
    guard token.utf8.count <= 16 * 1_024 else { throw PaginationTokenError.malformed }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
          let keyIDData = Self.decodeBase64URL(String(parts[0])),
          keyIDData.count <= 128,
          let keyID = String(data: keyIDData, encoding: .utf8),
          !keyID.isEmpty,
          let combined = Self.decodeBase64URL(String(parts[1])),
          combined.count <= 12 * 1_024,
          let key = await provider.key(for: keyID) else {
      throw PaginationTokenError.malformed
    }
    let body: Data
    do {
      body = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key.key)
    } catch {
      throw PaginationTokenError.unauthenticated
    }
    guard let payload = try? Self.makeDecoder().decode(PaginationTokenPayload.self, from: body),
          payload.version == 1,
          payload.keyID == keyID else { throw PaginationTokenError.malformed }
    guard payload.issuedAt <= now,
          payload.expiresAt >= now,
          payload.expiresAt.timeIntervalSince(payload.issuedAt) <= maximumLifetime else {
      throw PaginationTokenError.expired
    }
    guard payload.backend == expectedBackend,
          payload.principalID == expectedScope.principalID.rawValue,
          payload.operation == expectedScope.operation,
          payload.bucket == expectedScope.bucket.rawValue,
          payload.grantPrefix == expectedScope.grantPrefix,
          payload.requestedPrefix == requestedPrefix,
          payload.delimiter == delimiter else {
      throw PaginationTokenError.scopeMismatch
    }
    return payload
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }

  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func decodeBase64URL(_ value: String) -> Data? {
    guard !value.isEmpty,
          value.utf8.allSatisfy({ byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
              (48...57).contains(byte) || byte == 45 || byte == 95
          }),
          value.count % 4 != 1 else { return nil }
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64), base64URL(data) == value else { return nil }
    return data
  }
}
