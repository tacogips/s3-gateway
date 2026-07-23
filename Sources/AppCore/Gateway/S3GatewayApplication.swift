import Foundation

public struct S3GatewayApplication: Sendable {
  private let router: S3OperationRouter
  private let verifier: SigV4Verifier
  private let authorization: AuthorizationPolicy
  private let pagination: PaginationTokenService
  private let service: GatewayService
  private let limits: GatewayLimits
  private let health: HealthEndpointConfiguration?
  private let telemetry: any GatewayTelemetrySink

  public init(
    router: S3OperationRouter,
    verifier: SigV4Verifier,
    authorization: AuthorizationPolicy,
    pagination: PaginationTokenService,
    service: GatewayService,
    limits: GatewayLimits,
    health: HealthEndpointConfiguration? = nil,
    telemetry: any GatewayTelemetrySink = NoopGatewayTelemetrySink()
  ) {
    self.router = router
    self.verifier = verifier
    self.authorization = authorization
    self.pagination = pagination
    self.service = service
    self.limits = limits
    self.health = health
    self.telemetry = telemetry
  }

  public func handle(_ request: HTTPTransportRequest) async -> HTTPTransportResponse {
    let started = ContinuousClock.now
    let response = await response(for: request)
    let finalResponse = if request.method == "HEAD", response.body != nil {
      HTTPTransportResponse(status: response.status, headers: response.headers)
    } else {
      response
    }
    let elapsed = started.duration(to: ContinuousClock.now).components
    let milliseconds = max(0, elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
    let requestID = finalResponse.headers.first {
      $0.0.caseInsensitiveCompare("x-amz-request-id") == .orderedSame
    }?.1 ?? UUID().uuidString.lowercased()
    await telemetry.record(
      GatewayTelemetryEvent(
        requestID: requestID,
        method: GatewayRequestMethodClass(method: request.method),
        backend: await service.backendKind,
        status: finalResponse.status,
        durationMilliseconds: milliseconds
      )
    )
    return finalResponse
  }

  private func response(for request: HTTPTransportRequest) async -> HTTPTransportResponse {
    if let response = await healthResponse(request) { return response }
    let requestID = UUID().uuidString.lowercased()
    do {
      return try await handleAuthorized(request, requestID: requestID)
    } catch let error as GatewayError {
      return S3ResponseEncoder.error(error, requestID: requestID)
    } catch let error as BackendError {
      return S3ResponseEncoder.error(GatewayError.map(error), requestID: requestID)
    } catch is SigV4Error {
      return S3ResponseEncoder.error(
        GatewayError(code: .accessDenied, safeMessage: "The request signature is invalid."),
        requestID: requestID
      )
    } catch is S3AddressingError {
      return S3ResponseEncoder.error(
        GatewayError(code: .invalidRequest, safeMessage: "The bucket or object address is invalid."),
        requestID: requestID
      )
    } catch is S3RoutingError {
      return S3ResponseEncoder.error(
        GatewayError(code: .notImplemented, safeMessage: "The requested S3 operation is not implemented."),
        requestID: requestID
      )
    } catch {
      return S3ResponseEncoder.error(
        GatewayError(code: .invalidRequest, safeMessage: "The request is malformed."),
        requestID: requestID
      )
    }
  }

  private func healthResponse(_ request: HTTPTransportRequest) async -> HTTPTransportResponse? {
    guard let health,
          request.rawQuery.isEmpty,
          request.method == "GET" || request.method == "HEAD" else { return nil }
    let state: String
    let status: Int
    switch request.rawPath {
    case health.livenessPath:
      state = "live"
      status = 200
    case health.readinessPath:
      do {
        try await service.readinessCheck()
        state = "ready"
        status = 200
      } catch {
        state = "not-ready"
        status = 503
      }
    default: return nil
    }
    let data = Data("{\"status\":\"\(state)\"}\n".utf8)
    return HTTPTransportResponse(
      status: status,
      headers: [
        ("content-type", "application/json"),
        ("content-length", String(data.count)),
        ("cache-control", "no-store")
      ],
      body: request.method == "HEAD" ? nil : ObjectBodyStream(data: data)
    )
  }

  private func handleAuthorized(
    _ request: HTTPTransportRequest,
    requestID: String
  ) async throws -> HTTPTransportResponse {
    guard request.header("host").count == 1,
          let host = request.header("host").first else {
      throw SigV4Error.malformed
    }
    let hasHeaderAuthorization = !request.header("authorization").isEmpty
    let payloadHash: String
    if hasHeaderAuthorization {
      guard request.header("x-amz-content-sha256").count == 1,
            let value = request.header("x-amz-content-sha256").first else {
        throw SigV4Error.malformed
      }
      payloadHash = value
    } else {
      payloadHash = "UNSIGNED-PAYLOAD"
    }
    if payloadHash == "UNSIGNED-PAYLOAD", request.method != "GET", request.method != "HEAD" {
      throw SigV4Error.invalidPayloadPolicy
    }
    let routed = try router.route(
      RawS3RequestHead(
        method: request.method,
        rawPath: request.rawPath,
        rawQuery: request.rawQuery,
        host: host,
        headers: request.headers
      )
    )
    let signatureRequest = SigV4Request(
      method: request.method,
      rawPath: request.rawPath,
      rawQuery: request.rawQuery,
      headers: request.headers,
      payloadHash: payloadHash
    )
    let authentication = if hasHeaderAuthorization {
      try await verifier.verifyHeader(request: signatureRequest)
    } else {
      try await verifier.verifyPresigned(request: signatureRequest)
    }
    let listPrefix = routed.operation == .listObjectsV2 ? routed.query["prefix", default: ""] : nil
    let scope = try authorization.authorize(
      AuthorizationRequest(
        principalID: authentication.principalID,
        operation: routed.operation,
        bucket: routed.address.bucket,
        key: routed.address.key,
        listPrefix: listPrefix
      )
    )
    let context = RequestContext(
      requestID: requestID,
      principalID: authentication.principalID,
      deadline: Date().addingTimeInterval(TimeInterval(limits.requestTimeoutSeconds))
    )
    switch routed.operation {
    case .getObject:
      return try await get(request: request, routed: routed, context: context, requestID: requestID)
    case .headObject:
      return try await head(request: request, routed: routed, context: context, requestID: requestID)
    case .putObject:
      return try await put(
        request: request,
        routed: routed,
        payloadHash: payloadHash,
        context: context,
        requestID: requestID
      )
    case .deleteObject:
      return try await delete(request: request, routed: routed, context: context, requestID: requestID)
    case .listObjectsV2:
      return try await list(routed: routed, scope: scope, context: context, requestID: requestID)
    default:
      throw GatewayError(code: .notImplemented, safeMessage: "The requested operation is not implemented.")
    }
  }

  private func get(
    request: HTTPTransportRequest,
    routed: RoutedS3Operation,
    context: RequestContext,
    requestID: String
  ) async throws -> HTTPTransportResponse {
    let key = try requireKey(routed)
    let range = try parseRange(request.header("range"))
    let result = try await service.get(
      GetObjectRequest(
        bucket: routed.address.bucket,
        key: key,
        range: range,
        conditions: try readConditions(request)
      ),
      context: context
    )
    var headers = S3ResponseEncoder.metadataHeaders(result.metadata)
    if let range {
      let upper = min(range.upperBound ?? result.metadata.contentLength - 1, result.metadata.contentLength - 1)
      headers.removeAll { $0.0 == "content-length" }
      headers.append(("content-length", String(upper - range.lowerBound + 1)))
      headers.append(("content-range", "bytes \(range.lowerBound)-\(upper)/\(result.metadata.contentLength)"))
    }
    headers.append(("x-amz-request-id", requestID))
    return HTTPTransportResponse(status: range == nil ? 200 : 206, headers: headers, body: result.body)
  }

  private func head(
    request: HTTPTransportRequest,
    routed: RoutedS3Operation,
    context: RequestContext,
    requestID: String
  ) async throws -> HTTPTransportResponse {
    let metadata = try await service.head(
      HeadObjectRequest(
        bucket: routed.address.bucket,
        key: try requireKey(routed),
        conditions: try readConditions(request)
      ),
      context: context
    )
    return HTTPTransportResponse(
      status: 200,
      headers: S3ResponseEncoder.metadataHeaders(metadata) + [("x-amz-request-id", requestID)]
    )
  }

  private func put(
    request: HTTPTransportRequest,
    routed: RoutedS3Operation,
    payloadHash: String,
    context: RequestContext,
    requestID: String
  ) async throws -> HTTPTransportResponse {
    let contentLength = try optionalSingleInt64(request.header("content-length"), name: "Content-Length")
    if let contentLength, contentLength > limits.maximumObjectBytes {
      throw GatewayError(code: .invalidRequest, safeMessage: "The object exceeds the configured size limit.")
    }
    let metadata = try userMetadata(request)
    var expectedChecksums = try checksumHeaders(request)
    if let signatureChecksum = Self.sha256Checksum(hex: payloadHash) {
      expectedChecksums.append(signatureChecksum)
    }
    let result = try await service.put(
      PutObjectRequest(
        bucket: routed.address.bucket,
        key: try requireKey(routed),
        body: request.body,
        knownContentLength: contentLength,
        contentType: try contentType(request),
        userMetadata: metadata,
        expectedChecksums: expectedChecksums,
        expectedContentMD5: try contentMD5(request),
        conditions: try writeConditions(request)
      ),
      context: context
    )
    return HTTPTransportResponse(
      status: 200,
      headers: [("etag", result.metadata.entityTag.rawValue), ("x-amz-request-id", requestID)]
    )
  }

  private func delete(
    request: HTTPTransportRequest,
    routed: RoutedS3Operation,
    context: RequestContext,
    requestID: String
  ) async throws -> HTTPTransportResponse {
    try await service.delete(
      DeleteObjectRequest(
        bucket: routed.address.bucket,
        key: try requireKey(routed),
        conditions: try writeConditions(request)
      ),
      context: context
    )
    return HTTPTransportResponse(status: 204, headers: [("x-amz-request-id", requestID)])
  }

  private func list(
    routed: RoutedS3Operation,
    scope: AuthorizedScope,
    context: RequestContext,
    requestID: String
  ) async throws -> HTTPTransportResponse {
    let prefix = routed.query["prefix", default: ""]
    let delimiter = routed.query["delimiter"].flatMap {
      $0.isEmpty ? nil : $0
    }
    let maximumKeys = try routed.query["max-keys"].map {
      guard let value = Int($0) else { throw GatewayError(code: .invalidArgument, safeMessage: "max-keys is invalid.") }
      return value
    } ?? 1_000
    let encodingType = routed.query["encoding-type"]
    guard encodingType == nil || encodingType == "url" else {
      throw GatewayError(
        code: .invalidArgument,
        safeMessage: "encoding-type must be url."
      )
    }
    let backendKind = await service.backendKind
    let orderingState: String?
    if let token = routed.query["continuation-token"] {
      orderingState = try await pagination.verify(
        token,
        expectedBackend: backendKind,
        expectedScope: scope,
        requestedPrefix: prefix,
        delimiter: delimiter
      ).orderingState
    } else {
      orderingState = nil
    }
    let result = try await service.list(
      ListObjectsV2Request(
        bucket: routed.address.bucket,
        prefix: prefix,
        delimiter: delimiter,
        maximumKeys: maximumKeys,
        continuationToken: orderingState
      ),
      context: context
    )
    try validateListResult(
      result,
      scope: scope,
      requestedPrefix: prefix,
      maximumKeys: maximumKeys
    )
    let nextToken: String?
    if let state = result.nextContinuationToken {
      nextToken = try await pagination.issue(
        backend: backendKind,
        scope: scope,
        requestedPrefix: prefix,
        delimiter: delimiter,
        orderingState: state
      )
    } else {
      nextToken = nil
    }
    return S3ResponseEncoder.list(
      result: result,
      bucket: routed.address.bucket,
      prefix: prefix,
      delimiter: delimiter,
      maximumKeys: maximumKeys,
      encodingType: encodingType,
      nextToken: nextToken,
      requestID: requestID
    )
  }

  private func validateListResult(
    _ result: ListObjectsV2Result,
    scope: AuthorizedScope,
    requestedPrefix: String,
    maximumKeys: Int
  ) throws {
    guard result.objects.count + result.commonPrefixes.count <= maximumKeys,
          result.objects.map(\.key.rawValue).allSatisfy({ key in
            Self.isListValue(key, within: scope, requestedPrefix: requestedPrefix)
          }),
          result.commonPrefixes.allSatisfy({ prefix in
            Self.isListValue(prefix, within: scope, requestedPrefix: requestedPrefix)
          }) else {
      throw BackendError.consistencyFailure
    }
  }

  private static func isListValue(
    _ value: String,
    within scope: AuthorizedScope,
    requestedPrefix: String
  ) -> Bool {
    guard value.hasPrefix(requestedPrefix) else { return false }
    guard let grantPrefix = scope.grantPrefix else { return true }
    return value == grantPrefix || value.hasPrefix(grantPrefix + "/")
  }

  private func requireKey(_ routed: RoutedS3Operation) throws -> ObjectKey {
    guard let key = routed.address.key else {
      throw GatewayError(code: .invalidRequest, safeMessage: "An object key is required.")
    }
    return key
  }

  private func readConditions(_ request: HTTPTransportRequest) throws -> ReadConditions {
    let matchValues = request.header("if-match")
    let noneMatchValues = request.header("if-none-match")
    return ReadConditions(
      ifMatch: matchValues == ["*"] ? [] : try entityTags(matchValues),
      ifNoneMatch: noneMatchValues == ["*"] ? [] : try entityTags(noneMatchValues),
      ifMatchAny: matchValues == ["*"],
      ifNoneMatchAny: noneMatchValues == ["*"],
      ifModifiedSince: try optionalHTTPDate(request.header("if-modified-since"), name: "If-Modified-Since"),
      ifUnmodifiedSince: try optionalHTTPDate(request.header("if-unmodified-since"), name: "If-Unmodified-Since")
    )
  }

  private func writeConditions(_ request: HTTPTransportRequest) throws -> WriteConditions {
    let matches = try entityTags(request.header("if-match"))
    let noneMatches = request.header("if-none-match")
    guard matches.count <= 1,
          noneMatches.isEmpty || noneMatches == ["*"] else {
      throw GatewayError(code: .invalidRequest, safeMessage: "The write condition is invalid.")
    }
    return WriteConditions(ifMatch: matches.first, requireAbsent: noneMatches == ["*"])
  }

  private func entityTags(_ values: [String]) throws -> [EntityTag] {
    guard values.count <= 1 else { throw GatewayError(code: .invalidRequest, safeMessage: "A condition header was repeated.") }
    return try values.flatMap { line in
      try line.split(separator: ",").map { value in
        guard let tag = EntityTag(rawValue: value.trimmingCharacters(in: .whitespaces)) else {
          throw GatewayError(code: .invalidRequest, safeMessage: "An entity tag is invalid.")
        }
        return tag
      }
    }
  }

  private func parseRange(_ values: [String]) throws -> ByteRange? {
    guard values.count <= 1 else { throw GatewayError(code: .invalidRange, safeMessage: "Multiple ranges are unsupported.") }
    guard let value = values.first else { return nil }
    guard value.hasPrefix("bytes="), !value.contains(",") else {
      throw GatewayError(code: .notImplemented, safeMessage: "Only one byte range is supported.")
    }
    let bounds = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
    guard bounds.count == 2, let lower = Int64(bounds[0]) else {
      throw GatewayError(code: .invalidRange, safeMessage: "The byte range is invalid.")
    }
    let upper = bounds[1].isEmpty ? nil : Int64(bounds[1])
    return try ByteRange(lowerBound: lower, upperBound: upper)
  }

  private func userMetadata(_ request: HTTPTransportRequest) throws -> [String: String] {
    var result: [String: String] = [:]
    var bytes = 0
    for (name, values) in request.headers where name.lowercased().hasPrefix("x-amz-meta-") {
      guard values.count == 1 else { throw GatewayError(code: .invalidRequest, safeMessage: "User metadata was repeated.") }
      let key = String(name.lowercased().dropFirst("x-amz-meta-".count))
      guard !key.isEmpty, result[key] == nil, !values[0].contains(where: { $0.isNewline || $0.asciiValue.map({ $0 < 32 }) == true }) else {
        throw GatewayError(code: .invalidRequest, safeMessage: "User metadata is invalid.")
      }
      bytes += key.utf8.count + values[0].utf8.count
      guard bytes <= 8 * 1_024 else { throw GatewayError(code: .invalidRequest, safeMessage: "User metadata is too large.") }
      result[key] = values[0]
    }
    return result
  }

  private func checksumHeaders(_ request: HTTPTransportRequest) throws -> [ObjectChecksum] {
    var result: [ObjectChecksum] = []
    if let value = try optionalSingle(request.header("x-amz-checksum-sha256"), name: "x-amz-checksum-sha256") {
      guard let decoded = Data(base64Encoded: value),
            decoded.count == 32,
            decoded.base64EncodedString() == value else {
        throw GatewayError(code: .invalidRequest, safeMessage: "x-amz-checksum-sha256 is invalid.")
      }
      result.append(ObjectChecksum(algorithm: .sha256, base64Value: value))
    }
    if let value = try optionalSingle(request.header("x-amz-checksum-crc32c"), name: "x-amz-checksum-crc32c") {
      guard let decoded = Data(base64Encoded: value),
            decoded.count == 4,
            decoded.base64EncodedString() == value else {
        throw GatewayError(code: .invalidRequest, safeMessage: "x-amz-checksum-crc32c is invalid.")
      }
      result.append(ObjectChecksum(algorithm: .crc32c, base64Value: value))
    }
    return result
  }

  private func contentMD5(_ request: HTTPTransportRequest) throws -> String? {
    guard let value = try optionalSingle(request.header("content-md5"), name: "Content-MD5") else { return nil }
    guard let decoded = Data(base64Encoded: value),
          decoded.count == 16,
          decoded.base64EncodedString() == value else {
      throw GatewayError(code: .invalidRequest, safeMessage: "Content-MD5 is invalid.")
    }
    return value
  }

  private func contentType(_ request: HTTPTransportRequest) throws -> String? {
    guard let value = try optionalSingle(request.header("content-type"), name: "Content-Type") else { return nil }
    guard !value.isEmpty,
          value.utf8.count <= 1_024,
          !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
      throw GatewayError(code: .invalidRequest, safeMessage: "Content-Type is invalid.")
    }
    return value
  }

  private func optionalSingle(_ values: [String], name: String) throws -> String? {
    guard values.count <= 1 else { throw GatewayError(code: .invalidRequest, safeMessage: "\(name) was repeated.") }
    return values.first
  }

  private func optionalSingleInt64(_ values: [String], name: String) throws -> Int64? {
    guard let value = try optionalSingle(values, name: name) else { return nil }
    guard let parsed = Int64(value), parsed >= 0 else {
      throw GatewayError(code: .invalidRequest, safeMessage: "\(name) is invalid.")
    }
    return parsed
  }

  private func optionalHTTPDate(_ values: [String], name: String) throws -> Date? {
    guard let value = try optionalSingle(values, name: name) else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    guard let date = formatter.date(from: value) else {
      throw GatewayError(code: .invalidRequest, safeMessage: "\(name) is invalid.")
    }
    return date
  }

  private static func sha256Checksum(hex: String) -> ObjectChecksum? {
    guard hex.count == 64 else { return nil }
    var bytes = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return ObjectChecksum(algorithm: .sha256, base64Value: bytes.base64EncodedString())
  }
}
