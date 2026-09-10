// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SummarizationKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SummarizationKit", targets: ["SummarizationKit"])
    ],
    targets: [
        .target(name: "SummarizationKit")
    ]
)
