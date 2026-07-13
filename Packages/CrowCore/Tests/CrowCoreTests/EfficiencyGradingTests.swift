import Foundation
import Testing
@testable import CrowCore

// #710 (ADR 0008 v1): the single penalty-point grading function. Session and
// weekly grades share it — it only ever takes raw numerators/denominators.

private func deduction(
    _ result: EfficiencyGrading.GradeResult,
    _ metric: EfficiencyGrading.Metric
) -> EfficiencyGrading.Deduction? {
    guard case .graded(_, _, let deductions) = result else { return nil }
    return deductions.first { $0.metric == metric }
}

private func score(_ result: EfficiencyGrading.GradeResult) -> Int? {
    guard case .graded(let score, _, _) = result else { return nil }
    return score
}

@Test func cleanSessionGradesAWithNoDeductions() {
    let input = EfficiencyGrading.GradeInput(
        activeTimeSeconds: 3600,
        inputTokens: 5_000,
        promptCount: 10,
        cacheReadTokens: 80_000,
        cacheCreationTokens: 5_000,
        apiErrorCount: 0,
        apiRequestCount: 100
    )
    guard case .graded(let score, let letter, let deductions) = EfficiencyGrading.grade(input) else {
        Issue.record("expected graded result")
        return
    }
    #expect(score == 100)
    #expect(letter == .a)
    #expect(deductions.isEmpty)
}

// The ADR's canonical coachable sentence: "C — 3 compactions (−15), 12% API
// error rate (−10)". 100 − 15 − 10 = 75 → C. This fixture is the calibration
// anchor for the tuning constants.
@Test func adrCanonicalExampleGradesC() {
    let input = EfficiencyGrading.GradeInput(
        compactionCount: 3,
        activeTimeSeconds: 3600, // 1 active hour
        inputTokens: 10_000,
        promptCount: 10,
        cacheReadTokens: 80_000,
        cacheCreationTokens: 5_000,
        apiErrorCount: 12,
        apiRequestCount: 100
    )
    guard case .graded(let score, let letter, let deductions) = EfficiencyGrading.grade(input) else {
        Issue.record("expected graded result")
        return
    }
    #expect(score == 75)
    #expect(letter == .c)
    #expect(deductions.count == 2)
    #expect(deductions[0] == EfficiencyGrading.Deduction(
        metric: .compactions, points: 15, label: "3 compactions (3.0/active hr)"))
    #expect(deductions[1] == EfficiencyGrading.Deduction(
        metric: .apiErrorRate, points: 10, label: "12% API error rate"))
}

// Compactions are normalized per ACTIVE hour, not per session: the same 3
// compactions cost half as much over twice the active time.
@Test func compactionsNormalizedPerActiveHour() {
    func input(activeSeconds: Double) -> EfficiencyGrading.GradeInput {
        EfficiencyGrading.GradeInput(
            compactionCount: 3, activeTimeSeconds: activeSeconds, promptCount: 10)
    }
    let overTwoHours = deduction(EfficiencyGrading.grade(input(activeSeconds: 7200)), .compactions)
    #expect(overTwoHours?.points == 8) // 1.5/hr × 5, rounded

    let overHalfHour = deduction(EfficiencyGrading.grade(input(activeSeconds: 1800)), .compactions)
    #expect(overHalfHour?.points == EfficiencyGrading.Tuning.compactionDeductionCap) // 6/hr × 5 = 30
}

// Zero recorded active time uses the denominator floor — capped deduction, no
// division by zero, no infinite rate.
@Test func zeroActiveTimeUsesFloor() {
    let input = EfficiencyGrading.GradeInput(
        compactionCount: 4, activeTimeSeconds: 0, promptCount: 10)
    let compaction = deduction(EfficiencyGrading.grade(input), .compactions)
    #expect(compaction?.points == EfficiencyGrading.Tuning.compactionDeductionCap)
    #expect(input.compactionsPerActiveHour == 16) // 4 / 0.25h floor
}

@Test func zeroCompactionsEmitNoDeduction() {
    let input = EfficiencyGrading.GradeInput(activeTimeSeconds: 60, promptCount: 10)
    #expect(deduction(EfficiencyGrading.grade(input), .compactions) == nil)
}

