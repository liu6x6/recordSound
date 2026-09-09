// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AudioKit", targets: ["AudioKit"])
    ],
    targets: [
        .target(name: "AudioKit")
    ]
)
