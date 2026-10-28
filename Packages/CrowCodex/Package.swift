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
        // SHA-256 for Codex's per-hook trust hash (CROW-1381). Same range as
        // CrowDaemon, so the app resolves one copy.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "CrowCodex",
            dependencies: [
                "CrowCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .testTarget(name: "CrowCodexTests", dependencies: ["CrowCodex"]),
    ]
)
