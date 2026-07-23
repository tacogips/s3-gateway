import Foundation

public struct AuthorizationRequest: Sendable {
  public let principalID: PrincipalID
  public let operation: GatewayOperation
  public let bucket: BucketName
  public let key: ObjectKey?
  public let listPrefix: String?

  public init(
    principalID: PrincipalID,
    operation: GatewayOperation,
    bucket: BucketName,
    key: ObjectKey? = nil,
    listPrefix: String? = nil
  ) {
    self.principalID = principalID
    self.operation = operation
    self.bucket = bucket
    self.key = key
    self.listPrefix = listPrefix
  }
}

public struct AuthorizedScope: Equatable, Sendable {
  public let principalID: PrincipalID
  public let operation: GatewayOperation
  public let bucket: BucketName
  public let grantPrefix: String?
  public let requestedPrefix: String?
}

public struct AuthorizationPolicy: Sendable {
  private let policies: [String: [AuthorizationGrant]]

  public init(principals: [PrincipalAuthorization]) throws {
    guard principals.count <= 10_000,
          principals.reduce(0, { $0 + $1.grants.count }) <= 100_000 else {
      throw ConfigurationError.invalid(field: "authorization", reason: "contains too many grants")
    }
    var result: [String: [AuthorizationGrant]] = [:]
    for principal in principals {
      guard PrincipalID(rawValue: principal.principalID) != nil,
            result[principal.principalID] == nil,
            principal.grants.allSatisfy({ grant in
              BucketName(rawValue: grant.bucket) != nil &&
                !grant.operations.isEmpty &&
                (grant.keyPrefix.map({ !$0.isEmpty && ObjectKey(rawValue: $0) != nil }) ?? true)
            }) else {
        throw ConfigurationError.invalid(field: "authorization", reason: "contains invalid or duplicate principal grants")
      }
      result[principal.principalID] = principal.grants
    }
    policies = result
  }

  public func authorize(_ request: AuthorizationRequest) throws -> AuthorizedScope {
    let candidates = policies[request.principalID.rawValue, default: []].filter {
      $0.operations.contains(request.operation) && $0.bucket == request.bucket.rawValue
    }
    let selected: AuthorizationGrant?
    if request.operation == .listObjectsV2 {
      selected = candidates
        .filter { grant in
          guard let grantPrefix = grant.keyPrefix else { return true }
          guard let requested = request.listPrefix else { return false }
          return requested == grantPrefix || requested.hasPrefix(grantPrefix + "/")
        }
        .max { ($0.keyPrefix?.count ?? 0) < ($1.keyPrefix?.count ?? 0) }
    } else if let key = request.key {
      selected = candidates
        .filter { grant in
          guard let prefix = grant.keyPrefix else { return true }
          return key.rawValue == prefix || key.rawValue.hasPrefix(prefix + "/")
        }
        .max { ($0.keyPrefix?.count ?? 0) < ($1.keyPrefix?.count ?? 0) }
    } else {
      selected = nil
    }
    guard let selected else { throw GatewayError(code: .accessDenied, safeMessage: "Access denied.") }
    return AuthorizedScope(
      principalID: request.principalID,
      operation: request.operation,
      bucket: request.bucket,
      grantPrefix: selected.keyPrefix,
      requestedPrefix: request.listPrefix
    )
  }
}
