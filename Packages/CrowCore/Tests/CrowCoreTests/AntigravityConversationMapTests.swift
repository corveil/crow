import Foundation
import Testing
@testable import CrowCore

@Suite struct AntigravityHomeTests {
    @Test func resolvesUnderGeminiHome() {
        let p = AntigravityHome.path(environment: [:])
        #expect(p.hasSuffix("/.gemini/antigravity-cli"))
    }

    @Test func honorsGeminiHomeOverride() {
        let p = AntigravityHome.path(environment: ["GEMINI_HOME": "/custom/gem"])
        #expect(p == "/custom/gem/antigravity-cli")
    }

    @Test func brainDirAndTranscriptPathDerivation() {
        let brain = AntigravityHome.brainDir(environment: ["GEMINI_HOME": "/g"])
        #expect(brain == "/g/antigravity-cli/brain")
        let t = AntigravityHome.transcriptPath(conversationID: "abc", brainDir: brain)
        #expect(t == "/g/antigravity-cli/brain/abc/.system_generated/logs/transcript_full.jsonl")
    }

    @Test func conversationIDInvertsTranscriptPath() {
        let t = AntigravityHome.transcriptPath(conversationID: "conv-42", brainDir: "/g/brain")
        let id = AntigravityHome.conversationID(forTranscript: URL(fileURLWithPath: t))
        #expect(id == "conv-42")
    }
}

@Suite struct AntigravityConversationMapTests {
    /// A temp dir + a map-file URL under it; cleans up and resets the static cache.
    private func makeTemp() -> (dir: URL, mapURL: URL, cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-map-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mapURL = dir.appendingPathComponent("map.json")
        return (dir, mapURL, {
            AntigravityConversationMap.resetForTesting()
            try? FileManager.default.removeItem(at: dir)
        })
    }

    /// Create a real `transcript_full.jsonl` for a conversation under a brain dir.
    private func writeTranscript(brainDir: URL, conversationID: String, body: String = "{}") throws {
        let path = AntigravityHome.transcriptPath(conversationID: conversationID, brainDir: brainDir.path)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    @Test func recordThenLoadRoundTrip() throws {
        let (_, mapURL, cleanup) = makeTemp()
        defer { cleanup() }

        let wrote = AntigravityConversationMap.record(
            conversationID: "C1", worktreePath: "/dev/ws/repo-1",
            transcriptPath: "/brain/C1/.system_generated/logs/transcript.jsonl",
            now: 100, mapURL: mapURL)
        #expect(wrote)

        let map = AntigravityConversationMap.load(mapURL: mapURL)
        let entry = try #require(map.conversations["C1"])
        #expect(entry.worktreePath == "/dev/ws/repo-1")
        #expect(entry.transcriptPath == "/brain/C1/.system_generated/logs/transcript.jsonl")
        #expect(entry.updatedAt == 100)
    }

    @Test func recordDedupesUnchangedPair() throws {
        let (_, mapURL, cleanup) = makeTemp()
        defer { cleanup() }

        #expect(AntigravityConversationMap.record(
            conversationID: "C1", worktreePath: "/ws/a", now: 1, mapURL: mapURL))
        // Same conversation → same worktree, no transcript change: no rewrite.
        #expect(!AntigravityConversationMap.record(
            conversationID: "C1", worktreePath: "/ws/a", now: 2, mapURL: mapURL))
        // A new worktree for the same conversation *is* a change.
        #expect(AntigravityConversationMap.record(
            conversationID: "C1", worktreePath: "/ws/b", now: 3, mapURL: mapURL))
        #expect(AntigravityConversationMap.load(mapURL: mapURL).conversations["C1"]?.worktreePath == "/ws/b")
    }

    @Test func recordRejectsBlankInput() {
        let (_, mapURL, cleanup) = makeTemp()
        defer { cleanup() }
        #expect(!AntigravityConversationMap.record(conversationID: "", worktreePath: "/ws", mapURL: mapURL))
        #expect(!AntigravityConversationMap.record(conversationID: "C", worktreePath: "  ", mapURL: mapURL))
        #expect(AntigravityConversationMap.load(mapURL: mapURL).conversations.isEmpty)
    }

    @Test func transcriptsFilterByWorktreeAndExistence() throws {
        let (dir, _, cleanup) = makeTemp()
        defer { cleanup() }
        let brain = dir.appendingPathComponent("brain", isDirectory: true)
        try writeTranscript(brainDir: brain, conversationID: "A")   // worktree X
        try writeTranscript(brainDir: brain, conversationID: "B")   // worktree Y
        // "C" is mapped but its file is missing → dropped, never guessed.

        let map = AntigravityConversationMap(conversations: [
            "A": .init(worktreePath: "/ws/x"),
            "B": .init(worktreePath: "/ws/y"),
            "C": .init(worktreePath: "/ws/x"),
        ])
        let forX = map.transcripts(forWorktreePath: "/ws/x", brainDir: brain.path)
        #expect(forX == [AntigravityHome.transcriptPath(conversationID: "A", brainDir: brain.path)])

        let forY = map.transcripts(forWorktreePath: "/ws/y", brainDir: brain.path)
        #expect(forY.count == 1)
        #expect(forY[0].hasSuffix("/B/.system_generated/logs/transcript_full.jsonl"))

        // A worktree with no mapped conversation → nothing.
        #expect(map.transcripts(forWorktreePath: "/ws/z", brainDir: brain.path).isEmpty)
    }

    @Test func preferredTranscriptRedirectsToFullBesideARecordedTruncatedFile() {
        // A recorded `transcript.jsonl` hint resolves to the durable
        // `transcript_full.jsonl` in the same directory.
        let entry = AntigravityConversationMap.Entry(
            worktreePath: "/ws",
            transcriptPath: "/brain/C/.system_generated/logs/transcript.jsonl")
        let path = AntigravityConversationMap.preferredTranscript(
            entry: entry, conversationID: "C", brainDir: "/other/brain")
        #expect(path == "/brain/C/.system_generated/logs/transcript_full.jsonl")
    }

    @Test func preferredTranscriptDerivesFromConversationWhenNoHint() {
        let entry = AntigravityConversationMap.Entry(worktreePath: "/ws")
        let path = AntigravityConversationMap.preferredTranscript(
            entry: entry, conversationID: "C", brainDir: "/b")
        #expect(path == "/b/C/.system_generated/logs/transcript_full.jsonl")
    }
}
