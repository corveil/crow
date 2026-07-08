import ArgumentParser
import Foundation

// MARK: - Setup Command

/// First-time setup wizard for Crow.
///
/// Checks for runtime dependencies, prompts for a development root and workspaces,
/// then scaffolds the directory structure and configuration files.
public struct Setup: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "setup", abstract: "First-time setup for Crow")

    @Option(name: .long, help: "Development root path") var devRoot: String?

    public init() {}

    public func run() throws {
        print("Welcome to Crow setup.\n")

        // Check for runtime dependencies
        let tools: [(name: String, install: String)] = [
            ("git", "xcode-select --install"),
            ("gh", "brew install gh"),
            ("claude", "https://claude.ai/download"),
        ]
        for tool in tools {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            proc.arguments = [tool.name]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                print("  WARNING: \(tool.name) not found. Install: \(tool.install)")
            }
        }
        print()

        // Determine devRoot
        let root: String
        if let devRoot {
            root = devRoot
        } else {
            let defaultPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Dev").path
            print("Development root [\(defaultPath)]: ", terminator: "")
            if let input = readLine()?.trimmingCharacters(in: .whitespaces), !input.isEmpty {
                root = input
            } else {
                root = defaultPath
            }
        }

        // Create devRoot
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        print("  Using: \(root)\n")

        // Collect workspaces
        var workspaces: [SetupWorkspace] = []
        var addMore = true

        while addMore {
            print("Add a workspace:")
            print("  Name: ", terminator: "")
            guard let name = readLine()?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                break
            }

            print("  Provider (github/gitlab) [github]: ", terminator: "")
            let providerInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let provider = providerInput.isEmpty ? "github" : providerInput

            var host: String? = nil
            if provider == "gitlab" {
                print("  GitLab host (e.g., gitlab.example.com): ", terminator: "")
                let hostInput = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
                if !hostInput.isEmpty { host = hostInput }
            }

            let cli = provider == "github" ? "gh" : "glab"
            workspaces.append(SetupWorkspace(name: name, provider: provider, cli: cli, host: host, alwaysInclude: []))

            // Create workspace directory
            let wsPath = (root as NSString).appendingPathComponent(name)
            try FileManager.default.createDirectory(atPath: wsPath, withIntermediateDirectories: true)
            print("  Created: \(wsPath)")

            print("  Add another? (y/n) [n]: ", terminator: "")
            addMore = (readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "y")
            print()
        }

        // Build config JSON using Codable
        let config = SetupConfig(
            workspaces: workspaces,
            defaults: SetupDefaults(
                provider: "github",
                cli: "gh",
                branchPrefix: "feature/",
                excludeDirs: ["node_modules", ".git", "vendor", "dist", "build", "target"]
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try encoder.encode(config)
        let configJSON = String(data: configData, encoding: .utf8)!

        // Write devRoot pointer
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("crow", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try root.write(to: appSupport.appendingPathComponent("devroot"), atomically: true, encoding: .utf8)

        // Scaffold .claude directory
        let claudeDir = (root as NSString).appendingPathComponent(".claude")
        let skillsDir = (claudeDir as NSString).appendingPathComponent("skills/crow-workspace")
        try FileManager.default.createDirectory(atPath: skillsDir, withIntermediateDirectories: true)

        // Write config
        let configPath = (claudeDir as NSString).appendingPathComponent("config.json")
        try configJSON.write(toFile: configPath, atomically: true, encoding: .utf8)

        // Write CLAUDE.md (minimal version)
        let claudeMDPath = (claudeDir as NSString).appendingPathComponent("CLAUDE.md")
        if !FileManager.default.fileExists(atPath: claudeMDPath) {
            try "# Crow — Manager Context\n\nSee crow --help for CLI reference.\n\n## Known Issues / Corrections\n".write(
                toFile: claudeMDPath, atomically: true, encoding: .utf8)
        }

        print("Configuration saved to: \(configPath)")
        print("Workspace scaffolded at: \(claudeDir)/")
        print()
        print("Next steps:")
        print("  1. Build:  make build")
        print("  2. Launch: .build/debug/crowd  (then open the web UI)")
        print("  3. CLI:    crow --help")
    }
}

// MARK: - Setup Config Types

/// Workspace entry for the setup configuration file.
struct SetupWorkspace: Codable, Sendable {
    let name: String
    let provider: String
    let cli: String
    let host: String?
    let alwaysInclude: [String]
}

/// Default settings for the setup configuration file.
struct SetupDefaults: Codable, Sendable {
    let provider: String
    let cli: String
    let branchPrefix: String
    let excludeDirs: [String]
}

/// Top-level setup configuration written to `.claude/config.json`.
struct SetupConfig: Codable, Sendable {
    let workspaces: [SetupWorkspace]
    let defaults: SetupDefaults
}
