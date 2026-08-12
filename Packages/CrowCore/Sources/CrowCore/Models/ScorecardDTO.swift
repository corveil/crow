import Foundation

/// A flat, `Codable`, JS-friendly projection of `ScorecardModel` for the web
/// client (ADR 0008 web parity, #721). The web has no Swift value types, so
/// `crowd` builds the model server-side and ships this DTO over `get-scorecard`.
/// The web renders it verbatim — the grade, throughput, combined score, and
/// baseline are all computed by the one Core `ScorecardModel.build(...)`, so the
/// numbers have a single source of truth.
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
    /// Manager-session weekly usage, newest first (#745, #767, CROW-983).
    /// Deliberately NOT derived from `ScorecardModel` — a Manager never
    /// reaches a terminal status, so it has no snapshot. These rows are a
    /// projection of the persisted `managerUsageWeekly` mirror, and that
    /// separation is what structurally keeps Managers out of the shipped
    /// count, cost-per-shipped, the combined score, and the baseline.
    ///
    /// They DO carry an efficiency grade (CROW-983): that half of ADR 0008's
    /// grade needs no outcome, so withholding it was hiding a signal the data
    /// already supported. The outcome surfaces above stay absent.
    public let managerWeeks: [ManagerUsageWeekDTO]

    // Live telemetry capture health (#745), for the header status line and the
    // empty state's "why is this empty" copy. `telemetryCapturing == false`
    // means telemetry is off or hasn't started.
    public let telemetryCapturing: Bool
    public let telemetrySessionCount: Int
    public let telemetryLastReceivedAtMillis: Double?

    // Tuning constants the web needs for its "baseline building" / "insufficient
    // data" copy, so those thresholds live in Core, not duplicated in JS.
    public let minimumBaselineWeeks: Int
    public let baselineWeekCount: Int
    public let minimumGradablePromptCount: Int

    public init(
        _ model: ScorecardModel,
        telemetryEnabled: Bool,
        snapshotCount: Int,
        managerUsage: [ManagerWeeklyUsage] = [],
        managerNames: [UUID: String] = [:],
        captureStatus: TelemetryCaptureStatus? = nil
    ) {
        self.telemetryEnabled = telemetryEnabled
        self.snapshotCount = snapshotCount
        self.managerWeeks = Self.projectManagerWeeks(managerUsage, names: managerNames)
        self.telemetryCapturing = captureStatus != nil
        self.telemetrySessionCount = captureStatus?.sessionCount ?? 0
        self.telemetryLastReceivedAtMillis = captureStatus?.lastReceivedAt?.millis
        self.currentWeek = WeeklyDTO(model.currentWeek)
        self.priorWeeks = model.priorWeeks.map(WeeklyDTO.init)
        self.baseline = BaselineDTO(model.baseline)
        self.sessions = model.currentWeekSessions.map(SessionRowDTO.init)
        self.minimumBaselineWeeks = EfficiencyGrading.Tuning.minimumBaselineWeeks
        self.baselineWeekCount = EfficiencyGrading.Tuning.baselineWeekCount
        self.minimumGradablePromptCount = EfficiencyGrading.Tuning.minimumGradablePromptCount
    }

    /// Newest-first, and bounded **per Manager** to the window
    /// `SessionService.refreshManagerUsage` actually recomputes (the current
    /// week plus the trailing baseline window).
    ///
    /// The bound matters: `managerUsageWeekly` is merge-only and never pruned,
    /// so without it the card grows by a row a week forever — ~52 rows after a
    /// year, each now carrying a full chip set. Capping per Manager rather than
    /// globally keeps a second Manager from evicting the first one's history.
    ///
    /// Two compatibility rules, both driven by pre-CROW-983 rollups that
    /// carry no `sessionID`:
    /// - A `nil` `sessionID` resolves to the **primary** Manager. #745 only
    ///   ever queried that one session, so a legacy row cannot be anyone else.
    /// - When a legacy bare-keyed week and a new composite-keyed week describe
    ///   the same (week, Manager), the one with an explicit `sessionID` wins.
    ///   Both persist — the first refresh after upgrade writes the composite
    ///   key while the legacy key remains — and rendering both would duplicate
    ///   the row. Legacy rows are still kept when nothing superseded them:
    ///   a week aged out of telemetry retention never gets recomputed, and
    ///   dropping it would lose history the merge-only store exists to protect.
    static func projectManagerWeeks(
        _ usage: [ManagerWeeklyUsage], names: [UUID: String]
    ) -> [ManagerUsageWeekDTO] {
        let weekCap = EfficiencyGrading.Tuning.baselineWeekCount + 1
        var seen: Set<[String]> = []
        var keptPerManager: [UUID: Int] = [:]

        return usage
            // Sort before deduping and capping so both "supersedes" and
            // "newest N" are well defined. Explicit-sessionID rows sort ahead
            // of legacy ones for the same week so the dedupe keeps the newer
            // shape; the id tiebreak keeps output stable across the unordered
            // dictionary this is built from.
            .sorted { lhs, rhs in
                if lhs.weekStart != rhs.weekStart { return lhs.weekStart > rhs.weekStart }
                let lhsExplicit = lhs.sessionID != nil
                let rhsExplicit = rhs.sessionID != nil
                if lhsExplicit != rhsExplicit { return lhsExplicit }
                return (lhs.sessionID?.uuidString ?? "") < (rhs.sessionID?.uuidString ?? "")
            }
            .compactMap { week -> ManagerUsageWeekDTO? in
                let resolvedID = week.sessionID ?? AppState.managerSessionID
                let identity = [String(week.weekStart.timeIntervalSince1970), resolvedID.uuidString]
                guard seen.insert(identity).inserted else { return nil }
                let kept = keptPerManager[resolvedID, default: 0]
                guard kept < weekCap else { return nil }
                keptPerManager[resolvedID] = kept + 1
                return ManagerUsageWeekDTO(
                    week, sessionID: resolvedID, sessionName: names[resolvedID])
            }
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

/// One Manager-usage week (#745, #767, CROW-983) — the same figures a work
/// week renders, plus the Manager's identity and its outcome-independent
/// efficiency grade.
///
/// `grade` is the EFFICIENCY half of ADR 0008's grade only
/// (`EfficiencyGrading.efficiencyInput(for:)` leaves `costContext` nil, so
/// cost-per-shipped never applies). There is deliberately no `sessionsShipped`,
/// `costPerShipped`, or `combined` field here: a Manager never reaches
/// `.completed`, so every outcome surface would be a fabrication. The web must
/// keep labelling this row as efficiency-only.
public struct ManagerUsageWeekDTO: Codable, Sendable, Equatable {
    public let weekStartMillis: Double

    /// Which Manager (CROW-983). Always resolved — a rollup persisted before
    /// per-Manager attribution existed reports the primary Manager, the only
    /// session that could have produced it.
    public let sessionID: String
    /// Display name resolved at projection time; `nil` when the session row is
    /// gone (a deleted non-primary Manager keeps its persisted weeks).
    public let sessionName: String?

    /// Outcome-independent efficiency grade over this week's raws.
    public let grade: GradeDTO

    public let promptCount: Int
    public let totalTokens: Int
    public let totalCost: Double
    public let activeTimeSeconds: Double
    public let commitCount: Int
    public let toolCallCount: Int

    // Derived rates, read off the same `GradeInput` that produced `grade` so a
    // chip can never disagree with the deduction that cites it.
    public let compactionsPerActiveHour: Double
    public let inputTokensPerPrompt: Double
    public let cacheHitRatio: Double
    public let apiErrorRate: Double

    init(_ week: ManagerWeeklyUsage, sessionID: UUID, sessionName: String? = nil) {
        let input = EfficiencyGrading.efficiencyInput(for: week)
        self.weekStartMillis = week.weekStart.millis
        self.sessionID = sessionID.uuidString
        self.sessionName = sessionName
        self.grade = GradeDTO(EfficiencyGrading.grade(input))
        self.promptCount = week.analytics.promptCount
        self.totalTokens = week.analytics.totalTokens
        self.totalCost = week.analytics.totalCost
        self.activeTimeSeconds = week.analytics.activeTimeSeconds
        self.commitCount = week.analytics.commitCount
        self.toolCallCount = week.analytics.toolCallCount
        self.compactionsPerActiveHour = input.compactionsPerActiveHour
        self.inputTokensPerPrompt = input.inputTokensPerPrompt
        self.cacheHitRatio = input.cacheHitRatio
        self.apiErrorRate = input.apiErrorRate
    }
}

private extension Date {
    /// Epoch milliseconds — the JS-native `Date` unit, so the web never has to
    /// know Swift's date-encoding strategy.
    var millis: Double { timeIntervalSince1970 * 1000 }
}
