import Foundation

public struct GatewayConfiguration: Codable, Equatable, Sendable {
  public var listener: ListenerConfiguration
  public var limits: GatewayLimits
  public var addressingStyles: Set<AddressingStyle>
  public var virtualHostSuffixes: [String]
  public var acceptedSigV4Regions: Set<String>?
  public var health: HealthEndpointConfiguration?
  public var telemetry: TelemetryConfiguration?
  public var credentials: CredentialProviderConfiguration
  public var authorization: [PrincipalAuthorization]
  public var backend: BackendConfiguration

  public init(
    listener: ListenerConfiguration,
    limits: GatewayLimits = .defaults,
    addressingStyles: Set<AddressingStyle> = [.path],
    virtualHostSuffixes: [String] = [],
    acceptedSigV4Regions: Set<String>? = nil,
    health: HealthEndpointConfiguration? = nil,
    telemetry: TelemetryConfiguration? = nil,
    credentials: CredentialProviderConfiguration,
    authorization: [PrincipalAuthorization] = [],
    backend: BackendConfiguration
  ) {
    self.listener = listener
    self.limits = limits
    self.addressingStyles = addressingStyles
    self.virtualHostSuffixes = virtualHostSuffixes
    self.acceptedSigV4Regions = acceptedSigV4Regions
    self.health = health
    self.telemetry = telemetry
    self.credentials = credentials
    self.authorization = authorization
    self.backend = backend
  }

  public func validated(fileSystem: FileSystemInspecting = LocalFileSystemInspector()) throws -> Self {
    try listener.validate()
    if let tls = listener.tls {
      guard tls.certificateChainPath.hasPrefix("/"), tls.privateKeyPath.hasPrefix("/") else {
        throw ConfigurationError.invalid(field: "listener.tls", reason: "certificate and key paths must be absolute")
      }
      try fileSystem.validateRegularFile(path: tls.certificateChainPath)
      try fileSystem.validateCredentialFile(path: tls.privateKeyPath)
    }
    try limits.validate()
    guard !addressingStyles.isEmpty else {
      throw ConfigurationError.invalid(field: "addressingStyles", reason: "at least one style is required")
    }
    if addressingStyles.contains(.virtualHost), virtualHostSuffixes.isEmpty {
      throw ConfigurationError.invalid(field: "virtualHostSuffixes", reason: "required for virtual-host addressing")
    }
    let normalizedSuffixes = virtualHostSuffixes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    guard normalizedSuffixes.count <= 64,
          Set(normalizedSuffixes).count == normalizedSuffixes.count,
          normalizedSuffixes.allSatisfy(Self.isValidDNSName) else {
      throw ConfigurationError.invalid(field: "virtualHostSuffixes", reason: "contains an invalid or duplicate DNS suffix")
    }
    if let acceptedSigV4Regions,
       acceptedSigV4Regions.isEmpty ||
       acceptedSigV4Regions.count > 64 ||
       acceptedSigV4Regions.contains(where: { region in
         region.isEmpty || region.utf8.count > 128 || !region.utf8.allSatisfy { byte in
           (65...90).contains(byte) || (97...122).contains(byte) ||
             (48...57).contains(byte) || byte == 45
         }
       }) {
      throw ConfigurationError.invalid(field: "acceptedSigV4Regions", reason: "contains an invalid region")
    }
    try health?.validate()
    if health != nil, addressingStyles.contains(.virtualHost) {
      throw ConfigurationError.invalid(
        field: "health",
        reason: "health routes require path-only addressing to prevent object-key collisions"
      )
    }
    try credentials.validate(fileSystem: fileSystem)
    try backend.validate(fileSystem: fileSystem)
    let configuredBuckets: Set<String> = switch backend {
    case .posix(let configuration): Set(configuration.bucketDirectories.keys)
    case .s3(let configuration): Set(configuration.bucketMappings.keys)
    }
    guard authorization.flatMap(\.grants).allSatisfy({ configuredBuckets.contains($0.bucket) }) else {
      throw ConfigurationError.invalid(field: "authorization", reason: "references an unconfigured bucket")
    }
    _ = try AuthorizationPolicy(principals: authorization)
    return self
  }

