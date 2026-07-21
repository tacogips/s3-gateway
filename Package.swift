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
  targets: [
    .target(name: "AppCore"),
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
