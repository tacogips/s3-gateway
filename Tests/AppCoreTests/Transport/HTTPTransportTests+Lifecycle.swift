import Darwin
import Foundation
import Testing
@testable import AppCore

@Test func nioTransportDisconnectCancelsApplicationTaskAndReleasesSharedCapacity() async throws {
  let transport = makeLifecycleTransport(requestTimeoutSeconds: 10)
  let lifecycle = TransportApplicationLifecycleProbe()
  try await transport.start { request in
    if request.rawPath == "/blocked" {
      await lifecycle.blockUntilCancelled()
      return HTTPTransportResponse(status: 500)
    }
    return HTTPTransportResponse(status: 200)
  }
  let port = try #require(await transport.localPort)
  let descriptor = try openLifecycleHTTPRequest(
    port: port,
    request:
      "GET /blocked HTTP/1.1\r\n" +
      "Host: localhost\r\n" +
      "Connection: close\r\n\r\n"
  )
  await lifecycle.waitUntilStarted()
  close(descriptor)
  await lifecycle.waitUntilCancelled()
  while !(await transport.isSharedRequestLimiterIdle) {
    await Task.yield()
  }

  let url = try #require(URL(string: "http://127.0.0.1:\(port)/after-disconnect"))
  let (_, response) = try await URLSession.shared.data(from: url)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  try await transport.stop()
}

@Test func nioTransportTimeoutCancelsApplicationTaskAndReleasesSharedCapacity() async throws {
  let transport = makeLifecycleTransport(requestTimeoutSeconds: 1)
  let lifecycle = TransportApplicationLifecycleProbe()
  try await transport.start { request in
    if request.rawPath == "/timeout" {
      await lifecycle.blockUntilCancelled()
      return HTTPTransportResponse(status: 500)
    }
    return HTTPTransportResponse(status: 200)
  }
  let port = try #require(await transport.localPort)
  let timeoutURL = try #require(URL(string: "http://127.0.0.1:\(port)/timeout"))
  let timedOutRequest = Task {
    try await URLSession.shared.data(from: timeoutURL)
  }
  await lifecycle.waitUntilStarted()
  await lifecycle.waitUntilCancelled()
  while !(await transport.isSharedRequestLimiterIdle) {
    await Task.yield()
  }
  await #expect(throws: (any Error).self) {
    _ = try await timedOutRequest.value
  }

  let recoveryURL = try #require(URL(string: "http://127.0.0.1:\(port)/after-timeout"))
  let (_, response) = try await URLSession.shared.data(from: recoveryURL)
  #expect((response as? HTTPURLResponse)?.statusCode == 200)
  try await transport.stop()
}

@Test func readinessTrafficCannotConsumeAuthenticatedRequestCapacity() async throws {
  let healthClassifier = HealthRouteClassifier(
    configuration: HealthEndpointConfiguration()
  )
  let transport = NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      developmentPlaintext: true
    ),
    limits: lifecycleLimits(requestTimeoutSeconds: 10),
    healthClassifier: healthClassifier
  )
  let admission = TransportReadinessAdmissionProbe()
  try await transport.start { request in
    if request.healthAdmission == .readiness {
      await admission.blockReadiness()
    }
    return HTTPTransportResponse(status: 200)
  }
  let port = try #require(await transport.localPort)
  let readinessURL = try #require(
    URL(string: "http://127.0.0.1:\(port)/.well-known/swift-s3-gateway/ready")
  )
  let readinessRequest = Task {
    try await URLSession.shared.data(from: readinessURL)
  }
  await admission.waitUntilStarted()

  let objectURL = try #require(URL(string: "http://127.0.0.1:\(port)/my-bucket/object"))
  let (_, objectResponse) = try await URLSession.shared.data(from: objectURL)
  #expect((objectResponse as? HTTPURLResponse)?.statusCode == 200)

  await admission.releaseReadiness()
  let (_, readinessResponse) = try await readinessRequest.value
  #expect((readinessResponse as? HTTPURLResponse)?.statusCode == 200)
  try await transport.stop()
}