  private static func isValidDNSName(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 253 else { return false }
    return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
      guard !label.isEmpty,
            label.utf8.count <= 63,
            label.first != "-",
            label.last != "-" else { return false }
      return label.utf8.allSatisfy { byte in
        (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
      }
    }
  }
}

public struct TelemetryConfiguration: Codable, Equatable, Sendable {
  public let enabled: Bool

  public init(enabled: Bool = false) {
    self.enabled = enabled
  }
}

public struct HealthEndpointConfiguration: Codable, Equatable, Sendable {
  public let livenessPath: String
  public let readinessPath: String

  public init(
    livenessPath: String = "/.well-known/s3-gateway/live",
    readinessPath: String = "/.well-known/s3-gateway/ready"
  ) {
    self.livenessPath = livenessPath
    self.readinessPath = readinessPath
  }

  func validate() throws {
    for (field, path) in [("livenessPath", livenessPath), ("readinessPath", readinessPath)] {
      guard path.hasPrefix("/.well-known/s3-gateway/"),
            path.count > "/.well-known/s3-gateway/".count,
            !path.contains("?"),
            !path.contains("#") else {
        throw ConfigurationError.invalid(field: "health.\(field)", reason: "must use the reserved health prefix")
      }
    }
    guard livenessPath != readinessPath else {
      throw ConfigurationError.invalid(field: "health", reason: "liveness and readiness paths must differ")
    }
  }
}

public struct ListenerConfiguration: Codable, Equatable, Sendable {
  public var host: String
  public var port: Int
  public var tls: TLSConfiguration?
  public var developmentPlaintext: Bool
  public var trustedProxyAddresses: [String]

  public init(
    host: String = "127.0.0.1",
    port: Int = 8443,
    tls: TLSConfiguration? = nil,
    developmentPlaintext: Bool = false,
    trustedProxyAddresses: [String] = []
  ) {
    self.host = host
    self.port = port
    self.tls = tls
    self.developmentPlaintext = developmentPlaintext
    self.trustedProxyAddresses = trustedProxyAddresses
  }

  func validate() throws {
    let loopbackDevelopment = developmentPlaintext && (host == "127.0.0.1" || host == "::1" || host == "localhost")
    guard (1...65_535).contains(port) || port == 0 && loopbackDevelopment else {
      throw ConfigurationError.invalid(field: "listener.port", reason: "must be between 1 and 65535")
    }
    if tls == nil {
      guard loopbackDevelopment else {
        throw ConfigurationError.invalid(
          field: "listener.tls",
          reason: "native TLS is required except for explicit loopback development mode"
        )
      }
    }
    guard trustedProxyAddresses.isEmpty else {
      throw ConfigurationError.invalid(
        field: "listener.trustedProxyAddresses",
        reason: "forwarded-header trust is not supported in Stage 1 native-TLS mode"
      )
    }
  }
}

public struct TLSConfiguration: Codable, Equatable, Sendable {
  public let certificateChainPath: String
  public let privateKeyPath: String

  public init(certificateChainPath: String, privateKeyPath: String) {
    self.certificateChainPath = certificateChainPath
    self.privateKeyPath = privateKeyPath
  }
}

public struct GatewayLimits: Codable, Equatable, Sendable {
  public var maximumHeaderBytes: Int
  public var maximumXMLBytes: Int
  public var maximumObjectBytes: Int64
  public var maximumChunkBytes: Int
  public var maximumInFlightBytes: Int
  public var maximumConcurrentRequests: Int
  public var requestTimeoutSeconds: Int

  public static let defaults = GatewayLimits(
    maximumHeaderBytes: 32 * 1_024,
    maximumXMLBytes: 1 * 1_024 * 1_024,
    maximumObjectBytes: 5 * 1_024 * 1_024 * 1_024,
    maximumChunkBytes: 64 * 1_024,
    maximumInFlightBytes: 8 * 1_024 * 1_024,
    maximumConcurrentRequests: 256,
    requestTimeoutSeconds: 300
  )

