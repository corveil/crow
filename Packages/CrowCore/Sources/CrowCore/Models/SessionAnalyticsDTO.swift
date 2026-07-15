import Foundation

/// A flat, `Codable`, JS-friendly projection of a single session's analytics for
/// the web per-session strip (CROW-722; ADR 0008 web parity, sibling to the
/// `ScorecardDTO` surface). The desktop `SessionAnalyticsStrip` reads a
/// `SessionAnalytics` value directly; the web has no Swift value types, so
/// `crowd` resolves the best available source per session — the live in-memory
/// hook aggregate for an open session, else the durable end-of-session snapshot —
/// and ships this DTO inside `list-sessions-live`. The web renders it verbatim
/// with the same `fmt*` helpers the scorecard chips use, so web and desktop can't
/// drift on the numbers or their formatting.
public struct SessionAnalyticsDTO: Codable, Sendable, Equatable {
    /// Which source produced these numbers: `"live"` = the in-memory hook
    /// aggregate for an open session; `"snapshot"` = the durable end-of-session
    /// record. Lets the web distinguish live-updating vs. final without a second
    /// lookup (currently informational — the strip renders both identically).
    public let source: String
    public let totalCost: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreationTokens: Int
    public let totalTokens: Int
    public let activeTimeSeconds: Double
    public let toolCallCount: Int
    public let linesAdded: Int
    public let linesRemoved: Int
    public let apiErrorCount: Int
    /// Wall-clock span (first `SessionStart` → last `SessionEnd`). Display-only
    /// context beside "Active", never a grading input. `nil` hides the chip
    /// (open-ended session, or an agent that never sends `SessionEnd`).
    public let wallClockDurationSeconds: Double?

    private init(source: String, analytics: SessionAnalytics, wallClockDurationSeconds: Double?) {
        self.source = source
        self.totalCost = analytics.totalCost
        self.inputTokens = analytics.inputTokens
        self.outputTokens = analytics.outputTokens
        self.cacheReadTokens = analytics.cacheReadTokens
        self.cacheCreationTokens = analytics.cacheCreationTokens
        self.totalTokens = analytics.totalTokens
        self.activeTimeSeconds = analytics.activeTimeSeconds
        self.toolCallCount = analytics.toolCallCount
        self.linesAdded = analytics.linesAdded
        self.linesRemoved = analytics.linesRemoved
        self.apiErrorCount = analytics.apiErrorCount
        self.wallClockDurationSeconds = wallClockDurationSeconds
    }

    /// Live in-memory hook aggregate for an open session. `wallClockDuration`
    /// comes from the session's lifecycle stamps (`nil` while the session hasn't
    /// ended, or for agents that never send `SessionEnd`).
    public init(live analytics: SessionAnalytics, wallClockDuration: TimeInterval? = nil) {
        self.init(source: "live", analytics: analytics, wallClockDurationSeconds: wallClockDuration)
    }

    /// Durable end-of-session snapshot (terminal sessions). Snapshots are only
    /// written for non-empty aggregates, so a snapshot is always meaningful.
    public init(snapshot: SessionAnalyticsSnapshot) {
        self.init(
            source: "snapshot",
            analytics: snapshot.analytics,
            wallClockDurationSeconds: snapshot.wallClockDurationSeconds
        )
    }
}
