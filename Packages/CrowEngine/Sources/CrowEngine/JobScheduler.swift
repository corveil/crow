import Foundation
import CrowCore
import CrowTerminal

/// Drives scheduled jobs (CROW-317).
///
/// Ticks on a `Timer` (like `IssueTracker`) and, for each enabled job that is
/// due, asks `SessionService.runJob` to spin up a worktree + session + Claude
/// terminal in the job's scoped repo. The first prompt is dispatched by the
/// terminal-readiness machine on launch; any remaining prompts are delivered
/// here once the terminal reports `.agentLaunched`, spaced by a fixed gap.
///
/// Job config (including `lastRunAt`) lives in `AppConfig`; this class reads it
/// through `jobsProvider`/`devRootProvider` closures and reports each run back
/// via `onJobRan` so AppDelegate can persist `lastRunAt`. Keeping the canonical
/// config in AppDelegate avoids a second source of truth.
@MainActor
public final class JobScheduler {
    private let appState: AppState
    private let sessionService: SessionService
    private var timer: Timer?

    /// How often to evaluate jobs. A job fires within one tick of becoming due.
    private let tickInterval: TimeInterval = 30
    /// Gap between consecutive prompt sends after Claude has launched.
    private let promptGap: TimeInterval = 20
    /// Max polls (× 5s) to wait for `.agentLaunched` before giving up on the
    /// follow-up prompts for a run.
    private let maxLaunchWaitPolls = 60

    /// Grace period after the final prompt is delivered before a run is eligible
    /// to auto-complete. Prevents catching a stale top-level `.done` from an
    /// earlier prompt before the agent has picked up the last one (CROW-561).
    private let finishSettleDelay: TimeInterval = 20
    /// Safety cap: stop watching a run for completion after this long so a
    /// blocked/erroring run doesn't linger in memory forever (CROW-561).
    private let maxWatchDuration: TimeInterval = 12 * 3600

    /// Jobs currently being created — guards against a long worktree creation
    /// double-firing on the next tick before `lastRunAt` is persisted.
    private var inFlight: Set<UUID> = []

    /// A job run being watched so its session auto-completes once the agent
    /// finishes successfully (CROW-561).
    private struct RunWatch {
        let terminalID: UUID
        let startedAt: Date
        /// Set once the *last* prompt has been delivered; until then the run is
        /// not yet eligible to be judged finished.
        var promptsDeliveredAt: Date?
    }

    /// Active job runs, keyed by session id, awaiting successful-finish detection.
    /// In-memory only: an app relaunch mid-run drops the watch, reverting that run
    /// to the pre-CROW-561 "linger until manually completed" behavior.
    private var watchedRuns: [UUID: RunWatch] = [:]

    /// Reads the current job list (from AppDelegate's `appConfig`).
    public var jobsProvider: () -> [JobConfig] = { [] }
    /// Reads the configured dev root.
    public var devRootProvider: () -> String? = { nil }
    /// Reports a successful run so AppDelegate can persist the job's `lastRunAt`.
    public var onJobRan: (UUID, Date) -> Void = { _, _ in }

    public init(appState: AppState, sessionService: SessionService) {
        self.appState = appState
        self.sessionService = sessionService
    }

