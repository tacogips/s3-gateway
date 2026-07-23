import Crypto
import Foundation

struct UpstreamS3Signer: Sendable {
  let configuration: UpstreamS3Configuration
  let credentials: any UpstreamCredentialProviding

  func signedRequest(
    method: String,
    bucket: BucketName,
    key: ObjectKey?,
    query: [(String, String)] = [],
    additionalHeaders: [(String, String)] = [],
    body: ObjectBodyStream? = nil,
    contentLength: Int64? = nil,
    payloadHash: String = "UNSIGNED-PAYLOAD",
    deadline: Date? = nil,
    now: Date = Date()
  ) async throws -> UpstreamHTTPRequest {
    guard let upstreamBucket = configuration.bucketMappings[bucket.rawValue] else { throw BackendError.notFound }
    let credential = await credentials.activeCredential()
    let path = Self.path(bucket: upstreamBucket, key: key, style: configuration.addressingStyle)
    let host = Self.host(endpoint: configuration.endpoint, bucket: upstreamBucket, style: configuration.addressingStyle)
    guard var components = URLComponents(url: configuration.endpoint, resolvingAgainstBaseURL: false) else {
      throw BackendError.invalidRequest("The upstream endpoint is invalid.")
    }
    components.host = host
    components.percentEncodedPath = path
    if !query.isEmpty {
      components.percentEncodedQuery = query.map { "\(Self.encode($0.0, preserveSlash: false))=\(Self.encode($0.1, preserveSlash: false))" }
        .joined(separator: "&")
    }
    guard let url = components.url else { throw BackendError.invalidRequest("The upstream URL is invalid.") }
    let date = Self.sigV4Date(now)
    var headers = additionalHeaders
    headers.append(("host", Self.hostHeader(url)))
    headers.append(("x-amz-content-sha256", payloadHash))
    headers.append(("x-amz-date", date))
    if let contentLength { headers.append(("content-length", String(contentLength))) }
    if let token = credential.sessionToken { headers.append(("x-amz-security-token", token)) }
    let signedNames = Set(headers.map { $0.0.lowercased() }).sorted()
    var canonicalHeaders: [String: [String]] = [:]
    for header in headers { canonicalHeaders[header.0, default: []].append(header.1) }
    let canonical = try SigV4Canonicalizer.canonicalRequest(
      request: SigV4Request(
        method: method,
        rawPath: path,
        rawQuery: components.percentEncodedQuery ?? "",
        headers: canonicalHeaders,
        payloadHash: payloadHash
      ),
      signedHeaders: signedNames
    )
    let shortDate = String(date.prefix(8))
    let scope = "\(shortDate)/\(configuration.region)/s3/aws4_request"
    let stringToSign = [
      "AWS4-HMAC-SHA256", date, scope, SigV4Canonicalizer.sha256Hex(canonical)
    ].joined(separator: "\n")
    let signingKey = SigV4Verifier.deriveSigningKey(
      secret: credential.signingSecret,
      date: shortDate,
      region: configuration.region,
      service: "s3"
    )
    let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey)
      .map { String(format: "%02x", $0) }.joined()
    headers.append((
      "authorization",
      "AWS4-HMAC-SHA256 Credential=\(credential.accessKeyID)/\(scope), SignedHeaders=\(signedNames.joined(separator: ";")), Signature=\(signature)"
    ))
    return UpstreamHTTPRequest(
      method: method,
      url: url,
      headers: headers,
      body: body,
      deadline: deadline
    )
  }

  private static func path(bucket: String, key: ObjectKey?, style: AddressingStyle) -> String {
    let keyPath = key.map { encode($0.rawValue, preserveSlash: true) } ?? ""
    switch style {
    case .path:
      return "/" + encode(bucket, preserveSlash: false) + (keyPath.isEmpty ? "" : "/" + keyPath)
    case .virtualHost:
      return keyPath.isEmpty ? "/" : "/" + keyPath
    }
  }

  private static func host(endpoint: URL, bucket: String, style: AddressingStyle) -> String {
    guard let endpointHost = endpoint.host else { return "" }
    return style == .virtualHost ? "\(bucket).\(endpointHost)" : endpointHost
  }

  private static func hostHeader(_ url: URL) -> String {
    guard let host = url.host else { return "" }
    guard let port = url.port, port != 443 else { return host }
    return "\(host):\(port)"
  }

  private static func sigV4Date(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private static func encode(_ value: String, preserveSlash: Bool) -> String {
    value.utf8.map { byte -> String in
      if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) {
        return String(Character(UnicodeScalar(byte)))
      }
      if preserveSlash, byte == 47 { return "/" }
      return String(format: "%%%02X", byte)
    }.joined()
  }
}
