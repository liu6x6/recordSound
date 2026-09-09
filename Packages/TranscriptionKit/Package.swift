// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscriptionKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"])
    ],
    targets: [
        .target(name: "TranscriptionKit")
    ]
)
