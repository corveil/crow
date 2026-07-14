import Foundation

/// ADR 0008 v2 combined multiplicative score (follow-up 11, #699):
/// `alignment-weighted throughput × efficiency multiplier`, computed at
/// **weekly grain only**. There is deliberately no session-grain API — at
/// session grain the throughput factor is usually zero, producing the
/// unstable, unexplainable scores the ADR rejects.
///
/// Multiplicative is the point: an additive combination lets high throughput
/// mask terrible hygiene, recreating the raw-spend-leaderboard failure. Here
/// the efficiency multiplier is provably ≤ 1, so waste can only shrink a
/// week's score — it cannot be bought back with volume.
///
/// The score is an ADDITIONAL surface on the weekly scorecard; the v1 A–F
/// grade and the sessions-shipped count remain their own separate surfaces.
/// It decomposes into inspectable factors —
/// `shipped count × alignment factor × efficiency multiplier` — so it stays
/// a coachable sentence, not an opaque number. Private self-comparison
/// posture per the ADR: no leaderboard unless a later ADR supersedes it.
public enum CombinedScore {

    // MARK: - Tuning

    /// Hygiene-penalty priors. Like `EfficiencyGrading.Tuning`, every value is
    /// a starting heuristic under the ADR's binding 4-week calibration period
    /// — revise against real distributions, not taste.
    public enum Tuning {
        /// Hygiene fraction removed per detected revert: ×(1 − 0.25) each.
        /// A revert is the strongest shipped-then-unshipped signal, so one
        /// revert costs more than any single grade deduction — but the decay
        /// is geometric, never zeroing a week: waste is expensive, not
        /// annihilating.
        public static let revertHygienePenalty: Double = 0.25
        /// Per detected post-merge fix: ×(1 − 0.10). Lighter than a revert
        /// because the 48h file-overlap heuristic can catch legitimate
        /// follow-on work, not just repair.
        public static let postMergeFixHygienePenalty: Double = 0.10
        /// Merge-rate blend weight: factor = 1 − w × (1 − mergeRate). At
        /// w = 0.5 a 0%-merge-rate week bottoms out at ×0.5 rather than ×0 —
        /// closed-without-merge is ambiguous (superseded branches,
        /// exploration), unlike a revert. A nil merge rate (nothing resolved)
        /// is fully neutral.
        public static let mergeRateHygieneWeight: Double = 0.5
    }

    // MARK: - Weekly rework rollup

    /// Whole-machine rework counts for one scorecard week, rolled up from the
    /// persisted PR attributions (#693/#694). Deliberately NOT per-session —
    /// the v2 unit is per-user-per-week, and on this single-user app
    /// "per-user" is every attribution on the machine. (CrowPersistence's
    /// `SessionReworkMetrics` is the per-session drill-down counterpart.)
    public struct WeeklyRework: Equatable, Sendable {
        /// PRs whose current state is MERGED with `mergedAt` in the week.
        public let mergedCount: Int
        /// PRs whose current state is CLOSED with `closedAt` in the week —
        /// a reopened-then-merged PR counts as merged, never closed.
        public let closedWithoutMergeCount: Int
        /// Reverts detected (`detectedAt`) in the week.
        public let revertCount: Int
        /// Post-merge fixes detected (`detectedAt`) in the week.
        public let postMergeFixCount: Int

        /// merged / (merged + closed-without-merge); nil when the week
        /// resolved nothing — neutral, never a fake 0 or 1.
        public var mergeRate: Double? {
            let resolved = mergedCount + closedWithoutMergeCount
            guard resolved > 0 else { return nil }
            return Double(mergedCount) / Double(resolved)
        }

        public static let empty = WeeklyRework(
            mergedCount: 0,
            closedWithoutMergeCount: 0,
            revertCount: 0,
            postMergeFixCount: 0
        )

        public init(mergedCount: Int, closedWithoutMergeCount: Int, revertCount: Int, postMergeFixCount: Int) {
            self.mergedCount = mergedCount
            self.closedWithoutMergeCount = closedWithoutMergeCount
            self.revertCount = revertCount
            self.postMergeFixCount = postMergeFixCount
        }
    }

    /// Rolls the attribution store up into one week's rework counts.
    /// Membership is half-open (`>= start && < end`) to match
    /// `ScorecardModel`'s week bucketing — NOT `DateInterval.contains`,
    /// which is end-inclusive and would double-count a Monday-00:00 event
    /// into two adjacent weeks.
    public static func weeklyRework(
        attributions: [PRSessionAttribution],
        week: DateInterval
    ) -> WeeklyRework {
        var merged = 0
        var closed = 0
        var reverts = 0
        var fixes = 0

        for attribution in attributions {
            if attribution.state == "MERGED", let mergedAt = attribution.mergedAt, contains(week, mergedAt) {
                merged += 1
            }
            if attribution.state == "CLOSED", let closedAt = attribution.closedAt, contains(week, closedAt) {
                closed += 1
            }
            reverts += (attribution.reverts ?? []).filter { contains(week, $0.detectedAt) }.count
            fixes += (attribution.postMergeFixes ?? []).filter { contains(week, $0.detectedAt) }.count
        }

        return WeeklyRework(
            mergedCount: merged,
            closedWithoutMergeCount: closed,
            revertCount: reverts,
            postMergeFixCount: fixes
        )
    }

