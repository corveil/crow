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

    private func makeTempWorktree() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        CodexHookConfigWriter.resetTrackedCacheForTesting()
        return url
    }

    // MARK: - Per-worktree hook document (CROW-1060)

    @Test func generateDocumentBakesInSessionUUIDAndAgentForAllEvents() throws {
        let sid = UUID()
        let doc = CodexHookConfigWriter.generateDocument(
            sessionID: sid, crowPath: "/opt/homebrew/bin/crow", asyncHooksSupported: false)
        let hooks = try #require(doc["hooks"] as? [String: Any])

        #expect(hooks.count == CodexHookConfigWriter.allEvents.count)
        #expect(hooks["Interrupt"] != nil, "CROW-1177: Interrupt must be registered")
        for event in CodexHookConfigWriter.allEvents {
            let groups = try #require(hooks[event] as? [[String: Any]], "missing hook entry for \(event)")
            let entry = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
            #expect(entry["type"] as? String == "command")
            let command = try #require(entry["command"] as? String)
            // Shell-quoted crow path, session UUID routing, explicit agent kind.
            #expect(command == "'/opt/homebrew/bin/crow' hook-event --session \(sid.uuidString) --agent codex --event \(event)")
            let expectedTimeout = event == "Interrupt" ? 3 : 5
            #expect(entry["timeout"] as? Int == expectedTimeout, "event \(event) timeout")
            #expect(entry["async"] == nil, "Interrupt (and every other non-PostToolUse event) stays sync")
        }
    }

    @Test func generateDocumentShellQuotesSpacedCrowPath() throws {
        let doc = CodexHookConfigWriter.generateDocument(
            sessionID: UUID(), crowPath: "/Users/me/My Apps/crow", asyncHooksSupported: false)
        let hooks = try #require(doc["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let entry = try #require((stop.first?["hooks"] as? [[String: Any]])?.first)
        let command = try #require(entry["command"] as? String)
        #expect(command.hasPrefix("'/Users/me/My Apps/crow' hook-event"))
    }

    @Test func writeHookConfigWritesPerWorktreeSessionScopedFile() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let sid = UUID()
        try CodexHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")

        let path = worktree.appendingPathComponent(".codex/hooks.json")
        #expect(FileManager.default.fileExists(atPath: path.path))

        let data = try #require(FileManager.default.contents(atPath: path.path))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(CodexHookConfigWriter.isCrowOwned(root))
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let entry = try #require((stop.first?["hooks"] as? [[String: Any]])?.first)
        let command = try #require(entry["command"] as? String)
        #expect(command.contains("--session \(sid.uuidString)"))
        #expect(command.contains("--agent codex"))
    }

    @Test func writeHookConfigIsIdempotent() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let sid = UUID()
        let path = worktree.appendingPathComponent(".codex/hooks.json")

        try CodexHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")
        let first = try #require(FileManager.default.contents(atPath: path.path))
        try CodexHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")
        let second = try #require(FileManager.default.contents(atPath: path.path))
        #expect(first == second)
    }

    @Test func writeDoesNotClobberUserHooks() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let codexDir = worktree.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let path = codexDir.appendingPathComponent("hooks.json")
        // A user's own hooks.json (no `hook-event --session` marker).
        let userDoc = "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"/usr/local/bin/my-tool\"}]}]}}"
        try userDoc.write(to: path, atomically: true, encoding: .utf8)

        try CodexHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        let body = try String(contentsOf: path, encoding: .utf8)
        #expect(body == userDoc, "a user-owned .codex/hooks.json must be left untouched")
    }

    // MARK: - Async gating (CROW-999)

    @Test func writeEmitsNoAsyncHooksByDefault() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }
        try CodexHookConfigWriter(asyncHooksSupported: false).writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        for (event, entry) in try hookEntries(in: worktree) {
            #expect(
                entry["async"] == nil,
                "event \(event) has async flag; pre-0.148 Codex silently skips async hooks")
        }
    }

    @Test func writeEmitsAsyncOnlyForPostToolUseWhenSupported() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }
        try CodexHookConfigWriter(asyncHooksSupported: true).writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        var sawAsync = false
        for (event, entry) in try hookEntries(in: worktree) {
            if event == "PostToolUse" {
                #expect(entry["async"] as? Bool == true, "PostToolUse should be async")
                sawAsync = true
            } else {
                // PreToolUse stays sync so it is accepted ahead of
                // the PermissionRequest that follows it (#903). Interrupt
                // stays sync because it mutates activityState (CROW-1177).
                #expect(entry["async"] == nil, "event \(event) must stay synchronous")
            }
        }
        #expect(sawAsync, "PostToolUse entry should exist")
    }

    // MARK: - Removal

    @Test func removeHookConfigDeletesCrowOwnedFileAndPrunesDir() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        try CodexHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".codex/hooks.json").path))

        CodexHookConfigWriter().removeHookConfig(worktreePath: worktree.path)
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".codex/hooks.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".codex").path))
    }

    @Test func removeHookConfigLeavesUserFile() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let codexDir = worktree.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let path = codexDir.appendingPathComponent("hooks.json")
        try "{\"hooks\":{}}".write(to: path, atomically: true, encoding: .utf8)

        CodexHookConfigWriter().removeHookConfig(worktreePath: worktree.path)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func isCrowOwnedRejectsEmptyAndForeign() {
        #expect(!CodexHookConfigWriter.isCrowOwned([:]))
        #expect(!CodexHookConfigWriter.isCrowOwned(["hooks": [String: Any]()]))
        #expect(!CodexHookConfigWriter.isCrowOwned(["hooks": ["Stop": "nope"]]))
    }

    @Test func isCrowOwnedRecognizesLegacySixEventFile() throws {
        // A CROW-1060 file has the original six events and no Interrupt. It
        // must still count as Crow-owned so `writeHookConfig` can upgrade it.
        let sid = UUID()
        var hooks: [String: Any] = [:]
        for event in CodexHookConfigWriter.ownershipEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "/bin/crow hook-event --session \(sid.uuidString) --agent codex --event \(event)",
                ]]
            ]]
        }
        #expect(CodexHookConfigWriter.isCrowOwned(["hooks": hooks]))
        #expect(hooks["Interrupt"] == nil)
    }

    @Test func writeHookConfigUpgradesLegacySixEventFileWithInterrupt() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let sid = UUID()
        var hooks: [String: Any] = [:]
        for event in CodexHookConfigWriter.ownershipEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "/bin/crow hook-event --session \(sid.uuidString) --agent codex --event \(event)",
                ]]
            ]]
        }
        let codexDir = worktree.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let path = codexDir.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: ["hooks": hooks]).write(to: path)

        try CodexHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")

        let after = try #require(FileManager.default.contents(atPath: path.path))
        let root = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        let afterHooks = try #require(root["hooks"] as? [String: Any])
        #expect(afterHooks["Interrupt"] != nil, "upgrade must register Interrupt")
        #expect(CodexHookConfigWriter.isCrowOwned(root))
    }

    @Test func isCrowOwnedRejectsUserInterruptGraftedOntoCrowFile() throws {
        let sid = UUID()
        var hooks: [String: Any] = [:]
        for event in CodexHookConfigWriter.ownershipEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "/bin/crow hook-event --session \(sid.uuidString) --agent codex --event \(event)",
                ]]
            ]]
        }
        hooks["Interrupt"] = [[
            "hooks": [["type": "command", "command": "/usr/local/bin/user-interrupt"]]
        ]]
        #expect(!CodexHookConfigWriter.isCrowOwned(["hooks": hooks]),
                "a user Interrupt on an otherwise Crow file must not be clobbered")
    }

    // MARK: - Global-config migration (one-time cleanup)

    @Test func removeManagedGlobalConfigStripsCrowEntriesAndDeletesWhenEmpty() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        // Seed the legacy global form the retired `installGlobalConfig` wrote:
        // one Crow group per event, commands carrying `hook-event --agent codex`
        // (no `--session`, cwd-resolved).
        var hooks: [String: Any] = [:]
        for event in CodexHookConfigWriter.allEvents {
            hooks[event] = [[
                "hooks": [[
                    "type": "command",
                    "command": "/opt/homebrew/bin/crow hook-event --agent codex --event \(event)",
                ]]
            ]]
        }
        let hooksPath = codexHome.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: ["hooks": hooks])
            .write(to: hooksPath)

        CodexHookConfigWriter.removeManagedGlobalConfig(codexHome: codexHome.path)

        // Only Crow's entries existed, so the file is removed rather than left a husk.
        #expect(!FileManager.default.fileExists(atPath: hooksPath.path))
    }

    @Test func removeManagedGlobalConfigPreservesUserEntries() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        let seed: [String: Any] = [
            "hooks": [
                // Crow's managed Stop group.
                "Stop": [[
                    "hooks": [["type": "command", "command": "/bin/crow hook-event --agent codex --event Stop"]]
                ]],
                // A user's own hook for an event Crow doesn't manage.
                "CustomUserEvent": [[
                    "hooks": [["type": "command", "command": "/usr/local/bin/my-tool"]]
                ]],
            ]
        ]
        let hooksPath = codexHome.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: seed).write(to: hooksPath)

        CodexHookConfigWriter.removeManagedGlobalConfig(codexHome: codexHome.path)

        let after = try #require(FileManager.default.contents(atPath: hooksPath.path))
        let root = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks["Stop"] == nil, "Crow's managed group should be stripped")
        #expect(hooks["CustomUserEvent"] != nil, "user-managed hook entry should be preserved")
    }

    @Test func removeManagedGlobalConfigPreservesUserGroupOnManagedEvent() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        // Same managed event (Stop) carrying both Crow's group and a user's own.
        let seed: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "/bin/crow hook-event --agent codex --event Stop"]]],
                    ["hooks": [["type": "command", "command": "/usr/local/bin/user-stop"]]],
                ]
            ]
        ]
        let hooksPath = codexHome.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: seed).write(to: hooksPath)

        CodexHookConfigWriter.removeManagedGlobalConfig(codexHome: codexHome.path)

        let after = try #require(FileManager.default.contents(atPath: hooksPath.path))
        let root = try #require(try JSONSerialization.jsonObject(with: after) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 1, "only Crow's group should be removed")
        let command = try #require((stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(command == "/usr/local/bin/user-stop")
    }

    @Test func removeManagedGlobalConfigNoOpsWhenAbsent() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        // No hooks.json at all — must not throw or create one.
        CodexHookConfigWriter.removeManagedGlobalConfig(codexHome: codexHome.path)
        #expect(!FileManager.default.fileExists(
            atPath: codexHome.appendingPathComponent("hooks.json").path))
    }

    // MARK: - config.toml (feature enable + notify retirement)

    @Test func installGlobalTomlConfigEnablesHooksWithoutNotify() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }
        try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome.path)

        let toml = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(toml.contains("[features]"))
        #expect(toml.contains("hooks = true"))
        // CROW-1060: the notify bridge is retired — no notify line is written.
        #expect(!toml.contains("notify"), "the legacy notify bridge line must not be written")
        #expect(!toml.contains("codex_hooks"), "deprecated codex_hooks key must not be written")
    }

    @Test func installGlobalTomlConfigRetiresCrowNotifyLine() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        // A prior Crow wrote the notify bridge line; a current boot must strip it.
        let legacy = """
        model = "gpt-4o"
        notify = ["/opt/homebrew/bin/crow", "codex-notify"]

        [features]
        hooks = true
        """
        try legacy.write(
            toFile: codexHome.appendingPathComponent("config.toml").path,
            atomically: true, encoding: .utf8)

        try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome.path)

        let toml = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(!toml.contains("codex-notify"), "the retired notify bridge line should be stripped")
        #expect(toml.contains("model = \"gpt-4o\""), "unrelated user config survives")
        #expect(toml.contains("hooks = true"))
    }

    @Test func installGlobalTomlConfigPreservesUserNotify() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        // A user's own notify hook (not Crow's) must survive.
        let user = """
        notify = ["/usr/local/bin/my-notifier"]
        model = "gpt-4o"
        """
        try user.write(
            toFile: codexHome.appendingPathComponent("config.toml").path,
            atomically: true, encoding: .utf8)

        try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome.path)

        let toml = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(toml.contains("/usr/local/bin/my-notifier"), "a user's own notify must be preserved")
    }

    @Test func installGlobalTomlConfigMigratesLegacyCodexHooksKey() throws {
        let codexHome = try makeTempCodexHome()
        defer { try? FileManager.default.removeItem(at: codexHome) }

        // Pre-seed with the deprecated `codex_hooks` key that pre-fix installs
        // left behind. The migration should strip it and replace it with `hooks`.
        let legacy = """
        model = "gpt-4o"

        [features]
        codex_hooks = true
        memories = true
        """
        try legacy.write(
            toFile: codexHome.appendingPathComponent("config.toml").path,
            atomically: true, encoding: .utf8)

        try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome.path)

        let toml = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(toml.contains("hooks = true"), "modern hooks key should be present")
        #expect(!toml.contains("codex_hooks"), "deprecated codex_hooks key should be stripped")
        #expect(toml.contains("model = \"gpt-4o\""))
        #expect(toml.contains("memories = true"))

        // Idempotent — re-running produces the same content.
        try CodexHookConfigWriter.installGlobalTomlConfig(codexHome: codexHome.path)
        let second = try String(contentsOf: codexHome.appendingPathComponent("config.toml"))
        #expect(toml == second)
    }

    /// Flatten a worktree's `.codex/hooks.json` to `(eventName, innerHookEntry)`.
    private func hookEntries(in worktree: URL) throws -> [(String, [String: Any])] {
        let data = try Data(contentsOf: worktree.appendingPathComponent(".codex/hooks.json"))
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
