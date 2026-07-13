import Foundation
import Testing
@testable import CrowCore

// #710 (ADR 0008 v1): week bucketing, Σ-based weekly rollup, sessions-shipped
// throughput, and the trailing-4-week self-comparison baseline.

/// Fixed UTC ISO-8601 calendar so bucketing is deterministic on any machine
/// (including Linux CI).
private let utc: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Mid-week "now": Wednesday 2026-07-15. The current ISO week runs Monday
/// 2026-07-13 00:00 UTC through Sunday 2026-07-19.
private let now = date(2026, 7, 15)
private let currentWeekMonday = date(2026, 7, 13, 0)

private func snapshot(
    endedAt: Date,
    status: SessionStatus = .archived,
    compactions: Int? = 0,
    activeSeconds: Double = 3600,
    prompts: Int = 10,
    inputTokens: Int = 0,
    cacheRead: Int = 0,
    cacheCreation: Int = 0,
    apiErrors: Int = 0,
    apiRequests: Int = 0,
    cost: Double = 0,
    linesAdded: Int = 0,
    linesRemoved: Int = 0,
    commits: Int = 0
) -> SessionAnalyticsSnapshot {
    SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: endedAt,
        status: status,
        analytics: SessionAnalytics(
            totalCost: cost,
            inputTokens: inputTokens,
            cacheReadTokens: cacheRead,
            cacheCreationTokens: cacheCreation,
            activeTimeSeconds: activeSeconds,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            commitCount: commits,
            promptCount: prompts,
            apiRequestCount: apiRequests,
            apiErrorCount: apiErrors
        ),
        compactionCount: compactions
    )
}

private func weeklyScore(_ week: WeeklyScorecard) -> Int? {
    guard case .graded(let score, _, _) = week.result else { return nil }
    return score
}

// The ADR's core anti-dilution rule: the weekly grade re-aggregates raw
// numerators/denominators (Σ compactions / Σ active hours) — one disastrous
// session cannot be laundered by surrounding it with many short clean ones,
// which averaging per-session grades would allow.
@Test func weeklyRollupSumsRawsNotAverages() {
    var snapshots = [
        // Disaster: 6 compactions in half an active hour.
        snapshot(endedAt: date(2026, 7, 13), compactions: 6, activeSeconds: 1800, prompts: 5)
    ]
    // Five short clean sessions (0.1 active hours each).
    for day in 14...18 {
        snapshots.append(snapshot(endedAt: date(2026, 7, day), activeSeconds: 360, prompts: 5))
    }

    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)

    // Σ = 6 compactions over 1.0 total active hours → 6.0/hr → capped −30.
    guard case .graded(let weekScore, _, let deductions) = model.currentWeek.result else {
        Issue.record("expected graded week")
        return
    }
    #expect(deductions == [EfficiencyGrading.Deduction(
        metric: .compactions,
        points: EfficiencyGrading.Tuning.compactionDeductionCap,
        label: "6 compactions (6.0/active hr)")])
    #expect(weekScore == 70)

    // The mean of per-session scores (5×100 + 1×70 = 95) would have diluted
    // the disaster; the Σ-based weekly score must sit strictly below it.
    let sessionScores = model.currentWeekSessions.compactMap { row -> Int? in
        guard case .graded(let s, _, _) = row.result else { return nil }
        return s
    }
    #expect(sessionScores.count == 6)
    let mean = Double(sessionScores.reduce(0, +)) / Double(sessionScores.count)
    #expect(Double(weekScore) < mean)
}

// ISO-8601 weeks: Monday 00:00 starts a new bucket.
@Test func weekBucketingSplitsOnISOMonday() {
    let sundayNight = snapshot(endedAt: date(2026, 7, 12, 23, 59))
    let mondayMorning = snapshot(endedAt: date(2026, 7, 13, 0, 1))

    let model = ScorecardModel.build(
        snapshots: [sundayNight, mondayMorning], now: now, calendar: utc)

    #expect(model.currentWeek.weekStart == currentWeekMonday)
    #expect(model.currentWeek.sessionCount == 1)
    #expect(model.currentWeekSessions.first?.sessionID == mondayMorning.sessionID)
    #expect(model.priorWeeks.count == 1)
    #expect(model.priorWeeks[0].sessionCount == 1)
}

