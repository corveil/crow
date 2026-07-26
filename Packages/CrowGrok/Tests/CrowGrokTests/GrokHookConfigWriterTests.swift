import Foundation
import Testing
@testable import CrowGrok

@Suite("GrokHookConfigWriter")
struct GrokHookConfigWriterTests {

    private func makeTempWorktree() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Document shape

    @Test func generateDocumentBakesInSessionAndEvents() throws {
        let sid = UUID()
        let doc = GrokHookConfigWriter.generateDocument(sessionID: sid, crowPath: "/usr/local/bin/crow")
        let hooks = try #require(doc["hooks"] as? [String: Any])

        // Every registered event is present, Claude-compatible schema.
        for event in GrokHookConfigWriter.allEvents {
            let groups = try #require(hooks[event] as? [[String: Any]])
            let inner = try #require((groups.first?["hooks"]) as? [[String: Any]])
            let entry = try #require(inner.first)
            #expect(entry["type"] as? String == "command")
            let command = try #require(entry["command"] as? String)
            #expect(command == "/usr/local/bin/crow hook-event --session \(sid.uuidString) --event \(event)")
            #expect(entry["timeout"] as? Int == 5)
            // No matcher key (match-all).
            #expect(groups.first?["matcher"] == nil)
            // Sync-only for now (Grok async delivery unverified).
            #expect(entry["async"] == nil)
        }
    }

    @Test func registersTheVerifiedGrokEventSet() {
        // The ticket's core loop needs a real Stop + Notification; these are the
        // events GrokSignalSource handles.
        let events = Set(GrokHookConfigWriter.allEvents)
        for expected in ["SessionStart", "SessionEnd", "Stop", "StopFailure",
                         "Notification", "PreToolUse", "PostToolUse", "UserPromptSubmit"] {
            #expect(events.contains(expected))
        }
    }

    // MARK: - Write / remove

    @Test func writeHookConfigWritesPerWorktreeSessionScopedFile() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let sid = UUID()
        try GrokHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")

        // Lands in `<worktree>/.grok/hooks/crow.json`.
        let path = worktree.appendingPathComponent(".grok/hooks/crow.json")
        #expect(FileManager.default.fileExists(atPath: path.path))

        let data = try #require(FileManager.default.contents(atPath: path.path))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let entry = try #require(((stop.first?["hooks"]) as? [[String: Any]])?.first)
        // The session UUID is baked into the command (exact per-session scope).
        #expect((entry["command"] as? String)?.contains("--session \(sid.uuidString)") == true)
    }

    @Test func removeHookConfigDeletesFileAndPrunesEmptyDirs() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let writer = GrokHookConfigWriter()
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: worktree.path)

        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".grok/hooks/crow.json").path))
        // Crow-created empty dirs are pruned.
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".grok").path))
        // Removing again is a safe no-op.
        writer.removeHookConfig(worktreePath: worktree.path)
    }

    @Test func removeHookConfigPreservesUserHookFiles() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        // A user's own hook file sits alongside ours in `.grok/hooks/`.
        let hooksDir = worktree.appendingPathComponent(".grok/hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let userHook = hooksDir.appendingPathComponent("my-hook.json")
        try "{\"hooks\":{}}".write(to: userHook, atomically: true, encoding: .utf8)

        let writer = GrokHookConfigWriter()
        try writer.writeHookConfig(worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        writer.removeHookConfig(worktreePath: worktree.path)

        // Ours is gone; theirs (and the non-empty dir) survive.
        #expect(!FileManager.default.fileExists(
            atPath: hooksDir.appendingPathComponent("crow.json").path))
        #expect(FileManager.default.fileExists(atPath: userHook.path))
    }
}
