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

        let store = JSONStore()
        let git = GitManager()
        let appState = await seedAppState(from: store)

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

        startBoardPoll(tracker: tracker, eventHub: eventHub)
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
                settingsProvider: { ConfigStore.loadConfig(devRoot: options.devRoot)?.autoRespond ?? AutoRespondSettings() })
            return (service, coordinator)
        }

        // Write-actions that mutate session state are forwarded to the desktop
        // app's socket (the source of truth) so its side effects run and we
        // never clobber its newer state. When the daemon itself owns the default
        // socket (app not running), there's no app to forward to — handle
        // locally instead. (CROW-581)
        let appSocketPath = SocketServer.defaultSocketPath()
        let forwardSocket: String? = (appSocketPath == options.socketPath) ? nil : appSocketPath

        // When standalone (owns the default socket — the app isn't running), the
        // daemon is the authority, so it ensures the primary Manager exists just
        // like the app does at launch. That gives `work-on-issue` a live Manager
        // terminal to drive, and — because the daemon registered the window
        // itself — it holds the live tmux binding in-process, so no stale-index
        // adoption of the app's window is needed (ADR 0007; CROW-581, M-E2).
        if forwardSocket == nil, let sessionService {
            await MainActor.run {
                sessionService.ensureManagerSession(devRoot: options.devRoot)
                // Standalone (app down): the daemon runs the IssueTracker
                // background automations the app normally owns — crow:auto
                // pickup, auto-respond, auto-merge, auto-rebase, auto-cleanup —
                // so they keep working headless. Gated to standalone so app-up
                // doesn't double-drive them (ADR 0007; CROW-581).
                wireTrackerAutomations(
                    tracker: tracker, appState: appState, sessionService: sessionService,
                    autoRespond: autoRespond, devRoot: options.devRoot)
            }
        }

        let commandRouter = makeCommandRouter(
            appState: appState, store: store, git: git, devRoot: options.devRoot,
            cockpit: cockpit, forwardSocket: forwardSocket, tracker: tracker, allowList: allowList,
            sessionService: sessionService, autoRespond: autoRespond)

        // Unix socket — lets the existing `crow` CLI talk to the daemon. Refuse
        // to bind a socket another server already answers on (e.g. the desktop
        // app's crow.sock): `SocketServer.start()` unlinks unconditionally, so
        // binding it would hijack the app's CLI channel (CROW-581 review). The
        // daemon's default is a distinct crowd.sock; sharing is opt-in via
        // --socket, and even then we won't steal a live one.
        if Self.socketInUse(options.socketPath) {
            log("WARNING: \(options.socketPath) is already in use (another crowd or the Crow app). "
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

        // WebSocket router: JSON-RPC at /rpc, terminal byte-stream at /terminal.
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        RPCWebSocketHandler.mount(on: wsRouter, commandRouter: commandRouter, eventHub: eventHub, boundHost: options.host)
        if let cockpit { TerminalWebSocket.mount(on: wsRouter, cockpit: cockpit, boundHost: options.host) }

        // HTTP router: web UI, xterm assets, health.
        let httpRouter = Router()
        httpRouter.get("/health") { _, _ in "ok" }
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

    /// Wire the IssueTracker's background automation hooks for standalone
    /// (app-down) operation, mirroring the desktop app's AppDelegate wiring but
    /// adapted for headless: spawns go to the daemon's Manager terminal /
    /// SessionService, and macOS notifications are dropped (the daemon has no
    /// UI). Config-gated behaviors read `{devRoot}/.claude/config.json` fresh on
    /// each poll so Settings edits take effect. Called only when the app isn't
    /// running (`forwardSocket == nil`) so the app owns these when it is — no
    /// double-drive (CROW-581).
    @MainActor
    private static func wireTrackerAutomations(
        tracker: IssueTracker,
        appState: AppState,
        sessionService: SessionService,
        autoRespond: AutoRespondCoordinator?,
        devRoot: String
    ) {
        func config() -> AppConfig? { ConfigStore.loadConfig(devRoot: devRoot) }

        // crow:auto — run /crow-workspace on the Manager for a newly-labeled
        // assigned issue (the tracker strips the label after, so once-only).
        tracker.autoCreateWatcherEnabledProvider = { config()?.autoCreateWatcherEnabled ?? false }
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
            tracker.onPRStatusTransitions = { transitions in autoRespond.handle(transitions) }
            tracker.onAutoRebaseConflicts = { sessionID, _, _ in
                autoRespond.dispatchManual(action: .fixConflicts, sessionID: sessionID)
            }
            tracker.respondToChangesRequestedProvider = { config()?.autoRespond.respondToChangesRequested ?? false }
            tracker.autoRebaseAndResolveConflictsProvider = { config()?.autoRespond.autoRebaseAndResolveConflicts ?? false }
        }

        // Auto-merge (enable GitHub native auto-merge on eligible Crow PRs). The
        // user-facing notification is dropped headless; the audit line is NSLog'd
        // at the tracker's call site regardless.
        tracker.autoMergeWatcherEnabledProvider = { config()?.autoMergeWatcherEnabled ?? false }

        // Auto-cleanup — the retention reaper asks the tracker to delete a
        // session; run the daemon's own SessionService teardown.
        tracker.onDeleteSession = { id in await sessionService.deleteSession(id: id) }
    }

    /// Drive `IssueTracker.refresh()` on an explicit async tick. The tracker's
    /// own `start()` schedules a `Timer` on `RunLoop.main`, which the headless
    /// daemon never runs (`app.runService()` drives NIO event loops, not an
    /// AppKit run loop) — so the Timer would never fire. This does the initial
    /// fetch immediately, then polls on the app's 60s cadence (CROW-581, M-C).
    /// Broadcasts a `changed` nudge after each poll so clients re-fetch the
    /// boards reactively (M-D).
    private static func startBoardPoll(tracker: IssueTracker, eventHub: EventHub) {
        Task {
            while !Task.isCancelled {
                await tracker.refresh()
                await eventHub.broadcast()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
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

    /// A DISTINCT default from the app's `crow.sock`, in the same owner-only dir,
    /// so running `crowd` with defaults never unlinks/steals the desktop app's
    /// socket. The daemon forwards writes to the app's socket; sharing the app's
    /// path directly is opt-in via `--socket` (CROW-581 review).
    static func defaultDaemonSocketPath() -> String {
        let dir = (SocketServer.defaultSocketPath() as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("crowd.sock")
    }

    static func parse(_ arguments: [String]) -> DaemonOptions {
        var options = DaemonOptions()
        if let envRoot = ProcessInfo.processInfo.environment["CROW_DEV_ROOT"] {
            options.devRoot = envRoot
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
            case "--dev-root": if let value = next { options.devRoot = value }; index += 1
            case "--web-dir": if let value = next { options.webDir = value }; index += 1
            default:
                if flag.hasPrefix("-") {
                    FileHandle.standardError.write(Data("[crowd] WARNING: ignoring unknown flag '\(flag)'\n".utf8))
                }
            }
            index += 1
        }
        return options
    }
}
