import Foundation
import Testing
@testable import CrowCore

@Suite struct TranscriptHeadReaderTests {
    /// A realistic Claude transcript head: the first lines are control events
    /// with no cwd, and the message events carry cwd/gitBranch/timestamp.
    private let sample = """
    {"type":"mode","sessionId":"dfb5e99e-3195-4342-89fd-4025f1b7f09e"}
    {"type":"permission-mode","sessionId":"dfb5e99e-3195-4342-89fd-4025f1b7f09e"}
    {"type":"user","sessionId":"dfb5e99e-3195-4342-89fd-4025f1b7f09e","cwd":"/Users/j/Dev2/RadiusMethod/crow-1075-session-backfill","gitBranch":"feature/crow-1075-session-backfill","version":"2.1.236","timestamp":"2026-08-19T23:28:12.852Z"}
    """

    @Test func parsesCwdBranchSessionFromHead() {
        let head = TranscriptHeadReader.parse(sample)
        #expect(head.sessionID == "dfb5e99e-3195-4342-89fd-4025f1b7f09e")
        #expect(head.cwd == "/Users/j/Dev2/RadiusMethod/crow-1075-session-backfill")
        #expect(head.gitBranch == "feature/crow-1075-session-backfill")
        #expect(head.firstTimestamp == "2026-08-19T23:28:12.852Z")
    }

    @Test func ignoresNonJSONAndEmptyLines() {
        let body = "\nnot json\n{\"cwd\":\"/x\",\"sessionId\":\"s\"}\n"
        let head = TranscriptHeadReader.parse(body)
        #expect(head.cwd == "/x")
        #expect(head.sessionID == "s")
        #expect(head.gitBranch == nil)
    }

    @Test func readsHeadFromDiskAndStopsEarly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("thr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        // Head fields in the first lines, then a large tail that must not be read
        // in full (the reader stops once the head is complete).
        var body = sample + "\n"
        body += String(repeating: "{\"type\":\"noise\"}\n", count: 100_000)
        try body.write(to: file, atomically: true, encoding: .utf8)

        let head = TranscriptHeadReader.read(file)
        #expect(head.cwd == "/Users/j/Dev2/RadiusMethod/crow-1075-session-backfill")
        #expect(head.gitBranch == "feature/crow-1075-session-backfill")
    }

    @Test func unreadableFileYieldsEmptyHead() {
        let head = TranscriptHeadReader.read(URL(fileURLWithPath: "/nope/does/not/exist.jsonl"))
        #expect(head == TranscriptHead())
    }

    // MARK: Codex rollout shape (CROW-1089)

    /// A Codex rollout's first line records cwd/id/timestamp under a nested
    /// `payload`, and no git branch. One reader must handle both shapes.
    private let codexSample = """
    {"timestamp":"2026-06-01T21:33:36.314Z","type":"session_meta","payload":{"id":"019e851b-213a-7cb3-8f08-1cb867fb118a","timestamp":"2026-06-01T21:33:28.251Z","cwd":"/Users/j/Dev2/RadiusMethod/corveil-ecs","originator":"codex-tui","git":{}}}
    {"timestamp":"2026-06-01T21:33:36.315Z","type":"event_msg","payload":{"type":"task_started"}}
    """

    @Test func parsesCodexPayloadCwdIdTimestamp() {
        let head = TranscriptHeadReader.parse(codexSample)
        #expect(head.sessionID == "019e851b-213a-7cb3-8f08-1cb867fb118a")
        #expect(head.cwd == "/Users/j/Dev2/RadiusMethod/corveil-ecs")
        #expect(head.firstTimestamp == "2026-06-01T21:33:36.314Z") // top-level wins
        #expect(head.gitBranch == nil) // Codex records no branch
    }

    @Test func agentLogCwdReaderReadsClaudeAndCodexHeads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cwdreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let claude = dir.appendingPathComponent("claude.jsonl")
        try (sample + "\n").write(to: claude, atomically: true, encoding: .utf8)
        #expect(AgentLogCwdReader.read(claude) == "/Users/j/Dev2/RadiusMethod/crow-1075-session-backfill")

        // Codex cwd on line 1 (nested), then a large tail that must NOT be read —
        // AgentLogCwdReader stops the instant cwd is found.
        let codex = dir.appendingPathComponent("rollout.jsonl")
        var body = codexSample + "\n"
        body += String(repeating: "{\"type\":\"noise\",\"payload\":{}}\n", count: 100_000)
        try body.write(to: codex, atomically: true, encoding: .utf8)
        #expect(AgentLogCwdReader.read(codex) == "/Users/j/Dev2/RadiusMethod/corveil-ecs")

        // A file whose head carries no cwd yields nil (never guessed).
        let noCwd = dir.appendingPathComponent("nocwd.jsonl")
        try "{\"type\":\"x\"}\n".write(to: noCwd, atomically: true, encoding: .utf8)
        #expect(AgentLogCwdReader.read(noCwd) == nil)
        #expect(AgentLogCwdReader.read(URL(fileURLWithPath: "/nope/x.jsonl")) == nil)
    }
}
