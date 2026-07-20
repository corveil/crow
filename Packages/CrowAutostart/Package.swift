// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowAutostart",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowAutostart", targets: ["CrowAutostart"]),
    ],
    targets: [
        .target(name: "CrowAutostart"),
        .testTarget(name: "CrowAutostartTests", dependencies: ["CrowAutostart"]),
    ]
)
