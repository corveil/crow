import Foundation

/// A flat, `Codable`, JS-friendly projection of `ScorecardModel` for the web
/// client (ADR 0008 web parity, #721). The macOS `ScorecardView` reads
/// `ScorecardModel` directly; the web has no Swift value types, so `crowd`
/// builds the model server-side and ships this DTO over `get-scorecard`. The
/// web renders it verbatim — the grade, throughput, combined score, and
/// baseline are all computed by the one Core `ScorecardModel.build(...)`, so
/// web and desktop can never diverge on the numbers.
///
/// Flattening rules that keep the wire shape trivial for JavaScript:
/// - The `GradeResult` / `CombinedScore.WeeklyResult` / `CostPerShipped`
///   enums-with-payloads collapse to structs with optional fields and a
///   discriminator (`graded`, `scored`) — a `nil` payload field means the
///   other case.
/// - Dates are epoch **milliseconds** (`Double`), not `Date` — `new Date(ms)`
///   in JS, and no `JSONEncoder.dateEncodingStrategy` coupling with the
///   `JSONValue` transport used by `get-state`.
/// - The current week carries its derived rates inline so the web can draw the
///   baseline comparison without re-deriving them from raws.
public struct ScorecardDTO: Codable, Sendable, Equatable {
    /// `config.telemetry.enabled` at build time — lets the web split the empty
    /// state into "telemetry off" vs. "on but nothing shipped yet".
    public let telemetryEnabled: Bool
    /// Total persisted snapshots. Zero ⇒ the desktop's `analyticsSnapshots
    /// .isEmpty` empty state.
    public let snapshotCount: Int
    public let currentWeek: WeeklyDTO
    /// Trailing weeks that had snapshots, newest first (absence is not a zero).
    public let priorWeeks: [WeeklyDTO]
    public let baseline: BaselineDTO
    /// Current week's per-session drill-down rows, newest first.
    public let sessions: [SessionRowDTO]

    // Tuning constants the web needs for its "baseline building" / "insufficient
    // data" copy, so those thresholds live in Core, not duplicated in JS.
    public let minimumBaselineWeeks: Int
    public let baselineWeekCount: Int
    public let minimumGradablePromptCount: Int

    public init(
        _ model: ScorecardModel,
        telemetryEnabled: Bool,
        snapshotCount: Int
    ) {
        self.telemetryEnabled = telemetryEnabled
        self.snapshotCount = snapshotCount
        self.currentWeek = WeeklyDTO(model.currentWeek)
        self.priorWeeks = model.priorWeeks.map(WeeklyDTO.init)
        self.baseline = BaselineDTO(model.baseline)
        self.sessions = model.currentWeekSessions.map(SessionRowDTO.init)
        self.minimumBaselineWeeks = EfficiencyGrading.Tuning.minimumBaselineWeeks
        self.baselineWeekCount = EfficiencyGrading.Tuning.baselineWeekCount
        self.minimumGradablePromptCount = EfficiencyGrading.Tuning.minimumGradablePromptCount
    }
}

/// One week: the A–F grade, the separate sessions-shipped surface, the v2
/// combined score, the displayed-not-graded context stats, and the current
/// week's derived rates for baseline comparison.
public struct WeeklyDTO: Codable, Sendable, Equatable {
    public let weekStartMillis: Double
    public let grade: GradeDTO
    public let sessionsShipped: Int
    /// `Σ totalCost / sessionsShipped`; `nil` = insufficient outcomes (nothing
    /// shipped), never a fallback division.
    public let costPerShipped: Double?
    public let sessionCount: Int
    public let totalCost: Double
    public let activeTimeSeconds: Double
    public let commitCount: Int
    public let churnHint: Double
    public let combined: CombinedDTO

    // Derived rates (for the current week's baseline comparison rows).
    public let compactionsPerActiveHour: Double
    public let inputTokensPerPrompt: Double
    public let cacheHitRatio: Double
    public let apiErrorRate: Double

    init(_ week: WeeklyScorecard) {
        self.weekStartMillis = week.weekStart.millis
        self.grade = GradeDTO(week.result)
        self.sessionsShipped = week.sessionsShipped
        if case .graded(let cost) = week.costPerShipped {
            self.costPerShipped = cost
        } else {
            self.costPerShipped = nil
        }
        self.sessionCount = week.sessionCount
        self.totalCost = week.totalCost
        self.activeTimeSeconds = week.activeTimeSeconds
        self.commitCount = week.commitCount
        self.churnHint = week.churnHint
        self.combined = CombinedDTO(week.combined)
        self.compactionsPerActiveHour = week.input.compactionsPerActiveHour
        self.inputTokensPerPrompt = week.input.inputTokensPerPrompt
        self.cacheHitRatio = week.input.cacheHitRatio
        self.apiErrorRate = week.input.apiErrorRate
    }
}

