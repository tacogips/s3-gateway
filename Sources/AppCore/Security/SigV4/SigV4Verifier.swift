import Crypto
import Foundation

public struct SigV4Verifier: Sendable {
  private let credentials: any InboundCredentialProviding
  private let acceptedRegions: Set<String>
  private let acceptedServices: Set<String>
  private let maximumClockSkew: TimeInterval
  private let maximumPresignedLifetime: TimeInterval

  public init(
    credentials: any InboundCredentialProviding,
    acceptedRegions: Set<String>,
    acceptedServices: Set<String> = ["s3"],
    maximumClockSkew: TimeInterval = 900,
    maximumPresignedLifetime: TimeInterval = 604_800
  ) {
    self.credentials = credentials
    self.acceptedRegions = acceptedRegions
    self.acceptedServices = acceptedServices
    self.maximumClockSkew = maximumClockSkew
    self.maximumPresignedLifetime = maximumPresignedLifetime
  }

  public func verifyPresigned(
    request: SigV4Request,
    now: Date = Date()
  ) async throws -> SigV4AuthenticationResult {
    let query = try Self.parseQuery(request.rawQuery)
    guard query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256",
          let credentialText = query["X-Amz-Credential"],
          let dateText = query["X-Amz-Date"],
          let expiryText = query["X-Amz-Expires"],
          let expiry = TimeInterval(expiryText),
          expiry >= 0,
          expiry <= maximumPresignedLifetime,
          let signedHeadersText = query["X-Amz-SignedHeaders"],
          let signature = query["X-Amz-Signature"],
          Self.isLowerHex(signature, length: 64) else {
      throw SigV4Error.malformed
    }
    let scope = try parseScope(credentialText)
    guard acceptedRegions.contains(scope.region), acceptedServices.contains(scope.service) else {
      throw SigV4Error.invalidScope
    }
    guard let signedAt = Self.parseDate(dateText), scope.date == String(dateText.prefix(8)) else {
      throw SigV4Error.malformed
    }
    guard now >= signedAt.addingTimeInterval(-maximumClockSkew),
          now <= signedAt.addingTimeInterval(expiry) else {
      throw SigV4Error.expired
    }
    guard request.payloadHash == "UNSIGNED-PAYLOAD" || Self.isLowerHex(request.payloadHash, length: 64),
          let credential = await credentials.credential(for: scope.accessKeyID) else {
      throw SigV4Error.unknownCredential
    }
    let signedHeaders = signedHeadersText.split(separator: ";").map(String.init)
    guard signedHeaders.contains("host") else { throw SigV4Error.malformed }
    let canonical = try SigV4Canonicalizer.canonicalRequest(
      request: request,
      signedHeaders: signedHeaders,
      excludingSignatureQuery: true
    )
    let scopeText = "\(scope.date)/\(scope.region)/\(scope.service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      dateText,
      scopeText,
      SigV4Canonicalizer.sha256Hex(canonical)
    ].joined(separator: "\n")
    let signingKey = Self.deriveSigningKey(
      secret: credential.signingSecret,
      date: scope.date,
      region: scope.region,
      service: scope.service
    )
    let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey))
    guard let supplied = Self.decodeHex(signature), Self.constantTimeEqual(expected, supplied) else {
      throw SigV4Error.signatureMismatch
    }
    return SigV4AuthenticationResult(
      principalID: credential.principalID,
      accessKeyID: credential.accessKeyID,
      signedAt: signedAt
    )
  }

  public func verifyHeader(
    request: SigV4Request,
    now: Date = Date()
  ) async throws -> SigV4AuthenticationResult {
    guard request.values(for: "authorization").count == 1,
          let authorization = request.values(for: "authorization").first,
          request.values(for: "x-amz-date").count == 1,
          let dateText = request.values(for: "x-amz-date").first else {
      throw SigV4Error.malformed
    }
    let parsed = try parseAuthorization(authorization)
    guard parsed.signedHeaders.contains("host") else { throw SigV4Error.malformed }
    let scope = try parseScope(parsed.credential)
    guard acceptedRegions.contains(scope.region), acceptedServices.contains(scope.service) else {
      throw SigV4Error.invalidScope
    }
    guard let signedAt = Self.parseDate(dateText),
          scope.date == String(dateText.prefix(8)),
          abs(now.timeIntervalSince(signedAt)) <= maximumClockSkew else {
      throw SigV4Error.expired
    }
    guard request.payloadHash == "UNSIGNED-PAYLOAD" || Self.isLowerHex(request.payloadHash, length: 64) else {
      throw SigV4Error.invalidPayloadPolicy
    }
    guard let credential = await credentials.credential(for: scope.accessKeyID) else {
      throw SigV4Error.unknownCredential
    }
    let canonical = try SigV4Canonicalizer.canonicalRequest(
      request: request,
      signedHeaders: parsed.signedHeaders
    )
    let scopeText = "\(scope.date)/\(scope.region)/\(scope.service)/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256",
      dateText,
      scopeText,
      SigV4Canonicalizer.sha256Hex(canonical)
    ].joined(separator: "\n")
    let signingKey = Self.deriveSigningKey(
      secret: credential.signingSecret,
      date: scope.date,
      region: scope.region,
      service: scope.service
    )
    let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey))
    guard let supplied = Self.decodeHex(parsed.signature),
          Self.constantTimeEqual(expected, supplied) else {
      throw SigV4Error.signatureMismatch
    }
    return SigV4AuthenticationResult(
      principalID: credential.principalID,
      accessKeyID: credential.accessKeyID,
      signedAt: signedAt
    )
  }

  private func parseAuthorization(_ value: String) throws -> ParsedAuthorization {
    guard value.hasPrefix("AWS4-HMAC-SHA256 ") else { throw SigV4Error.unsupportedAlgorithm }
    let fields = value.dropFirst("AWS4-HMAC-SHA256 ".count).split(separator: ",")
    var values: [String: String] = [:]
    for field in fields {
      let pair = field.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
      guard pair.count == 2, values[String(pair[0])] == nil else { throw SigV4Error.malformed }
      values[String(pair[0])] = String(pair[1])
    }
    guard let credential = values["Credential"],
          let signedHeaders = values["SignedHeaders"]?.split(separator: ";").map(String.init),
          let signature = values["Signature"],
          values.count == 3,
          Self.isLowerHex(signature, length: 64) else {
      throw SigV4Error.malformed
    }
    return ParsedAuthorization(credential: credential, signedHeaders: signedHeaders, signature: signature)
  }

  private func parseScope(_ value: String) throws -> CredentialScope {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 5,
          parts[4] == "aws4_request",
          parts[1].count == 8,
          !parts[0].isEmpty,
          !parts[2].isEmpty,
          !parts[3].isEmpty else {
      throw SigV4Error.invalidScope
    }
    return CredentialScope(
      accessKeyID: String(parts[0]),
      date: String(parts[1]),
      region: String(parts[2]),
      service: String(parts[3])
    )
  }

  static func deriveSigningKey(secret: SymmetricKey, date: String, region: String, service: String) -> SymmetricKey {
    let rawSecret = secret.withUnsafeBytes { Data($0) }
    let dateKey = hmac(key: SymmetricKey(data: Data("AWS4".utf8) + rawSecret), value: date)
    let regionKey = hmac(key: dateKey, value: region)
    let serviceKey = hmac(key: regionKey, value: service)
    return hmac(key: serviceKey, value: "aws4_request")
  }

  private static func hmac(key: SymmetricKey, value: String) -> SymmetricKey {
    SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: key)))
  }

  private static func parseDate(_ value: String) -> Date? {
    guard value.count == 16, value.hasSuffix("Z") else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.date(from: value)
  }

  private static func isLowerHex(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func decodeHex(_ value: String) -> Data? {
    guard value.count.isMultiple(of: 2) else { return nil }
    var data = Data()
    var index = value.startIndex
    while index < value.endIndex {
      let next = value.index(index, offsetBy: 2)
      guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
      data.append(byte)
      index = next
    }
    return data
  }

  private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }

  private static func parseQuery(_ rawQuery: String) throws -> [String: String] {
    var result: [String: String] = [:]
    for field in rawQuery.split(separator: "&", omittingEmptySubsequences: false) where !field.isEmpty {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = try percentDecode(String(pair[0]))
      let value = try percentDecode(pair.count == 2 ? String(pair[1]) : "")
      guard result[name] == nil else { throw SigV4Error.malformed }
      result[name] = value
    }
    return result
  }

  private static func percentDecode(_ value: String) throws -> String {
    var bytes: [UInt8] = []
    let input = Array(value.utf8)
    var index = 0
    while index < input.count {
      if input[index] == 37 {
        guard index + 2 < input.count,
              let byte = UInt8(String(bytes: input[(index + 1)...(index + 2)], encoding: .utf8) ?? "", radix: 16) else {
          throw SigV4Error.malformed
        }
        bytes.append(byte)
        index += 3
      } else {
        bytes.append(input[index])
        index += 1
      }
    }
    guard let decoded = String(bytes: bytes, encoding: .utf8) else { throw SigV4Error.malformed }
    return decoded
  }
}

private struct ParsedAuthorization {
  let credential: String
  let signedHeaders: [String]
  let signature: String
}

private struct CredentialScope {
  let accessKeyID: String
  let date: String
  let region: String
  let service: String
}
