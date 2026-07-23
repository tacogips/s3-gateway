import Foundation

public struct RequestContext: Sendable {
  public let requestID: String
  public let principalID: PrincipalID
  public let deadline: Date

  public init(requestID: String, principalID: PrincipalID, deadline: Date) {
    self.requestID = requestID
    self.principalID = principalID
    self.deadline = deadline
  }
}

public struct GetObjectRequest: Sendable {
  public let bucket: BucketName
  public let key: ObjectKey
  public let range: ByteRange?
  public let conditions: ReadConditions

  public init(
    bucket: BucketName,
    key: ObjectKey,
    range: ByteRange? = nil,
    conditions: ReadConditions = .init()
  ) {
    self.bucket = bucket
    self.key = key
    self.range = range
    self.conditions = conditions
  }
}

public struct HeadObjectRequest: Sendable {
  public let bucket: BucketName
  public let key: ObjectKey
  public let conditions: ReadConditions

  public init(bucket: BucketName, key: ObjectKey, conditions: ReadConditions = .init()) {
    self.bucket = bucket
    self.key = key
    self.conditions = conditions
  }
}

public struct PutObjectRequest: Sendable {
  public let bucket: BucketName
  public let key: ObjectKey
  public let body: ObjectBodyStream
  public let knownContentLength: Int64?
  public let contentType: String?
  public let userMetadata: [String: String]
  public let expectedChecksums: [ObjectChecksum]
  public let expectedContentMD5: String?
  public let conditions: WriteConditions

  public init(
    bucket: BucketName,
    key: ObjectKey,
    body: ObjectBodyStream,
    knownContentLength: Int64? = nil,
    contentType: String? = nil,
    userMetadata: [String: String] = [:],
    expectedChecksums: [ObjectChecksum] = [],
    expectedContentMD5: String? = nil,
    conditions: WriteConditions = .init()
  ) {
    self.bucket = bucket
    self.key = key
    self.body = body
    self.knownContentLength = knownContentLength
    self.contentType = contentType
    self.userMetadata = userMetadata
    self.expectedChecksums = expectedChecksums
    self.expectedContentMD5 = expectedContentMD5
    self.conditions = conditions
  }
}

public struct DeleteObjectRequest: Sendable {
  public let bucket: BucketName
  public let key: ObjectKey
  public let conditions: WriteConditions

  public init(bucket: BucketName, key: ObjectKey, conditions: WriteConditions = .init()) {
    self.bucket = bucket
    self.key = key
    self.conditions = conditions
  }
}

public struct ListObjectsV2Request: Sendable {
  public let bucket: BucketName
  public let prefix: String
  public let delimiter: String?
  public let maximumKeys: Int
  public let continuationToken: String?

  public init(
    bucket: BucketName,
    prefix: String = "",
    delimiter: String? = nil,
    maximumKeys: Int = 1_000,
    continuationToken: String? = nil
  ) {
    self.bucket = bucket
    self.prefix = prefix
    self.delimiter = delimiter
    self.maximumKeys = maximumKeys
    self.continuationToken = continuationToken
  }
}

public struct GetObjectResult: Sendable {
  public let metadata: ObjectMetadata
  public let body: ObjectBodyStream
  public let servedRange: ByteRange?
}

public struct PutObjectResult: Sendable {
  public let metadata: ObjectMetadata
}

public struct ListedObject: Codable, Equatable, Sendable {
  public let key: ObjectKey
  public let size: Int64
  public let lastModified: Date
  public let entityTag: EntityTag
}

public struct ListObjectsV2Result: Sendable {
  public let objects: [ListedObject]
  public let commonPrefixes: [String]
  public let nextContinuationToken: String?
}
