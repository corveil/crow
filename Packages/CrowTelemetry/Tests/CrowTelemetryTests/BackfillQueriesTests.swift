import CrowCore
import Foundation
import Testing
@testable import CrowTelemetry

/// Tests for the scorecard-backfill query surface (issue #745):
/// `sessionIDs()` (which sessions have telemetry rows), the
/// `received_at`-windowed `sessionAnalytics(for:receivedBetween:end:)`
/// behind the Manager weekly rollups, and the `captureStatus()` health probe.

private func makeDatabase() async throws -> (db: TelemetryDatabase, path: String) {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".db").path
    let db = TelemetryDatabase(path: path)
    try await db.open()
    return (db, path)
}

private func insertPrompt(
    _ db: TelemetryDatabase, session: UUID, receivedAt: Date = Date()
) async {
    await db.insertEvent(
        crowSessionID: session,
        eventName: "claude_code.user_prompt",
        body: nil,
        attributesJSON: nil,
        severityNumber: nil,
        timestampNs: nil,
        receivedAt: receivedAt
    )
}

private func insertTokens(
    _ db: TelemetryDatabase,
    session: UUID,
    type: String,
    value: Double,
    receivedAt: Date = Date()
) async {
    await db.insertMetric(
        crowSessionID: session,
        metricName: "claude_code.token.usage",
        value: value,
        attributesJSON: "{\"type\":\"\(type)\"}",
        timestampNs: nil,
        temporality: .delta,
        isMonotonic: true,
        receivedAt: receivedAt
    )
}

private func insertCost(
    _ db: TelemetryDatabase, session: UUID, value: Double, receivedAt: Date = Date()
) async {
    await db.insertMetric(
        crowSessionID: session,
        metricName: "claude_code.cost.usage",
        value: value,
        attributesJSON: nil,
        timestampNs: nil,
        temporality: .delta,
        isMonotonic: true,
        receivedAt: receivedAt
    )
}

// MARK: - sessionIDs()

@Test func sessionIDsDeduplicatesAcrossMetricsAndEvents() async throws {
    let (db, _) = try await makeDatabase()
    let inBoth = UUID()
    let metricsOnly = UUID()
    let eventsOnly = UUID()

    await insertTokens(db, session: inBoth, type: "input", value: 100)
    await insertPrompt(db, session: inBoth)
    await insertTokens(db, session: metricsOnly, type: "input", value: 100)
    await insertPrompt(db, session: eventsOnly)

    let ids = await db.sessionIDs()
    #expect(Set(ids) == [inBoth, metricsOnly, eventsOnly])
    #expect(ids.count == 3)

    await db.close()
}

@Test func sessionIDsIsEmptyForEmptyDatabase() async throws {
    let (db, _) = try await makeDatabase()
    #expect(await db.sessionIDs().isEmpty)
    await db.close()
}

// A mapping alone (session_map row, no metric/event rows) is not
// "has telemetry" — backfill drives off actual data rows.
@Test func sessionIDsIgnoresMappingOnlySessions() async throws {
    let (db, _) = try await makeDatabase()
    let mappedOnly = UUID()
    await db.registerSessionMapping(claudeSessionID: "claude-abc", crowSessionID: mappedOnly)

    #expect(await db.sessionIDs().isEmpty)
    await db.close()
}

// MARK: - Windowed sessionAnalytics

@Test func windowedAnalyticsFiltersByReceivedAtHalfOpen() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()
    let start = Date(timeIntervalSince1970: 1_752_000_000)
    let end = start.addingTimeInterval(7 * 86_400)

    // Before, at-start (inclusive), inside, at-end (exclusive), after.
    await insertTokens(db, session: session, type: "input", value: 1,
                       receivedAt: start.addingTimeInterval(-1))
    await insertTokens(db, session: session, type: "input", value: 10, receivedAt: start)
    await insertTokens(db, session: session, type: "input", value: 100,
                       receivedAt: start.addingTimeInterval(3 * 86_400))
    await insertTokens(db, session: session, type: "input", value: 1_000, receivedAt: end)
    await insertTokens(db, session: session, type: "input", value: 10_000,
                       receivedAt: end.addingTimeInterval(1))
    await insertPrompt(db, session: session, receivedAt: start.addingTimeInterval(-1))
    await insertPrompt(db, session: session, receivedAt: start.addingTimeInterval(60))
    await insertPrompt(db, session: session, receivedAt: end)

    let windowed = await db.sessionAnalytics(for: session, receivedBetween: start, end: end)
    #expect(windowed.inputTokens == 110)
    #expect(windowed.promptCount == 1)

    await db.close()
}