@Test func contextPressureBands() {
    func input(tokensPerPrompt: Int) -> EfficiencyGrading.GradeInput {
        EfficiencyGrading.GradeInput(
            activeTimeSeconds: 3600, inputTokens: tokensPerPrompt * 5, promptCount: 5)
    }
    #expect(deduction(EfficiencyGrading.grade(input(tokensPerPrompt: 20_000)), .contextPressure) == nil)

    let light = deduction(EfficiencyGrading.grade(input(tokensPerPrompt: 20_001)), .contextPressure)
    #expect(light?.points == 5)
    #expect(light?.label == "20.0K input tokens/prompt")

    #expect(deduction(EfficiencyGrading.grade(input(tokensPerPrompt: 50_000)), .contextPressure)?.points == 5)
    #expect(deduction(EfficiencyGrading.grade(input(tokensPerPrompt: 50_001)), .contextPressure)?.points == 10)
    #expect(deduction(EfficiencyGrading.grade(input(tokensPerPrompt: 100_001)), .contextPressure)?.points == 15)
}

// Higher cache-read share of carried context is BETTER (ADR 0008 deliberately
// grades the opposite polarity of #648's original framing).
@Test func cacheHitRatioBandsHigherIsBetter() {
    func input(cacheRead: Int) -> EfficiencyGrading.GradeInput {
        EfficiencyGrading.GradeInput(
            activeTimeSeconds: 3600, inputTokens: 1_000, promptCount: 10,
            cacheReadTokens: cacheRead, cacheCreationTokens: 0)
    }
    #expect(deduction(EfficiencyGrading.grade(input(cacheRead: 700)), .cacheHitRatio) == nil) // 0.7 good

    let fair = deduction(EfficiencyGrading.grade(input(cacheRead: 500)), .cacheHitRatio)
    #expect(fair?.points == 5)
    #expect(fair?.label == "50% cache hit ratio")

    #expect(deduction(EfficiencyGrading.grade(input(cacheRead: 300)), .cacheHitRatio)?.points == 10)
    #expect(deduction(EfficiencyGrading.grade(input(cacheRead: 0)), .cacheHitRatio)?.points == 15)
}

// A session whose telemetry recorded prompts but no token traffic has no
// context to cache — the metric doesn't apply, rather than penalizing a 0%.
@Test func cacheRatioSkippedWithNoTokenTraffic() {
    let input = EfficiencyGrading.GradeInput(activeTimeSeconds: 3600, promptCount: 10)
    #expect(deduction(EfficiencyGrading.grade(input), .cacheHitRatio) == nil)
}

@Test func apiErrorRateBands() {
    func input(errors: Int) -> EfficiencyGrading.GradeInput {
        EfficiencyGrading.GradeInput(
            activeTimeSeconds: 3600, promptCount: 10,
            apiErrorCount: errors, apiRequestCount: 100)
    }
    #expect(deduction(EfficiencyGrading.grade(input(errors: 1)), .apiErrorRate) == nil) // < 2% clean

    let moderate = deduction(EfficiencyGrading.grade(input(errors: 2)), .apiErrorRate)
    #expect(moderate?.points == 5)
    #expect(moderate?.label == "2% API error rate")

    #expect(deduction(EfficiencyGrading.grade(input(errors: 10)), .apiErrorRate)?.points == 5) // 10% is not > 10%
    #expect(deduction(EfficiencyGrading.grade(input(errors: 11)), .apiErrorRate)?.points == 10)
}

@Test func costPerShippedBandsAtWeeklyGrain() {
    func input(totalCost: Double, shipped: Int = 1) -> EfficiencyGrading.GradeInput {
        EfficiencyGrading.GradeInput(
            activeTimeSeconds: 3600, promptCount: 10,
            costContext: .init(totalCost: totalCost, sessionsShipped: shipped))
    }
    #expect(deduction(EfficiencyGrading.grade(input(totalCost: 5)), .costPerShipped) == nil)

    let light = deduction(EfficiencyGrading.grade(input(totalCost: 10)), .costPerShipped)
    #expect(light?.points == 5)
    #expect(light?.label == "$10.00 per shipped session")

    #expect(deduction(EfficiencyGrading.grade(input(totalCost: 20)), .costPerShipped)?.points == 10)
    #expect(deduction(EfficiencyGrading.grade(input(totalCost: 31)), .costPerShipped)?.points == 15)
    // Σ / shipped, not per session: $40 across 8 shipped = $5 → clean.
    #expect(deduction(EfficiencyGrading.grade(input(totalCost: 40, shipped: 8)), .costPerShipped) == nil)
}

