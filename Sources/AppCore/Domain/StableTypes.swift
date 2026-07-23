import Foundation

public enum BackendKind: String, Codable, CaseIterable, Sendable {
  case posix
  case s3
}

public enum AddressingStyle: String, Codable, CaseIterable, Sendable {
  case path
  case virtualHost
}

public enum GatewayOperation: String, Codable, CaseIterable, Hashable, Sendable {
  case getObject
  case headObject
  case putObject
  case deleteObject
  case listObjectsV2
  case createMultipartUpload
  case uploadPart
  case completeMultipartUpload
  case abortMultipartUpload
}

public enum BackendCapability: String, Codable, CaseIterable, Hashable, Sendable {
  case rangeRead
  case conditionalRead
  case conditionalWrite
  case listPagination
  case userMetadata
  case multipartUpload
  case strongReadAfterWrite
  case checksumSHA256
  case checksumCRC32C
}

public enum ChecksumAlgorithm: String, Codable, CaseIterable, Hashable, Sendable {
  case sha256
  case crc32c
}

public enum POSIXLayoutPolicy: String, Codable, CaseIterable, Sendable {
  case managedPrivateLayout
  case sharedLocalDirectory
}

public enum DurabilityMode: String, Codable, CaseIterable, Sendable {
  case relaxed
  case data
  case strict
}
