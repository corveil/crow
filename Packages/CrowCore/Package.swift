// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowCore", targets: ["CrowCore"]),
    ],
    targets: [
        .target(name: "CrowCore"),
        .testTarget(name: "CrowCoreTests", dependencies: ["CrowCore"]),
    ]
)
