// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowIPC",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowIPC", targets: ["CrowIPC"]),
    ],
    dependencies: [
        // The MCP layer (CROW-1004) needs `MCPScope` and `MCPTokenRecord`, which
        // live in CrowCore because `ParityLedger` and `AppConfig` reference them.
        // Acyclic: CrowCore has no dependencies at all.
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(
            name: "CrowIPC",
            dependencies: [.product(name: "CrowCore", package: "CrowCore")]
        ),
        .testTarget(
            name: "CrowIPCTests",
            dependencies: [
                "CrowIPC",
                .product(name: "CrowCore", package: "CrowCore"),
            ]
        ),
    ]
)
