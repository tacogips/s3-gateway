import Crypto
import Foundation

enum SigV4Canonicalizer {
  static func canonicalRequest(
    request: SigV4Request,
    signedHeaders: [String],
    excludingSignatureQuery: Bool = false
  ) throws -> String {
    let headerBlock = try canonicalHeaders(request: request, signedHeaders: signedHeaders)
    let query = try canonicalQuery(request.rawQuery, excludingSignature: excludingSignatureQuery)
    return [
      request.method,
      try canonicalURI(request.rawPath),
      query,
      headerBlock,
      signedHeaders.joined(separator: ";"),
      request.payloadHash
    ].joined(separator: "\n")
  }

  static func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  static func canonicalURI(_ rawPath: String) throws -> String {
    guard rawPath.hasPrefix("/") else { throw SigV4Error.malformed }
    return try encode(rawPath, preserveSlash: true)
  }

  static func canonicalQuery(_ rawQuery: String, excludingSignature: Bool) throws -> String {
    guard !rawQuery.isEmpty else { return "" }
    var fields: [(String, String)] = []
    for field in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
      let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let name = try encode(String(parts[0]), preserveSlash: false)
      let value = try encode(parts.count == 2 ? String(parts[1]) : "", preserveSlash: false)
      if excludingSignature, name.caseInsensitiveCompare("X-Amz-Signature") == .orderedSame { continue }
      fields.append((name, value))
    }
    fields.sort { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
    return fields.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
  }

  private static func canonicalHeaders(request: SigV4Request, signedHeaders: [String]) throws -> String {
    guard signedHeaders == signedHeaders.sorted(), Set(signedHeaders).count == signedHeaders.count else {
      throw SigV4Error.malformed
    }
    return try signedHeaders.map { name in
      guard name == name.lowercased(), !name.isEmpty else { throw SigV4Error.malformed }
      let values = request.values(for: name)
      guard !values.isEmpty else { throw SigV4Error.missingSignedHeader }
      let normalized = values.map(normalizeHeaderValue).joined(separator: ",")
      return "\(name):\(normalized)\n"
    }.joined()
  }

  private static func normalizeHeaderValue(_ value: String) -> String {
    value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private static func encode(_ value: String, preserveSlash: Bool) throws -> String {
    let bytes = Array(value.utf8)
    var result = ""
    var index = 0
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 37 {
        guard index + 2 < bytes.count,
              let first = hexValue(bytes[index + 1]),
              let second = hexValue(bytes[index + 2]) else {
          throw SigV4Error.malformed
        }
        result += String(format: "%%%02X", first * 16 + second)
        index += 3
      } else if isUnreserved(byte) || preserveSlash && byte == 47 {
        result.append(Character(UnicodeScalar(byte)))
        index += 1
      } else {
        result += String(format: "%%%02X", byte)
        index += 1
      }
    }
    return result
  }

  private static func isUnreserved(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte)
  }

  private static func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }
}
