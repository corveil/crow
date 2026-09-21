#if canImport(Darwin)
import Darwin
import MachO
#elseif canImport(Glibc)
import Glibc
#endif
import CrowCore
import CrowCodex
import CrowEngine
import CrowProvider
import CrowGit
import CrowTerminal
import CrowIPC
import CrowPersistence
#if canImport(Network)
import CrowTelemetry
#endif
import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// One-slot box for the `TelemetryService`, so the receiver's `onDataReceived`
/// callback and `SessionService`'s analytics providers — all built before (or
/// alongside) the service itself — can reach it once it exists. MainActor-isolated
/// because that is where every reader already runs, which also makes it `Sendable`
/// without a lock (#772). macOS-only — CrowTelemetry uses Network.framework.
#if canImport(Network)
@MainActor
final class TelemetryHolder {
    var service: TelemetryService?
}
#endif

/// The headless `crowd` daemon: serves Crow's JSON-RPC domain logic and the
/// browser terminal over HTTP + WebSocket, reusing `CrowCore`/`CrowIPC`/
/// `CrowGit`/`CrowPersistence`/`CrowTerminal` verbatim. Also binds the existing
/// Unix socket so the current `crow` CLI can drive it (CROW-581, M0 + M1).
///
/// This file is process bootstrap (`run`, re-exec, log). Automations, poll
/// loops, AppState hydration, flock guards, and CLI parsing live in sibling
/// `CrowDaemon+*.swift` / `DaemonOptions.swift` files (CROW-1279).
public enum CrowDaemon {
    /// Largest WebSocket payload `/rpc` and `/terminal` accept, in bytes.
    ///
    /// Two ceilings, deliberately the same number: the NIO frame decoder's
    /// `maxFrameSize` on the shared upgrade channel (see `run` below), which caps
    /// a single unfragmented frame, and `inbound.messages(maxSize:)` in both
    /// handlers, which caps a message reassembled across continuation frames.
    ///
    /// The frame ceiling is the one that actually bites: `WSCore` size-checks
    /// `maxSize` only while appending *continuation* frames, so a single frame is
    /// never measured against it — and a browser sends one unfragmented frame per
    /// `ws.send()`. With no configuration passed, `maxFrameSize` defaulted to
    /// `1 << 14` and NIO answered anything larger with close 1009 before either
    /// handler saw a byte, no matter what the message ceiling said: every Settings
    /// save failed once `config.json` outgrew ~8 KB, and a >16 KB paste into the
    /// web terminal dropped the socket (CROW-956).
    ///
    /// Matches `SocketServer.maxMessageSize`, so a request's fate does not depend
    /// on whether it arrived over the Unix socket or over `/rpc`.
    static let maxWebSocketFrameSize = 1 << 20

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
        // exits (the multi-`daemon-run` footgun). Distinct --socket → own lock, so
        // isolated daemons still run (CROW-581).
        guard acquireSingleInstanceLock(socketPath: options.socketPath) else {
            logAndExit("Another crowd is already running on \(options.socketPath) — exiting. "
                + "Only one daemon per socket is allowed (use a distinct --socket for an isolated instance).")
        }

        // Store-writer guard: the socket lock above is keyed to the socket, but
        // `store.json` lives at a fixed app-support path regardless of --socket,
        // so two daemons on DIFFERENT sockets would still both write it — and
        // because every mutate rewrites the whole file, the loser's sessions
        // vanish silently. Lock the store itself (fail closed) so exactly one
        // crowd may write it, whatever --socket each was launched with (#759).
        let storeDirectory = JSONStore.defaultDirectory
        guard acquireStoreWriterLock(storeDirectory: storeDirectory) else {
            logAndExit("FATAL: another process already holds the store writer lock for "
                + "\(storeDirectory.path) — refusing to start. Only ONE crowd may write store.json, "
                + "regardless of --socket. Stop the other daemon first (a second writer silently "
                + "clobbers every session the first one knew about).")
        }

        log("started: pid \(getpid()); socket \(options.socketPath); store \(storeDirectory.appendingPathComponent("store.json").path)")

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