// Sessions shipped counts `.completed` snapshots only — the ADR 0008 outcome
// flag, not `doneIssuesLast24h`.
@Test func sessionsShippedCountsCompletedOnly() {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), status: .completed),
        snapshot(endedAt: date(2026, 7, 14), status: .completed),
        snapshot(endedAt: date(2026, 7, 15), status: .archived)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    #expect(model.currentWeek.sessionsShipped == 2)
    #expect(model.currentWeekSessions.filter(\.shipped).count == 2)
}

@Test func zeroShippedWeekIsInsufficientOutcomes() {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), status: .archived, cost: 12),
        snapshot(endedAt: date(2026, 7, 14), status: .archived, cost: 30)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    #expect(model.currentWeek.costPerShipped == .insufficientOutcomes)
    // The spend still displays, and no cost deduction sneaks into the grade.
    #expect(model.currentWeek.totalCost == 42)
    if case .graded(_, _, let deductions) = model.currentWeek.result {
        #expect(!deductions.contains { $0.metric == .costPerShipped })
    }
}

@Test func costPerShippedIsWeeklySigmaOverShippedCount() {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), status: .completed, cost: 10),
        snapshot(endedAt: date(2026, 7, 14), status: .completed, cost: 20),
        snapshot(endedAt: date(2026, 7, 15), status: .archived, cost: 5)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    // Σ cost (35, including the unshipped session's spend) / 2 shipped.
    #expect(model.currentWeek.costPerShipped == .graded(17.5))
}

// Baseline = the user's own trailing-4-week median; even count → mean of the
// middle two.
@Test func baselineIsMedianOfTrailingFourWeeks() throws {
    var snapshots: [SessionAnalyticsSnapshot] = []
    // Week −1: clean → 100. Week −2: 2% errors → 95. Week −3: 12% errors →
    // 90. Week −4: 12% errors → 90.
    let errorsByWeek = [0, 2, 12, 12]
    for (index, errors) in errorsByWeek.enumerated() {
        let monday = utc.date(byAdding: .weekOfYear, value: -(index + 1), to: currentWeekMonday)!
        snapshots.append(snapshot(
            endedAt: monday.addingTimeInterval(3600),
            status: .completed,
            apiErrors: errors, apiRequests: 100, cost: 4))
    }
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)

    #expect(model.priorWeeks.count == 4)
    #expect(model.baseline.weeksAvailable == 4)
    #expect(model.baseline.medianScore == 92.5) // (95 + 90) / 2
    let medianErrorRate = try #require(model.baseline.medianApiErrorRate)
    #expect(abs(medianErrorRate - 0.07) < 1e-9) // (0.02 + 0.12) / 2
    #expect(model.baseline.medianCompactionsPerActiveHour == 0)
    #expect(model.baseline.medianCostPerShipped == 4)
}

@Test func baselineMedianOddCountTakesMiddle() {
    #expect(ScorecardModel.median([90, 100, 95]) == 95)
    #expect(ScorecardModel.median([]) == nil)
}

// A week with no snapshots is absent, not a zero — it neither appears in
// priorWeeks nor drags the baseline.
@Test func datalessWeeksExcludedFromBaseline() {
    let snapshots = [
        snapshot(
            endedAt: utc.date(byAdding: .weekOfYear, value: -1, to: currentWeekMonday)!,
            status: .completed),
        snapshot(
            endedAt: utc.date(byAdding: .weekOfYear, value: -3, to: currentWeekMonday)!,
            status: .completed)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    #expect(model.priorWeeks.count == 2)
    #expect(model.baseline.weeksAvailable == 2)
    #expect(model.baseline.medianScore == 100)
}

// An ungraded (sub-floor) prior week is present in the list but contributes
// nothing to the baseline medians.
@Test func insufficientDataWeeksExcludedFromBaselineMedians() {
    let snapshots = [
        snapshot(
            endedAt: utc.date(byAdding: .weekOfYear, value: -1, to: currentWeekMonday)!,
            prompts: 2),
        snapshot(
            endedAt: utc.date(byAdding: .weekOfYear, value: -2, to: currentWeekMonday)!,
            status: .completed, prompts: 10)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    #expect(model.priorWeeks.count == 2)
    #expect(model.baseline.weeksAvailable == 1)
}

// The minimum-sample floor applies at weekly grain through the same function:
// a week whose summed prompts are below the floor is insufficient data, while
// sessions-shipped (a plain count on a separate surface) still reports.
@Test func weeklySigmaUnderFivePromptsIsInsufficientData() {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), status: .completed, prompts: 2),
        snapshot(endedAt: date(2026, 7, 14), prompts: 2)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    #expect(model.currentWeek.result == .insufficientData(promptCount: 4))
    #expect(model.currentWeek.sessionsShipped == 1)
}

