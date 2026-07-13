import Foundation

/// ADR 0008 v1 efficiency grading: a penalty-point deduction from 100 within a
/// single unit, mapped to A–F bands. Every deduction is labeled with its cause
/// so the grade is a coachable sentence, not a number.
///
/// There is exactly ONE grading function, and it takes raw numerators and
/// denominators (`GradeInput`), never grades: the per-session grade is
/// `grade(input(for: snapshot))` and the weekly grade is
/// `grade(weeklyInput(summing: snapshots))`. Averaging per-session grades is
/// structurally impossible here — no API accepts grades as input — which is
/// how the ADR's anti-session-splitting rollup rule is enforced.
///
/// The grade and the sessions-shipped throughput count are separate surfaces;
/// no combined number exists in v1 (ADR 0008).
public enum EfficiencyGrading {

    // MARK: - Tuning

    /// Grade bands and penalty weights. Every value here is a starting
    /// heuristic (ADR 0008) — a tunable prior under the binding 4-week
    /// calibration period. If real data says a threshold punishes legitimately
    /// hard sessions, the threshold moves; revise against real distributions,
    /// not taste.
    public enum Tuning {
        /// Sessions (or weekly sums) with fewer prompts than this are shown as
        /// "insufficient data", not graded — the anti-farming minimum-sample
        /// floor ("< ~5 prompts" in the ADR).
        public static let minimumGradablePromptCount = 5

        /// Letter cutoffs: score ≥ 90 → A, ≥ 80 → B, ≥ 70 → C, ≥ 60 → D, else F.
        public static let gradeACutoff = 90
        public static let gradeBCutoff = 80
        public static let gradeCCutoff = 70
        public static let gradeDCutoff = 60

        /// Compactions are the heaviest penalty, normalized per active hour
        /// (`activeTimeSeconds` is the authoritative clock — never wall-clock,
        /// never per-session, never per-outcome). Calibrated to the ADR's
        /// canonical example: 3 compactions in ~1 active hour → −15.
        public static let pointsPerCompactionPerActiveHour = 5.0
        public static let compactionDeductionCap = 30
        /// Floor (in hours) for the active-time denominator so a compaction in
        /// a minutes-long session doesn't produce an absurd rate, and so zero
        /// recorded active time never divides by zero.
        public static let activeHoursFloor = 0.25

        /// Context pressure (`inputTokens / max(1, promptCount)`): a
        /// per-session average threshold until per-turn data exists (ADR 0008
        /// follow-up 7).
        public static let contextPressureLightThreshold = 20_000.0  // above → −5
        public static let contextPressureMediumThreshold = 50_000.0 // above → −10
        public static let contextPressureHeavyThreshold = 100_000.0 // above → −15
        public static let contextPressureLightPoints = 5
        public static let contextPressureMediumPoints = 10
        public static let contextPressureHeavyPoints = 15

        /// Cache hit ratio (`cacheRead / max(1, input + cacheCreation)`),
        /// higher = better: a high cache-read share means context is carried
        /// via prompt cache instead of re-sent as fresh input. ADR: > 0.7 good.
        public static let cacheRatioGoodThreshold = 0.7   // at or above → 0
        public static let cacheRatioFairThreshold = 0.5   // at or above → −5
        public static let cacheRatioPoorThreshold = 0.3   // at or above → −10, below → −15
        public static let cacheRatioFairPoints = 5
        public static let cacheRatioPoorPoints = 10
        public static let cacheRatioBadPoints = 15

        /// API error rate: < 2% clean, > 10% heavy (ADR). The heavy value is
        /// pinned by the ADR's own example: "12% API error rate (−10)".
        public static let apiErrorRateCleanThreshold = 0.02
        public static let apiErrorRateHeavyThreshold = 0.10
        public static let apiErrorRateModeratePoints = 5
        public static let apiErrorRateHeavyPoints = 10

