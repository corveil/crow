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
        // Login-item installer shared with the crow CLI (CROW-769).
        .package(path: "../CrowAutostart"),
        .package(path: "../CrowTerminal"),
        // The headless engine (IssueTracker / AllowListService) + its provider
        // layer, so the daemon owns the board reads with the app down (CROW-581).
        .package(path: "../CrowEngine"),
        .package(path: "../CrowProvider"),
        // Coding agents — the daemon owns its own AgentRegistry so `list-agents`
        // (and future launch gating) works with the desktop app down (CROW-581).
        .package(path: "../CrowClaude"),
        .package(path: "../CrowCodex"),
        .package(path: "../CrowCursor"),
        .package(path: "../CrowOpenCode"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        // Already resolved transitively (via NIO/Hummingbird); declared directly
        // for the web-auth password hashing (PBKDF2-HMAC-SHA256) (CROW-593).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "CrowDaemon",
            dependencies: [
                .product(name: "CrowCore", package: "CrowCore"),
                .product(name: "CrowPersistence", package: "CrowPersistence"),
                .product(name: "CrowGit", package: "CrowGit"),
                .product(name: "CrowIPC", package: "CrowIPC"),
                .product(name: "CrowAutostart", package: "CrowAutostart"),
                .product(name: "CrowTerminal", package: "CrowTerminal"),
                .product(name: "CrowEngine", package: "CrowEngine"),
                .product(name: "CrowProvider", package: "CrowProvider"),
                .product(name: "CrowClaude", package: "CrowClaude"),
                .product(name: "CrowCodex", package: "CrowCodex"),
                .product(name: "CrowCursor", package: "CrowCursor"),
                .product(name: "CrowOpenCode", package: "CrowOpenCode"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            resources: [
                .copy("Resources/web"),
            ]
        ),
        .testTarget(
            name: "CrowDaemonTests",
            dependencies: [
                "CrowDaemon",
                .product(name: "CrowCore", package: "CrowCore"),
                .product(name: "CrowAutostart", package: "CrowAutostart"),
                .product(name: "CrowClaude", package: "CrowClaude"),
                .product(name: "CrowEngine", package: "CrowEngine"),
                .product(name: "CrowProvider", package: "CrowProvider"),
            ]
        ),
    ]
)
