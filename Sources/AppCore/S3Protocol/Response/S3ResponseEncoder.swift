import Foundation

enum S3ResponseEncoder {
  static func error(_ error: GatewayError, requestID: String) -> HTTPTransportResponse {
    let status: Int
    switch error.code {
    case .accessDenied: status = 403
    case .badDigest, .invalidArgument, .invalidRequest: status = 400
    case .invalidRange: status = 416
    case .noSuchBucket, .noSuchKey: status = 404
    case .notModified: status = 304
    case .notImplemented: status = 501
    case .preconditionFailed: status = 412
    case .requestTimeout: status = 408
    case .serviceUnavailable, .slowDown: status = 503
    case .internalError: status = 500
    }
    if status == 304 {
      return HTTPTransportResponse(status: status, headers: [("x-amz-request-id", requestID)])
    }
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Error><Code>\(escape(error.code.rawValue))</Code><Message>\(escape(error.safeMessage))</Message><RequestId>\(escape(requestID))</RequestId></Error>
    """
    return HTTPTransportResponse(
      status: status,
      headers: [("content-type", "application/xml"), ("x-amz-request-id", requestID)],
      data: Data(xml.utf8)
    )
  }

  static func list(
    result: ListObjectsV2Result,
    bucket: BucketName,
    prefix: String,
    delimiter: String?,
    maximumKeys: Int,
    encodingType: String?,
    nextToken: String?,
    requestID: String
  ) -> HTTPTransportResponse {
    let objects = result.objects.map { object in
      "<Contents>" +
        "<Key>\(escape(listValue(object.key.rawValue, encodingType: encodingType)))</Key>" +
        "<LastModified>\(iso8601(object.lastModified))</LastModified>" +
        "<ETag>\(escape(object.entityTag.rawValue))</ETag>" +
        "<Size>\(object.size)</Size>" +
        "<StorageClass>STANDARD</StorageClass>" +
        "</Contents>"
    }.joined()
    let commonPrefixes = result.commonPrefixes.map {
      "<CommonPrefixes><Prefix>\(escape(listValue($0, encodingType: encodingType)))</Prefix></CommonPrefixes>"
    }.joined()
    let token = nextToken.map { "<NextContinuationToken>\(escape($0))</NextContinuationToken>" } ?? ""
    let delimiterXML = delimiter.map {
      "<Delimiter>\(escape(listValue($0, encodingType: encodingType)))</Delimiter>"
    } ?? ""
    let encodingXML = encodingType.map { "<EncodingType>\(escape($0))</EncodingType>" } ?? ""
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Name>\(escape(bucket.rawValue))</Name>
    <Prefix>\(escape(listValue(prefix, encodingType: encodingType)))</Prefix>
    \(delimiterXML)\(encodingXML)
    <KeyCount>\(result.objects.count + result.commonPrefixes.count)</KeyCount>
    <MaxKeys>\(maximumKeys)</MaxKeys><IsTruncated>\(nextToken != nil)</IsTruncated>
    \(objects)\(commonPrefixes)\(token)
    </ListBucketResult>
    """
    return HTTPTransportResponse(
      status: 200,
      headers: [("content-type", "application/xml"), ("x-amz-request-id", requestID)],
      data: Data(xml.utf8)
    )
  }

  static func metadataHeaders(_ metadata: ObjectMetadata) -> [(String, String)] {
    var headers: [(String, String)] = [
      ("content-length", String(metadata.contentLength)),
      ("etag", metadata.entityTag.rawValue),
      ("last-modified", httpDate(metadata.lastModified))
    ]
    if let contentType = metadata.contentType { headers.append(("content-type", contentType)) }
    for (name, value) in metadata.userMetadata.sorted(by: { $0.key < $1.key }) {
      headers.append(("x-amz-meta-\(name)", value))
    }
    for checksum in metadata.checksums {
      switch checksum.algorithm {
      case .sha256: headers.append(("x-amz-checksum-sha256", checksum.base64Value))
      case .crc32c: headers.append(("x-amz-checksum-crc32c", checksum.base64Value))
      }
    }
    return headers
  }

  private static func escape(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }

  private static func listValue(
    _ value: String,
    encodingType: String?
  ) -> String {
    guard encodingType == "url" else { return value }
    return value.utf8.map { byte in
      if (65...90).contains(byte) ||
         (97...122).contains(byte) ||
         (48...57).contains(byte) ||
         [45, 46, 95, 126].contains(byte) {
        return String(Character(UnicodeScalar(byte)))
      }
      return String(format: "%%%02X", byte)
    }.joined()
  }

  private static func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }

  private static func httpDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    return formatter.string(from: date)
  }
}
