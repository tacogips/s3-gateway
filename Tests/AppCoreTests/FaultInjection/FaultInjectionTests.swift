import Foundation
import Testing
@testable import AppCore

@Suite("FaultInjectionTests")
struct FaultInjectionTests {
  @Test("Body failure removes staging and publishes nothing")
  func bodyFailureRollsBack() async throws {
    let fixture = try POSIXFaultFixture()
    defer { fixture.remove() }
    let backend = try fixture.backend()
    let body = AsyncThrowingStream<Data, any Error> { continuation in
      continuation.yield(Data("partial".utf8))
      continuation.finish(throwing: BackendError.capacityExceeded)
    }

    await #expect(throws: BackendError.capacityExceeded) {
      _ = try await backend.putObject(
        try fixture.request(body: ObjectBodyStream(maximumChunkBytes: 4_096, stream: body)),
        context: fixture.context
      )
    }
    try await fixture.expectAbsentAndNoStaging(backend)
  }

  @Test(
    "Pre-publication durability failures roll back",
    arguments: [POSIXFaultPoint.dataSynchronization, .commitRecord]
  )
  func prepublicationFailureRollsBack(point: POSIXFaultPoint) async throws {
    let fixture = try POSIXFaultFixture()
    defer { fixture.remove() }
    let backend = try fixture.backend(failingAt: [point])

    await #expect(throws: BackendError.consistencyFailure) {
      _ = try await backend.putObject(
        try fixture.request(body: ObjectBodyStream(data: fixture.value, maximumChunkBytes: 4)),
        context: fixture.context
      )
    }
    try await fixture.expectAbsentAndNoStaging(backend)
  }

  @Test("Metadata publication failure leaves a restart-recoverable commit")
  func metadataFailureRecoversOnRestart() async throws {
    let fixture = try POSIXFaultFixture()
    defer { fixture.remove() }
    let interrupted = try fixture.backend(failingAt: [.metadataPublication])

    await #expect(throws: BackendError.consistencyFailure) {
      _ = try await interrupted.putObject(
        try fixture.request(body: ObjectBodyStream(data: fixture.value, maximumChunkBytes: 4)),
        context: fixture.context
      )
    }

    let recovered = try fixture.backend()
    let result = try await recovered.getObject(
      GetObjectRequest(bucket: fixture.bucket, key: fixture.key),
      context: fixture.context
    )
    let collector = FaultCollector()
    try await result.body.consume { await collector.append($0) }
    #expect(await collector.data == fixture.value)
    #expect(result.metadata.userMetadata["fault-suite"] == "recoverable")
    #expect(try fixture.commitFiles().isEmpty)
  }

  @Test("Cancellation is typed and removes unpublished state")
  func cancellationRollsBack() async throws {
    let fixture = try POSIXFaultFixture()
    defer { fixture.remove() }
    let backend = try fixture.backend()
    let pair = AsyncThrowingStream<Data, any Error>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    pair.continuation.yield(Data(repeating: 1, count: 4_096))
    let task = Task {
      try await backend.putObject(
        try fixture.request(
          body: ObjectBodyStream(maximumChunkBytes: 4_096, stream: pair.stream)
        ),
        context: fixture.context
      )
    }
    await Task.yield()
    task.cancel()
    pair.continuation.finish()

    await #expect(throws: BackendError.cancelled) {
      _ = try await task.value
    }
    try await fixture.expectAbsentAndNoStaging(backend)
  }
}

private struct POSIXFaultFixture {
  let base: URL
  let root: URL
  let sidecar: URL
  let bucketDirectory: URL
  let bucket: BucketName
  let key: ObjectKey
  let principalID: PrincipalID
  let value = Data("recoverable-value".utf8)

  var context: RequestContext {
    RequestContext(
      requestID: "fault-injection",
      principalID: principalID,
      deadline: Date().addingTimeInterval(30)
    )
  }

  init() throws {
    guard let bucket = BucketName(rawValue: "fault-bucket"),
          let principalID = PrincipalID(rawValue: "fault-suite") else {
      throw BackendError.consistencyFailure
    }
    self.bucket = bucket
    self.principalID = principalID
    key = try ObjectKey(validating: "fault/object.bin")
    base = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    root = base.appendingPathComponent("root", isDirectory: true)
    sidecar = base.appendingPathComponent("sidecar", isDirectory: true)
    bucketDirectory = root.appendingPathComponent("bucket", isDirectory: true)
    try FileManager.default.createDirectory(
      at: bucketDirectory,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: sidecar,
      withIntermediateDirectories: true
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: sidecar.path
    )
  }

  func backend(failingAt points: Set<POSIXFaultPoint> = []) throws -> POSIXBackend {
    try POSIXBackend(
      configuration: POSIXBackendConfiguration(
        rootPath: root.path,
        bucketDirectories: [bucket.rawValue: "bucket"],
        layoutPolicy: .managedPrivateLayout,
        sidecarPath: sidecar.path,
        durability: .data
      ),
      maximumChunkBytes: 4_096,
      faultInjector: POSIXFaultInjector(failingPoints: points)
    )
  }

  func request(body: ObjectBodyStream) throws -> PutObjectRequest {
    PutObjectRequest(
      bucket: bucket,
      key: key,
      body: body,
      knownContentLength: nil,
      contentType: "application/octet-stream",
      userMetadata: ["fault-suite": "recoverable"]
    )
  }

  func expectAbsentAndNoStaging(_ backend: POSIXBackend) async throws {
    await #expect(throws: BackendError.notFound) {
      _ = try await backend.headObject(
        HeadObjectRequest(bucket: bucket, key: key),
        context: context
      )
    }
    let staging = sidecar
      .appendingPathComponent(".swift-s3-gateway-staging", isDirectory: true)
      .appendingPathComponent(bucket.rawValue, isDirectory: true)
    if FileManager.default.fileExists(atPath: staging.path) {
      #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }
  }

  func commitFiles() throws -> [String] {
    let root = sidecar
      .appendingPathComponent(".swift-s3-gateway-commits", isDirectory: true)
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.subpathsOfDirectory(atPath: root.path)
      .filter { $0.hasSuffix(".json") }
  }

  func remove() {
    try? FileManager.default.removeItem(at: base)
  }
}

private actor FaultCollector {
  private(set) var data = Data()

  func append(_ chunk: Data) {
    data.append(chunk)
  }
}
