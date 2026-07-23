import Foundation

public struct EntityTag: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard rawValue.count >= 2,
          rawValue.first == "\"",
          rawValue.last == "\"",
          !rawValue.dropFirst().dropLast().contains("\"") else {
      return nil
    }
    self.rawValue = rawValue
  }
}

public struct ObjectChecksum: Codable, Equatable, Hashable, Sendable {
  public let algorithm: ChecksumAlgorithm
  public let base64Value: String

  public init(algorithm: ChecksumAlgorithm, base64Value: String) {
    self.algorithm = algorithm
    self.base64Value = base64Value
  }
}

public struct ObjectMetadata: Codable, Equatable, Sendable {
  public let contentType: String?
  public let contentLength: Int64
  public let lastModified: Date
  public let entityTag: EntityTag
  public let userMetadata: [String: String]
  public let checksums: [ObjectChecksum]
  public let versionToken: ObjectVersionToken

  public init(
    contentType: String?,
    contentLength: Int64,
    lastModified: Date,
    entityTag: EntityTag,
    userMetadata: [String: String] = [:],
    checksums: [ObjectChecksum] = [],
    versionToken: ObjectVersionToken
  ) {
    self.contentType = contentType
    self.contentLength = contentLength
    self.lastModified = lastModified
    self.entityTag = entityTag
    self.userMetadata = userMetadata
    self.checksums = checksums
    self.versionToken = versionToken
  }
}

public struct ByteRange: Codable, Equatable, Sendable {
  public let lowerBound: Int64
  public let upperBound: Int64?

  public init(lowerBound: Int64, upperBound: Int64? = nil) throws {
    guard lowerBound >= 0, upperBound.map({ $0 >= lowerBound }) ?? true else {
      throw DomainValidationError.invalidRange
    }
    self.lowerBound = lowerBound
    self.upperBound = upperBound
  }
}

public struct ReadConditions: Codable, Equatable, Sendable {
  public var ifMatch: [EntityTag]
  public var ifNoneMatch: [EntityTag]
  public var ifMatchAny: Bool
  public var ifNoneMatchAny: Bool
  public var ifModifiedSince: Date?
  public var ifUnmodifiedSince: Date?

  public init(
    ifMatch: [EntityTag] = [],
    ifNoneMatch: [EntityTag] = [],
    ifMatchAny: Bool = false,
    ifNoneMatchAny: Bool = false,
    ifModifiedSince: Date? = nil,
    ifUnmodifiedSince: Date? = nil
  ) {
    self.ifMatch = ifMatch
    self.ifNoneMatch = ifNoneMatch
    self.ifMatchAny = ifMatchAny
    self.ifNoneMatchAny = ifNoneMatchAny
    self.ifModifiedSince = ifModifiedSince
    self.ifUnmodifiedSince = ifUnmodifiedSince
  }
}

public struct WriteConditions: Codable, Equatable, Sendable {
  public var ifMatch: EntityTag?
  public var requireAbsent: Bool

  public init(ifMatch: EntityTag? = nil, requireAbsent: Bool = false) {
    self.ifMatch = ifMatch
    self.requireAbsent = requireAbsent
  }
}
