import Crypto
import Foundation

public actor S3Backend: ObjectStoreBackend {
  public nonisolated let kind: BackendKind = .s3

  private let configuration: UpstreamS3Configuration
  private let signer: UpstreamS3Signer
  private let client: any UpstreamHTTPClient
  private let maximumChunkBytes: Int
  private let maximumXMLBytes: Int

  public init(
    configuration: UpstreamS3Configuration,
    credentials: any UpstreamCredentialProviding,
    maximumChunkBytes: Int = 64 * 1_024,
    maximumInFlightBytes: Int = 8 * 1_024 * 1_024,
    maximumHeaderBytes: Int = 32 * 1_024,
    maximumXMLBytes: Int = 1 * 1_024 * 1_024,
    requestTimeoutSeconds: Int = 300
  ) throws {
    try configuration.validate()
    self.configuration = configuration
    signer = UpstreamS3Signer(configuration: configuration, credentials: credentials)
    client = try NIOUpstreamHTTPClient(
      maximumChunkBytes: maximumChunkBytes,
      maximumInFlightBytes: maximumInFlightBytes,
      maximumHeaderBytes: maximumHeaderBytes,
      requestTimeoutSeconds: requestTimeoutSeconds,
      trustedCAPath: configuration.trustedCAPath
    )
    self.maximumChunkBytes = maximumChunkBytes
    self.maximumXMLBytes = maximumXMLBytes
  }

  init(
    configuration: UpstreamS3Configuration,
    credentials: any UpstreamCredentialProviding,
    client: any UpstreamHTTPClient,
    maximumChunkBytes: Int = 64 * 1_024,
    maximumXMLBytes: Int = 1 * 1_024 * 1_024
  ) {
    self.configuration = configuration
    signer = UpstreamS3Signer(configuration: configuration, credentials: credentials)
    self.client = client
    self.maximumChunkBytes = maximumChunkBytes
    self.maximumXMLBytes = maximumXMLBytes
  }

  public func capabilities() async -> BackendCapabilities {
    BackendCapabilities(
      supported: [
        .rangeRead, .conditionalRead, .conditionalWrite, .listPagination,
        .userMetadata, .strongReadAfterWrite, .checksumSHA256, .checksumCRC32C
      ],
      checksumAlgorithms: [.sha256, .crc32c],
      consistencyDescription: "preserves the configured upstream S3 consistency contract"
    )
  }

  public func readinessCheck() async throws {
    guard let bucketText = configuration.bucketMappings.keys.sorted().first,
          let bucket = BucketName(rawValue: bucketText) else {
      throw BackendError.unavailable(retryable: false)
    }
    let request = try await signer.signedRequest(method: "HEAD", bucket: bucket, key: nil)
    let response = try await executeWithRetry(request)
    guard (200...299).contains(response.status) else {
      throw BackendError.unavailable(retryable: response.status == 429 || response.status >= 500)
    }
  }

  public func getObject(_ request: GetObjectRequest, context: RequestContext) async throws -> GetObjectResult {
    try check(context)
    var headers = conditionHeaders(request.conditions)
    if let range = request.range {
      headers.append(("range", "bytes=\(range.lowerBound)-\(range.upperBound.map(String.init) ?? "")"))
    }
    let upstream = try await signer.signedRequest(
      method: "GET",
      bucket: request.bucket,
      key: request.key,
      additionalHeaders: headers,
      deadline: context.deadline
    )
    let response = try await executeWithRetry(upstream)
    guard response.status == 200 || response.status == 206 else { throw mapStatus(response.status) }
    return GetObjectResult(
      metadata: try metadata(from: response),
      body: response.body,
      servedRange: request.range
    )
  }

  public func headObject(_ request: HeadObjectRequest, context: RequestContext) async throws -> ObjectMetadata {
    try check(context)
    let upstream = try await signer.signedRequest(
      method: "HEAD",
      bucket: request.bucket,
      key: request.key,
      additionalHeaders: conditionHeaders(request.conditions),
      deadline: context.deadline
    )
    let response = try await executeWithRetry(upstream)
    guard response.status == 200 else { throw mapStatus(response.status) }
    return try metadata(from: response)
  }

  public func putObject(_ request: PutObjectRequest, context: RequestContext) async throws -> PutObjectResult {
    try check(context)
    let staged = try await stage(request, deadline: context.deadline)
    defer { try? FileManager.default.removeItem(at: staged.url) }
    var headers = writeConditionHeaders(request.conditions)
    if let contentType = request.contentType { headers.append(("content-type", contentType)) }
    for (name, value) in request.userMetadata { headers.append(("x-amz-meta-\(name)", value)) }
    for checksum in request.expectedChecksums {
      switch checksum.algorithm {
      case .sha256: headers.append(("x-amz-checksum-sha256", checksum.base64Value))
      case .crc32c: headers.append(("x-amz-checksum-crc32c", checksum.base64Value))
      }
    }
    if let contentMD5 = request.expectedContentMD5 { headers.append(("content-md5", contentMD5)) }
    let response = try await executeStagedPutWithRetry(
      bucket: request.bucket,
      key: request.key,
      headers: headers,
      staged: staged,
      deadline: context.deadline
    )
    guard (200...299).contains(response.status) else { throw mapStatus(response.status) }
    guard let etagText = try singleHeader(response, name: "etag", required: true),
          let etag = EntityTag(rawValue: etagText) else {
      throw BackendError.consistencyFailure
    }
    return PutObjectResult(
      metadata: ObjectMetadata(
        contentType: request.contentType,
        contentLength: staged.length,
        lastModified: Date(),
        entityTag: etag,
        userMetadata: request.userMetadata,
        checksums: request.expectedChecksums,
        versionToken: ObjectVersionToken(rawValue: etag.rawValue)
      )
    )
  }

  public func deleteObject(_ request: DeleteObjectRequest, context: RequestContext) async throws {
    try check(context)
    let upstream = try await signer.signedRequest(
      method: "DELETE",
      bucket: request.bucket,
      key: request.key,
      additionalHeaders: writeConditionHeaders(request.conditions),
      deadline: context.deadline
    )
    let response = try await executeWithRetry(upstream)
    guard (200...299).contains(response.status) || response.status == 404 else { throw mapStatus(response.status) }
  }

  public func listObjectsV2(
    _ request: ListObjectsV2Request,
    context: RequestContext
  ) async throws -> ListObjectsV2Result {
    try check(context)
    guard (0...1_000).contains(request.maximumKeys) else {
      throw BackendError.invalidRequest("max-keys must be between 0 and 1000.")
    }
    var query = [("list-type", "2"), ("prefix", request.prefix), ("max-keys", String(request.maximumKeys))]
    if let delimiter = request.delimiter, !delimiter.isEmpty {
      query.append(("delimiter", delimiter))
    }
    if let token = request.continuationToken { query.append(("continuation-token", token)) }
    let upstream = try await signer.signedRequest(
      method: "GET",
      bucket: request.bucket,
      key: nil,
      query: query,
      deadline: context.deadline
    )
    let response = try await executeWithRetry(upstream)
    guard response.status == 200 else { throw mapStatus(response.status) }
    let data = try await collect(response.body, maximumBytes: maximumXMLBytes)
    return try S3ListXMLParser.parse(data)
  }

  private func metadata(from response: UpstreamHTTPResponse) throws -> ObjectMetadata {
    guard let responseLengthText = try singleHeader(
            response,
            name: "content-length",
            required: true
          ),
          let responseLength = Int64(responseLengthText),
          responseLength >= 0,
          let etagText = try singleHeader(response, name: "etag", required: true),
          let etag = EntityTag(rawValue: etagText),
          let lastModifiedText = try singleHeader(
            response,
            name: "last-modified",
            required: true
          ),
          let lastModified = Self.httpDate(lastModifiedText) else {
      throw BackendError.consistencyFailure
    }
    let length: Int64
    if response.status == 206 {
      guard let contentRange = try singleHeader(
              response,
              name: "content-range",
              required: true
            ),
            let totalText = contentRange.split(separator: "/", maxSplits: 1).last,
            let total = Int64(totalText),
            total >= responseLength else {
        throw BackendError.consistencyFailure
      }
      length = total
    } else {
      length = responseLength
    }
    var userMetadata: [String: String] = [:]
    for (name, values) in response.headers where name.lowercased().hasPrefix("x-amz-meta-") {
      let normalized = String(name.lowercased().dropFirst(11))
      guard !normalized.isEmpty,
            values.count == 1,
            userMetadata[normalized] == nil else {
        throw BackendError.consistencyFailure
      }
      userMetadata[normalized] = values[0]
    }
    var checksums: [ObjectChecksum] = []
    if let value = try singleHeader(
      response,
      name: "x-amz-checksum-sha256",
      required: false
    ) {
      checksums.append(ObjectChecksum(algorithm: .sha256, base64Value: value))
    }
    if let value = try singleHeader(
      response,
      name: "x-amz-checksum-crc32c",
      required: false
    ) {
      checksums.append(ObjectChecksum(algorithm: .crc32c, base64Value: value))
    }
    return ObjectMetadata(
      contentType: try singleHeader(response, name: "content-type", required: false),
      contentLength: length,
      lastModified: lastModified,
      entityTag: etag,
      userMetadata: userMetadata,
      checksums: checksums,
      versionToken: ObjectVersionToken(rawValue: etag.rawValue + ":" + String(length))
    )
  }

  private func stage(
    _ request: PutObjectRequest,
    deadline: Date
  ) async throws -> StagedUpload {
    let directory = configuration.stagingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.temporaryDirectory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("swift-s3-gateway-\(UUID().uuidString).upload")
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
      throw BackendError.capacityExceeded
    }
    do {
      let accumulator = S3StagingAccumulator(
        file: try FileHandle(forWritingTo: url),
        expectedLength: request.knownContentLength,
        deadline: deadline
      )
      try await request.body.consume { try await accumulator.append($0) }
      let result = try await accumulator.finish()
      for expected in request.expectedChecksums {
        let actual = switch expected.algorithm {
        case .sha256: result.sha256Base64
        case .crc32c: result.crc32cBase64
        }
        guard expected.base64Value == actual else { throw BackendError.checksumMismatch }
      }
      if let expected = request.expectedContentMD5, expected != result.md5Base64 {
        throw BackendError.checksumMismatch
      }
      return StagedUpload(url: url, length: result.length, sha256Hex: result.sha256Hex)
    } catch is CancellationError {
      try? FileManager.default.removeItem(at: url)
      throw BackendError.cancelled
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  private func conditionHeaders(_ conditions: ReadConditions) -> [(String, String)] {
    var headers: [(String, String)] = []
    if conditions.ifMatchAny {
      headers.append(("if-match", "*"))
    } else if !conditions.ifMatch.isEmpty {
      headers.append(("if-match", conditions.ifMatch.map(\.rawValue).joined(separator: ",")))
    }
    if conditions.ifNoneMatchAny {
      headers.append(("if-none-match", "*"))
    } else if !conditions.ifNoneMatch.isEmpty {
      headers.append(("if-none-match", conditions.ifNoneMatch.map(\.rawValue).joined(separator: ",")))
    }
    if let date = conditions.ifModifiedSince { headers.append(("if-modified-since", Self.formatHTTPDate(date))) }
    if let date = conditions.ifUnmodifiedSince { headers.append(("if-unmodified-since", Self.formatHTTPDate(date))) }
    return headers
  }

  private func writeConditionHeaders(_ conditions: WriteConditions) -> [(String, String)] {
    var headers: [(String, String)] = []
    if let etag = conditions.ifMatch { headers.append(("if-match", etag.rawValue)) }
    if conditions.requireAbsent { headers.append(("if-none-match", "*")) }
    return headers
  }

  private func mapStatus(_ status: Int) -> BackendError {
    switch status {
    case 304: .notModified
    case 403: .accessDenied
    case 404: .notFound
    case 412: .conditionFailed
    case 416: .rangeNotSatisfiable
    case 429, 503: .unavailable(retryable: true)
    case 500...599: .unavailable(retryable: true)
    default: .invalidRequest("The upstream S3 service rejected the request.")
    }
  }

  private func check(_ context: RequestContext) throws {
    if Task.isCancelled { throw BackendError.cancelled }
    if context.deadline < Date() { throw BackendError.deadlineExceeded }
  }

  private func collect(_ stream: ObjectBodyStream, maximumBytes: Int) async throws -> Data {
    let collector = BoundedDataCollector(maximumBytes: maximumBytes)
    try await stream.consume { try await collector.append($0) }
    return await collector.data
  }

  private func executeWithRetry(_ request: UpstreamHTTPRequest, maximumAttempts: Int = 3) async throws -> UpstreamHTTPResponse {
    precondition(request.body == nil, "automatic retries require a replayable request")
    var lastError: (any Error)?
    for attempt in 1...maximumAttempts {
      try checkRetryState(deadline: request.deadline)
      do {
        let response = try await client.execute(request)
        if response.status < 500 && response.status != 429 { return response }
        _ = try? await collect(response.body, maximumBytes: 64 * 1_024)
        lastError = BackendError.unavailable(retryable: true)
      } catch is CancellationError {
        throw BackendError.cancelled
      } catch let error as BackendError where !Self.isRetryable(error) {
        throw error
      } catch {
        lastError = error
      }
      if attempt < maximumAttempts {
        try await retryDelay(attempt: attempt, deadline: request.deadline)
      }
    }
    throw lastError ?? BackendError.unavailable(retryable: true)
  }

  private func executeStagedPutWithRetry(
    bucket: BucketName,
    key: ObjectKey,
    headers: [(String, String)],
    staged: StagedUpload,
    deadline: Date,
    maximumAttempts: Int = 3
  ) async throws -> UpstreamHTTPResponse {
    var lastError: (any Error)?
    for attempt in 1...maximumAttempts {
      try checkRetryState(deadline: deadline)
      do {
        let body = Self.fileStream(url: staged.url, size: staged.length, maximumChunkBytes: maximumChunkBytes)
        let request = try await signer.signedRequest(
          method: "PUT",
          bucket: bucket,
          key: key,
          additionalHeaders: headers,
          body: body,
          contentLength: staged.length,
          payloadHash: staged.sha256Hex,
          deadline: deadline
        )
        let response = try await client.execute(request)
        if response.status < 500 && response.status != 429 { return response }
        _ = try? await collect(response.body, maximumBytes: 64 * 1_024)
        lastError = BackendError.unavailable(retryable: true)
      } catch is CancellationError {
        throw BackendError.cancelled
      } catch let error as BackendError where !Self.isRetryable(error) {
        throw error
      } catch {
        lastError = error
      }
      if attempt < maximumAttempts {
        try await retryDelay(attempt: attempt, deadline: deadline)
      }
    }
    throw lastError ?? BackendError.unavailable(retryable: true)
  }

  private static func isRetryable(_ error: BackendError) -> Bool {
    if case .unavailable(let retryable) = error { return retryable }
    return false
  }

  private func checkRetryState(deadline: Date?) throws {
    if Task.isCancelled { throw BackendError.cancelled }
    if let deadline, deadline <= Date() {
      throw BackendError.deadlineExceeded
    }
  }

  private func retryDelay(attempt: Int, deadline: Date?) async throws {
    try checkRetryState(deadline: deadline)
    let delay = TimeInterval(50 * attempt) / 1_000
    let remaining = deadline?.timeIntervalSinceNow ?? delay
    guard remaining > 0 else {
      throw BackendError.deadlineExceeded
    }
    do {
      try await Task.sleep(
        for: .milliseconds(Int64(max(1.0, min(delay, remaining) * 1_000)))
      )
    } catch {
      throw BackendError.cancelled
    }
    try checkRetryState(deadline: deadline)
  }

  private func singleHeader(
    _ response: UpstreamHTTPResponse,
    name: String,
    required: Bool
  ) throws -> String? {
    let values = response.headers
      .filter { $0.key.caseInsensitiveCompare(name) == .orderedSame }
      .flatMap(\.value)
    guard values.count <= 1, !required || values.count == 1 else {
      throw BackendError.consistencyFailure
    }
    return values.first
  }

  private static func fileStream(url: URL, size: Int64, maximumChunkBytes: Int) -> ObjectBodyStream {
    let source = StagedFileBodySource(
      url: url,
      size: size,
      maximumChunkBytes: maximumChunkBytes
    )
    return ObjectBodyStream(
      maximumChunkBytes: maximumChunkBytes,
      stream: AsyncThrowingStream(unfolding: { try await source.next() })
    )
  }

  private static func httpDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    return formatter.date(from: value)
  }

  private static func formatHTTPDate(_ value: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    return formatter.string(from: value)
  }
}