    public func start() {
        // Adopt any already-done job sessions we aren't watching so they still
        // auto-complete after a relaunch, or if they predate this feature — the
        // in-memory watch is otherwise lost and the run lingers in `.active`
        // (CROW-579). Runs post-hydration (`start()` is wired after
        // `hydrateState`), so restored sessions/terminals are present.
        reconcileUnwatchedJobs(now: Date())

        // First tick after one interval — gives the app a grace period at
        // launch and lets overdue jobs fire shortly after.
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = tickInterval / 4
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    /// Evaluate jobs once: reconcile/auto-complete watched runs, then fire any
    /// enabled job that is due. Invoked by the `Timer` in the desktop app, and
    /// driven directly by an explicit async loop in the headless daemon (which
    /// has no `RunLoop.main` to run the Timer) (CROW-581).
    public func tick() {
        let now = Date()
        // Adopt any active job sessions we aren't already watching (relaunched
        // or predating the feature) so they can auto-complete too (CROW-579).
        reconcileUnwatchedJobs(now: now)
        // Auto-complete any job runs that have finished successfully. Runs on
        // every tick regardless of whether jobs are due (CROW-561).
        checkFinishedRuns(now: now)

        guard let devRoot = devRootProvider() else { return }
        for job in jobsProvider() where job.enabled {
            guard !inFlight.contains(job.id) else { continue }
            let baseline = job.lastRunAt ?? job.createdAt
            guard let next = job.nextRunDate(after: baseline), next <= now else { continue }
            fire(job, devRoot: devRoot)
        }
    }

    // MARK: - Manual run

    /// Why a manual run request could not launch (CROW-604).
    public enum RunNowError: Error, LocalizedError, Equatable {        case noDevRoot
        case jobNotFound
        case alreadyRunning
        case launchFailed

        public var errorDescription: String? {            switch self {
            case .noDevRoot: "No dev root configured"
            case .jobNotFound: "Job not found"
            case .alreadyRunning: "Job is already running"
            case .launchFailed: "Failed to launch job (no non-empty prompts, or the repo/worktree could not be prepared)"
            }
        }
    }

    /// The reason a `runNow` request would be rejected, or `nil` if it can
    /// proceed. Pure so it's unit-testable (like `finishDecision`).
    public nonisolated static func runNowPrecheck(        jobID: UUID, jobs: [JobConfig], devRoot: String?, inFlight: Set<UUID>
    ) -> RunNowError? {
        guard devRoot != nil else { return .noDevRoot }
        guard jobs.contains(where: { $0.id == jobID }) else { return .jobNotFound }
        guard !inFlight.contains(jobID) else { return .alreadyRunning }
        return nil
    }

    /// Fire a job on demand, regardless of its enabled flag or schedule.
    /// Fire-and-forget (Settings UI "Run now"); failures are silently dropped.
    public func runNow(_ jobID: UUID) {
        guard let devRoot = devRootProvider() else { return }
        guard let job = jobsProvider().first(where: { $0.id == jobID }) else { return }
        fire(job, devRoot: devRoot)
    }

    /// Fire a job on demand and report the launched session/terminal, so the
    /// `job run` RPC can return them to the CLI (CROW-604). Same semantics as
    /// `runNow(_:)` — the enabled flag and schedule are ignored — but launch
    /// problems surface as `RunNowError` instead of being dropped.
    public func runNowReporting(_ jobID: UUID) async throws -> (sessionID: UUID, terminalID: UUID) {
        if let error = Self.runNowPrecheck(
            jobID: jobID, jobs: jobsProvider(), devRoot: devRootProvider(), inFlight: inFlight
        ) {
            throw error
        }
        guard let devRoot = devRootProvider(),
              let job = jobsProvider().first(where: { $0.id == jobID }),
              markInFlight(job.id) else {
            // Providers changed between the precheck and here — treat as busy.
            throw RunNowError.alreadyRunning
        }
        return try await launchMarked(job, devRoot: devRoot)
    }

    /// Launch one job: guard against double-launch, then hand off to
    /// `launchMarked`. Shared by `tick()` (scheduled) and `runNow(_:)` (manual).
    private func fire(_ job: JobConfig, devRoot: String) {
        guard markInFlight(job.id) else { return }
        Task { @MainActor in
            _ = try? await self.launchMarked(job, devRoot: devRoot)
        }
    }

    /// Mark a job as launching. Returns `false` if it already is — the caller
    /// must not proceed. Synchronous so check-and-insert is atomic on the
    /// MainActor, closing the double-launch window between two callers.
    private func markInFlight(_ id: UUID) -> Bool {
        guard !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    /// Spin up the worktree/session/Claude terminal, persist the run time, then
    /// deliver any remaining prompts. Requires a successful `markInFlight`;
    /// clears the mark when done.
    private func launchMarked(_ job: JobConfig, devRoot: String) async throws -> (sessionID: UUID, terminalID: UUID) {
        defer { inFlight.remove(job.id) }
        guard let result = await sessionService.runJob(job, devRoot: devRoot) else {
            throw RunNowError.launchFailed
        }
        // Persist run time first so the job isn't re-fired next tick.
        onJobRan(job.id, Date())
        // Watch this run so its session auto-completes on success (CROW-561).
        watchedRuns[result.sessionID] = RunWatch(
            terminalID: result.terminalID,
            startedAt: Date(),
            promptsDeliveredAt: nil
        )
        deliverRemainingPrompts(job, sessionID: result.sessionID, terminalID: result.terminalID)
        return result
    }

    // MARK: - Multi-prompt delivery (best-effort)

    /// Deliver every prompt after the first non-empty one, once Claude has
    /// launched, spaced by `promptGap`.
    private func deliverRemainingPrompts(_ job: JobConfig, sessionID: UUID, terminalID: UUID) {
        let remaining = job.prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .dropFirst()
        guard !remaining.isEmpty else {
            // Single-prompt job: the sole prompt launches with the agent, so the
            // run is fully delivered as soon as the terminal reports launched.
            waitForAgentLaunched(terminalID: terminalID, polls: 0) { [weak self] in
                self?.markPromptsDelivered(sessionID: sessionID)
            }
            return
        }

        waitForAgentLaunched(terminalID: terminalID, polls: 0) { [weak self] in
            self?.sendSequentially(Array(remaining), sessionID: sessionID, terminalID: terminalID)
        }
    }

    /// Poll the readiness machine until the terminal reports `.agentLaunched`,
    /// then run `then`. Bounded so a stuck launch doesn't poll forever.
    private func waitForAgentLaunched(terminalID: UUID, polls: Int, then: @escaping () -> Void) {
        if appState.terminalReadiness[terminalID] == .agentLaunched {
            then()
            return
        }
        guard polls < maxLaunchWaitPolls else {
            NSLog("[JobScheduler] gave up waiting for agent launch on \(terminalID)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.waitForAgentLaunched(terminalID: terminalID, polls: polls + 1, then: then)
        }
    }

    /// Send prompts one at a time, waiting `promptGap` before each so they don't
    /// collide with Claude still processing the previous one. Stops if the
    /// terminal disappears (e.g. the session was deleted).
    private func sendSequentially(_ prompts: [String], sessionID: UUID, terminalID: UUID) {
        guard !prompts.isEmpty else {
            // Every prompt has been sent — the run is now eligible to finish.
            markPromptsDelivered(sessionID: sessionID)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + promptGap) { [weak self] in
            guard let self else { return }
            guard let terminal = self.appState.terminals.values
                .flatMap({ $0 })
                .first(where: { $0.id == terminalID }) else {
                NSLog("[JobScheduler] terminal \(terminalID) gone; stopping prompt delivery")
                // Delivery aborted — stop watching this run for completion too.
                self.watchedRuns[sessionID] = nil
                return
            }
            TerminalRouter.send(terminal, text: prompts[0] + "\n")
            self.sendSequentially(Array(prompts.dropFirst()), sessionID: sessionID, terminalID: terminalID)
        }
    }

    // MARK: - Auto-complete on finish (CROW-561)

    /// Record that a watched run has had all of its prompts delivered, starting
    /// the settle window before it can be judged finished.
    private func markPromptsDelivered(sessionID: UUID) {
        watchedRuns[sessionID]?.promptsDeliveredAt = Date()
    }

    // MARK: - Reconcile unwatched runs (CROW-579)

    /// Adopt any active `.job` session we aren't already watching so it can be
    /// auto-completed like a run we fired ourselves. Covers runs this process
    /// never watched: the app was relaunched after the run finished (the
    /// in-memory `watchedRuns` was lost), or the run predates CROW-566.
    ///
    /// The adopted watch stamps both `startedAt` and `promptsDeliveredAt` at
    /// `now`, which does two things:
    /// - The run is inside the settle window, so `finishDecision` won't complete
    ///   it until a later tick when it is *still* at rest — i.e. at rest across a
    ///   full tick. That guards against completing a multi-prompt job mid-gap.
    /// - The `maxWatchDuration` cap counts from adoption, not the session's real
    ///   start, so a days-old predates-the-feature run is still eligible (using
    ///   its actual start would trip the cap and never complete it).
    ///
    /// Sessions already in `watchedRuns` (runs we fired) are skipped so their
    /// real delivery timestamp / settle timing is never disturbed.
    private func reconcileUnwatchedJobs(now: Date) {
        for session in appState.sessions where Self.shouldReconcile(
            kind: session.kind,
            status: session.status,
            alreadyWatched: watchedRuns[session.id] != nil
        ) {
            // Need the managed terminal to read readiness/activity; if it's gone
            // (e.g. the session was torn down mid-run) there's nothing to judge —
            // leave it `.active` so the anomaly surfaces rather than completing it.
            guard let terminalID = appState.terminals[session.id]?
                .first(where: { $0.isManaged })?.id else { continue }
            watchedRuns[session.id] = RunWatch(
                terminalID: terminalID,
                startedAt: now,
                promptsDeliveredAt: now
            )
        }
    }

    /// Whether an unwatched session should be adopted for finish-watching on
    /// reconciliation (CROW-579). Pure so it's unit-testable without an
    /// `AppState`. The stateful caller additionally requires a managed terminal
    /// to derive readiness.
    static func shouldReconcile(
        kind: SessionKind,
        status: SessionStatus,
        alreadyWatched: Bool
    ) -> Bool {
        kind == .job && status == .active && !alreadyWatched
    }

    /// Auto-complete watched job runs whose agent has finished successfully.
    ///
    /// A run completes when, after all its prompts were delivered plus a settle
    /// window, the agent has emitted a real finish event (`.done`) rather than
    /// still working, awaiting input / errored (`.waiting`), or never having
    /// started (`.idle`). Keyed purely on `AgentActivityState`, so it works the
    /// same across Claude/Codex/Cursor/OpenCode. See `finishDecision`.
    private func checkFinishedRuns(now: Date) {
        // Mutating `watchedRuns` inside the loop is safe: `for (_, _) in dict`
        // iterates a value copy, so the mutation just triggers copy-on-write.
        for (sessionID, run) in watchedRuns {
            let decision = Self.finishDecision(
                now: now,
                status: appState.sessions.first(where: { $0.id == sessionID })?.status,
                startedAt: run.startedAt,
                promptsDeliveredAt: run.promptsDeliveredAt,
                readiness: appState.terminalReadiness[run.terminalID],
                activityState: appState.hookState(for: sessionID).activityState,
                finishSettleDelay: finishSettleDelay,
                maxWatchDuration: maxWatchDuration
            )
            switch decision {
            case .keepWaiting:
                continue
            case .stopWatching:
                watchedRuns[sessionID] = nil
            case .complete:
                sessionService.completeSession(id: sessionID)
                watchedRuns[sessionID] = nil
            }
        }
    }

    /// What to do with a watched run this tick — pure so it's unit-testable
    /// without an `AppState`/`SessionService`.
    enum RunDecision: Equatable {
        case keepWaiting    // still delivering, inside settle window, or agent busy
        case stopWatching   // session gone / no longer active / timed out
        case complete       // finished successfully → mark the session completed
    }

    /// Decide a watched run's fate from plain inputs. `status == nil` means the
    /// session no longer exists.
    ///
    /// Only `.done` counts as finished. `.idle` deliberately does **not**: across
    /// every agent kind it is set *only* on a fresh `SessionStart` (the default /
    /// never-started state), never as a resting state after work. Treating it as
    /// finished would silently complete failed launches (readiness parks at
    /// `.agentLaunched` with no agent, so no hook event ever arrives and the state
    /// stays the default `.idle`), still-booting agents, and TUI agents reasoning
    /// before their first tool call — the exact "silently completed" outcome this
    /// feature must avoid. `.done`, by contrast, is only produced by a real finish
    /// event (Claude/Codex `Stop`, or a TUI `Stop`/`Notification` safety-net),
    /// which proves the agent actually ran.
    ///
    /// Known limitation: OpenCode/Cursor map an error `Notification`
    /// (e.g. `session.error`) to `.done` when no top-level Stop was recorded, so an
    /// errored TUI run can complete as "success". Claude/Codex errored runs
    /// (`StopFailure` → `.waiting`) are correctly left active.
    static func finishDecision(
        now: Date,
        status: SessionStatus?,
        startedAt: Date,
        promptsDeliveredAt: Date?,
        readiness: TerminalReadiness?,
        activityState: AgentActivityState,
        finishSettleDelay: TimeInterval,
        maxWatchDuration: TimeInterval
    ) -> RunDecision {
        // Session deleted, or manually moved out of active → stop watching.
        guard let status, status == .active else { return .stopWatching }
        // Safety cap so a blocked/erroring run doesn't linger forever.
        if now.timeIntervalSince(startedAt) >= maxWatchDuration { return .stopWatching }
        // Not all prompts delivered yet, or still inside the settle window.
        guard let deliveredAt = promptsDeliveredAt,
              now.timeIntervalSince(deliveredAt) >= finishSettleDelay else { return .keepWaiting }
        // The agent must have actually launched.
        guard readiness == .agentLaunched else { return .keepWaiting }

        switch activityState {
        case .idle, .working, .waiting:
            // Not finished: `.idle` is the never-started default, `.working` is
            // in-progress, `.waiting` is awaiting input or errored. All stay
            // active so the run surfaces rather than being silently completed.
            return .keepWaiting
        case .done:
            return .complete
        }
    }
}