@Test func nioTransportShutdownCancelsActiveApplicationTask() async throws {
  let transport = makeLifecycleTransport(requestTimeoutSeconds: 2)
  let lifecycle = TransportApplicationLifecycleProbe()
  try await transport.start { _ in
    await lifecycle.blockUntilCancelled()
    return HTTPTransportResponse(status: 500)
  }
  let port = try #require(await transport.localPort)
  let url = try #require(URL(string: "http://127.0.0.1:\(port)/shutdown"))
  let client = Task {
    try await URLSession.shared.data(from: url)
  }
  await lifecycle.waitUntilStarted()
  try await transport.stop()
  await lifecycle.waitUntilCancelled()
  await #expect(throws: (any Error).self) {
    _ = try await client.value
  }
}

private func makeLifecycleTransport(requestTimeoutSeconds: Int) -> NIOHTTPTransport {
  NIOHTTPTransport(
    configuration: ListenerConfiguration(
      host: "127.0.0.1",
      port: 0,
      developmentPlaintext: true
    ),
    limits: lifecycleLimits(requestTimeoutSeconds: requestTimeoutSeconds)
  )
}

private func lifecycleLimits(requestTimeoutSeconds: Int) -> GatewayLimits {
  GatewayLimits(
    maximumHeaderBytes: 8_192,
    maximumXMLBytes: 8_192,
    maximumObjectBytes: 1_024 * 1_024,
    maximumChunkBytes: 4_096,
    maximumInFlightBytes: 4_096,
    maximumConcurrentRequests: 1,
    requestTimeoutSeconds: requestTimeoutSeconds
  )
}

private actor TransportApplicationLifecycleProbe {
  private var started = false
  private var cancelled = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

  func blockUntilCancelled() async {
    started = true
    let startWaiters = self.startWaiters
    self.startWaiters.removeAll()
    for waiter in startWaiters {
      waiter.resume()
    }
    do {
      try await Task.sleep(for: .seconds(30))
    } catch {
      cancelled = true
      let cancellationWaiters = self.cancellationWaiters
      self.cancellationWaiters.removeAll()
      for waiter in cancellationWaiters {
        waiter.resume()
      }
    }
  }

  func waitUntilStarted() async {
    guard !started else {
      return
    }
    await withCheckedContinuation {
      startWaiters.append($0)
    }
  }

  func waitUntilCancelled() async {
    guard !cancelled else {
      return
    }
    await withCheckedContinuation {
      cancellationWaiters.append($0)
    }
  }
}

private actor TransportReadinessAdmissionProbe {
  private var started = false
  private var released = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func blockReadiness() async {
    started = true
    let startWaiters = self.startWaiters
    self.startWaiters.removeAll()
    for waiter in startWaiters {
      waiter.resume()
    }
    guard !released else {
      return
    }
    await withCheckedContinuation {
      releaseWaiters.append($0)
    }
  }

  func waitUntilStarted() async {
    guard !started else {
      return
    }
    await withCheckedContinuation {
      startWaiters.append($0)
    }
  }

  func releaseReadiness() {
    released = true
    let releaseWaiters = self.releaseWaiters
    self.releaseWaiters.removeAll()
    for waiter in releaseWaiters {
      waiter.resume()
    }
  }
}

private func openLifecycleHTTPRequest(
  port: Int,
  request: String
) throws -> Int32 {
  let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  guard descriptor >= 0 else {
    throw LifecycleSocketError.failed("socket failed")
  }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(port).bigEndian
  guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
    close(descriptor)
    throw LifecycleSocketError.failed("inet_pton failed")
  }
  let connected = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(
        descriptor,
        $0,
        socklen_t(MemoryLayout<sockaddr_in>.size)
      )
    }
  }
  guard connected == 0 else {
    close(descriptor)
    throw LifecycleSocketError.failed("connect failed")
  }
  let bytes = Data(request.utf8)
  try bytes.withUnsafeBytes { rawBuffer in
    guard let baseAddress = rawBuffer.baseAddress else {
      return
    }
    var offset = 0
    while offset < rawBuffer.count {
      let written = Darwin.write(
        descriptor,
        baseAddress.advanced(by: offset),
        rawBuffer.count - offset
      )
      guard written > 0 else {
        close(descriptor)
        throw LifecycleSocketError.failed("write failed")
      }
      offset += written
    }
  }
  return descriptor
}

private enum LifecycleSocketError: Error {
  case failed(String)
}
