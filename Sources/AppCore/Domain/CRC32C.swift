import Foundation

struct CRC32C: Sendable {
  private var value: UInt32 = 0xffff_ffff

  mutating func update(_ data: Data) {
    for byte in data {
      var current = (value ^ UInt32(byte)) & 0xff
      for _ in 0..<8 {
        current = current & 1 == 1 ? (current >> 1) ^ 0x82f6_3b78 : current >> 1
      }
      value = (value >> 8) ^ current
    }
  }

  func base64Value() -> String {
    var checksum = (value ^ 0xffff_ffff).bigEndian
    return withUnsafeBytes(of: &checksum) { Data($0).base64EncodedString() }
  }
}
