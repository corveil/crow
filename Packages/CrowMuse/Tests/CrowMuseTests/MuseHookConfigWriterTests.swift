import Foundation
import Testing
@testable import CrowMuse

@Suite("MuseHookConfigWriter")
struct MuseHookConfigWriterTests {

    private func makeTempWorktree() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        MuseHookConfigWriter.resetTrackedCacheForTesting()
        return url
    }

    @Test func generateDocumentBakesInSessionAndEvents() throws {
        let sid = UUID()
        let doc = MuseHookConfigWriter.generateDocument(sessionID: sid, crowPath: "/usr/local/bin/crow")
        let hooks = try #require(doc["hooks"] as? [String: Any])

        for event in MuseHookConfigWriter.allEvents {
            let groups = try #require(hooks[event] as? [[String: Any]])
            let inner = try #require((groups.first?["hooks"]) as? [[String: Any]])
            let entry = try #require(inner.first)
            #expect(entry["type"] as? String == "command")
            let command = try #require(entry["command"] as? String)
            #expect(command == "'/usr/local/bin/crow' hook-event --session \(sid.uuidString) --event \(event)")
            #expect(entry["timeout"] as? Int == 5)
            #expect(entry["async"] == nil)
        }
        #expect(hooks["PreToolUse"] == nil)
    }

    @Test func shellQuotesSpacedCrowPath() throws {
        let doc = MuseHookConfigWriter.generateDocument(
            sessionID: UUID(), crowPath: "/Users/me/My Apps/crow")
        let hooks = try #require(doc["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let entry = try #require(((stop.first?["hooks"]) as? [[String: Any]])?.first)
        let command = try #require(entry["command"] as? String)
        #expect(command.hasPrefix("'/Users/me/My Apps/crow' hook-event"))
    }

    @Test func registersTheDocumentedStateEventsAndSkipsPreToolUse() {
        let events = Set(MuseHookConfigWriter.allEvents)
        for expected in ["SessionStart", "UserPromptSubmit", "PostToolUse",
                         "PermissionRequest", "Stop"] {
            #expect(events.contains(expected))
        }
        #expect(!events.contains("PreToolUse"))
    }

    @Test func writeHookConfigWritesPerWorktreeSessionScopedFile() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let sid = UUID()
        try MuseHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: sid, crowPath: "/bin/crow")

        let path = worktree.appendingPathComponent(".muse/hooks.json")
        #expect(FileManager.default.fileExists(atPath: path.path))

        let data = try #require(FileManager.default.contents(atPath: path.path))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(MuseHookConfigWriter.isCrowOwned(root))
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let entry = try #require(((stop.first?["hooks"]) as? [[String: Any]])?.first)
        #expect((entry["command"] as? String)?.contains(sid.uuidString) == true)
    }

    @Test func writeDoesNotClobberUserHooks() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let museDir = worktree.appendingPathComponent(".muse")
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)
        let path = museDir.appendingPathComponent("hooks.json")
        try "{\"hooks\":[]}".write(to: path, atomically: true, encoding: .utf8)

        try MuseHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")

        let body = try String(contentsOf: path, encoding: .utf8)
        #expect(body == "{\"hooks\":[]}")
    }

    @Test func removeHookConfigDeletesCrowOwnedFile() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        try MuseHookConfigWriter().writeHookConfig(
            worktreePath: worktree.path, sessionID: UUID(), crowPath: "/bin/crow")
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".muse/hooks.json").path))

        MuseHookConfigWriter().removeHookConfig(worktreePath: worktree.path)
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".muse/hooks.json").path))
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent(".muse").path))
    }

    @Test func removeHookConfigLeavesUserFile() throws {
        let worktree = try makeTempWorktree()
        defer { try? FileManager.default.removeItem(at: worktree) }

        let museDir = worktree.appendingPathComponent(".muse")
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)
        let path = museDir.appendingPathComponent("hooks.json")
        try "{\"hooks\":[]}".write(to: path, atomically: true, encoding: .utf8)

        MuseHookConfigWriter().removeHookConfig(worktreePath: worktree.path)
        #expect(FileManager.default.fileExists(atPath: path.path))
    }

    @Test func isCrowOwnedRejectsEmptyAndForeign() {
        #expect(!MuseHookConfigWriter.isCrowOwned([:]))
        #expect(!MuseHookConfigWriter.isCrowOwned(["hooks": [String: Any]()]))
        #expect(!MuseHookConfigWriter.isCrowOwned(["hooks": ["Stop": "nope"]]))
    }
}
