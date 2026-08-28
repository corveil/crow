// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowCLI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowCLILib", targets: ["CrowCLILib"]),
    ],
    dependencies: [
        .package(path: "../CrowIPC"),
        .package(path: "../CrowCore"),
        .package(path: "../CrowCodex"),
        .package(path: "../CrowAutostart"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CrowCLILib",
            dependencies: [
                "CrowIPC",
                // Lets `crow notifications` validate against the canonical
                // NotificationEvent cases, builtInSounds, and the custom sound
                // library instead of keeping its own copy (CROW-813 / CROW-1147).
                "CrowCore",
                "CrowCodex",
                "CrowAutostart",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CrowCLITests",
            dependencies: ["CrowCLILib"]
        ),
    ]
)
