import Foundation
import Testing
import CrowCore
import CrowPersistence
@testable import Crow

/// End-of-session analytics snapshot persistence (#690, ADR 0008 follow-up 2).
/// Tests drive the awaitable `writeAnalyticsSnapshot` / `persistState`
/// directly rather than the fire-and-forget `Task {}` trigger, so there is no
/// timing dependence.
@MainActor
@Suite("SessionService analytics snapshot")
struct SessionServiceAnalyticsSnapshotTests {

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-analytics-snap-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private nonisolated static let sampleAnalytics = SessionAnalytics(
        totalCost: 2.5, inputTokens: 500, outputTokens: 900,
        activeTimeSeconds: 1_200, promptCount: 9, toolCallCount: 30
    )

    @Test
    func completedSessionWithProviderPersistsSnapshot() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "shipped")]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let snapshot = store.data.analyticsSnapshots?[id.uuidString]
        #expect(snapshot?.sessionID == id)
        #expect(snapshot?.status == .completed)
        #expect(snapshot?.analytics == Self.sampleAnalytics)
    }

    // Telemetry's SQL aggregate is all-zeros for a session with no rows —
    // that must never become a persisted snapshot, and it must not clobber
    // a real one written earlier.
    @Test
    func emptyProviderAggregateWritesNothingAndPreservesExisting() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "no-data")]
        let existing = SessionAnalyticsSnapshot(
            sessionID: id, endedAt: Date(timeIntervalSince1970: 1_752_000_000),
            status: .completed, analytics: Self.sampleAnalytics)
        store.mutate { $0.analyticsSnapshots = [id.uuidString: existing] }

        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in SessionAnalytics() })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        #expect(store.data.analyticsSnapshots?[id.uuidString] == existing)
    }

    // Telemetry disabled (nil provider): fall back to the in-memory aggregate.
    @Test
    func nilProviderFallsBackToInMemoryAnalytics() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "in-memory")]
        appState.hookState(for: id).analytics = Self.sampleAnalytics
        let service = SessionService(store: store, appState: appState)

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        #expect(store.data.analyticsSnapshots?[id.uuidString]?.analytics == Self.sampleAnalytics)
    }

    // The relaunch-then-complete gap: in-memory analytics is nil after a
    // relaunch until new telemetry arrives, but telemetry.db still has the
    // session's rows — the fresh provider aggregate wins.
    @Test
    func providerWinsWhenInMemoryIsNil() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "post-relaunch")]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .archived)

        let snapshot = store.data.analyticsSnapshots?[id.uuidString]
        #expect(snapshot?.analytics == Self.sampleAnalytics)
        #expect(snapshot?.status == .archived)
    }

    // A session with no telemetry at all ends gracefully: no crash, no entry.
    @Test
    func noTelemetryAnywhereWritesNothing() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "telemetry-off")]
        let service = SessionService(store: store, appState: appState)

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        #expect(store.data.analyticsSnapshots?[id.uuidString] == nil)
    }

    // Re-ending a session (resume → end again) updates the one entry rather
    // than duplicating — and records the newest status and aggregate.
    @Test
    func reEndingUpdatesInsteadOfDuplicating() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "resumed")]
        let firstRun = Self.sampleAnalytics
        var secondRun = Self.sampleAnalytics
        secondRun.promptCount = 20

        let firstEnd = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in firstRun })
        await firstEnd.writeAnalyticsSnapshot(for: id, status: .completed)

        let secondEnd = SessionService(
            store: store, appState: appState,
            analyticsProvider: { [secondRun] _ in secondRun })
        await secondEnd.writeAnalyticsSnapshot(for: id, status: .archived)

        let snapshots = store.data.analyticsSnapshots
        #expect(snapshots?.count == 1)
        #expect(snapshots?[id.uuidString]?.status == .archived)
        #expect(snapshots?[id.uuidString]?.analytics.promptCount == 20)
    }

    @Test
    func nonTerminalStatusAndManagerWriteNothing() async {
        let store = Self.tempStore()
        let appState = AppState()
        let workID = UUID()
        appState.sessions = [
            Session(id: workID, name: "in-flight"),
            Session(id: AppState.managerSessionID, name: "Manager", kind: .manager),
        ]
        appState.hookState(for: workID).analytics = Self.sampleAnalytics
        appState.hookState(for: AppState.managerSessionID).analytics = Self.sampleAnalytics
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: workID, status: .active)
        await service.writeAnalyticsSnapshot(for: workID, status: .inReview)
        await service.writeAnalyticsSnapshot(for: AppState.managerSessionID, status: .completed)

        #expect(store.data.analyticsSnapshots == nil)
    }

    // The persisted snapshot must read back after a simulated relaunch.
    @Test
    func snapshotSurvivesSimulatedRelaunch() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-analytics-relaunch-\(UUID().uuidString)")
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "durable")]
        let service = SessionService(
            store: JSONStore(directory: dir), appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let reloaded = JSONStore(directory: dir)
        let snapshot = reloaded.data.analyticsSnapshots?[id.uuidString]
        #expect(snapshot?.analytics == Self.sampleAnalytics)
        #expect(snapshot?.status == .completed)
    }

    // #691: two completed compactions persist as 2 on the snapshot and read
    // back after a simulated relaunch. Routed through noteCompactionEvent —
    // the hook-handler seam — so PreCompact is exercised as a non-increment.
    @Test
    func compactionCountPersistsAndSurvivesSimulatedRelaunch() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-compaction-relaunch-\(UUID().uuidString)")
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "compacted-twice")]
        let hookState = appState.hookState(for: id)
        hookState.noteCompactionEvent("PreCompact")
        hookState.noteCompactionEvent("PostCompact")
        hookState.noteCompactionEvent("PreCompact")
        hookState.noteCompactionEvent("PostCompact")
        let service = SessionService(
            store: JSONStore(directory: dir), appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let reloaded = JSONStore(directory: dir)
        #expect(reloaded.data.analyticsSnapshots?[id.uuidString]?.compactionCount == 2)
    }

    // #691: a session that never compacted persists an explicit 0.
    @Test
    func zeroCompactionsPersistsZero() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "never-compacted")]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        #expect(store.data.analyticsSnapshots?[id.uuidString]?.compactionCount == 0)
    }

    // Quit-race backfill: a terminal transition's async snapshot write can be
    // beaten by a fast quit; persistState backfills from the in-memory
    // aggregate — but never overwrites an existing snapshot.
    @Test
    func persistStateBackfillsMissingSnapshotOnly() async {
        let store = Self.tempStore()
        let appState = AppState()

        var ended = Session(id: UUID(), name: "ended-then-quit")
        ended.status = .completed
        ended.updatedAt = Date(timeIntervalSince1970: 1_752_100_000)

        var alreadySnapshotted = Session(id: UUID(), name: "already-done")
        alreadySnapshotted.status = .completed

        var stillActive = Session(id: UUID(), name: "active")
        stillActive.status = .active

        appState.sessions = [ended, alreadySnapshotted, stillActive]
        appState.hookState(for: ended.id).analytics = Self.sampleAnalytics
        appState.hookState(for: ended.id).noteCompactionEvent("PostCompact")
        appState.hookState(for: alreadySnapshotted.id).analytics = Self.sampleAnalytics
        appState.hookState(for: stillActive.id).analytics = Self.sampleAnalytics

        let existing = SessionAnalyticsSnapshot(
            sessionID: alreadySnapshotted.id,
            endedAt: Date(timeIntervalSince1970: 1_752_000_000),
            status: .archived, analytics: SessionAnalytics(promptCount: 1))
        store.mutate { $0.analyticsSnapshots = [alreadySnapshotted.id.uuidString: existing] }

        let service = SessionService(store: store, appState: appState)
        service.persistState()

        let snapshots = store.data.analyticsSnapshots
        // Backfilled for the ended session, stamped with its transition time,
        // carrying the compaction count (#691).
        #expect(snapshots?[ended.id.uuidString]?.analytics == Self.sampleAnalytics)
        #expect(snapshots?[ended.id.uuidString]?.endedAt == ended.updatedAt)
        #expect(snapshots?[ended.id.uuidString]?.compactionCount == 1)
        // Existing snapshot untouched (DB-derived, at least as fresh).
        #expect(snapshots?[alreadySnapshotted.id.uuidString] == existing)
        // Non-terminal sessions never snapshot.
        #expect(snapshots?[stillActive.id.uuidString] == nil)
    }

    // MARK: - Wall-clock duration (#692, ADR 0008 follow-up 4)

    // The ADR's role separation: wall-clock duration is display-only context;
    // analytics.activeTimeSeconds is the authoritative penalty-normalization
    // clock. An idle-overnight session (8h wall-clock, 20m active) persists
    // both values distinctly — neither substitutes for the other.
    @Test
    func snapshotCarriesWallClockDistinctFromActiveTime() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_752_000_000)
        appState.sessions = [Session(
            id: id, name: "idle-overnight",
            agentSessionStartedAt: start,
            agentSessionEndedAt: start.addingTimeInterval(28_800))]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let snapshot = store.data.analyticsSnapshots?[id.uuidString]
        #expect(snapshot?.wallClockDurationSeconds == 28_800)
        #expect(snapshot?.analytics.activeTimeSeconds == Self.sampleAnalytics.activeTimeSeconds)
        #expect(snapshot?.wallClockDurationSeconds != snapshot?.analytics.activeTimeSeconds)
    }

    // A session that never saw a SessionEnd (non-Claude agents don't send one;
    // or the agent was killed) still snapshots its analytics — with a nil
    // wall-clock, never a fabricated one.
    @Test
    func openEndedSessionSnapshotsNilWallClock() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(
            id: id, name: "open-ended",
            agentSessionStartedAt: Date(timeIntervalSince1970: 1_752_000_000))]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let snapshot = store.data.analyticsSnapshots?[id.uuidString]
        #expect(snapshot != nil)
        #expect(snapshot?.wallClockDurationSeconds == nil)
    }

    // The quit-race backfill path carries the duration too.
    @Test
    func persistStateBackfillCarriesWallClock() async {
        let store = Self.tempStore()
        let appState = AppState()
        let start = Date(timeIntervalSince1970: 1_752_000_000)
        var ended = Session(
            id: UUID(), name: "ended-then-quit",
            agentSessionStartedAt: start,
            agentSessionEndedAt: start.addingTimeInterval(4_500))
        ended.status = .completed
        appState.sessions = [ended]
        appState.hookState(for: ended.id).analytics = Self.sampleAnalytics

        let service = SessionService(store: store, appState: appState)
        service.persistState()

        #expect(store.data.analyticsSnapshots?[ended.id.uuidString]?
            .wallClockDurationSeconds == 4_500)
    }

    // Both the session's lifecycle stamps and the snapshot's duration copy
    // must read back after a simulated relaunch.
    @Test
    func wallClockSurvivesSimulatedRelaunch() async {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-wallclock-relaunch-\(UUID().uuidString)")
        let appState = AppState()
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_752_000_000)
        let session = Session(
            id: id, name: "durable-duration",
            agentSessionStartedAt: start,
            agentSessionEndedAt: start.addingTimeInterval(3_600))
        appState.sessions = [session]
        let store = JSONStore(directory: dir)
        store.mutate { $0.sessions = [session] }
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let reloaded = JSONStore(directory: dir)
        let restored = reloaded.data.sessions.first(where: { $0.id == id })
        #expect(restored?.agentSessionStartedAt == start)
        #expect(restored?.agentSessionEndedAt == start.addingTimeInterval(3_600))
        #expect(restored?.wallClockDuration == 3_600)
        #expect(reloaded.data.analyticsSnapshots?[id.uuidString]?
            .wallClockDurationSeconds == 3_600)
    }

    // MARK: - Alignment weight + org goal (#696, ADR 0008 follow-up 8)

    // A tagged, high-priority session snapshots its alignment weight (the
    // future v2 multiplicand) and goal at session end.
    @Test
    func snapshotCarriesAlignmentWeightAndOrgGoal() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(
            id: id, name: "aligned",
            orgGoal: "Q3 latency KPI", ticketPriority: .high)]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let snapshot = store.data.analyticsSnapshots?[id.uuidString]
        #expect(snapshot?.alignmentWeight
            == AlignmentWeight.weight(priority: .high, hasOrgGoal: true))
        #expect(snapshot?.orgGoal == "Q3 latency KPI")
    }

    // An untagged session snapshots the exact neutral weight — the
    // "done ≠ value" fix cannot regress anyone who never tags.
    @Test
    func untaggedSessionSnapshotsNeutralWeight() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        appState.sessions = [Session(id: id, name: "untagged")]
        let service = SessionService(
            store: store, appState: appState,
            analyticsProvider: { _ in Self.sampleAnalytics })

        await service.writeAnalyticsSnapshot(for: id, status: .completed)

        let snapshot = store.data.analyticsSnapshots?[id.uuidString]
        #expect(snapshot?.alignmentWeight == AlignmentWeight.neutral)
        #expect(snapshot?.orgGoal == nil)
    }

    // The quit-race backfill path carries the alignment fields too.
    @Test
    func persistStateBackfillCarriesAlignmentFields() async {
        let store = Self.tempStore()
        let appState = AppState()
        var ended = Session(
            id: UUID(), name: "aligned-then-quit",
            orgGoal: "Q3 latency KPI", ticketPriority: .highest)
        ended.status = .completed
        appState.sessions = [ended]
        appState.hookState(for: ended.id).analytics = Self.sampleAnalytics

        let service = SessionService(store: store, appState: appState)
        service.persistState()

        let snapshot = store.data.analyticsSnapshots?[ended.id.uuidString]
        #expect(snapshot?.alignmentWeight
            == AlignmentWeight.weight(priority: .highest, hasOrgGoal: true))
        #expect(snapshot?.orgGoal == "Q3 latency KPI")
    }

    // setOrgGoal mutates both live state and the store; clearing goes back to
    // nil (not empty string) so the weight returns to neutral.
    @Test
    func setOrgGoalPersistsAndClears() async {
        let store = Self.tempStore()
        let appState = AppState()
        let id = UUID()
        let session = Session(id: id, name: "taggable")
        appState.sessions = [session]
        store.mutate { $0.sessions = [session] }
        let service = SessionService(store: store, appState: appState)

        service.setOrgGoal(id: id, goal: "Q3 latency KPI")
        #expect(appState.sessions[0].orgGoal == "Q3 latency KPI")
        #expect(store.data.sessions.first(where: { $0.id == id })?.orgGoal == "Q3 latency KPI")

        service.setOrgGoal(id: id, goal: nil)
        #expect(appState.sessions[0].orgGoal == nil)
        #expect(store.data.sessions.first(where: { $0.id == id })?.orgGoal == nil)
        #expect(appState.sessions[0].alignmentWeight == AlignmentWeight.neutral)
    }
}