        /// Cost per shipped session — graded at weekly grain only
        /// (`Σ totalCost / sessionsShipped`). Pure prior with no ADR anchor;
        /// calibration will move these.
        public static let costPerShippedLightThreshold = 5.0   // above → −5
        public static let costPerShippedMediumThreshold = 15.0 // above → −10
        public static let costPerShippedHeavyThreshold = 30.0  // above → −15
        public static let costPerShippedLightPoints = 5
        public static let costPerShippedMediumPoints = 10
        public static let costPerShippedHeavyPoints = 15

        /// Trailing weeks below this count render the self-comparison baseline
        /// as "building" instead of a comparison (ADR cold-start consequence).
        public static let minimumBaselineWeeks = 2
        /// The baseline window: the user's own trailing 4-week median.
        public static let baselineWeekCount = 4
    }

    // MARK: - Types

    /// The graded metrics. Cost-per-shipped-session participates at weekly
    /// grain only.
    public enum Metric: String, Codable, Sendable, CaseIterable {
        case compactions
        case contextPressure
        case cacheHitRatio
        case apiErrorRate
        case costPerShipped
    }

    public enum LetterGrade: String, Codable, Sendable, CaseIterable {
        case a = "A", b = "B", c = "C", d = "D", f = "F"
    }

    /// One labeled, coachable penalty. The view renders "label (−points)",
    /// e.g. "3 compactions (3.0/active hr) −15".
    public struct Deduction: Equatable, Sendable {
        public let metric: Metric
        public let points: Int
        public let label: String

        public init(metric: Metric, points: Int, label: String) {
            self.metric = metric
            self.points = points
            self.label = label
        }
    }

    /// Raw numerators and denominators — the only input grading accepts.
    /// Session grain: one snapshot's raws with `costContext == nil` (cost is
    /// weekly-grain-only). Weekly grain: sums across the week's snapshots plus
    /// a `CostContext`.
    public struct GradeInput: Equatable, Sendable {
        public var compactionCount: Int
        /// The authoritative penalty clock (telemetry active time). Wall-clock
        /// duration is display-only and must never appear here.
        public var activeTimeSeconds: Double
        public var inputTokens: Int
        public var promptCount: Int
        public var cacheReadTokens: Int
        public var cacheCreationTokens: Int
        public var apiErrorCount: Int
        public var apiRequestCount: Int
        /// Present at weekly grain only.
        public var costContext: CostContext?

        public struct CostContext: Equatable, Sendable {
            /// Σ totalCost across the week's snapshots.
            public var totalCost: Double
            /// Count of outcome-flagged (`.completed`) snapshots in the week.
            public var sessionsShipped: Int

            public init(totalCost: Double, sessionsShipped: Int) {
                self.totalCost = totalCost
                self.sessionsShipped = sessionsShipped
            }
        }

        public init(
            compactionCount: Int = 0,
            activeTimeSeconds: Double = 0,
            inputTokens: Int = 0,
            promptCount: Int = 0,
            cacheReadTokens: Int = 0,
            cacheCreationTokens: Int = 0,
            apiErrorCount: Int = 0,
            apiRequestCount: Int = 0,
            costContext: CostContext? = nil
        ) {
            self.compactionCount = compactionCount
            self.activeTimeSeconds = activeTimeSeconds
            self.inputTokens = inputTokens
            self.promptCount = promptCount
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.apiErrorCount = apiErrorCount
            self.apiRequestCount = apiRequestCount
            self.costContext = costContext
        }

        // MARK: Derived rates (shared by grading, baselines, and display)

        public var activeHours: Double { activeTimeSeconds / 3600 }

        /// Compactions per active hour, with the denominator floored so short
        /// or zero active time never explodes the rate.
        public var compactionsPerActiveHour: Double {
            Double(compactionCount) / max(activeHours, Tuning.activeHoursFloor)
        }

        public var inputTokensPerPrompt: Double {
            Double(inputTokens) / Double(max(1, promptCount))
        }

        public var cacheHitRatio: Double {
            Double(cacheReadTokens) / Double(max(1, inputTokens + cacheCreationTokens))
        }

        public var apiErrorRate: Double {
            Double(apiErrorCount) / Double(max(1, apiRequestCount))
        }
    }

