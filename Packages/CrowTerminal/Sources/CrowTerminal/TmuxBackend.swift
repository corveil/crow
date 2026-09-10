import CrowCore
import Foundation

/// The two cockpit-session ops `TmuxBackend.ensureCockpitSession` performs
/// while starting the tmux server. Abstracted so the create-or-adopt branch
/// is unit-testable with a fake — without spinning up a real tmux server or
/// abstracting the whole `TmuxController`. `TmuxController` is the production
/// conformer (see its `extension` in TmuxController.swift).
protocol CockpitSessionStarter {
    func hasSession() -> Bool
    func newSessionDetached(configPath: String?, env: [String: String], command: String?) throws
}

/// Crow-app-wide singleton that owns the tmux server backing all
/// `SessionTerminal.backend == .tmux` rows.
///
/// Facade (CROW-1222): `configure`, shared state, callbacks, and the public
/// methods callers already use. Each concern lives in its own file as an
/// `extension TmuxBackend` so call sites keep `TmuxBackend.shared.*` and
/// Swift access stays module-internal — no second singleton, no public-API
/// move.
///
///   - `TmuxServerLifecycle` — ensure / resurrect, conf reconcile, reload
///   - `TmuxWindowLifecycle` — register / adopt / destroy / kill / list
///   - `TmuxInput` — paste, search, prompt-nav, select-all, cwd
///   - `TmuxScrollbackHealth` — CROW-804 / CROW-1023 / #822
///   - `TmuxCockpitReaper` — unbound reap + orphan reconcile (not the
///     legacy PID-socket `TmuxOrphanReaper`)
///   - `TmuxReadinessWatch` — sentinel wait, retry, diagnostics
///   - `TmuxManagerExitMonitor` — Manager foreground-command poll (#558)
///
/// Thread-safety: `@MainActor` — window/binding mutations are confined to the
/// main actor. (The daemon renders terminals in-browser over the `/terminal`
/// WebSocket; the retired macOS AppKit surface is gone — ADR 0010.)
@MainActor
public final class TmuxBackend {
    public static let shared = TmuxBackend()

    /// Scrollback ceiling every managed window should be born with. Mirrors the
    /// bundled `crow-tmux.conf` `set -gs history-limit 50000`, the daemon's
    /// `TerminalCockpit.replayLines`, and the web UI's xterm.js `scrollback:
    /// 50000` — the single number those four surfaces must agree on so a full
    /// transcript survives a reconnect. A window whose `history_limit` is below
    /// this (created under an older 2000/5000 default) is degraded and can only
    /// be fixed by recreating it (CROW-804).
    nonisolated public static let scrollbackHistoryLimit = 50000

    /// Windows born under the retracted CROW-1008 inline-agent clamp
    /// (`history-limit 0`). That cap is no longer applied (CROW-1010): Cursor's
    /// transcript is legitimate native scrollback, not frame sediment. A window
    /// still sitting at this limit fails the history floor and should Recreate.
    nonisolated public static let inlineAgentHistoryLimit = 0

    /// Fired when a tmux-backed terminal's readiness state changes.
    /// Callers wire this through to the `TerminalReadiness` state machine so
    /// downstream consumers (e.g. `ClaudeLauncher`) stay backend-agnostic.
    public var onReadinessChanged: ((UUID, TerminalReadiness) -> Void)?

    /// Fired when a tmux subcommand exceeds the watchdog timeout in
    /// `TmuxController.run`. The host app surfaces this to the user (spec
    /// §10.1) — typically via an alert offering "Restart tmux server" — so
    /// the app stays responsive even when the tmux server hangs. Errors
    /// other than `.timedOut` are not forwarded here; they propagate to
    /// the caller for normal handling.
    public var onUnresponsive: ((TmuxError) -> Void)?

    /// Fired when a cached controller's cockpit session has vanished mid-run —
    /// the server died while the app was live (#588). A fresh launch (no
    /// cached controller) never fires this. Lazy detection: it only triggers on
    /// the next tmux command.
    public var onServerLost: (() -> Void)?

    // MARK: - Shared state (CROW-1222)
    //
    // Module-internal so the `extension TmuxBackend` files can reach it.
    // Swift `private` is file-scoped; these are not public and this is not a
    // second singleton.

    /// Created on first use of the backend. Survives until app exit (or a
    /// `shutdown()` call from the watchdog flow in PROD #5).
    var controller: TmuxController?

    /// UUID → tmux window index for tabs registered with us.
    var bindings: [UUID: Int] = [:]

    /// Agent-window indices seen orphaned on the previous reconcile pass — the
    /// one-pass grace so a window created mid-`new-terminal` (before its binding
    /// lands) is never reaped (CROW-581).
    var orphanGraceWindows: Set<Int> = []

