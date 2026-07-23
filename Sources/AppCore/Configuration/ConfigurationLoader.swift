import Foundation

public enum ConfigurationLoader {
  public static func loadJSON(at path: String) throws -> GatewayConfiguration {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? file.close() }
    let data = try file.read(upToCount: 4 * 1_024 * 1_024 + 1) ?? Data()
    guard data.count <= 4 * 1_024 * 1_024 else {
      throw ConfigurationError.invalid(field: "configuration", reason: "file exceeds 4 MiB")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(GatewayConfiguration.self, from: data)
  }
}
