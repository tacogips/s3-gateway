import Crypto
import Foundation

public struct InboundVerificationCredential: Sendable {
  public let accessKeyID: String
  public let principalID: PrincipalID
  let signingSecret: SymmetricKey
}

public struct UpstreamSigningCredential: Sendable {
  public let accessKeyID: String
  public let sessionToken: String?
  let signingSecret: SymmetricKey
}

public struct PaginationSigningKey: Sendable {
  public let keyID: String
  let key: SymmetricKey
}

public protocol InboundCredentialProviding: Sendable {
  func credential(for accessKeyID: String) async -> InboundVerificationCredential?
}

public protocol UpstreamCredentialProviding: Sendable {
  func activeCredential() async -> UpstreamSigningCredential
}

public protocol PaginationKeyProviding: Sendable {
  func activeKey() async -> PaginationSigningKey
  func key(for keyID: String) async -> PaginationSigningKey?
}

public enum CredentialProviderError: Error, Equatable, Sendable {
  case invalidFormat
  case duplicateIdentifier
  case missingActiveKey
  case recordLimitExceeded
}

struct VersionedInboundCredentialFile: Decodable {
  let version: Int
  let records: [InboundCredentialRecord]
}

struct InboundCredentialRecord: Decodable {
  let accessKeyID: String
  let secretAccessKey: String
  let principalID: String
  let enabled: Bool
}

struct VersionedUpstreamCredentialFile: Decodable {
  let version: Int
  let active: UpstreamCredentialRecord
}

struct UpstreamCredentialRecord: Decodable {
  let accessKeyID: String
  let secretAccessKey: String
  let sessionToken: String?
}

struct VersionedPaginationKeyFile: Decodable {
  let version: Int
  let activeKeyID: String
  let keys: [PaginationKeyRecord]
}

struct PaginationKeyRecord: Decodable {
  let keyID: String
  let secretBase64: String
  let enabled: Bool
}