    public enum GradeResult: Equatable, Sendable {
        case graded(score: Int, letter: LetterGrade, deductions: [Deduction])
        /// Below the minimum-sample floor — shown as "insufficient data".
        case insufficientData(promptCount: Int)
    }

    // MARK: - Input builders

    /// Session-grain input from one persisted snapshot. `costContext` stays
    /// nil: cost per shipped session is graded at weekly grain only.
    public static func input(for snapshot: SessionAnalyticsSnapshot) -> GradeInput {
        let analytics = snapshot.analytics
        return GradeInput(
            compactionCount: snapshot.compactionCount ?? 0,
            activeTimeSeconds: analytics.activeTimeSeconds,
            inputTokens: analytics.inputTokens,
            promptCount: analytics.promptCount,
            cacheReadTokens: analytics.cacheReadTokens,
            cacheCreationTokens: analytics.cacheCreationTokens,
            apiErrorCount: analytics.apiErrorCount,
            apiRequestCount: analytics.apiRequestCount
        )
    }

    /// Weekly-grain input: re-aggregates raw numerators and denominators
    /// across the week's snapshots (Σ compactions / Σ active hours, Σ input
    /// tokens / Σ prompts, …) — never an average of per-session grades.
    /// Sub-floor sessions' raws still sum in (the floor gates only the graded
    /// result), so splitting one long session into many short ones neither
    /// resets a denominator nor dodges a numerator.
    public static func weeklyInput(summing snapshots: [SessionAnalyticsSnapshot]) -> GradeInput {
        var input = GradeInput()
        var totalCost = 0.0
        var shipped = 0
        for snapshot in snapshots {
            let analytics = snapshot.analytics
            input.compactionCount += snapshot.compactionCount ?? 0
            input.activeTimeSeconds += analytics.activeTimeSeconds
            input.inputTokens += analytics.inputTokens
            input.promptCount += analytics.promptCount
            input.cacheReadTokens += analytics.cacheReadTokens
            input.cacheCreationTokens += analytics.cacheCreationTokens
            input.apiErrorCount += analytics.apiErrorCount
            input.apiRequestCount += analytics.apiRequestCount
            totalCost += analytics.totalCost
            if snapshot.status == .completed { shipped += 1 }
        }
        input.costContext = GradeInput.CostContext(totalCost: totalCost, sessionsShipped: shipped)
        return input
    }

    // MARK: - Grading

    /// The single grading function. Deductions are sorted heaviest-first;
    /// zero-point metrics emit no deduction. The cost metric is evaluated only
    /// when a `costContext` is present AND at least one session shipped — a
    /// zero-shipped week is "insufficient outcomes", never divided by a
    /// fallback.
    public static func grade(_ input: GradeInput) -> GradeResult {
        guard input.promptCount >= Tuning.minimumGradablePromptCount else {
            return .insufficientData(promptCount: input.promptCount)
        }

        var deductions: [Deduction] = []
        if let deduction = compactionDeduction(input) { deductions.append(deduction) }
        if let deduction = contextPressureDeduction(input) { deductions.append(deduction) }
        if let deduction = cacheRatioDeduction(input) { deductions.append(deduction) }
        if let deduction = apiErrorDeduction(input) { deductions.append(deduction) }
        if let deduction = costPerShippedDeduction(input) { deductions.append(deduction) }

        deductions.sort { lhs, rhs in
            if lhs.points != rhs.points { return lhs.points > rhs.points }
            return metricOrder(lhs.metric) < metricOrder(rhs.metric)
        }
        let score = max(0, 100 - deductions.reduce(0) { $0 + $1.points })
        return .graded(score: score, letter: letter(forScore: score), deductions: deductions)
    }

    public static func letter(forScore score: Int) -> LetterGrade {
        switch score {
        case Tuning.gradeACutoff...: return .a
        case Tuning.gradeBCutoff...: return .b
        case Tuning.gradeCCutoff...: return .c
        case Tuning.gradeDCutoff...: return .d
        default: return .f
        }
    }

    // MARK: - Per-metric deductions

