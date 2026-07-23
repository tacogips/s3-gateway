import Foundation

public struct BucketName: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init?(rawValue: String) {
    guard Self.isValid(rawValue) else { return nil }
    self.rawValue = rawValue
  }

  public init(validating value: String) throws {
    guard Self.isValid(value) else { throw DomainValidationError.invalidBucketName }
    rawValue = value
  }

  public var description: String { rawValue }

  private static func isValid(_ value: String) -> Bool {
    guard (3...63).contains(value.utf8.count),
          value.first?.isLetter == true || value.first?.isNumber == true,
          value.last?.isLetter == true || value.last?.isNumber == true,
          !value.contains(".."),
          !value.contains(".-"),
          !value.contains("-.") else {
      return false
    }
    return value.utf8.allSatisfy { byte in
      (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 46
    }
  }
}

public struct ObjectKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init?(rawValue: String) {
    guard !Self.valueHasInvalidBytes(rawValue), rawValue.utf8.count <= 1_024 else { return nil }
    self.rawValue = rawValue
  }

  public init(validating value: String) throws {
    guard !Self.valueHasInvalidBytes(value), value.utf8.count <= 1_024 else {
      throw DomainValidationError.invalidObjectKey
    }
    rawValue = value
  }

  public var description: String { rawValue }

  private static func valueHasInvalidBytes(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: {
      $0.value == 0 || CharacterSet.controlCharacters.contains($0)
    })
  }
}

public struct PrincipalID: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init?(rawValue: String) {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 256 else { return nil }
    self.rawValue = rawValue
  }
}

public struct ObjectVersionToken: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public enum DomainValidationError: Error, Equatable, Sendable {
  case invalidBucketName
  case invalidObjectKey
  case invalidRange
  case invalidEntityTag
}