private struct StagedUpload: Sendable {
  let url: URL
  let length: Int64
  let sha256Hex: String
}

private actor S3StagingAccumulator {
  private let file: FileHandle
  private let expectedLength: Int64?
  private let deadline: Date
  private var length: Int64 = 0
  private var md5 = Insecure.MD5()
  private var sha256 = SHA256()
  private var crc32c = CRC32C()

  init(file: FileHandle, expectedLength: Int64?, deadline: Date) {
    self.file = file
    self.expectedLength = expectedLength
    self.deadline = deadline
  }

  func append(_ data: Data) throws {
    try Task.checkCancellation()
    guard Date() <= deadline else { throw BackendError.deadlineExceeded }
    length += Int64(data.count)
    if let expectedLength, length > expectedLength { throw BackendError.invalidRequest("Body exceeds Content-Length.") }
    sha256.update(data: data)
    md5.update(data: data)
    crc32c.update(data)
    try file.write(contentsOf: data)
  }

  func finish() throws -> S3StagingDigest {
    guard Date() <= deadline else { throw BackendError.deadlineExceeded }
    if let expectedLength, length != expectedLength { throw BackendError.invalidRequest("Body length does not match Content-Length.") }
    try file.synchronize()
    try file.close()
    let sha256Data = Data(sha256.finalize())
    return S3StagingDigest(
      length: length,
      sha256Base64: sha256Data.base64EncodedString(),
      sha256Hex: sha256Data.map { String(format: "%02x", $0) }.joined(),
      md5Base64: Data(md5.finalize()).base64EncodedString(),
      crc32cBase64: crc32c.base64Value()
    )
  }
}