    /// Window indices observed in the alternate buffer (`#{alternate_on}==1`) at
    /// least once, latched sticky (CROW-1023). This is the ground truth for the
    /// `uses_alternate_screen` flag `list-terminals` forwards to the client —
    /// which caps xterm scrollback to 0 only for a window that truly owns an alt
    /// buffer. It supersedes the static per-kind `CodingAgent.usesAlternateScreen`
    /// capability, because two Claude Code builds diverge at runtime: one enters
    /// the alt buffer (`alt_on=1`, no client scrollback needed), the other renders
    /// INLINE (`alt_on=0`) and must be treated like Cursor — unified 50k, local
    /// wheel, a visible bar. Only a runtime read tells them apart.
    ///
    /// Sticky (union across reads) so a build that enters the alt screen once
    /// keeps the capped-0 model through its transient main-buffer drops (a
    /// shell-out, exit) instead of flip-flopping its scrollback every poll. Only
    /// windows with `alternate-screen on` (agent surfaces) can ever land here —
    /// a plain shell keeps the global `off`, so even a full-screen app in it
    /// stays `alt_on=0`. Pruned to live windows on each read, and cleared per
    /// index at (re)registration, so a recycled tmux index never inherits a
    /// stale observation.
    var observedAltBufferWindows: Set<Int> = []

    /// Terminal whose tmux window is currently selected, so `makeActive` can
    /// skip a redundant `select-window`. `makeActive` is called repeatedly for
    /// the same visible tab (e.g. re-selecting an already-active terminal), and
    /// without this each call shells out another run-loop-pumping subprocess
    /// (review nit on #336). Keyed by UUID, not window index — tmux can reuse
    /// a freed index for a new window, and a UUID never collides that way.
    var activeTerminalID: UUID?

    /// UUID → per-terminal sentinel path. Cleared on destroy.
    var sentinels: [UUID: String] = [:]

    /// UUID → per-terminal wrapper-log path. Populated alongside `sentinels`
    /// so `captureDiagnostics(id:)` can read it back on `.timedOut`. Cleared
    /// on destroy. Issue #256.
    var wrapperLogs: [UUID: String] = [:]

    /// UUID → in-flight readiness watch Tasks (the 10s progress beacon and
    /// the waiter). `destroyTerminal` cancels these so they don't fire
    /// `onReadinessChanged` for a tab the user just closed. Issue #282.
    var readinessTasks: [UUID: [Task<Void, Never>]] = [:]

    /// Poll loop watching the Manager window's foreground command so the
    /// "Manager process exited" banner reappears under the shared xterm.js
    /// attach client (#558). At most one runs at a time; re-armed by
    /// `SessionService` on launch / restart. See `startManagerExitMonitor`.
    var managerExitMonitor: Task<Void, Never>?

    /// Public for test isolation. Production callers use `.shared`.
    public init() {}

    // MARK: - Configuration

    /// Inject the path to the user's tmux binary. Resolved by the host app
    /// (PROD #4 first-run check uses `which tmux` + version probe).
    /// Must be called before any other method.
    public private(set) var tmuxBinary: String = ""

    /// Persistent socket path. Crow uses one explicit, per-user socket
    /// (`$TMPDIR/crow-tmux.sock`) so it never collides with a user's own tmux.
    /// Since #330 it is stable across app instances: the server outlives a
    /// clean quit and a relaunch re-attaches to it (single-instance guard in
    /// AppDelegate guarantees only one owner).
    public private(set) var socketPath: String = ""

    /// Per-devroot bin dir containing symlinks for `defaults.binaries.<name>`
    /// (CROW-487). When non-empty, `registerTerminal` exports `CROW_BIN_DIR`
    /// into the spawned tmux window and seeds the window's `PATH` with this
    /// directory in front. The shell wrapper re-prepends it after sourcing
    /// the user's rc so a user `export PATH=…` can't shadow the symlink farm.
    public private(set) var crowBinDir: String = ""

    public func configure(tmuxBinary: String, socketPath: String, crowBinDir: String = "") {
        self.tmuxBinary = tmuxBinary
        self.socketPath = socketPath
        self.crowBinDir = crowBinDir
    }

    // MARK: - Lifecycle

    /// Whether the cockpit session is live. Note this may be true on a fresh
    /// app launch (before this process has created anything) when a prior Crow
    /// quit left the server running at the stable socket — see #330.
    public var isRunning: Bool { controller?.hasSession() ?? false }

    /// Probe whether the cockpit tmux session is live on the socket *right now*,
    /// WITHOUT creating it — unlike `ensureRunningServer`, which resurrects an
    /// empty cockpit as a side effect. Used at daemon cold start to choose
    /// between adopting surviving windows (warm `crowd` restart) and recreating
    /// + relaunching them (machine reboot / `tmux kill-server`) — CROW-747.
    ///
    /// Distinct from `isRunning`: that reads the *cached* `controller`, which is
    /// `nil` at daemon boot even when the server is alive, so it can't answer
    /// the cold-start question. This constructs a throwaway `TmuxController`
    /// when none is cached and runs `has-session` against the socket directly.
    /// The throwaway is deliberately NOT cached — populating `controller` with a
    /// session-less handle would make the next `ensureRunningServer` spuriously
    /// fire `onServerLost` (it treats a cached controller whose session vanished
    /// as a mid-run crash). Returns `false` when tmux wasn't configured this run.
    public func cockpitSessionIsLive() -> Bool {
        guard !tmuxBinary.isEmpty, !socketPath.isEmpty else { return false }
        let ctrl = controller ?? TmuxController(
            tmuxBinary: tmuxBinary,
            socketPath: socketPath,
            sessionName: TmuxBackend.cockpitSessionName
        )
        return ctrl.hasSession()
    }

