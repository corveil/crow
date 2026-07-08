#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import CrowCore
import CrowClaude
import CrowCodex
import CrowCursor
import CrowOpenCode
import CrowEngine
import CrowProvider
import CrowGit
import CrowTerminal
import CrowIPC
import CrowPersistence
import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The headless `crowd` daemon: serves Crow's JSON-RPC domain logic and the
/// browser terminal over HTTP + WebSocket, reusing `CrowCore`/`CrowIPC`/
/// `CrowGit`/`CrowPersistence`/`CrowTerminal` verbatim. Also binds the existing
/// Unix socket so the current `crow` CLI can drive it (CROW-581, M0 + M1).
public enum CrowDaemon {
    public static func run(arguments: [String] = CommandLine.arguments) async throws {
        let options = DaemonOptions.parse(arguments)

        // The WS endpoints are unauthenticated; the Origin guard blocks
        // cross-site browser hijacking but not same-origin/native clients on the
        // network. Binding beyond loopback exposes git + a shell — warn loudly
        // (CROW-581 review). Token auth for remote access is a follow-up.
        if !WebSocketOriginGuard.isLoopbackHost(options.host) {
            log("WARNING: binding to non-loopback host \(options.host) — /rpc and /terminal are UNAUTHENTICATED. "
                + "Cross-origin browser requests are rejected, but any same-origin page or native client that can "
                + "reach this address can run git and open a shell. Use only on trusted networks.")
        }

        // Single-instance guard: refuse to start a SECOND crowd on this socket. A
        // duplicate would skip the unix bind and orphan `crow.sock` when the first
        // exits (the multi-`crowd-dev` footgun). Distinct --socket → own lock, so
        // isolated daemons still run (CROW-581).
        guard acquireSingleInstanceLock(socketPath: options.socketPath) else {
            log("Another crowd is already running on \(options.socketPath) — exiting. "
                + "Only one daemon per socket is allowed (use a distinct --socket for an isolated instance).")
            exit(1)
        }

        let store = JSONStore()
        let git = GitManager()
        let appState = await seedAppState(from: store)
        // Apply config-derived AppState fields (rc, auto-permission modes, board
        // filters) before anything reads them — the board poll's first takeover
        // rebuilds the Manager terminal from `remoteControlEnabled` (CROW-581).
        await applyConfigToAppState(appState, devRoot: options.devRoot)

        // Loud warning: a set web password is bypassed by any loopback forwarder
        // that omits X-Forwarded-For (ssh -L / socat / cloud port-forward), which
        // presents as a trusted local peer (review #1; WebAuthGuard.authorize).
        if ConfigStore.loadConfig(devRoot: options.devRoot)?.webAuth != nil {
            log("WARNING: a web password is set, but a loopback forwarder that omits X-Forwarded-For (ssh -L, socat, cloud port-forward) is trusted as local and bypasses it — make sure your proxy sets X-Forwarded-For.")
        }

        // Register coding agents in the daemon's own AgentRegistry so
        // `list-agents` (and future launch gating) answer locally, with the
        // desktop app down. Mirrors the app's registration; both hosts read the
        // same store-backed binary overrides (CROW-581, M-B).
        await registerAgents(devRoot: options.devRoot)

        // Providers back both the board tracker (M-C) and the spawn engine
        // (M-E2). Zero-config at construction — it reads gh/glab/config lazily.
        let providerManager = ProviderManager()

        // Boards: the daemon owns the ticket/review + allowlist read layer so
        // those panels work with the app down (CROW-581, M-C). AllowListService
        // is a synchronous disk scan (ready immediately); IssueTracker polls the
        // providers — its Timer needs a RunLoop.main the headless daemon doesn't
        // run, so we drive it with an explicit async tick (`startBoardPoll`)
        // instead of `tracker.start()`.
        let (tracker, allowList): (IssueTracker, AllowListService) = await MainActor.run {
            let tracker = IssueTracker(appState: appState, providerManager: providerManager)
            let allowList = AllowListService(appState: appState, devRoot: options.devRoot)
            allowList.scan()
            return (tracker, allowList)
        }
        // Fan-out hub for server-initiated `changed` nudges over `/rpc`, so
        // connected clients re-fetch on state change instead of polling
        // (CROW-581, M-D).
        let eventHub = EventHub()

        // Live-reload the store so the web UI reflects the desktop app's writes
        // (new sessions/status/terminals/links) without a daemon restart.
        startStoreReloadPoll(store: store, appState: appState, eventHub: eventHub)

        // Terminal cockpit (tmux). Optional — RPC still works without tmux, but
        // the terminal handlers (new-terminal/close-terminal) and `/terminal`
        // then return an error / are disabled.
        let cockpit = TerminalCockpit(devRoot: options.devRoot)
        if cockpit == nil {
            log("WARNING: tmux not found; /terminal + terminal RPC disabled (set CROW_TMUX to override)")
        }

        // Host the real SessionService so the daemon can spawn Manager (and
        // later review/job) workspaces headlessly with the app down (ADR 0007;
        // CROW-581, M-E2). It drives tmux through the process-global
        // `TmuxBackend.shared`, which we point at the SAME server the web
        // terminal (`TerminalCockpit`) uses so spawned windows appear there.
        // `wireTerminalReadiness` arms the callback that launches the agent once
        // its tmux window is ready. No tmux → no spawning (nil; spawn RPCs keep
        // forwarding / erroring).
        // `autoRespond` backs quick-action's local path AND (standalone) the
        // auto-respond-to-PR-transition automation. Built alongside SessionService
        // because both need a live cockpit to have a terminal to send to. Manual
        // quick-actions bypass the AutoRespondSettings toggles; the automation
        // path honors them, so read them fresh from config (CROW-581, M-E).
        let sessionService: SessionService?
        let autoRespond: AutoRespondCoordinator?
        (sessionService, autoRespond) = await MainActor.run { () -> (SessionService?, AutoRespondCoordinator?) in
            guard let cockpit else { return (nil, nil) }
            TmuxBackend.shared.configure(
                tmuxBinary: cockpit.controller.tmuxBinary,
                socketPath: cockpit.controller.socketPath,
                crowBinDir: (options.devRoot as NSString).appendingPathComponent(".claude/bin"))
            let service = SessionService(
                store: store, appState: appState,
                providerManager: providerManager, hostBridge: NoopHostBridge())
            service.wireTerminalReadiness()
            let coordinator = AutoRespondCoordinator(
                appState: appState, providerManager: providerManager,
                settingsProvider: {
                    ConfigStore.loadConfig(devRoot: options.devRoot)?.autoRespond ?? AutoRespondSettings()
                })
            return (service, coordinator)
        }

        // Write-actions that mutate session state run locally on the daemon's
        // own SessionService / store — the sole authority (ADR 0007).

        // Drive the board poll. It also performs the terminal "takeover" (adopt
        // persisted tmux windows + ensure the Manager) on startup (CROW-581).
        startBoardPoll(
            tracker: tracker, eventHub: eventHub, sessionService: sessionService,
            appState: appState, devRoot: options.devRoot)

        // Wire the IssueTracker background automations — crow:auto, auto-respond,
        // auto-merge, auto-rebase, auto-cleanup, review auto-kickoff. Needs a live
        // cockpit (terminals to dispatch into) (CROW-581).
        // Serializes review kickoffs (auto-review + the start-review RPC share
        // the internal createReviewSession dedupe; a dedicated serializer keeps a
        // burst of pending review requests from racing duplicate clones).
        let reviewSerializer = ReviewKickoffSerializer()
        if let sessionService {
            await MainActor.run {
                wireTrackerAutomations(
                    tracker: tracker, appState: appState, sessionService: sessionService,
                    autoRespond: autoRespond, devRoot: options.devRoot,
                    reviewSerializer: reviewSerializer)
            }
        }

        // Scheduled jobs (CROW-317) — run them headless too. `JobScheduler.start()`
        // uses a `RunLoop.main` Timer the daemon lacks, so build it here and drive
        // `tick()` from an explicit async loop, gated on authority (CROW-581).
        // Hoisted out of the `if let sessionService` block so it can also back the
        // `run-job` RPC's local path via `makeCommandRouter` below (ADR 0007).
        let jobScheduler: JobScheduler? = await MainActor.run { () -> JobScheduler? in
            guard let sessionService else { return nil }
            let scheduler = JobScheduler(appState: appState, sessionService: sessionService)
            scheduler.jobsProvider = { ConfigStore.loadConfig(devRoot: options.devRoot)?.jobs ?? [] }
            scheduler.devRootProvider = { options.devRoot }
            scheduler.onJobRan = { jobID, ranAt in
                // Jobs (incl. `lastRunAt`) live in config.json, not the store —
                // persist under the shared config lock so a Settings save can't
                // clobber it (review #10).
                ConfigStore.withConfigLock {
                    guard var config = ConfigStore.loadConfig(devRoot: options.devRoot),
                          let idx = config.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                    config.jobs[idx].lastRunAt = ranAt
                    try? ConfigStore.saveConfig(config, devRoot: options.devRoot)
                }
            }
            return scheduler
        }
        if let jobScheduler { startJobPoll(scheduler: jobScheduler) }

        // Delegate any method the daemon's curated router doesn't explicitly own
        // to the app's FULL engine router (hook-event, send, link/ticket ops,
        // resync-jira, get-session, list-worktrees, …). This makes a "missing
        // handler" structurally impossible: crowd answers everything the app does,
        // not a hand-copied subset (ADR 0007; CROW-581). Needs a live
        // SessionService — its EngineContext is non-optional; with no tmux there's
        // nothing to fall back to (spawn/terminal RPCs were already disabled).
        let engineDevRoot = options.devRoot
        let engineFallback: CommandRouter? = await MainActor.run { () -> CommandRouter? in
            guard let sessionService else { return nil }
            let ctx = EngineContext(
                appState: appState, store: store, sessionService: sessionService,
                issueTracker: tracker, telemetryPort: nil, devRoot: engineDevRoot,
                hostBridge: NoopHostBridge(),
                loadConfig: {
                    let dr = ConfigStore.loadDevRoot() ?? engineDevRoot
                    guard let cfg = ConfigStore.loadConfig(devRoot: dr) else { return nil }
                    return (dr, cfg)
                },
                applyConfig: { incoming in
                    try? ConfigStore.saveConfig(incoming, devRoot: engineDevRoot)
                    return ConfigStore.loadConfig(devRoot: engineDevRoot)
                })
            return makeEngineRouter(ctx)
        }

        let commandRouter = makeCommandRouter(
            appState: appState, store: store, git: git, devRoot: options.devRoot,
            cockpit: cockpit, tracker: tracker, allowList: allowList,
            sessionService: sessionService, autoRespond: autoRespond, jobScheduler: jobScheduler,
            fallback: engineFallback)

        // Unix socket — lets the existing `crow` CLI talk to the daemon. By
        // default this IS the app's well-known `crow.sock` (the daemon owns it in
        // the client-default world), so refuse to bind when another server already
        // answers on it (another crowd instance): `SocketServer.start()` unlinks
        // unconditionally, so binding would hijack that server's CLI channel. The
        // probe is live, so a *stale* socket file is reclaimed, not skipped
        // (CROW-581 review).
        if Self.socketInUse(options.socketPath) {
            log("WARNING: \(options.socketPath) is already in use (another crowd instance). "
                + "Not binding the Unix socket to avoid hijacking it — use a distinct --socket. Continuing with HTTP/WS only.")
        } else {
            let socketServer = SocketServer(socketPath: options.socketPath, router: commandRouter)
            do {
                try socketServer.start()
                log("JSON-RPC Unix socket listening at \(options.socketPath)")
            } catch {
                log("WARNING: socket bind failed (\(error)); continuing with HTTP/WS only")
            }
        }

        // Web-access auth (CROW-593): shared session store + login rate limiter,
        // used by the HTTP middleware and both WS-upgrade gates.
        let sessions = SessionStore()
        // Periodically drop expired login tokens so a long-running daemon doesn't
        // accrue abandoned sessions (review #2 — SessionStore.prune had no caller).
        Task { while !Task.isCancelled { try? await Task.sleep(for: .seconds(300)); sessions.prune() } }
        let loginLimiter = LoginRateLimiter()

        // WebSocket router: JSON-RPC at /rpc, terminal byte-stream at /terminal.
        let wsRouter = Router(context: CrowWSContext.self)
        RPCWebSocketHandler.mount(on: wsRouter, commandRouter: commandRouter, eventHub: eventHub, boundHost: options.host, sessions: sessions, devRoot: options.devRoot)
        if let cockpit { TerminalWebSocket.mount(on: wsRouter, cockpit: cockpit, boundHost: options.host, sessions: sessions, devRoot: options.devRoot) }

        // HTTP router: web UI, xterm assets, health.
        let httpRouter = Router(context: CrowHTTPContext.self)
        httpRouter.get("/health") { _, _ in "ok" }
        // Web-access password gate + /login + /logout (CROW-593). Added before the
        // asset/board routes so the middleware wraps them.
        WebAuthRoutes.mount(on: httpRouter, sessions: sessions, loginLimiter: loginLimiter, devRoot: options.devRoot, webDir: options.webDir)
        // Local-only secret management (web password + AI gateways) as
        // Origin-checked HTTP POSTs, gated to a local-direct peer (CROW-593).
        SecretRoutes.mount(on: httpRouter, boundHost: options.host, devRoot: options.devRoot)
        StaticAssets.mount(on: httpRouter, webDir: options.webDir)
        // Per-session generated images (diagrams/screenshots an agent dropped
        // in the scratch dir), served read-only + sandboxed (CROW-593).
        Artifacts.mount(on: httpRouter)
        if let webDir = options.webDir {
            log("serving web UI live from \(webDir) (edit + refresh, no rebuild)")
        }

        let app = Application(
            router: httpRouter,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(
                address: .hostname(options.host, port: options.httpPort),
                serverName: "crowd"))

        log("HTTP/WS listening on http://\(options.host):\(options.httpPort) (terminal at /)")
        try await app.runService()
    }

