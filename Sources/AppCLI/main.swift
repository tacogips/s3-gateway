import Foundation
import AppCore

let command = AppCommand(arguments: Array(CommandLine.arguments.dropFirst()))

do {
  let output = try command.run()
  if !output.isEmpty {
    print(output)
  }
} catch AppCommand.Error.unknownArgument(let argument) {
  FileHandle.standardError.write(Data("Unknown argument: \(argument)\n".utf8))
  exit(2)
} catch {
  FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
  exit(1)
}
