import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
@preconcurrency import NIOSSL

public actor NIOHTTPTransport {
  private let configuration: ListenerConfiguration
  private let limits: GatewayLimits
  private let group: MultiThreadedEventLoopGroup
  private let requestLimiter: RequestLimiter
  private let healthClassifier: HealthRouteClassifier
  private let taskRegistry = TransportTaskRegistry()
  private var serverChannel: Channel?

  public init(
    configuration: ListenerConfiguration,
    limits: GatewayLimits,
    healthClassifier: HealthRouteClassifier = .disabled
  ) {
    self.configuration = configuration
    self.limits = limits
    self.healthClassifier = healthClassifier
    group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    requestLimiter = RequestLimiter(limit: limits.maximumConcurrentRequests)
  }

  public func start(application: @escaping HTTPApplicationHandler) async throws {
    guard serverChannel == nil else { return }
    let sslContext = try configuration.tls.map(Self.makeSSLContext)
    let maximumBufferedChunks = max(1, limits.maximumInFlightBytes / limits.maximumChunkBytes)
    let decoderLimits: NIOHTTPDecoderLimitConfiguration = {
      var value = NIOHTTPDecoderLimitConfiguration()
      value.maxHeaderFieldSize = limits.maximumHeaderBytes
      value.maxHeaderListSize = limits.maximumHeaderBytes
      value.maxHeaderFieldCount = max(1, min(1_024, limits.maximumHeaderBytes / 2))
      return value
    }()
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelOption(
        ChannelOptions.recvAllocator,
        value: FixedSizeRecvByteBufferAllocator(capacity: limits.maximumChunkBytes)
      )
      .childChannelOption(ChannelOptions.autoRead, value: false)
      .childChannelInitializer { channel in
        do {
          if let sslContext {
            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
          }
          try channel.pipeline.syncOperations.configureHTTPServerPipeline(
            withEncoderConfiguration: HTTPResponseEncoder.Configuration(),
            withDecoderLimitConfiguration: decoderLimits
          )
          try channel.pipeline.syncOperations.addHandler(
            HTTP1RequestHandler(
              application: application,
              maximumHeaderBytes: self.limits.maximumHeaderBytes,
              maximumObjectBytes: self.limits.maximumObjectBytes,
              maximumChunkBytes: self.limits.maximumChunkBytes,
              maximumBufferedChunks: maximumBufferedChunks,
              requestTimeoutSeconds: self.limits.requestTimeoutSeconds,
              requestLimiter: self.requestLimiter,
              healthClassifier: self.healthClassifier,
              taskRegistry: self.taskRegistry
            )
          )
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
    serverChannel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
  }

  public func stop() async throws {
    if let serverChannel {
      try await serverChannel.close().get()
      self.serverChannel = nil
    }
    await taskRegistry.beginDrainingAndCancelAll()
    await requestLimiter.beginDraining()
    let drainDeadline = ContinuousClock.now.advanced(
      by: .seconds(limits.requestTimeoutSeconds)
    )
    while !(await requestLimiter.isIdle),
          ContinuousClock.now < drainDeadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      group.shutdownGracefully { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  public var localAddress: String? {
    serverChannel?.localAddress.map(String.init(describing:))
  }

  public var localPort: Int? {
    serverChannel?.localAddress?.port
  }

  var isSharedRequestLimiterIdle: Bool {
    get async {
      await requestLimiter.isIdle
    }
  }

  private static func makeSSLContext(_ configuration: AppCore.TLSConfiguration) throws -> NIOSSLContext {
    let certificates = try NIOSSLCertificate.fromPEMFile(configuration.certificateChainPath)
      .map(NIOSSLCertificateSource.certificate)
    let privateKey = try NIOSSLPrivateKey(file: configuration.privateKeyPath, format: .pem)
    var tls = NIOSSL.TLSConfiguration.makeServerConfiguration(
      certificateChain: certificates,
      privateKey: .privateKey(privateKey)
    )
    tls.minimumTLSVersion = .tlsv12
    return try NIOSSLContext(configuration: tls)
  }
}

private final class HTTP1RequestHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let application: HTTPApplicationHandler
  private let maximumHeaderBytes: Int
  private let maximumObjectBytes: Int64
  private let maximumChunkBytes: Int
  private let maximumBufferedChunks: Int
  private let requestTimeoutSeconds: Int
  private let requestLimiter: RequestLimiter
  private let healthClassifier: HealthRouteClassifier
  private let taskRegistry: TransportTaskRegistry
  private var bodySource: DemandDrivenRequestBodySource?
  private var receivedBytes: Int64 = 0
  private var requestActive = false
  private var timeoutTask: Scheduled<Void>?
  private var pendingBodyBuffers: [ByteBuffer] = []
  private var inboundEnded = false
  private var applicationTaskID: UUID?
  private var applicationTask: Task<Void, Never>?

  init(
    application: @escaping HTTPApplicationHandler,
    maximumHeaderBytes: Int,
    maximumObjectBytes: Int64,
    maximumChunkBytes: Int,
    maximumBufferedChunks: Int,
    requestTimeoutSeconds: Int,
    requestLimiter: RequestLimiter,
    healthClassifier: HealthRouteClassifier,
    taskRegistry: TransportTaskRegistry
  ) {
    self.application = application
    self.maximumHeaderBytes = maximumHeaderBytes
    self.maximumObjectBytes = maximumObjectBytes
    self.maximumChunkBytes = maximumChunkBytes
    self.maximumBufferedChunks = maximumBufferedChunks
    self.requestTimeoutSeconds = requestTimeoutSeconds
    self.requestLimiter = requestLimiter
    self.healthClassifier = healthClassifier
    self.taskRegistry = taskRegistry
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): receiveHead(head, context: context)
    case .body(var buffer): receiveBody(&buffer, context: context)
    case .end:
      inboundEnded = true
      finishBodyIfDrained()
    }
  }

  func channelActive(context: ChannelHandlerContext) {
    context.read()
    context.fireChannelActive()
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    if bodySource?.isWaitingForData == true {
      context.read()
    }
    context.fireChannelReadComplete()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    cancelActiveRequest(error: error)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    cancelActiveRequest(error: CancellationError())
    context.fireChannelInactive()
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    cancelActiveRequest(error: CancellationError())
  }

  private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
    guard !requestActive else {
      writeImmediateError(status: .badRequest, context: context)
      return
    }
    let headerBytes = head.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }
    guard headerBytes <= maximumHeaderBytes else {
      writeImmediateError(status: .requestHeaderFieldsTooLarge, context: context)
      return
    }
    guard let target = Self.splitTarget(head.uri) else {
      writeImmediateError(status: .uriTooLong, context: context)
      return
    }
    let contentLengths = head.headers[canonicalForm: "content-length"]
    let transferEncodings = head.headers[canonicalForm: "transfer-encoding"]
    guard contentLengths.count <= 1,
          contentLengths.isEmpty || transferEncodings.isEmpty,
          contentLengths.first.map({ Int64($0).map { $0 >= 0 } ?? false }) ?? true else {
      writeImmediateError(status: .badRequest, context: context)
      return
    }
    if let contentLength = contentLengths.first.flatMap({ Int64($0) }), contentLength > maximumObjectBytes {
      writeImmediateError(status: .payloadTooLarge, context: context)
      return
    }
    let expectations = head.headers[canonicalForm: "expect"]
    guard expectations.isEmpty || expectations == ["100-continue"] else {
      writeImmediateError(status: .expectationFailed, context: context)
      return
    }
    requestActive = true
    receivedBytes = 0
    let deadline = Date().addingTimeInterval(TimeInterval(requestTimeoutSeconds))
    let timeoutContext = UnsafeSendable(value: context)
    let timeoutInterval = max(1, Int64(deadline.timeIntervalSinceNow * 1_000_000_000))
    timeoutTask = context.eventLoop.scheduleTask(in: .nanoseconds(timeoutInterval)) { [weak self] in
      self?.cancelActiveRequest(error: BackendError.deadlineExceeded)
      timeoutContext.value.close(promise: nil)
    }
    let transferredContext = UnsafeSendable(value: context)
    let transferredHandler = UnsafeSendable(value: self)
    let source = DemandDrivenRequestBodySource(
      maximumBufferedChunks: maximumBufferedChunks,
      requestRead: {
        transferredContext.value.eventLoop.execute {
          transferredHandler.value.provideNextBodyChunk(
            context: transferredContext.value,
            readIfDrained: true
          )
        }
      },
      cancelChannel: {
        transferredContext.value.eventLoop.execute {
          transferredContext.value.close(promise: nil)
        }
      }
    )
    bodySource = source
    let stream = AsyncThrowingStream<Data, any Error>(unfolding: {
      try await source.next()
    })
    if !expectations.isEmpty {
      context.writeAndFlush(
        wrapOutboundOut(
          .head(HTTPResponseHead(version: .http1_1, status: .continue, headers: HTTPHeaders()))
        ),
        promise: nil
      )
    }
    var headers: [String: [String]] = [:]
    for header in head.headers { headers[header.name, default: []].append(header.value) }
    let request = HTTPTransportRequest(
      method: head.method.rawValue,
      rawPath: target.path,
      rawQuery: target.query,
      headers: headers,
      body: ObjectBodyStream(maximumChunkBytes: maximumChunkBytes, stream: stream),
      remoteAddress: context.remoteAddress.map(String.init(describing:)),
      healthClassifier: healthClassifier,
      deadline: deadline
    )
    let channel = context.channel
    let taskID = UUID()
    let cleanup = RequestExecutionCleanup(
      requestLimiter: requestLimiter,
      taskRegistry: taskRegistry,
      taskID: taskID,
      requiresSharedPermit: request.healthAdmission == .none
    )
    let task = Task { [application, transferredContext, channel] in
      guard await cleanup.acquirePermit() else {
        if !Task.isCancelled {
          try? await self.write(
            response: HTTPTransportResponse(status: 503),
            channel: channel,
            transferredContext: transferredContext
          )
        }
        await cleanup.finish()
        self.applicationDidFinish(taskID, context: transferredContext)
        return
      }
      let response = await application(request)
      if !Task.isCancelled {
        do {
          try await self.write(
            response: response,
            channel: channel,
            transferredContext: transferredContext
          )
        } catch {
          withUnsafeCurrentTask {
            $0?.cancel()
          }
          transferredContext.value.eventLoop.execute {
            transferredContext.value.close(promise: nil)
          }
        }
      }
      await cleanup.finish()
      self.applicationDidFinish(taskID, context: transferredContext)
    }
    applicationTaskID = taskID
    applicationTask = task
    Task {
      await taskRegistry.register(task, id: taskID)
    }
    if transferEncodings.isEmpty,
       contentLengths.isEmpty || contentLengths == ["0"] {
      context.read()
    }
  }

  private func applicationDidFinish(
    _ taskID: UUID,
    context: UnsafeSendable<ChannelHandlerContext>
  ) {
    context.value.eventLoop.execute { [weak self] in
      guard self?.applicationTaskID == taskID else {
        return
      }
      self?.timeoutTask?.cancel()
      self?.timeoutTask = nil
      self?.applicationTask = nil
      self?.applicationTaskID = nil
    }
  }

  private func cancelActiveRequest(error: any Error) {
    timeoutTask?.cancel()
    timeoutTask = nil
    bodySource?.fail(error)
    bodySource = nil
    applicationTask?.cancel()
  }

  private func receiveBody(_ buffer: inout ByteBuffer, context: ChannelHandlerContext) {
    guard requestActive, let bodySource else {
      writeImmediateError(status: .badRequest, context: context)
      return
    }
    receivedBytes += Int64(buffer.readableBytes)
    guard receivedBytes <= maximumObjectBytes else {
      bodySource.fail(BackendError.capacityExceeded)
      self.bodySource = nil
      writeImmediateError(status: .payloadTooLarge, context: context)
      return
    }
    pendingBodyBuffers.append(buffer)
    provideNextBodyChunk(context: context, readIfDrained: false)
  }

  private func provideNextBodyChunk(
    context: ChannelHandlerContext,
    readIfDrained: Bool
  ) {
    while !pendingBodyBuffers.isEmpty,
          pendingBodyBuffers[0].readableBytes == 0 {
      pendingBodyBuffers.removeFirst()
    }
    guard !pendingBodyBuffers.isEmpty else {
      if inboundEnded {
        finishBodyIfDrained()
      } else if readIfDrained {
        context.read()
      }
      return
    }
    let count = min(maximumChunkBytes, pendingBodyBuffers[0].readableBytes)
    guard let rawBytes = pendingBodyBuffers[0].readBytes(length: count),
          bodySource?.receive([Data(rawBytes)]) == true else {
      bodySource?.fail(BackendError.capacityExceeded)
      self.bodySource = nil
      context.close(promise: nil)
      return
    }
    if pendingBodyBuffers[0].readableBytes == 0 {
      pendingBodyBuffers.removeFirst()
    }
    finishBodyIfDrained()
  }

  private func finishBodyIfDrained() {
    guard inboundEnded, pendingBodyBuffers.isEmpty else { return }
    bodySource?.finish()
    bodySource = nil
  }

  private func write(
    response: HTTPTransportResponse,
    channel: Channel,
    transferredContext: UnsafeSendable<ChannelHandlerContext>
  ) async throws {
    var headers = HTTPHeaders(response.headers)
    if response.body != nil,
       !headers.contains(name: "content-length"),
       !headers.contains(name: "transfer-encoding") {
      headers.add(name: "transfer-encoding", value: "chunked")
    }
    headers.replaceOrAdd(name: "connection", value: "close")
    let status = HTTPResponseStatus(statusCode: response.status)
    try await writePart(
      .head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)),
      transferredContext: transferredContext
    )
    if let body = response.body {
      try await body.consume { [channel, transferredContext] chunk in
        var buffer = channel.allocator.buffer(capacity: chunk.count)
        buffer.writeBytes(chunk)
        try await self.writePart(.body(.byteBuffer(buffer)), transferredContext: transferredContext)
      }
    }
    try await writePart(.end(nil), transferredContext: transferredContext)
    try await channel.close().get()
  }

  private func writePart(
    _ part: HTTPServerResponsePart,
    transferredContext: UnsafeSendable<ChannelHandlerContext>
  ) async throws {
    let context = transferredContext.value
    try await withCheckedThrowingContinuation { continuation in
      context.eventLoop.execute { [transferredContext] in
        let context = transferredContext.value
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { result in continuation.resume(with: result) }
        context.writeAndFlush(self.wrapOutboundOut(part), promise: promise)
      }
    }
  }

  private func writeImmediateError(status: HTTPResponseStatus, context: ChannelHandlerContext) {
    var headers = HTTPHeaders()
    headers.add(name: "content-length", value: "0")
    headers.add(name: "connection", value: "close")
    context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
    let transferredContext = UnsafeSendable(value: context)
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      transferredContext.value.close(promise: nil)
    }
  }

  private static func splitTarget(_ target: String) -> (path: String, query: String)? {
    guard !target.isEmpty, target.utf8.count <= 16 * 1_024 else { return nil }
    guard let separator = target.firstIndex(of: "?") else { return (target, "") }
    return (String(target[..<separator]), String(target[target.index(after: separator)...]))
  }
}

