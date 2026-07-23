import Foundation
import Testing
@testable import AppCore

@Test func backendErrorsMapWithoutLeakingImplementationDetails() {
  let mapped = GatewayError.map(.unavailable(retryable: true))
  #expect(mapped.code == .serviceUnavailable)
  #expect(mapped.retryable)
  #expect(!mapped.safeMessage.isEmpty)

  let untrusted = GatewayError.map(
    .invalidRequest("secret endpoint /private/path should not escape")
  )
  #expect(untrusted.code == .invalidRequest)
  #expect(!untrusted.safeMessage.contains("secret"))
  #expect(!untrusted.safeMessage.contains("/private/path"))
}

@Test func everyBackendErrorMapsToControlledS3Code() {
  let cases: [GatewayErrorMappingCase] = [
    GatewayErrorMappingCase(.notFound, .noSuchKey),
    GatewayErrorMappingCase(.alreadyExists, .preconditionFailed),
    GatewayErrorMappingCase(.accessDenied, .accessDenied),
    GatewayErrorMappingCase(.invalidRequest("untrusted"), .invalidRequest),
    GatewayErrorMappingCase(.conditionFailed, .preconditionFailed),
    GatewayErrorMappingCase(.notModified, .notModified),
    GatewayErrorMappingCase(.rangeNotSatisfiable, .invalidRange),
    GatewayErrorMappingCase(.checksumMismatch, .badDigest),
    GatewayErrorMappingCase(.capacityExceeded, .slowDown, retryable: true),
    GatewayErrorMappingCase(.consistencyFailure, .internalError, retryable: true),
    GatewayErrorMappingCase(.cancelled, .requestTimeout, retryable: true),
    GatewayErrorMappingCase(.deadlineExceeded, .requestTimeout, retryable: true),
    GatewayErrorMappingCase(
      .unavailable(retryable: false),
      .serviceUnavailable
    ),
    GatewayErrorMappingCase(
      .unavailable(retryable: true),
      .serviceUnavailable,
      retryable: true
    ),
    GatewayErrorMappingCase(
      .unsupported(.conditionalWrite),
      .notImplemented
    )
  ]
  for value in cases {
    let mapped = GatewayError.map(value.backend)
    #expect(mapped.code == value.expectedCode)
    #expect(mapped.retryable == value.expectedRetryable)
    #expect(!mapped.safeMessage.isEmpty)
    #expect(!mapped.safeMessage.contains("untrusted"))
  }
}

@Test func s3ErrorEncoderEscapesMessageAndRequestID() async throws {
  let response = S3ResponseEncoder.error(
    GatewayError(
      code: .invalidRequest,
      safeMessage: "unsafe <tag> & \"quote\" 'apostrophe'"
    ),
    requestID: "request<&\"'"
  )
  #expect(response.status == 400)
  let collector = GatewayErrorDataCollector()
  try await #require(response.body).consume { await collector.append($0) }
  let xml = try #require(String(data: await collector.data, encoding: .utf8))
  #expect(xml.contains("unsafe &lt;tag&gt; &amp; &quot;quote&quot; &apos;apostrophe&apos;"))
  #expect(xml.contains("request&lt;&amp;&quot;&apos;"))
  #expect(!xml.contains("<tag>"))
}

private struct GatewayErrorMappingCase {
  let backend: BackendError
  let expectedCode: GatewayErrorCode
  let expectedRetryable: Bool

  init(
    _ backend: BackendError,
    _ expectedCode: GatewayErrorCode,
    retryable: Bool = false
  ) {
    self.backend = backend
    self.expectedCode = expectedCode
    expectedRetryable = retryable
  }
}

private actor GatewayErrorDataCollector {
  private(set) var data = Data()

  func append(_ value: Data) {
    data.append(value)
  }
}