    private static func contains(_ interval: DateInterval, _ date: Date) -> Bool {
        date >= interval.start && date < interval.end
    }

    // MARK: - Factors

    /// Every input and intermediate of one week's combined score, so the
    /// number decomposes into an explainable sentence:
    /// `value == shippedCount × alignmentFactor × efficiencyMultiplier`
    /// (within floating-point epsilon; the exact identity is
    /// `weightedThroughput × efficiencyMultiplier`).
    public struct Factors: Equatable, Sendable {
        /// Raw throughput count: `.completed` snapshots in the week.
        public let shippedCount: Int
        /// Σ alignment weight over shipped snapshots (nil weight = neutral
        /// 1.0, so pre-#696 snapshots count exactly as an unweighted count).
        public let weightedThroughput: Double
        /// The week's v1 grade score (0–100) — the grade half of the
        /// efficiency multiplier.
        public let gradeScore: Int
        /// The rework half of the efficiency multiplier, in (0, 1].
        public let hygieneFactor: Double
        /// The rework counts behind `hygieneFactor`, for display.
        public let rework: WeeklyRework

        /// Average alignment weight of the week's shipped work; neutral 1.0
        /// for a zero-shipped week (keeps the decomposition identity
        /// `0 × 1.0 × E = 0` instead of dividing by zero).
        public var alignmentFactor: Double {
            shippedCount > 0 ? weightedThroughput / Double(shippedCount) : AlignmentWeight.neutral
        }
        public var gradeFactor: Double { Double(gradeScore) / 100 }
        /// Grade × hygiene, clamped to [0, 1]: both halves are already ≤ 1 by
        /// construction, so the clamp is defensive. Hygiene can only shrink a
        /// score — a perfect week multiplies by exactly 1.
        public var efficiencyMultiplier: Double { min(1, max(0, gradeFactor * hygieneFactor)) }
        /// The combined score.
        public var value: Double { weightedThroughput * efficiencyMultiplier }

        public init(
            shippedCount: Int,
            weightedThroughput: Double,
            gradeScore: Int,
            hygieneFactor: Double,
            rework: WeeklyRework
        ) {
            self.shippedCount = shippedCount
            self.weightedThroughput = weightedThroughput
            self.gradeScore = gradeScore
            self.hygieneFactor = hygieneFactor
            self.rework = rework
        }
    }

    public enum WeeklyResult: Equatable, Sendable {
        case scored(Factors)
        /// Passthrough of the weekly grade's minimum-sample floor: no grade →
        /// no efficiency multiplier → no combined score. (A graded week that
        /// shipped nothing IS scored — value 0 is a legitimate weekly-grain
        /// zero, not the session-grain degeneracy the ADR rejects.)
        case insufficientData(promptCount: Int)
    }

    // MARK: - Scoring

    /// `(1 − revertPenalty)^reverts × (1 − fixPenalty)^fixes ×
    /// (1 − w × (1 − mergeRate))`, clamped to [0, 1] defensively. Each factor
    /// is in (0, 1] by construction, so a week with no attributions — or no
    /// resolved PRs — is fully neutral at 1.0: absence of data is never
    /// punished (the `AlignmentWeight` principle).
    public static func hygieneFactor(rework: WeeklyRework) -> Double {
        let revertFactor = pow(1 - Tuning.revertHygienePenalty, Double(rework.revertCount))
        let fixFactor = pow(1 - Tuning.postMergeFixHygienePenalty, Double(rework.postMergeFixCount))
        let mergeRateFactor: Double
        if let mergeRate = rework.mergeRate {
            mergeRateFactor = 1 - Tuning.mergeRateHygieneWeight * (1 - mergeRate)
        } else {
            mergeRateFactor = 1
        }
        return min(1, max(0, revertFactor * fixFactor * mergeRateFactor))
    }

    /// One week's combined score from the week's snapshots, its already
    /// computed v1 grade, and its rework rollup. The grade is passed in, not
    /// recomputed, so the combined score is guaranteed to be built on exactly
    /// the number the grade card shows.
    public static func weeklyScore(
        snapshots: [SessionAnalyticsSnapshot],
        gradeResult: EfficiencyGrading.GradeResult,
        rework: WeeklyRework
    ) -> WeeklyResult {
        switch gradeResult {
        case .insufficientData(let promptCount):
            return .insufficientData(promptCount: promptCount)
        case .graded(let score, _, _):
            let shipped = snapshots.filter { $0.status == .completed }
            let weightedThroughput = shipped.reduce(0.0) {
                $0 + ($1.alignmentWeight ?? AlignmentWeight.neutral)
            }
            return .scored(Factors(
                shippedCount: shipped.count,
                weightedThroughput: weightedThroughput,
                gradeScore: score,
                hygieneFactor: hygieneFactor(rework: rework),
                rework: rework
            ))
        }
    }
}
