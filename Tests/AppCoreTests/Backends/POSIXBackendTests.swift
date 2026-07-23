import Darwin
import Foundation
import Testing
@testable import AppCore

@Test func sharedDirectoryReconcilesExistingAndExternallyModifiedFiles() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let existing = fixture.bucketURL.appendingPathComponent("existing.txt")
  try Data("first".utf8).write(to: existing)
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "existing.txt")
  let context = try makeContext()

  let first = try await backend.headObject(HeadObjectRequest(bucket: bucket, key: key), context: context)
  #expect(first.contentLength == 5)
  let firstETag = first.entityTag

  try Data("second-value".utf8).write(to: existing, options: .atomic)
  let second = try await backend.headObject(HeadObjectRequest(bucket: bucket, key: key), context: context)
  #expect(second.contentLength == 12)
  #expect(second.entityTag != firstETag)

  let listed = try await backend.listObjectsV2(ListObjectsV2Request(bucket: bucket), context: context)
  #expect(listed.objects.map(\.key.rawValue) == ["existing.txt"])

  let renamed = fixture.bucketURL.appendingPathComponent("renamed.txt")
  try FileManager.default.moveItem(at: existing, to: renamed)
  await #expect(throws: BackendError.notFound) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: key),
      context: context
    )
  }
  let renamedList = try await backend.listObjectsV2(
    ListObjectsV2Request(bucket: bucket),
    context: context
  )
  #expect(renamedList.objects.map(\.key.rawValue) == ["renamed.txt"])

  try FileManager.default.removeItem(at: renamed)
  let deletedList = try await backend.listObjectsV2(
    ListObjectsV2Request(bucket: bucket),
    context: context
  )
  #expect(deletedList.objects.isEmpty)
}

@Test func posixBackendRecoversAbandonedSidecarStagingFiles() throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let staging = fixture.sidecarURL
    .appendingPathComponent(".swift-s3-gateway-staging/my-bucket", isDirectory: true)
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  let abandoned = staging.appendingPathComponent(".swift-s3-gateway-\(UUID().uuidString).tmp")
  try Data("partial".utf8).write(to: abandoned)
  _ = try fixture.makeBackend(policy: .sharedLocalDirectory)
  #expect(!FileManager.default.fileExists(atPath: abandoned.path))
}

@Test func posixRecoveryCompletesMetadataAfterPublishedData() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "recovered-published.txt")
  let interrupted = try makeInterruptedPOSIXCommit(
    fixture: fixture,
    bucket: bucket,
    key: key,
    value: Data("published-before-crash".utf8)
  )
  try interrupted.mapper.publish(interrupted.temporary, durability: .data)
  close(interrupted.temporary.temporaryParentDescriptor)
  close(interrupted.temporary.destinationParentDescriptor)

  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let metadata = try await backend.headObject(
    HeadObjectRequest(bucket: bucket, key: key),
    context: makeContext()
  )
  #expect(metadata.userMetadata["recovery"] == "preserved")
  #expect(
    !FileManager.default.fileExists(
      atPath: interrupted.mapper.commitFileURL(bucket: bucket, key: key).path
    )
  )
}

@Test func posixRecoveryPublishesRecognizableStagedCommit() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "recovered-staged.txt")
  let value = Data("staged-before-crash".utf8)
  let interrupted = try makeInterruptedPOSIXCommit(
    fixture: fixture,
    bucket: bucket,
    key: key,
    value: value
  )
  close(interrupted.temporary.temporaryParentDescriptor)
  close(interrupted.temporary.destinationParentDescriptor)

  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let result = try await backend.getObject(
    GetObjectRequest(bucket: bucket, key: key),
    context: makeContext()
  )
  let collector = POSIXDataCollector()
  try await result.body.consume { await collector.append($0) }
  #expect(await collector.data == value)
  #expect(result.metadata.userMetadata["recovery"] == "preserved")
}

