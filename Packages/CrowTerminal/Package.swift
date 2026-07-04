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
        // Linux-only C shim exposing openpty(3) from <pty.h> (see Sources/CPty).
        // Empty/no-op on Apple platforms, where Darwin already declares openpty.
        .target(name: "CPty"),
        .target(
            name: "CrowTerminal",
            dependencies: [
                .product(name: "CrowCore", package: "CrowCore"),
                .target(name: "CPty", condition: .when(platforms: [.linux])),
            ],
            resources: [
                .copy("Resources/crow-shell-wrapper.sh"),
                .copy("Resources/crow-tmux.conf"),
                .copy("Resources/xterm"),
            ],
            linkerSettings: [
                // WebKit backs the macOS xterm.js surface (XTermSurfaceView);
                // those files are compiled-away on Linux via #if canImport(WebKit).
                .linkedFramework("WebKit", .when(platforms: [.macOS])),
                // libutil provides openpty(3) on Linux (declared via the CPty shim).
                .linkedLibrary("util", .when(platforms: [.linux])),
            ]
        ),
        .testTarget(
            name: "CrowTerminalTests",
            dependencies: ["CrowTerminal"]
        ),
    ]
)
