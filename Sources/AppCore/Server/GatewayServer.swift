import Foundation

public actor GatewayServer {
  private let transport: NIOHTTPTransport
  private let application: S3GatewayApplication

  public static func make(configuration: GatewayConfiguration) async throws -> GatewayServer {
    let configuration = try configuration.validated()
    let providers = try FileCredentialProviderSet.load(configuration: configuration.credentials)
    let backend: any ObjectStoreBackend
    switch configuration.backend {
    case .posix(let posix):
      backend = try POSIXBackend(
        configuration: posix,
        maximumChunkBytes: configuration.limits.maximumChunkBytes
      )
    case .s3(let upstream):
      backend = try S3Backend(
        configuration: upstream,
        credentials: providers.upstream,
        maximumChunkBytes: configuration.limits.maximumChunkBytes,
        maximumInFlightBytes: configuration.limits.maximumInFlightBytes,
        maximumHeaderBytes: configuration.limits.maximumHeaderBytes,
        maximumXMLBytes: configuration.limits.maximumXMLBytes,
        requestTimeoutSeconds: configuration.limits.requestTimeoutSeconds
      )
    }
    try await backend.readinessCheck()
    let service = try await GatewayService(backend: backend)
    let router = S3OperationRouter(
      resolver: S3AddressingResolver(
        styles: configuration.addressingStyles,
        virtualHostSuffixes: configuration.virtualHostSuffixes
      )
    )
    let application = S3GatewayApplication(
      router: router,
      verifier: SigV4Verifier(
        credentials: providers.inbound,
        acceptedRegions: configuration.acceptedSigV4Regions ?? ["us-east-1"]
      ),
      authorization: try AuthorizationPolicy(principals: configuration.authorization),
      pagination: PaginationTokenService(provider: providers.pagination, maximumLifetime: 900),
      service: service,
      limits: configuration.limits,
      health: configuration.health,
      telemetry: configuration.telemetry?.enabled == true
        ? StandardErrorGatewayTelemetrySink()
        : NoopGatewayTelemetrySink()
    )
    return GatewayServer(
      transport: NIOHTTPTransport(configuration: configuration.listener, limits: configuration.limits),
      application: application
    )
  }

  private init(transport: NIOHTTPTransport, application: S3GatewayApplication) {
    self.transport = transport
    self.application = application
  }

  public func start() async throws {
    let application = self.application
    try await transport.start { request in await application.handle(request) }
  }

  public func stop() async throws {
    try await transport.stop()
  }

  public var localAddress: String? {
    get async { await transport.localAddress }
  }

  public var localPort: Int? {
    get async { await transport.localPort }
  }
}
