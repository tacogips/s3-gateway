import Foundation
import Testing
@testable import AppCore

@Test func healthRouteClassifierAcceptsOnlyExactConfiguredControlPlaneRoutes() {
  let classifier = HealthRouteClassifier(
    configuration: HealthEndpointConfiguration(
      livenessPath: "/health/live",
      readinessPath: "/health/ready"
    )
  )

  #expect(
    classifier.classify(method: "GET", rawPath: "/health/live", rawQuery: "") ==
      .liveness
  )
  #expect(
    classifier.classify(method: "HEAD", rawPath: "/health/ready", rawQuery: "") ==
      .readiness
  )
  #expect(
    classifier.classify(method: "POST", rawPath: "/health/ready", rawQuery: "") ==
      .none
  )
  #expect(
    classifier.classify(method: "GET", rawPath: "/health/ready", rawQuery: "probe=1") ==
      .none
  )
  #expect(
    classifier.classify(method: "GET", rawPath: "/health/ready/", rawQuery: "") ==
      .none
  )
  #expect(
    HealthRouteClassifier.disabled.classify(
      method: "GET",
      rawPath: "/health/ready",
      rawQuery: ""
    ) == .none
  )
}
