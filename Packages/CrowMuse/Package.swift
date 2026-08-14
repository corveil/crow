// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowMuse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowMuse", targets: ["CrowMuse"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(name: "CrowMuse", dependencies: ["CrowCore"]),
        .testTarget(name: "CrowMuseTests", dependencies: ["CrowMuse", "CrowCore"]),
    ]
)