        // Ask the installed `codex` whether its hook engine honors
        // `async: true` before the per-worktree hook writer starts running
        // (CROW-999). Fail-closed: no Codex, no binary, a hang, or an
        // unreadable banner all leave hooks registered synchronously, which
        // every Codex build handles. Probed once here — like agent
        // availability — so upgrading `codex` under a running `crowd` needs a
        // restart to take effect. Bounded by the probe's own 3s timeout.
        var codexAsyncHooks = CodexVersionProbe.AsyncHookSupport.unsupported
        if let codexBinary = AgentRegistry.shared.agent(for: .codex)?.findBinary() {
            codexAsyncHooks = await CodexVersionProbe.probe(binaryPath: codexBinary)
            log("Codex hooks: \(codexAsyncHooks.logLine)")
            // Re-register Codex with an async-aware per-worktree hook writer.
            // The initial `registerAgents` registration ran *before* the probe
            // (it needs the registered agent to resolve the binary), with the
            // sync-safe default; now that the verdict is in, replace the agent so
            // `writeHookConfig` emits `async` for `PostToolUse` where the installed
            // Codex honors it (>= 0.148.0). `registerKnown` updates in place —
            // `agent(for:)` returned non-nil only because Codex is available, so
            // re-registering `available: true` preserves that (CROW-1060).
            AgentRegistry.shared.registerKnown(
                OpenAICodexAgent(
                    hookConfigWriter: CodexHookConfigWriter(
                        asyncHooksSupported: codexAsyncHooks.supported)),
                available: true)
        }

        // Refresh the dev-root scaffold — bundled skills, CLAUDE.md,
        // settings.local.json, .claude/bin symlinks — on every launch, the way
        // the retired app's `AppDelegate.launchMainApp` used to (#766). Runs
        // AFTER `registerAgents` (the per-agent branches gate on the registry
        // and on `BinaryOverrides`) and synchronously BEFORE `startBoardPoll`,
        // whose first tick calls `ensureManagerSession` — so the Manager agent
        // sees `.claude/skills/` on first paint. Bounded by
        // `Scaffolder.corveilInstallTimeout` in the worst case.
        let scaffoldWarning = LaunchScaffold.run(
            devRoot: options.devRoot,
            configured: options.devRootConfigured)
        await MainActor.run { appState.corveilSkillInstallWarning = scaffoldWarning }

        // Repair hook blocks left dangling by an earlier build (#897). Must run
        // AFTER `LaunchScaffold.run` (which re-points `.claude/bin/crow`, the
        // path repairs are written with) and after `seedAppState` above (whose
        // sessions decide what is still live), but BEFORE `startBoardPoll` —
        // its first tick runs `ensureManagerSession`, the Manager's own hook
        // writer.
        await LaunchScaffold.repairStaleHooks(
            devRoot: options.devRoot, configured: options.devRootConfigured, appState: appState)

        // Providers back both the board tracker (M-C) and the spawn engine
        // (M-E2). Zero-config at construction — it reads gh/glab/config lazily.
        let providerManager = ProviderManager()

        // Boards: the daemon owns the ticket/review read layer so those panels
        // work with the app down (CROW-581, M-C). IssueTracker polls the
        // providers — its Timer needs a RunLoop.main the headless daemon doesn't
        // run, so we drive it with an explicit async tick (`startBoardPoll`)
        // instead of `tracker.start()`.
        let tracker: IssueTracker = await MainActor.run {
            IssueTracker(appState: appState, providerManager: providerManager, store: store)
        }
        // Fan-out hub for server-initiated `changed` nudges over `/rpc`, so
        // connected clients re-fetch on state change instead of polling
        // (CROW-581, M-D).
        let eventHub = EventHub()

        // Live-reload the store so the web UI reflects the desktop app's writes
        // (new sessions/status/terminals/links) without a daemon restart.
        startStoreReloadPoll(
            store: store, appState: appState, eventHub: eventHub, devRoot: options.devRoot)