// Cost is weekly-grain-only: session-grain inputs carry no cost context, so
// even an expensive session takes no cost deduction.
@Test func costMetricSkippedAtSessionGrain() {
    let snapshot = SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: Date(timeIntervalSince1970: 1_752_000_000),
        status: .completed,
        analytics: SessionAnalytics(
            totalCost: 500, activeTimeSeconds: 3600, promptCount: 10))
    let input = EfficiencyGrading.input(for: snapshot)
    #expect(input.costContext == nil)
    #expect(deduction(EfficiencyGrading.grade(input), .costPerShipped) == nil)
}

// A zero-shipped week is "insufficient outcomes" — the cost metric is skipped
// entirely, never divided by a fallback.
@Test func zeroShippedWeekSkipsCostMetric() {
    let input = EfficiencyGrading.GradeInput(
        activeTimeSeconds: 3600, promptCount: 10,
        costContext: .init(totalCost: 1_000, sessionsShipped: 0))
    #expect(deduction(EfficiencyGrading.grade(input), .costPerShipped) == nil)
}

// The anti-farming minimum-sample floor: < 5 prompts is not graded.
@Test func underFivePromptsIsInsufficientData() {
    let four = EfficiencyGrading.grade(EfficiencyGrading.GradeInput(promptCount: 4))
    #expect(four == .insufficientData(promptCount: 4))

    let five = EfficiencyGrading.grade(EfficiencyGrading.GradeInput(promptCount: 5))
    #expect(score(five) == 100)
}

// Pre-#691 snapshots have no compaction counter; nil is zero, not a penalty.
@Test func nilCompactionCountTreatedAsZero() {
    let snapshot = SessionAnalyticsSnapshot(
        sessionID: UUID(),
        endedAt: Date(timeIntervalSince1970: 1_752_000_000),
        status: .archived,
        analytics: SessionAnalytics(activeTimeSeconds: 3600, promptCount: 10),
        compactionCount: nil)
    let input = EfficiencyGrading.input(for: snapshot)
    #expect(input.compactionCount == 0)
    #expect(deduction(EfficiencyGrading.grade(input), .compactions) == nil)
}

// No combined number, behaviorally: throughput never scales the grade. With
// cost in the clean band, shipping 1 vs 5 sessions yields the identical grade.
@Test func throughputNeverScalesTheGrade() {
    func input(shipped: Int) -> EfficiencyGrading.GradeInput {
        EfficiencyGrading.GradeInput(
            compactionCount: 3, activeTimeSeconds: 3600, promptCount: 10,
            costContext: .init(totalCost: 4, sessionsShipped: shipped))
    }
    #expect(EfficiencyGrading.grade(input(shipped: 1)) == EfficiencyGrading.grade(input(shipped: 5)))
}

@Test func letterCutoffs() {
    #expect(EfficiencyGrading.letter(forScore: 100) == .a)
    #expect(EfficiencyGrading.letter(forScore: 90) == .a)
    #expect(EfficiencyGrading.letter(forScore: 89) == .b)
    #expect(EfficiencyGrading.letter(forScore: 80) == .b)
    #expect(EfficiencyGrading.letter(forScore: 79) == .c)
    #expect(EfficiencyGrading.letter(forScore: 70) == .c)
    #expect(EfficiencyGrading.letter(forScore: 69) == .d)
    #expect(EfficiencyGrading.letter(forScore: 60) == .d)
    #expect(EfficiencyGrading.letter(forScore: 59) == .f)
    #expect(EfficiencyGrading.letter(forScore: 0) == .f)
}

// Deductions are ordered heaviest-first so the worst coaching lands on top.
@Test func deductionsSortedHeaviestFirst() {
    let input = EfficiencyGrading.GradeInput(
        compactionCount: 3, activeTimeSeconds: 3600,
        inputTokens: 300_000, promptCount: 5, // 60K/prompt → −10
        apiErrorCount: 2, apiRequestCount: 100) // 2% → −5
    guard case .graded(_, _, let deductions) = EfficiencyGrading.grade(input) else {
        Issue.record("expected graded result")
        return
    }
    let points = deductions.map(\.points)
    #expect(points == points.sorted(by: >))
    #expect(deductions.first?.metric == .compactions)
}
