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
        .package(path: "../CrowCodex"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CrowCLILib",
            dependencies: [
                "CrowIPC",
                "CrowCodex",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "CrowCLITests",
            dependencies: ["CrowCLILib"]
        ),
    ]
)
