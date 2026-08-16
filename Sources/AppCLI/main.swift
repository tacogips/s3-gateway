import AppCore
import Darwin
import Dispatch
import Foundation

@main
struct SwiftS3GatewayMain {
  static func main() async {
    let command = AppCommand(arguments: Array(CommandLine.arguments.dropFirst()))
    do {
      switch try command.action() {
      case .print(let output):
        if !output.isEmpty { print(output) }
      case .serve(let configurationPath):
        let configuration = try ConfigurationLoader.loadJSON(at: configurationPath)
        let server = try await GatewayServer.make(configuration: configuration)
        try await server.start()
        if let address = await server.localAddress {
          print("s3-gateway listening on \(address)")
        }
        await ShutdownSignal.wait()
        try await server.stop()
      }
    } catch AppCommand.Error.unknownArgument(let argument) {
      fail("Unknown argument: \(argument)", code: 2)
    } catch AppCommand.Error.missingConfigurationPath {
      fail("Missing configuration path.", code: 2)
    } catch AppCommand.Error.unexpectedArgument(let argument) {
      fail("Unexpected argument: \(argument)", code: 2)
    } catch ConfigurationError.invalid(let field, let reason) {
      fail("Invalid configuration for \(field): \(reason)", code: 1)
    } catch ConfigurationError.unreadable {
      fail("A required file or directory is unavailable.", code: 1)
    } catch ConfigurationError.insecureCredentialFile {
      fail("A credential file has insecure ownership, type, or permissions.", code: 1)
    } catch ConfigurationError.unsupportedFileSystem {
      fail("The configured filesystem is unsupported for the selected storage policy.", code: 1)
    } catch is CredentialProviderError {
      fail("A credential file is invalid.", code: 1)
    } catch is DecodingError {
      fail("The configuration file is not valid gateway JSON.", code: 1)
    } catch {
      fail("Gateway startup or shutdown failed.", code: 1)
    }
  }

  private static func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
  }
}

private enum ShutdownSignal {
  static func wait() async {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    await withCheckedContinuation { continuation in
      let state = SignalContinuation(continuation)
      let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
      let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
      interrupt.setEventHandler { state.resume() }
      terminate.setEventHandler { state.resume() }
      interrupt.resume()
      terminate.resume()
      state.retain(interrupt: interrupt, terminate: terminate)
    }
  }
}

private final class SignalContinuation: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var sources: (DispatchSourceSignal, DispatchSourceSignal)?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func retain(interrupt: DispatchSourceSignal, terminate: DispatchSourceSignal) {
    lock.lock()
    guard continuation != nil else {
      lock.unlock()
      interrupt.cancel()
      terminate.cancel()
      return
    }
    sources = (interrupt, terminate)
    lock.unlock()
  }

  func resume() {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    sources = nil
    lock.unlock()
    continuation?.resume()
  }
}
