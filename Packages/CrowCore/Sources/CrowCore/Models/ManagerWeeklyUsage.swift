import Foundation

/// Weekly rollup of one Manager session's telemetry (#745, CROW-983,
/// ADR 0008 addenda). A Manager session is permanent and never reaches a
/// terminal status, so it can't produce a `SessionAnalyticsSnapshot`; its
/// usage is instead aggregated per ISO-8601 week directly from telemetry.db
/// and persisted so weeks that age out of telemetry retention survive.
///
/// Excluded from every OUTCOME surface — the shipped count, cost-per-shipped,
/// the combined score, and the baseline — because ADR 0008's outcome flag is
/// `status == .completed`, which a Manager can never reach. The
/// outcome-independent EFFICIENCY grade *is* computed from these raws
/// (CROW-983); see `EfficiencyGrading.efficiencyInput(for:)`.
public struct ManagerWeeklyUsage: Codable, Equatable, Sendable {
    /// Start of the ISO-8601 week (Monday) in the timezone current when the
    /// rollup was computed — the same bucketing `ScorecardModel.build` uses.
    public let weekStart: Date
    public var analytics: SessionAnalytics

    /// Which Manager this week belongs to (CROW-983). **Optional for
    /// backward compatibility, and that is load-bearing**: `StoreData`
    /// decoding is all-or-nothing (`JSONStore.init` backs the file up to
    /// `store.json.bak` and resets to an empty store on any throw), so a
    /// non-optional field added here would wipe the user's sessions. `nil`
    /// means a pre-CROW-983 rollup, which could only have come from the
    /// primary Manager — that was the sole session #745 ever queried.
    public var sessionID: UUID?

    /// Completed compactions (`PostCompact`) attributed to this week.
    /// Accumulated at event time rather than recomputed: telemetry.db has no
    /// compaction rows, and `SessionHookState.compactionCount` is a
    /// per-app-run running total with no week attribution, so a permanent
    /// session's compactions cannot be sliced out of it after the fact.
    /// Optional for the same store-compat reason as `sessionID`; `nil` means
    /// "never counted", which is distinct from a counted zero.
    public var compactionCount: Int?

    public init(
        weekStart: Date,
        analytics: SessionAnalytics,
        sessionID: UUID? = nil,
        compactionCount: Int? = nil
    ) {
        self.weekStart = weekStart
        self.analytics = analytics
        self.sessionID = sessionID
        self.compactionCount = compactionCount
    }
}

/// Live telemetry.db health probe backing the scorecard's capture-status
/// line (#745). Not persisted — recomputed at launch and on manual rebuild;
/// nil on `AppState` means telemetry isn't capturing (disabled or not yet
/// started).
public struct TelemetryCaptureStatus: Equatable, Sendable {
    /// Distinct sessions with at least one telemetry row still in retention.
    public var sessionCount: Int
    /// Ingest time of the newest telemetry row, nil when the DB is empty.
    public var lastReceivedAt: Date?

    public init(sessionCount: Int, lastReceivedAt: Date?) {
        self.sessionCount = sessionCount
        self.lastReceivedAt = lastReceivedAt
    }
}
