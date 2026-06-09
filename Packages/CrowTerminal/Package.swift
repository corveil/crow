// swift-tools-version: 6.0
import PackageDescription
import Foundation

// CROW-466 spike: opt into SwiftTerm renderer by exporting CROW_RENDERER_SWIFTTERM=1
// before `swift build`. When set, GhosttyKit is unlinked, SwiftTerm is added as a
// dependency, and source files gate on `#if CROW_RENDERER_SWIFTTERM`.
let useSwiftTerm = ProcessInfo.processInfo.environment["CROW_RENDERER_SWIFTTERM"] != nil

var packageDependencies: [Package.Dependency] = [
    .package(path: "../CrowCore"),
]
var targetDependencies: [Target.Dependency] = [
    .product(name: "CrowCore", package: "CrowCore"),
]
var targets: [Target] = []
var swiftSettings: [SwiftSetting] = []
var linkerSettings: [LinkerSetting] = [
    .linkedFramework("Carbon"),
    .linkedFramework("Metal"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("CoreText"),
    .linkedFramework("IOSurface"),
    .linkedLibrary("c++"),
]

if useSwiftTerm {
    packageDependencies.append(
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0")
    )
    targetDependencies.append(.product(name: "SwiftTerm", package: "SwiftTerm"))
    swiftSettings.append(.define("CROW_RENDERER_SWIFTTERM"))
} else {
    targetDependencies.append("GhosttyKit")
    swiftSettings.append(
        .unsafeFlags(["-I../../Frameworks/GhosttyKit.xcframework/macos-arm64/Headers"])
    )
    targets.append(
        .binaryTarget(
            name: "GhosttyKit",
            path: "../../Frameworks/GhosttyKit.xcframework"
        )
    )
}

targets.insert(
    .target(
        name: "CrowTerminal",
        dependencies: targetDependencies,
        resources: [
            .copy("Resources/crow-shell-wrapper.sh"),
            .copy("Resources/crow-tmux.conf"),
            .copy("Resources/spike-link-test.sh"),
        ],
        swiftSettings: swiftSettings,
        linkerSettings: linkerSettings
    ),
    at: 0
)

targets.append(
    .testTarget(
        name: "CrowTerminalTests",
        dependencies: ["CrowTerminal"]
    )
)

let package = Package(
    name: "CrowTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowTerminal", targets: ["CrowTerminal"]),
    ],
    dependencies: packageDependencies,
    targets: targets
)
