import Crypto
import Foundation
import Testing
@testable import AppCore

@Test func sigV4VerifiesPublishedS3StyleRequest() async throws {
  let request = SigV4Request(
    method: "GET",
    rawPath: "/test.txt",
    headers: [
      "Host": ["examplebucket.s3.amazonaws.com"],
      "Range": ["bytes=0-9"],
      "x-amz-content-sha256": ["e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"],
      "x-amz-date": ["20130524T000000Z"],
      "Authorization": [
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
          "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, " +
          "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
      ]
    ],
    payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  )
  let verifier = SigV4Verifier(
    credentials: TestInboundCredentialProvider(),
    acceptedRegions: ["us-east-1"]
  )
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
  let signedAt = try #require(formatter.date(from: "20130524T000000Z"))
  let result = try await verifier.verifyHeader(request: request, now: signedAt)
  #expect(result.principalID.rawValue == "example-principal")
}

@Test func sigV4RejectsSignatureTampering() async throws {
  let request = SigV4Request(
    method: "GET",
    rawPath: "/test.txt",
    headers: [
      "host": ["examplebucket.s3.amazonaws.com"],
      "x-amz-date": ["20130524T000000Z"],
      "authorization": [
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
          "SignedHeaders=host;x-amz-date, Signature=" + String(repeating: "0", count: 64)
      ]
    ],
    payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  )
  let verifier = SigV4Verifier(
    credentials: TestInboundCredentialProvider(),
    acceptedRegions: ["us-east-1"]
  )
  let now = Date(timeIntervalSince1970: 1_369_353_600)
  await #expect(throws: (any Error).self) {
    _ = try await verifier.verifyHeader(request: request, now: now)
  }
}

@Test func canonicalQuerySortsDuplicatesWithoutDecodingSeparators() throws {
  #expect(
    try SigV4Canonicalizer.canonicalQuery("z=2&a=%2f&a=1&plus=+", excludingSignature: false)
      == "a=%2F&a=1&plus=%2B&z=2"
  )
}

@Test func sigV4CanonicalHeadersNormalizeWhitespaceAndRequireStableOrder() throws {
  let request = SigV4Request(
    method: "GET",
    rawPath: "/",
    headers: [
      "host": [" example.test\t"],
      "x-example": ["  alpha\t beta   gamma  "]
    ],
    payloadHash: "UNSIGNED-PAYLOAD"
  )
  let canonical = try SigV4Canonicalizer.canonicalRequest(
    request: request,
    signedHeaders: ["host", "x-example"]
  )
  #expect(canonical.contains("host:example.test\nx-example:alpha beta gamma\n"))
  #expect(throws: SigV4Error.malformed) {
    _ = try SigV4Canonicalizer.canonicalRequest(
      request: request,
      signedHeaders: ["x-example", "host"]
    )
  }
  #expect(throws: SigV4Error.malformed) {
    _ = try SigV4Canonicalizer.canonicalRequest(
      request: request,
      signedHeaders: ["host", "host"]
    )
  }
}

@Test func sigV4RejectsClockSkewUnknownCredentialsAndInvalidPayloadPolicy() async throws {
  let signedAt = Date(timeIntervalSince1970: 1_369_353_600)
  let verifier = SigV4Verifier(
    credentials: TestInboundCredentialProvider(),
    acceptedRegions: ["us-east-1"],
    maximumClockSkew: 900
  )
  let validShape = SigV4Request(
    method: "GET",
    rawPath: "/test.txt",
    headers: [
      "host": ["examplebucket.s3.amazonaws.com"],
      "x-amz-date": ["20130524T000000Z"],
      "authorization": [
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
          "SignedHeaders=host;x-amz-date, Signature=" + String(repeating: "0", count: 64)
      ]
    ],
    payloadHash: "UNSIGNED-PAYLOAD"
  )
  await #expect(throws: SigV4Error.expired) {
    _ = try await verifier.verifyHeader(
      request: validShape,
      now: signedAt.addingTimeInterval(901)
    )
  }

  let unknown = SigV4Request(
    method: validShape.method,
    rawPath: validShape.rawPath,
    headers: [
      "host": ["examplebucket.s3.amazonaws.com"],
      "x-amz-date": ["20130524T000000Z"],
      "authorization": [
        "AWS4-HMAC-SHA256 Credential=UNKNOWN/20130524/us-east-1/s3/aws4_request, " +
          "SignedHeaders=host;x-amz-date, Signature=" + String(repeating: "0", count: 64)
      ]
    ],
    payloadHash: "UNSIGNED-PAYLOAD"
  )
  await #expect(throws: SigV4Error.unknownCredential) {
    _ = try await verifier.verifyHeader(request: unknown, now: signedAt)
  }

  let invalidPayload = SigV4Request(
    method: validShape.method,
    rawPath: validShape.rawPath,
    headers: validShape.headers,
    payloadHash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
  )
  await #expect(throws: SigV4Error.invalidPayloadPolicy) {
    _ = try await verifier.verifyHeader(
      request: invalidPayload,
      now: signedAt
    )
  }
}

@Test func sigV4RejectsMalformedSignedHeaderListsBeforeComparison() async throws {
  let verifier = SigV4Verifier(
    credentials: TestInboundCredentialProvider(),
    acceptedRegions: ["us-east-1"]
  )
  let signedAt = Date(timeIntervalSince1970: 1_369_353_600)
  for signedHeaders in ["x-amz-date;host", "host;host"] {
    let request = SigV4Request(
      method: "GET",
      rawPath: "/test.txt",
      headers: [
        "host": ["examplebucket.s3.amazonaws.com"],
        "x-amz-date": ["20130524T000000Z"],
        "authorization": [
          "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " +
            "SignedHeaders=\(signedHeaders), Signature=" + String(repeating: "0", count: 64)
        ]
      ],
      payloadHash: "UNSIGNED-PAYLOAD"
    )
    await #expect(throws: SigV4Error.malformed) {
      _ = try await verifier.verifyHeader(request: request, now: signedAt)
    }
  }
}

@Test func sigV4VerifiesPresignedReadAndExpiry() async throws {
  let query = "X-Amz-Algorithm=AWS4-HMAC-SHA256&" +
    "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&" +
    "X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&" +
    "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  let request = SigV4Request(
    method: "GET",
    rawPath: "/test.txt",
    rawQuery: query,
    headers: ["host": ["examplebucket.s3.amazonaws.com"]],
    payloadHash: "UNSIGNED-PAYLOAD"
  )
  let verifier = SigV4Verifier(
    credentials: TestInboundCredentialProvider(),
    acceptedRegions: ["us-east-1"]
  )
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
  let signedAt = try #require(formatter.date(from: "20130524T000000Z"))
  let result = try await verifier.verifyPresigned(request: request, now: signedAt.addingTimeInterval(60))
  #expect(result.accessKeyID == "AKIAIOSFODNN7EXAMPLE")
  await #expect(throws: SigV4Error.expired) {
    _ = try await verifier.verifyPresigned(request: request, now: signedAt.addingTimeInterval(86_401))
  }
}

private struct TestInboundCredentialProvider: InboundCredentialProviding {
  func credential(for accessKeyID: String) async -> InboundVerificationCredential? {
    guard accessKeyID == "AKIAIOSFODNN7EXAMPLE",
          let principal = PrincipalID(rawValue: "example-principal") else {
      return nil
    }
    return InboundVerificationCredential(
      accessKeyID: accessKeyID,
      principalID: principal,
      signingSecret: SymmetricKey(data: Data("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".utf8))
    )
  }
}