        // Terminal cockpit (tmux). Optional — RPC still works without tmux, but
        // the terminal handlers (new-terminal/close-terminal) and `/terminal`
        // then return an error / are disabled.
        let cockpit = TerminalCockpit(devRoot: options.devRoot)
        if cockpit == nil {
            log("WARNING: tmux not found; /terminal + terminal RPC disabled (set CROW_TMUX to override)")
        }

        let tuiHooks: TuiTmuxHooks = {
            guard let cockpit else { return .noop }
            return TuiTmuxHooks(
                displayMessage: { target, format in
                    try cockpit.controller.displayMessage(target: target, format: format)
                },
                capturePane: { target, linesBack in
                    try cockpit.controller.capturePane(target: target, linesBack: linesBack, escapes: false)
                }
            )
        }()
        let tuiRecorder = TuiRecorder(tmux: tuiHooks, eventHub: eventHub)
        tuiRecorder.boot()

        // Telemetry (#772). The OTLP receiver uses Network.framework and is
        // macOS-only; on Linux crowd runs without per-session analytics.
        // Built BEFORE SessionService because the service captures
        // `telemetryPort` (the `OTEL_*` env prefix Claude Code needs) and the
        // analytics providers at init. Enable/port are read once here — changing
        // them needs a daemon restart.
        #if canImport(Network)
        let telemetryConfig = ConfigStore.loadConfig(devRoot: options.devRoot)?.telemetry
            ?? TelemetryConfig()
        // The `onDataReceived` callback resolves through a holder the init fills
        // in afterwards (the app used `self.telemetryService` for the same reason).
        let telemetryHolder = TelemetryHolder()
        // Create AND start before deriving `telemetryPort`: `start()` is where the
        // database opens and the listener comes up. Starting later would leave a
        // window where the port is already baked into every agent launch (exporting
        // at a dead endpoint) and the holder answers queries against an unopened DB.
        var startedTelemetry: TelemetryService?
        if telemetryConfig.enabled {
            do {
                let service = try TelemetryService(
                    port: telemetryConfig.port,
                    onDataReceived: { sessionID in
                        Task { @MainActor in
                            guard let service = telemetryHolder.service else { return }
                            let analytics = await service.analytics(for: sessionID)
                            appState.hookState(for: sessionID).analytics = analytics
                            appState.telemetryCaptureStatus = TelemetryCaptureStatus(
                                sessionCount: max(appState.telemetryCaptureStatus?.sessionCount ?? 0, 1),
                                lastReceivedAt: Date())
                        }
                    })
                // Publish before `start()` so the first datapoint can't arrive to an
                // empty holder; cleared again below if the start throws.
                await MainActor.run { telemetryHolder.service = service }
                try await service.start()
                startedTelemetry = service
            } catch {
                log("WARNING: telemetry receiver unavailable on port \(telemetryConfig.port) "
                    + "(\(error)) — per-session analytics will not be collected")
                await MainActor.run { telemetryHolder.service = nil }
            }
        }
        let telemetry = startedTelemetry
        // nil when telemetry is off OR the receiver never came up: without a live
        // receiver the `OTEL_*` exporter vars would point at a closed port.
        let telemetryPort: UInt16? = telemetry.map(\.port)
        #else
        let telemetryPort: UInt16? = nil
        #endif

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
            // The four telemetry closures resolve through the holder rather than
            // capturing `telemetry` directly, so they stay correct (and nil-safe)
            // whether or not the receiver was created (#772).
            #if canImport(Network)
            let analyticsProvider: @Sendable (UUID) async -> SessionAnalytics? = { id in
                await MainActor.run { telemetryHolder.service }?.analytics(for: id)
            }
            let telemetrySessionIDsProvider: @Sendable () async -> [UUID] = {
                await MainActor.run { telemetryHolder.service }?.sessionIDs() ?? []
            }
            // Per-Manager since CROW-983: the id is a parameter, so every
            // Manager is metered rather than only the well-known primary.
            let managerUsageProvider: @Sendable (UUID, Date, Date) async -> SessionAnalytics = { id, start, end in
                await MainActor.run { telemetryHolder.service }?
                    .analytics(for: id, receivedBetween: start, end: end)
                    ?? SessionAnalytics()
            }
            let telemetryDeleteProvider: @Sendable (UUID) async -> Void = { id in
                await MainActor.run { telemetryHolder.service }?.deleteSessionData(for: id)
            }
            #else
            let analyticsProvider: (@Sendable (UUID) async -> SessionAnalytics?)? = nil
            let telemetrySessionIDsProvider: (@Sendable () async -> [UUID])? = nil
            let managerUsageProvider: (@Sendable (UUID, Date, Date) async -> SessionAnalytics)? = nil
            let telemetryDeleteProvider: (@Sendable (UUID) async -> Void)? = nil
            #endif
            let service = SessionService(
                store: store, appState: appState,
                telemetryPort: telemetryPort,
                providerManager: providerManager,
                analyticsProvider: analyticsProvider,
                telemetrySessionIDsProvider: telemetrySessionIDsProvider,
                managerUsageProvider: managerUsageProvider,
                telemetryDeleteProvider: telemetryDeleteProvider,
                hostBridge: NoopHostBridge())
            service.wireTerminalReadiness()
            let coordinator = AutoRespondCoordinator(
                appState: appState, providerManager: providerManager,
                settingsProvider: {
                    ConfigStore.loadConfig(devRoot: options.devRoot)?.autoRespond ?? AutoRespondSettings()
                })
            return (service, coordinator)
        }

        // One rebuild entry point (#767), shared by the launch startup below, the
        // hourly poll, and the `rebuild-scorecard` RPC: backfill snapshots for
        // sessions recorded before snapshotting existed, recompute the ungraded
        // Manager weekly rollups, and refresh the capture-status line. Wrapped in
        // a single-flight `ScorecardRebuilder` so overlapping callers await one
        // rebuild instead of racing (the RPC never reports success for skipped
        // work, and `isRebuildingScorecard` can't clear mid-run — #781). Nil when
        // telemetry is off.
        let rebuildScorecard: (@MainActor @Sendable () async -> Void)?
        #if canImport(Network)
        if let telemetry, let sessionService {
            let rebuilder = await MainActor.run {
                ScorecardRebuilder {
                    appState.isRebuildingScorecard = true
                    defer { appState.isRebuildingScorecard = false }
                    await sessionService.backfillAnalyticsSnapshots()
                    await sessionService.refreshManagerUsage()
                    appState.telemetryCaptureStatus = await telemetry.captureStatus()
                }
            }
            rebuildScorecard = { await rebuilder.rebuild() }
        } else {
            rebuildScorecard = nil
        }

        // The rest of the telemetry startup, deferred until SessionService exists to
        // drive it. Order mirrors the app's: backfill BEFORE pruning, so sessions
        // whose rows are about to age out still produce a snapshot (#745). The
        // hourly poll keeps the current week's Manager rollup and the capture line
        // moving — the app refreshed only at launch, fine for a process restarted
        // daily but not for a daemon that runs for weeks (#767).
        if let telemetry, let rebuildScorecard {
            let retentionDays = telemetryConfig.retentionDays
            Task {
                await rebuildScorecard()
                await telemetry.pruneOldData(retentionDays: retentionDays)
            }
            startScorecardPoll(rebuild: rebuildScorecard)
        }
        #else
        rebuildScorecard = nil
        #endif

        // Write-actions that mutate session state run locally on the daemon's
        // own SessionService / store — the sole authority (ADR 0007).

        // Push a `changed` nudge whenever the tracker's in-flight state moves,
        // so clients can render a refresh indicator for the *automatic* poll.
        // `isLoadingIssues` is runtime-only (not store-backed), so nothing else
        // announces it. Wired unconditionally — it needs no cockpit, unlike the
        // automations below (CROW-771).
        await MainActor.run {
            tracker.onLoadingIssuesChanged = { Task { await eventHub.broadcast() } }
        }

        // Drive the board poll. It also performs the terminal "takeover" (adopt
        // persisted tmux windows + ensure the Manager) on startup (CROW-581).
        startBoardPoll(
            tracker: tracker, eventHub: eventHub, sessionService: sessionService,
            appState: appState, devRoot: options.devRoot)

        // Drive the session-log collector (CROW-1056). Opt-in and default OFF —
        // the tick is a cheap no-op until a workspace ticks `uploadSessionLogs`
        // and has a gateway to reuse. Terminal-independent (it reads harness log
        // files off disk), so it runs whenever `crowd` runs.
        //
        // First carry any legacy global `logSync` opt-in over to the per-workspace
        // checkbox (CROW-1070), once, under the config lock before the poll starts.
        ConfigStore.migrateLogSyncAtBoot(devRoot: options.devRoot)
        startLogSyncPoll(appState: appState, devRoot: options.devRoot)

        // Wire the IssueTracker's config-flag providers and its notification-only
        // outcome hooks. Terminal-INDEPENDENT, so this runs whenever `crowd` runs —
        // enabling GitHub native auto-merge is a pure gh/GraphQL call and
        // auto-rebase is pure git; neither needs tmux, and a broadcast needs only
        // the event hub. Bundling these behind the cockpit is what silently killed
        // every automation on a daemon started without tmux (CROW-782): the
        // providers stayed at their `{ false }` defaults and `applyAutoMerge`
        // bailed on its first guard, every poll, with no log line. The retired
        // AppDelegate wired them unconditionally; this restores that.
        await MainActor.run {
            wireTrackerAutomations(
                tracker: tracker, appState: appState, devRoot: options.devRoot,
                autoRespond: autoRespond, eventHub: eventHub)
        }

        // Wire the automations that DO need a terminal / SessionService to act:
        // crow:auto workspace spawns, auto-respond + conflict hand-off dispatch,
        // session completion/in-review, auto-cleanup teardown, review auto-kickoff
        // (CROW-581). Without a cockpit these stay nil and the corresponding paths
        // are inert no-ops — but auto-merge above keeps working.
        // Serializes review kickoffs (auto-review + the start-review RPC share
        // the internal createReviewSession dedupe; a dedicated serializer keeps a
        // burst of pending review requests from racing duplicate clones).
        let reviewSerializer = ReviewKickoffSerializer()
        if let sessionService {
            await MainActor.run {
                wireTerminalAutomations(
                    tracker: tracker, appState: appState, sessionService: sessionService,
                    autoRespond: autoRespond, devRoot: options.devRoot,
                    reviewSerializer: reviewSerializer, eventHub: eventHub)
            }
        }

        // One durable startup line so "were automations even armed?" is
        // answerable from the log alone, without a rebuild (CROW-782).
        let cfg = ConfigStore.loadConfig(devRoot: options.devRoot)
        CrowLog.automation(
            "startup: tmux=\(cockpit == nil ? "missing" : "present") "
            + "terminalAutomations=\(sessionService == nil ? "off" : "on") "
            + "autoMergeWatcherEnabled=\(cfg?.autoMergeWatcherEnabled ?? false) "
            + "autoCreateWatcherEnabled=\(cfg?.autoCreateWatcherEnabled ?? false) "
            + "respondToChangesRequested=\(cfg?.autoRespond.respondToChangesRequested ?? false) "
            + "autoRebaseAndResolveConflicts=\(cfg?.autoRespond.autoRebaseAndResolveConflicts ?? false)")

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

        // Upstream version check (CROW-938): compare the stamped build SHA against
        // corveil/crow main. Runs on a long interval and caches the result in
        // memory — failures are silent and never block startup.
        let buildInfo = BuildInfoLoader.load(webDir: options.webDir)
            ?? BuildInfo(version: "?", gitSha: "dev", buildDate: "")
        let versionUpdateService = await MainActor.run {
            VersionUpdateService(buildInfo: buildInfo)
        }
        startVersionUpdatePoll(
            service: versionUpdateService, devRoot: options.devRoot, eventHub: eventHub)

        let corveilManagedRoot = JSONStore.defaultDirectory
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("corveil", isDirectory: true)
        let corveilAutoUpdateService = CorveilAutoUpdateService(
            devRoot: options.devRoot,
            managedRoot: corveilManagedRoot,
            userAgent: "Crow/\(buildInfo.version)",
            onSkillWarning: { warning in
                await MainActor.run { appState.corveilSkillInstallWarning = warning }
            })
        startCorveilAutoUpdatePoll(
            service: corveilAutoUpdateService, devRoot: options.devRoot, eventHub: eventHub)

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
                issueTracker: tracker, telemetryPort: telemetryPort, devRoot: engineDevRoot,
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

        let soundLibrary = CustomSoundLibrary.live
        let commandRouter = makeCommandRouter(
            appState: appState, store: store, git: git, devRoot: options.devRoot,
            cockpit: cockpit, tracker: tracker,
            sessionService: sessionService, autoRespond: autoRespond, jobScheduler: jobScheduler,
            rebuildScorecard: rebuildScorecard, versionUpdateService: versionUpdateService,
            corveilAutoUpdateService: corveilAutoUpdateService,
            soundLibrary: soundLibrary,
            tuiRecorder: tuiRecorder,
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
        if let cockpit { TerminalWebSocket.mount(on: wsRouter, cockpit: cockpit, boundHost: options.host, sessions: sessions, devRoot: options.devRoot, tuiRecorder: tuiRecorder) }

        // HTTP router: web UI, xterm assets, health.
        let httpRouter = Router(context: CrowHTTPContext.self)
        httpRouter.get("/health") { _, _ in "ok" }
        // Web-access password gate + /login + /logout (CROW-593). Added before the
        // asset/board routes so the middleware wraps them.
        WebAuthRoutes.mount(on: httpRouter, sessions: sessions, loginLimiter: loginLimiter, devRoot: options.devRoot, webDir: options.webDir)
        // One-shot JSON-RPC for sandboxed `crow` CLIs that cannot reach crow.sock
        // (CROW-1220). Same router + gates as the /rpc WebSocket; POST only, so it
        // does not collide with the WS upgrade on GET.
        RPCHTTPHandler.mount(
            on: httpRouter, commandRouter: commandRouter, boundHost: options.host,
            devRoot: options.devRoot)
        // Local-only secret management (web password + AI gateways) as
        // Origin-checked HTTP POSTs, gated to a local-direct peer (CROW-593).
        SecretRoutes.mount(on: httpRouter, boundHost: options.host, devRoot: options.devRoot)
        // "Start Crow at login" for Settings → General — same local-only gating,
        // since it registers a launch agent on the host machine (CROW-769).
        AutostartRoutes.mount(on: httpRouter, boundHost: options.host, options: options)
        // Settings → Corveil CLI's Verify / Reinstall skill buttons (CROW-1011).
        // Local-only for the same reason as the two above: both run an absolute
        // path on this machine.
        CorveilRoutes.mount(
            on: httpRouter, boundHost: options.host, devRoot: options.devRoot, appState: appState)
        // Corveil Connect (OAuth) flow (CROW-1119): the loopback callback +
        // Connect trigger. Local-only, same rationale as the routes above — the
        // callback stores user-scoped OAuth tokens on the host. The in-flight
        // authorization store lives for the daemon's lifetime; a periodic prune
        // drops abandoned flows.
        let corveilPendingAuth = CorveilPendingAuthStore()
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                corveilPendingAuth.prune()
            }
        }
        CorveilIntegrationRoutes.mount(
            on: httpRouter, boundHost: options.host, devRoot: options.devRoot,
            httpPort: options.httpPort, pending: corveilPendingAuth)
        // Corveil token health (CROW-1125): renew the stored access token before it
        // expires, and latch a "Reconnect" state (surfaced by `crow corveil status`
        // and the Integrations tab) when a refresh is definitively rejected. Each
        // tick reloads the connection, so it needs no reactive config wiring; a
        // no-op tick when nothing is connected costs one disk read. Ticks first,
        // then sleeps, so an already-expired token is caught at boot rather than one
        // interval later.
        let corveilRefreshDevRoot = options.devRoot
        Task {
            while !Task.isCancelled {
                let outcome = await CorveilTokenRefreshWatcher.tick(devRoot: corveilRefreshDevRoot)
                switch outcome {
                case .refreshed:
                    log("Corveil access token refreshed")
                case .failed(let needsReconnect):
                    log("Corveil token refresh failed"
                        + (needsReconnect ? " — connection revoked, reconnect required" : " (will retry)"))
                case .noConnection, .notRefreshable, .notDue, .superseded:
                    break  // routine; no log
                }
                try? await Task.sleep(for: .seconds(CorveilTokenRefreshWatcher.tickInterval))
            }
        }
        // Read-only MCP for off-box clients (CROW-1004). Authenticates with a scoped
        // bearer token minted by `crow mcp token mint`, NOT the web-session cookie —
        // `/mcp` is listed in `WebAuthMiddleware.isAuthExempt` for that reason, and
        // `MCPRoutes` is strictly stricter than the middleware it replaces.
        MCPRoutes.mount(
            on: httpRouter,
            commandRouter: commandRouter,
            boundHost: options.host,
            devRoot: options.devRoot,
            serverVersion: buildInfo.version)
        StaticAssets.mount(on: httpRouter, webDir: options.webDir)
        // Per-session generated images (diagrams/screenshots an agent dropped
        // in the scratch dir), served read-only + sandboxed (CROW-593).
        Artifacts.mount(on: httpRouter, boundHost: options.host)
        TuiRecordingRoutes.mount(on: httpRouter, boundHost: options.host, recorder: tuiRecorder)
        CustomSoundRoutes.mount(
            on: httpRouter, boundHost: options.host, library: soundLibrary)
        if let webDir = options.webDir {
            log("serving web UI live from \(webDir) (edit + refresh, no rebuild)")
        }

        let app = Application(
            router: httpRouter,
            server: .http1WebSocketUpgrade(
                webSocketRouter: wsRouter,
                // `HTTP1WebSocketUpgradeChannel.Configuration`, not a bare
                // `WebSocketServerConfiguration` — the latter binds to a
                // deprecated overload. Leaving `http1:` at its defaults
                // reproduces exactly what the no-configuration form built, so
                // `maxFrameSize` is the only thing that moves (CROW-956).
                configuration: .init(ws: .init(maxFrameSize: maxWebSocketFrameSize))),
            configuration: .init(
                address: .hostname(options.host, port: options.httpPort),
                serverName: "crowd"))

        log("HTTP/WS listening on http://\(options.host):\(options.httpPort) (terminal at /)")
        try await app.runService()
        #if canImport(Network)
        // Close the OTLP listener and the SQLite handle before we exit or re-exec —
        // the re-exec'd image binds the same port and opens the same db file (#772).
        if let telemetry { await telemetry.stop() }
        #endif
        // First-run setup (`run-setup`) asks us to re-exec so the freshly-written
        // devroot pointer is adopted by every subsystem that captured it at
        // startup (CROW-605). Hummingbird's runService() returns cleanly on
        // SIGTERM (NIO closes the TCP listener → port freed); we then drop the
        // flock and execv the same binary/args.
        if Self.pendingReexec {
            Self.reexec(arguments)
        }
    }

    /// Set by `run-setup` so `run()` re-execs after graceful shutdown. Written
    /// from the RPC handler's Task and read once on the main run path after
    /// `runService()` returns — never mutated concurrently with a read.
    nonisolated(unsafe) static var pendingReexec = false

    /// Ask the daemon to shut down and re-exec itself (so a newly-written
    /// `~/Library/Application Support/crow/devroot` pointer is adopted). Delays
    /// the SIGTERM briefly so the JSON-RPC `ok` result can flush to the client
    /// before graceful shutdown begins (CROW-605).
    static func requestReexec() {
        pendingReexec = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            raise(SIGTERM)
        }
    }

    /// Close the single-instance lock fd (no `O_CLOEXEC`, so an inherited fd
    /// would still hold the flock and the re-exec'd image's
    /// `acquireSingleInstanceLock` would fail), then re-exec the same binary
    /// and args. Does not return on success.
    ///
    /// Resolves the real executable path first — `execv(argv[0])` does **not**
    /// search `PATH`, so a user who ran `crowd` from `~/.local/bin` (the README
    /// install flow) would hit ENOENT and the daemon would `exit(1)` after the
    /// first-run wizard instead of restarting (review Yellow #2 / CROW-605).
    static func reexec(_ argv: [String]) {
        if singleInstanceLockFD >= 0 {
            close(singleInstanceLockFD)
            singleInstanceLockFD = -1
        }
        // Same rationale for the store lock (#759): an inherited fd keeps the
        // flock held, so the re-exec'd image's fail-closed store guard would
        // refuse to start.
        if storeWriterLockFD >= 0 {
            close(storeWriterLockFD)
            storeWriterLockFD = -1
        }
        guard let argv0 = argv.first, !argv0.isEmpty else {
            logAndExit("re-exec failed: empty argv")
        }
        let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { for p in cArgv where p != nil { free(p) } }

        // `execv` replaces this image, taking the log drain thread with it, so
        // anything still queued would never be written (CROW-874). The os_log
        // copy survives regardless; this is for stderr / crowd.log.
        CrowLog.flush(timeout: 1.0)

        // Prefer the kernel's view of this process's executable (absolute path),
        // then a path-shaped argv[0], then `execvp` so a bare `crowd` on PATH still
        // restarts.
        if let resolved = resolvedExecutablePath() {
            execv(resolved, cArgv)
            log("re-exec failed (execv \(resolved)): \(String(cString: strerror(errno)))")
        } else if argv0.contains("/") {
            execv(argv0, cArgv)
            log("re-exec failed (execv \(argv0)): \(String(cString: strerror(errno)))")
        } else {
            execvp(argv0, cArgv)
            log("re-exec failed (execvp \(argv0)): \(String(cString: strerror(errno)))")
        }
        CrowLog.flush(timeout: 1.0)
        exit(1)
    }

    /// Decode a null-terminated `[CChar]` C-string buffer into a `String`,
    /// truncating at the first NUL. Replaces the deprecated `String(cString:)`
    /// array initializer.
    private static func decodeCString(_ buf: [CChar]) -> String {
        String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Absolute path of the running `crowd` binary, or `nil` if it can't be
    /// resolved (caller falls back to `execvp`). Exposed for tests.
    static func resolvedExecutablePath() -> String? {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        // `_NSGetExecutablePath` may return a relative path; realpath makes it
        // absolute so a later cwd change can't break the re-exec.
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(buf, &resolved) != nil else { return decodeCString(buf) }
        return decodeCString(resolved)
        #elseif os(Linux)
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = readlink("/proc/self/exe", &buf, buf.count - 1)
        guard n > 0 else { return nil }
        buf[n] = 0
        return decodeCString(buf)
        #else
        return nil
        #endif
    }

    // Internal (not private): `LaunchScaffold` logs through the same prefix.
    //
    // Routed through `CrowLog` so it cannot block: this used to be a synchronous
    // `FileHandle.standardError.write`, which stalls the caller when stderr is a
    // tty nobody is draining — and `CrowDaemon` is `@MainActor` (CROW-874). The
    // `[crowd]` prefix stays inside the message so these lines read as they
    // always have, now with a leading timestamp.
    static func log(_ message: String) {
        CrowLog.info("[crowd] \(message)")
    }

    /// Log a final line, drain the sink, then exit. `CrowLog` delivery is
    /// asynchronous (CROW-874), so a bare `exit()` right after `log()` would
    /// race the drain and lose the message explaining why the daemon stopped.
    /// The flush is bounded — a wedged stderr delays shutdown by at most a
    /// second, and the os_log copy was already made on this thread regardless.
    private static func logAndExit(_ message: String, code: Int32 = 1) -> Never {
        log(message)
        CrowLog.flush(timeout: 1.0)
        exit(code)
    }
}
