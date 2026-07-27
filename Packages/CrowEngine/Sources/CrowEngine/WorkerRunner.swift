import Foundation
import CrowCore
import CrowProvider

/// Drives Corveil worker runs as a native Crow runner (corveil/crow#801).
///
/// The Corveil twin of `JobScheduler`: instead of local `config.json` jobs, it
/// polls a Corveil queue for claimable worker runs, claims up to a per-host cap,
/// executes each in a repo-less scratch workdir (`SessionService.runWorkerRun`),
/// holds the lease with heartbeats, and — reusing `JobScheduler.finishDecision`
/// — maps the agent's `.done` onto `corveil worker-run complete`. Crow owns the
/// claim → heartbeat → complete lifecycle; the agent only does allow-listed
/// write-backs. Local jobs are unaffected: this source is additive.
///
/// Reachability: the org-scoped `CORVEIL_API_KEY` is sourced from the crowd
/// process env (never persisted); with no key present the loop is inert.
@MainActor
public final class WorkerRunner {
    private let appState: AppState
    private let sessionService: SessionService

    // MARK: - Injection

    /// Current runner config (from `AppConfig.runner`). Nil (no `runner` block or
    /// a failed config load) or `disabled` ⇒ **no new claims**, but teardown of
    /// existing/persisted runs still runs each `tick()` so secrets are never
    /// orphaned (review).
    public var configProvider: () -> RunnerConfig? = { nil }
    /// The configured dev root (scratch dirs live under it).
    public var devRootProvider: () -> String? = { nil }
    /// The org-scoped API key, sourced from the crowd env. Blank ⇒ inert.
    public var apiKeyProvider: () -> String? = { ProcessInfo.processInfo.environment["CORVEIL_API_KEY"] }
    /// Fallback `CORVEIL_URL` when the config omits it.
    public var envURLProvider: () -> String? = { ProcessInfo.processInfo.environment["CORVEIL_URL"] }
    /// Builds the Corveil worker backend for a resolved config. Overridable in
    /// tests to inject a fake `ShellRunner`.
    public var makeBackend: @Sendable (CorveilWorkerConfig) -> CorveilWorkerBackend = { config in
        CorveilWorkerBackend(shellRunner: ProcessShellRunner(), config: config)
    }

    // MARK: - Tunables

    /// Lease requested on claim/heartbeat (matches Corveil's 30m default), and
    /// the window after which a run with no successful heartbeat is failed closed.
    /// `var` (not `let`) only so tests can shrink it to force the lost-lease path.
    var leaseSeconds = 1800
    /// Re-heartbeat once a watched run is this old since its last beat — well
    /// under the 30m lease so a slow tick can't drop a live run.
    private let heartbeatInterval: TimeInterval = 600
    /// Grace after the prompt is delivered before a run may auto-complete
    /// (mirrors `JobScheduler.finishSettleDelay`).
    private let finishSettleDelay: TimeInterval = 20
    /// Safety cap so a stuck run can't linger forever. `var` (not `let`) only so
    /// tests can shrink it to force the timeout path without waiting 12h.
    var maxWatchDuration: TimeInterval = 12 * 3600
    /// Max polls (× 5s) to observe `.agentLaunched` before giving up on stamping
    /// the settle window for a run.
    private let maxLaunchWaitPolls = 60

    // MARK: - State

    /// A claimed run being executed + watched for completion, keyed by session id.
    struct WorkerRunWatch {
        let runID: String
        let workerID: String
        let scratchDir: String
        let terminalID: UUID
        let startedAt: Date
        /// Set once the prompt has launched; until then not eligible to finish.
        var promptsDeliveredAt: Date?
        var lastHeartbeatAt: Date
    }
    private var watchedRuns: [UUID: WorkerRunWatch] = [:]
    /// Guards against a slow claim being re-entered by the next tick.
    private var ticking = false
    private var timer: Timer?
    /// One-shot log guard so a missing API key warns once, not every tick.
    private var warnedMissingKey = false
    /// One-shot log guard so a persistent list/auth failure warns once, not every
    /// tick — reset on the first successful list so a transient blip re-warns.
    private var warnedListError = false

