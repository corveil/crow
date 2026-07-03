// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowDaemon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowDaemon", targets: ["CrowDaemon"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
        .package(path: "../CrowPersistence"),
        .package(path: "../CrowGit"),
        .package(path: "../CrowIPC"),
        .package(path: "../CrowTerminal"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "CrowDaemon",
            dependencies: [
                .product(name: "CrowCore", package: "CrowCore"),
                .product(name: "CrowPersistence", package: "CrowPersistence"),
                .product(name: "CrowGit", package: "CrowGit"),
                .product(name: "CrowIPC", package: "CrowIPC"),
                .product(name: "CrowTerminal", package: "CrowTerminal"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            resources: [
                .copy("Resources/web"),
            ]
        ),
        .testTarget(
            name: "CrowDaemonTests",
            dependencies: ["CrowDaemon"]
        ),
    ]
)