private actor StagedFileBodySource {
  private let url: URL
  private let size: Int64
  private let maximumChunkBytes: Int
  private var file: FileHandle?
  private var offset: Int64 = 0
  private var completed = false

  init(url: URL, size: Int64, maximumChunkBytes: Int) {
    self.url = url
    self.size = size
    self.maximumChunkBytes = maximumChunkBytes
  }

  deinit {
    try? file?.close()
  }

  func next() throws -> Data? {
    guard !completed else { return nil }
    do {
      try Task.checkCancellation()
      guard offset < size else {
        try file?.close()
        file = nil
        completed = true
        return nil
      }
      let file = try openIfNeeded()
      let count = min(maximumChunkBytes, Int(size - offset))
      guard let data = try file.read(upToCount: count), !data.isEmpty else {
        throw BackendError.consistencyFailure
      }
      offset += Int64(data.count)
      return data
    } catch {
      try? file?.close()
      file = nil
      completed = true
      throw error
    }
  }

  private func openIfNeeded() throws -> FileHandle {
    if let file { return file }
    let opened = try FileHandle(forReadingFrom: url)
    file = opened
    return opened
  }
}

private struct S3StagingDigest: Sendable {
  let length: Int64
  let sha256Base64: String
  let sha256Hex: String
  let md5Base64: String
  let crc32cBase64: String
}

