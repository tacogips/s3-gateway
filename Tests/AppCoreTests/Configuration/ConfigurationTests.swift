import Foundation
import Testing
@testable import AppCore

@Test func productionListenerRequiresNativeTLS() throws {
  let configuration = makeConfiguration(
    listener: ListenerConfiguration(host: "0.0.0.0", port: 9000)
  )
  #expect(throws: ConfigurationError.self) {
    _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
  }
}

@Test func loopbackDevelopmentMayUsePlaintext() throws {
  let configuration = makeConfiguration(
    listener: ListenerConfiguration(
      host: "127.0.0.1",
      port: 9000,
      developmentPlaintext: true
    )
  )
  _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
}

@Test func credentialDomainsMustUseDifferentFiles() throws {
  var configuration = makeConfiguration()
  configuration.credentials = CredentialProviderConfiguration(
    inboundPath: "/secrets/shared.json",
    upstreamPath: "/secrets/shared.json",
    paginationPath: "/secrets/page.json"
  )
  #expect(throws: ConfigurationError.self) {
    _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
  }
}

@Test func sharedDirectoryRequiresLocalStorage() throws {
  let inspector = AcceptingFileSystemInspector(rejectLocal: true)
  #expect(throws: ConfigurationError.unsupportedFileSystem(path: "/data")) {
    _ = try makeConfiguration().validated(fileSystem: inspector)
  }
}

@Test func healthPathsMustBeDistinctAbsolutePaths() throws {
  var configuration = makeConfiguration()
  configuration.health = HealthEndpointConfiguration(
    livenessPath: "/.well-known/s3-gateway/health",
    readinessPath: "/.well-known/s3-gateway/health"
  )
  #expect(throws: ConfigurationError.self) {
    _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
  }
  configuration.health = HealthEndpointConfiguration(
    livenessPath: "health/live",
    readinessPath: "/.well-known/s3-gateway/ready"
  )
  #expect(throws: ConfigurationError.self) {
    _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
  }
}

@Test func stageOneRejectsUnusedTrustedProxyConfiguration() throws {
  let configuration = makeConfiguration(
    listener: ListenerConfiguration(
      host: "0.0.0.0",
      port: 8443,
      tls: TLSConfiguration(certificateChainPath: "/tls/cert.pem", privateKeyPath: "/tls/key.pem"),
      trustedProxyAddresses: ["127.0.0.1"]
    )
  )
  #expect(throws: ConfigurationError.self) {
    _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
  }
}

@Test func sharedPOSIXExampleConfigurationDecodes() throws {
  let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let configuration = try ConfigurationLoader.loadJSON(
    at: repository.appendingPathComponent("config-examples/gateway-posix-shared.json").path
  )
  #expect(configuration.health?.readinessPath == "/.well-known/s3-gateway/ready")
  #expect(configuration.telemetry?.enabled == true)
  guard case .posix(let posix) = configuration.backend else {
    Issue.record("Expected the example to select the POSIX backend")
    return
  }
  #expect(posix.layoutPolicy == .sharedLocalDirectory)
  #expect(posix.bucketDirectories["local-files"] == "shared")
}

@Test func upstreamS3ExampleConfigurationDecodes() throws {
  let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let configuration = try ConfigurationLoader.loadJSON(
    at: repository.appendingPathComponent(
      "config-examples/gateway-s3.json"
    ).path
  )
  guard case .s3(let s3) = configuration.backend else {
    Issue.record("Expected the example to select the S3 backend")
    return
  }
  #expect(s3.endpoint.absoluteString == "https://s3.us-east-1.amazonaws.com")
  #expect(s3.region == "us-east-1")
  #expect(s3.bucketMappings["public-files"] == "company-public-files")
  #expect(s3.stagingDirectory == "/var/lib/s3-gateway/staging")
}

@Test func upstreamPrivateCATrustPathMustBeAbsolute() throws {
  var configuration = makeConfiguration()
  configuration.backend = .s3(
    UpstreamS3Configuration(
      endpoint: try #require(URL(string: "https://s3.example.test")),
      region: "us-east-1",
      addressingStyle: .path,
      bucketMappings: ["my-bucket": "upstream-bucket"],
      trustedCAPath: "private-ca.pem"
    )
  )
  #expect(throws: ConfigurationError.self) {
    _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
  }
}

@Test func backendJSONRejectsConfigurationsForBothKinds() throws {
  let json = """
  {
    "kind": "posix",
    "posix": {
      "rootPath": "/data",
      "bucketDirectories": {"my-bucket": "bucket"},
      "layoutPolicy": "sharedLocalDirectory",
      "sidecarPath": "/metadata",
      "durability": "data"
    },
    "s3": {
      "endpoint": "https://s3.example.test",
      "region": "us-east-1",
      "addressingStyle": "path",
      "bucketMappings": {"my-bucket": "remote-bucket"}
    }
  }
  """
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(BackendConfiguration.self, from: Data(json.utf8))
  }
}

@Test func posixBucketMappingsMustNotAliasOrNest() throws {
  var configuration = makeConfiguration()
  configuration.backend = .posix(
    POSIXBackendConfiguration(
      rootPath: "/data",
      bucketDirectories: [
        "first-bucket": "shared",
        "second-bucket": "shared/nested"
      ],
      layoutPolicy: .sharedLocalDirectory,
      sidecarPath: "/metadata"
    )
  )
  #expect(throws: ConfigurationError.self) {
    _ = try configuration.validated(fileSystem: AcceptingFileSystemInspector())
  }
}

private func makeConfiguration(
  listener: ListenerConfiguration = ListenerConfiguration(
    host: "0.0.0.0",
    port: 8443,
    tls: TLSConfiguration(certificateChainPath: "/tls/cert.pem", privateKeyPath: "/tls/key.pem")
  )
) -> GatewayConfiguration {
  GatewayConfiguration(
    listener: listener,
    credentials: CredentialProviderConfiguration(
      inboundPath: "/secrets/inbound.json",
      upstreamPath: "/secrets/upstream.json",
      paginationPath: "/secrets/pagination.json"
    ),
    backend: .posix(
      POSIXBackendConfiguration(
        rootPath: "/data",
        bucketDirectories: ["my-bucket": "my-bucket"],
        layoutPolicy: .sharedLocalDirectory,
        sidecarPath: "/metadata"
      )
    )
  )
}

private struct AcceptingFileSystemInspector: FileSystemInspecting {
  var rejectLocal = false

  func validateDirectory(path: String, requireLocal: Bool) throws {
    if rejectLocal, requireLocal {
      throw ConfigurationError.unsupportedFileSystem(path: path)
    }
  }

  func validateCredentialFile(path: String) throws {}

  func validateRegularFile(path: String) throws {}

  func validatePrivateDirectory(path: String) throws {}

  func sameFileSystem(_ firstPath: String, _ secondPath: String) throws -> Bool {
    true
  }
}