    private static func compactionDeduction(_ input: GradeInput) -> Deduction? {
        guard input.compactionCount > 0 else { return nil }
        let rate = input.compactionsPerActiveHour
        let points = min(
            Tuning.compactionDeductionCap,
            Int((rate * Tuning.pointsPerCompactionPerActiveHour).rounded())
        )
        guard points > 0 else { return nil }
        let noun = input.compactionCount == 1 ? "compaction" : "compactions"
        let label = String(format: "%d %@ (%.1f/active hr)", input.compactionCount, noun, rate)
        return Deduction(metric: .compactions, points: points, label: label)
    }

    private static func contextPressureDeduction(_ input: GradeInput) -> Deduction? {
        let perPrompt = input.inputTokensPerPrompt
        guard perPrompt > Tuning.contextPressureLightThreshold else { return nil }
        let points: Int
        if perPrompt <= Tuning.contextPressureMediumThreshold {
            points = Tuning.contextPressureLightPoints
        } else if perPrompt <= Tuning.contextPressureHeavyThreshold {
            points = Tuning.contextPressureMediumPoints
        } else {
            points = Tuning.contextPressureHeavyPoints
        }
        let label = String(format: "%@ input tokens/prompt", abbreviatedCount(perPrompt))
        return Deduction(metric: .contextPressure, points: points, label: label)
    }

    private static func cacheRatioDeduction(_ input: GradeInput) -> Deduction? {
        // No context carried at all → nothing to cache; the metric doesn't
        // apply (avoids penalizing sessions whose telemetry recorded prompts
        // but no token traffic).
        guard input.inputTokens + input.cacheCreationTokens > 0 else { return nil }
        let ratio = input.cacheHitRatio
        let points: Int
        switch ratio {
        case Tuning.cacheRatioGoodThreshold...: return nil
        case Tuning.cacheRatioFairThreshold...: points = Tuning.cacheRatioFairPoints
        case Tuning.cacheRatioPoorThreshold...: points = Tuning.cacheRatioPoorPoints
        default: points = Tuning.cacheRatioBadPoints
        }
        let label = String(format: "%@ cache hit ratio", percentString(ratio))
        return Deduction(metric: .cacheHitRatio, points: points, label: label)
    }

    private static func apiErrorDeduction(_ input: GradeInput) -> Deduction? {
        let rate = input.apiErrorRate
        guard rate >= Tuning.apiErrorRateCleanThreshold else { return nil }
        let points = rate > Tuning.apiErrorRateHeavyThreshold
            ? Tuning.apiErrorRateHeavyPoints
            : Tuning.apiErrorRateModeratePoints
        let label = String(format: "%@ API error rate", percentString(rate))
        return Deduction(metric: .apiErrorRate, points: points, label: label)
    }

    private static func costPerShippedDeduction(_ input: GradeInput) -> Deduction? {
        guard let cost = input.costContext, cost.sessionsShipped > 0 else { return nil }
        let perShipped = cost.totalCost / Double(cost.sessionsShipped)
        let points: Int
        switch perShipped {
        case ...Tuning.costPerShippedLightThreshold: return nil
        case ...Tuning.costPerShippedMediumThreshold: points = Tuning.costPerShippedLightPoints
        case ...Tuning.costPerShippedHeavyThreshold: points = Tuning.costPerShippedMediumPoints
        default: points = Tuning.costPerShippedHeavyPoints
        }
        let label = String(format: "$%.2f per shipped session", perShipped)
        return Deduction(metric: .costPerShipped, points: points, label: label)
    }

    private static func metricOrder(_ metric: Metric) -> Int {
        Metric.allCases.firstIndex(of: metric) ?? 0
    }

    // MARK: - Label formatting (String(format:) only — Linux-safe, no FormatStyle)

    static func percentString(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent == percent.rounded() {
            return String(format: "%.0f%%", percent)
        }
        return String(format: "%.1f%%", percent)
    }

    static func abbreviatedCount(_ value: Double) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", value / 1_000)
        }
        return String(format: "%.0f", value)
    }
}
