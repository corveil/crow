// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Crow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CrowApp", targets: ["Crow"]),
        .executable(name: "crow", targets: ["CrowCLI"]),
        // Headless cross-platform daemon (CROW-581). Build standalone on Linux
        // with `swift build --product crowd` — it does not depend on the AppKit
        // `Crow` target or its generated BuildInfo.
        .executable(name: "crowd", targets: ["crowd"]),
    ],
    dependencies: [
        .package(path: "Packages/CrowCore"),
        .package(path: "Packages/CrowUI"),
        .package(path: "Packages/CrowTerminal"),
        .package(path: "Packages/CrowGit"),
        .package(path: "Packages/CrowProvider"),
        .package(path: "Packages/CrowPersistence"),
        .package(path: "Packages/CrowClaude"),
        .package(path: "Packages/CrowCodex"),
        .package(path: "Packages/CrowCursor"),
        .package(path: "Packages/CrowOpenCode"),
        .package(path: "Packages/CrowIPC"),
        .package(path: "Packages/CrowTelemetry"),
        .package(path: "Packages/CrowEngine"),
        .package(path: "Packages/CrowCLI"),
        .package(path: "Packages/CrowDaemon"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Crow",
            dependencies: [
                "CrowCore",
                "CrowUI",
                "CrowTerminal",
                "CrowGit",
                "CrowProvider",
                "CrowPersistence",
                "CrowClaude",
                "CrowCodex",
                "CrowCursor",
                "CrowOpenCode",
                "CrowIPC",
                "CrowTelemetry",
                "CrowEngine",
            ],
            path: "Sources/Crow",
            resources: [
                .copy("Resources/AppIcon.png"),
                .copy("Resources/CorveilBrandmark.svg"),
            ],
            linkerSettings: [
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "CrowCLI",
            dependencies: [
                .product(name: "CrowCLILib", package: "CrowCLI"),
            ],
            path: "Sources/CrowCLI"
        ),
        .executableTarget(
            name: "crowd",
            dependencies: [
                .product(name: "CrowDaemon", package: "CrowDaemon"),
            ],
            path: "Sources/crowd"
        ),
        .testTarget(
            name: "CrowTests",
            dependencies: ["Crow"],
            path: "Tests/CrowTests"
        ),
    ]
)
