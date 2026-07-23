import Foundation

public struct ObjectBodyStream: Sendable {
  public typealias Chunk = Data

  private let stream: AsyncThrowingStream<Chunk, any Error>
  private let consumption = ConsumptionState()
  public let maximumChunkBytes: Int

  public init(maximumChunkBytes: Int, stream: AsyncThrowingStream<Chunk, any Error>) {
    precondition(maximumChunkBytes > 0)
    self.maximumChunkBytes = maximumChunkBytes
    self.stream = stream
  }

  public init(data: Data, maximumChunkBytes: Int = 64 * 1_024) {
    let source = DataChunkSource(data: data, maximumChunkBytes: maximumChunkBytes)
    self.init(
      maximumChunkBytes: maximumChunkBytes,
      stream: AsyncThrowingStream(unfolding: { await source.next() })
    )
  }

  public init(
    maximumChunkBytes: Int,
    makeStream: @escaping @Sendable () -> AsyncThrowingStream<Chunk, any Error>
  ) {
    self.init(maximumChunkBytes: maximumChunkBytes, stream: makeStream())
  }

  public func consume(
    _ receive: @escaping @Sendable (Chunk) async throws -> Void
  ) async throws {
    guard await consumption.claim() else { throw ObjectBodyStreamError.alreadyConsumed }
    try Task.checkCancellation()
    for try await chunk in stream {
      guard !chunk.isEmpty, chunk.count <= maximumChunkBytes else {
        throw ObjectBodyStreamError.invalidChunkSize(chunk.count)
      }
      try Task.checkCancellation()
      try await receive(chunk)
    }
    try Task.checkCancellation()
  }
}

public enum ObjectBodyStreamError: Error, Equatable, Sendable {
  case alreadyConsumed
  case invalidChunkSize(Int)
}

private actor ConsumptionState {
  private var consumed = false

  func claim() -> Bool {
    guard !consumed else { return false }
    consumed = true
    return true
  }
}

private actor DataChunkSource {
  private let data: Data
  private let maximumChunkBytes: Int
  private var offset = 0

  init(data: Data, maximumChunkBytes: Int) {
    self.data = data
    self.maximumChunkBytes = maximumChunkBytes
  }

  func next() -> Data? {
    guard offset < data.count else { return nil }
    let end = min(offset + maximumChunkBytes, data.count)
    defer { offset = end }
    return data.subdata(in: offset..<end)
  }
}