    /// Wire the IssueTracker's background automation hooks: spawns go to the
    /// daemon's Manager terminal / SessionService, notifications are dropped (no
    /// UI). Config-gated behaviors read `{devRoot}/.claude/config.json` fresh each
    /// poll so Settings edits take effect (CROW-581).
    @MainActor
    private static func wireTrackerAutomations(
        tracker: IssueTracker,
        appState: AppState,
        sessionService: SessionService,
        autoRespond: AutoRespondCoordinator?,
        devRoot: String,
        reviewSerializer: ReviewKickoffSerializer
    ) {
        func config() -> AppConfig? { ConfigStore.loadConfig(devRoot: devRoot) }
        // crow:auto — run /crow-workspace on the Manager for a newly-labeled
        // assigned issue (the tracker strips the label after, so once-only).
        tracker.autoCreateWatcherEnabledProvider = { (config()?.autoCreateWatcherEnabled ?? false) }
        tracker.onAutoCreateRequest = { issue in
            guard let managerTerminal = appState.terminals[AppState.managerSessionID]?.first else {
                log("crow:auto: Manager terminal not ready; dropped \(issue.url)")
                return
            }
            TerminalRouter.send(managerTerminal, text: "/crow-workspace \(issue.url)\n")
        }

        // Auto-respond to PR transitions (changes-requested / checks-failing) and
        // auto-rebase conflict hand-off — both go through the coordinator, which
        // pastes the prompt into the session's managed terminal.
        if let autoRespond {
            tracker.onPRStatusTransitions = { transitions in
                autoRespond.handle(transitions)
            }
            tracker.onAutoRebaseConflicts = { sessionID, _, _ in
                autoRespond.dispatchManual(action: .fixConflicts, sessionID: sessionID)
            }
            tracker.respondToChangesRequestedProvider = { (config()?.autoRespond.respondToChangesRequested ?? false) }
            tracker.autoRebaseAndResolveConflictsProvider = { (config()?.autoRespond.autoRebaseAndResolveConflicts ?? false) }
        }

        // Auto-merge (enable GitHub native auto-merge on eligible Crow PRs). The
        // user-facing notification is dropped headless; the audit line is NSLog'd
        // at the tracker's call site regardless.
        tracker.autoMergeWatcherEnabledProvider = { (config()?.autoMergeWatcherEnabled ?? false) }

        // Auto-complete on merge/close, and auto-move-to-inReview when a
        // session's PR opens, run INSIDE the tracker's own refresh via these
        // `AppState` callbacks (not tracker hooks). The app wires them in
        // AppDelegate; the daemon must too, or `autoCompleteFinishedSessions`
        // / `autoCompleteFinishedReviews` compute the right decisions and then
        // no-op against a nil callback — leaving merged PRs' sessions stuck in
        // `.active`. Authority-gated so the daemon only drives them with the
        // app down; while it's up the app's own refresh owns them (CROW-581).
        appState.onCompleteSession = { id in
            sessionService.completeSession(id: id)
        }
        appState.onSetSessionInReview = { id in
            sessionService.setSessionInReview(id: id)
        }

        // Auto-cleanup — the retention reaper asks the tracker to delete a
        // session; run the daemon's own SessionService teardown.
        tracker.onDeleteSession = { id in
            await sessionService.deleteSession(id: id)
        }

        // Review auto-kickoff — for review requests on repos opted into
        // `autoReviewRepos`, spawn a review session (mirrors the desktop's
        // enqueueReviewKickoff). Fires on every refresh so requests pending at
        // startup are picked up; deduped by a (request, headSHA) fingerprint plus
        // the persisted reviewSessionID, and serialized so a burst can't race
        // duplicate clones. `onNewReviewRequests` is notification-only → dropped.
        var autoReviewed: Set<String> = []
        tracker.onReviewRequestsRefreshed = { requests in
            let patterns = (config()?.workspaces ?? []).flatMap { $0.autoReviewRepos }
            guard !patterns.isEmpty else { return }
            for request in requests {
                guard request.reviewSessionID == nil else { continue }
                guard repoMatchesPatterns(request.repo, patterns: patterns) else { continue }
                let fingerprint = "\(request.id)\n\(request.headRefOid ?? "")"
                guard autoReviewed.insert(fingerprint).inserted else { continue }
                let url = request.url
                Task { _ = await reviewSerializer.enqueue { await sessionService.createReviewSession(prURL: url, selectAfterCreate: false) } }
            }
        }
    }

