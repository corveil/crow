import Foundation

/// Per-connection dispatcher for `/rpc` requests (#931).
///
/// The reader task used to `await commandRouter.handle(request:)` inline, so one
/// slow method held the socket's read loop and everything queued behind it hit
/// the browser's timeout — a `refresh-tickets` behind a `gh` call stalled the
/// unrelated `set-status` the user clicked next. The reader now hands each
/// request here and immediately reads the next frame.
///
/// Three invariants, in the order they matter:
///
/// 1. **Lane ordering.** Requests in the same ``Lane`` run one at a time in
///    arrival order, via a `Task` chain per lane — the same shape as
///    ``ReviewKickoffSerializer``, whose single global chain this generalizes to
///    one chain per lane. `set-status` then `complete-session` on one session
///    still cannot reorder.
/// 2. **Bounded work.** At most `maxConcurrent` operations *execute* at once,
///    and at most `maxInFlight` are *accepted* before the dispatcher refuses.
///    A queued lane task waits for its predecessor **before** taking a permit,
///    never while holding one — see ``run(id:lane:predecessor:operation:)``.
/// 3. **Drain before finish.** ``drain()`` returns only once every accepted
///    operation has yielded its response, so the reader can end the writer's
///    stream without truncating a reply. ``shutdown()`` releases every waiter so
///    an abnormal close never parks the reader.
///
/// One instance per connection, created in `onUpgrade`. Nothing is shared
/// between connections — the daemon already served those concurrently
/// (`SocketServer` dispatches each CLI connection to the global concurrent
/// queue, and every browser tab is its own upgrade), so this change makes
/// intra-connection concurrency match the inter-connection concurrency that
/// already existed rather than introducing a new kind.
actor RPCDispatcher {

    /// A serialization lane. Same lane → strict arrival order. Different lanes,
    /// and lane-less requests, run concurrently.
    ///
    /// Ordering is **not** preserved *across* lanes: a `set-config` and a
    /// `set-status` sent back to back can land in either order. That is the
    /// deliberate cost of the fix, and it matches what two open browser tabs
    /// could already produce. Every `app.js` call site awaits its response
    /// before issuing a dependent one.
    enum Lane: Hashable, Sendable {
        /// Serialize on one request parameter's value — `session_id`,
        /// `terminal_id`, `job_id`. The parameter *name* is part of the key so a
        /// session UUID and a terminal UUID can never collide into one lane.
        case param(name: String, value: String)

        /// The `config.json` read-modify-write family.
        ///
        /// Two reasons, and the second is the load-bearing one:
        /// `ConfigStore.withConfigLock` already makes each mutation atomic, so
        /// the lane is what keeps two *pipelined* mutations from landing out of
        /// order — but that lock is an `NSLock` held across synchronous disk
        /// I/O, so concurrent config writers would **block cooperative-pool
        /// threads**, the shape that wedged the daemon in #874. One lane means
        /// `/rpc` never contends for that lock with itself.
        case config

        /// The Manager window and the tmux server it lives in. Typing into the
        /// Manager (`work-on-issue`) must not race creating or restarting it.
        case manager

        /// `start-review` / `batch-start-review`. They already funnel through
        /// ``ReviewKickoffSerializer`` — and `start-review` *awaits* its chained
        /// task, so without a lane N pipelined kickoffs would each hold a
        /// concurrency permit for the whole serialized clone-and-spawn run and
        /// re-create #931 one level down.
        case reviewKickoff

        /// Whole-board provider sweeps (`resync-jira`), which walk every session
        /// and transition its ticket. Two at once would double every provider
        /// call.
        case tracker

        /// The user-initiated historical backfill (`backfill-upload`, CROW-1075).
        /// A single long upload run serializes against itself — two concurrent
        /// backfills would double the provider validation and upload work — while
        /// staying off the `config` lane so a lengthy backfill never blocks
        /// ordinary Settings saves.
        case backfill
    }

    // MARK: - Configuration

    /// Ceiling on operations executing at once.
    ///
    /// Deliberately small. Most handlers hop to `@MainActor`, which is the real
    /// bottleneck — raising this buys queueing, not throughput — and several
    /// take `ConfigStore.withConfigLock`, an `NSLock` that blocks a cooperative
    /// thread while held. 8 keeps blocked threads well under the pool width on
    /// any host `crowd` runs on, and the ``Lane/config`` lane keeps `/rpc`'s own
    /// contribution to that lock at one.
    private let maxConcurrent: Int

    /// Ceiling on operations *accepted* per connection before ``dispatch(lane:operation:)``
    /// starts refusing.
    ///
    /// Non-blocking rejection rather than reader backpressure, matching
    /// `TerminalConnectionLimiter`: a client holding 64 requests open on one
    /// socket is not one the daemon should quietly queue for. The web UI never
    /// exceeds a handful, so this only fires on a runaway caller — which learns
    /// immediately instead of timing out 64 times.
    private let maxInFlight: Int

    // MARK: - State

    private struct LaneTail {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var lanes: [Lane: LaneTail] = [:]
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var inFlight = 0
    private var running = 0
    private var permitWaiters: [CheckedContinuation<Bool, Never>] = []
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false

    init(maxConcurrent: Int = 8, maxInFlight: Int = 64) {
        self.maxConcurrent = maxConcurrent
        self.maxInFlight = maxInFlight
    }

    // MARK: - Introspection (tests)

    /// Live lane count. Zero once every chain has drained — the assertion that
    /// the lane map is bounded by *live* lanes rather than by every session id a
    /// long-lived connection has ever addressed.
    var laneCount: Int { lanes.count }
    var inFlightCount: Int { inFlight }
    var runningCount: Int { running }

    // MARK: - Dispatch

    /// Accept `operation` for execution, ordered behind anything already queued
    /// in `lane`. Returns immediately — the operation runs on its own task.
    ///
    /// Returns `false` when the connection is at its in-flight ceiling or the
    /// dispatcher has shut down; the caller answers the request itself rather
    /// than dropping it, since a dropped request would sit until the client's
    /// deadline — the exact symptom this change exists to remove.
    @discardableResult
    func dispatch(lane: Lane?, operation: @escaping @Sendable () async -> Void) -> Bool {
        guard !isShutDown, inFlight < maxInFlight else { return false }
        inFlight += 1

        let id = UUID()
        let predecessor = lane.flatMap { lanes[$0]?.task }
        let task = Task {
            await self.run(id: id, lane: lane, predecessor: predecessor, operation: operation)
        }
        pending[id] = task
        if let lane { lanes[lane] = LaneTail(id: id, task: task) }
        return true
    }

    /// Return once every accepted operation has yielded its response.
    ///
    /// Called by the reader after inbound closes, so ending the writer's stream
    /// cannot truncate a reply that is still being computed. ``shutdown()`` also
    /// releases this, so a reader parked here when the *writer* is what died
    /// unwinds instead of hanging the connection's task group.
    func drain() async {
        guard inFlight > 0, !isShutDown else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            drainWaiters.append(c)
        }
    }

    /// Stop accepting, cancel every chain, and release every waiter.
    ///
    /// Cancellation reaches the *waiting*, not the running: `CommandRouter`
    /// handlers are not cancellation-aware (most are a synchronous
    /// `MainActor.run`), so an `add-worktree` already inside `git` finishes its
    /// work exactly as it does today. What this guarantees is that nothing is
    /// left suspended on a lane predecessor, a permit, or ``drain()``.
    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true

        for task in pending.values { task.cancel() }

        let permits = permitWaiters
        permitWaiters.removeAll()
        for c in permits { c.resume(returning: false) }

        let drains = drainWaiters
        drainWaiters.removeAll()
        for c in drains { c.resume() }
    }

    // MARK: - Internals

    /// The body of every dispatched task.
    ///
    /// `nonisolated` on purpose: a `Task {}` created inside an actor inherits
    /// that actor's isolation, which would run each operation's non-suspended
    /// stretches — including JSON encoding — on the dispatcher itself. Hopping
    /// straight out keeps the actor to the four short isolated calls below.
    ///
    /// **The permit is taken after the lane wait, never before.** A task parked
    /// on its predecessor holds nothing, so (a) a burst on one session cannot
    /// starve the pool, and (b) the classic deadlock — every permit held by a
    /// task waiting on a predecessor that can never get a permit — is
    /// structurally impossible: a permit holder only ever waits on `operation`,
    /// which waits on nothing this actor owns.
    private nonisolated func run(
        id: UUID,
        lane: Lane?,
        predecessor: Task<Void, Never>?,
        operation: @escaping @Sendable () async -> Void
    ) async {
        if let predecessor {
            await predecessor.value
        }
        if !Task.isCancelled, await acquirePermit() {
            await operation()
            await releasePermit()
        }
        await complete(id: id, lane: lane)
    }

    /// `true` when a permit was granted. `false` only on shutdown, in which case
    /// the caller must skip the operation and must not release.
    private func acquirePermit() async -> Bool {
        if isShutDown { return false }
        if running < maxConcurrent {
            running += 1
            return true
        }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            permitWaiters.append(c)
        }
    }

    /// Hand the permit straight to the oldest waiter rather than decrementing and
    /// letting it re-check — FIFO, and no window where `running` dips below the
    /// ceiling while work is queued.
    private func releasePermit() {
        if permitWaiters.isEmpty {
            running -= 1
        } else {
            let waiter = permitWaiters.removeFirst()
            waiter.resume(returning: true)
        }
    }

    /// Retire the task and, if it was still its lane's tail, the lane with it —
    /// this is what keeps `lanes` bounded. A lane whose chain is still running
    /// keeps exactly one entry.
    private func complete(id: UUID, lane: Lane?) {
        pending[id] = nil
        if let lane, lanes[lane]?.id == id { lanes[lane] = nil }
        inFlight -= 1
        if inFlight == 0 {
            let waiters = drainWaiters
            drainWaiters.removeAll()
            for c in waiters { c.resume() }
        }
    }
}
