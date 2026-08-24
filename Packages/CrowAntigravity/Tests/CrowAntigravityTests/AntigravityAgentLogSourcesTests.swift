import Foundation
import Testing
import CrowCore
@testable import CrowAntigravity

/// `AntigravityAgent.logSources` resolves through the runtime conversation→worktree
/// map (CROW-1107): it returns exactly the transcripts the map attributes to the
/// worktree, and nothing when the map has no entry — never a guess.
@Suite struct AntigravityAgentLogSourcesTests {
    private func makeTemp() -> (dir: URL, mapURL: URL, brain: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-agent-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir,
                dir.appendingPathComponent("map.json"),
                dir.appendingPathComponent("brain", isDirectory: true),
                { try? FileManager.default.removeItem(at: dir) })
    }

    private func writeTranscript(brain: URL, conversationID: String) throws {
        let path = AntigravityHome.transcriptPath(conversationID: conversationID, brainDir: brain.path)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "{}".write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func mapHitReturnsAFileSource() throws {
        let (_, mapURL, brain, cleanup) = makeTemp()
        defer { cleanup() }
        try writeTranscript(brain: brain, conversationID: "C1")
        #expect(AntigravityConversationMap.record(
            conversationID: "C1", worktreePath: "/ws/repo-1", mapURL: mapURL))

        let agent = AntigravityAgent(conversationMapURL: mapURL, brainDir: brain.path)
        let sources = agent.logSources(worktreePath: "/ws/repo-1", harnessSessionID: nil)
        #expect(sources.count == 1)
        #expect(sources[0].selector == .file)
        #expect(sources[0].format == .jsonl)
        #expect(sources[0].path
            == AntigravityHome.transcriptPath(conversationID: "C1", brainDir: brain.path))
    }

    @Test func emptyMapReturnsNothing() {
        let (_, mapURL, brain, cleanup) = makeTemp()
        defer { cleanup() }
        let agent = AntigravityAgent(conversationMapURL: mapURL, brainDir: brain.path)
        #expect(agent.logSources(worktreePath: "/ws/repo-1", harnessSessionID: nil).isEmpty)
    }

    @Test func entryForADifferentWorktreeReturnsNothing() throws {
        let (_, mapURL, brain, cleanup) = makeTemp()
        defer { cleanup() }
        try writeTranscript(brain: brain, conversationID: "C1")
        #expect(AntigravityConversationMap.record(
            conversationID: "C1", worktreePath: "/ws/other", mapURL: mapURL))

        let agent = AntigravityAgent(conversationMapURL: mapURL, brainDir: brain.path)
        // The map attributes C1 to /ws/other, so a different worktree gets nothing —
        // dropped, never guessed.
        #expect(agent.logSources(worktreePath: "/ws/repo-1", harnessSessionID: nil).isEmpty)
    }
}
