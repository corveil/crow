// swift-tools-version: 6.0
import PackageDescription

// CrowEngine — the headless session/engine layer extracted out of the macOS app
// (CROW-581 headless-engine migration). Both the AppKit `Crow` app and the
// `crowd` daemon can host this package; it links no AppKit/SwiftUI. Host-only
// actions (clipboard, open-in-editor, notifications) go through `HostBridge`.
let package = Package(
    name: "CrowEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowEngine", targets: ["CrowEngine"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
        .package(path: "../CrowPersistence"),
        .package(path: "../CrowGit"),
        .package(path: "../CrowProvider"),
        .package(path: "../CrowTerminal"),
        .package(path: "../CrowClaude"),
        .package(path: "../CrowIPC"),
    ],
    targets: [
        .target(
            name: "CrowEngine",
            dependencies: [
                "CrowCore",
                "CrowPersistence",
                "CrowGit",
                "CrowProvider",
                "CrowTerminal",
                "CrowClaude",
                "CrowIPC",
            ]
        ),
        .testTarget(
            name: "CrowEngineTests",
            dependencies: ["CrowEngine"]
        ),
    ]
)