// Sub-floor sessions' raws still sum into the weekly denominators and
// numerators — splitting work into tiny sessions can't dodge the rollup.
@Test func subFloorSessionRawsStillSumIntoWeek() {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), compactions: 4, activeSeconds: 1800, prompts: 2),
        snapshot(endedAt: date(2026, 7, 14), compactions: 0, activeSeconds: 1800, prompts: 10)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    // Σ prompts = 12 ≥ floor; Σ = 4 compactions / 1.0 active hour → −20.
    guard case .graded(let score, _, let deductions) = model.currentWeek.result else {
        Issue.record("expected graded week")
        return
    }
    #expect(deductions.first?.points == 20)
    #expect(score == 80)
}

@Test func emptySnapshotsBuildEmptyModel() {
    let model = ScorecardModel.build(snapshots: [], now: now, calendar: utc)
    #expect(model.currentWeek.result == .insufficientData(promptCount: 0))
    #expect(model.currentWeek.sessionsShipped == 0)
    #expect(model.currentWeek.costPerShipped == .insufficientOutcomes)
    #expect(model.currentWeek.sessionCount == 0)
    #expect(model.priorWeeks.isEmpty)
    #expect(model.baseline == .empty)
    #expect(model.currentWeekSessions.isEmpty)
}

// MARK: - v2 combined score wiring (#699)

private func mergedAttribution(
    prURL: String,
    mergedAt: Date,
    reverts: [PRRevertRecord]? = nil
) -> PRSessionAttribution {
    PRSessionAttribution(
        prURL: prURL,
        repoNameWithOwner: "corveil/crow",
        prNumber: 1,
        sessionIDs: [UUID()],
        state: "MERGED",
        mergedAt: mergedAt,
        firstSeenAt: mergedAt.addingTimeInterval(-86_400),
        updatedAt: mergedAt,
        reverts: reverts
    )
}

// The combined score appears on the current week, built from the week's
// shipped snapshots and the attributions' rework signals.
@Test func combinedScoreAppearsOnCurrentWeek() throws {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), status: .completed),
        snapshot(endedAt: date(2026, 7, 14), status: .archived)
    ]
    let attributions = [mergedAttribution(
        prURL: "https://github.com/corveil/crow/pull/1",
        mergedAt: date(2026, 7, 14),
        reverts: [PRRevertRecord(
            revertedCommitSHA: "abc1234", revertCommitSHA: "def5678",
            detectedAt: date(2026, 7, 15))]
    )]
    let model = ScorecardModel.build(
        snapshots: snapshots, attributions: attributions, now: now, calendar: utc)

    guard case .scored(let factors) = model.currentWeek.combined else {
        Issue.record("expected scored combined result")
        return
    }
    #expect(factors.shippedCount == 1)
    #expect(factors.rework.mergedCount == 1)
    #expect(factors.rework.revertCount == 1)
    #expect(factors.gradeScore == 100)
    // hygiene = (1−0.25)¹ × mergeRate factor (rate 1.0 → 1.0) = 0.75
    #expect(abs(factors.hygieneFactor - 0.75) < 1e-12)
    #expect(abs(factors.value - 0.75) < 1e-12)
}

