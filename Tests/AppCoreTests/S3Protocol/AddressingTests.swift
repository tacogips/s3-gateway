import Testing
@testable import AppCore

@Test func pathAddressingDecodesExactlyOnceWithoutNormalizingKey() throws {
  let resolver = S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
  let result = try resolver.resolve(rawPath: "/my-bucket/a//..%2Ffile", host: "localhost")
  #expect(result.bucket.rawValue == "my-bucket")
  #expect(result.key?.rawValue == "a//../file")
}

@Test func virtualHostAddressingRequiresTrustedSuffix() throws {
  let resolver = S3AddressingResolver(styles: [.virtualHost], virtualHostSuffixes: ["s3.example.test"])
  let result = try resolver.resolve(rawPath: "/file", host: "my-bucket.s3.example.test:8443")
  #expect(result.bucket.rawValue == "my-bucket")
  #expect(result.key?.rawValue == "file")
}

@Test func malformedPercentEncodingFails() {
  let resolver = S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
  #expect(throws: (any Error).self) {
    _ = try resolver.resolve(rawPath: "/my-bucket/bad%2", host: "localhost")
  }
}
