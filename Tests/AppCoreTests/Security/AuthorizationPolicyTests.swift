import Testing
@testable import AppCore

@Test func authorizationDefaultsToDeny() throws {
  let policy = try AuthorizationPolicy(principals: [])
  let request = AuthorizationRequest(
    principalID: try #require(PrincipalID(rawValue: "unknown")),
    operation: .getObject,
    bucket: try #require(BucketName(rawValue: "my-bucket")),
    key: try ObjectKey(validating: "file.txt")
  )
  #expect(throws: GatewayError.self) { try policy.authorize(request) }
}

@Test func listAuthorizationCannotBroadenPrefix() throws {
  let policy = try AuthorizationPolicy(
    principals: [
      PrincipalAuthorization(
        principalID: "reader",
        grants: [
          AuthorizationGrant(
            operations: [.listObjectsV2],
            bucket: "my-bucket",
            keyPrefix: "allowed"
          )
        ]
      )
    ]
  )
  let principal = try #require(PrincipalID(rawValue: "reader"))
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  #expect(throws: GatewayError.self) {
    try policy.authorize(
      AuthorizationRequest(
        principalID: principal,
        operation: .listObjectsV2,
        bucket: bucket,
        listPrefix: ""
      )
    )
  }
  let scope = try policy.authorize(
    AuthorizationRequest(
      principalID: principal,
      operation: .listObjectsV2,
      bucket: bucket,
      listPrefix: "allowed/child"
    )
  )
  #expect(scope.grantPrefix == "allowed")
}

@Test func authorizationEnforcesBoundariesUnicodeWholeBucketAndRestartRevocation() throws {
  let principal = try #require(PrincipalID(rawValue: "reader"))
  let bucket = try #require(BucketName(rawValue: "my-bucket"))
  let policy = try AuthorizationPolicy(
    principals: [
      PrincipalAuthorization(
        principalID: principal.rawValue,
        grants: [
          AuthorizationGrant(
            operations: [.getObject],
            bucket: bucket.rawValue,
            keyPrefix: "文書"
          ),
          AuthorizationGrant(
            operations: [.headObject],
            bucket: bucket.rawValue,
            keyPrefix: nil
          )
        ]
      )
    ]
  )

  let unicodeScope = try policy.authorize(
    AuthorizationRequest(
      principalID: principal,
      operation: .getObject,
      bucket: bucket,
      key: try ObjectKey(validating: "文書/報告.txt")
    )
  )
  #expect(unicodeScope.grantPrefix == "文書")
  #expect(throws: GatewayError.self) {
    try policy.authorize(
      AuthorizationRequest(
        principalID: principal,
        operation: .getObject,
        bucket: bucket,
        key: try ObjectKey(validating: "文書-old/報告.txt")
      )
    )
  }

  let wholeBucketScope = try policy.authorize(
    AuthorizationRequest(
      principalID: principal,
      operation: .headObject,
      bucket: bucket,
      key: try ObjectKey(validating: "any/key")
    )
  )
  #expect(wholeBucketScope.grantPrefix == nil)

  let revokedPolicy = try AuthorizationPolicy(principals: [])
  #expect(throws: GatewayError.self) {
    try revokedPolicy.authorize(
      AuthorizationRequest(
        principalID: principal,
        operation: .headObject,
        bucket: bucket,
        key: try ObjectKey(validating: "any/key")
      )
    )
  }
}
