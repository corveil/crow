import Foundation

/// Cost per shipped session — the only outcome-touching grade input, computed
/// at weekly grain only (ADR 0008). A week that shipped nothing is
/// "insufficient outcomes"; the total is never divided by a fallback.
public enum CostPerShipped: Equatable, Sendable {
    case graded(Double)
    case insufficientOutcomes
}

/// One week of the scorecard: the re-aggregated efficiency grade, the
/// sessions-shipped throughput count, and the displayed-not-graded context
/// stats. Grade and throughput are separate surfaces — nothing here combines
/// them (no combined number exists in v1, ADR 0008).
public struct WeeklyScorecard: Equatable, Sendable {
    public let weekStart: Date
    /// Grade over the week's summed raws (`EfficiencyGrading.weeklyInput`),
    /// never an average of per-session grades.
    public let result: EfficiencyGrading.GradeResult
    /// The summed raws behind `result`; exposes the derived rates for the
    /// self-comparison baseline and display.
    public let input: EfficiencyGrading.GradeInput
    /// Throughput headline: count of outcome-flagged (`.completed`) snapshots.
    public let sessionsShipped: Int
    public let costPerShipped: CostPerShipped
    public let sessionCount: Int
    // Displayed, not graded (Σ over the week):
    public let totalCost: Double
    public let activeTimeSeconds: Double
    public let commitCount: Int
    /// `Σ linesRemoved / max(1, Σ linesAdded)` — informational only, too weak
    /// as a rework proxy to grade (ADR 0008).
    public let churnHint: Double
}

/// The user's own trailing 4-week medians — the private "this week vs. your
/// normal" comparison. Nil fields mean no graded prior weeks supplied a value.
public struct ScorecardBaseline: Equatable, Sendable {
    /// Graded prior weeks found (0...4). Below
    /// `EfficiencyGrading.Tuning.minimumBaselineWeeks` the view shows
    /// "baseline building" instead of comparisons.
    public let weeksAvailable: Int
    public let medianScore: Double?
    public let medianCompactionsPerActiveHour: Double?
    public let medianInputTokensPerPrompt: Double?
    public let medianCacheHitRatio: Double?
    public let medianApiErrorRate: Double?
    /// Median over prior weeks that actually shipped (zero-shipped weeks have
    /// no cost-per-shipped value to enter the median).
    public let medianCostPerShipped: Double?

    public static let empty = ScorecardBaseline(
        weeksAvailable: 0,
        medianScore: nil,
        medianCompactionsPerActiveHour: nil,
        medianInputTokensPerPrompt: nil,
        medianCacheHitRatio: nil,
        medianApiErrorRate: nil,
        medianCostPerShipped: nil
    )
}

/// Per-session drill-down row for the current week.
public struct SessionGradeRow: Equatable, Sendable, Identifiable {
    public var id: UUID { sessionID }
    public let sessionID: UUID
    public let endedAt: Date
    /// `status == .completed` — the ADR 0008 outcome flag.
    public let shipped: Bool
    public let result: EfficiencyGrading.GradeResult
    /// For the displayed-not-graded chips (cost, active time, commits, churn).
    public let analytics: SessionAnalytics
    /// Display-only context; never a grading denominator.
    public let wallClockDurationSeconds: Double?
}

/// The read-only scorecard model (ADR 0008 v1): built from persisted
/// `SessionAnalyticsSnapshot`s, pure and deterministic — `now` and the
/// calendar's time zone are injected, and nothing here reads a store or a
/// clock.
public struct ScorecardModel: Equatable, Sendable {
    public let currentWeek: WeeklyScorecard
    /// Up to the trailing 4 weeks, newest first; weeks with no snapshots are
    /// omitted (absence is not a zero).
    public let priorWeeks: [WeeklyScorecard]
    public let baseline: ScorecardBaseline
    /// Current week's sessions, newest first.
    public let currentWeekSessions: [SessionGradeRow]

    /// Buckets snapshots into ISO-8601 weeks (Monday start, locale-stable so
    /// the historical baseline doesn't shift with the user's locale) in the
    /// injected calendar's time zone, grades the current week over summed
    /// raws, and computes the trailing-4-week median baseline from the prior
    /// weeks.
    public static func build(
        snapshots: [SessionAnalyticsSnapshot],
        now: Date,
        calendar: Calendar
    ) -> ScorecardModel {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone

        let currentInterval = iso.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: now, duration: 7 * 86_400)

