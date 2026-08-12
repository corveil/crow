import Foundation
import Testing
import CrowCore
import CrowPersistence
@testable import CrowEngine

/// CROW-983: Manager weekly rollups are per-Manager, and their compaction
/// counts are accumulated at event time rather than recomputed.
///
/// Before this, `refreshManagerUsage` read a provider that hardcoded the
/// well-known primary UUID, so a second Manager was not merged into one
/// bucket — it contributed nothing at all.
@Suite("SessionService Manager usage rollups")
struct SessionServiceManagerUsageTests {

    /// Records which (session, window) tuples the provider was asked for, and
    /// answers from a fixture table. A class so MainActor assertions read it
    /// without hopping.
    @MainActor
    private final class UsageProvider {
        /// sessionID → analytics returned for every requested week.
        var perSession: [UUID: SessionAnalytics] = [:]
        var requested: [UUID] = []

        func analytics(for id: UUID) -> SessionAnalytics {
            requested.append(id)
            return perSession[id] ?? SessionAnalytics()
        }
    }

    private static func tempStore() -> JSONStore {
        JSONStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-mgr-usage-\(UUID().uuidString)"))
    }

    private static func analytics(cost: Double, prompts: Int) -> SessionAnalytics {
        SessionAnalytics(
            totalCost: cost, inputTokens: 1000, activeTimeSeconds: 600, promptCount: prompts)
    }

    @MainActor
    private func service(
        appState: AppState, store: JSONStore, provider: UsageProvider
    ) -> SessionService {
        SessionService(
            store: store, appState: appState,
            managerUsageProvider: { id, _, _ in
                await MainActor.run { provider.analytics(for: id) }
            })
    }

    @Test @MainActor
    func eachManagerGetsItsOwnRollup() async {
        let primary = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
        let second = Session(name: "Manager 2", kind: .manager)
        let work = Session(name: "some-feature", kind: .work)
        let appState = AppState()
        appState.sessions = [primary, second, work]

        let provider = UsageProvider()
        provider.perSession[primary.id] = Self.analytics(cost: 3, prompts: 20)
        provider.perSession[second.id] = Self.analytics(cost: 7, prompts: 40)

        let store = Self.tempStore()
        await service(appState: appState, store: store, provider: provider)
            .refreshManagerUsage()

        let rollups = store.data.managerUsageWeekly ?? [:]
        // Both Managers are metered, and only Managers — the work session's
        // telemetry belongs to the graded snapshot pipeline.
        #expect(Set(provider.requested) == [primary.id, second.id])
        let byManager = Dictionary(grouping: rollups.values, by: { $0.sessionID })
        #expect(byManager[primary.id]?.allSatisfy { $0.analytics.totalCost == 3 } == true)
        #expect(byManager[second.id]?.allSatisfy { $0.analytics.totalCost == 7 } == true)
        // Current week + the trailing baseline window, per Manager.
        let weeksPerManager = EfficiencyGrading.Tuning.baselineWeekCount + 1
        #expect(byManager[primary.id]?.count == weeksPerManager)
        #expect(byManager[second.id]?.count == weeksPerManager)
        // Keys are composite, so the two Managers cannot collide.
        #expect(rollups.count == weeksPerManager * 2)
    }

    @Test @MainActor
    func compactionsAccumulateAndSurviveARefresh() async {
        let manager = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
        let appState = AppState()
        appState.sessions = [manager]

        let provider = UsageProvider()
        provider.perSession[manager.id] = Self.analytics(cost: 3, prompts: 20)
        let store = Self.tempStore()
        let svc = service(appState: appState, store: store, provider: provider)

        svc.noteManagerCompaction(sessionID: manager.id)
        svc.noteManagerCompaction(sessionID: manager.id)

        // A compaction can land before the week's first telemetry refresh, so
        // the counter seeds its own rollup rather than being dropped.
        let seeded = (store.data.managerUsageWeekly ?? [:]).values
            .first { $0.sessionID == manager.id && $0.compactionCount != nil }
        #expect(seeded?.compactionCount == 2)

        // The refresh overwrites analytics from telemetry — which has no
        // compaction rows — so it must carry the accumulated count forward.
        await svc.refreshManagerUsage()

        let current = (store.data.managerUsageWeekly ?? [:]).values
            .first { $0.compactionCount != nil }
        #expect(current?.compactionCount == 2)
        #expect(current?.analytics.totalCost == 3)

        // And a further compaction still adds on top of the refreshed row.
        svc.noteManagerCompaction(sessionID: manager.id)
        let after = (store.data.managerUsageWeekly ?? [:]).values
            .first { $0.compactionCount != nil }
        #expect(after?.compactionCount == 3)
        #expect(after?.analytics.totalCost == 3)
    }

