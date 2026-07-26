// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowAntigravity",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowAntigravity", targets: ["CrowAntigravity"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(name: "CrowAntigravity", dependencies: ["CrowCore"]),
        .testTarget(name: "CrowAntigravityTests", dependencies: ["CrowAntigravity"]),
    ]
)