  func validate() throws {
    guard (1_024...(1 * 1_024 * 1_024)).contains(maximumHeaderBytes),
          maximumXMLBytes > 0,
          maximumObjectBytes > 0,
          maximumChunkBytes > 0,
          maximumInFlightBytes >= maximumChunkBytes,
          maximumConcurrentRequests > 0,
          requestTimeoutSeconds > 0 else {
      throw ConfigurationError.invalid(field: "limits", reason: "all limits must be positive and internally consistent")
    }
  }
}

public enum BackendConfiguration: Codable, Equatable, Sendable {
  case posix(POSIXBackendConfiguration)
  case s3(UpstreamS3Configuration)

  private enum CodingKeys: String, CodingKey {
    case kind
    case posix
    case s3
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(BackendKind.self, forKey: .kind)
    switch kind {
    case .posix:
      guard container.contains(.posix), !container.contains(.s3) else {
        throw DecodingError.dataCorruptedError(
          forKey: .kind,
          in: container,
          debugDescription: "The backend block must contain only its selected configuration."
        )
      }
      self = .posix(try container.decode(POSIXBackendConfiguration.self, forKey: .posix))
    case .s3:
      guard container.contains(.s3), !container.contains(.posix) else {
        throw DecodingError.dataCorruptedError(
          forKey: .kind,
          in: container,
          debugDescription: "The backend block must contain only its selected configuration."
        )
      }
      self = .s3(try container.decode(UpstreamS3Configuration.self, forKey: .s3))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .posix(let configuration):
      try container.encode(BackendKind.posix, forKey: .kind)
      try container.encode(configuration, forKey: .posix)
    case .s3(let configuration):
      try container.encode(BackendKind.s3, forKey: .kind)
      try container.encode(configuration, forKey: .s3)
    }
  }

  func validate(fileSystem: FileSystemInspecting) throws {
    switch self {
    case .posix(let configuration): try configuration.validate(fileSystem: fileSystem)
    case .s3(let configuration): try configuration.validate(fileSystem: fileSystem)
    }
  }
}

public struct POSIXBackendConfiguration: Codable, Equatable, Sendable {
  public let rootPath: String
  public let bucketDirectories: [String: String]
  public let layoutPolicy: POSIXLayoutPolicy
  public let sidecarPath: String
  public let durability: DurabilityMode

  public init(
    rootPath: String,
    bucketDirectories: [String: String],
    layoutPolicy: POSIXLayoutPolicy,
    sidecarPath: String,
    durability: DurabilityMode = .strict
  ) {
    self.rootPath = rootPath
    self.bucketDirectories = bucketDirectories
    self.layoutPolicy = layoutPolicy
    self.sidecarPath = sidecarPath
    self.durability = durability
  }

