#if canImport(Glibc)
import Glibc
#endif
import CrowCore
import CrowGit
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
        // Live-reload the store so the web UI reflects the desktop app's writes
        // (new sessions/status/terminals/links) without a daemon restart.
        startStoreReloadPoll(store: store, appState: appState)

        // Terminal cockpit (tmux). Optional — RPC still works without tmux, but
        // the terminal handlers (new-terminal/close-terminal) and `/terminal`
        // then return an error / are disabled.
        let cockpit = TerminalCockpit(devRoot: options.devRoot)
        if cockpit == nil {
            log("WARNING: tmux not found; /terminal + terminal RPC disabled (set CROW_TMUX to override)")
        }

        // Write-actions that mutate session state are forwarded to the desktop
        // app's socket (the source of truth) so its side effects run and we
        // never clobber its newer state. When the daemon itself owns the default
        // socket (app not running), there's no app to forward to — handle
        // locally instead. (CROW-581)
        let appSocketPath = SocketServer.defaultSocketPath()
        let forwardSocket: String? = (appSocketPath == options.socketPath) ? nil : appSocketPath

        let commandRouter = makeCommandRouter(
            appState: appState, store: store, git: git, devRoot: options.devRoot,
            cockpit: cockpit, forwardSocket: forwardSocket)

        // Unix socket — lets the existing `crow` CLI talk to the daemon.
        let socketServer = SocketServer(socketPath: options.socketPath, router: commandRouter)
        do {
            try socketServer.start()
            log("JSON-RPC Unix socket listening at \(options.socketPath)")
        } catch {
            log("WARNING: socket bind failed (\(error)); continuing with HTTP/WS only")
        }

        // WebSocket router: JSON-RPC at /rpc, terminal byte-stream at /terminal.
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        RPCWebSocketHandler.mount(on: wsRouter, commandRouter: commandRouter, boundHost: options.host)
        if let cockpit { TerminalWebSocket.mount(on: wsRouter, cockpit: cockpit, boundHost: options.host) }

        // HTTP router: web UI, xterm assets, health.
        let httpRouter = Router()
        httpRouter.get("/health") { _, _ in "ok" }
        StaticAssets.mount(on: httpRouter)

        let app = Application(
            router: httpRouter,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(
                address: .hostname(options.host, port: options.httpPort),
                serverName: "crowd"))

        log("HTTP/WS listening on http://\(options.host):\(options.httpPort) (terminal at /)")
        try await app.runService()
    }

    @MainActor
    private static func seedAppState(from store: JSONStore) -> AppState {
        let appState = AppState()
        reseed(appState, from: store)
        return appState
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
    }

    /// Poll `store.json`'s mtime and reload when the desktop app writes it, so
    /// the web UI reflects new sessions/status/terminals/links without a daemon
    /// restart. Cheap (a stat every 2s) and robust against the atomic renames
    /// that break fd-based watching.
    private static func startStoreReloadPoll(store: JSONStore, appState: AppState) {
        Task {
            var lastModified = store.storeModificationDate
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let now = store.storeModificationDate
                if now != lastModified {
                    lastModified = now
                    store.reload()
                    await reseed(appState, from: store)
                }
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[crowd] \(message)\n".utf8))
    }
}

/// Minimal CLI/env option parsing — kept dependency-free (no argument-parser,
/// no generated BuildInfo) so `crowd` builds standalone on Linux via
/// `swift build --product crowd`.
struct DaemonOptions {
    var httpPort: Int = 8787
    var host: String = "127.0.0.1"
    var socketPath: String = SocketServer.defaultSocketPath()
    var devRoot: String = FileManager.default.currentDirectoryPath

    static func parse(_ arguments: [String]) -> DaemonOptions {
        var options = DaemonOptions()
        if let envRoot = ProcessInfo.processInfo.environment["CROW_DEV_ROOT"] {
            options.devRoot = envRoot
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
            default: break
            }
            index += 1
        }
        return options
    }
}
