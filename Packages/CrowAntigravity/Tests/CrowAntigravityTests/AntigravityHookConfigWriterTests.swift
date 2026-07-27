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

    /// The whole hooks.json as a named-group map (root is the groups, NOT a
    /// top-level `hooks` wrapper).
    private func readRoot(_ path: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
    }

    /// Crow's `"crow"` group (event → config array).
    private func crowGroup(_ path: URL) throws -> [String: Any] {
        try readRoot(path)["crow"] as! [String: Any]
    }

    /// The handler object for a *direct* event (invocation/Stop) — no matcher.
    private func directHandler(_ group: [String: Any], _ event: String) -> [String: Any] {
        (group[event] as! [[String: Any]]).first!
    }

    /// The handler object for a *tool* event (matcher + hooks[]).
    private func toolHandler(_ group: [String: Any], _ event: String) -> [String: Any] {
        let wrap = (group[event] as! [[String: Any]]).first!
        return (wrap["hooks"] as! [[String: Any]]).first!
    }

    // MARK: - Named-group schema (Antigravity's, not Claude's)

    @Test func writesNamedCrowGroupNotClaudeHooksWrapper() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let sid = UUID()
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/opt/homebrew/bin/crow")

        let root = try readRoot(worktree.appendingPathComponent(".agents/hooks.json"))
        // Top-level is the named group `crow` — NOT a Claude-style `hooks` key,
        // and no `version` scaffold.
        #expect(root["crow"] != nil)
        #expect(root["hooks"] == nil)
        #expect(root["version"] == nil)

        let group = root["crow"] as! [String: Any]
        // Mirrors Antigravity's vibe-island plugin: no PreToolUse.
        #expect(Set(group.keys) == ["PreInvocation", "PostInvocation", "PostToolUse", "Stop"])
        #expect(group["PreToolUse"] == nil)
    }

    @Test func toolEventUsesMatcherAndHooksWrapper() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        let group = try crowGroup(worktree.appendingPathComponent(".agents/hooks.json"))

        // PostToolUse: `[{matcher:"*", hooks:[handler]}]`.
        let wrap = (group["PostToolUse"] as! [[String: Any]]).first!
        #expect(wrap["matcher"] as? String == "*")
        #expect(wrap["hooks"] != nil)
    }

    @Test func directEventsListHandlersUnderEventKey() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        let group = try crowGroup(worktree.appendingPathComponent(".agents/hooks.json"))

        // Invocation/Stop handlers sit directly under the event key — no matcher,
        // no `hooks` wrapper.
        for event in ["PreInvocation", "PostInvocation", "Stop"] {
            let h = directHandler(group, event)
            #expect(h["type"] as? String == "command")
            #expect(h["command"] != nil)
            #expect(h["matcher"] == nil)
            #expect(h["hooks"] == nil)
        }
    }

    @Test func noAsyncFieldAnywhere() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        // `async` is not part of Antigravity's handler schema — a stray field
        // risks a parse failure.
        let raw = try String(
            contentsOf: worktree.appendingPathComponent(".agents/hooks.json"), encoding: .utf8)
        #expect(raw.contains("async") == false)
    }

    // MARK: - Command wrapper (session UUID + stdout verdict + always-exit-0)

    @Test func commandForwardsThenEmitsStdoutVerdict() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let sid = UUID()
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/opt/homebrew/bin/crow")
        let group = try crowGroup(worktree.appendingPathComponent(".agents/hooks.json"))

        // Stop command: session UUID + --agent antigravity, hook-event output
        // suppressed, then an empty-object verdict emitted so the hook never
        // blocks / loops the agent.
        let stopCmd = directHandler(group, "Stop")["command"] as! String
        #expect(stopCmd.contains("hook-event --session \(sid.uuidString) --agent antigravity --event Stop"))
        #expect(stopCmd.contains(">/dev/null 2>&1; printf '{}'"))

        // PostToolUse command carries the same wrapper shape.
        let toolCmd = toolHandler(group, "PostToolUse")["command"] as! String
        #expect(toolCmd.contains("--event PostToolUse >/dev/null 2>&1; printf '{}'"))
    }

    @Test func crowPathWithSpacesIsShellQuoted() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let spaced = "/Users/x/My Projects/.claude/bin/crow"
        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: spaced)
        let group = try crowGroup(worktree.appendingPathComponent(".agents/hooks.json"))
        #expect((directHandler(group, "Stop")["command"] as! String).hasPrefix("'\(spaced)' hook-event "))
    }

    // MARK: - User-group preservation + idempotency

    @Test func preservesOtherNamedGroupsAndIsIdempotent() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        // Seed a user's own named group alongside where Crow's will go.
        let agentsDir = worktree.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "my-linter": ["PostToolUse": [["matcher": "run_command", "hooks": [["command": "lint.sh"]]]]],
        ]
        try JSONSerialization.data(withJSONObject: seed)
            .write(to: agentsDir.appendingPathComponent("hooks.json"))

        let writer = AntigravityHookConfigWriter()
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        let root = try readRoot(worktree.appendingPathComponent(".agents/hooks.json"))
        // The user's group survives untouched; Crow's group is present exactly once.
        #expect(root["my-linter"] != nil)
        #expect(root["crow"] != nil)
        let linter = root["my-linter"] as! [String: Any]
        let wrap = (linter["PostToolUse"] as! [[String: Any]]).first!
        #expect(wrap["matcher"] as? String == "run_command")
    }

    // MARK: - remove

    @Test func removeStripsCrowGroupButKeepsUserGroups() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let agentsDir = worktree.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let seed: [String: Any] = [
            "my-linter": ["PreInvocation": [["command": "lint.sh"]]],
        ]
        try JSONSerialization.data(withJSONObject: seed)
            .write(to: agentsDir.appendingPathComponent("hooks.json"))

        let writer = AntigravityHookConfigWriter()
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: worktree.path)

        let root = try readRoot(worktree.appendingPathComponent(".agents/hooks.json"))
        #expect(root["crow"] == nil)
        #expect(root["my-linter"] != nil)
    }

    @Test func removeDeletesFileWhenOnlyCrowGroupExisted() throws {
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

    @Test func removeManagedGlobalConfigStripsOnlyCrowGroup() throws {
        let home = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let seed: [String: Any] = [
            "crow": ["Stop": [["type": "command", "command": "old-crow"]]],
            "user-group": ["Stop": [["type": "command", "command": "user-hook"]]],
        ]
        let path = home.appendingPathComponent("hooks.json")
        try JSONSerialization.data(withJSONObject: seed).write(to: path)

        AntigravityHookConfigWriter.removeManagedGlobalConfig(geminiConfigHome: home.path)

        let root = try readRoot(path)
        #expect(root["crow"] == nil)
        #expect(root["user-group"] != nil)
    }

    // MARK: - Unparseable / torn-file guard (regression)

    @Test func writeHookConfigLeavesUnparseableFileUntouched() throws {
        let worktree = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: worktree) }
        AntigravityHookConfigWriter.resetTrackedCacheForTesting()
        let agentsDir = worktree.appendingPathComponent(".agents")
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        let garbage = "{ \"crow\": {  <-- oops not json"
        let hooksPath = agentsDir.appendingPathComponent("hooks.json")
        try garbage.write(to: hooksPath, atomically: true, encoding: .utf8)

        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        #expect(try String(contentsOf: hooksPath, encoding: .utf8) == garbage)
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
        let committed: [String: Any] = ["user-group": ["Stop": [["command": "committed"]]]]
        try JSONSerialization.data(withJSONObject: committed)
            .write(to: agentsDir.appendingPathComponent("hooks.json"))
        git(["add", ".agents/hooks.json"])
        git(["commit", "-m", "seed"])

        try AntigravityHookConfigWriter().writeHookConfig(
            worktreePath: repo.path, sessionID: UUID(), crowPath: "/bin/crow")

        // The committed file is untouched — no `crow` group injected.
        let root = try readRoot(repo.appendingPathComponent(".agents/hooks.json"))
        #expect(root["crow"] == nil)
        #expect(root["user-group"] != nil)
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

        let exclude = try String(
            contentsOfFile: repo.appendingPathComponent(".git/info/exclude").path, encoding: .utf8)
        #expect(exclude.contains(".agents/hooks.json"))
    }
}
