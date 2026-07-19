import Foundation

/// Serializes review-session kickoffs so two concurrent `start-review` RPCs
/// can't both pass `SessionService.createReviewSession`'s dedupe check for the
/// same PR before either has appended its session row. That dedupe is only
/// race-free when kickoffs run one at a time — the headless equivalent of the
/// app's `reviewKickoffTail` chain (CROW-581, M-E2 / ADR 0007).
actor ReviewKickoffSerializer {
    private var tail: Task<UUID?, Never>?

    /// Chain `op` behind any in-flight kickoff and return the task to await.
    /// Each task awaits its predecessor's value first, so by the time `op`
    /// runs the prior review's row is already in `appState`.
    func enqueue(_ op: @escaping @Sendable () async -> UUID?) -> Task<UUID?, Never> {
        let previous = tail
        let task = Task { () -> UUID? in
            _ = await previous?.value
            return await op()
        }
        tail = task
        return task
    }
}
