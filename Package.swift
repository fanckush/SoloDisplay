// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "SoloDisplayKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "SoloDisplayCore", targets: ["SoloDisplayCore"]),
    .library(name: "SoloDisplayPlatform", targets: ["SoloDisplayPlatform"]),
    .executable(name: "solodisplay-lab", targets: ["SoloDisplayLab"])
  ],
  targets: [
    .target(name: "SoloDisplayCore"),
    .target(name: "SoloDisplayPlatform", dependencies: ["SoloDisplayCore"]),
    .executableTarget(
      name: "SoloDisplayLab",
      dependencies: ["SoloDisplayCore", "SoloDisplayPlatform"]
    ),
    .testTarget(name: "SoloDisplayCoreTests", dependencies: ["SoloDisplayCore"]),
    .testTarget(name: "SoloDisplayPlatformTests", dependencies: ["SoloDisplayPlatform"])
  ],
  swiftLanguageModes: [.v6]
)
