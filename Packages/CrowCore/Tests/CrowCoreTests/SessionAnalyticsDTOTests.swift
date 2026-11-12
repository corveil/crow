import Foundation
import Testing
@testable import CrowCore

// CROW-722 (ADR 0008 web parity): `SessionAnalyticsDTO` is a lossless, JS-friendly
// projection of a session's analytics — either the live in-memory hook aggregate
// or the durable end-of-session snapshot. These pin that both inits carry exactly
// the numbers the desktop `SessionAnalyticsStrip` reads, so the web strip can't
// drift from Core.

@Test func liveInitCarriesEveryFieldAndComputesTotalTokens() {
    let analytics = SessionAnalytics(
        totalCost: 1.23,
        inputTokens: 100,
        outputTokens: 200,
        cacheReadTokens: 300,
        cacheCreationTokens: 400,
        activeTimeSeconds: 3600,
        linesAdded: 10,
        linesRemoved: 4,
        commitCount: 2,
        promptCount: 5,
        toolCallCount: 42,
        apiRequestCount: 7,
        apiErrorCount: 3
    )
    let dto = SessionAnalyticsDTO(live: analytics, wallClockDuration: 5400)

    #expect(dto.source == "live")
    #expect(dto.totalCost == 1.23)
    #expect(dto.inputTokens == 100)
    #expect(dto.outputTokens == 200)
    #expect(dto.cacheReadTokens == 300)
    #expect(dto.cacheCreationTokens == 400)
    #expect(dto.totalTokens == 1000) // 100 + 200 + 300 + 400
    #expect(dto.activeTimeSeconds == 3600)
    #expect(dto.toolCallCount == 42)
    #expect(dto.linesAdded == 10)
    #expect(dto.linesRemoved == 4)
    #expect(dto.apiErrorCount == 3)
    #expect(dto.wallClockDurationSeconds == 5400)
}

@Test func liveInitWithoutWallClockOmitsDuration() {
    let dto = SessionAnalyticsDTO(live: SessionAnalytics(totalCost: 0.5))
    #expect(dto.source == "live")
    #expect(dto.wallClockDurationSeconds == nil)
}

@Test func snapshotInitCarriesAnalyticsAndWallClock() {
    let snapshot = SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: Date(),
        status: .completed,
        analytics: SessionAnalytics(totalCost: 2.5, inputTokens: 50, outputTokens: 50, toolCallCount: 9),
        compactionCount: 1,
        wallClockDurationSeconds: 7200
    )
    let dto = SessionAnalyticsDTO(snapshot: snapshot)

    #expect(dto.source == "snapshot")
    #expect(dto.totalCost == 2.5)
    #expect(dto.totalTokens == 100)
    #expect(dto.toolCallCount == 9)
    #expect(dto.wallClockDurationSeconds == 7200)
}

@Test func snapshotInitWithoutWallClockOmitsDuration() {
    let snapshot = SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: Date(),
        status: .archived,
        analytics: SessionAnalytics(totalCost: 1.0)
    )
    let dto = SessionAnalyticsDTO(snapshot: snapshot)
    #expect(dto.source == "snapshot")
    #expect(dto.wallClockDurationSeconds == nil)
}

@Test func encodesToFlatJSONObjectForTheWeb() throws {
    let dto = SessionAnalyticsDTO(
        live: SessionAnalytics(totalCost: 0.01, inputTokens: 1, outputTokens: 1, toolCallCount: 3),
        wallClockDuration: 60
    )
    let data = try JSONEncoder().encode(dto)
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    #expect(object["source"] as? String == "live")
    #expect(object["totalTokens"] as? Int == 2)
    #expect(object["toolCallCount"] as? Int == 3)
    #expect(object["wallClockDurationSeconds"] as? Double == 60)
}

// CROW-1439: a Manager's strip is its current-week rollup. It carries the week
// start (the web's `This week` label) and the week's compactions, and no
// lifetime wall-clock duration.
@Test func managerWeekInitCarriesWindowAndCompactions() {
    let weekStart = Date(timeIntervalSince1970: 1_794_182_400) // Mon 2026-11-09 UTC
    let week = ManagerWeeklyUsage(
        weekStart: weekStart,
        analytics: SessionAnalytics(totalCost: 6.75, inputTokens: 120, outputTokens: 30, toolCallCount: 11),
        sessionID: UUID(), compactionCount: 2)
    let dto = SessionAnalyticsDTO(managerWeek: week)

    #expect(dto.source == "week")
    #expect(dto.totalCost == 6.75)
    #expect(dto.totalTokens == 150)
    #expect(dto.toolCallCount == 11)
    #expect(dto.weekStartMillis == 1_794_182_400_000)
    #expect(dto.compactionCount == 2)
    #expect(dto.wallClockDurationSeconds == nil)
}

// Work-session payloads are unchanged: the Manager-only keys never reach the wire.
@Test func workSessionDTOOmitsManagerOnlyKeys() throws {
    let live = SessionAnalyticsDTO(live: SessionAnalytics(totalCost: 1), wallClockDuration: 60)
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(live)) as? [String: Any]
    let keys = Set(object?.keys.map { $0 } ?? [])
    #expect(!keys.contains("weekStartMillis"))
    #expect(!keys.contains("compactionCount"))
    #expect(keys == [
        "source", "totalCost", "inputTokens", "outputTokens", "cacheReadTokens",
        "cacheCreationTokens", "totalTokens", "activeTimeSeconds", "toolCallCount",
        "linesAdded", "linesRemoved", "apiErrorCount", "wallClockDurationSeconds",
    ])
}
