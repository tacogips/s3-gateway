import Crypto
import Darwin
import Foundation

public struct FileCredentialProviderSet: Sendable {
  public let inbound: FileInboundCredentialProvider
  public let upstream: FileUpstreamCredentialProvider
  public let pagination: FilePaginationKeyProvider

  public static func load(
    configuration: CredentialProviderConfiguration,
    fileSystem: FileSystemInspecting = LocalFileSystemInspector()
  ) throws -> FileCredentialProviderSet {
    try fileSystem.validateCredentialFile(path: configuration.inboundPath)
    try fileSystem.validateCredentialFile(path: configuration.upstreamPath)
    try fileSystem.validateCredentialFile(path: configuration.paginationPath)
    return try FileCredentialProviderSet(
      inbound: FileInboundCredentialProvider(path: configuration.inboundPath),
      upstream: FileUpstreamCredentialProvider(path: configuration.upstreamPath),
      pagination: FilePaginationKeyProvider(path: configuration.paginationPath)
    )
  }
}

public struct FileInboundCredentialProvider: InboundCredentialProviding, Sendable {
  private let credentials: [String: InboundVerificationCredential]

  public init(path: String) throws {
    let file: VersionedInboundCredentialFile = try CredentialFileDecoder.decode(path: path)
    guard file.version == 1, file.records.count <= 10_000 else {
      throw CredentialProviderError.invalidFormat
    }
    var values: [String: InboundVerificationCredential] = [:]
    for record in file.records where record.enabled {
      guard !record.accessKeyID.isEmpty,
            record.accessKeyID.utf8.count <= 128,
            record.secretAccessKey.utf8.count >= 16,
            record.secretAccessKey.utf8.count <= 512,
            let principal = PrincipalID(rawValue: record.principalID),
            values[record.accessKeyID] == nil else {
        throw CredentialProviderError.invalidFormat
      }
      values[record.accessKeyID] = InboundVerificationCredential(
        accessKeyID: record.accessKeyID,
        principalID: principal,
        signingSecret: SymmetricKey(data: Data(record.secretAccessKey.utf8))
      )
    }
    credentials = values
  }

  public func credential(for accessKeyID: String) async -> InboundVerificationCredential? {
    credentials[accessKeyID]
  }
}

public struct FileUpstreamCredentialProvider: UpstreamCredentialProviding, Sendable {
  private let credential: UpstreamSigningCredential

  public init(path: String) throws {
    let file: VersionedUpstreamCredentialFile = try CredentialFileDecoder.decode(path: path)
    guard file.version == 1,
          !file.active.accessKeyID.isEmpty,
          file.active.accessKeyID.utf8.count <= 128,
          file.active.secretAccessKey.utf8.count >= 16,
          file.active.secretAccessKey.utf8.count <= 512,
          file.active.sessionToken.map({
            !$0.isEmpty && $0.utf8.count <= 4_096
          }) ?? true else {
      throw CredentialProviderError.invalidFormat
    }
    credential = UpstreamSigningCredential(
      accessKeyID: file.active.accessKeyID,
      sessionToken: file.active.sessionToken,
      signingSecret: SymmetricKey(data: Data(file.active.secretAccessKey.utf8))
    )
  }

  public func activeCredential() async -> UpstreamSigningCredential {
    credential
  }
}

public struct FilePaginationKeyProvider: PaginationKeyProviding, Sendable {
  private let active: PaginationSigningKey
  private let keys: [String: PaginationSigningKey]

  public init(path: String) throws {
    let file: VersionedPaginationKeyFile = try CredentialFileDecoder.decode(path: path)
    guard file.version == 1, file.keys.count <= 16 else {
      throw CredentialProviderError.invalidFormat
    }
    var values: [String: PaginationSigningKey] = [:]
    for record in file.keys where record.enabled {
      guard values[record.keyID] == nil,
            !record.keyID.isEmpty,
            record.keyID.utf8.count <= 128,
            let secret = Data(base64Encoded: record.secretBase64),
            secret.count == 32 else {
        throw CredentialProviderError.invalidFormat
      }
      values[record.keyID] = PaginationSigningKey(
        keyID: record.keyID,
        key: SymmetricKey(data: secret)
      )
    }
    guard let active = values[file.activeKeyID] else { throw CredentialProviderError.missingActiveKey }
    self.active = active
    keys = values
  }

  public func activeKey() async -> PaginationSigningKey {
    active
  }

  public func key(for keyID: String) async -> PaginationSigningKey? {
    keys[keyID]
  }
}

private enum CredentialFileDecoder {
  static func decode<Value: Decodable>(path: String) throws -> Value {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ConfigurationError.unreadable(path: path) }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
      var information = stat()
      guard fstat(descriptor, &information) == 0,
            information.st_mode & S_IFMT == S_IFREG,
            information.st_uid == geteuid(),
            information.st_mode & 0o077 == 0 else {
        throw ConfigurationError.insecureCredentialFile(path: path)
      }
      guard information.st_size <= 1_048_576 else {
        throw CredentialProviderError.recordLimitExceeded
      }
      let data = try file.read(upToCount: 1_048_577) ?? Data()
      guard data.count <= 1_048_576 else { throw CredentialProviderError.recordLimitExceeded }
      try file.close()
      return try JSONDecoder().decode(Value.self, from: data)
    } catch let error as CredentialProviderError {
      throw error
    } catch let error as ConfigurationError {
      throw error
    } catch {
      throw CredentialProviderError.invalidFormat
    }
  }
}