  func validate(fileSystem: FileSystemInspecting) throws {
    guard rootPath.hasPrefix("/"), sidecarPath.hasPrefix("/") else {
      throw ConfigurationError.invalid(field: "backend.posix", reason: "root and sidecar paths must be absolute")
    }
    let normalizedRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
      .standardizedFileURL.path
    let normalizedSidecar = URL(fileURLWithPath: sidecarPath, isDirectory: true)
      .standardizedFileURL.path
    guard !bucketDirectories.isEmpty else {
      throw ConfigurationError.invalid(field: "backend.posix.bucketDirectories", reason: "at least one bucket mapping is required")
    }
    let sidecarIsWithinRoot = normalizedRoot == "/"
      ? normalizedSidecar.hasPrefix("/")
      : normalizedSidecar.hasPrefix(normalizedRoot + "/")
    guard normalizedSidecar != normalizedRoot,
          !sidecarIsWithinRoot else {
      throw ConfigurationError.invalid(field: "backend.posix.sidecarPath", reason: "sidecars must be outside the exposed namespace")
    }
    try fileSystem.validateDirectory(path: rootPath, requireLocal: layoutPolicy == .sharedLocalDirectory)
    try fileSystem.validateDirectory(path: sidecarPath, requireLocal: true)
    try fileSystem.validatePrivateDirectory(path: sidecarPath)
    guard try fileSystem.sameFileSystem(rootPath, sidecarPath) else {
      throw ConfigurationError.invalid(field: "backend.posix.sidecarPath", reason: "must be on the same filesystem as the root")
    }
    let relativePaths = bucketDirectories.values.map {
      $0.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    }
    for (bucket, relativePath) in bucketDirectories {
      let components = relativePath.split(
        separator: "/",
        omittingEmptySubsequences: false
      )
      guard BucketName(rawValue: bucket) != nil,
            !relativePath.hasPrefix("/"),
            !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw ConfigurationError.invalid(field: "backend.posix.bucketDirectories", reason: "contains an invalid mapping")
      }
    }
    for firstIndex in relativePaths.indices {
      for secondIndex in relativePaths.indices where firstIndex < secondIndex {
        let first = relativePaths[firstIndex]
        let second = relativePaths[secondIndex]
        let sharedCount = min(first.count, second.count)
        guard Array(first.prefix(sharedCount)) != Array(second.prefix(sharedCount)) else {
          throw ConfigurationError.invalid(
            field: "backend.posix.bucketDirectories",
            reason: "bucket directory mappings must not overlap"
          )
        }
      }
    }
  }
}

public struct UpstreamS3Configuration: Codable, Equatable, Sendable {
  public let endpoint: URL
  public let region: String
  public let addressingStyle: AddressingStyle
  public let bucketMappings: [String: String]
  public let stagingDirectory: String?
  public let trustedCAPath: String?

  public init(
    endpoint: URL,
    region: String,
    addressingStyle: AddressingStyle,
    bucketMappings: [String: String],
    stagingDirectory: String? = nil,
    trustedCAPath: String? = nil
  ) {
    self.endpoint = endpoint
    self.region = region
    self.addressingStyle = addressingStyle
    self.bucketMappings = bucketMappings
    self.stagingDirectory = stagingDirectory
    self.trustedCAPath = trustedCAPath
  }

  func validate(fileSystem: FileSystemInspecting = LocalFileSystemInspector()) throws {
    guard endpoint.scheme == "https",
          endpoint.host != nil,
          endpoint.user == nil,
          endpoint.password == nil,
          endpoint.query == nil,
          endpoint.fragment == nil,
          endpoint.path.isEmpty || endpoint.path == "/" else {
      throw ConfigurationError.invalid(field: "backend.s3.endpoint", reason: "must be an absolute HTTPS URL")
    }
    guard !region.isEmpty,
          region.utf8.count <= 128,
          region.utf8.allSatisfy({
            (65...90).contains($0) ||
              (97...122).contains($0) ||
              (48...57).contains($0) ||
              $0 == 45
          }),
          !bucketMappings.isEmpty,
          Set(bucketMappings.values).count == bucketMappings.count,
          bucketMappings.allSatisfy({ BucketName(rawValue: $0.key) != nil && BucketName(rawValue: $0.value) != nil }) else {
      throw ConfigurationError.invalid(
        field: "backend.s3",
        reason: "region and non-overlapping bucket mappings are required"
      )
    }
    if let stagingDirectory, !stagingDirectory.hasPrefix("/") {
      throw ConfigurationError.invalid(field: "backend.s3.stagingDirectory", reason: "must be absolute")
    }
    if let stagingDirectory {
      try fileSystem.validateDirectory(path: stagingDirectory, requireLocal: true)
      try fileSystem.validatePrivateDirectory(path: stagingDirectory)
    }
    if let trustedCAPath {
      guard trustedCAPath.hasPrefix("/") else {
        throw ConfigurationError.invalid(field: "backend.s3.trustedCAPath", reason: "must be absolute")
      }
      try fileSystem.validateRegularFile(path: trustedCAPath)
    }
  }
}

public enum ConfigurationError: Error, Equatable, Sendable {
  case invalid(field: String, reason: String)
  case unreadable(path: String)
  case insecureCredentialFile(path: String)
  case unsupportedFileSystem(path: String)
}