    /// A compaction that lands *during* a refresh must not be lost.
    /// `refreshManagerUsage` suspends at every provider `await`, and
    /// `noteManagerCompaction` runs on the same actor — so if the carry-forward
    /// read its value while building the update set rather than inside the
    /// final `store.mutate`, the write would clobber the increment.
    @Test @MainActor
    func compactionDuringARefreshIsNotLost() async {
        let manager = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
        let appState = AppState()
        appState.sessions = [manager]
        let store = Self.tempStore()

        let provider = UsageProvider()
        provider.perSession[manager.id] = Self.analytics(cost: 3, prompts: 20)

        // Build the service first so the provider closure can reach it.
        var svc: SessionService?
        let service = SessionService(
            store: store, appState: appState,
            managerUsageProvider: { id, _, _ in
                await MainActor.run {
                    // Interleave exactly where the real hook handler would:
                    // while the refresh is suspended on this provider call.
                    svc?.noteManagerCompaction(sessionID: AppState.managerSessionID)
                    return provider.analytics(for: id)
                }
            })
        svc = service

        await service.refreshManagerUsage()

        // One compaction per provider call, all in the current week — only the
        // current-week key can hold them, and none may be dropped.
        let weeks = EfficiencyGrading.Tuning.baselineWeekCount + 1
        let total = (store.data.managerUsageWeekly ?? [:]).values
            .compactMap(\.compactionCount).reduce(0, +)
        #expect(total == weeks)
    }

    @Test @MainActor
    func agedOutWeeksKeepTheirPersistedRollup() async {
        let manager = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
        let appState = AppState()
        appState.sessions = [manager]
        let store = Self.tempStore()

        // A historical week whose telemetry rows have since aged out of
        // retention: the merge-only write must not zero it.
        let old = ManagerWeeklyUsage(
            weekStart: Date(timeIntervalSince1970: 1_700_000_000),
            analytics: Self.analytics(cost: 42, prompts: 99),
            sessionID: manager.id)
        store.mutate { $0.managerUsageWeekly = ["2023-11-13|\(manager.id.uuidString)": old] }

        let provider = UsageProvider()
        provider.perSession[manager.id] = Self.analytics(cost: 3, prompts: 20)
        await service(appState: appState, store: store, provider: provider)
            .refreshManagerUsage()

        #expect(store.data.managerUsageWeekly?["2023-11-13|\(manager.id.uuidString)"] == old)
    }

    /// An all-zeros aggregate means "no rows", not "a real zero week" — so a
    /// week with no telemetry is skipped rather than written.
    @Test @MainActor
    func emptyWeeksAreSkippedNotZeroed() async {
        let manager = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
        let appState = AppState()
        appState.sessions = [manager]
        let store = Self.tempStore()

        // Provider returns an empty aggregate for every week.
        await service(appState: appState, store: store, provider: UsageProvider())
            .refreshManagerUsage()

        #expect((store.data.managerUsageWeekly ?? [:]).isEmpty)
    }

    @Test @MainActor
    func noManagerSessionsMeansNoRollups() async {
        let appState = AppState()
        appState.sessions = [Session(name: "just-work", kind: .work)]
        let provider = UsageProvider()
        let store = Self.tempStore()

        await service(appState: appState, store: store, provider: provider)
            .refreshManagerUsage()

        #expect(provider.requested.isEmpty)
        #expect((store.data.managerUsageWeekly ?? [:]).isEmpty)
    }
}