    /// Drive `IssueTracker.refresh()` on an explicit async tick. The tracker's
    /// own `start()` schedules a `Timer` on `RunLoop.main`, which the headless
    /// daemon never runs (`app.runService()` drives NIO event loops, not an
    /// AppKit run loop) — so the Timer would never fire. This does the initial
    /// fetch immediately, then polls on the app's 60s cadence (CROW-581, M-C).
    /// Broadcasts a `changed` nudge after each poll so clients re-fetch the
    /// boards reactively (M-D).
    ///
    /// Also performs the terminal TAKEOVER: on the first tick it adopts every
    /// persisted tmux window into this process (so `TerminalRouter.send` /
    /// `isRegistered` works) and ensures the Manager. Runs before `refresh()` so
    /// automation dispatches have a live, registered Manager to reach.
    private static func startBoardPoll(
        tracker: IssueTracker,
        eventHub: EventHub,
        sessionService: SessionService?,
        appState: AppState,
        devRoot: String
    ) {
        Task {
            var didTakeOver = false
            while !Task.isCancelled {
                // Re-apply config-derived AppState each tick so settings edits
                // (exclude repos, auto-permission modes, remote control) take
                // effect within one poll — before the Manager rebuild and the
                // board refresh below read them (CROW-581).
                await MainActor.run { applyConfigToAppState(appState, devRoot: devRoot) }
                if let sessionService {
                    if !didTakeOver {
                        await MainActor.run {
                            sessionService.rebuildAllSurfaces()
                            sessionService.ensureManagerSession(devRoot: devRoot)
                        }
                        didTakeOver = true
                    }
                    // Reconcile terminals ↔ tmux windows each tick: prune terminal
                    // records whose window is gone and reap orphaned windows
                    // (targeted-auto, Manager-safe). Runs after `rebuildAllSurfaces`
                    // on the takeover tick so adopted windows are in the keep-set.
                    await MainActor.run { sessionService.reconcileTerminalSurfaces() }
                }
                await tracker.refresh()
                await eventHub.broadcast()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    /// Drive `JobScheduler.tick()` on an explicit async loop (its own Timer needs
    /// a `RunLoop.main` the daemon lacks), on the scheduler's 30s cadence
    /// (CROW-581).
    private static func startJobPoll(scheduler: JobScheduler) {
        Task {
            while !Task.isCancelled {
                await MainActor.run { scheduler.tick() }
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    @MainActor
    private static func seedAppState(from store: JSONStore) -> AppState {
        let appState = AppState()
        reseed(appState, from: store)
        return appState
    }

    /// Register the coding agents in this process's `AgentRegistry`, mirroring
    /// the desktop app's registration (AppDelegate): Claude is always present;
    /// Codex/Cursor/OpenCode register only when their binary resolves on PATH
    /// (or a `defaults.binaries.*` override). Reads binary overrides from the
    /// same on-disk config the app uses so both hosts gate identically
    /// (CROW-581, M-B).
    @MainActor
    private static func registerAgents(devRoot: String) {
        if let config = ConfigStore.loadConfig(devRoot: devRoot) {
            BinaryOverrides.shared.set(config.defaults.binaries)
        }

        AgentRegistry.shared.register(ClaudeCodeAgent())

        let codex = OpenAICodexAgent()
        if let path = codex.findBinary() {
            AgentRegistry.shared.register(codex)
            log("OpenAI Codex agent registered at \(path)")
        }

        let cursor = CursorAgent()
        if let path = cursor.findBinary() {
            AgentRegistry.shared.register(cursor)
            log("Cursor agent registered at \(path)")
        }

        let openCode = OpenCodeAgent()
        if let path = openCode.findBinary() {
            AgentRegistry.shared.register(openCode)
            log("OpenCode agent registered at \(path)")
        }
    }

    /// (Re)populate `appState` from the store snapshot — sessions + their
    /// worktrees, terminals, and links. Called at boot and by the live-reload
    /// poll when the desktop app writes `store.json`. (The app's fuller
    /// `SessionService.hydrateState` — hook state, migrations, agent wiring — is
    /// AppKit-bound and out of scope for the daemon.)
    @MainActor
    private static func reseed(_ appState: AppState, from store: JSONStore) {
        let data = store.data
        appState.sessions = data.sessions
        appState.worktrees = [:]
        appState.terminals = [:]
        appState.links = [:]
        for session in appState.sessions {
            appState.worktrees[session.id] = data.worktrees.filter { $0.sessionID == session.id }
            appState.terminals[session.id] = data.terminals.filter { $0.sessionID == session.id }
            appState.links[session.id] = data.links.filter { $0.sessionID == session.id }
        }
        // Restore persisted hook state so the sidebar can show activity dots
        // (working / needs-attention / done), mirroring the desktop app.
        if let hookStates = data.hookStates {
            let liveIDs = Set(appState.sessions.map(\.id))
            for (key, snapshot) in hookStates {
                guard let sid = UUID(uuidString: key), liveIDs.contains(sid) else { continue }
                appState.restoreHookState(snapshot, for: sid)
            }
        }
    }

    /// Mirror the config-derived `AppState` fields the desktop app syncs in
    /// `AppDelegate` (remote-control, the three auto-permission-mode gates, and
    /// the board exclude/ignore filters). In headless crowd nothing else copies
    /// these out of `config.json`, so without this: the ticket board ignores
    /// `defaults.excludeTicketRepos`, and Manager/job/work sessions never see
    /// their configured auto-permission mode or `--rc`. `reseed` (store-driven)
    /// leaves these fields untouched, so this is the sole writer — called at boot
    /// (before the first takeover's `ensureManagerSession`) and each board tick so
    /// runtime settings edits take effect within one poll (CROW-581).
    @MainActor
    static func applyConfigToAppState(_ appState: AppState, devRoot: String) {
        guard let config = ConfigStore.loadConfig(devRoot: devRoot) else { return }
        appState.remoteControlEnabled = config.remoteControlEnabled
        appState.managerAutoPermissionMode = config.managerAutoPermissionMode
        appState.jobsAutoPermissionMode = config.jobsAutoPermissionMode
        appState.reviewAutoPermissionMode = config.reviewAutoPermissionMode
        appState.coderViewAutoPermissionMode = config.coderViewAutoPermissionMode
        appState.excludeReviewRepos = config.effectiveExcludeReviewRepos
        appState.excludeTicketRepos = config.defaults.excludeTicketRepos
        appState.ignoreReviewLabels = config.defaults.ignoreReviewLabels
        // Configured agent selection. Without this the headless daemon always
        // resolves the built-in default (.claudeCode) via appState.agentKind(for:),
        // so the Settings manager/coder agent pickers are ignored on
        // restart/respawn even though they persist to config (CROW-433 / CROW-581).
        appState.defaultAgentKind = config.defaultAgentKind
        appState.agentsByKind = config.agentsByKind
    }

    /// Poll `store.json`'s mtime and reload when the desktop app writes it, so
    /// the web UI reflects new sessions/status/terminals/links without a daemon
    /// restart. Cheap (a stat every 2s) and robust against the atomic renames
    /// that break fd-based watching. Broadcasts a `changed` nudge on the hub so
    /// connected clients re-fetch immediately instead of waiting for their own
    /// interval poll (CROW-581, M-D).
    private static func startStoreReloadPoll(store: JSONStore, appState: AppState, eventHub: EventHub) {
        Task {
            var lastModified = store.storeModificationDate
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let now = store.storeModificationDate
                if now != lastModified {
                    lastModified = now
                    store.reload()
                    await reseed(appState, from: store)
                    await eventHub.broadcast()
                }
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[crowd] \(message)\n".utf8))
    }

    /// Whether a live server is already accepting on the Unix socket at `path` —
    /// used to avoid stealing another process's socket. A stale socket file
    /// (nothing listening) returns false, so normal startup still replaces it.
    private static func socketInUse(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                p.withMemoryRebound(to: CChar.self, capacity: 104) { dest in strlcpy(dest, ptr, 104) }
            }
        }
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                connect(fd, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    /// Held for the process lifetime once acquired — closing the fd drops the
    /// `flock`, so the OS reclaims the lock automatically on exit or crash.
    /// `nonisolated(unsafe)`: written once during single-threaded startup, then
    /// only kept alive; never mutated concurrently.
    nonisolated(unsafe) private static var singleInstanceLockFD: Int32 = -1

    /// Enforce ONE `crowd` per socket path via an advisory `flock` on
    /// `<socketPath>.lock`. Without it a second daemon on the same socket sees the
    /// socket "in use", skips the unix bind, and runs degraded (HTTP-only) — then
    /// orphans `crow.sock` when the first exits (the multi-`crowd-dev` footgun).
    /// Distinct `--socket` paths get distinct locks, so isolated daemons still
    /// coexist. Fails open on lock-file errors (never blocks a daemon over a weird
    /// lock dir). Returns false when another live crowd already holds this lock
    /// (CROW-581).
    static func acquireSingleInstanceLock(socketPath: String) -> Bool {
        let lockPath = socketPath + ".lock"
        let fd = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o600) }
        guard fd >= 0 else {
            log("WARNING: could not open lock file \(lockPath) (\(String(cString: strerror(errno)))); "
                + "continuing without the single-instance guard")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        singleInstanceLockFD = fd
        return true
    }
}

/// Minimal CLI/env option parsing — kept dependency-free (no argument-parser,
/// no generated BuildInfo) so `crowd` builds standalone on Linux via
/// `swift build --product crowd`.
struct DaemonOptions {
    var httpPort: Int = 8787
    var host: String = "127.0.0.1"
    var socketPath: String = DaemonOptions.defaultDaemonSocketPath()
    var devRoot: String = FileManager.default.currentDirectoryPath
    /// When set, serve web UI files live from this source directory instead of
    /// the compiled bundle (`--web-dir` / `CROW_WEB_DIR`) — edit + refresh.
    var webDir: String?

    /// The well-known `crow.sock` — the same path the `crow` CLI, hooks, and
    /// setup scripts target. In the client-default world (F cutover) the desktop
    /// app no longer binds this socket, so the daemon owns it and every existing
    /// CLI consumer reaches `crowd` unchanged (ADR 0007; CROW-581). Sharing the
    /// path is safe: the bind guard (`socketInUse`, see `run()`) is a live connect
    /// probe — it refuses to bind only when a *running* legacy app already holds
    /// it, and reclaims a stale file otherwise. Run an isolated daemon with an
    /// explicit `--socket` (e.g. a distinct `crowd.sock`) when you must not share.
    static func defaultDaemonSocketPath() -> String {
        SocketServer.defaultSocketPath()
    }

    static func parse(_ arguments: [String]) -> DaemonOptions {
        var options = DaemonOptions()
        var devRootExplicit = false
        if let envRoot = ProcessInfo.processInfo.environment["CROW_DEV_ROOT"] {
            options.devRoot = envRoot
            devRootExplicit = true
        }
        if let envWebDir = ProcessInfo.processInfo.environment["CROW_WEB_DIR"] {
            options.webDir = envWebDir
        }
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            let next = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch flag {
            case "--http-port":
                if let value = next {
                    if let port = Int(value) {
                        options.httpPort = port
                    } else {
                        FileHandle.standardError.write(Data(
                            "[crowd] WARNING: ignoring malformed --http-port '\(value)'; using \(options.httpPort)\n".utf8))
                    }
                }
                index += 1
            case "--host": if let value = next { options.host = value }; index += 1
            case "--socket", "--socket-path": if let value = next { options.socketPath = value }; index += 1
            case "--dev-root":
                if let value = next {
                    options.devRoot = value
                    devRootExplicit = true
                }
                index += 1
            case "--web-dir": if let value = next { options.webDir = value }; index += 1
            default:
                if flag.hasPrefix("-") {
                    FileHandle.standardError.write(Data("[crowd] WARNING: ignoring unknown flag '\(flag)'\n".utf8))
                }
            }
            index += 1
        }
        // Match the desktop app: read ~/Library/Application Support/crow/devroot
        // when no explicit override is supplied (CROW_DEV_ROOT / --dev-root).
        if !devRootExplicit {
            if let configured = ConfigStore.loadDevRoot() {
                options.devRoot = configured
            } else {
                options.devRoot = FileManager.default.currentDirectoryPath
            }
        }
        return options
    }
}
