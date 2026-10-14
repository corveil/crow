import CrowCore
import Foundation

/// Serializes review-session kickoffs so two concurrent `start-review` RPCs
/// can't both pass `SessionService.createReviewSession`'s dedupe check for the
/// same PR before either has appended its session row. That dedupe is only
/// race-free when kickoffs run one at a time — the headless equivalent of the
/// app's `reviewKickoffTail` chain (CROW-581, M-E2 / ADR 0007).
///
/// Each kickoff is bounded by ``timeout``. One task that never finishes — a
/// `git checkout` blocked on a full pipe, a prompt on an inherited TTY — used
/// to pin every later review for the life of the daemon (CROW-1323). The
/// chain advances when the timeout fires, the in-flight operation is
/// cancelled (which terminates its child process), and a line is written to
/// `crowd-automation.log`.
actor ReviewKickoffSerializer {
    /// Long enough for a large `gh repo clone` plus checkout. Short enough
    /// that one stuck child costs one review interval, not the rest of the day.
    static let defaultTimeout: Duration = .seconds(15 * 60)

    private var tail: Task<UUID?, Never>?
    private let timeout: Duration

    init(timeout: Duration = ReviewKickoffSerializer.defaultTimeout) {
        self.timeout = timeout
    }

    /// Chain `op` behind any in-flight kickoff and return the task to await.
    /// Each task awaits its predecessor's value first, so by the time `op`
    /// runs the prior review's row is already in `appState` — unless that
    /// predecessor timed out, in which case it has been cancelled and the
    /// chain has moved on.
    ///
    /// `url` is only for the timeout log line.
    func enqueue(url: String = "", _ op: @escaping @Sendable () async -> UUID?) -> Task<UUID?, Never> {
        let previous = tail
        let timeout = self.timeout
        let task = Task { () -> UUID? in
            _ = await previous?.value
            return await Self.run(op, timeout: timeout, url: url)
        }
        tail = task
        return task
    }

    /// Race `op` against `timeout`. The returned value does not wait for an
    /// operation that ignores cancellation: the next kickoff only awaits this
    /// function, and this function returns as soon as either side wins.
    private static func run(
        _ op: @escaping @Sendable () async -> UUID?,
        timeout: Duration,
        url: String
    ) async -> UUID? {
        let gate = KickoffGate()
        let box = TaskBox()
        return await withCheckedContinuation { (cont: CheckedContinuation<UUID?, Never>) in
            // Timer first so a fast `op` always observes a task it can cancel.
            box.storeTimer(Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                guard gate.claim() else { return }
                box.cancelOp()
                let target = url.isEmpty ? "(no url)" : url
                CrowLog.automation("[ReviewKickoff] timed out after \(phrase(timeout)) for \(target)")
                cont.resume(returning: nil)
            })
            box.storeOp(Task {
                let id = await op()
                guard gate.claim() else { return }
                box.cancelTimer()
                cont.resume(returning: id)
            })
        }
    }

    /// `900s` for a whole-second timeout, `150ms` otherwise. The operator
    /// line is `[ReviewKickoff] timed out after Ns for <url>`.
    /// Nonisolated so the timeout task and tests can format it without
    /// hopping onto the serializer actor.
    nonisolated static func phrase(_ timeout: Duration) -> String {
        let components = timeout.components
        if components.attoseconds == 0 {
            return "\(components.seconds)s"
        }
        let milliseconds = (Double(components.seconds) * 1000)
            + (Double(components.attoseconds) / 1e15)
        return "\(Int(milliseconds.rounded()))ms"
    }
}

/// First caller wins. The loser must not resume the continuation.
private final class KickoffGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Lets the timer and the operation cancel each other. The lock publishes
/// each task to the other side; the timer only reads the operation after
/// its sleep, and the operation only reads the timer after `op` returns.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var op: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func storeTimer(_ task: Task<Void, Never>) {
        lock.lock()
        timer = task
        lock.unlock()
    }

    func storeOp(_ task: Task<Void, Never>) {
        lock.lock()
        op = task
        lock.unlock()
    }

    func cancelOp() {
        lock.lock()
        let task = op
        lock.unlock()
        task?.cancel()
    }

    func cancelTimer() {
        lock.lock()
        let task = timer
        lock.unlock()
        task?.cancel()
    }
}