@Test func posixRecoveryDoesNotOverwriteExternalReplacement() throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "externally-replaced.txt")
  let interrupted = try makeInterruptedPOSIXCommit(
    fixture: fixture,
    bucket: bucket,
    key: key,
    value: Data("gateway-value".utf8)
  )
  close(interrupted.temporary.temporaryParentDescriptor)
  close(interrupted.temporary.destinationParentDescriptor)
  let destination = fixture.bucketURL.appendingPathComponent(key.rawValue)
  try Data("external-value".utf8).write(to: destination)

  #expect(throws: BackendError.consistencyFailure) {
    _ = try fixture.makeBackend(policy: .sharedLocalDirectory)
  }
  #expect(try Data(contentsOf: destination) == Data("external-value".utf8))
}

@Test func posixRecoveryRollsBackCommitWhoseStageWasRemoved() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "rollback.txt")
  let destination = fixture.bucketURL.appendingPathComponent(key.rawValue)
  let original = Data("original-value".utf8)
  try original.write(to: destination)
  let interrupted = try makeInterruptedPOSIXCommit(
    fixture: fixture,
    bucket: bucket,
    key: key,
    value: Data("unpublished-value".utf8)
  )
  interrupted.mapper.removeTemporary(interrupted.temporary)
  close(interrupted.temporary.temporaryParentDescriptor)
  close(interrupted.temporary.destinationParentDescriptor)

  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let result = try await backend.getObject(
    GetObjectRequest(bucket: bucket, key: key),
    context: makeContext()
  )
  let collector = POSIXDataCollector()
  try await result.body.consume { await collector.append($0) }
  #expect(await collector.data == original)
  #expect(
    !FileManager.default.fileExists(
      atPath: interrupted.mapper.commitFileURL(bucket: bucket, key: key).path
    )
  )
}

@Test func posixRecoveryFailsClosedForMalformedCommitRecord() throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "malformed.txt")
  let mapper = try fixture.makeMapper(policy: .sharedLocalDirectory)
  let commit = mapper.commitFileURL(bucket: bucket, key: key)
  try FileManager.default.createDirectory(
    at: commit.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try Data("not-json".utf8).write(to: commit)

  #expect(throws: BackendError.consistencyFailure) {
    _ = try fixture.makeBackend(policy: .sharedLocalDirectory)
  }
  #expect(FileManager.default.fileExists(atPath: commit.path))
}

@Test func posixMetadataReadDoesNotFollowSubstitutedSidecarSymlink() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "sidecar-symlink.txt")
  let object = fixture.bucketURL.appendingPathComponent(key.rawValue)
  try Data("object".utf8).write(to: object)
  let mapper = try fixture.makeMapper(policy: .sharedLocalDirectory)
  let observedIdentity = try mapper.objectIdentity(bucket: bucket, key: key)
  let identity = try #require(observedIdentity)
  let outside = fixture.baseURL.appendingPathComponent("outside-sidecar.json")
  guard let entityTag = EntityTag(rawValue: "\"forged\"") else {
    throw BackendError.consistencyFailure
  }
  let forged = POSIXMetadataRecord(
    version: 1,
    identity: identity,
    metadata: ObjectMetadata(
      contentType: nil,
      contentLength: identity.size,
      lastModified: identity.date,
      entityTag: entityTag,
      userMetadata: ["secret": "outside"],
      versionToken: identity.versionToken
    )
  )
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .millisecondsSince1970
  let forgedData = try encoder.encode(forged)
  try forgedData.write(to: outside)
  let sidecar = mapper.sidecarFileURL(bucket: bucket, key: key)
  try FileManager.default.createDirectory(
    at: sidecar.deletingLastPathComponent(),
    withIntermediateDirectories: true
  )
  try FileManager.default.createSymbolicLink(
    at: sidecar,
    withDestinationURL: outside
  )

  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let metadata = try await backend.headObject(
    HeadObjectRequest(bucket: bucket, key: key),
    context: makeContext()
  )
  #expect(metadata.userMetadata.isEmpty)
  #expect(metadata.entityTag != entityTag)
  #expect(try Data(contentsOf: outside) == forgedData)
}

