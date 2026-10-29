// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowCore", targets: ["CrowCore"]),
    ],
    targets: [
        // System zlib for gzip on both macOS and Linux (CROW-1394).
        .systemLibrary(name: "CZlib", providers: [.apt(["zlib1g-dev"])]),
        .target(name: "CrowCore", dependencies: ["CZlib"]),
        .testTarget(name: "CrowCoreTests", dependencies: ["CrowCore"]),
    ]
)
