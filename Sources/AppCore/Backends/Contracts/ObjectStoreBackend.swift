import Foundation

public struct BackendCapabilities: Codable, Equatable, Sendable {
  public let supported: Set<BackendCapability>
  public let maximumPartCount: Int
  public let checksumAlgorithms: Set<ChecksumAlgorithm>
  public let consistencyDescription: String

  public init(
    supported: Set<BackendCapability>,
    maximumPartCount: Int = 0,
    checksumAlgorithms: Set<ChecksumAlgorithm> = [],
    consistencyDescription: String
  ) {
    self.supported = supported
    self.maximumPartCount = maximumPartCount
    self.checksumAlgorithms = checksumAlgorithms
    self.consistencyDescription = consistencyDescription
  }
}

public protocol ObjectStoreBackend: Sendable {
  var kind: BackendKind { get }
  func capabilities() async -> BackendCapabilities
  func readinessCheck(deadline: Date) async throws
  func getObject(_ request: GetObjectRequest, context: RequestContext) async throws -> GetObjectResult
  func headObject(_ request: HeadObjectRequest, context: RequestContext) async throws -> ObjectMetadata
  func putObject(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult
  func deleteObject(_ request: DeleteObjectRequest, context: RequestContext) async throws
  func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result
}

public extension ObjectStoreBackend {
  func readinessCheck(deadline: Date) async throws {
    guard deadline > Date() else {
      throw BackendError.deadlineExceeded
    }
  }
}

public enum BackendError: Error, Equatable, Sendable {
  case notFound
  case alreadyExists
  case accessDenied
  case invalidRequest(String)
  case conditionFailed
  case notModified
  case rangeNotSatisfiable
  case checksumMismatch
  case capacityExceeded
  case consistencyFailure
  case cancelled
  case deadlineExceeded
  case unavailable(retryable: Bool)
  case unsupported(BackendCapability)
}
