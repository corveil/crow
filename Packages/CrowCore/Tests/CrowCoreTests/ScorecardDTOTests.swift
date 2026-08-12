import Foundation
import Testing
@testable import CrowCore

// #721 (ADR 0008 web parity): the `ScorecardDTO` is a lossless, JS-friendly
// projection of `ScorecardModel`. These pin that the DTO carries exactly the
// numbers the web scorecard reads — building server-side is what lets the web
// match Core without re-implementing grading in JavaScript.

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
    #expect(off.managerWeeks.isEmpty)
    #expect(!off.telemetryCapturing)
}

// MARK: - Manager usage (ungraded bucket; #745, #767)

private func managerWeek(
    _ weekStart: Date, prompts: Int = 12, cost: Double = 3, inputTokens: Int = 900
) -> ManagerWeeklyUsage {
    ManagerWeeklyUsage(
        weekStart: weekStart,
        analytics: SessionAnalytics(
            totalCost: cost,
            inputTokens: inputTokens,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            activeTimeSeconds: 1800,
            linesAdded: 0,
            linesRemoved: 0,
            commitCount: 0,
            promptCount: prompts,
            apiRequestCount: 0,
            apiErrorCount: 0
        ))
}

@Test func dtoProjectsManagerWeeksNewestFirst() {
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    // Deliberately supplied oldest-first — the DTO owns the ordering, because
    // it comes off an unordered dictionary on `AppState`.
    let usage = [
        managerWeek(date(2026, 6, 29), prompts: 4, cost: 1),
        managerWeek(date(2026, 7, 13), prompts: 12, cost: 3),
        managerWeek(date(2026, 7, 6), prompts: 8, cost: 2),
    ]
    let dto = ScorecardDTO(model, telemetryEnabled: true, snapshotCount: 0, managerUsage: usage)

    #expect(dto.managerWeeks.map(\.promptCount) == [12, 8, 4])
    #expect(dto.managerWeeks.map(\.totalCost) == [3, 2, 1])
    #expect(dto.managerWeeks[0].weekStartMillis == date(2026, 7, 13).timeIntervalSince1970 * 1000)
    // totalTokens is SessionAnalytics' derived sum, not a stored field.
    #expect(dto.managerWeeks[0].totalTokens == usage[1].analytics.totalTokens)
}

@Test func managerUsageNeverTouchesTheGradedMath() {
    // AC for #767: the Manager bucket is visibility only. Same snapshots, with
    // and without Manager usage — every graded surface must be identical.
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), compactions: 3, prompts: 10, cost: 4),
        snapshot(endedAt: date(2026, 7, 14), compactions: 0, prompts: 8, cost: 6),
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    let without = ScorecardDTO(model, telemetryEnabled: true, snapshotCount: snapshots.count)
    let with = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: snapshots.count,
        // An implausibly expensive Manager week: if it leaked into the math at
        // all, cost-per-shipped and the combined score would move.
        managerUsage: [managerWeek(date(2026, 7, 13), prompts: 5000, cost: 999)])

    #expect(with.currentWeek == without.currentWeek)
    #expect(with.priorWeeks == without.priorWeeks)
    #expect(with.baseline == without.baseline)
    #expect(with.sessions == without.sessions)
    #expect(with.managerWeeks.count == 1)
}

@Test func dtoCarriesManagerWeeksWithZeroSnapshots() {
    // The web's empty-state gate is `!snapshotCount && !managerWeeks.length`,
    // so captured Manager usage must survive a scorecard with nothing graded.
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0,
        managerUsage: [managerWeek(date(2026, 7, 13))])

    #expect(dto.snapshotCount == 0)
    #expect(dto.managerWeeks.count == 1)
}