    public init(appState: AppState, sessionService: SessionService) {
        self.appState = appState
        self.sessionService = sessionService
    }

    // MARK: - Lifecycle

    /// Start a `RunLoop.main` timer loop, for a future desktop-app host.
    ///
    /// Currently **unused**: this slice is daemon-first, and `crowd` drives
    /// `tick()` from its own async poll (`CrowDaemon.startRunnerPoll`) because it
    /// has no `RunLoop.main`. Kept for parity with `JobScheduler.start()` so the
    /// desktop app can adopt the runner later; nothing wires it today, so the
    /// desktop app does not claim worker runs (corveil/crow#801 review).
    public func start() {
        let interval = TimeInterval(configProvider()?.effectivePollIntervalSeconds ?? 30)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer?.tolerance = interval / 4
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Build a Corveil backend from the current config + env. Shared by `tick()`
    /// and the out-of-tick launch-timeout teardown so both authenticate the same
    /// way (a nil config resolves to a disabled default — teardown never depends
    /// on config presence).
    private func currentBackend() -> CorveilWorkerBackend {
        let config = configProvider() ?? RunnerConfig()
        let apiKey = (apiKeyProvider() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = config.corveilURL.isEmpty ? (envURLProvider() ?? "") : config.corveilURL
        return makeBackend(CorveilWorkerConfig(url: url, apiKey: apiKey))
    }

    // MARK: - Tick

    /// One evaluation: adopt/heartbeat/finish watched runs, then claim new ones
    /// up to the per-host cap. Async (unlike `JobScheduler.tick`) because every
    /// step is a `corveil` CLI round-trip. Re-entrancy-guarded so a slow network
    /// tick isn't overlapped by the next poll.
    ///
    /// **Teardown always runs; only claiming is gated.** Reconcile + heartbeat +
    /// finish/wipe of already-watched (or persisted, post-relaunch) runs happen
    /// every tick regardless of config presence / `enabled` / API-key / dev-root —
    /// otherwise disabling the runner (by flipping `enabled`, **removing the whole
    /// `runner` block**, or a transient `ConfigStore.loadConfig` failure that
    /// makes `configProvider()` return nil) would abandon the local secret
    /// teardown, leaving the scoped `CORVEIL_API_KEY` on disk (review). Teardown
    /// needs none of those — each watch carries its own `workerID` and absolute
    /// scratch path — so it runs first, then claiming is gated at the bottom.
    public func tick() async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }

        // A nil config (no `runner` block, or a failed config load) means "don't
        // claim new work", NOT "skip teardown" — default to a disabled config so
        // the teardown below never depends on config presence.
        let config = configProvider() ?? RunnerConfig()
        let apiKey = (apiKeyProvider() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = config.corveilURL.isEmpty ? (envURLProvider() ?? "") : config.corveilURL
        let backend = currentBackend()
        let now = Date()

        // Teardown of existing runs — always, independent of config/enabled/key/
        // devRoot. Uses each watch's own stored `workerID` + absolute scratch
        // path. Without a key the Corveil-side `complete`/`heartbeat` best-efforts
        // fail (logged), but the local `completeSession` + scratch-dir wipe still
        // run, which is the security-critical part.
        reconcileUnwatchedWorkerRuns(now: now)
        // Backstop for crash / failed-wipe orphans: remove any scratch dir with no
        // live `.workerRun` session (e.g. `crowd` died after `writeCorveilRunEnv`
        // but before persisting the session). Needs a dev root to locate the
        // scratch root; skipped when unavailable (rare).
        if let devRoot = devRootProvider() { sweepOrphanScratchDirs(devRoot: devRoot) }
        await heartbeatWatched(backend: backend, now: now)
        await checkFinishedRuns(backend: backend, now: now)

        // New claims are gated on the runner being enabled, a dev root (to place
        // scratch dirs), and a usable key.
        guard config.enabled else { return }
        guard let devRoot = devRootProvider() else { return }
        let workerID = config.resolvedWorkerID()
        guard !apiKey.isEmpty else {
            if !warnedMissingKey {
                NSLog("[WorkerRunner] runner enabled but CORVEIL_API_KEY is not set in the crowd environment; idle")
                warnedMissingKey = true
            }
            return
        }
        warnedMissingKey = false
        await claimIfCapacity(config: config, backend: backend, devRoot: devRoot, url: url, apiKey: apiKey, workerID: workerID)
    }

    // MARK: - Reconcile (relaunch recovery)

    /// Adopt any active `.workerRun` session we aren't watching — e.g. `crowd`
    /// was relaunched mid-run and lost the in-memory watch. The persisted
    /// `workerRunID` / `workerID` / `workerRunScratchDir` let us still complete
    /// the Corveil run and wipe the scratch dir. Stamps `startedAt` /
    /// `promptsDeliveredAt` at `now` so the settle window re-applies (same
    /// rationale as `JobScheduler.reconcileUnwatchedJobs`).
    private func reconcileUnwatchedWorkerRuns(now: Date) {
        for session in appState.sessions where session.kind == .workerRun
            && session.status == .active
            && watchedRuns[session.id] == nil {
            guard let runID = session.workerRunID, let workerID = session.workerID,
                  let scratchDir = session.workerRunScratchDir,
                  let terminalID = appState.terminals[session.id]?.first(where: { $0.isManaged })?.id
            else {
                // Incomplete linkage — we can't drive this run to completion, and
                // (if it has a scratch dir) the orphan sweep won't touch a dir a
                // live session still references. Fail-closed LOCALLY so the scoped
                // key isn't stranded: wipe the scratch dir, then move the session
                // off `.active`. If the wipe fails, keep it active so a later
                // reconcile retries rather than leaving the key referenced by a
                // completed session (review).
                if let scratchDir = session.workerRunScratchDir, !scratchDir.isEmpty,
                   !SessionService.wipeWorkerRunScratch(scratchDir) {
                    continue
                }
                NSLog("[WorkerRunner] worker-run session %@ has incomplete linkage; failing closed",
                      session.id.uuidString)
                sessionService.completeSession(id: session.id)
                continue
            }
            watchedRuns[session.id] = WorkerRunWatch(
                runID: runID,
                workerID: workerID,
                scratchDir: scratchDir,
                terminalID: terminalID,
                startedAt: now,
                promptsDeliveredAt: now,
                lastHeartbeatAt: now
            )
        }
    }

    // MARK: - Orphan sweep

    /// Remove scratch dirs under `.crow-worker-runs/` that no live `.workerRun`
    /// session references. Backstop for the case a run's scratch dir (holding the
    /// scoped `CORVEIL_API_KEY`) was created but its session never persisted — a
    /// crash between `writeCorveilRunEnv` and `store.mutate`, or a setup-failure
    /// wipe that itself failed — leaving an orphan no reconcile/watch can reach.
    ///
    /// "Live" = referenced by any `.workerRun` session currently in `appState`
    /// (regardless of status: a completed session whose wipe is still retrying
    /// keeps its dir, and its watch handles the retry). A dir is swept only when
    /// no such session claims it.
    private func sweepOrphanScratchDirs(devRoot: String) {
        let root = SessionService.workerRunsRoot(devRoot: devRoot)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return }
        let live = Set(appState.sessions
            .filter { $0.kind == .workerRun }
            .compactMap { $0.workerRunScratchDir })
        for entry in entries {
            let path = (root as NSString).appendingPathComponent(entry)
            guard !live.contains(path) else { continue }
            NSLog("[WorkerRunner] sweeping orphan worker-run scratch dir %@", path)
            SessionService.wipeWorkerRunScratch(path)
        }
    }

