import Foundation

public struct SigV4Request: Sendable {
  public let method: String
  public let rawPath: String
  public let rawQuery: String
  public let headers: [String: [String]]
  public let payloadHash: String

  public init(
    method: String,
    rawPath: String,
    rawQuery: String = "",
    headers: [String: [String]],
    payloadHash: String
  ) {
    self.method = method
    self.rawPath = rawPath
    self.rawQuery = rawQuery
    self.headers = headers
    self.payloadHash = payloadHash
  }

  func values(for name: String) -> [String] {
    headers.flatMap { key, value in key.caseInsensitiveCompare(name) == .orderedSame ? value : [] }
  }
}

public struct SigV4AuthenticationResult: Sendable {
  public let principalID: PrincipalID
  public let accessKeyID: String
  public let signedAt: Date
}

public enum SigV4Error: Error, Equatable, Sendable {
  case malformed
  case unsupportedAlgorithm
  case unknownCredential
  case invalidScope
  case expired
  case missingSignedHeader
  case signatureMismatch
  case invalidPayloadPolicy
}
