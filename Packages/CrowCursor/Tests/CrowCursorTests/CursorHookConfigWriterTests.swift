import Foundation
import Testing
@testable import CrowCursor
@testable import CrowCore

@Suite("CursorHookConfigWriter")
struct CursorHookConfigWriterTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readHooks(_ path: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: path)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["hooks"] as! [String: Any]
    }

    private func command(_ hooks: [String: Any], _ key: String) -> String {
        let entries = hooks[key] as! [[String: Any]]
        let inner = entries.first!["hooks"] as! [[String: Any]]
        return inner.first!["command"] as! String
    }

    // MARK: - Per-project write

    @Test func writeHookConfigWritesPerWorktreeWithSession() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let sid = UUID()
        try CursorHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path,
            sessionID: sid,
            crowPath: "/opt/homebrew/bin/crow"
        )

        let hooksPath = worktree.appendingPathComponent(".cursor/hooks.json")
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: hooksPath)) as! [String: Any]
        // Versioned schema.
        #expect(root["version"] as? Int == 1)

        let hooks = root["hooks"] as! [String: Any]
        // Same curated camelCase event set.
        #expect(hooks.count == 6)
        for event in ["sessionStart", "preToolUse", "postToolUse", "beforeSubmitPrompt", "stop", "afterAgentResponse"] {
            #expect(hooks[event] != nil, "missing hook entry for \(event)")
        }

        // The command bakes in the session UUID and rewrites the event to its
        // Crow-canonical PascalCase name.
        let cmd = command(hooks, "preToolUse")
        #expect(cmd == "/opt/homebrew/bin/crow hook-event --session \(sid.uuidString) --agent cursor --event PreToolUse")
    }

    @Test func writeHookConfigMapsAfterAgentResponseToNotification() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        try CursorHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/usr/local/bin/crow")

        let hooks = try readHooks(worktree.appendingPathComponent(".cursor/hooks.json"))
        #expect(command(hooks, "afterAgentResponse").contains("--event Notification"))
    }

    @Test func writeHookConfigPostToolUseAndNotificationAsync() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        try CursorHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        let hooks = try readHooks(worktree.appendingPathComponent(".cursor/hooks.json"))
        for asyncKey in ["postToolUse", "afterAgentResponse"] {
            let entries = hooks[asyncKey] as! [[String: Any]]
            let inner = entries.first!["hooks"] as! [[String: Any]]
            #expect(inner.first!["async"] as? Bool == true, "\(asyncKey) should be async")
        }
        // Stop stays synchronous — its timing matters.
        let stop = hooks["stop"] as! [[String: Any]]
        let stopInner = stop.first!["hooks"] as! [[String: Any]]
        #expect(stopInner.first!["async"] == nil, "stop should be synchronous")
    }

    @Test func writeHookConfigPreservesUserEntries() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        // Pre-seed a user-managed hook for a non-Crow event.
        let cursorDir = worktree.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        let hooksPath = cursorDir.appendingPathComponent("hooks.json")
        let preExisting: [String: Any] = [
            "hooks": ["beforeShellExecution": [["hooks": [["type": "command", "command": "/usr/local/bin/guard"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: preExisting).write(to: hooksPath)

        try CursorHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        let hooks = try readHooks(hooksPath)
        #expect(hooks["beforeShellExecution"] != nil, "user-managed hook should survive")
        #expect(hooks["stop"] != nil, "Crow's stop hook should be installed")
    }

    @Test func writeHookConfigIsIdempotent() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let sid = UUID()
        let w = CursorHookConfigWriter()
        try w.writeHookConfig(worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")
        let first = try Data(contentsOf: worktree.appendingPathComponent(".cursor/hooks.json"))
        try w.writeHookConfig(worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")
        let second = try Data(contentsOf: worktree.appendingPathComponent(".cursor/hooks.json"))
        #expect(first == second)
    }

    // MARK: - Removal

    @Test func removeHookConfigDeletesWhenOnlyOursRemain() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let hooksPath = worktree.appendingPathComponent(".cursor/hooks.json")
        let w = CursorHookConfigWriter()
        try w.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        #expect(FileManager.default.fileExists(atPath: hooksPath.path))
        w.removeHookConfig(worktreePath: worktree.path)
        // Nothing but our entries + version scaffold → file removed.
        #expect(FileManager.default.fileExists(atPath: hooksPath.path) == false)
    }

    @Test func removeHookConfigPreservesUserEntries() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        let w = CursorHookConfigWriter()
        try w.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        // Add a user entry alongside ours.
        let hooksPath = worktree.appendingPathComponent(".cursor/hooks.json")
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: hooksPath)) as! [String: Any]
        var hooks = root["hooks"] as! [String: Any]
        hooks["beforeShellExecution"] = [["hooks": [["type": "command", "command": "/usr/local/bin/guard"]]]]
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: hooksPath)

        w.removeHookConfig(worktreePath: worktree.path)

        #expect(FileManager.default.fileExists(atPath: hooksPath.path), "file kept because a user entry remains")
        let after = try readHooks(hooksPath)
        #expect(after["beforeShellExecution"] != nil)
        #expect(after["stop"] == nil, "Crow entries removed")
    }

    // MARK: - Global-config migration

    @Test func removeManagedGlobalConfigStripsOnlyCrowEntries() throws {
        let cursorHome = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cursorHome) }
        // Simulate a legacy global config: a Crow-managed `stop` (old cwd form)
        // + a user's own `beforeShellExecution`.
        let hooksPath = cursorHome.appendingPathComponent("hooks.json")
        let legacy: [String: Any] = [
            "hooks": [
                "stop": [["hooks": [["type": "command", "command": "/bin/crow hook-event --agent cursor --event Stop"]]]],
                "beforeShellExecution": [["hooks": [["type": "command", "command": "/usr/local/bin/guard"]]]],
            ]
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: hooksPath)

        CursorHookConfigWriter.removeManagedGlobalConfig(cursorHome: cursorHome.path)

        let hooks = try readHooks(hooksPath)
        #expect(hooks["stop"] == nil, "legacy Crow entry stripped")
        #expect(hooks["beforeShellExecution"] != nil, "user entry preserved")
    }

    @Test func removeManagedGlobalConfigProtectsUserOwnedEventName() throws {
        let cursorHome = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cursorHome) }
        // A user's own `stop` hook (not Crow's) must NOT be stripped.
        let hooksPath = cursorHome.appendingPathComponent("hooks.json")
        let userConfig: [String: Any] = [
            "hooks": ["stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-stop"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: userConfig).write(to: hooksPath)

        CursorHookConfigWriter.removeManagedGlobalConfig(cursorHome: cursorHome.path)

        let hooks = try readHooks(hooksPath)
        #expect(hooks["stop"] != nil, "user's own stop hook preserved")
    }

    @Test func removeManagedGlobalConfigDeletesFileWhenEmptied() throws {
        let cursorHome = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: cursorHome) }
        let hooksPath = cursorHome.appendingPathComponent("hooks.json")
        let legacy: [String: Any] = [
            "hooks": ["stop": [["hooks": [["type": "command", "command": "/bin/crow hook-event --agent cursor --event Stop"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: legacy).write(to: hooksPath)

        CursorHookConfigWriter.removeManagedGlobalConfig(cursorHome: cursorHome.path)

        #expect(FileManager.default.fileExists(atPath: hooksPath.path) == false)
    }

    @Test func writeHookConfigCoexistsWithUserOwnedManagedEvent() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        // User already ships a `stop` hook (a managed event key) in the shared
        // project file.
        let cursorDir = worktree.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursorDir, withIntermediateDirectories: true)
        let hooksPath = cursorDir.appendingPathComponent("hooks.json")
        let userStop: [String: Any] = [
            "hooks": ["stop": [["hooks": [["type": "command", "command": "/usr/local/bin/my-stop"]]]]]
        ]
        try JSONSerialization.data(withJSONObject: userStop).write(to: hooksPath)

        let w = CursorHookConfigWriter()
        try w.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        // Both groups present: user's own `stop` is NOT clobbered, Crow's added.
        var hooks = try readHooks(hooksPath)
        var stopGroups = hooks["stop"] as! [[String: Any]]
        #expect(stopGroups.count == 2, "user stop + crow stop coexist")
        let commands = stopGroups.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
        #expect(commands.contains { $0.contains("/usr/local/bin/my-stop") })
        #expect(commands.contains { $0.contains("hook-event --session") })

        // Idempotent: a second write doesn't duplicate Crow's group.
        try w.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        hooks = try readHooks(hooksPath)
        stopGroups = hooks["stop"] as! [[String: Any]]
        #expect(stopGroups.count == 2, "re-write drops the prior crow group before appending")

        // Remove strips only Crow's group, leaving the user's stop.
        w.removeHookConfig(worktreePath: worktree.path)
        hooks = try readHooks(hooksPath)
        let remaining = hooks["stop"] as! [[String: Any]]
        #expect(remaining.count == 1)
        let cmd = (remaining.first!["hooks"] as! [[String: Any]]).first!["command"] as! String
        #expect(cmd == "/usr/local/bin/my-stop", "user's own stop hook survives removal")
    }

    @Test func writeHookConfigAddsGitExclude() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        // Simulate a normal git checkout (`.git` is a directory).
        try FileManager.default.createDirectory(
            at: worktree.appendingPathComponent(".git/info"), withIntermediateDirectories: true)

        try CursorHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        let exclude = try String(
            contentsOf: worktree.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        #expect(exclude.contains(".cursor/hooks.json"))

        // Idempotent — a second write doesn't duplicate the line.
        try CursorHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        let after = try String(
            contentsOf: worktree.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
        let count = after.components(separatedBy: ".cursor/hooks.json").count - 1
        #expect(count == 1, "pattern listed exactly once")
    }
}
