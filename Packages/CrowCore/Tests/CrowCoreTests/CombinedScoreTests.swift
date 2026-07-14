import Foundation
import Testing
@testable import CrowCore

// #699 (ADR 0008 v2, follow-up 11): the combined multiplicative score —
// alignment-weighted throughput × efficiency multiplier, weekly grain only.

/// Fixed UTC ISO-8601 calendar so windowing is deterministic on any machine
/// (including Linux CI). Duplicated from EfficiencyScorecardTests, where the
/// helpers are file-private.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .iso8601)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// The ISO week Monday 2026-07-13 00:00 UTC ..< Monday 2026-07-20 00:00 UTC.
private let week = DateInterval(start: date(2026, 7, 13, 0), end: date(2026, 7, 20, 0))

private func snapshot(
    status: SessionStatus = .completed,
    alignmentWeight: Double? = nil,
    prompts: Int = 10
) -> SessionAnalyticsSnapshot {
    SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: date(2026, 7, 15),
        status: status,
        analytics: SessionAnalytics(activeTimeSeconds: 3600, promptCount: prompts),
        compactionCount: 0,
        alignmentWeight: alignmentWeight
    )
}

private func attribution(
    prURL: String,
    state: String = "MERGED",
    mergedAt: Date? = nil,
    closedAt: Date? = nil,
    reverts: [PRRevertRecord]? = nil,
    postMergeFixes: [PostMergeFixRecord]? = nil
) -> PRSessionAttribution {
    PRSessionAttribution(
        prURL: prURL,
        repoNameWithOwner: "corveil/crow",
        prNumber: 1,
        sessionIDs: [UUID()],
        state: state,
        mergedAt: mergedAt,
        firstSeenAt: date(2026, 7, 1),
        updatedAt: date(2026, 7, 15),
        closedAt: closedAt,
        reverts: reverts,
        postMergeFixes: postMergeFixes
    )
}

private func fix(detectedAt: Date) -> PostMergeFixRecord {
    PostMergeFixRecord(fixPRURL: "https://github.com/corveil/crow/pull/999", overlappingFileCount: 1, detectedAt: detectedAt)
}

private func graded(_ score: Int) -> EfficiencyGrading.GradeResult {
    .graded(score: score, letter: EfficiencyGrading.letter(forScore: score), deductions: [])
}

private func factors(_ result: CombinedScore.WeeklyResult) -> CombinedScore.Factors? {
    guard case .scored(let factors) = result else { return nil }
    return factors
}

// The reason the score is multiplicative (ADR 0008): a high-throughput week
// with terrible hygiene must score BELOW a modest clean week — waste cannot
// be bought back with volume, which an additive combination would allow.
@Test func multiplicativeDragDownBeatsVolume() throws {
    let distinctReverts = (1...4).map { index in
        PRRevertRecord(revertedCommitSHA: "sha\(index)", revertCommitSHA: "rev\(index)", detectedAt: date(2026, 7, 15))
    }
    let dirty = CombinedScore.weeklyRework(
        attributions: [attribution(
            prURL: "https://github.com/corveil/crow/pull/1",
            mergedAt: date(2026, 7, 14),
            reverts: distinctReverts
        )],
        week: week
    )
    #expect(dirty.revertCount == 4)

    let highVolumeBadHygiene = CombinedScore.weeklyScore(
        snapshots: (1...10).map { _ in snapshot() },
        gradeResult: graded(70),
        rework: dirty
    )
    let modestClean = CombinedScore.weeklyScore(
        snapshots: (1...3).map { _ in snapshot() },
        gradeResult: graded(95),
        rework: .empty
    )

    let dirtyValue = try #require(factors(highVolumeBadHygiene)).value
    let cleanValue = try #require(factors(modestClean)).value
    // 10 × (0.70 × 0.75⁴ ≈ 0.2215) ≈ 2.21 < 3 × 0.95 = 2.85. An additive
    // combination of the same inputs would rank the dirty week first.
    #expect(dirtyValue < cleanValue)
}

// Alignment weight raises on-goal work: same shipped count, higher weight →
// strictly higher score.
@Test func alignmentRaisesOnGoalWork() throws {
    let onGoal = CombinedScore.weeklyScore(
        snapshots: (1...3).map { _ in
            snapshot(alignmentWeight: AlignmentWeight.highPriorityBase * AlignmentWeight.onGoalMultiplier)
        },
        gradeResult: graded(90),
        rework: .empty
    )
    let untagged = CombinedScore.weeklyScore(
        snapshots: (1...3).map { _ in snapshot(alignmentWeight: nil) },
        gradeResult: graded(90),
        rework: .empty
    )

    let onGoalFactors = try #require(factors(onGoal))
    let untaggedFactors = try #require(factors(untagged))
    #expect(onGoalFactors.value > untaggedFactors.value)
    #expect(abs(onGoalFactors.alignmentFactor - 1.95) < 1e-9)
    #expect(untaggedFactors.alignmentFactor == AlignmentWeight.neutral)
}

// The score must stay explainable: it decomposes into the three inspectable
// factors shown on the card.
@Test func decompositionIdentity() throws {
    let result = CombinedScore.weeklyScore(
        snapshots: [
            snapshot(alignmentWeight: 1.5),
            snapshot(alignmentWeight: 1.2),
            snapshot(alignmentWeight: nil),
            snapshot(status: .archived, alignmentWeight: 2.1) // not shipped — excluded
        ],
        gradeResult: graded(85),
        rework: CombinedScore.WeeklyRework(
            mergedCount: 3, closedWithoutMergeCount: 1, revertCount: 1, postMergeFixCount: 2)
    )
    let f = try #require(factors(result))
    #expect(f.shippedCount == 3)
    #expect(abs(f.weightedThroughput - 3.7) < 1e-9)
    #expect(abs(f.value - f.weightedThroughput * f.efficiencyMultiplier) < 1e-12)
    #expect(abs(f.value - Double(f.shippedCount) * f.alignmentFactor * f.efficiencyMultiplier) < 1e-9)
}

