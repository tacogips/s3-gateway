import Foundation
import Testing
@testable import AppCore

@Test func standardErrorTelemetryEmitsOnlyAllowlistedFields() async throws {
  let pipe = Pipe()
  let sink = StandardErrorGatewayTelemetrySink(output: pipe.fileHandleForWriting)
  await sink.record(
    GatewayTelemetryEvent(
      requestID: "request-id",
      method: .put,
      backend: .posix,
      status: 200,
      durationMilliseconds: 12
    )
  )
  try pipe.fileHandleForWriting.close()
  let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
  let object = try #require(
    try JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  #expect(Set(object.keys) == ["backend", "durationMilliseconds", "method", "requestID", "status"])
  #expect(object["requestID"] as? String == "request-id")
  let line = try #require(String(data: data, encoding: .utf8))
  #expect(!line.contains("bucket"))
  try pipe.fileHandleForReading.close()
}