    // MARK: - Heartbeat

    private func heartbeatWatched(backend: CorveilWorkerBackend, now: Date) async {
        for (sessionID, run) in watchedRuns {
            guard now.timeIntervalSince(run.lastHeartbeatAt) >= heartbeatInterval else { continue }
            do {
                try await backend.heartbeat(run.runID, workerID: run.workerID, leaseSeconds: leaseSeconds)
                watchedRuns[sessionID]?.lastHeartbeatAt = now
            } catch {
                NSLog("[WorkerRunner] heartbeat failed for run %@: %@", run.runID, String(describing: error))
            }
        }
    }

    // MARK: - Finish → complete

    /// Auto-complete watched runs whose agent has finished. Reuses
    /// `JobScheduler.finishDecision` (the same `.done` + settle-window logic) and
    /// maps the outcome onto `corveil worker-run complete`.
    private func checkFinishedRuns(backend: CorveilWorkerBackend, now: Date) async {
        for (sessionID, run) in watchedRuns {
            // Fail-closed on a lost lease: if no heartbeat has succeeded within the
            // lease window, Corveil may have expired our claim and re-queued the
            // run to another runner. Continuing to execute (and calling `mcp-call`)
            // would open a duplicate-runner / racing-write window (review). Stop:
            // fail the dead claim, complete the local session, free the slot.
            if now.timeIntervalSince(run.lastHeartbeatAt) >= TimeInterval(leaseSeconds) {
                NSLog("[WorkerRunner] lease lost for run %@ (no successful heartbeat within %ds); failing",
                      run.runID, leaseSeconds)
                await failClosed(run: run, sessionID: sessionID, backend: backend,
                                 reason: "lease lost — runner could not heartbeat within the lease window")
                continue
            }
            let status = appState.sessions.first(where: { $0.id == sessionID })?.status
            let decision = JobScheduler.finishDecision(
                now: now,
                status: status,
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
            case .complete:
                let result = WorkerRunResult.decode(
                    fromFile: (run.scratchDir as NSString).appendingPathComponent(WorkerRunPrompt.resultFileName)
                )
                let args = WorkerRunCompletion.map(result: result)
                await complete(backend: backend, run: run, args: args)
                sessionService.completeSession(id: sessionID)
                wipeAndDrop(sessionID: sessionID, scratchDir: run.scratchDir)
            case .stopWatching:
                await stopWatching(run: run, sessionID: sessionID, status: status, backend: backend)
            }
        }
    }