// The v1 surfaces are computed identically with and without attributions —
// the combined score is an additional surface, never an input to the grade,
// the shipped count, or their baselines.
@Test func v1SurfacesUnchangedByAttributions() {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), status: .completed, apiErrors: 12, apiRequests: 100, cost: 10),
        snapshot(
            endedAt: utc.date(byAdding: .weekOfYear, value: -1, to: currentWeekMonday)!,
            status: .completed)
    ]
    let attributions = [mergedAttribution(
        prURL: "https://github.com/corveil/crow/pull/1",
        mergedAt: date(2026, 7, 14),
        reverts: [PRRevertRecord(
            revertedCommitSHA: "abc1234", revertCommitSHA: "def5678",
            detectedAt: date(2026, 7, 15))]
    )]

    let with = ScorecardModel.build(
        snapshots: snapshots, attributions: attributions, now: now, calendar: utc)
    let without = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)

    #expect(with.currentWeek.result == without.currentWeek.result)
    #expect(with.currentWeek.input == without.currentWeek.input)
    #expect(with.currentWeek.sessionsShipped == without.currentWeek.sessionsShipped)
    #expect(with.currentWeek.costPerShipped == without.currentWeek.costPerShipped)
    #expect(with.baseline.medianScore == without.baseline.medianScore)
    #expect(with.baseline.medianCostPerShipped == without.baseline.medianCostPerShipped)
    #expect(with.currentWeekSessions == without.currentWeekSessions)
}

// Weekly grain isolation: an attribution event lands in exactly the week that
// contains it, not in every week the record is visible from.
@Test func combinedScoreWeeklyGrainIsolation() throws {
    let priorMonday = utc.date(byAdding: .weekOfYear, value: -1, to: currentWeekMonday)!
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), status: .completed),
        snapshot(endedAt: priorMonday.addingTimeInterval(3600), status: .completed)
    ]
    // Merged and reverted in the PRIOR week only.
    let attributions = [mergedAttribution(
        prURL: "https://github.com/corveil/crow/pull/1",
        mergedAt: priorMonday.addingTimeInterval(7200),
        reverts: [PRRevertRecord(
            revertedCommitSHA: "abc1234", revertCommitSHA: "def5678",
            detectedAt: priorMonday.addingTimeInterval(10_800))]
    )]
    let model = ScorecardModel.build(
        snapshots: snapshots, attributions: attributions, now: now, calendar: utc)

    let current = try #require({
        guard case .scored(let f) = model.currentWeek.combined else { return nil }
        return f
    }() as CombinedScore.Factors?)
    #expect(current.rework == .empty)
    #expect(current.hygieneFactor == 1.0)

    let prior = try #require({
        guard case .scored(let f) = model.priorWeeks[0].combined else { return nil }
        return f
    }() as CombinedScore.Factors?)
    #expect(prior.rework.mergedCount == 1)
    #expect(prior.rework.revertCount == 1)
}

// The baseline's median combined score includes a scored zero-shipped week —
// a present zero IS a combined score (unlike cost-per-shipped, which has no
// value for such a week).
@Test func baselineMedianCombinedScoreIncludesZeroShippedWeeks() throws {
    var snapshots: [SessionAnalyticsSnapshot] = []
    // Week −1: 2 shipped (clean grade 100 → value 2.0). Week −2: 0 shipped
    // (graded, value 0). Week −3: 1 shipped (value 1.0).
    for (offset, shippedCount) in [(1, 2), (2, 0), (3, 1)] {
        let monday = utc.date(byAdding: .weekOfYear, value: -offset, to: currentWeekMonday)!
        if shippedCount == 0 {
            snapshots.append(snapshot(endedAt: monday.addingTimeInterval(3600), status: .archived))
        } else {
            for index in 0..<shippedCount {
                snapshots.append(snapshot(
                    endedAt: monday.addingTimeInterval(Double(index + 1) * 3600),
                    status: .completed))
            }
        }
    }
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    #expect(model.baseline.medianCombinedScore == 1.0) // median of {2, 0, 1}
}

// Displayed-not-graded stats are Σ over the week; churn is Σ removed / Σ added.
@Test func displayedStatsSumAcrossTheWeek() {
    let snapshots = [
        snapshot(endedAt: date(2026, 7, 13), cost: 1.5, linesAdded: 100, linesRemoved: 40, commits: 2),
        snapshot(endedAt: date(2026, 7, 14), cost: 2.5, linesAdded: 100, linesRemoved: 10, commits: 3)
    ]
    let model = ScorecardModel.build(snapshots: snapshots, now: now, calendar: utc)
    #expect(model.currentWeek.totalCost == 4)
    #expect(model.currentWeek.activeTimeSeconds == 7200)
    #expect(model.currentWeek.commitCount == 5)
    #expect(model.currentWeek.churnHint == 0.25)
}
