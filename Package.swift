// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "SoloDisplayKit",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "SoloDisplayCore", targets: ["SoloDisplayCore"]),
    .library(name: "SoloDisplayPlatform", targets: ["SoloDisplayPlatform"]),
    .executable(name: "solodisplay-lab", targets: ["SoloDisplayLab"]),
    .executable(name: "solodisplay-probe", targets: ["SoloDisplayProbe"])
  ],
  targets: [
    .target(name: "SoloDisplayCore"),
    .target(name: "SoloDisplayPlatform", dependencies: ["SoloDisplayCore"]),
    .executableTarget(
      name: "SoloDisplayLab",
      dependencies: ["SoloDisplayCore", "SoloDisplayPlatform"]
    ),
    .executableTarget(
      name: "SoloDisplayProbe",
      dependencies: ["SoloDisplayCore", "SoloDisplayPlatform"]
    ),
    .testTarget(name: "SoloDisplayCoreTests", dependencies: ["SoloDisplayCore"]),
    .testTarget(
      name: "SoloDisplayPlatformTests",
      dependencies: ["SoloDisplayPlatform", "SoloDisplayProbe"]
    )
  ],
  swiftLanguageModes: [.v6]
)
