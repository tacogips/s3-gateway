import Foundation

public struct CredentialProviderConfiguration: Codable, Equatable, Sendable {
  public let inboundPath: String
  public let upstreamPath: String
  public let paginationPath: String

  public init(inboundPath: String, upstreamPath: String, paginationPath: String) {
    self.inboundPath = inboundPath
    self.upstreamPath = upstreamPath
    self.paginationPath = paginationPath
  }

  func validate(fileSystem: FileSystemInspecting) throws {
    let paths = [inboundPath, upstreamPath, paginationPath]
    guard Set(paths).count == paths.count else {
      throw ConfigurationError.invalid(field: "credentials", reason: "credential domains must use separate files")
    }
    for path in paths {
      guard path.hasPrefix("/") else {
        throw ConfigurationError.invalid(field: "credentials", reason: "credential paths must be absolute")
      }
      try fileSystem.validateCredentialFile(path: path)
    }
  }
}

public struct PrincipalAuthorization: Codable, Equatable, Sendable {
  public let principalID: String
  public let grants: [AuthorizationGrant]

  public init(principalID: String, grants: [AuthorizationGrant]) {
    self.principalID = principalID
    self.grants = grants
  }
}

public struct AuthorizationGrant: Codable, Equatable, Sendable {
  public let operations: Set<GatewayOperation>
  public let bucket: String
  public let keyPrefix: String?

  public init(operations: Set<GatewayOperation>, bucket: String, keyPrefix: String? = nil) {
    self.operations = operations
    self.bucket = bucket
    self.keyPrefix = keyPrefix
  }
}