    /// Detach this Crow process from the tmux backend, resetting in-memory
    /// state. Used by app quit and by the crash-watchdog (PROD #5).
    ///
    /// `killServer` controls whether the underlying tmux server is torn down:
    ///   - `false` (clean app quit, #330): leave the server — and all its
    ///     sessions/windows — running so the next launch can re-attach via
    ///     `adoptTerminal`. The sentinel and wrapper-log files are *kept* on
    ///     disk for the same reason: `adoptTerminal` re-fires `.shellReady`
    ///     off the surviving sentinel.
    ///   - `true` (default — crash-watchdog "Restart tmux server"): run
    ///     `kill-server` and unlink the per-terminal scratch files.
    public func shutdown(killServer: Bool = true) {
        if controller != nil {
            CrowLog.info("[CrowTelemetry tmux:\(killServer ? "server_killed" : "server_detach") bindings=\(bindings.count)]")
        }
        if killServer {
            controller?.killServer()
        }
        controller = nil
        bindings.removeAll()
        activeTerminalID = nil
        // Cancel any in-flight readiness watches so they don't keep polling
        // after we let go of the backend. Mirrors the `destroyTerminal`
        // cleanup (#282).
        for tasks in readinessTasks.values { tasks.forEach { $0.cancel() } }
        readinessTasks.removeAll()
        // Stop the Manager exit poll too — its window is gone with the server
        // (#558). `SessionService` re-arms it after `rebuildAllSurfaces`.
        stopManagerExitMonitor()
        // Only unlink the per-terminal scratch files when we're actually
        // killing the server. On a clean quit that leaves the server running
        // they must survive so the next launch's `adoptTerminal` can detect
        // the already-ready shell from the existing sentinel (#330).
        if killServer {
            for path in sentinels.values {
                try? FileManager.default.removeItem(atPath: path)
            }
            for path in wrapperLogs.values {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        sentinels.removeAll()
        wrapperLogs.removeAll()
    }

    /// Reset the cockpit's active-window marker so the next `makeActive` runs a
    /// real `select-window` instead of short-circuiting. Called on the light
    /// "attach client died, server still alive" recovery path (#588) — the
    /// browser xterm.js client reconnects over the daemon's `/terminal`
    /// WebSocket, so there is no native surface to tear down here.
    public func recycleCockpitSurface() {
        // A fresh attach lands on the session's current window, which may not
        // match what we last selected — force the next makeActive to actually
        // run select-window instead of short-circuiting.
        activeTerminalID = nil
    }

    /// Whether `id` has a live tmux-window binding. Used by callers that
    /// want to gate a send/destroy/makeActive on "this terminal is actually
    /// wired up" without relying on the throwing dispatch path.
    public func isRegistered(id: UUID) -> Bool {
        bindings[id] != nil
    }

    /// Forward .timedOut errors to the unresponsive callback. Other errors
    /// pass through silently — they're regular CLI failures the caller
    /// already handles.
    func reportIfTimeout(_ error: Error) {
        if let tmuxError = error as? TmuxError, case .timedOut = tmuxError {
            CrowLog.info("[CrowTelemetry tmux:server_unresponsive error=\"\(tmuxError)\"]")
            onUnresponsive?(tmuxError)
        }
    }

    /// Fixed session name for the cockpit. Per-app, not per-user-session.
    /// `nonisolated` because the value is an immutable string literal —
    /// safe to read from any context (e.g., TmuxOrphanReaper at launch).
    nonisolated public static let cockpitSessionName = "crow-cockpit"
}

public enum TmuxBackendError: Error, CustomStringConvertible {
    case bundledResourceMissing(String)
    case unknownTerminal(UUID)
    case bindingMismatch(expected: String, actual: String)
    case windowNotFound(Int)
    case serverCrashed
    case notConfigured

    public var description: String {
        switch self {
        case let .bundledResourceMissing(name):
            return "TmuxBackend bundled resource missing: \(name)"
        case let .unknownTerminal(id):
            return "TmuxBackend has no binding for terminal \(id)"
        case let .bindingMismatch(expected, actual):
            return "TmuxBackend binding mismatch: expected \(expected), got \(actual)"
        case let .windowNotFound(index):
            return "TmuxBackend: no live window at index \(index)"
        case .serverCrashed:
            return "TmuxBackend: tmux server was not running (crashed or rebooted); cockpit was recreated empty"
        case .notConfigured:
            return "TmuxBackend.configure(...) was not called this run (no tmux ≥ 3.3 binary was found)"
        }
    }
}
