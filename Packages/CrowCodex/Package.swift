// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowCodex",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowCodex", targets: ["CrowCodex"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(name: "CrowCodex", dependencies: ["CrowCore"]),
        .testTarget(name: "CrowCodexTests", dependencies: ["CrowCodex"]),
    ]
)