    /// Wipe the scratch dir and drop the watch — but **only if the wipe
    /// succeeded**. A failed wipe keeps the watch so a later tick re-evaluates and
    /// retries; the session has already been moved off `.active`, so it resolves
    /// to `.stopWatching` (no repeated Corveil calls) and just re-attempts the
    /// wipe. This prevents a transient remove failure from orphaning the scoped
    /// API key with no retry (review).
    private func wipeAndDrop(sessionID: UUID, scratchDir: String) {
        if SessionService.wipeWorkerRunScratch(scratchDir) {
            watchedRuns[sessionID] = nil
        }
    }

    /// Terminal fail-closed teardown for a still-`.active` run we can no longer
    /// safely execute (lost lease, launch timeout, max-duration timeout): fail the
    /// Corveil claim, **stop the agent** (so it can't keep using its in-process
    /// credentials against a claim Corveil may have re-queued), move the session
    /// off `.active` (so reconcile won't re-adopt it), and wipe+drop. Shared so
    /// every fail path frees the concurrency slot identically.
    private func failClosed(run: WorkerRunWatch, sessionID: UUID, backend: CorveilWorkerBackend, reason: String) async {
        await complete(backend: backend, run: run, args: .init(error: reason))
        sessionService.stopManagedTerminals(sessionID: sessionID)
        sessionService.completeSession(id: sessionID)
        wipeAndDrop(sessionID: sessionID, scratchDir: run.scratchDir)
    }

