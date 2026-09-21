import CrowCore
import CrowIPC
import CrowPersistence
import Foundation

/// Minimal CLI/env option parsing — kept dependency-free (no argument-parser,
/// no generated BuildInfo) so `crowd` builds standalone on Linux via
/// `swift build --product crowd`.
struct DaemonOptions {
    var httpPort: Int = 8787
    var host: String = "127.0.0.1"
    var socketPath: String = DaemonOptions.defaultDaemonSocketPath()
    var devRoot: String = FileManager.default.currentDirectoryPath
    /// Whether `devRoot` came from an explicit override (`--dev-root` /
    /// `CROW_DEV_ROOT`) or the App Support pointer — as opposed to the bare
    /// current-working-directory fallback below. Gates the launch-time scaffold
    /// (#766): re-materializing `.claude/skills/` is right for a configured dev
    /// root and wrong for whatever directory `crowd` happened to start in.
    var devRootConfigured: Bool = false
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
        // An empty / whitespace-only `CROW_DEV_ROOT=` is treated as unset, not
        // as an explicit override of "" — otherwise it would count as a
        // configured root and open the launch-time scaffold gate on a nonsense
        // path (#766 review).
        if let envRoot = ProcessInfo.processInfo.environment["CROW_DEV_ROOT"]?
            .trimmingCharacters(in: .whitespaces), !envRoot.isEmpty {
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
            // An empty / whitespace-only value read as its trimmed self, or nil.
            let trimmedNext = next?.trimmingCharacters(in: .whitespaces)
            switch flag {
            case "--http-port":
                if let value = next {
                    if let port = Int(value) {
                        options.httpPort = port
                    } else {
                        CrowLog.info(
                            "[crowd] WARNING: ignoring malformed --http-port '\(value)'; using \(options.httpPort)")
                    }
                }
                index += 1
            case "--host": if let value = next { options.host = value }; index += 1
            case "--socket", "--socket-path": if let value = next { options.socketPath = value }; index += 1
            case "--dev-root":
                // Same guard as empty `CROW_DEV_ROOT=`: an empty or
                // whitespace-only `--dev-root ""` must NOT count as a configured
                // root. `NSString("").appendingPathComponent(".claude")`
                // resolves to a relative `.claude`, so honoring it would scaffold
                // into the process CWD — the exact footgun `devRootConfigured`
                // exists to prevent (#766 review).
                if let value = trimmedNext, !value.isEmpty {
                    options.devRoot = value
                    devRootExplicit = true
                }
                index += 1
            case "--web-dir": if let value = next { options.webDir = value }; index += 1
            default:
                if flag.hasPrefix("-") {
                    CrowLog.info("[crowd] WARNING: ignoring unknown flag '\(flag)'")
                }
            }
            index += 1
        }
        // Match the desktop app: read ~/Library/Application Support/crow/devroot
        // when no explicit override is supplied (CROW_DEV_ROOT / --dev-root).
        if !devRootExplicit {
            if let configured = ConfigStore.loadDevRoot() {
                options.devRoot = configured
                options.devRootConfigured = true
            } else {
                options.devRoot = FileManager.default.currentDirectoryPath
            }
        } else {
            options.devRootConfigured = true
        }
        return options
    }
}
