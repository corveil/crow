// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CrowOpenCode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CrowOpenCode", targets: ["CrowOpenCode"]),
    ],
    dependencies: [
        .package(path: "../CrowCore"),
        // SHA-256 for the MCP-mirror provenance digest (so the sidecar records a
        // hash, not a third plaintext copy of the Jira token). Already resolved
        // repo-wide via CrowDaemon's web-auth PBKDF2 (CROW-593).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "CrowOpenCode",
            dependencies: [
                "CrowCore",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "CrowOpenCodeTests", dependencies: ["CrowOpenCode"]),
    ]
)
