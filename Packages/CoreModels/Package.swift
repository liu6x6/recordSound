// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CoreModels",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CoreModels", targets: ["CoreModels"])
    ],
    targets: [
        .target(name: "CoreModels")
    ]
)