// nil alignment weight (pre-#696 snapshots) is exactly neutral — a nil-weight
// week scores identically to an explicit-1.0 week.
@Test func nilAlignmentWeightIsNeutral() throws {
    let nilWeight = CombinedScore.weeklyScore(
        snapshots: [snapshot(alignmentWeight: nil)], gradeResult: graded(90), rework: .empty)
    let explicitNeutral = CombinedScore.weeklyScore(
        snapshots: [snapshot(alignmentWeight: 1.0)], gradeResult: graded(90), rework: .empty)
    #expect(nilWeight == explicitNeutral)
}

// A graded week that shipped nothing is a legitimate zero at weekly grain —
// scored, value 0, with a neutral alignment factor so the decomposition
// identity holds without dividing by zero.
@Test func zeroShippedWeekScoresZero() throws {
    let result = CombinedScore.weeklyScore(
        snapshots: [snapshot(status: .archived)], gradeResult: graded(100), rework: .empty)
    let f = try #require(factors(result))
    #expect(f.shippedCount == 0)
    #expect(f.value == 0)
    #expect(f.alignmentFactor == AlignmentWeight.neutral)
}

// No grade → no efficiency multiplier → no combined score. The weekly grade's
// minimum-sample floor passes straight through.
@Test func insufficientDataPassthrough() {
    let result = CombinedScore.weeklyScore(
        snapshots: [snapshot(prompts: 3)],
        gradeResult: .insufficientData(promptCount: 3),
        rework: .empty
    )
    #expect(result == .insufficientData(promptCount: 3))
}

// Absence of data is never punished: no attributions (and therefore a nil
// merge rate) leave hygiene fully neutral.
@Test func hygieneNeutralWithNoAttributions() {
    #expect(CombinedScore.WeeklyRework.empty.mergeRate == nil)
    #expect(CombinedScore.hygieneFactor(rework: .empty) == 1.0)
}

// Exact hygiene formula, and its bounds: each factor is in (0, 1], so even a
// pathological week stays strictly above 0 and never above 1.
@Test func hygieneFactorFormulaAndBounds() {
    let rework = CombinedScore.WeeklyRework(
        mergedCount: 1, closedWithoutMergeCount: 1, revertCount: 1, postMergeFixCount: 2)
    // (1−0.25)¹ × (1−0.10)² × (1 − 0.5×(1−0.5)) = 0.75 × 0.81 × 0.75
    let expected = 0.75 * 0.81 * 0.75
    #expect(abs(CombinedScore.hygieneFactor(rework: rework) - expected) < 1e-12)

    let pathological = CombinedScore.WeeklyRework(
        mergedCount: 0, closedWithoutMergeCount: 5, revertCount: 10, postMergeFixCount: 10)
    let factor = CombinedScore.hygieneFactor(rework: pathological)
    #expect(factor > 0)
    #expect(factor <= 1)
}

// Weekly rework windowing: half-open week membership matching the scorecard's
// bucketing, current-state gating for merged vs. closed, nil merge rate when
// nothing resolved.
@Test func weeklyReworkWindowing() {
    let attributions = [
        // Merged inside the week; revert detected at the exact week start
        // (included) and another at the exact week end (excluded).
        attribution(
            prURL: "https://github.com/corveil/crow/pull/1",
            mergedAt: date(2026, 7, 13, 0, 0),
            reverts: [
                PRRevertRecord(revertedCommitSHA: "in", revertCommitSHA: "r1", detectedAt: week.start),
                PRRevertRecord(revertedCommitSHA: "out", revertCommitSHA: "r2", detectedAt: week.end)
            ]
        ),
        // Merged the week before — outside.
        attribution(prURL: "https://github.com/corveil/crow/pull/2", mergedAt: date(2026, 7, 10)),
        // Reopened-then-merged: state MERGED with a stale closedAt in-window —
        // counts as merged only, never closed.
        attribution(
            prURL: "https://github.com/corveil/crow/pull/3",
            mergedAt: date(2026, 7, 16),
            closedAt: date(2026, 7, 14)
        ),
        // Currently CLOSED, closed in-window.
        attribution(
            prURL: "https://github.com/corveil/crow/pull/4",
            state: "CLOSED",
            closedAt: date(2026, 7, 15),
            postMergeFixes: [fix(detectedAt: date(2026, 7, 15))]
        )
    ]

    let rework = CombinedScore.weeklyRework(attributions: attributions, week: week)
    #expect(rework.mergedCount == 2)
    #expect(rework.closedWithoutMergeCount == 1)
    #expect(rework.revertCount == 1)
    #expect(rework.postMergeFixCount == 1)
    #expect(rework.mergeRate == 2.0 / 3.0)

    // A week that resolved nothing has no merge rate — neutral, not 0 or 1.
    let quietWeek = DateInterval(start: date(2026, 6, 1, 0), end: date(2026, 6, 8, 0))
    #expect(CombinedScore.weeklyRework(attributions: attributions, week: quietWeek).mergeRate == nil)
}

// The efficiency multiplier is a pure discount: a perfect week multiplies by
// exactly 1, and nothing can push it above 1.
@Test func efficiencyMultiplierNeverExceedsOne() throws {
    let perfect = CombinedScore.weeklyScore(
        snapshots: [snapshot()], gradeResult: graded(100), rework: .empty)
    let f = try #require(factors(perfect))
    #expect(f.efficiencyMultiplier == 1.0)
    #expect(f.value == f.weightedThroughput)
}