    /// Handle a run we've stopped watching. There are three sub-cases behind
    /// `finishDecision`'s `.stopWatching`, distinguished by the session status:
    ///
    /// - **Still `.active` (max-duration timeout):** the run overran the watch
    ///   cap. Fail it on Corveil AND `completeSession` — moving it off `.active` is
    ///   essential, because otherwise the next tick's `reconcileUnwatchedWorkerRuns`
    ///   re-adopts it and resets `startedAt`, so the 12h cap never sticks and the
    ///   run becomes a zombie permanently holding a `maxConcurrentRuns` slot while
    ///   re-heartbeating an already-completed Corveil run (review).
    /// - **Deleted (`nil`):** `deleteSession` already tore down the local session +
    ///   scratch dir; just best-effort fail the Corveil run so the queue isn't hung.
    /// - **User-moved off `.active` (paused/archived/…):** leave the Corveil run to
    ///   the lease-expiry abandonment sweep; only wipe the local secret.
    ///
    /// Every case wipes the scratch dir and drops the watch.
    private func stopWatching(run: WorkerRunWatch, sessionID: UUID, status: SessionStatus?, backend: CorveilWorkerBackend) async {
        switch status {
        case .active:
            await failClosed(run: run, sessionID: sessionID, backend: backend,
                             reason: "run exceeded the runner's max watch duration")
        case nil:
            // Deleted — `deleteSession` already destroyed the terminals and tore
            // down locally; just best-effort fail the Corveil run.
            await complete(backend: backend, run: run,
                           args: .init(error: "run aborted on runner before completion"))
            wipeAndDrop(sessionID: sessionID, scratchDir: run.scratchDir)
        default:
            // User moved it off `.active` (paused/archived/…). Don't leave the
            // agent running with the scoped key while we stop heartbeating (the
            // lease can then lapse and another runner claim the same run): fail the
            // Corveil claim AND stop the agent. Preserve the user's chosen status
            // (no `completeSession`) (review).
            await complete(backend: backend, run: run,
                           args: .init(error: "run abandoned — session moved out of active on the runner"))
            sessionService.stopManagedTerminals(sessionID: sessionID)
            wipeAndDrop(sessionID: sessionID, scratchDir: run.scratchDir)
        }
    }

    private func complete(backend: CorveilWorkerBackend, run: WorkerRunWatch, args: WorkerRunCompletion.CompleteArgs) async {
        do {
            try await backend.complete(
                run.runID, workerID: run.workerID,
                title: args.title, content: args.content, output: args.output, error: args.error
            )
        } catch {
            NSLog("[WorkerRunner] complete failed for run %@: %@", run.runID, String(describing: error))
        }
    }

    // MARK: - Claim

    /// List claimable runs, surfacing errors instead of swallowing them. A
    /// misconfiguration (`unauthenticated` / `featureDisabled`) otherwise looks
    /// identical to "queue empty" and the runner idles silently forever; warn
    /// once (reset on the next success) so the failure is visible in the log.
    private func listClaimableSurfacing(backend: CorveilWorkerBackend, kind: String?, caps: [String]) async -> [WorkerRun] {
        do {
            let runs = try await backend.listClaimable(kind: kind, caps: caps)
            warnedListError = false
            return runs
        } catch {
            if !warnedListError {
                NSLog("[WorkerRunner] listClaimable failed (kind=%@): %@ — runner will keep retrying",
                      kind ?? "*", String(describing: error))
                warnedListError = true
            }
            return []
        }
    }

