import Foundation
import Testing
@testable import AppCore

@Suite("SecurityRegressionTests")
struct SecurityRegressionTests {
  @Test func healthAdmissionIsDerivedFromTheExactRawRequest() {
    let classifier = HealthRouteClassifier(
      configuration: HealthEndpointConfiguration(
        livenessPath: "/health/live",
        readinessPath: "/health/ready"
      )
    )

    let readiness = request(
      method: "GET",
      rawPath: "/health/ready",
      rawQuery: "",
      classifier: classifier
    )
    let nearMatch = request(
      method: "GET",
      rawPath: "/health/ready/",
      rawQuery: "",
      classifier: classifier
    )
    let queried = request(
      method: "GET",
      rawPath: "/health/ready",
      rawQuery: "probe=1",
      classifier: classifier
    )

    #expect(readiness.healthAdmission == .readiness)
    #expect(nearMatch.healthAdmission == .none)
    #expect(queried.healthAdmission == .none)
  }

  private func request(
    method: String,
    rawPath: String,
    rawQuery: String,
    classifier: HealthRouteClassifier
  ) -> HTTPTransportRequest {
    HTTPTransportRequest(
      method: method,
      rawPath: rawPath,
      rawQuery: rawQuery,
      headers: [:],
      body: ObjectBodyStream(data: Data()),
      healthClassifier: classifier
    )
  }
}
