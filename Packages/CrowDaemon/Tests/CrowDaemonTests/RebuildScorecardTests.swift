import Foundation
import Testing
import CrowCore
import CrowIPC
import CrowPersistence
import CrowGit
@testable import CrowDaemon

/// #767/#781: the `rebuild-scorecard` RPC and its single-flight coalescer. The
/// DTO/reseed paths are covered elsewhere (`ScorecardDTOTests`,
/// `reseedSurfacesPersistedManagerWeeksOnScorecard`); these pin the handler's
/// telemetry-off error and that success is only ever reported for real work.
@Suite struct RebuildScorecardHandlerTests {
    @MainActor
    private func router(rebuildScorecard: (@MainActor @Sendable () async -> Void)?) -> CommandRouter {
        makeCommandRouter(
            appState: AppState(), store: JSONStore.temporary(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil,
            rebuildScorecard: rebuildScorecard)
    }

    @Test @MainActor func errorsWhenTelemetryUnavailable() async {
        // nil closure == telemetry off / receiver never came up: there is no DB
        // to rebuild from, so the RPC must error rather than invent success.
        let resp = await router(rebuildScorecard: nil)
            .handle(request: JSONRPCRequest(id: 1, method: "rebuild-scorecard"))
        #expect(resp.error?.code == RPCErrorCode.applicationError)
        #expect(resp.result == nil)
    }

    @Test @MainActor func invokesRebuildAndReportsSuccess() async {
        let ran = Counter()
        let resp = await router(rebuildScorecard: { ran.bump() })
            .handle(request: JSONRPCRequest(id: 1, method: "rebuild-scorecard"))
        #expect(resp.error == nil)
        #expect(resp.result?["rebuilt"]?.boolValue == true)
        #expect(ran.value == 1) // the handler actually drove a rebuild
    }
}

@Suite struct ScorecardRebuilderTests {
    /// A caller arriving while a rebuild is in flight coalesces into it — the
    /// whole point: the RPC must not report success for a rebuild it skipped, and
    /// two runs must not race the same telemetry.db.
    @Test @MainActor func coalescesOverlappingCallers() async {
        let runs = Counter()
        let gate = Gate()
        let rebuilder = ScorecardRebuilder {
            runs.bump()
            await gate.wait() // hold this rebuild open while a second caller arrives
        }
        // Start the first rebuild and deterministically wait until its work has
        // actually begun (and is now blocked on the gate) before the second call —
        // so the second is guaranteed to observe an in-flight rebuild, not a race.
        let first = Task { await rebuilder.rebuild() }
        while runs.value == 0 { await Task.yield() }
        let second = Task { await rebuilder.rebuild() }
        await Task.yield() // let `second` reach its `await inFlight.value`

        gate.open()
        await first.value
        await second.value
        #expect(runs.value == 1) // second coalesced, did not start its own run

        // Once settled, `inFlight` is cleared, so a fresh call runs again.
        await rebuilder.rebuild()
        #expect(runs.value == 2)
    }
}

/// Main-isolated mutable counters/gates for the async assertions above — plain
/// `var` capture isn't allowed in the `@Sendable` rebuild closures.
@MainActor private final class Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}

@MainActor private final class Gate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func open() {
        opened = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}
