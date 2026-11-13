import Foundation
import Testing
@testable import CrowCore

/// CROW-1449: a transcript's activity time is its newest timestamped entry,
/// not its mtime, which a live agent re-touches while idle.
@Suite struct TranscriptActivityTests {
    private func tempFile(_ name: String = "t.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-activity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private func write(_ lines: [String], to url: URL, mtime: Date = Date()) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// The observed shape: a last real turn, then untimestamped metadata lines
    /// appended later, and an mtime far newer than either.
    @Test func trailingMetadataAndFreshMtimeDontCount() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lastTurn = Date(timeIntervalSince1970: 1_800_000_000.25)
        try write([
            #"{"type":"user","timestamp":"\#(iso(lastTurn.addingTimeInterval(-30)))"}"#,
            #"{"type":"assistant","timestamp":"\#(iso(lastTurn))"}"#,
            #"{"type":"custom-title","customTitle":"x","sessionId":"s"}"#,
            #"{"type":"agent-name","agentName":"y"}"#,
            #"{"type":"permission-mode","permissionMode":"auto"}"#,
        ], to: url, mtime: lastTurn.addingTimeInterval(20 * 3600))
        #expect(TranscriptActivity.lastActivity(url) == lastTurn)
    }

    /// Claude interleaves a few out-of-order lines within a turn; the newest
    /// wins, not the last written.
    @Test func newestNotLastTimestampWins() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write([
            #"{"type":"api-request","timestamp":"2026-11-13T19:16:15.925Z"}"#,
            #"{"type":"user","timestamp":"2026-11-13T19:16:15.908Z"}"#,
        ], to: url)
        #expect(TranscriptActivity.lastActivity(url) == TranscriptActivity.timestamp(
            ofLine: #"{"timestamp":"2026-11-13T19:16:15.925Z"}"#))
    }

    @Test func noTimestampedLineFallsBackToMtime() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try write([#"{"type":"user"}"#, "not json", ""], to: url, mtime: mtime)
        #expect(TranscriptActivity.lastActivity(url) == mtime)
    }

    @Test func missingFileIsNil() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).jsonl")
        #expect(TranscriptActivity.lastActivity(url) == nil)
        #expect(TranscriptActivity.lastActivity([url]) == nil)
    }

    /// Only the entry's own `timestamp` counts; one nested in its content
    /// (a tool result, say) is not when the agent acted.
    @Test func nestedTimestampIsContent() {
        #expect(TranscriptActivity.timestamp(
            ofLine: #"{"type":"user","toolUseResult":{"timestamp":"2030-01-01T00:00:00Z"}}"#) == nil)
        #expect(TranscriptActivity.timestamp(ofLine: "") == nil)
        #expect(TranscriptActivity.timestamp(ofLine: "{\"timestamp\": not json") == nil)
    }

    /// Claude (milliseconds), Codex (milliseconds), Grok (microseconds),
    /// plain seconds, and numeric epochs.
    @Test func timestampShapes() {
        let ms = Date(timeIntervalSince1970: 1_763_061_375.664)
        let parsed = TranscriptActivity.timestamp(ofLine: #"{"timestamp":"2025-11-13T19:16:15.664Z"}"#)
        #expect(parsed.map { abs($0.timeIntervalSince(ms)) < 0.001 } == true)
        let grok = TranscriptActivity.timestamp(ofLine: #"{"timestamp":"2025-11-13T19:16:15.664123Z","prompt":"x"}"#)
        #expect(grok.map { abs($0.timeIntervalSince(ms)) < 0.001 } == true)
        #expect(TranscriptActivity.timestamp(ofLine: #"{"timestamp":"2025-11-13T19:16:15Z"}"#)
            == Date(timeIntervalSince1970: 1_763_061_375))
        #expect(TranscriptActivity.timestamp(ofLine: #"{"timestamp":1763061375}"#)
            == Date(timeIntervalSince1970: 1_763_061_375))
        #expect(TranscriptActivity.timestamp(ofLine: #"{"timestamp":1763061375664}"#)
            .map { abs($0.timeIntervalSince(ms)) < 0.001 } == true)
    }

    /// The scan walks back past more than one chunk of untimestamped tail,
    /// and joins a timestamped line that straddles a chunk boundary.
    @Test func scansBackAcrossChunks() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let big = String(repeating: "x", count: TranscriptActivity.chunkBytes)
        let filler = (0..<3).map { _ in #"{"type":"mode","pad":"\#(big)"}"# }
        try write([
            #"{"type":"user","timestamp":"2026-01-01T00:00:00Z"}"#,
            #"{"type":"assistant","blob":"\#(big)","timestamp":"2026-01-02T00:00:00Z"}"#,
        ] + filler, to: url)
        #expect(TranscriptActivity.lastActivity(url)
            == TranscriptActivity.timestamp(ofLine: #"{"timestamp":"2026-01-02T00:00:00Z"}"#))
    }

    /// An unchanged file is answered from the cache; touching it re-reads,
    /// and still finds the old turn; a new turn moves it.
    @Test func touchKeepsActivityNewTurnMovesIt() throws {
        let url = try tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let lines = [#"{"type":"user","timestamp":"2026-01-01T00:00:00Z"}"#]
        let first = TranscriptActivity.timestamp(ofLine: lines[0])
        try write(lines, to: url, mtime: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(TranscriptActivity.lastActivity(url) == first)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_003_600)], ofItemAtPath: url.path)
        #expect(TranscriptActivity.lastActivity(url) == first)

        let next = #"{"type":"assistant","timestamp":"2026-01-03T00:00:00Z"}"#
        try write(lines + [next], to: url)
        #expect(TranscriptActivity.lastActivity(url) == TranscriptActivity.timestamp(ofLine: next))
    }

    /// Across files the newest activity wins, each file on its own signal.
    @Test func newestAcrossFiles() throws {
        let a = try tempFile("a.jsonl")
        let dir = a.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = dir.appendingPathComponent("b.jsonl")
        try write([#"{"timestamp":"2026-01-01T00:00:00Z"}"#], to: a, mtime: Date(timeIntervalSince1970: 1_900_000_000))
        let bMtime = Date(timeIntervalSince1970: 1_767_400_000)  // 2026-01-03
        try write([#"{"type":"user"}"#], to: b, mtime: bMtime)
        #expect(TranscriptActivity.lastActivity([a, b]) == bMtime)
    }
}
