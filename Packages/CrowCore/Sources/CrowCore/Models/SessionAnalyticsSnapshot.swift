import Foundation

/// Durable per-session analytics record, persisted when a session reaches a
/// terminal status (`.completed` / `.archived`).
///
/// This is the persistence backbone for ADR 0008's scorecard: weekly rollups
/// re-aggregate these snapshots, and the trailing-4-week self-comparison
/// baseline is derived from them. Snapshots deliberately outlive session
/// deletion — the retention reaper deletes completed/archived sessions (and
/// their telemetry rows) after a configurable window, and the baseline must
/// survive that cleanup. That is also why the terminal `status` is recorded
/// here rather than looked up on the session: "sessions shipped" is counted
/// from snapshots after the session record is gone.
///
/// Extension point (ADR 0008 follow-up 3): add future fields — e.g.
/// `compactionCount: Int?` — as OPTIONALS on this struct, not on
/// `SessionAnalytics`, so previously persisted snapshots keep decoding.
public struct SessionAnalyticsSnapshot: Codable, Equatable, Sendable {
    public var sessionID: UUID
    /// When the session reached its terminal status. Weekly rollups bucket by
    /// this date.
    public var endedAt: Date
    /// Terminal status at snapshot time. `.completed` is ADR 0008's outcome
    /// flag ("shipped"); `.archived` is ended without shipping. A session that
    /// is reactivated and ends again overwrites its snapshot with the newer
    /// status and aggregate.
    public var status: SessionStatus
    public var analytics: SessionAnalytics

    public init(
        sessionID: UUID,
        endedAt: Date,
        status: SessionStatus,
        analytics: SessionAnalytics
    ) {
        self.sessionID = sessionID
        self.endedAt = endedAt
        self.status = status
        self.analytics = analytics
    }
}
