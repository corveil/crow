import Foundation
import Testing
@testable import CrowCore

/// Context size + cache state from a transcript tail (CROW-1493). Fixture lines are
/// hand-written to the shapes Claude Code 2.1.330 and Codex 0.16x persist, never read
/// from a live `~/.claude` (ADR 0012).
@Suite struct ContextSnapshotTests {
    static func iso(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)!
    }

    static let claude = #"""
    {"type":"user","isSidechain":false,"timestamp":"2026-11-20T10:00:00.000Z","message":{"role":"user","content":"go"}}
    {"type":"assistant","isSidechain":false,"timestamp":"2026-11-20T10:00:05.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":2,"cache_read_input_tokens":300000,"cache_creation_input_tokens":2000,"cache_creation":{"ephemeral_1h_input_tokens":2000,"ephemeral_5m_input_tokens":0},"output_tokens":10}}}
    {"type":"assistant","isSidechain":true,"timestamp":"2026-11-20T10:00:09.000Z","message":{"model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":9,"cache_read_input_tokens":9,"cache_creation":{"ephemeral_5m_input_tokens":9}}}}
    {"type":"user","isSidechain":false,"timestamp":"2026-11-20T10:00:10.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"the word usage appears in tool output"}]}}
    {"type":"assistant","isSidechain":false,"timestamp":"2026-11-20T10:00:20.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":4,"cache_read_input_tokens":302000,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"output_tokens":9}}}
    {"type":"assistant","isSidechain":false,"timestamp":"2026-11-20T10:00:21.000Z","message":{"model":"<synthetic>","content":[],"usage":{"input_tokens":0}}}
    """#

    @Test func claudeLatestMainCallWithTheLastCacheLifetimeSeen() throws {
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(Self.claude.utf8), format: .claude))
        #expect(snap.tokens == 302_004)
        #expect(snap.model == "claude-opus-5-5")
        #expect(snap.maxTokens == 1_000_000)
        #expect(snap.lastRequestAt == Self.iso("2026-11-20T10:00:20.000Z"))
        // The pure cache read wrote no entry; the 1h write before it decides.
        // The sidechain's 5m write is a different conversation.
        #expect(snap.cacheTTL == 3_600)
        #expect(snap.compactedAt == nil)
    }

    @Test func cacheExpiryAgesFromTheLastCall() throws {
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(Self.claude.utf8), format: .claude))
        let last = Self.iso("2026-11-20T10:00:20.000Z")
        #expect(snap.cacheLikelyExpired(now: last.addingTimeInterval(3_599)) == false)
        #expect(snap.cacheLikelyExpired(now: last.addingTimeInterval(3_600)) == true)
        #expect(snap.idleSeconds(now: last.addingTimeInterval(90)) == 90)
        // A clock behind the transcript is idle 0, not negative.
        #expect(snap.idleSeconds(now: last.addingTimeInterval(-5)) == 0)
    }

    @Test func fiveMinuteCacheIsRecognized() throws {
        let line = #"{"type":"assistant","timestamp":"2026-11-20T10:00:00Z","message":{"model":"claude-sonnet-5-5","content":[],"usage":{"input_tokens":1,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":50}}}}"#
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(line.utf8), format: .claude))
        #expect(snap.cacheTTL == 300)
        #expect(snap.tokens == 51)
        // Second-precision timestamps parse too.
        #expect(snap.lastRequestAt == ISO8601DateFormatter().date(from: "2026-11-20T10:00:00Z"))
    }

    @Test func unknownLifetimeLeavesExpiryUnknown() throws {
        let line = #"{"type":"assistant","timestamp":"2026-11-20T10:00:00.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":1,"cache_read_input_tokens":9}}}"#
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(line.utf8), format: .claude))
        #expect(snap.cacheTTL == nil)
        #expect(snap.cacheLikelyExpired(now: Date.distantFuture) == nil)
    }

    @Test func compactionAfterTheLastCallReportsItsResult() throws {
        let tail = Self.claude + "\n" + #"""
        {"isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","compactMetadata":{"trigger":"manual","preTokens":302004,"postTokens":10314},"timestamp":"2026-11-20T10:50:00.000Z"}
        {"type":"user","isSidechain":false,"isCompactSummary":true,"timestamp":"2026-11-20T10:50:00.100Z","message":{"role":"user","content":"summary"}}
        """#
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(tail.utf8), format: .claude))
        #expect(snap.tokens == 10_314)
        #expect(snap.compactedAt == Self.iso("2026-11-20T10:50:00.000Z"))
        #expect(snap.lastRequestAt == Self.iso("2026-11-20T10:50:00.000Z"))
        #expect(snap.model == "claude-opus-5-5")
    }

    @Test func aCallAfterTheCompactionClearsIt() throws {
        let tail = Self.claude + "\n" + #"""
        {"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":10314},"timestamp":"2026-11-20T10:50:00.000Z"}
        {"type":"assistant","timestamp":"2026-11-20T11:30:00.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":3,"cache_creation_input_tokens":12000,"cache_creation":{"ephemeral_1h_input_tokens":12000}}}}
        """#
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(tail.utf8), format: .claude))
        #expect(snap.tokens == 12_003)
        #expect(snap.compactedAt == nil)
    }

    @Test func compactionWithoutASizeReportsUnknownTokens() throws {
        let tail = Self.claude + "\n" + #"{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-20T10:50:00.000Z"}"#
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(tail.utf8), format: .claude))
        #expect(snap.tokens == nil)
        #expect(snap.compactedAt != nil)
    }

    @Test func noUsageIsNil() {
        let tail = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
        #expect(ContextSnapshotReader.snapshot(tail: Data(tail.utf8), format: .claude) == nil)
    }

    @Test func aMidLineStartDropsTheFirstFragment() throws {
        // The fragment would decode as a complete record if it were kept.
        let fragment = #"{"type":"assistant","timestamp":"2026-11-20T09:00:00.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":999999}}}"#
        let tail = fragment + "\n" + #"{"type":"user","message":{"content":"x"}}"#
        #expect(ContextSnapshotReader.snapshot(tail: Data(tail.utf8), format: .claude, startsMidLine: true) == nil)
        #expect(ContextSnapshotReader.snapshot(tail: Data(tail.utf8), format: .claude)?.tokens == 999_999)
    }

    @Test func codexTokenCountWithItsWindow() throws {
        let tail = #"""
        {"timestamp":"2026-11-20T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.5-codex"}}
        {"timestamp":"2026-11-20T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":25559,"cached_input_tokens":2432,"output_tokens":13},"model_context_window":258400}}}
        """#
        let snap = try #require(ContextSnapshotReader.snapshot(tail: Data(tail.utf8), format: .codex))
        #expect(snap.tokens == 25_559)
        #expect(snap.model == "gpt-5.5-codex")
        #expect(snap.maxTokens == 258_400)
        #expect(snap.lastRequestAt == Self.iso("2026-11-20T10:00:04.000Z"))
        #expect(snap.cacheTTL == nil)
    }

    @Test func readerWidensTheTailUntilItFindsUsage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.jsonl")
        let usage = #"{"type":"assistant","timestamp":"2026-11-20T10:00:00.000Z","message":{"model":"claude-opus-5-5","content":[],"usage":{"input_tokens":42}}}"#
        let filler = String(repeating: #"{"type":"user","message":{"content":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}"# + "\n", count: 200)
        try Data((usage + "\n" + filler).utf8).write(to: file)
        let snap = try ContextSnapshotReader.read(
            path: file.path, format: .claude, initialTailBytes: 256, maxTailBytes: 64 * 1_024)
        #expect(snap?.tokens == 42)
        // A ceiling below the usage line gives up rather than reading the whole file.
        let capped = try ContextSnapshotReader.read(
            path: file.path, format: .claude, initialTailBytes: 256, maxTailBytes: 1_024)
        #expect(capped == nil)
    }
}

/// `ContextCompactionSettings` decode tolerance and clamps (CROW-1493).
@Suite struct ContextCompactionSettingsTests {
    @Test func missingBlockDecodesToOffWithDefaults() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.contextCompaction == ContextCompactionSettings())
        #expect(config.contextCompaction.autoCompact == false)
        #expect(config.contextCompaction.minContextTokens == 200_000)
        #expect(config.contextCompaction.idleMinutes == 50)
    }

    @Test func partialBlockKeepsTheOtherDefaults() throws {
        let json = #"{"contextCompaction":{"autoCompact":true}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.contextCompaction.autoCompact)
        #expect(config.contextCompaction.idleMinutes == 50)
    }

    @Test func roundTrips() throws {
        var config = AppConfig()
        config.contextCompaction = ContextCompactionSettings(autoCompact: true, minContextTokens: 300_000, idleMinutes: 40)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded.contextCompaction == config.contextCompaction)
    }

    @Test func outOfRangeValuesAreClampedWhenRead() {
        let low = ContextCompactionSettings(minContextTokens: 5, idleMinutes: 0)
        #expect(low.effectiveMinContextTokens == 10_000)
        #expect(low.effectiveIdleSeconds == 60)
        let high = ContextCompactionSettings(minContextTokens: .max, idleMinutes: 99_999)
        #expect(high.effectiveMinContextTokens == 10_000_000)
        #expect(high.effectiveIdleSeconds == 1_440 * 60)
    }
}

/// Crow-requested compactions are excused from the efficiency grade (CROW-1493).
@Suite @MainActor struct CrowCompactionRequestTests {
    @Test func aPostCompactInsideTheWindowIsConsumedOnce() {
        let state = SessionHookState()
        let sent = Date()
        state.crowCompactionRequestedAt = sent
        #expect(state.consumeCrowCompactionRequest(at: sent.addingTimeInterval(60)))
        // The operator's next compaction counts.
        #expect(!state.consumeCrowCompactionRequest(at: sent.addingTimeInterval(120)))
    }

    @Test func aStaleRequestDoesNotExcuseALaterCompaction() {
        let state = SessionHookState()
        let sent = Date()
        state.crowCompactionRequestedAt = sent
        #expect(!state.consumeCrowCompactionRequest(at: sent.addingTimeInterval(SessionHookState.crowCompactionWindow + 1)))
        #expect(state.crowCompactionRequestedAt == nil)
    }

    @Test func noRequestExcusesNothing() {
        #expect(!SessionHookState().consumeCrowCompactionRequest())
    }
}
