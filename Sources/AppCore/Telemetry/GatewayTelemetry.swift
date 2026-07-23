import Foundation

public enum GatewayRequestMethodClass: String, Codable, Sendable {
  case get
  case head
  case put
  case delete
  case other

  init(method: String) {
    switch method {
    case "GET": self = .get
    case "HEAD": self = .head
    case "PUT": self = .put
    case "DELETE": self = .delete
    default: self = .other
    }
  }
}

public struct GatewayTelemetryEvent: Codable, Equatable, Sendable {
  public let requestID: String
  public let method: GatewayRequestMethodClass
  public let backend: BackendKind
  public let status: Int
  public let durationMilliseconds: Int64

  public init(
    requestID: String,
    method: GatewayRequestMethodClass,
    backend: BackendKind,
    status: Int,
    durationMilliseconds: Int64
  ) {
    self.requestID = requestID
    self.method = method
    self.backend = backend
    self.status = status
    self.durationMilliseconds = durationMilliseconds
  }
}

public protocol GatewayTelemetrySink: Sendable {
  func record(_ event: GatewayTelemetryEvent) async
}

public struct NoopGatewayTelemetrySink: GatewayTelemetrySink {
  public init() {}
  public func record(_ event: GatewayTelemetryEvent) async {}
}

public actor StandardErrorGatewayTelemetrySink: GatewayTelemetrySink {
  private let output: FileHandle
  private let encoder: JSONEncoder

  public init(output: FileHandle = .standardError) {
    self.output = output
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  }

  public func record(_ event: GatewayTelemetryEvent) {
    guard var data = try? encoder.encode(event) else { return }
    data.append(0x0A)
    try? output.write(contentsOf: data)
  }
}
