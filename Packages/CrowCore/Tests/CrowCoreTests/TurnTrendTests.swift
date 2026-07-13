import Testing
@testable import CrowCore

/// Tests for `EfficiencyGrading.perTurnInputTrendSlope` (issue #695): the
/// rising-vs-flat distinction the per-turn reader exists to enable.

private func turns(_ inputTokens: [Int]) -> [TurnAnalytics] {
    inputTokens.enumerated().map { TurnAnalytics(turnIndex: $0.offset, inputTokens: $0.element) }
}

@Test func risingPerTurnInputHasPositiveSlope() {
    let slope = EfficiencyGrading.perTurnInputTrendSlope(turns([10_000, 20_000, 30_000, 40_000]))
    #expect(slope == 10_000)
}

@Test func flatPerTurnInputHasZeroSlope() {
    let slope = EfficiencyGrading.perTurnInputTrendSlope(turns([20_000, 20_000, 20_000, 20_000]))
    #expect(slope == 0)
}

@Test func fallingPerTurnInputHasNegativeSlope() throws {
    let slope = try #require(EfficiencyGrading.perTurnInputTrendSlope(turns([40_000, 30_000, 10_000])))
    #expect(slope < 0)
}

@Test func fewerThanThreeTurnsIsNoTrend() {
    #expect(EfficiencyGrading.perTurnInputTrendSlope(turns([])) == nil)
    #expect(EfficiencyGrading.perTurnInputTrendSlope(turns([10_000])) == nil)
    #expect(EfficiencyGrading.perTurnInputTrendSlope(turns([10_000, 50_000])) == nil)
}

@Test func noisyButRisingSequenceHasPositiveSlope() throws {
    let slope = try #require(
        EfficiencyGrading.perTurnInputTrendSlope(turns([12_000, 9_000, 25_000, 18_000, 40_000, 35_000]))
    )
    #expect(slope > 0)
}
