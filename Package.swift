// swift-tools-version: 6.0
import PackageDescription

// Swift 6.1 Linux + ld.gold: libswiftObservation.so references swift::threading::fatal
// in libswiftCore without exporting it (swiftlang/swift#75670). The symbol resolves at
// runtime; --allow-shlib-undefined is the gold-compatible spelling (not -z …).
let linuxObservationLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "--allow-shlib-undefined"], .when(platforms: [.linux])),
]

let package = Package(
    name: "Crow",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "crow", targets: ["CrowCLI"]),
        // Headless cross-platform daemon (CROW-581). Build standalone on Linux
        // with `swift build --product crowd` — it does not depend on the AppKit
        // `Crow` target or its generated BuildInfo.
        .executable(name: "crowd", targets: ["crowd"]),
    ],
    dependencies: [
        .package(path: "Packages/CrowCLI"),
        .package(path: "Packages/CrowDaemon"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "CrowCLI",
            dependencies: [
                .product(name: "CrowCLILib", package: "CrowCLI"),
            ],
            path: "Sources/CrowCLI",
            linkerSettings: linuxObservationLinkerSettings
        ),
        .executableTarget(
            name: "crowd",
            dependencies: [
                .product(name: "CrowDaemon", package: "CrowDaemon"),
            ],
            path: "Sources/crowd",
            linkerSettings: linuxObservationLinkerSettings
        ),
    ]
)