@Test func posixPutAndGetStreamWithoutWholeObjectAPI() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "nested/object.bin")
  let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
  let context = try makeContext()
  let put = try await backend.putObject(
    PutObjectRequest(
      bucket: bucket,
      key: key,
      body: ObjectBodyStream(data: bytes, maximumChunkBytes: 4_096),
      knownContentLength: Int64(bytes.count),
      contentType: "application/octet-stream",
      userMetadata: ["source": "test"]
    ),
    context: context
  )
  #expect(put.metadata.contentLength == Int64(bytes.count))
  #expect(put.metadata.userMetadata["source"] == "test")

  let get = try await backend.getObject(GetObjectRequest(bucket: bucket, key: key), context: context)
  let collector = POSIXDataCollector()
  try await get.body.consume { await collector.append($0) }
  #expect(await collector.data == bytes)
}

@Test func posixCapacityFailureRemovesStageAndPublishesNothing() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "capacity-failure.bin")
  let pair = AsyncThrowingStream<Data, any Error>.makeStream(
    bufferingPolicy: .bufferingOldest(1)
  )
  pair.continuation.yield(Data(repeating: 7, count: 4_096))
  pair.continuation.finish(throwing: BackendError.capacityExceeded)

  await #expect(throws: BackendError.capacityExceeded) {
    _ = try await backend.putObject(
      PutObjectRequest(
        bucket: bucket,
        key: key,
        body: ObjectBodyStream(
          maximumChunkBytes: 4_096,
          stream: pair.stream
        )
      ),
      context: makeContext()
    )
  }
  await #expect(throws: BackendError.notFound) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: key),
      context: makeContext()
    )
  }
  let staging = fixture.sidecarURL
    .appendingPathComponent(
      ".swift-s3-gateway-staging/my-bucket",
      isDirectory: true
    )
  #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
}

@Test func posixPermissionRevocationFailsWithoutServingObject() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let object = fixture.bucketURL.appendingPathComponent("permission.txt")
  try Data("private".utf8).write(to: object)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o000],
    ofItemAtPath: object.path
  )
  defer {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: object.path
    )
  }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  await #expect(throws: BackendError.accessDenied) {
    _ = try await backend.getObject(
      GetObjectRequest(
        bucket: bucket,
        key: ObjectKey(validating: "permission.txt")
      ),
      context: makeContext()
    )
  }
}

@Test func posixReplacementDuringReadNeverMixesGenerations() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "generation.bin")
  let original = Data(repeating: 17, count: 64 * 1_024)
  let replacement = Data(repeating: 29, count: 64 * 1_024)
  _ = try await backend.putObject(
    PutObjectRequest(
      bucket: bucket,
      key: key,
      body: ObjectBodyStream(data: original, maximumChunkBytes: 4_096)
    ),
    context: makeContext()
  )
  let result = try await backend.getObject(
    GetObjectRequest(bucket: bucket, key: key),
    context: makeContext()
  )
  let collector = POSIXDataCollector()
  let coordinator = POSIXReplacementCoordinator()
  do {
    try await result.body.consume { chunk in
      await collector.append(chunk)
      if await coordinator.takeFirst() {
        _ = try await backend.putObject(
          PutObjectRequest(
            bucket: bucket,
            key: key,
            body: ObjectBodyStream(
              data: replacement,
              maximumChunkBytes: 4_096
            )
          ),
          context: makeContext()
        )
      }
    }
    Issue.record("A replaced generation unexpectedly completed as unchanged.")
  } catch BackendError.consistencyFailure {
  }
  let observed = await collector.data
  #expect(!observed.isEmpty)
  #expect(observed == original.prefix(observed.count))
  #expect(!observed.contains(29))

  let current = try await backend.getObject(
    GetObjectRequest(bucket: bucket, key: key),
    context: makeContext()
  )
  let currentCollector = POSIXDataCollector()
  try await current.body.consume { await currentCollector.append($0) }
  #expect(await currentCollector.data == replacement)
}

