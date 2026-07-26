import Foundation
import Testing
@testable import CrowAntigravity
@testable import CrowCore

@Suite("AntigravityHookConfigWriter")
struct AntigravityHookConfigWriterTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readHooks(_ path: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: path)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return json["hooks"] as! [String: Any]
    }

    private func entry(_ hooks: [String: Any], _ event: String) -> [String: Any] {
        let groups = hooks[event] as! [[String: Any]]
        let inner = groups.first!["hooks"] as! [[String: Any]]
        return inner.first!
    }

    private func command(_ hooks: [String: Any], _ event: String) -> String {
        entry(hooks, event)["command"] as! String
    }

    // MARK: - Per-worktree write, Claude-style schema, UUID baked in

    @Test func writesPerWorktreeWithSessionAndPascalCaseEvents() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let sid = UUID()
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path,
            sessionID: sid,
            crowPath: "/opt/homebrew/bin/crow"
        )

        let hooksPath = worktree.appendingPathComponent(".agents/hooks.json")
        let hooks = try readHooks(hooksPath)
        // Exactly the documented v1.1.7 lifecycle events.
        #expect(hooks.count == 5)
        for event in ["PreInvocation", "PostInvocation", "PreToolUse", "PostToolUse", "Stop"] {
            #expect(hooks[event] != nil, "missing hook entry for \(event)")
        }

        // Claude-style schema has NO top-level version field.
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: hooksPath)) as! [String: Any]
        #expect(root["version"] == nil)

        // Command bakes the session UUID + --agent antigravity + PascalCase event.
        #expect(command(hooks, "PreToolUse")
            == "'/opt/homebrew/bin/crow' hook-event --session \(sid.uuidString) --agent antigravity --event PreToolUse")
    }

    @Test func stopSyncPostToolUseAndPostInvocationAsync() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/usr/local/bin/crow")

        let hooks = try readHooks(worktree.appendingPathComponent(".agents/hooks.json"))
        #expect(entry(hooks, "PostToolUse")["async"] as? Bool == true)
        #expect(entry(hooks, "PostInvocation")["async"] as? Bool == true)
        // Stop / PreToolUse / PreInvocation stay synchronous (ordering + timing).
        #expect(entry(hooks, "Stop")["async"] == nil)
        #expect(entry(hooks, "PreToolUse")["async"] == nil)
        #expect(entry(hooks, "PreInvocation")["async"] == nil)
    }

    // MARK: - Idempotency + user-group preservation

    @Test func rewriteIsIdempotentAndPreservesUserGroups() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()

        // Seed a user-authored group for a managed event.
        let agentsDir = worktree.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let userSeed: [String: Any] = [
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "my-own-hook"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: userSeed)
            .write(to: agentsDir.appendingPathComponent("hooks.json"))

        let writer = AntigravityHookConfigWriter()
        let sid = UUID()
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")

        let stopGroups = try readHooks(worktree.appendingPathComponent(".agents/hooks.json"))["Stop"] as! [[String: Any]]
        // Exactly two groups survive: the user's + one (not two) Crow group.
        #expect(stopGroups.count == 2)
        let commands = stopGroups.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
        #expect(commands.contains("my-own-hook"))
        #expect(commands.contains { $0.contains("--agent antigravity") })
    }

    // MARK: - remove

    @Test func removeStripsCrowGroupsButKeepsUserGroups() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let agentsDir = worktree.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let userSeed: [String: Any] = [
            "hooks": [
                "PreToolUse": [["hooks": [["type": "command", "command": "user-pretool"]]]],
            ],
        ]
        try JSONSerialization.data(withJSONObject: userSeed)
            .write(to: agentsDir.appendingPathComponent("hooks.json"))

        let writer = AntigravityHookConfigWriter()
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: worktree.path)

        let hooks = try readHooks(worktree.appendingPathComponent(".agents/hooks.json"))
        // The user's PreToolUse group survives; every Crow group is gone.
        let pre = hooks["PreToolUse"] as! [[String: Any]]
        #expect(pre.count == 1)
        #expect((pre.first!["hooks"] as! [[String: Any]]).first!["command"] as? String == "user-pretool")
        #expect(hooks["Stop"] == nil)
    }

    @Test func removeDeletesFileWhenOnlyCrowGroupsExisted() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let writer = AntigravityHookConfigWriter()
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: worktree.path)
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".agents/hooks.json").path))
    }

    // MARK: - Global-config migration (double-fire guard)

    @Test func removeManagedGlobalConfigStripsOnlyCrowGroups() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let seed: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "user-global-hook"]]],
                    ["hooks": [["type": "command", "command": "/x/crow hook-event --session X --agent antigravity --event Stop"]]],
                ],
            ],
        ]
        let path = home.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: seed).write(to: path)

        AntigravityHookConfigWriter.removeManagedGlobalConfig(geminiConfigHome: home.path)

        let stop = try readHooks(path)["Stop"] as! [[String: Any]]
        #expect(stop.count == 1)
        #expect((stop.first!["hooks"] as! [[String: Any]]).first!["command"] as? String == "user-global-hook")
    }

    // MARK: - Git-tracked guard + exclude

    @Test func skipsWriteWhenFileIsGitTracked() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        func git(_ args: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.environment = ProcessInfo.processInfo.environment.merging([
                "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
                "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
            ]) { _, new in new }
            try? p.run(); p.waitUntilExit()
        }
        git(["init"])
        let agentsDir = repo.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let committed: [String: Any] = ["hooks": ["Stop": [["hooks": [["type": "command", "command": "committed"]]]]]]
        try JSONSerialization.data(withJSONObject: committed)
            .write(to: agentsDir.appendingPathComponent("hooks.json"))
        git(["add", ".agents/hooks.json"])
        git(["commit", "-m", "seed"])

        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: repo.path, sessionID: UUID(), crowPath: "/bin/crow")

        // The committed file is left untouched — no Crow group injected.
        let hooks = try readHooks(repo.appendingPathComponent(".agents/hooks.json"))
        let stop = hooks["Stop"] as! [[String: Any]]
        #expect(stop.count == 1)
        #expect((stop.first!["hooks"] as! [[String: Any]]).first!["command"] as? String == "committed")
    }

    @Test func gitExcludesUntrackedConfig() throws {
        let repo = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: repo) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", repo.path, "init"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()

        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: repo.path, sessionID: UUID(), crowPath: "/bin/crow")

        let exclude = try String(contentsOfFile: repo.appendingPathComponent(".git/info/exclude").path, encoding: .utf8)
        #expect(exclude.contains(".agents/hooks.json"))
    }
}
