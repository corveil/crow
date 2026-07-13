import Foundation
import Testing
@testable import CrowCore

// #690 (ADR 0008 follow-up 2): the durable end-of-session analytics record.

@Test func sessionAnalyticsIsEmptySemantics() {
    #expect(SessionAnalytics().isEmpty)
    #expect(SessionAnalytics(totalCost: 0.01).isEmpty == false)
    #expect(SessionAnalytics(promptCount: 1).isEmpty == false)
    #expect(SessionAnalytics(activeTimeSeconds: 2.5).isEmpty == false)
}

@Test func snapshotJSONRoundTrip() throws {
    // Whole-second date: the store's ISO8601 strategy drops sub-second
    // precision, and this test locks in the same encoder configuration.
    let snapshot = SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: Date(timeIntervalSince1970: 1_752_000_000),
        status: .completed,
        analytics: SessionAnalytics(
            totalCost: 1.23, inputTokens: 100, outputTokens: 200,
            cacheReadTokens: 300, cacheCreationTokens: 40,
            activeTimeSeconds: 360, linesAdded: 12, linesRemoved: 3,
            commitCount: 2, promptCount: 7, toolCallCount: 21,
            apiRequestCount: 30, apiErrorCount: 1
        )
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(
        SessionAnalyticsSnapshot.self, from: encoder.encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.analytics.totalTokens == 640)
}

// Locks in the extension-point contract: future fields arrive as optionals on
// the snapshot (compactionCount, once the follow-up-3 example, is now real and
// must decode), and snapshots carrying keys this app version doesn't know must
// still decode — Codable synthesis ignores unknown keys.
@Test func snapshotDecodingIgnoresUnknownFutureKeys() throws {
    let json = """
    {
      "sessionID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "endedAt": "2026-07-13T00:00:00Z",
      "status": "archived",
      "analytics": {
        "totalCost": 0, "inputTokens": 42, "outputTokens": 0,
        "cacheReadTokens": 0, "cacheCreationTokens": 0, "activeTimeSeconds": 0,
        "linesAdded": 0, "linesRemoved": 0, "commitCount": 0,
        "promptCount": 0, "toolCallCount": 0, "apiRequestCount": 0,
        "apiErrorCount": 0
      },
      "compactionCount": 3,
      "someFutureScorecardField": true
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionAnalyticsSnapshot.self, from: Data(json.utf8))
    #expect(decoded.status == .archived)
    #expect(decoded.analytics.inputTokens == 42)
    #expect(decoded.analytics.isEmpty == false)
    #expect(decoded.compactionCount == 3)
    // #692 landed after some snapshots were persisted: the wall-clock field is
    // optional and absent keys decode to nil (open-ended, no bogus duration).
    #expect(decoded.wallClockDurationSeconds == nil)
}

// #691 (ADR 0008 follow-up 3): the per-session compaction counter.

// Completed compactions only: PostCompact increments; PreCompact (and a
// failed/aborted compaction, which never emits PostCompact) does not.
@MainActor
@Test func noteCompactionEventCountsPostCompactOnly() {
    let state = SessionHookState()
    #expect(state.compactionCount == 0)

    state.noteCompactionEvent("PreCompact")
    #expect(state.compactionCount == 0)

    state.noteCompactionEvent("PostCompact")
    state.noteCompactionEvent("PostCompact")
    #expect(state.compactionCount == 2)

    state.noteCompactionEvent("PreCompact")
    state.noteCompactionEvent("Stop")
    state.noteCompactionEvent("StopFailure")
    #expect(state.compactionCount == 2)
}

@Test func snapshotCompactionCountRoundTrips() throws {
    let snapshot = SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: Date(timeIntervalSince1970: 1_752_000_000),
        status: .completed,
        analytics: SessionAnalytics(promptCount: 1),
        compactionCount: 2
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(
        SessionAnalyticsSnapshot.self, from: encoder.encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.compactionCount == 2)
}

// Snapshots persisted before #691 have no compactionCount key — they must
// keep decoding, with the absent field surfacing as nil (treated as 0).
@Test func snapshotWithoutCompactionCountDecodesAsNil() throws {
    let json = """
    {
      "sessionID": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
      "endedAt": "2026-07-13T00:00:00Z",
      "status": "completed",
      "analytics": {
        "totalCost": 0, "inputTokens": 42, "outputTokens": 0,
        "cacheReadTokens": 0, "cacheCreationTokens": 0, "activeTimeSeconds": 0,
        "linesAdded": 0, "linesRemoved": 0, "commitCount": 0,
        "promptCount": 0, "toolCallCount": 0, "apiRequestCount": 0,
        "apiErrorCount": 0
      }
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionAnalyticsSnapshot.self, from: Data(json.utf8))
    #expect(decoded.compactionCount == nil)
    #expect(decoded.compactionCount ?? 0 == 0)
}

// #692 (ADR 0008 follow-up 4): the display-only wall-clock scalar rides the
// snapshot's documented optional-extension point.
@Test func snapshotWallClockRoundTrip() throws {
    let snapshot = SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: Date(timeIntervalSince1970: 1_752_000_000),
        status: .completed,
        analytics: SessionAnalytics(activeTimeSeconds: 300),
        wallClockDurationSeconds: 28_800
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(
        SessionAnalyticsSnapshot.self, from: encoder.encode(snapshot))
    #expect(decoded == snapshot)
    // Role separation (ADR 0008): wall-clock is display-only context; the
    // penalty-normalization clock is analytics.activeTimeSeconds. Both persist
    // independently and an idle-heavy session keeps them far apart.
    #expect(decoded.wallClockDurationSeconds == 28_800)
    #expect(decoded.analytics.activeTimeSeconds == 300)
}
