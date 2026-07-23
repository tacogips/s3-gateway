import Foundation
import Testing
@testable import AppCore

@Test func bucketNamesEnforceS3DNSSubset() throws {
  #expect(BucketName(rawValue: "valid-bucket.1") != nil)
  #expect(BucketName(rawValue: "UPPER") == nil)
  #expect(BucketName(rawValue: "ab") == nil)
  #expect(BucketName(rawValue: "bad..bucket") == nil)
}

@Test func objectKeysPreserveLogicalPathData() throws {
  let key = try ObjectKey(validating: "a//../%2F/日本語")
  #expect(key.rawValue == "a//../%2F/日本語")
  #expect(ObjectKey(rawValue: "bad\u{0}key") == nil)
}

@Test func objectBodyStreamIsChunkBoundedAndSingleConsumer() async throws {
  let stream = ObjectBodyStream(data: Data(repeating: 7, count: 10), maximumChunkBytes: 4)
  let collector = DataCollector()
  try await stream.consume { chunk in
    await collector.append(chunk)
  }
  #expect(await collector.data.count == 10)

  await #expect(throws: ObjectBodyStreamError.alreadyConsumed) {
    try await stream.consume { _ in }
  }
}

private actor DataCollector {
  private(set) var data = Data()

  func append(_ chunk: Data) {
    data.append(chunk)
  }
}
