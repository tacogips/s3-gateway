import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
@preconcurrency import NIOSSL

final class NIOUpstreamHTTPClient: UpstreamHTTPClient, @unchecked Sendable {
  private let group: MultiThreadedEventLoopGroup
  private let sslContext: NIOSSLContext
  private let maximumChunkBytes: Int
  private let maximumBufferedChunks: Int
  private let maximumHeaderBytes: Int
  private let requestTimeoutSeconds: Int

  init(
    maximumChunkBytes: Int,
    maximumInFlightBytes: Int,
    maximumHeaderBytes: Int,
    requestTimeoutSeconds: Int,
    trustedCAPath: String?
  ) throws {
    group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, min(4, System.coreCount)))
    var tls = NIOSSL.TLSConfiguration.makeClientConfiguration()
    tls.minimumTLSVersion = .tlsv12
    tls.certificateVerification = .fullVerification
    if let trustedCAPath {
      tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(trustedCAPath))
    }
    sslContext = try NIOSSLContext(configuration: tls)
    self.maximumChunkBytes = maximumChunkBytes
    maximumBufferedChunks = max(1, maximumInFlightBytes / maximumChunkBytes)
    self.maximumHeaderBytes = maximumHeaderBytes
    self.requestTimeoutSeconds = requestTimeoutSeconds
  }

  deinit {
    try? group.syncShutdownGracefully()
  }

  func execute(_ request: UpstreamHTTPRequest) async throws -> UpstreamHTTPResponse {
    guard request.url.scheme == "https", let host = request.url.host else { throw BackendError.accessDenied }
    let port = request.url.port ?? 443
    let connectTimeout = try effectiveTimeout(deadline: request.deadline)
    let state = UpstreamResponseState(
      maximumChunkBytes: maximumChunkBytes,
      maximumBufferedChunks: maximumBufferedChunks
    )
    return try await withTaskCancellationHandler {
      try await execute(
        request,
        host: host,
        port: port,
        connectTimeout: connectTimeout,
        state: state
      )
    } onCancel: {
      state.cancel()
    }
  }

  private func execute(
    _ request: UpstreamHTTPRequest,
    host: String,
    port: Int,
    connectTimeout: TimeAmount,
    state: UpstreamResponseState
  ) async throws -> UpstreamHTTPResponse {
    let channel = try await ClientBootstrap(group: group)
      .connectTimeout(connectTimeout)
      .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .channelOption(
        ChannelOptions.recvAllocator,
        value: FixedSizeRecvByteBufferAllocator(capacity: maximumChunkBytes)
      )
      .channelInitializer { channel in
        do {
          let tlsHandler = try NIOSSLClientHandler(context: self.sslContext, serverHostname: host)
          try channel.pipeline.syncOperations.addHandler(tlsHandler)
          var decoderLimits = NIOHTTPDecoderLimitConfiguration()
          decoderLimits.maxHeaderFieldSize = self.maximumHeaderBytes
          decoderLimits.maxHeaderListSize = self.maximumHeaderBytes
          decoderLimits.maxHeaderFieldCount = max(1, min(1_024, self.maximumHeaderBytes / 2))
          try channel.pipeline.syncOperations.addHTTPClientHandlers(
            decoderLimitConfiguration: decoderLimits
          )
          try channel.pipeline.syncOperations.addHandler(
            UpstreamResponseHandler(state: state, requestMethod: request.method)
          )
          return channel.eventLoop.makeSucceededVoidFuture()
        } catch {
          return channel.eventLoop.makeFailedFuture(error)
        }
      }
      .connect(host: host, port: port)
      .get()
    state.setChannel(channel)
    let responseTimeout: TimeAmount
    do {
      responseTimeout = try effectiveTimeout(deadline: request.deadline)
    } catch {
      channel.close(promise: nil)
      throw error
    }
    let timeoutTask = channel.eventLoop.scheduleTask(in: responseTimeout) {
      state.fail(BackendError.deadlineExceeded)
      channel.close(promise: nil)
    }
    state.setTimeoutTask(timeoutTask)
    do {
      var headers = HTTPHeaders(request.headers)
      headers.replaceOrAdd(name: "host", value: Self.hostHeader(url: request.url))
      headers.replaceOrAdd(name: "connection", value: "close")
      if request.body != nil,
         !headers.contains(name: "content-length"),
         !headers.contains(name: "transfer-encoding") {
        headers.add(name: "transfer-encoding", value: "chunked")
      }
      let uri = request.url.path.isEmpty ? "/" : request.url.path
      let target = request.url.query.map { uri + "?" + $0 } ?? uri
      let method = HTTPMethod(rawValue: request.method)
      try await channel.writeAndFlush(
        HTTPClientRequestPart.head(
          HTTPRequestHead(version: .http1_1, method: method, uri: target, headers: headers)
        )
      ).get()
      if let body = request.body {
        try await body.consume { chunk in
          var buffer = channel.allocator.buffer(capacity: chunk.count)
          buffer.writeBytes(chunk)
          try await channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer))).get()
        }
      }
      try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
      let response = try await state.waitForResponse()
      if request.method == "HEAD" ||
         response.status == 204 ||
         response.status == 304 ||
         response.header("content-length") == "0" {
        try await state.waitForEmptyBodyCompletion()
      }
      return response
    } catch {
      try? await channel.close().get()
      throw error
    }
  }

  private static func hostHeader(url: URL) -> String {
    guard let host = url.host else { return "" }
    guard let port = url.port, port != 443 else { return host }
    return "\(host):\(port)"
  }

  private func effectiveTimeout(deadline: Date?) throws -> TimeAmount {
    let configured = TimeInterval(requestTimeoutSeconds)
    let interval = min(configured, deadline?.timeIntervalSinceNow ?? configured)
    guard interval > 0 else { throw BackendError.deadlineExceeded }
    return .nanoseconds(max(1, Int64(interval * 1_000_000_000)))
  }
}

