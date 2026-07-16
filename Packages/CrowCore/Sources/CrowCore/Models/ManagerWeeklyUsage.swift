import Foundation

/// Ungraded weekly rollup of the Manager session's telemetry (#745,
/// ADR 0008 addendum). The Manager session is permanent and never reaches a
/// terminal status, so it can't produce a `SessionAnalyticsSnapshot`; its
/// usage is instead aggregated per ISO-8601 week directly from telemetry.db
/// and persisted so weeks that age out of telemetry retention survive.
/// Deliberately excluded from every graded surface and the baseline — it is
/// visibility only, consistent with ADR 0008's private-scorecard posture.
public struct ManagerWeeklyUsage: Codable, Equatable, Sendable {
    /// Start of the ISO-8601 week (Monday) in the timezone current when the
    /// rollup was computed — the same bucketing `ScorecardModel.build` uses.
    public let weekStart: Date
    public var analytics: SessionAnalytics

    public init(weekStart: Date, analytics: SessionAnalytics) {
        self.weekStart = weekStart
        self.analytics = analytics
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