    private func claimIfCapacity(
        config: RunnerConfig, backend: CorveilWorkerBackend,
        devRoot: String, url: String, apiKey: String, workerID: String
    ) async {
        let cap = config.effectiveMaxConcurrentRuns
        guard watchedRuns.count < cap else { return }

        // Gather claimable candidates. The API's `--kind` is single-valued, so
        // fan out across configured kinds; an empty `kinds` lists any kind.
        var candidates: [WorkerRun] = []
        if config.kinds.isEmpty {
            candidates = await listClaimableSurfacing(backend: backend, kind: nil, caps: config.caps)
        } else {
            for kind in config.kinds {
                candidates += await listClaimableSurfacing(backend: backend, kind: kind, caps: config.caps)
            }
        }

        let inFlight = Set(watchedRuns.values.map(\.runID))
        let plan = Self.claimPlan(
            activeCount: watchedRuns.count, cap: cap,
            candidateIDs: candidates.map(\.id), inFlight: inFlight
        )
        guard !plan.isEmpty else { return }

        for runID in plan {
            guard watchedRuns.count < cap else { break }
            do {
                let claimed = try await backend.claim(runID, workerID: workerID, leaseSeconds: leaseSeconds)
                // `claim` returns the full row, but fetch the snapshot if the
                // prompt body wasn't inlined.
                let full: WorkerRun
                if (claimed.promptBody ?? "").isEmpty {
                    full = (try? await backend.get(runID)) ?? claimed
                } else {
                    full = claimed
                }
                await launchClaimed(full, backend: backend, devRoot: devRoot, url: url, apiKey: apiKey, workerID: workerID)
            } catch WorkerRunError.unclaimable {
                // Lost the race — someone else claimed it. Try the next.
                continue
            } catch {
                NSLog("[WorkerRunner] claim failed for run %@: %@", runID, String(describing: error))
                continue
            }
        }
    }

    /// Spin up the scratch workdir + session for a just-claimed run and begin
    /// watching it. If setup fails, fail the Corveil run so it isn't left held.
    private func launchClaimed(
        _ run: WorkerRun, backend: CorveilWorkerBackend,
        devRoot: String, url: String, apiKey: String, workerID: String
    ) async {
        guard let result = await sessionService.runWorkerRun(
            run: run, devRoot: devRoot, corveilURL: url, apiKey: apiKey, workerID: workerID
        ) else {
            try? await backend.complete(
                run.id, workerID: workerID,
                title: nil, content: nil, output: nil,
                error: "runner failed to start the run"
            )
            return
        }
        let now = Date()
        watchedRuns[result.sessionID] = WorkerRunWatch(
            runID: run.id,
            workerID: workerID,
            scratchDir: result.scratchDir,
            terminalID: result.terminalID,
            startedAt: now,
            promptsDeliveredAt: nil,
            lastHeartbeatAt: now
        )
        markPromptsDeliveredWhenLaunched(sessionID: result.sessionID, terminalID: result.terminalID, polls: 0)
    }

    // MARK: - Prompt-delivery watch (single prompt)

