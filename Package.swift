// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "LidlessKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "LidlessCore", targets: ["LidlessCore"]),
    .library(name: "LidlessPlatform", targets: ["LidlessPlatform"]),
    .executable(name: "lidless-lab", targets: ["LidlessLab"]),
  ],
  targets: [
    .target(name: "LidlessCore"),
    .target(name: "LidlessPlatform", dependencies: ["LidlessCore"]),
    .executableTarget(name: "LidlessLab", dependencies: ["LidlessCore", "LidlessPlatform"]),
    .testTarget(name: "LidlessCoreTests", dependencies: ["LidlessCore"]),
    .testTarget(name: "LidlessPlatformTests", dependencies: ["LidlessPlatform"]),
  ],
  swiftLanguageModes: [.v6]
)
