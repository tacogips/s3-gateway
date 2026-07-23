import Foundation

public enum HealthAdmission: String, Equatable, Sendable {
  case liveness
  case readiness
  case none
}

public struct HealthRouteClassifier: Equatable, Sendable {
  private let livenessPath: String?
  private let readinessPath: String?

  public static let disabled = HealthRouteClassifier(configuration: nil)

  public init(configuration: HealthEndpointConfiguration?) {
    livenessPath = configuration?.livenessPath
    readinessPath = configuration?.readinessPath
  }

  public func classify(
    method: String,
    rawPath: String,
    rawQuery: String
  ) -> HealthAdmission {
    guard rawQuery.isEmpty, method == "GET" || method == "HEAD" else {
      return .none
    }
    if rawPath == livenessPath {
      return .liveness
    }
    if rawPath == readinessPath {
      return .readiness
    }
    return .none
  }
}
