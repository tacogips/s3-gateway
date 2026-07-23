import Foundation

struct UpstreamHTTPRequest: Sendable {
  let method: String
  let url: URL
  let headers: [(String, String)]
  let body: ObjectBodyStream?
  let deadline: Date?

  init(
    method: String,
    url: URL,
    headers: [(String, String)],
    body: ObjectBodyStream?,
    deadline: Date? = nil
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.deadline = deadline
  }
}

struct UpstreamHTTPResponse: Sendable {
  let status: Int
  let headers: [String: [String]]
  let body: ObjectBodyStream

  func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value.first
  }
}

protocol UpstreamHTTPClient: Sendable {
  func execute(_ request: UpstreamHTTPRequest) async throws -> UpstreamHTTPResponse
}