@Test func windowedAnalyticsUnknownSessionIsAllZeros() async throws {
    let (db, _) = try await makeDatabase()
    let analytics = await db.sessionAnalytics(
        for: UUID(),
        receivedBetween: Date(timeIntervalSince1970: 0),
        end: Date(timeIntervalSince1970: 2_000_000_000))
    #expect(analytics.isEmpty)
    await db.close()
}

// Sanity lock: an all-covering window equals the un-windowed aggregate,
// so the shared helper refactor can't have changed the original query.
@Test func windowedAnalyticsOverFullRangeMatchesUnwindowed() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()
    await insertTokens(db, session: session, type: "input", value: 500)
    await insertTokens(db, session: session, type: "output", value: 900)
    await insertTokens(db, session: session, type: "cacheRead", value: 4_000)
    await insertCost(db, session: session, value: 2.5)
    await insertPrompt(db, session: session)
    await insertPrompt(db, session: session)

    let unwindowed = await db.sessionAnalytics(for: session)
    let windowed = await db.sessionAnalytics(
        for: session,
        receivedBetween: Date(timeIntervalSince1970: 0),
        end: Date(timeIntervalSince1970: 4_000_000_000))

    #expect(windowed == unwindowed)
    #expect(!windowed.isEmpty)

    await db.close()
}

// Retention interaction (the "aged out" half at the DB layer): once rows
// are pruned, the window that covered them reads empty — which the
// merge-only Manager refresh treats as "skip", not "zero".
@Test func prunedRowsDisappearFromWindowedAnalytics() async throws {
    let (db, _) = try await makeDatabase()
    let session = UUID()
    let oldWeekStart = Date().addingTimeInterval(-200 * 86_400)
    await insertTokens(db, session: session, type: "input", value: 500,
                       receivedAt: oldWeekStart.addingTimeInterval(3_600))
    await insertPrompt(db, session: session, receivedAt: oldWeekStart.addingTimeInterval(3_600))

    let before = await db.sessionAnalytics(
        for: session, receivedBetween: oldWeekStart,
        end: oldWeekStart.addingTimeInterval(7 * 86_400))
    #expect(!before.isEmpty)

    await db.pruneOldData(retentionDays: 180)

    let after = await db.sessionAnalytics(
        for: session, receivedBetween: oldWeekStart,
        end: oldWeekStart.addingTimeInterval(7 * 86_400))
    #expect(after.isEmpty)
    #expect(await db.sessionIDs().isEmpty)

    await db.close()
}

// MARK: - captureStatus()

@Test func captureStatusCountsDistinctSessionsAndNewestRow() async throws {
    let (db, _) = try await makeDatabase()
    let first = UUID()
    let second = UUID()
    let older = Date(timeIntervalSince1970: 1_752_000_000)
    let newest = Date(timeIntervalSince1970: 1_752_500_000)

    await insertTokens(db, session: first, type: "input", value: 100, receivedAt: older)
    await insertPrompt(db, session: first, receivedAt: older)
    await insertPrompt(db, session: second, receivedAt: newest)

    let status = await db.captureStatus()
    #expect(status.sessionCount == 2)
    #expect(status.lastReceivedAt == newest)

    await db.close()
}

@Test func captureStatusIsZeroAndNilForEmptyDatabase() async throws {
    let (db, _) = try await makeDatabase()
    let status = await db.captureStatus()
    #expect(status.sessionCount == 0)
    #expect(status.lastReceivedAt == nil)
    await db.close()
}