@Test func managedPOSIXLayoutPreservesArbitraryKeysAndConditionalWrites() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .managedPrivateLayout)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "../logical//key")
  let context = try makeContext()
  _ = try await backend.putObject(
    PutObjectRequest(
      bucket: bucket,
      key: key,
      body: ObjectBodyStream(data: Data("managed".utf8)),
      conditions: WriteConditions(requireAbsent: true)
    ),
    context: context
  )
  await #expect(throws: BackendError.conditionFailed) {
    _ = try await backend.putObject(
      PutObjectRequest(
        bucket: bucket,
        key: key,
        body: ObjectBodyStream(data: Data("replacement".utf8)),
        conditions: WriteConditions(requireAbsent: true)
      ),
      context: context
    )
  }
  let listed = try await backend.listObjectsV2(ListObjectsV2Request(bucket: bucket), context: context)
  #expect(listed.objects.map(\.key.rawValue) == [key.rawValue])
  let capabilities = await backend.capabilities()
  #expect(capabilities.supported.contains(.conditionalWrite))
  #expect(capabilities.supported.contains(.strongReadAfterWrite))

  let boundaryKey = try ObjectKey(validating: String(repeating: "a", count: 150))
  let boundaryChildKey = try ObjectKey(validating: String(repeating: "a", count: 151))
  let maximumKey = try ObjectKey(validating: String(repeating: "z", count: 1_024))
  for value in [boundaryKey, boundaryChildKey, maximumKey] {
    _ = try await backend.putObject(
      PutObjectRequest(bucket: bucket, key: value, body: ObjectBodyStream(data: Data(value.rawValue.utf8))),
      context: context
    )
    let metadata = try await backend.headObject(HeadObjectRequest(bucket: bucket, key: value), context: context)
    #expect(metadata.contentLength == Int64(value.rawValue.utf8.count))
  }
}

@Test func sharedDirectoryDoesNotAdvertiseAtomicExternalConditions() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let capabilities = await backend.capabilities()
  #expect(!capabilities.supported.contains(.conditionalWrite))
  #expect(!capabilities.supported.contains(.strongReadAfterWrite))
}

@Test func posixReadConditionsApplyEntityTagPrecedence() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "conditions.txt")
  let context = try makeContext()
  let put = try await backend.putObject(
    PutObjectRequest(bucket: bucket, key: key, body: ObjectBodyStream(data: Data("value".utf8))),
    context: context
  )

  _ = try await backend.headObject(
    HeadObjectRequest(
      bucket: bucket,
      key: key,
      conditions: ReadConditions(
        ifMatch: [put.metadata.entityTag],
        ifUnmodifiedSince: Date(timeIntervalSince1970: 0)
      )
    ),
    context: context
  )
  let different = try #require(EntityTag(rawValue: "\"different\""))
  _ = try await backend.headObject(
    HeadObjectRequest(
      bucket: bucket,
      key: key,
      conditions: ReadConditions(
        ifNoneMatch: [different],
        ifModifiedSince: Date().addingTimeInterval(3_600)
      )
    ),
    context: context
  )
  await #expect(throws: BackendError.notModified) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: key, conditions: ReadConditions(ifNoneMatchAny: true)),
      context: context
    )
  }
  await #expect(throws: BackendError.notModified) {
    _ = try await backend.headObject(
      HeadObjectRequest(
        bucket: bucket,
        key: key,
        conditions: ReadConditions(
          ifModifiedSince: Date(timeIntervalSince1970: floor(put.metadata.lastModified.timeIntervalSince1970))
        )
      ),
      context: context
    )
  }
}

@Test func posixBackendRejectsSymlinkObjects() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let outside = fixture.baseURL.appendingPathComponent("outside.txt")
  try Data("secret".utf8).write(to: outside)
  let link = fixture.bucketURL.appendingPathComponent("link.txt")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "link.txt")
  await #expect(throws: BackendError.accessDenied) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: key),
      context: makeContext()
    )
  }
}

@Test func posixBackendRejectsHardLinkedObjects() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let first = fixture.bucketURL.appendingPathComponent("first.txt")
  let second = fixture.bucketURL.appendingPathComponent("second.txt")
  try Data("linked".utf8).write(to: first)
  try FileManager.default.linkItem(at: first, to: second)
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  await #expect(throws: BackendError.accessDenied) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: ObjectKey(validating: "first.txt")),
      context: makeContext()
    )
  }
}

@Test func posixBackendRejectsSpecialFilesWithoutBlocking() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let fifo = fixture.bucketURL.appendingPathComponent("named-pipe")
  try #require(mkfifo(fifo.path, mode_t(0o600)) == 0)
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  await #expect(throws: BackendError.accessDenied) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: ObjectKey(validating: "named-pipe")),
      context: makeContext()
    )
  }
}

