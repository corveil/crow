import Foundation
import Testing
@testable import CrowCore

// #721 (ADR 0008 web parity): the `ScorecardDTO` is a lossless, JS-friendly
// projection of `ScorecardModel`. These pin that the DTO carries exactly the
// numbers the desktop `ScorecardView` reads — building server-side is what lets
// the web match Core without re-implementing grading in JavaScript.

private let utc: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}

private let now = date(2026, 7, 15) // Wed of ISO week Mon 2026-07-13 … Sun 2026-07-19

private func snapshot(
    endedAt: Date,
    status: SessionStatus = .completed,
    compactions: Int? = 0,
    activeSeconds: Double = 3600,
    prompts: Int = 10,
    inputTokens: Int = 0,
    apiErrors: Int = 0,
    apiRequests: Int = 0,
    cost: Double = 0
) -> SessionAnalyticsSnapshot {
    SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: endedAt,
        status: status,
        analytics: SessionAnalytics(
            totalCost: cost,
            inputTokens: inputTokens,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            activeTimeSeconds: activeSeconds,
            linesAdded: 0,
            linesRemoved: 0,
            commitCount: 0,
            promptCount: prompts,
            apiRequestCount: apiRequests,
            apiErrorCount: apiErrors
        ),
        compactionCount: compactions
    )
}

@Test func dtoMirrorsCurrentWeekGradeAndThroughput() {
    // Current week: two shipped sessions, one with a compaction penalty.
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), compactions: 3, activeSeconds: 3600, prompts: 10, cost: 4),
        snapshot(endedAt: date(2026, 7, 14), compactions: 0, activeSeconds: 3600, prompts: 8, cost: 6),
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    let dto = ScorecardDTO(model, telemetryEnabled: true, snapshotCount: snapshots.count)

    guard case .graded(let score, let letter, let deductions) = model.currentWeek.result else {
        Issue.record("expected a graded current week"); return
    }
    #expect(dto.currentWeek.grade.graded)
    #expect(dto.currentWeek.grade.score == score)
    #expect(dto.currentWeek.grade.letter == letter.rawValue)
    #expect(dto.currentWeek.grade.deductions.count == deductions.count)
    #expect(dto.currentWeek.grade.deductions.first?.metric == deductions.first?.metric.rawValue)

    #expect(dto.currentWeek.sessionsShipped == model.currentWeek.sessionsShipped)
    #expect(dto.currentWeek.sessionsShipped == 2)
    // costPerShipped graded ⇒ present.
    if case .graded(let cost) = model.currentWeek.costPerShipped {
        #expect(dto.currentWeek.costPerShipped == cost)
    } else {
        Issue.record("expected graded cost-per-shipped")
    }
    // Derived rates carried inline for the baseline comparison.
    #expect(dto.currentWeek.compactionsPerActiveHour == model.currentWeek.input.compactionsPerActiveHour)
    #expect(dto.currentWeek.cacheHitRatio == model.currentWeek.input.cacheHitRatio)
    #expect(dto.sessions.count == model.currentWeekSessions.count)
    #expect(dto.snapshotCount == 2)
    #expect(dto.telemetryEnabled)
}

@Test func dtoMirrorsCombinedScoreDecomposition() {
    let snapshots = [snapshot(endedAt: date(2026, 7, 13), prompts: 10, cost: 3)]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    let dto = ScorecardDTO(model, telemetryEnabled: true, snapshotCount: 1)

    guard case .scored(let factors) = model.currentWeek.combined else {
        Issue.record("expected a scored combined result"); return
    }
    #expect(dto.currentWeek.combined.scored)
    #expect(dto.currentWeek.combined.value == factors.value)
    #expect(dto.currentWeek.combined.shippedCount == factors.shippedCount)
    #expect(dto.currentWeek.combined.efficiencyMultiplier == factors.efficiencyMultiplier)
    #expect(dto.currentWeek.combined.gradeScore == factors.gradeScore)
    // No attributions ⇒ neutral hygiene, nil merge rate (never a fake 0/1).
    #expect(dto.currentWeek.combined.hygieneFactor == 1.0)
    #expect(dto.currentWeek.combined.mergeRate == nil)
}

@Test func dtoFlattensInsufficientData() {
    // Below the minimum-sample floor ⇒ not graded, not scored.
    let snapshots = [snapshot(endedAt: date(2026, 7, 13), prompts: 2)]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    let dto = ScorecardDTO(model, telemetryEnabled: true, snapshotCount: 1)

    #expect(!dto.currentWeek.grade.graded)
    #expect(dto.currentWeek.grade.score == nil)
    #expect(dto.currentWeek.grade.promptCount == 2)
    #expect(!dto.currentWeek.combined.scored)
    #expect(dto.currentWeek.combined.promptCount == 2)
}

@Test func dtoCarriesBaselineWhenPriorWeeksExist() {
    // Four graded prior weeks + the current week ⇒ a full baseline.
    var snapshots: [SessionAnalyticsSnapshot] = []
    for offset in 0...4 {
        let day = date(2026, 7, 13 - offset * 7)
        snapshots.append(snapshot(endedAt: day, compactions: offset, prompts: 10, cost: 5))
    }
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    let dto = ScorecardDTO(model, telemetryEnabled: true, snapshotCount: snapshots.count)

    #expect(dto.priorWeeks.count == model.priorWeeks.count)
    #expect(dto.baseline.weeksAvailable == model.baseline.weeksAvailable)
    #expect(dto.baseline.medianScore == model.baseline.medianScore)
    #expect(dto.minimumBaselineWeeks == EfficiencyGrading.Tuning.minimumBaselineWeeks)
    #expect(dto.baselineWeekCount == EfficiencyGrading.Tuning.baselineWeekCount)
}

@Test func dtoRoundTripsThroughJSON() throws {
    let snapshots = [snapshot(endedAt: date(2026, 7, 13), compactions: 2, prompts: 10, cost: 8)]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    let dto = ScorecardDTO(model, telemetryEnabled: false, snapshotCount: 1)

    let data = try JSONEncoder().encode(dto)
    let decoded = try JSONDecoder().decode(ScorecardDTO.self, from: data)
    #expect(decoded == dto)
    // Week start survives as epoch millis (JS `new Date(ms)`).
    #expect(decoded.currentWeek.weekStartMillis == model.currentWeek.weekStart.timeIntervalSince1970 * 1000)
}

@Test func dtoEmptyStateFlags() {
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let off = ScorecardDTO(model, telemetryEnabled: false, snapshotCount: 0)
    #expect(off.snapshotCount == 0)
    #expect(!off.telemetryEnabled)
    #expect(off.sessions.isEmpty)
    #expect(off.priorWeeks.isEmpty)
}