private struct UnsafeSendable<Value>: @unchecked Sendable {
  let value: Value
}

private actor RequestLimiter {
  private let limit: Int
  private var active = 0
  private var draining = false

  init(limit: Int) { self.limit = limit }

  func acquire() -> Bool {
    guard !Task.isCancelled, !draining, active < limit else { return false }
    active += 1
    return true
  }

  func release() {
    active = max(0, active - 1)
  }

  func beginDraining() {
    draining = true
  }

  var isIdle: Bool {
    active == 0
  }
}

private actor TransportTaskRegistry {
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var completedBeforeRegistration: Set<UUID> = []
  private var draining = false

  func register(_ task: Task<Void, Never>, id: UUID) {
    if completedBeforeRegistration.remove(id) != nil {
      return
    }
    guard !draining else {
      task.cancel()
      return
    }
    tasks[id] = task
  }

  func remove(id: UUID) {
    if tasks.removeValue(forKey: id) == nil {
      completedBeforeRegistration.insert(id)
    }
  }

  func beginDrainingAndCancelAll() {
    draining = true
    let activeTasks = tasks.values
    tasks.removeAll()
    completedBeforeRegistration.removeAll()
    for task in activeTasks {
      task.cancel()
    }
  }
}

private actor RequestExecutionCleanup {
  private let requestLimiter: RequestLimiter
  private let taskRegistry: TransportTaskRegistry
  private let taskID: UUID
  private let requiresSharedPermit: Bool
  private var acquiredSharedPermit = false
  private var finished = false

  init(
    requestLimiter: RequestLimiter,
    taskRegistry: TransportTaskRegistry,
    taskID: UUID,
    requiresSharedPermit: Bool
  ) {
    self.requestLimiter = requestLimiter
    self.taskRegistry = taskRegistry
    self.taskID = taskID
    self.requiresSharedPermit = requiresSharedPermit
  }

  func acquirePermit() async -> Bool {
    guard !finished else {
      return false
    }
    guard requiresSharedPermit else {
      return !Task.isCancelled
    }
    guard await requestLimiter.acquire() else {
      return false
    }
    acquiredSharedPermit = true
    return true
  }

  func finish() async {
    guard !finished else {
      return
    }
    finished = true
    if acquiredSharedPermit {
      acquiredSharedPermit = false
      await requestLimiter.release()
    }
    await taskRegistry.remove(id: taskID)
  }
}

