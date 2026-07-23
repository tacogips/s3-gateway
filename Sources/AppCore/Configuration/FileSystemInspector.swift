import Darwin
import Foundation

public protocol FileSystemInspecting: Sendable {
  func validateDirectory(path: String, requireLocal: Bool) throws
  func validatePrivateDirectory(path: String) throws
  func validateRegularFile(path: String) throws
  func validateCredentialFile(path: String) throws
  func sameFileSystem(_ firstPath: String, _ secondPath: String) throws -> Bool
}

public struct LocalFileSystemInspector: FileSystemInspecting {
  public init() {}

  public func validateDirectory(path: String, requireLocal: Bool) throws {
    var information = stat()
    guard lstat(path, &information) == 0,
          information.st_mode & S_IFMT == S_IFDIR,
          information.st_mode & S_IFMT != S_IFLNK else {
      throw ConfigurationError.unreadable(path: path)
    }
    if requireLocal {
      var fileSystem = statfs()
      guard statfs(path, &fileSystem) == 0, fileSystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
        throw ConfigurationError.unsupportedFileSystem(path: path)
      }
    }
  }

  public func validatePrivateDirectory(path: String) throws {
    var information = stat()
    guard lstat(path, &information) == 0,
          information.st_mode & S_IFMT == S_IFDIR,
          information.st_uid == geteuid(),
          information.st_mode & 0o077 == 0 else {
      throw ConfigurationError.unreadable(path: path)
    }
  }

  public func validateCredentialFile(path: String) throws {
    var information = stat()
    guard lstat(path, &information) == 0,
          information.st_mode & S_IFMT == S_IFREG,
          information.st_uid == geteuid() else {
      throw ConfigurationError.unreadable(path: path)
    }
    let permissions = information.st_mode & 0o777
    guard permissions & 0o077 == 0 else {
      throw ConfigurationError.insecureCredentialFile(path: path)
    }
  }

  public func validateRegularFile(path: String) throws {
    var information = stat()
    guard lstat(path, &information) == 0,
          information.st_mode & S_IFMT == S_IFREG,
          access(path, R_OK) == 0 else {
      throw ConfigurationError.unreadable(path: path)
    }
  }

  public func sameFileSystem(_ firstPath: String, _ secondPath: String) throws -> Bool {
    var first = stat()
    var second = stat()
    guard stat(firstPath, &first) == 0, stat(secondPath, &second) == 0 else {
      throw ConfigurationError.unreadable(path: firstPath)
    }
    return first.st_dev == second.st_dev
  }
}
