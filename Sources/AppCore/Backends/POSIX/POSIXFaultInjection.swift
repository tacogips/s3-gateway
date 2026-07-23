enum POSIXFaultPoint: Sendable {
  case dataSynchronization
  case commitRecord
  case metadataPublication
}

struct POSIXFaultInjector: Sendable {
  private let failingPoints: Set<POSIXFaultPoint>

  init(failingPoints: Set<POSIXFaultPoint> = []) {
    self.failingPoints = failingPoints
  }

  func inject(_ point: POSIXFaultPoint) throws {
    if failingPoints.contains(point) {
      throw BackendError.consistencyFailure
    }
  }
}
