import Foundation

public struct RawS3RequestHead: Sendable {
  public let method: String
  public let rawPath: String
  public let rawQuery: String
  public let host: String
  public let headers: [String: [String]]

  public init(method: String, rawPath: String, rawQuery: String, host: String, headers: [String: [String]]) {
    self.method = method
    self.rawPath = rawPath
    self.rawQuery = rawQuery
    self.host = host
    self.headers = headers
  }
}

public struct RoutedS3Operation: Sendable {
  public let operation: GatewayOperation
  public let address: ResolvedS3Address
  public let query: [String: String]
}

public enum S3RoutingError: Error, Equatable, Sendable {
  case unsupported
  case malformed
  case duplicateQueryField(String)
}

public struct S3OperationRouter: Sendable {
  private let resolver: S3AddressingResolver

  public init(resolver: S3AddressingResolver) {
    self.resolver = resolver
  }

  public func route(_ request: RawS3RequestHead) throws -> RoutedS3Operation {
    let query = try parseQuery(request.rawQuery)
    let address = try resolver.resolve(rawPath: request.rawPath, host: request.host)
    let operation: GatewayOperation
    switch (request.method, address.key, query["list-type"]) {
    case ("GET", nil, "2"): operation = .listObjectsV2
    case ("GET", .some, _): operation = .getObject
    case ("HEAD", .some, _): operation = .headObject
    case ("PUT", .some, _): operation = .putObject
    case ("DELETE", .some, _): operation = .deleteObject
    default: throw S3RoutingError.unsupported
    }
    let authenticationFields = Set([
      "X-Amz-Algorithm", "X-Amz-Credential", "X-Amz-Date", "X-Amz-Expires",
      "X-Amz-SignedHeaders", "X-Amz-Signature", "X-Amz-Security-Token"
    ])
    let operationFields: Set<String> = switch operation {
    case .listObjectsV2:
      [
        "list-type", "prefix", "delimiter", "max-keys",
        "continuation-token", "encoding-type"
      ]
    case .getObject, .headObject, .putObject, .deleteObject:
      []
    default:
      []
    }
    let allowedFields = authenticationFields.union(operationFields)
    if query.keys.contains(where: { !allowedFields.contains($0) }) {
      throw S3RoutingError.unsupported
    }
    return RoutedS3Operation(operation: operation, address: address, query: query)
  }

  private func parseQuery(_ rawQuery: String) throws -> [String: String] {
    guard rawQuery.utf8.count <= 64 * 1_024 else { throw S3RoutingError.malformed }
    var result: [String: String] = [:]
    for field in rawQuery.split(separator: "&", omittingEmptySubsequences: false) where !field.isEmpty {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = try S3AddressingResolver.percentDecode(String(pair[0]))
      let value = try S3AddressingResolver.percentDecode(pair.count == 2 ? String(pair[1]) : "")
      guard result[name] == nil else { throw S3RoutingError.duplicateQueryField(name) }
      result[name] = value
    }
    return result
  }
}