/// A grade result: `graded` carries score/letter/deductions; otherwise
/// `promptCount` is the below-floor count for the "insufficient data" copy.
public struct GradeDTO: Codable, Sendable, Equatable {
    public let graded: Bool
    public let score: Int?
    public let letter: String?
    public let deductions: [DeductionDTO]
    /// Set only when `graded == false`.
    public let promptCount: Int?

    init(_ result: EfficiencyGrading.GradeResult) {
        switch result {
        case .graded(let score, let letter, let deductions):
            self.graded = true
            self.score = score
            self.letter = letter.rawValue
            self.deductions = deductions.map(DeductionDTO.init)
            self.promptCount = nil
        case .insufficientData(let prompts):
            self.graded = false
            self.score = nil
            self.letter = nil
            self.deductions = []
            self.promptCount = prompts
        }
    }
}

public struct DeductionDTO: Codable, Sendable, Equatable {
    /// `EfficiencyGrading.Metric` raw value — the web keys its coaching hint off
    /// this (`compactions`, `contextPressure`, `cacheHitRatio`, `apiErrorRate`,
    /// `costPerShipped`).
    public let metric: String
    public let points: Int
    public let label: String

    init(_ deduction: EfficiencyGrading.Deduction) {
        self.metric = deduction.metric.rawValue
        self.points = deduction.points
        self.label = deduction.label
    }
}

/// The v2 combined score: `scored` carries the decomposed factors; otherwise
/// it passes through the weekly grade's minimum-sample floor.
public struct CombinedDTO: Codable, Sendable, Equatable {
    public let scored: Bool
    public let value: Double?
    public let shippedCount: Int?
    public let alignmentFactor: Double?
    public let efficiencyMultiplier: Double?
    public let gradeScore: Int?
    public let hygieneFactor: Double?
    public let revertCount: Int?
    public let postMergeFixCount: Int?
    /// merged / (merged + closed-without-merge); `nil` when nothing resolved
    /// (neutral, never a fake 0 or 1).
    public let mergeRate: Double?
    /// Set only when `scored == false`.
    public let promptCount: Int?

    init(_ result: CombinedScore.WeeklyResult) {
        switch result {
        case .scored(let f):
            self.scored = true
            self.value = f.value
            self.shippedCount = f.shippedCount
            self.alignmentFactor = f.alignmentFactor
            self.efficiencyMultiplier = f.efficiencyMultiplier
            self.gradeScore = f.gradeScore
            self.hygieneFactor = f.hygieneFactor
            self.revertCount = f.rework.revertCount
            self.postMergeFixCount = f.rework.postMergeFixCount
            self.mergeRate = f.rework.mergeRate
            self.promptCount = nil
        case .insufficientData(let prompts):
            self.scored = false
            self.value = nil
            self.shippedCount = nil
            self.alignmentFactor = nil
            self.efficiencyMultiplier = nil
            self.gradeScore = nil
            self.hygieneFactor = nil
            self.revertCount = nil
            self.postMergeFixCount = nil
            self.mergeRate = nil
            self.promptCount = prompts
        }
    }
}

/// The trailing-4-week median baseline. `nil` medians mean no graded prior week
/// supplied that value.
public struct BaselineDTO: Codable, Sendable, Equatable {
    public let weeksAvailable: Int
    public let medianScore: Double?
    public let medianCompactionsPerActiveHour: Double?
    public let medianInputTokensPerPrompt: Double?
    public let medianCacheHitRatio: Double?
    public let medianApiErrorRate: Double?
    public let medianCostPerShipped: Double?
    public let medianCombinedScore: Double?

    init(_ baseline: ScorecardBaseline) {
        self.weeksAvailable = baseline.weeksAvailable
        self.medianScore = baseline.medianScore
        self.medianCompactionsPerActiveHour = baseline.medianCompactionsPerActiveHour
        self.medianInputTokensPerPrompt = baseline.medianInputTokensPerPrompt
        self.medianCacheHitRatio = baseline.medianCacheHitRatio
        self.medianApiErrorRate = baseline.medianApiErrorRate
        self.medianCostPerShipped = baseline.medianCostPerShipped
        self.medianCombinedScore = baseline.medianCombinedScore
    }
}

/// One per-session drill-down row for the current week.
public struct SessionRowDTO: Codable, Sendable, Equatable {
    public let sessionID: String
    public let endedAtMillis: Double
    public let shipped: Bool
    public let grade: GradeDTO
    public let totalCost: Double
    public let activeTimeSeconds: Double
    public let wallClockDurationSeconds: Double?

    init(_ row: SessionGradeRow) {
        self.sessionID = row.sessionID.uuidString
        self.endedAtMillis = row.endedAt.millis
        self.shipped = row.shipped
        self.grade = GradeDTO(row.result)
        self.totalCost = row.analytics.totalCost
        self.activeTimeSeconds = row.analytics.activeTimeSeconds
        self.wallClockDurationSeconds = row.wallClockDurationSeconds
    }
}

private extension Date {
    /// Epoch milliseconds — the JS-native `Date` unit, so the web never has to
    /// know Swift's date-encoding strategy.
    var millis: Double { timeIntervalSince1970 * 1000 }
}
