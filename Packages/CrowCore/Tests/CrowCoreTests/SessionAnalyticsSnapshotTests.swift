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

// Locks in the follow-up-3 extension-point contract: future fields (e.g. the
// compaction counter) arrive as optionals on the snapshot, and snapshots
// carrying keys this app version doesn't know must still decode — Codable
// synthesis ignores unknown keys.
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
      "compactionCount": 3
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SessionAnalyticsSnapshot.self, from: Data(json.utf8))
    #expect(decoded.status == .archived)
    #expect(decoded.analytics.inputTokens == 42)
    #expect(decoded.analytics.isEmpty == false)
}
