// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowCore", targets: ["CrowCore"]),
    ],
    targets: [
        .target(
            name: "CrowCore",
            linkerSettings: [
                // Swift 6.1 Linux: libswiftObservation.so references swift::threading::fatal,
                // which lives in libswiftCore.so but is not exported at link time
                // (swiftlang/swift#75670). The symbol resolves at runtime when linking
                // executables (crowd, crow) that transitively use @Observable.
                .unsafeFlags(
                    ["-Xlinker", "-z", "-Xlinker", "allow-shlib-undefined"],
                    .when(platforms: [.linux])
                ),
            ]
        ),
        .testTarget(name: "CrowCoreTests", dependencies: ["CrowCore"]),
    ]
)
