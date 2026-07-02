// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowTerminal", targets: ["CrowTerminal"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
    ],
    targets: [
        .target(
            name: "CrowTerminal",
            dependencies: [
                .product(name: "CrowCore", package: "CrowCore"),
            ],
            resources: [
                .copy("Resources/crow-shell-wrapper.sh"),
                .copy("Resources/crow-tmux.conf"),
                .copy("Resources/xterm"),
            ],
            linkerSettings: [
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "CrowTerminalTests",
            dependencies: ["CrowTerminal"]
        ),
    ]
)
