import Foundation

public struct AppCommand: Sendable {
  public enum Action: Equatable, Sendable {
    case print(String)
    case serve(configurationPath: String)
  }

  public enum Error: Swift.Error, Equatable, Sendable {
    case unknownArgument(String)
    case missingConfigurationPath
    case unexpectedArgument(String)
  }

  public let arguments: [String]

  public init(arguments: [String]) {
    self.arguments = arguments
  }

  public func run() throws -> String {
    switch try action() {
    case .print(let output): return output
    case .serve: return ""
    }
  }

  public func action() throws -> Action {
    if arguments.contains("--version") {
      return .print(Version.current)
    }

    if arguments.contains("--help") || arguments.contains("-h") {
      return .print(usage)
    }

    if arguments.first == "serve" {
      guard arguments.count >= 2 else { throw Error.missingConfigurationPath }
      if arguments[1] == "--config" {
        guard arguments.count >= 3 else { throw Error.missingConfigurationPath }
        guard arguments.count == 3 else { throw Error.unexpectedArgument(arguments[3]) }
        return .serve(configurationPath: arguments[2])
      }
      guard arguments.count == 2 else { throw Error.unexpectedArgument(arguments[2]) }
      return .serve(configurationPath: arguments[1])
    }
    if let firstUnknown = arguments.first(where: { $0.hasPrefix("-") }) { throw Error.unknownArgument(firstUnknown) }
    if let first = arguments.first { throw Error.unexpectedArgument(first) }
    return .print(usage)
  }

  public var usage: String {
    """
    Usage: s3-gateway <command> [options]

      s3-gateway --help
      s3-gateway --version
      s3-gateway serve --config <configuration.json>
    """
  }
}