@Test func dtoCarriesCaptureStatus() throws {
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let receivedAt = date(2026, 7, 15, 9)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0,
        managerUsage: [managerWeek(date(2026, 7, 13))],
        captureStatus: TelemetryCaptureStatus(sessionCount: 3, lastReceivedAt: receivedAt))

    #expect(dto.telemetryCapturing)
    #expect(dto.telemetrySessionCount == 3)
    #expect(dto.telemetryLastReceivedAtMillis == receivedAt.timeIntervalSince1970 * 1000)

    // Manager rows + capture status survive the wire (the web reads only JSON).
    let decoded = try JSONDecoder().decode(ScorecardDTO.self, from: JSONEncoder().encode(dto))
    #expect(decoded == dto)

    // A nil status is "not capturing", never a fake zero-count capture.
    let dark = ScorecardDTO(model, telemetryEnabled: true, snapshotCount: 0)
    #expect(!dark.telemetryCapturing)
    #expect(dark.telemetryLastReceivedAtMillis == nil)
}

// MARK: - Widened Manager metering + efficiency grade (CROW-983)

private let managerA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
private let managerB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

/// A Manager week with enough traffic to clear the grading prompt floor and
/// exercise every widened figure.
private func richManagerWeek(
    _ weekStart: Date,
    sessionID: UUID? = nil,
    compactions: Int? = nil,
    cost: Double = 12.5
) -> ManagerWeeklyUsage {
    ManagerWeeklyUsage(
        weekStart: weekStart,
        analytics: SessionAnalytics(
            totalCost: cost,
            inputTokens: 600_000,
            outputTokens: 40_000,
            cacheReadTokens: 1_800_000,
            cacheCreationTokens: 120_000,
            activeTimeSeconds: 7200,
            linesAdded: 400,
            linesRemoved: 120,
            commitCount: 9,
            promptCount: 40,
            toolCallCount: 310,
            apiRequestCount: 500,
            apiErrorCount: 15
        ),
        sessionID: sessionID,
        compactionCount: compactions)
}

@Test func managerWeekProjectsTheWidenedFigures() throws {
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let week = richManagerWeek(date(2026, 7, 13), sessionID: managerA, compactions: 3)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0, managerUsage: [week])

    let row = try #require(dto.managerWeeks.first)
    // The three original figures still project.
    #expect(row.promptCount == 40)
    #expect(row.totalCost == 12.5)
    #expect(row.totalTokens == week.analytics.totalTokens)
    // Everything CROW-983 stopped dropping at the DTO boundary.
    #expect(row.activeTimeSeconds == 7200)
    #expect(row.commitCount == 9)
    #expect(row.toolCallCount == 310)
    #expect(row.inputTokensPerPrompt == 15_000)
    #expect(row.cacheHitRatio == 1_800_000.0 / 720_000.0)
    #expect(row.apiErrorRate == 0.03)
    #expect(row.compactionsPerActiveHour == 1.5)
}

@Test func managerEfficiencyGradeMatchesHandComputedGrading() throws {
    // The grade on the wire must be exactly `grade()` over the same raws —
    // no second formula, no rounding drift between the badge and the chips.
    let week = richManagerWeek(date(2026, 7, 13), sessionID: managerA, compactions: 3)
    let expected = EfficiencyGrading.grade(EfficiencyGrading.efficiencyInput(for: week))
    guard case .graded(let score, let letter, let deductions) = expected else {
        Issue.record("fixture should grade; got \(expected)")
        return
    }

    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0, managerUsage: [week])
    let row = try #require(dto.managerWeeks.first)

    #expect(row.grade.graded)
    #expect(row.grade.score == score)
    #expect(row.grade.letter == letter.rawValue)
    #expect(row.grade.deductions.map(\.metric) == deductions.map(\.metric.rawValue))
    #expect(row.grade.deductions.map(\.points) == deductions.map(\.points))
}

@Test func managerGradeIsOutcomeIndependent() throws {
    // The efficiency half only: cost-per-shipped is the one outcome-touching
    // deduction, and a Manager has no outcomes to divide by. An absurdly
    // expensive week must still never produce that deduction.
    let week = richManagerWeek(date(2026, 7, 13), sessionID: managerA, cost: 5_000)
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0, managerUsage: [week])
    let row = try #require(dto.managerWeeks.first)

    #expect(!row.grade.deductions.contains {
        $0.metric == EfficiencyGrading.Metric.costPerShipped.rawValue
    })
    // ...and the input that produced it genuinely carries no cost context.
    #expect(EfficiencyGrading.efficiencyInput(for: week).costContext == nil)
}

