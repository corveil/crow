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
/// Extension point (ADR 0008 follow-ups): add future fields — like
/// `compactionCount` below — as OPTIONALS on this struct, not on
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
    /// Completed compactions (`PostCompact` events) over the session's life
    /// (ADR 0008 follow-up 3 — the scorecard's heaviest-weighted penalty).
    /// `nil` in snapshots persisted before #691; treat as 0.
    public var compactionCount: Int?
    /// Wall-clock span from first `SessionStart` to last `SessionEnd` hook,
    /// copied from the session's lifecycle stamps at snapshot time (#692, ADR
    /// 0008 follow-up 4). DISPLAY-ONLY context: `analytics.activeTimeSeconds`
    /// is the authoritative clock for all penalty normalization — this must
    /// never be a grading denominator. `nil` for open-ended sessions (no
    /// `SessionEnd` — e.g. non-Claude agents never send one) and for snapshots
    /// persisted before this field existed. Telemetry-off sessions get no
    /// snapshot at all, so their duration lives only on the `Session` row.
    public var wallClockDurationSeconds: Double?

    public init(
        sessionID: UUID,
        endedAt: Date,
        status: SessionStatus,
        analytics: SessionAnalytics,
        compactionCount: Int? = nil,
        wallClockDurationSeconds: Double? = nil
    ) {
        self.sessionID = sessionID
        self.endedAt = endedAt
        self.status = status
        self.analytics = analytics
        self.compactionCount = compactionCount
        self.wallClockDurationSeconds = wallClockDurationSeconds
    }
}
