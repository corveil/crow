import Foundation
import Testing
@testable import CrowCodex
@testable import CrowCore

@Suite("CodexHookConfigWriter")
struct CodexHookConfigWriterTests {
    private func makeTempCodexHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func writeHookConfigIsNoOp() throws {
        // Per-session writes are no-ops — Codex hooks are global.
        let writer = CodexHookConfigWriter()
        let tmp = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writer.writeHookConfig(
            worktreePath: tmp.path,
            sessionID: UUID(),
            crowPath: "/usr/local/bin/crow"
        )
        // No file should have been created in the worktree.
        let files = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        #expect(files.isEmpty)
    }

    @Test func installGlobalConfigWritesAllSixEvents() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try CodexHookConfigWriter.installGlobalConfig(
            codexHome: codexHome.path,
            crowPath: "/opt/homebrew/bin/crow"
        )

        let hooksPath = codexHome.appendingPathComponent("hooks.json")
        let data = try Data(contentsOf: hooksPath)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]

        #expect(hooks.count == 6)
        for event in ["SessionStart", "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "PermissionRequest"] {
            #expect(hooks[event] != nil, "missing hook entry for \(event)")
        }

        // Spot-check the command shape.
        let entries = hooks["PreToolUse"] as! [[String: Any]]
        let inner = entries.first!["hooks"] as! [[String: Any]]
        let command = inner.first!["command"] as! String
        #expect(command == "/opt/homebrew/bin/crow hook-event --agent codex --event PreToolUse")
    }

    @Test func installGlobalConfigPreservesUserEntries() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        // Pre-seed a user-managed hook for a non-Crow event.
        let hooksPath = codexHome.appendingPathComponent("hooks.json")
        let preExisting: [String: Any] = [
            "hooks": [
                "CustomUserEvent": [
                    ["hooks": [["type": "command", "command": "/usr/local/bin/my-tool"]]]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: preExisting)
        try data.write(to: hooksPath)

        try CodexHookConfigWriter.installGlobalConfig(
            codexHome: codexHome.path,
            crowPath: "/usr/local/bin/crow"
        )

        let after = try Data(contentsOf: hooksPath)
        let json = try JSONSerialization.jsonObject(with: after) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        #expect(hooks["CustomUserEvent"] != nil, "user-managed hook entry should be preserved")
        #expect(hooks["Stop"] != nil, "Crow's Stop hook should still be installed")
    }

    @Test func installGlobalConfigIsIdempotent() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try CodexHookConfigWriter.installGlobalConfig(codexHome: codexHome.path, crowPath: "/bin/crow")
        let first = try Data(contentsOf: codexHome.appendingPathComponent("hooks.json"))
        try CodexHookConfigWriter.installGlobalConfig(codexHome: codexHome.path, crowPath: "/bin/crow")
        let second = try Data(contentsOf: codexHome.appendingPathComponent("hooks.json"))
        #expect(first == second)
    }

    // MARK: - TOML config

    @Test func installGlobalTomlConfigCreatesFreshFile() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try CodexHookConfigWriter.installGlobalTomlConfig(
            codexHome: codexHome.path,
            crowPath: "/opt/homebrew/bin/crow"
        )
        let toml = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(toml.contains("notify = [\"/opt/homebrew/bin/crow\", \"codex-notify\"]"))
        #expect(toml.contains("[features]"))
        #expect(toml.contains("codex_hooks = true"))
    }

    @Test func installGlobalTomlConfigPreservesUserSettings() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let preExisting = """
        # User config
        model = "gpt-4o"

        [features]
        memories = true
        """
        try preExisting.write(
            toFile: codexHome.appendingPathComponent("config.toml").path,
            atomically: true, encoding: .utf8
        )

        try CodexHookConfigWriter.installGlobalTomlConfig(
            codexHome: codexHome.path,
            crowPath: "/usr/local/bin/crow"
        )

        let toml = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        // User entries preserved.
        #expect(toml.contains("model = \"gpt-4o\""))
        #expect(toml.contains("memories = true"))
        // Crow entries added.
        #expect(toml.contains("notify = "))
        #expect(toml.contains("codex_hooks = true"))
    }
}
