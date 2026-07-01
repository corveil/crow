// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowOpenCode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowOpenCode", targets: ["CrowOpenCode"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(name: "CrowOpenCode", dependencies: ["CrowCore"]),
        .testTarget(name: "CrowOpenCodeTests", dependencies: ["CrowOpenCode"]),
    ]
)
