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
    /// record; `"week"` = a Manager's current ISO-week rollup (CROW-1439). Lets
    /// the web distinguish live-updating vs. final without a second lookup
    /// (`live` and `snapshot` render identically; `week` adds a window label).
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
    /// Manager sessions only (CROW-1439): start of the ISO week these numbers
    /// cover, as epoch milliseconds. Its presence is what tells the web to label
    /// the strip `This week` — a Manager never ends, so its numbers are a
    /// week-to-date window, not a lifetime total. Nil (and so absent from the
    /// wire) for work sessions, keeping their payload unchanged.
    public let weekStartMillis: Double?
    /// Manager sessions only (CROW-1439): completed compactions attributed to
    /// the week. Nil for work sessions, and for a week that never counted one.
    public let compactionCount: Int?

    private init(
        source: String, analytics: SessionAnalytics, wallClockDurationSeconds: Double?,
        weekStartMillis: Double? = nil, compactionCount: Int? = nil
    ) {
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
        self.weekStartMillis = weekStartMillis
        self.compactionCount = compactionCount
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

    /// A Manager's current-week rollup (CROW-1439) — the same row the
    /// Scorecard's Manager Usage card shows. No wall-clock duration: a
    /// Manager's lifecycle stamps span its whole life, not the week.
    public init(managerWeek week: ManagerWeeklyUsage) {
        self.init(
            source: "week",
            analytics: week.analytics,
            wallClockDurationSeconds: nil,
            weekStartMillis: week.weekStart.timeIntervalSince1970 * 1000,
            compactionCount: week.compactionCount
        )
    }
}