private final class DemandDrivenRequestBodySource: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumBufferedChunks: Int
  private let requestRead: @Sendable () -> Void
  private let cancelChannel: @Sendable () -> Void
  private var buffered: [Data] = []
  private var waiter: CheckedContinuation<Data?, any Error>?
  private var terminalResult: Result<Void, any Error>?

  init(
    maximumBufferedChunks: Int,
    requestRead: @escaping @Sendable () -> Void,
    cancelChannel: @escaping @Sendable () -> Void
  ) {
    self.maximumBufferedChunks = maximumBufferedChunks
    self.requestRead = requestRead
    self.cancelChannel = cancelChannel
  }

  func next() async throws -> Data? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if !buffered.isEmpty {
          let value = buffered.removeFirst()
          lock.unlock()
          continuation.resume(returning: value)
          return
        }
        if let terminalResult {
          lock.unlock()
          continuation.resume(with: terminalResult.map { nil })
          return
        }
        waiter = continuation
        lock.unlock()
        requestRead()
      }
    } onCancel: {
      self.fail(CancellationError())
      self.cancelChannel()
    }
  }

  var isWaitingForData: Bool {
    lock.lock()
    defer { lock.unlock() }
    return waiter != nil
  }

  func receive(_ chunks: [Data]) -> Bool {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return false
    }
    var values = chunks
    let waiter = self.waiter
    self.waiter = nil
    let first = waiter == nil || values.isEmpty ? nil : values.removeFirst()
    let deliveredCount = first == nil ? 0 : 1
    guard deliveredCount + buffered.count + values.count <= maximumBufferedChunks else {
      let overflowWaiter = waiter
      terminalResult = .failure(BackendError.capacityExceeded)
      lock.unlock()
      overflowWaiter?.resume(throwing: BackendError.capacityExceeded)
      return false
    }
    buffered.append(contentsOf: values)
    lock.unlock()
    if let waiter, let first {
      waiter.resume(returning: first)
    } else if let waiter {
      waiter.resume(throwing: BackendError.consistencyFailure)
      return false
    }
    return true
  }

  func finish() {
    complete(.success(()))
  }

  func fail(_ error: any Error) {
    complete(.failure(error))
  }

  private func complete(_ result: Result<Void, any Error>) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = result
    let waiter = self.waiter
    self.waiter = nil
    lock.unlock()
    waiter?.resume(with: result.map { nil })
  }
}
