// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowGrok",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowGrok", targets: ["CrowGrok"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(name: "CrowGrok", dependencies: ["CrowCore"]),
        .testTarget(name: "CrowGrokTests", dependencies: ["CrowGrok"]),
    ]
)
