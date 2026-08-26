import Foundation
import CrowCore
import CrowPersistence

/// End-of-session analytics snapshots (#690, ADR 0008) and per-Manager weekly
/// usage rollups (#745, CROW-983), extracted from `SessionService` (CROW-1113).
/// Behavior-preserving: same terminal-status gate, same telemetry-provider
/// fallbacks, same week bucketing. Reaches `appState`, the shared **injected**
/// `JSONStore`, and the telemetry providers through an unowned back-reference
/// (ADR 0012 / #728 — never a throwaway `JSONStore()`). The public/internal
/// entry points stay on `SessionService` as facades (see the extension below).
@MainActor
final class SessionAnalyticsController {
    private unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }
    private var analyticsProvider: (@Sendable (UUID) async -> SessionAnalytics?)? { owner.analyticsProvider }
    private var telemetrySessionIDsProvider: (@Sendable () async -> [UUID])? { owner.telemetrySessionIDsProvider }
    private var managerUsageProvider: (@Sendable (UUID, Date, Date) async -> SessionAnalytics)? { owner.managerUsageProvider }

    init(owner: SessionService) { self.owner = owner }

    /// Stamp agent `SessionStart`/`SessionEnd` wall-clock timestamps on the
    /// session (#692, ADR 0008 follow-up 4). Display-only context —
    /// `activeTimeSeconds` from telemetry stays the penalty-normalization
    /// clock. Like `setLocked`, deliberately leaves `updatedAt` untouched so
    /// the retention clock is unaffected. These events are rare (agent
    /// launch/exit), so the unconditional store write is cheap.
    func recordAgentLifecycleEvent(sessionID: UUID, eventName: String, at date: Date = Date()) {
        guard eventName == "SessionStart" || eventName == "SessionEnd" else { return }

        func apply(_ session: inout Session) {
            if eventName == "SessionStart" {
                session.recordAgentSessionStart(at: date)
            } else {
                session.recordAgentSessionEnd(at: date)
            }
        }
        if let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) {
            apply(&appState.sessions[idx])
        }
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                apply(&data.sessions[idx])
            }
        }
    }

    // MARK: - Analytics Snapshot (#690, ADR 0008)

    /// Fire-and-forget trigger for the end-of-session analytics snapshot.
    /// Internal (not private) because the `set-status` RPC handler mutates
    /// status directly, bypassing `updateSessionStatus`, and must trigger the
    /// snapshot itself.
    func scheduleAnalyticsSnapshot(for id: UUID, status: SessionStatus) {
        guard status == .completed || status == .archived else { return }
        // Capture `owner` strongly so the snapshot write completes even if the
        // caller drops its `SessionService` reference before this task runs
        // (pre-CROW-1113 parity: the fire-and-forget task then strongly held the
        // SessionService, whose state this reaches through the `unowned owner`).
        Task { [owner] in
            _ = owner
            await writeAnalyticsSnapshot(for: id, status: status)
        }
    }

    /// Persist a durable `SessionAnalyticsSnapshot` when a session reaches a
    /// terminal status. Prefers a fresh aggregate from telemetry.db — covering
    /// the relaunch-then-complete gap where the in-memory aggregate is still
    /// nil — and falls back to `SessionHookState.analytics`. Skips (with a
    /// diagnostic, #745), preserving any existing snapshot, when both are nil
    /// or empty (telemetry disabled, or a session that never produced data —
    /// the SQL aggregate is all-zeros for unknown sessions, so `isEmpty` is
    /// the real guard). `endedAt` defaults to now for live transitions; the
    /// backfill passes the session's `updatedAt` so historical sessions land
    /// in their true week instead of the current one.
    func writeAnalyticsSnapshot(for id: UUID, status: SessionStatus, endedAt: Date? = nil) async {
        guard status == .completed || status == .archived else { return }
        guard !appState.isManagerSession(id) else { return }

        let fresh = await analyticsProvider?(id)
        let analytics = (fresh?.isEmpty == false)
            ? fresh
            : appState.existingHookState(for: id)?.analytics
        guard let analytics, !analytics.isEmpty else {
            CrowLog.info(
                "[SessionService] Skipped analytics snapshot for \(id.uuidString) (\(status.rawValue)): "
                    + "no telemetry data — telemetry disabled, not restarted since enabling, "
                    + "or the session produced none")
            appState.analyticsSnapshotSkipCount += 1
            appState.lastAnalyticsSnapshotSkipAt = Date()
            return
        }

        // Compaction count only exists on the in-memory hook state — telemetry.db
        // has no compaction rows — so read it there even when `analytics` came
        // from the DB provider (#691).
        let session = appState.sessions.first(where: { $0.id == id })
        let snapshot = SessionAnalyticsSnapshot(
            sessionID: id, endedAt: endedAt ?? Date(), status: status, analytics: analytics,
            compactionCount: appState.existingHookState(for: id)?.compactionCount ?? 0,
            wallClockDurationSeconds: session?.wallClockDuration,
            alignmentWeight: session?.alignmentWeight,
            orgGoal: session?.orgGoal)
        store.mutate { data in
            var snapshots = data.analyticsSnapshots ?? [:]
            snapshots[id.uuidString] = snapshot
            data.analyticsSnapshots = snapshots
        }
        appState.analyticsSnapshots[id.uuidString] = snapshot
    }

    /// Rebuild missing analytics snapshots from telemetry.db (#745): the
    /// one-shot write at a terminal transition means sessions recorded before
    /// snapshotting existed — or whose write raced a quit — never surface on
    /// the scorecard. Runs at launch (before retention pruning) and from the
    /// manual "Rebuild scorecard" action. Idempotent: existing snapshots are
    /// never touched, so re-runs are no-ops. Skips orphaned telemetry
    /// sessions (no Crow session record — their status/endedAt would be
    /// fabricated), non-terminal sessions (they snapshot at completion), and
    /// the Manager session (tracked by `refreshManagerUsage` instead). The
    /// empty-analytics guard in `writeAnalyticsSnapshot` still applies.
    /// Returns the number of snapshots written.
    @discardableResult
    func backfillAnalyticsSnapshots() async -> Int {
        guard let telemetrySessionIDsProvider else { return 0 }
        var written = 0
        for id in await telemetrySessionIDsProvider() {
            let key = id.uuidString
            guard store.data.analyticsSnapshots?[key] == nil else { continue }
            guard let session = appState.sessions.first(where: { $0.id == id }),
                  session.status == .completed || session.status == .archived,
                  !session.isManager else { continue }
            // updatedAt, not now: the session ended historically and must
            // bucket into its true week (mirrors the quit-race backfill).
            await writeAnalyticsSnapshot(for: id, status: session.status, endedAt: session.updatedAt)
            if store.data.analyticsSnapshots?[key] != nil { written += 1 }
        }
        if written > 0 {
            CrowLog.info("[SessionService] Backfilled \(written) analytics snapshot(s) from telemetry.db")
        }
        return written
    }

    /// Composite key for a persisted Manager rollup: `"yyyy-MM-dd|<uuid>"`
    /// (CROW-983). Pre-CROW-983 rows use a bare `"yyyy-MM-dd"`, which still
    /// decodes and is read as the primary Manager — the only session #745
    /// ever queried. Legacy keys are deliberately NOT rewritten: a rename
    /// would have to be transactional against a store that other writers
    /// share, and reading them is enough.
    ///
    /// The week component is formatted with the caller's calendar rather than
    /// a `static` `DateFormatter`. The old static captured `.timeZone =
    /// .current` at first access while `refreshManagerUsage` re-reads
    /// `.current` on every call, so a mid-process timezone change could key a
    /// week under a date its own bucket boundaries disagreed with.
    static func managerWeekKey(weekStart: Date, sessionID: UUID, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: weekStart)
        let day = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return "\(day)|\(sessionID.uuidString)"
    }

    /// ISO-8601 calendar in the current timezone — the same bucketing
    /// `ScorecardModel.build` uses, so Manager weeks line up with graded weeks.
    private static func managerWeekCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }

    /// Attribute one completed compaction to the week it happened in
    /// (CROW-983). Called from the `hook-event` handler on `PostCompact` for
    /// Manager sessions.
    ///
    /// Accumulated at event time because it cannot be recomputed: telemetry.db
    /// has no compaction rows, and `SessionHookState.compactionCount` is a
    /// per-app-run running total for the session's whole life — for a session
    /// that spans months, there is no way to slice out "this week's" share
    /// after the fact. Work sessions dodge this by snapshotting once at a
    /// terminal status, which a Manager never reaches.
    func noteManagerCompaction(sessionID: UUID, now: Date = Date()) {
        let calendar = Self.managerWeekCalendar()
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return }
        let key = Self.managerWeekKey(
            weekStart: week.start, sessionID: sessionID, calendar: calendar)

        store.mutate { data in
            var rollups = data.managerUsageWeekly ?? [:]
            // A compaction can land before the week's first telemetry refresh,
            // so seed an otherwise-empty rollup rather than dropping the count.
            var rollup = rollups[key] ?? ManagerWeeklyUsage(
                weekStart: week.start, analytics: SessionAnalytics(), sessionID: sessionID)
            rollup.compactionCount = (rollup.compactionCount ?? 0) + 1
            rollups[key] = rollup
            data.managerUsageWeekly = rollups
        }
        appState.managerUsageWeekly = store.data.managerUsageWeekly ?? [:]
    }

    /// Recompute every Manager session's weekly usage rollups from telemetry.db
    /// (#745; per-Manager since CROW-983) — a Manager never reaches a terminal
    /// status, so it can't produce a `SessionAnalyticsSnapshot`. Covers the
    /// current week plus the trailing baseline window, for each Manager.
    ///
    /// Merge-only: weeks with no telemetry rows are skipped rather than zeroed
    /// (absence usually means the rows aged out of retention), so persisted
    /// rollups survive pruning. Known bounded edge: the oldest still-covered
    /// week can be partially pruned mid-week, briefly dipping its recomputed
    /// total; it self-corrects once the week ages out entirely.
    func refreshManagerUsage(now: Date = Date()) async {
        guard let managerUsageProvider else { return }
        let calendar = Self.managerWeekCalendar()
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now) else { return }

        let managerIDs = appState.managerSessions.map(\.id)
        var updates: [String: ManagerWeeklyUsage] = [:]
        for managerID in managerIDs {
            for offset in 0...EfficiencyGrading.Tuning.baselineWeekCount {
                guard let weekDate = calendar.date(
                          byAdding: .weekOfYear, value: -offset, to: currentWeek.start),
                      let interval = calendar.dateInterval(of: .weekOfYear, for: weekDate)
                else { continue }
                let analytics = await managerUsageProvider(managerID, interval.start, interval.end)
                guard !analytics.isEmpty else { continue }
                let key = Self.managerWeekKey(
                    weekStart: interval.start, sessionID: managerID, calendar: calendar)
                updates[key] = ManagerWeeklyUsage(
                    weekStart: interval.start, analytics: analytics, sessionID: managerID)
            }
        }

        guard !updates.isEmpty else { return }
        store.mutate { data in
            var rollups = data.managerUsageWeekly ?? [:]
            for (key, value) in updates {
                var merged = value
                // Compactions are carried forward, never recomputed —
                // telemetry.db has no compaction rows. Read inside the mutate,
                // not while building `updates`: this method suspends at every
                // provider `await`, and `noteManagerCompaction` runs on the
                // same actor, so a value captured before the loop finished
                // would silently drop any compaction that landed during it.
                merged.compactionCount = rollups[key]?.compactionCount
                rollups[key] = merged
            }
            data.managerUsageWeekly = rollups
        }
        appState.managerUsageWeekly = store.data.managerUsageWeekly ?? [:]
    }
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    func recordAgentLifecycleEvent(sessionID: UUID, eventName: String, at date: Date = Date()) {
        analytics.recordAgentLifecycleEvent(sessionID: sessionID, eventName: eventName, at: date)
    }

    func scheduleAnalyticsSnapshot(for id: UUID, status: SessionStatus) {
        analytics.scheduleAnalyticsSnapshot(for: id, status: status)
    }

    func writeAnalyticsSnapshot(for id: UUID, status: SessionStatus, endedAt: Date? = nil) async {
        await analytics.writeAnalyticsSnapshot(for: id, status: status, endedAt: endedAt)
    }

    @discardableResult
    public func backfillAnalyticsSnapshots() async -> Int {
        await analytics.backfillAnalyticsSnapshots()
    }

    public func noteManagerCompaction(sessionID: UUID, now: Date = Date()) {
        analytics.noteManagerCompaction(sessionID: sessionID, now: now)
    }

    public func refreshManagerUsage(now: Date = Date()) async {
        await analytics.refreshManagerUsage(now: now)
    }
}
