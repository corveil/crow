import Foundation

/// Single-flight coalescer for the scorecard rebuild (#767, #781).
///
/// Launch, the hourly poll, and the `rebuild-scorecard` RPC all funnel through
/// `rebuild()`. A caller that arrives while a rebuild is running awaits *that*
/// rebuild instead of starting a second one — so the RPC never reports success
/// for work it skipped, and two runs can't race the same telemetry.db or clear
/// `isRebuildingScorecard` out from under each other. Every caller returns only
/// once a full rebuild has completed.
///
/// Main-isolated, so the `inFlight` check-and-set is atomic without a lock.
@MainActor
final class ScorecardRebuilder {
    private let work: @MainActor @Sendable () async -> Void
    private var inFlight: Task<Void, Never>?

    init(work: @escaping @MainActor @Sendable () async -> Void) {
        self.work = work
    }

    /// Run `work`, or await the in-flight run if one is already going. Returns
    /// only after a full rebuild has finished.
    func rebuild() async {
        if let inFlight {
            return await inFlight.value
        }
        // `defer` clears `inFlight` on the main actor as the task's last act, so
        // there is no window where it points at an already-finished task (which
        // would make the next caller coalesce into a completed no-op).
        let task = Task { @MainActor [work] in
            defer { self.inFlight = nil }
            await work()
        }
        inFlight = task
        await task.value
    }
}