private final class UpstreamResponseState: @unchecked Sendable {
  private let lock = NSLock()
  private let maximumChunkBytes: Int
  private let maximumBufferedChunks: Int
  private var responseHead: HTTPResponseHead?
  private var waiter: CheckedContinuation<HTTPResponseHead, any Error>?
  private var terminalError: (any Error)?
  private var timeoutTask: Scheduled<Void>?
  private var channel: Channel?
  private var bufferedBody: [Data] = []
  private var bodyWaiter: CheckedContinuation<Data?, any Error>?
  private var bodyTerminalResult: Result<Void, any Error>?
  private var completed = false

  init(maximumChunkBytes: Int, maximumBufferedChunks: Int) {
    self.maximumChunkBytes = maximumChunkBytes
    let tlsRecordChunks = (16 * 1_024 + maximumChunkBytes - 1) / maximumChunkBytes
    self.maximumBufferedChunks = max(maximumBufferedChunks, tlsRecordChunks)
  }

  func waitForResponse() async throws -> UpstreamHTTPResponse {
    let head = try await withCheckedThrowingContinuation { continuation in
      lock.lock()
      if let responseHead {
        lock.unlock()
        continuation.resume(returning: responseHead)
      } else if let terminalError {
        lock.unlock()
        continuation.resume(throwing: terminalError)
      } else {
        waiter = continuation
        lock.unlock()
      }
    }
    var headers: [String: [String]] = [:]
    for header in head.headers { headers[header.name, default: []].append(header.value) }
    return UpstreamHTTPResponse(
      status: Int(head.status.code),
      headers: headers,
      body: ObjectBodyStream(
        maximumChunkBytes: maximumChunkBytes,
        stream: AsyncThrowingStream(unfolding: { try await self.nextBodyChunk() })
      )
    )
  }

