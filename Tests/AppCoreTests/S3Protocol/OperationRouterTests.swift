import Testing
@testable import AppCore

@Test func routerRecognizesBoundedStageOneSurface() throws {
  let router = S3OperationRouter(
    resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
  )
  let list = try router.route(
    RawS3RequestHead(
      method: "GET",
      rawPath: "/my-bucket",
      rawQuery: "list-type=2&prefix=logs",
      host: "localhost",
      headers: [:]
    )
  )
  #expect(list.operation == .listObjectsV2)
  #expect(list.query["prefix"] == "logs")

  let get = try router.route(
    RawS3RequestHead(method: "GET", rawPath: "/my-bucket/key", rawQuery: "", host: "localhost", headers: [:])
  )
  #expect(get.operation == .getObject)
}

@Test func routerRejectsDuplicateSecuritySensitiveQueryFields() {
  let router = S3OperationRouter(
    resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
  )
  #expect(throws: S3RoutingError.duplicateQueryField("prefix")) {
    _ = try router.route(
      RawS3RequestHead(
        method: "GET",
        rawPath: "/my-bucket",
        rawQuery: "list-type=2&prefix=a&prefix=b",
        host: "localhost",
        headers: [:]
      )
    )
  }
}

@Test func routerRejectsCrossOperationAndStagedSubresources() {
  let router = S3OperationRouter(
    resolver: S3AddressingResolver(styles: [.path], virtualHostSuffixes: [])
  )
  for (method, query) in [
    ("GET", "prefix=ignored"),
    ("GET", "list-type=2"),
    ("PUT", "uploads="),
    ("PUT", "partNumber=1&uploadId=id"),
    ("DELETE", "uploadId=id")
  ] {
    #expect(throws: S3RoutingError.unsupported) {
      _ = try router.route(
        RawS3RequestHead(
          method: method,
          rawPath: "/my-bucket/key",
          rawQuery: query,
          host: "localhost",
          headers: [:]
        )
      )
    }
  }
}
