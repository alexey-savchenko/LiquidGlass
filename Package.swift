// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiquidGlass",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LiquidGlass", targets: ["LiquidGlass"])
    ],
    targets: [
        .target(name: "LiquidGlass"),
        .testTarget(name: "LiquidGlassTests", dependencies: ["LiquidGlass"])
    ],
    swiftLanguageModes: [.v5]
)