@Test func posixBackendRejectsSymlinkedAncestorAndReportsMissingNestedObject() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let outside = fixture.baseURL.appendingPathComponent("outside", isDirectory: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try Data("secret".utf8).write(to: outside.appendingPathComponent("value.txt"))
  try FileManager.default.createSymbolicLink(
    at: fixture.bucketURL.appendingPathComponent("linked-directory"),
    withDestinationURL: outside
  )
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))

  await #expect(throws: BackendError.accessDenied) {
    _ = try await backend.headObject(
      HeadObjectRequest(
        bucket: bucket,
        key: ObjectKey(validating: "linked-directory/value.txt")
      ),
      context: makeContext()
    )
  }
  await #expect(throws: BackendError.notFound) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: ObjectKey(validating: "missing/value.txt")),
      context: makeContext()
    )
  }
}

@Test func posixPaginationUsesTheSameByteOrderingAsListing() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .managedPrivateLayout)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let context = try makeContext()
  let keys = ["e\u{301}", "é", "日本", "z"]
  for value in keys {
    _ = try await backend.putObject(
      PutObjectRequest(
        bucket: bucket,
        key: try ObjectKey(validating: value),
        body: ObjectBodyStream(data: Data(value.utf8))
      ),
      context: context
    )
  }

  var observed: [String] = []
  var token: String?
  repeat {
    let page = try await backend.listObjectsV2(
      ListObjectsV2Request(
        bucket: bucket,
        maximumKeys: 1,
        continuationToken: token
      ),
      context: context
    )
    observed.append(contentsOf: page.objects.map(\.key.rawValue))
    token = page.nextContinuationToken
  } while token != nil

  let expected = keys.sorted {
    $0.utf8.lexicographicallyPrecedes($1.utf8)
  }
  #expect(observed == expected)
}

@Test func cancellingPOSIXPutRemovesStagingAndPublishesNothing() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let key = try ObjectKey(validating: "cancelled.bin")
  let pair = AsyncThrowingStream<Data, any Error>.makeStream(
    bufferingPolicy: .bufferingOldest(1)
  )
  pair.continuation.yield(Data(repeating: 9, count: 1_024))
  let body = ObjectBodyStream(maximumChunkBytes: 1_024, stream: pair.stream)
  let task = Task {
    try await backend.putObject(
      PutObjectRequest(bucket: bucket, key: key, body: body),
      context: makeContext()
    )
  }
  try await Task.sleep(for: .milliseconds(50))
  task.cancel()
  await #expect(throws: BackendError.cancelled) {
    _ = try await task.value
  }
  pair.continuation.finish()

  await #expect(throws: BackendError.notFound) {
    _ = try await backend.headObject(
      HeadObjectRequest(bucket: bucket, key: key),
      context: makeContext()
    )
  }
  let staging = fixture.sidecarURL
    .appendingPathComponent(".swift-s3-gateway-staging/my-bucket", isDirectory: true)
  #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
}

@Test func posixReadinessRejectsBucketDirectorySymlinkReplacement() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .sharedLocalDirectory)
  let moved = fixture.baseURL.appendingPathComponent("moved-bucket", isDirectory: true)
  try FileManager.default.moveItem(at: fixture.bucketURL, to: moved)
  try FileManager.default.createSymbolicLink(
    at: fixture.bucketURL,
    withDestinationURL: moved
  )
  await #expect(throws: BackendError.unavailable(retryable: true)) {
    try await backend.readinessCheck(deadline: Date().addingTimeInterval(30))
  }
}

@Test func posixDelimiterPaginationCountsUniquePrefixes() async throws {
  let fixture = try POSIXFixture()
  defer { fixture.remove() }
  let backend = try fixture.makeBackend(policy: .managedPrivateLayout)
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let context = try makeContext()
  for value in ["a/1", "a/2", "b/1", "z"] {
    _ = try await backend.putObject(
      PutObjectRequest(
        bucket: bucket,
        key: try ObjectKey(validating: value),
        body: ObjectBodyStream(data: Data(value.utf8))
      ),
      context: context
    )
  }

  var observed: [String] = []
  var token: String?
  repeat {
    let page = try await backend.listObjectsV2(
      ListObjectsV2Request(
        bucket: bucket,
        delimiter: "/",
        maximumKeys: 1,
        continuationToken: token
      ),
      context: context
    )
    observed.append(contentsOf: page.commonPrefixes)
    observed.append(contentsOf: page.objects.map(\.key.rawValue))
    token = page.nextContinuationToken
  } while token != nil

  #expect(observed == ["a/", "b/", "z"])
}

