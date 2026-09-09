// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscriptionKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriptionKit", targets: ["TranscriptionKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "TranscriptionKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ]
        )
    ]
)
