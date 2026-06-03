// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowCursor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowCursor", targets: ["CrowCursor"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(name: "CrowCursor", dependencies: ["CrowCore"]),
        .testTarget(name: "CrowCursorTests", dependencies: ["CrowCursor"]),
    ]
)