private actor BoundedDataCollector {
  private(set) var data = Data()
  let maximumBytes: Int

  init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

  func append(_ chunk: Data) throws {
    guard data.count + chunk.count <= maximumBytes else { throw BackendError.capacityExceeded }
    data.append(chunk)
  }
}

private enum S3ListXMLParser {
  static func parse(_ data: Data) throws -> ListObjectsV2Result {
    let delegate = S3ListDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else { throw BackendError.consistencyFailure }
    return try delegate.result()
  }
}

private final class S3ListDelegate: NSObject, XMLParserDelegate {
  private var current = ""
  private var elements: [String] = []
  private var key: String?
  private var size: Int64?
  private var lastModified: Date?
  private var etag: EntityTag?
  private var objects: [ListedObject] = []
  private var prefixes: [String] = []
  private var nextToken: String?
  private var invalid = false

  func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
    if elements.isEmpty, elementName != "ListBucketResult" {
      invalid = true
    }
    elements.append(elementName)
    current = ""
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) { current += string }

  func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
    switch elementName {
    case "Key": key = current
    case "Size": size = Int64(current)
    case "LastModified": lastModified = ISO8601DateFormatter().date(from: current)
    case "ETag": etag = EntityTag(rawValue: current)
    case "Contents":
      if let key, let objectKey = ObjectKey(rawValue: key), let size, let lastModified, let etag {
        objects.append(ListedObject(key: objectKey, size: size, lastModified: lastModified, entityTag: etag))
      } else {
        invalid = true
      }
      key = nil; size = nil; lastModified = nil; etag = nil
    case "Prefix" where elements.dropLast().last == "CommonPrefixes": prefixes.append(current)
    case "NextContinuationToken":
      if nextToken != nil {
        invalid = true
      } else {
        nextToken = current
      }
    default: break
    }
    _ = elements.popLast()
  }

  func result() throws -> ListObjectsV2Result {
    guard !invalid else { throw BackendError.consistencyFailure }
    return ListObjectsV2Result(
      objects: objects,
      commonPrefixes: prefixes,
      nextContinuationToken: nextToken
    )
  }
}