  func setChannel(_ channel: Channel) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      channel.close(promise: nil)
      return
    }
    self.channel = channel
    lock.unlock()
  }

  func cancel() {
    fail(CancellationError())
    closeChannel()
  }

  func waitForEmptyBodyCompletion() async throws {
    guard try await nextBodyChunk() == nil else {
      throw BackendError.consistencyFailure
    }
  }

  func receive(head: HTTPResponseHead) {
    lock.lock()
    guard !completed, responseHead == nil else {
      lock.unlock()
      return
    }
    responseHead = head
    let waiter = self.waiter
    self.waiter = nil
    lock.unlock()
    waiter?.resume(returning: head)
  }

  func setTimeoutTask(_ timeoutTask: Scheduled<Void>) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      timeoutTask.cancel()
      return
    }
    self.timeoutTask = timeoutTask
    lock.unlock()
  }

  func receive(body: Data) -> Bool {
    var chunks: [Data] = []
    var offset = 0
    while offset < body.count {
      let end = min(offset + maximumChunkBytes, body.count)
      chunks.append(body.subdata(in: offset..<end))
      offset = end
    }
    lock.lock()
    guard !completed, bodyTerminalResult == nil else {
      lock.unlock()
      return false
    }
    let waiter = bodyWaiter
    bodyWaiter = nil
    let first = waiter == nil || chunks.isEmpty ? nil : chunks.removeFirst()
    guard bufferedBody.count + chunks.count <= maximumBufferedChunks else {
      lock.unlock()
      fail(BackendError.capacityExceeded)
      return false
    }
    bufferedBody.append(contentsOf: chunks)
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
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    bodyTerminalResult = .success(())
    timeoutTask?.cancel()
    timeoutTask = nil
    let bodyWaiter = self.bodyWaiter
    self.bodyWaiter = nil
    if responseHead == nil {
      let error = BackendError.unavailable(retryable: true)
      terminalError = error
      bodyTerminalResult = .failure(error)
      let waiter = self.waiter
      self.waiter = nil
      lock.unlock()
      waiter?.resume(throwing: error)
      bodyWaiter?.resume(throwing: error)
      return
    }
    lock.unlock()
    bodyWaiter?.resume(returning: nil)
  }

  func fail(_ error: any Error) {
    lock.lock()
    guard !completed else {
      lock.unlock()
      return
    }
    completed = true
    terminalError = error
    bodyTerminalResult = .failure(error)
    timeoutTask?.cancel()
    timeoutTask = nil
    let waiter = self.waiter
    self.waiter = nil
    let bodyWaiter = self.bodyWaiter
    self.bodyWaiter = nil
    lock.unlock()
    waiter?.resume(throwing: error)
    bodyWaiter?.resume(throwing: error)
  }

  private func nextBodyChunk() async throws -> Data? {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.lock()
        if !bufferedBody.isEmpty {
          let body = bufferedBody.removeFirst()
          lock.unlock()
          continuation.resume(returning: body)
          return
        }
        if let bodyTerminalResult {
          lock.unlock()
          continuation.resume(with: bodyTerminalResult.map { nil })
          return
        }
        bodyWaiter = continuation
        let channel = self.channel
        lock.unlock()
        channel?.eventLoop.execute {
          channel?.read()
        }
      }
    } onCancel: {
      self.fail(CancellationError())
      self.closeChannel()
    }
  }

  private func closeChannel() {
    lock.lock()
    let channel = self.channel
    lock.unlock()
    channel?.eventLoop.execute {
      channel?.close(promise: nil)
    }
  }

  var isWaitingForBodyData: Bool {
    lock.lock()
    defer { lock.unlock() }
    return bodyWaiter != nil
  }
}

private final class UpstreamResponseHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = HTTPClientResponsePart

  private let state: UpstreamResponseState
  private let requestMethod: String

  init(state: UpstreamResponseState, requestMethod: String) {
    self.state = state
    self.requestMethod = requestMethod
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      if !(100..<200).contains(head.status.code) || head.status.code == 101 {
        state.receive(head: head)
        let shouldDrainEnd = requestMethod == "HEAD" ||
          head.status.code == 204 ||
          head.status.code == 304 ||
          head.headers.first(name: "content-length") == "0"
        let transferredContext = UnsafeUpstreamSendable(value: context)
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
          if shouldDrainEnd {
            transferredContext.value.read()
          }
        }
      }
    case .body(var buffer):
      guard let bytes = buffer.readBytes(length: buffer.readableBytes) else {
        state.fail(BackendError.unavailable(retryable: true))
        return
      }
      if !state.receive(body: Data(bytes)) { context.close(promise: nil) }
    case .end:
      state.finish()
      let transferredContext = UnsafeUpstreamSendable(value: context)
      context.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in
        transferredContext.value.close(promise: nil)
      }
    }
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    if state.isWaitingForBodyData {
      context.read()
    }
    context.fireChannelReadComplete()
  }

  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    state.fail(error)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    state.finish()
  }
}

private struct UnsafeUpstreamSendable<Value>: @unchecked Sendable {
  let value: Value
}
