import Foundation

public struct ResolvedS3Address: Equatable, Sendable {
  public let bucket: BucketName
  public let key: ObjectKey?
  public let style: AddressingStyle
}

public enum S3AddressingError: Error, Equatable, Sendable {
  case invalidHost
  case invalidPath
  case invalidBucket
  case ambiguous
}

public struct S3AddressingResolver: Sendable {
  private let styles: Set<AddressingStyle>
  private let virtualHostSuffixes: [String]

  public init(styles: Set<AddressingStyle>, virtualHostSuffixes: [String]) {
    self.styles = styles
    self.virtualHostSuffixes = virtualHostSuffixes
  }

  public func resolve(rawPath: String, host: String) throws -> ResolvedS3Address {
    let hostWithoutPort = Self.removePort(from: host.lowercased())
    let virtualMatches = virtualHostSuffixes.compactMap { suffix -> BucketName? in
      let suffix = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
      let marker = "." + suffix
      guard hostWithoutPort.hasSuffix(marker) else { return nil }
      return BucketName(rawValue: String(hostWithoutPort.dropLast(marker.count)))
    }
    if styles.contains(.virtualHost), virtualMatches.count == 1 {
      guard rawPath.hasPrefix("/") else { throw S3AddressingError.invalidPath }
      let encodedKey = String(rawPath.dropFirst())
      return ResolvedS3Address(
        bucket: virtualMatches[0],
        key: encodedKey.isEmpty ? nil : try ObjectKey(validating: Self.percentDecode(encodedKey)),
        style: .virtualHost
      )
    }
    if !virtualMatches.isEmpty { throw S3AddressingError.ambiguous }
    guard styles.contains(.path), rawPath.hasPrefix("/") else { throw S3AddressingError.invalidPath }
    let withoutSlash = rawPath.dropFirst()
    let separator = withoutSlash.firstIndex(of: "/")
    let encodedBucket = separator.map { String(withoutSlash[..<$0]) } ?? String(withoutSlash)
    guard let bucket = BucketName(rawValue: try Self.percentDecode(encodedBucket)) else {
      throw S3AddressingError.invalidBucket
    }
    let encodedKey = separator.map { String(withoutSlash[withoutSlash.index(after: $0)...]) }
    let key: ObjectKey?
    if let encodedKey, !encodedKey.isEmpty {
      key = try ObjectKey(validating: Self.percentDecode(encodedKey))
    } else {
      key = nil
    }
    return ResolvedS3Address(
      bucket: bucket,
      key: key,
      style: .path
    )
  }

  private static func removePort(from host: String) -> String {
    if host.hasPrefix("[") { return host }
    guard let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) else {
      return host
    }
    return String(host[..<colon])
  }

  static func percentDecode(_ value: String) throws -> String {
    var bytes: [UInt8] = []
    let input = Array(value.utf8)
    var index = 0
    while index < input.count {
      if input[index] == 37 {
        guard index + 2 < input.count,
              let high = hex(input[index + 1]),
              let low = hex(input[index + 2]) else {
          throw S3AddressingError.invalidPath
        }
        bytes.append(high * 16 + low)
        index += 3
      } else {
        bytes.append(input[index])
        index += 1
      }
    }
    guard let decoded = String(bytes: bytes, encoding: .utf8) else { throw S3AddressingError.invalidPath }
    return decoded
  }

  private static func hex(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }
}
