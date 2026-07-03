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

        let store = JSONStore()
        let git = GitManager()
        let appState = await seedAppState(from: store)
        let commandRouter = makeCommandRouter(
            appState: appState, store: store, git: git, devRoot: options.devRoot)

        // Unix socket — lets the existing `crow` CLI talk to the daemon.
        let socketServer = SocketServer(socketPath: options.socketPath, router: commandRouter)
        do {
            try socketServer.start()
            log("JSON-RPC Unix socket listening at \(options.socketPath)")
        } catch {
            log("WARNING: socket bind failed (\(error)); continuing with HTTP/WS only")
        }

        // Terminal cockpit (tmux). Optional — RPC still works without tmux.
        let cockpit = TerminalCockpit(devRoot: options.devRoot)
        if cockpit == nil {
            log("WARNING: tmux not found; /terminal disabled (set CROW_TMUX to override)")
        }

        // WebSocket router: JSON-RPC at /rpc, terminal byte-stream at /terminal.
        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        RPCWebSocketHandler.mount(on: wsRouter, commandRouter: commandRouter)
        if let cockpit { TerminalWebSocket.mount(on: wsRouter, cockpit: cockpit) }

        // HTTP router: terminal page, xterm assets, health.
        let httpRouter = Router()
        httpRouter.get("/health") { _, _ in "ok" }
        StaticAssets.mount(on: httpRouter, indexHTML: loadIndexHTML())

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
        // Minimal hydration: sessions + their worktrees. The app's fuller
        // `SessionService.hydrateState` (hook state, terminal migration, agent
        // wiring) is AppKit-bound and out of scope for the daemon's M0 surface.
        let appState = AppState()
        let data = store.data
        appState.sessions = data.sessions
        for session in appState.sessions {
            appState.worktrees[session.id] = data.worktrees.filter { $0.sessionID == session.id }
        }
        return appState
    }

    private static func loadIndexHTML() -> ByteBuffer {
        if let url = Bundle.module.url(
            forResource: "terminal", withExtension: "html", subdirectory: "web"),
            let data = try? Data(contentsOf: url) {
            return ByteBuffer(bytes: data)
        }
        return ByteBuffer(string: "<!doctype html><title>crowd</title><p>terminal.html missing from bundle</p>")
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
            case "--http-port": if let value = next, let port = Int(value) { options.httpPort = port }; index += 1
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
