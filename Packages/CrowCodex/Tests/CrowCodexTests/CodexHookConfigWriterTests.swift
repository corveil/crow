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
        #expect(toml.contains("hooks = true"))
        #expect(!toml.contains("codex_hooks"), "deprecated codex_hooks key must not be written")
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
        #expect(toml.contains("hooks = true"))
        #expect(!toml.contains("codex_hooks"), "deprecated codex_hooks key must not be written")
    }

    @Test func installGlobalTomlConfigMigratesLegacyCodexHooksKey() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        // Pre-seed with the deprecated `codex_hooks` key that pre-fix
        // installs left behind. The migration should strip it and replace
        // it with the current `hooks` key.
        let legacy = """
        model = "gpt-4o"

        [features]
        codex_hooks = true
        memories = true
        """
        try legacy.write(
            toFile: codexHome.appendingPathComponent("config.toml").path,
            atomically: true, encoding: .utf8
        )

        try CodexHookConfigWriter.installGlobalTomlConfig(
            codexHome: codexHome.path,
            crowPath: "/usr/local/bin/crow"
        )

        let toml = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(toml.contains("hooks = true"), "modern hooks key should be present")
        #expect(!toml.contains("codex_hooks"), "deprecated codex_hooks key should be stripped")
        // Unrelated user entries survive.
        #expect(toml.contains("model = \"gpt-4o\""))
        #expect(toml.contains("memories = true"))

        // Migration is idempotent — re-running produces the same content.
        try CodexHookConfigWriter.installGlobalTomlConfig(
            codexHome: codexHome.path,
            crowPath: "/usr/local/bin/crow"
        )
        let second = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(toml == second)
    }

    @Test func installGlobalConfigEmitsNoAsyncHooksByDefault() throws {
        // Fail-closed default: without a `CodexVersionProbe` verdict, no entry
        // may carry `async`. On a pre-0.148 Codex an async entry isn't
        // downgraded, it's skipped — which would silently stop Crow's
        // session-state detection.
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try CodexHookConfigWriter.installGlobalConfig(
            codexHome: codexHome.path,
            crowPath: "/usr/local/bin/crow"
        )

        for (event, entry) in try hookEntries(in: codexHome) {
            #expect(
                entry["async"] == nil,
                "event \(event) has async flag; pre-0.148 Codex silently skips async hooks"
            )
        }
    }

    @Test func installGlobalConfigEmitsAsyncOnlyForPostToolUseWhenSupported() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try CodexHookConfigWriter.installGlobalConfig(
            codexHome: codexHome.path,
            crowPath: "/usr/local/bin/crow",
            asyncHooksSupported: true
        )

        var sawAsync = false
        for (event, entry) in try hookEntries(in: codexHome) {
            if event == "PostToolUse" {
                #expect(entry["async"] as? Bool == true, "PostToolUse should be async")
                sawAsync = true
            } else {
                // PreToolUse in particular stays sync so it is accepted ahead of
                // the PermissionRequest that follows it (#903).
                #expect(entry["async"] == nil, "event \(event) must stay synchronous")
            }
        }
        #expect(sawAsync, "PostToolUse entry should exist")
    }

    @Test func installGlobalConfigStripsAsyncOnDowngrade() throws {
        // A user who downgrades Codex (or whose probe stops answering) must not
        // be left with a stranded `async` on a build that would skip the hook.
        // Each event's entry is rebuilt whole, so the key disappears.
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try CodexHookConfigWriter.installGlobalConfig(
            codexHome: codexHome.path, crowPath: "/usr/local/bin/crow", asyncHooksSupported: true)
        try CodexHookConfigWriter.installGlobalConfig(
            codexHome: codexHome.path, crowPath: "/usr/local/bin/crow", asyncHooksSupported: false)

        for (event, entry) in try hookEntries(in: codexHome) {
            #expect(entry["async"] == nil, "event \(event) kept a stale async flag")
        }
    }

    /// Flatten `hooks.json` to `(eventName, innerHookEntry)` pairs.
    private func hookEntries(in codexHome: URL) throws -> [(String, [String: Any])] {
        let data = try Data(contentsOf: codexHome.appendingPathComponent("hooks.json"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        var pairs: [(String, [String: Any])] = []
        for (event, value) in hooks {
            for outer in value as! [[String: Any]] {
                for entry in outer["hooks"] as! [[String: Any]] {
                    pairs.append((event, entry))
                }
            }
        }
        return pairs
    }

    // MARK: - Inline parent-table safety (#843 review round 7)

    @Test func upsertTomlSectionLineDoesNotDuplicateInlineProjectsParent() {
        // Legacy inline `[projects]` with `"/p" = { … }`: appending a
        // `[projects."/p"]` header on top is a duplicate-key TOML error. The
        // upsert must recognize the inline form and bail, not append.
        let content = "[projects]\n\"/p\" = { trust_level = \"untrusted\" }\n"
        let result = CodexHookConfigWriter.upsertTomlSectionLine(
            content, section: "projects.\"/p\"", key: "trust_level", line: "trust_level = \"trusted\"")
        #expect(!result.contains("[projects.\"/p\"]"), "must not append a conflicting header")
        #expect(result == content, "inline form is left intact (not merged)")
    }

    @Test func upsertTomlSectionLineDoesNotDuplicateTopLevelInlineTable() {
        // Top-level `features = { … }`: appending `[features]` is a duplicate key.
        let content = "features = { hooks = false }\n"
        let result = CodexHookConfigWriter.upsertTomlSectionLine(
            content, section: "features", key: "hooks", line: "hooks = true")
        #expect(!result.contains("[features]"), "must not append a conflicting header")
    }

    @Test func upsertTomlSectionLineStillHandlesHeaderForm() {
        // Regression guard: the normal `[features]` header path still upserts.
        let content = "[features]\nmemories = true\n"
        let result = CodexHookConfigWriter.upsertTomlSectionLine(
            content, section: "features", key: "hooks", line: "hooks = true")
        #expect(result.contains("hooks = true"))
        #expect(result.contains("memories = true"))
    }
}