    /// A worker run has exactly one (wrapped) prompt, launched with the agent, so
    /// it's "delivered" as soon as the terminal reports `.agentLaunched`. Poll
    /// until then (bounded), then stamp the settle window. Mirrors
    /// `JobScheduler.waitForAgentLaunched` + `markPromptsDelivered`.
    ///
    /// On expiry (the agent never reached `.agentLaunched` within the launch
    /// window) the run is **torn down**, not just logged: with `promptsDeliveredAt`
    /// left nil, `finishDecision` would return `.keepWaiting` until the 12h
    /// `maxWatchDuration`, so a stuck launch would otherwise hold a
    /// `maxConcurrentRuns` slot and keep heartbeating for hours (review). Failing
    /// it here frees the slot immediately.
    private func markPromptsDeliveredWhenLaunched(sessionID: UUID, terminalID: UUID, polls: Int) {
        guard watchedRuns[sessionID] != nil else { return }
        if appState.terminalReadiness[terminalID] == .agentLaunched {
            watchedRuns[sessionID]?.promptsDeliveredAt = Date()
            return
        }
        guard polls < maxLaunchWaitPolls else {
            NSLog("[WorkerRunner] agent never launched for session %@; failing the run", sessionID.uuidString)
            Task { @MainActor [weak self] in await self?.handleLaunchTimeout(sessionID: sessionID) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.markPromptsDeliveredWhenLaunched(sessionID: sessionID, terminalID: terminalID, polls: polls + 1)
        }
    }

    /// Tear down a run whose agent never launched: fail it on Corveil, complete
    /// the local session, and wipe the scratch dir (dropping the watch only once
    /// the wipe succeeds). Same shape as the max-duration timeout path.
    private func handleLaunchTimeout(sessionID: UUID) async {
        guard let run = watchedRuns[sessionID] else { return }
        await failClosed(run: run, sessionID: sessionID, backend: currentBackend(),
                         reason: "agent failed to launch on the runner")
    }

    // MARK: - Claim planning (pure)

    /// Which candidate run ids to claim this tick: the first `cap - activeCount`
    /// candidates not already in flight (deduped, order preserved). Pure so it's
    /// unit-testable without any Corveil round-trip.
    nonisolated static func claimPlan(activeCount: Int, cap: Int, candidateIDs: [String], inFlight: Set<String>) -> [String] {
        let slots = max(0, cap - activeCount)
        guard slots > 0 else { return [] }
        var seen = Set<String>()
        var plan: [String] = []
        for id in candidateIDs {
            if inFlight.contains(id) || seen.contains(id) { continue }
            seen.insert(id)
            plan.append(id)
            if plan.count >= slots { break }
        }
        return plan
    }

    // MARK: - Status (for the runner-status RPC)

    public struct WatchedRunInfo: Sendable, Equatable {
        public let runID: String
        public let sessionID: String
        public let status: String
    }

    public struct Status: Sendable, Equatable {
        public let enabled: Bool
        public let workerID: String
        public let activeRuns: Int
        public let maxConcurrent: Int
        public let apiKeyPresent: Bool
        public let watched: [WatchedRunInfo]
    }

    /// Read-only snapshot for the `runner-status` RPC.
    public func statusSnapshot() -> Status {
        let config = configProvider()
        let apiKeyPresent = !((apiKeyProvider() ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let watched = watchedRuns.map { sessionID, run in
            WatchedRunInfo(
                runID: run.runID,
                sessionID: sessionID.uuidString,
                status: appState.sessions.first(where: { $0.id == sessionID })?.status.rawValue ?? "unknown"
            )
        }
        return Status(
            enabled: config?.enabled ?? false,
            workerID: config?.resolvedWorkerID() ?? "",
            activeRuns: watchedRuns.count,
            maxConcurrent: config?.effectiveMaxConcurrentRuns ?? 0,
            apiKeyPresent: apiKeyPresent,
            watched: watched.sorted { $0.runID < $1.runID }
        )
    }
}

/// Maps a run's `.crow-run-result.json` (or its absence) onto the arguments for
/// `corveil worker-run complete`. Pure so it's unit-testable (corveil/crow#801).
enum WorkerRunCompletion {
    struct CompleteArgs: Equatable {
        var title: String?
        var content: String?
        var output: String?
        var error: String?

        init(title: String? = nil, content: String? = nil, output: String? = nil, error: String? = nil) {
            self.title = title
            self.content = content
            self.output = output
            self.error = error
        }
    }

    static func map(result: WorkerRunResult?) -> CompleteArgs {
        // No result file ⇒ the agent finished without reporting ⇒ fail the run.
        guard let result else {
            return CompleteArgs(error: "agent finished without producing a result")
        }
        // Agent self-reported a failure.
        if let err = result.error, !err.isEmpty {
            return CompleteArgs(error: err)
        }
        // Success requires at least a title or content; an empty success is
        // treated as a failure so a blank run isn't silently marked completed.
        let hasTitle = !(result.title ?? "").isEmpty
        let hasContent = !(result.content ?? "").isEmpty
        guard hasTitle || hasContent else {
            return CompleteArgs(output: result.output, error: "agent produced an empty result")
        }
        return CompleteArgs(
            title: result.title, content: result.content,
            output: result.output, error: nil
        )
    }
}