        let currentSnapshots = snapshots.filter { contains(currentInterval, $0.endedAt) }
        let currentWeek = weeklyScorecard(weekStart: currentInterval.start, snapshots: currentSnapshots)

        var priorWeeks: [WeeklyScorecard] = []
        for offset in 1...EfficiencyGrading.Tuning.baselineWeekCount {
            guard
                let weekDate = iso.date(byAdding: .weekOfYear, value: -offset, to: currentInterval.start),
                let interval = iso.dateInterval(of: .weekOfYear, for: weekDate)
            else { continue }
            let weekSnapshots = snapshots.filter { contains(interval, $0.endedAt) }
            guard !weekSnapshots.isEmpty else { continue }
            priorWeeks.append(weeklyScorecard(weekStart: interval.start, snapshots: weekSnapshots))
        }

        let rows = currentSnapshots
            .sorted { $0.endedAt > $1.endedAt }
            .map { snapshot in
                SessionGradeRow(
                    sessionID: snapshot.sessionID,
                    endedAt: snapshot.endedAt,
                    shipped: snapshot.status == .completed,
                    result: EfficiencyGrading.grade(EfficiencyGrading.input(for: snapshot)),
                    analytics: snapshot.analytics,
                    wallClockDurationSeconds: snapshot.wallClockDurationSeconds
                )
            }

        return ScorecardModel(
            currentWeek: currentWeek,
            priorWeeks: priorWeeks,
            baseline: baseline(from: priorWeeks),
            currentWeekSessions: rows
        )
    }

    /// Half-open week membership: `DateInterval.contains` is end-inclusive,
    /// which would put a snapshot ending exactly at Monday 00:00 into two
    /// adjacent week buckets.
    private static func contains(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }

    // MARK: - Weekly rollup

    static func weeklyScorecard(weekStart: Date, snapshots: [SessionAnalyticsSnapshot]) -> WeeklyScorecard {
        let input = EfficiencyGrading.weeklyInput(summing: snapshots)
        let shipped = input.costContext?.sessionsShipped ?? 0
        let totalCost = input.costContext?.totalCost ?? 0

        let costPerShipped: CostPerShipped = shipped > 0
            ? .graded(totalCost / Double(shipped))
            : .insufficientOutcomes

        let linesAdded = snapshots.reduce(0) { $0 + $1.analytics.linesAdded }
        let linesRemoved = snapshots.reduce(0) { $0 + $1.analytics.linesRemoved }

        return WeeklyScorecard(
            weekStart: weekStart,
            result: EfficiencyGrading.grade(input),
            input: input,
            sessionsShipped: shipped,
            costPerShipped: costPerShipped,
            sessionCount: snapshots.count,
            totalCost: totalCost,
            activeTimeSeconds: input.activeTimeSeconds,
            commitCount: snapshots.reduce(0) { $0 + $1.analytics.commitCount },
            churnHint: Double(linesRemoved) / Double(max(1, linesAdded))
        )
    }

    // MARK: - Baseline

    /// Medians over the graded prior weeks only — an ungraded (sub-floor) or
    /// absent week contributes nothing rather than a zero.
    static func baseline(from priorWeeks: [WeeklyScorecard]) -> ScorecardBaseline {
        var scores: [Double] = []
        var compactionRates: [Double] = []
        var contextPressures: [Double] = []
        var cacheRatios: [Double] = []
        var errorRates: [Double] = []
        var costsPerShipped: [Double] = []

        for week in priorWeeks {
            guard case .graded(let score, _, _) = week.result else { continue }
            scores.append(Double(score))
            compactionRates.append(week.input.compactionsPerActiveHour)
            contextPressures.append(week.input.inputTokensPerPrompt)
            cacheRatios.append(week.input.cacheHitRatio)
            errorRates.append(week.input.apiErrorRate)
            if case .graded(let cost) = week.costPerShipped {
                costsPerShipped.append(cost)
            }
        }

        return ScorecardBaseline(
            weeksAvailable: scores.count,
            medianScore: median(scores),
            medianCompactionsPerActiveHour: median(compactionRates),
            medianInputTokensPerPrompt: median(contextPressures),
            medianCacheHitRatio: median(cacheRatios),
            medianApiErrorRate: median(errorRates),
            medianCostPerShipped: median(costsPerShipped)
        )
    }

    /// Standard median: middle element, or the mean of the middle two for an
    /// even count. Nil for no values.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
