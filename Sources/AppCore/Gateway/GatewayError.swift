import Foundation

public enum GatewayErrorCode: String, Codable, Sendable {
  case accessDenied = "AccessDenied"
  case badDigest = "BadDigest"
  case internalError = "InternalError"
  case invalidArgument = "InvalidArgument"
  case invalidRange = "InvalidRange"
  case invalidRequest = "InvalidRequest"
  case noSuchBucket = "NoSuchBucket"
  case noSuchKey = "NoSuchKey"
  case notModified = "NotModified"
  case notImplemented = "NotImplemented"
  case preconditionFailed = "PreconditionFailed"
  case requestTimeout = "RequestTimeout"
  case serviceUnavailable = "ServiceUnavailable"
  case slowDown = "SlowDown"
}

public struct GatewayError: Error, Equatable, Sendable {
  public let code: GatewayErrorCode
  public let safeMessage: String
  public let retryable: Bool

  public init(code: GatewayErrorCode, safeMessage: String, retryable: Bool = false) {
    self.code = code
    self.safeMessage = safeMessage
    self.retryable = retryable
  }

  public static func map(_ error: BackendError) -> GatewayError {
    switch error {
    case .notFound:
      GatewayError(code: .noSuchKey, safeMessage: "The specified key does not exist.")
    case .alreadyExists, .conditionFailed:
      GatewayError(code: .preconditionFailed, safeMessage: "A request condition was not satisfied.")
    case .notModified:
      GatewayError(code: .notModified, safeMessage: "The object was not modified.")
    case .accessDenied:
      GatewayError(code: .accessDenied, safeMessage: "Access denied.")
    case .invalidRequest:
      GatewayError(code: .invalidRequest, safeMessage: "The storage request is invalid.")
    case .rangeNotSatisfiable:
      GatewayError(code: .invalidRange, safeMessage: "The requested range is not satisfiable.")
    case .checksumMismatch:
      GatewayError(code: .badDigest, safeMessage: "The supplied checksum did not match.")
    case .capacityExceeded:
      GatewayError(code: .slowDown, safeMessage: "Resource capacity was exceeded.", retryable: true)
    case .cancelled, .deadlineExceeded:
      GatewayError(code: .requestTimeout, safeMessage: "The request did not complete in time.", retryable: true)
    case .unavailable(let retryable):
      GatewayError(code: .serviceUnavailable, safeMessage: "The storage backend is unavailable.", retryable: retryable)
    case .unsupported:
      GatewayError(code: .notImplemented, safeMessage: "The requested capability is not implemented.")
    case .consistencyFailure:
      GatewayError(code: .internalError, safeMessage: "Stored data is temporarily inconsistent.", retryable: true)
    }
  }
}
