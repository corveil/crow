// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowTelemetry",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowTelemetry", targets: ["CrowTelemetry"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(
            name: "CrowTelemetry",
            dependencies: ["CrowCore"]
        ),
        .testTarget(
            name: "CrowTelemetryTests",
            dependencies: ["CrowTelemetry"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