@Test func managerWeekBelowThePromptFloorIsInsufficientData() throws {
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0,
        managerUsage: [managerWeek(date(2026, 7, 13), prompts: 2)])
    let row = try #require(dto.managerWeeks.first)

    #expect(!row.grade.graded)
    #expect(row.grade.promptCount == 2)
}

@Test func eachManagerIsAttributedSeparately() {
    // CROW-983's second gap: `crow create-manager` can make N Managers, and
    // before this they were not merged into one bucket — they were invisible.
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0,
        managerUsage: [
            richManagerWeek(date(2026, 7, 13), sessionID: managerA, cost: 10),
            richManagerWeek(date(2026, 7, 13), sessionID: managerB, cost: 20),
        ],
        managerNames: [managerA: "Manager", managerB: "Manager 2"])

    #expect(dto.managerWeeks.count == 2)
    let byID = Dictionary(uniqueKeysWithValues: dto.managerWeeks.map { ($0.sessionID, $0) })
    #expect(byID[managerA.uuidString]?.totalCost == 10)
    #expect(byID[managerA.uuidString]?.sessionName == "Manager")
    #expect(byID[managerB.uuidString]?.totalCost == 20)
    #expect(byID[managerB.uuidString]?.sessionName == "Manager 2")
}

@Test func legacyManagerWeekResolvesToThePrimaryManager() throws {
    // Pre-CROW-983 rollups carry no session id. #745 only ever queried the
    // primary, so that is the only session they can belong to.
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0,
        managerUsage: [managerWeek(date(2026, 7, 13))],
        managerNames: [AppState.managerSessionID: "Manager"])
    let row = try #require(dto.managerWeeks.first)

    #expect(row.sessionID == AppState.managerSessionID.uuidString)
    #expect(row.sessionName == "Manager")
}

@Test func recomputedManagerWeekSupersedesTheLegacyRow() {
    // After the upgrade the first refresh writes a composite-keyed row while
    // the bare-keyed one remains, so both describe the same week. Rendering
    // both would duplicate it; the recomputed one wins.
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0,
        managerUsage: [
            managerWeek(date(2026, 7, 13), cost: 1),                                  // legacy
            richManagerWeek(date(2026, 7, 13),
                            sessionID: AppState.managerSessionID, cost: 99),          // recomputed
        ])

    #expect(dto.managerWeeks.count == 1)
    #expect(dto.managerWeeks[0].totalCost == 99)

    // A legacy week nothing superseded still renders — a week aged out of
    // telemetry retention is never recomputed, and the merge-only store
    // exists precisely to keep it.
    let orphan = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0,
        managerUsage: [managerWeek(date(2026, 6, 22), cost: 7)])
    #expect(orphan.managerWeeks.count == 1)
    #expect(orphan.managerWeeks[0].totalCost == 7)
}

@Test func managerWeeksAreCappedPerManager() {
    // `managerUsageWeekly` is merge-only and never pruned, so the projection
    // bounds each Manager to the window the refresh recomputes. Capping per
    // Manager keeps a second one from evicting the first one's history.
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    let cap = EfficiencyGrading.Tuning.baselineWeekCount + 1
    var usage: [ManagerWeeklyUsage] = []
    for offset in 0..<(cap + 4) {
        let weekStart = date(2026, 7, 13).addingTimeInterval(Double(-offset) * 7 * 86_400)
        usage.append(richManagerWeek(weekStart, sessionID: managerA))
        usage.append(richManagerWeek(weekStart, sessionID: managerB))
    }
    let dto = ScorecardDTO(
        model, telemetryEnabled: true, snapshotCount: 0, managerUsage: usage)

    #expect(dto.managerWeeks.count == cap * 2)
    #expect(dto.managerWeeks.filter { $0.sessionID == managerA.uuidString }.count == cap)
    #expect(dto.managerWeeks.filter { $0.sessionID == managerB.uuidString }.count == cap)
    // Newest kept, oldest dropped.
    #expect(dto.managerWeeks[0].weekStartMillis == date(2026, 7, 13).timeIntervalSince1970 * 1000)
}
