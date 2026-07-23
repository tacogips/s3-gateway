import Foundation

public struct HTTPTransportRequest: Sendable {
  public let method: String
  public let rawPath: String
  public let rawQuery: String
  public let headers: [String: [String]]
  public let body: ObjectBodyStream
  public let remoteAddress: String?
  public let healthAdmission: HealthAdmission
  public let deadline: Date

  public init(
    method: String,
    rawPath: String,
    rawQuery: String,
    headers: [String: [String]],
    body: ObjectBodyStream,
    remoteAddress: String? = nil,
    healthClassifier: HealthRouteClassifier = .disabled,
    deadline: Date = Date().addingTimeInterval(
      TimeInterval(GatewayLimits.defaults.requestTimeoutSeconds)
    )
  ) {
    self.method = method
    self.rawPath = rawPath
    self.rawQuery = rawQuery
    self.headers = headers
    self.body = body
    self.remoteAddress = remoteAddress
    healthAdmission = healthClassifier.classify(
      method: method,
      rawPath: rawPath,
      rawQuery: rawQuery
    )
    self.deadline = deadline
  }

  public func header(_ name: String) -> [String] {
    headers.flatMap { $0.key.caseInsensitiveCompare(name) == .orderedSame ? $0.value : [] }
  }
}

public struct HTTPTransportResponse: Sendable {
  public let status: Int
  public let headers: [(String, String)]
  public let body: ObjectBodyStream?

  public init(status: Int, headers: [(String, String)] = [], body: ObjectBodyStream? = nil) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  public init(status: Int, headers: [(String, String)] = [], data: Data) {
    self.init(status: status, headers: headers, body: ObjectBodyStream(data: data))
  }
}

public typealias HTTPApplicationHandler = @Sendable (HTTPTransportRequest) async -> HTTPTransportResponse
