import CrowCore
import Foundation
import Testing
@testable import CrowTelemetry

/// Tests for the per-turn analytics reader (issue #695, ADR 0008 follow-up 7).
///
/// `turnAnalytics(for:)` reconstructs one record per `claude_code.user_prompt`
/// event by segmenting stored token/cost delta rows on their timestamps —
/// replacing the whole-session `inputTokens / promptCount` average as the
/// context-pressure signal.

private func makeDatabase() async throws -> (db: TelemetryDatabase, path: String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".db").path
    let db = TelemetryDatabase(path: path)
    try await db.open()
    return (db, path)
}

/// Nanosecond timestamp string for a whole second, matching OTLP timeUnixNano.
private func ns(_ seconds: Int) -> String {
    "\(seconds)000000000"
}

private func insertPrompt(_ db: TelemetryDatabase, session: UUID, atSecond second: Int?) async {
    await db.insertEvent(
        crowSessionID: session,
        eventName: "claude_code.user_prompt",
        body: nil,
        attributesJSON: nil,
        severityNumber: nil,
        timestampNs: second.map(ns)
    )
}

private func insertTokens(
    _ db: TelemetryDatabase,
    session: UUID,
    type: String,
    value: Double,
    atSecond second: Int?
) async {
    await db.insertMetric(
        crowSessionID: session,
        metricName: "claude_code.token.usage",
        value: value,
        attributesJSON: "{\"type\":\"\(type)\"}",
        timestampNs: second.map(ns),
        temporality: .delta,
        isMonotonic: true
    )
}

private func insertCost(_ db: TelemetryDatabase, session: UUID, value: Double, atSecond second: Int) async {
    await db.insertMetric(
        crowSessionID: session,
        metricName: "claude_code.cost.usage",
        value: value,
        attributesJSON: nil,
        timestampNs: ns(second),
        temporality: .delta,
        isMonotonic: true
    )
}

@Test func threePromptsSegmentTokenRowsIntoThreeTurns() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertPrompt(db, session: session, atSecond: 10)
    await insertTokens(db, session: session, type: "input", value: 1000, atSecond: 11)
    await insertTokens(db, session: session, type: "output", value: 500, atSecond: 12)
    await insertCost(db, session: session, value: 0.10, atSecond: 12)

    await insertPrompt(db, session: session, atSecond: 20)
    await insertTokens(db, session: session, type: "input", value: 2000, atSecond: 21)
    await insertTokens(db, session: session, type: "input", value: 3000, atSecond: 22)
    await insertTokens(db, session: session, type: "cacheRead", value: 40000, atSecond: 22)

    await insertPrompt(db, session: session, atSecond: 30)
    await insertTokens(db, session: session, type: "input", value: 7000, atSecond: 31)
    await insertTokens(db, session: session, type: "cacheCreation", value: 900, atSecond: 31)

    let turns = await db.turnAnalytics(for: session)
    #expect(turns.count == 3)
    #expect(turns[0] == TurnAnalytics(turnIndex: 0, inputTokens: 1000, outputTokens: 500, cost: 0.10))
    #expect(turns[1] == TurnAnalytics(turnIndex: 1, inputTokens: 5000, cacheReadTokens: 40000))
    #expect(turns[2] == TurnAnalytics(turnIndex: 2, inputTokens: 7000, cacheCreationTokens: 900))
    #expect(turns[1].contextTokenEstimate == 45000)
    await db.close()
}

@Test func tokensBeforeFirstPromptFoldIntoTurnZero() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    // Exporter batching can deliver token rows stamped before the first
    // recorded prompt — they belong to turn 0, not the floor.
    await insertTokens(db, session: session, type: "input", value: 300, atSecond: 5)
    await insertPrompt(db, session: session, atSecond: 10)
    await insertTokens(db, session: session, type: "input", value: 700, atSecond: 11)
    await insertPrompt(db, session: session, atSecond: 20)
    await insertTokens(db, session: session, type: "input", value: 400, atSecond: 21)

    let turns = await db.turnAnalytics(for: session)
    #expect(turns.count == 2)
    #expect(turns[0].inputTokens == 1000)
    #expect(turns[1].inputTokens == 400)

    // Per-field sums across turns reproduce the session aggregate.
    let analytics = await db.sessionAnalytics(for: session)
    #expect(turns.reduce(0) { $0 + $1.inputTokens } == analytics.inputTokens)
    await db.close()
}

@Test func nullTimestampNsFallsBackToReceivedAt() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    // No OTLP timestamps at all: ordering falls back to received_at, which
    // increases with insert order.
    await insertPrompt(db, session: session, atSecond: nil)
    await insertTokens(db, session: session, type: "input", value: 100, atSecond: nil)

    let turns = await db.turnAnalytics(for: session)
    #expect(turns.count == 1)
    #expect(turns[0].inputTokens == 100)
    await db.close()
}

@Test func emptySessionReturnsEmptyArray() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    // Aged out of retention or telemetry off: no rows at all. The empty
    // result is the caller's cue to fall back to the promptCount average.
    let turns = await db.turnAnalytics(for: session)
    #expect(turns.isEmpty)

    // Token rows without any prompt events (prompts pruned first) also
    // degrade to empty rather than inventing a turn.
    await insertTokens(db, session: session, type: "input", value: 100, atSecond: 5)
    #expect(await db.turnAnalytics(for: session).isEmpty)
    await db.close()
}

@Test func promptWithNoTokenRowsYieldsZeroRecord() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertPrompt(db, session: session, atSecond: 10)
    await insertTokens(db, session: session, type: "input", value: 100, atSecond: 11)
    await insertPrompt(db, session: session, atSecond: 20)  // no traffic yet

    let turns = await db.turnAnalytics(for: session)
    #expect(turns.count == 2)
    #expect(turns[1] == TurnAnalytics(turnIndex: 1))
    await db.close()
}

@Test func existingSessionAnalyticsUnchanged() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()

    await insertPrompt(db, session: session, atSecond: 10)
    await insertTokens(db, session: session, type: "input", value: 1000, atSecond: 11)
    await insertTokens(db, session: session, type: "output", value: 500, atSecond: 12)
    await insertCost(db, session: session, value: 0.25, atSecond: 12)
    await insertPrompt(db, session: session, atSecond: 20)
    await insertTokens(db, session: session, type: "input", value: 2000, atSecond: 21)

    let analytics = await db.sessionAnalytics(for: session)
    #expect(analytics.inputTokens == 3000)
    #expect(analytics.outputTokens == 500)
    #expect(analytics.totalCost == 0.25)
    #expect(analytics.promptCount == 2)
    await db.close()
}
