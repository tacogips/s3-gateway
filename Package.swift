// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "swift-s3-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .executable(name: "swift-s3-gateway", targets: ["AppCLI"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.99.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.2"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1")
  ],
  targets: [
    .target(
      name: "AppCore",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "Crypto", package: "swift-crypto")
      ]
    ),
    .executableTarget(
      name: "AppCLI",
      dependencies: ["AppCore"]
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