private struct POSIXFixture {
  let baseURL: URL
  let rootURL: URL
  let bucketURL: URL
  let sidecarURL: URL

  init() throws {
    baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    rootURL = baseURL.appendingPathComponent("data", isDirectory: true)
    bucketURL = rootURL.appendingPathComponent("bucket", isDirectory: true)
    sidecarURL = baseURL.appendingPathComponent("metadata", isDirectory: true)
    try FileManager.default.createDirectory(at: bucketURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sidecarURL, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sidecarURL.path)
  }

  func makeBackend(policy: POSIXLayoutPolicy) throws -> POSIXBackend {
    try POSIXBackend(
      configuration: configuration(policy: policy),
      maximumChunkBytes: 4_096
    )
  }

  func configuration(policy: POSIXLayoutPolicy) -> POSIXBackendConfiguration {
    POSIXBackendConfiguration(
      rootPath: rootURL.path,
      bucketDirectories: ["my-bucket": "bucket"],
      layoutPolicy: policy,
      sidecarPath: sidecarURL.path,
      durability: .data
    )
  }

  func makeMapper(policy: POSIXLayoutPolicy) throws -> POSIXPathMapper {
    var rootInformation = stat()
    guard lstat(rootURL.path, &rootInformation) == 0 else {
      throw BackendError.consistencyFailure
    }
    return POSIXPathMapper(
      rootURL: rootURL,
      sidecarURL: sidecarURL,
      bucketDirectories: ["my-bucket": "bucket"],
      policy: policy,
      rootDevice: UInt64(rootInformation.st_dev),
      durability: .data
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: baseURL)
  }
}

private struct InterruptedPOSIXCommit {
  let mapper: POSIXPathMapper
  let temporary: SecureTemporaryFile
  let record: POSIXCommitRecord
}

private func makeInterruptedPOSIXCommit(
  fixture: POSIXFixture,
  bucket: BucketName,
  key: ObjectKey,
  value: Data
) throws -> InterruptedPOSIXCommit {
  let mapper = try fixture.makeMapper(policy: .sharedLocalDirectory)
  let temporary = try mapper.createTemporaryFile(bucket: bucket, key: key)
  try temporary.handle.write(contentsOf: value)
  try temporary.handle.synchronize()
  try temporary.handle.close()
  let identity = try mapper.identity(
    parentDescriptor: temporary.temporaryParentDescriptor,
    name: temporary.temporaryName
  )
  guard let entityTag = EntityTag(rawValue: "\"recovery-etag\"") else {
    throw BackendError.consistencyFailure
  }
  let metadata = ObjectMetadata(
    contentType: "text/plain",
    contentLength: Int64(value.count),
    lastModified: identity.date,
    entityTag: entityTag,
    userMetadata: ["recovery": "preserved"],
    versionToken: identity.versionToken
  )
  let record = POSIXCommitRecord(
    version: 1,
    bucket: bucket,
    key: key,
    temporaryName: temporary.temporaryName,
    identity: identity,
    previousIdentity: try mapper.objectIdentity(bucket: bucket, key: key),
    metadata: metadata
  )
  try POSIXMetadataStore(mapper: mapper).prepareCommit(record)
  return InterruptedPOSIXCommit(
    mapper: mapper,
    temporary: temporary,
    record: record
  )
}

private actor POSIXDataCollector {
  private(set) var data = Data()

  func append(_ value: Data) { data.append(value) }
}

private actor POSIXReplacementCoordinator {
  private var available = true

  func takeFirst() -> Bool {
    guard available else { return false }
    available = false
    return true
  }
}

private func makeContext() throws -> RequestContext {
  RequestContext(
    requestID: UUID().uuidString,
    principalID: try #require(PrincipalID(rawValue: "test")),
    deadline: Date().addingTimeInterval(30)
  )
}
