#if canImport(AppKit)
import AppKit  // only for the WKWebView cockpit surface (gated below); Linux uses the daemon's WebSocket terminal instead
#endif
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
/// Responsibilities:
///   - Lazily start a per-app tmux server with the bundled `crow-tmux.conf`.
///   - Lazily create ONE `XTermSurfaceView` whose command is
///     `tmux attach-session …` (the "shared cockpit" surface that every
///     tmux-backed Crow tab re-parents into).
///   - Map terminal UUIDs to tmux window indices.
///   - Drive `select-window` / `new-window` / `kill-window` / `paste-buffer`
///     in response to UI events from the rest of the app.
///   - Track readiness via `SentinelWaiter` (replaces the historical 5s
///     sleep from the old per-terminal renderer path).
///
/// Thread-safety: `@MainActor` — AppKit-thread access required for surface ops.
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

    /// Fired when the cockpit attach client's PTY exits outside a deliberate
    /// `shutdown()`/`destroy()` — i.e. the tmux server crashed out from under
    /// the app, or the user detached the client (#588). Deliberate teardown
    /// never fires this: `shutdown()` destroys the surface (which nils the
    /// underlying `onProcessExit`) before touching the server.
    public var onCockpitExit: ((Int32) -> Void)?

    /// Fired when a cached controller's cockpit session has vanished mid-run —
    /// the server died while the app was live (#588). A fresh launch (no
    /// cached controller) never fires this. Secondary, lazy detection: it only
    /// triggers on the next tmux command; the primary signal is `onCockpitExit`.
    public var onServerLost: (() -> Void)?

    // MARK: - Internal state

    /// Created on first use of the backend. Survives until app exit (or a
    /// `shutdown()` call from the watchdog flow in PROD #5).
    private var controller: TmuxController?

    /// The single embedded surface attached to the cockpit session. Created
    /// lazily on first use; WKWebView must load in a visible window.
    #if canImport(AppKit)
    private var sharedSurface: XTermSurfaceView?
    #endif

    /// UUID → tmux window index for tabs registered with us.
    private var bindings: [UUID: Int] = [:]

    /// Agent-window indices seen orphaned on the previous reconcile pass — the
    /// one-pass grace so a window created mid-`new-terminal` (before its binding
    /// lands) is never reaped (CROW-581).
    private var orphanGraceWindows: Set<Int> = []

    /// Terminal whose tmux window is currently selected, so `makeActive` can
    /// skip a redundant `select-window`. SwiftUI re-runs `updateNSView` (→
    /// `syncSurface` → `makeActive`) repeatedly for the same visible tab;
    /// without this each call shells out another run-loop-pumping subprocess
    /// (review nit on #336). Keyed by UUID, not window index — tmux can reuse
    /// a freed index for a new window, and a UUID never collides that way.
    private(set) var activeTerminalID: UUID?

    /// UUID → per-terminal sentinel path. Cleared on destroy.
    private var sentinels: [UUID: String] = [:]

    /// UUID → per-terminal wrapper-log path. Populated alongside `sentinels`
    /// so `captureDiagnostics(id:)` can read it back on `.timedOut`. Cleared
    /// on destroy. Issue #256.
    private var wrapperLogs: [UUID: String] = [:]

    /// UUID → in-flight readiness watch Tasks (the 10s progress beacon and
    /// the waiter). `destroyTerminal` cancels these so they don't fire
    /// `onReadinessChanged` for a tab the user just closed. Issue #282.
    private var readinessTasks: [UUID: [Task<Void, Never>]] = [:]

    /// Poll loop watching the Manager window's foreground command so the
    /// "Manager process exited" banner reappears under the shared xterm.js
    /// attach client (#558). At most one runs at a time; re-armed by
    /// `SessionService` on launch / restart. See `startManagerExitMonitor`.
    private var managerExitMonitor: Task<Void, Never>?

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
            NSLog("[CrowTelemetry tmux:\(killServer ? "server_killed" : "server_detach") bindings=\(bindings.count)]")
        }
        // Destroy the surface BEFORE kill-server: destroy() nils the surface's
        // onProcessExit synchronously, and killServer's waitUntilExit pumps the
        // main run loop — without this order the attach client's death would be
        // delivered mid-shutdown and a deliberate restart would masquerade as
        // a server crash (#588). Guarded for the Linux daemon build, where the
        // AppKit surface doesn't exist (b982621).
        #if canImport(AppKit)
        sharedSurface?.destroy()
        sharedSurface = nil
        #endif
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

    // MARK: - Per-terminal API

    /// Create a new tmux window for `id`. If the cockpit session doesn't
    /// exist yet, starts it. Returns the binding so callers can persist
    /// it on the `SessionTerminal` row.
    ///
    /// `agentSurface` selects this window's scroll model (ADR-0013): a
    /// repainting agent TUI gets `alternate-screen on`, while a plain shell
    /// keeps the global `off` and the unified 50k scrollback. Callers should
    /// pass `SessionTerminal.isAgentSurface(session:)` rather than a hand-rolled
    /// test — in particular `isManaged` ALONE is wrong, because the Manager's
    /// terminal is built without that flag yet still runs an agent.
    @discardableResult
    public func registerTerminal(
        id: UUID,
        name: String,
        cwd: String,
        command: String?,
        trackReadiness: Bool,
        agentKind: AgentKind? = nil,
        agentSurface: Bool = false,
        extraEnv: [String: String] = [:],
        newWindowTimeout: TimeInterval = TmuxController.defaultTimeout
    ) throws -> TmuxBinding {
        precondition(!tmuxBinary.isEmpty, "TmuxBackend.configure(...) must be called first")
        let ctrl: TmuxController
        do {
            ctrl = try ensureRunningServer()
        } catch {
            reportIfTimeout(error)
            throw error
        }

        // Each window gets its own sentinel path so concurrent terminals
        // don't race on the same file.
        let sentinelPath = sentinelPath(for: id)
        try? FileManager.default.removeItem(atPath: sentinelPath)
        sentinels[id] = sentinelPath

        // Per-terminal wrapper log. The bundled shell wrapper writes stage
        // breadcrumbs here so `captureDiagnostics(id:)` can include them in
        // the .timedOut bundle (issue #256).
        let wrapperLog = wrapperLogPath(for: id)
        try? FileManager.default.removeItem(atPath: wrapperLog)
        wrapperLogs[id] = wrapperLog

        // Shell wrapper does the readiness markers + sources user's shell
        // config. Each tmux window's child process *is* the wrapper.
        guard let wrapperURL = BundledResources.shellWrapperScriptURL else {
            throw TmuxBackendError.bundledResourceMissing("crow-shell-wrapper.sh")
        }
        let wrapperPath = wrapperURL.path

        var env = [
            "CROW_SENTINEL": sentinelPath,
            "CROW_WRAPPER_LOG": wrapperLog,
        ]
        // Caller-supplied vars (e.g. CROW_ARTIFACTS_DIR / CROW_SESSION_ID).
        // Merged first so the built-ins below always win on any collision.
        for (key, value) in extraEnv { env[key] = value }
        if let agentKind {
            for (key, value) in CrowAttribution.environmentEntries(for: agentKind) {
                env[key] = value
            }
        }
        if !cwd.isEmpty { env["PWD"] = cwd }

        // CROW-487: hand the per-devroot bin dir to the wrapper so it can
        // prepend it to PATH *after* user rc sourcing — that's the only
        // insertion point that survives `export PATH=…` in `.zshrc`. We also
        // seed the window's PATH directly so non-rc shells (fish, the
        // unknown-shell fallback branch of the wrapper, processes that
        // bypass the wrapper entirely) still find the symlink farm.
        if !crowBinDir.isEmpty {
            env["CROW_BIN_DIR"] = crowBinDir
            env["PATH"] = "\(crowBinDir):\(ShellEnvironment.shared.resolvedPATH)"
        }

        let windowIndex = try ctrl.newWindow(
            name: name,
            cwd: cwd.isEmpty ? nil : cwd,
            env: env,
            command: wrapperPath,
            timeout: newWindowTimeout
        )
        bindings[id] = windowIndex

        // Hand agent-TUI windows their own viewport BEFORE the launch command
        // below is pasted, so the agent enters the alt buffer on its very first
        // repaint and never deposits a frame into the shared history (#822).
        if agentSurface {
            enableAlternateScreen(index: windowIndex)
        }

        if trackReadiness {
            startReadinessWatch(id: id, sentinelPath: sentinelPath)
        }

        // If the caller supplied an initial command (e.g. `claude --continue`),
        // route it through the buffer-paste path — same as PROD #3.
        if let command, !command.isEmpty {
            try sendText(id: id, text: command + "\n")
        }

        return TmuxBinding(
            socketPath: ctrl.socketPath,
            sessionName: ctrl.sessionName,
            windowIndex: windowIndex
        )
    }

    /// Re-bind a terminal to a window that already exists in the live tmux
    /// server (e.g. on app restart with a long-lived session). No new
    /// window is created.
    public func adoptTerminal(id: UUID, binding: TmuxBinding, trackReadiness: Bool) throws {
        let (ctrl, serverWasResurrected) = try ensureRunningServerReportingResurrection()
        guard ctrl.socketPath == binding.socketPath, ctrl.sessionName == binding.sessionName else {
            throw TmuxBackendError.bindingMismatch(
                expected: binding.socketPath + ":" + binding.sessionName,
                actual: ctrl.socketPath + ":" + ctrl.sessionName
            )
        }
        let liveIndices = try ctrl.listWindowIndices()
        guard liveIndices.contains(binding.windowIndex) else {
            // A binding exists but the server had to be respawned from
            // scratch: every window is gone, not just this one — the server
            // crashed (or the machine rebooted) since the binding was made.
            // Distinguish that from a single closed window (#588).
            throw serverWasResurrected
                ? TmuxBackendError.serverCrashed
                : TmuxBackendError.windowNotFound(binding.windowIndex)
        }
        bindings[id] = binding.windowIndex
        // No sentinel re-fire on adoption — the wrapper's precmd already
        // touched the file when the original window was created.
        let sentinelPath = sentinelPath(for: id)
        sentinels[id] = sentinelPath
        wrapperLogs[id] = wrapperLogPath(for: id)
        if trackReadiness, FileManager.default.fileExists(atPath: sentinelPath) {
            onReadinessChanged?(id, .shellReady)
        } else if trackReadiness {
            startReadinessWatch(id: id, sentinelPath: sentinelPath)
        }
    }

    /// Bring `id`'s window into focus. Called by the UI when the user
    /// switches tabs.
    ///
    /// The `select-window` shell-out runs synchronously on the main actor so tab
    /// switches stay strictly serialized — the dedup guard, the `select-window`,
    /// and the `activeTerminalID` update are atomic w.r.t. other switches, giving
    /// last-switch-wins. This is safe even mid-window-open-animation because
    /// `TmuxController.run` no longer pumps a nested run loop while waiting
    /// (#653): the main thread blocks on the child without re-entering the
    /// in-flight CoreAnimation commit that used to SIGSEGV. Deliberately NOT moved
    /// off the main actor — doing so let two in-flight switches race and could
    /// leave tmux focused on the wrong window until the next `updateNSView`
    /// (PR #658 review).
    public func makeActive(id: UUID) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        // Already the selected window — skip the redundant `select-window`
        // subprocess (see `activeTerminalID`).
        if id == activeTerminalID { return }
        let start = Date()
        do {
            try ensureRunningServer().selectWindow(index: windowIndex)
        } catch {
            reportIfTimeout(error)
            throw error
        }
        // Record only after a successful switch — a failed `select-window`
        // must not suppress the next attempt.
        activeTerminalID = id
        let elapsedMS = Int((Date().timeIntervalSince(start)) * 1000)
        // Operator-greppable: `[CrowTelemetry tmux:tab_switch_ms=…]`. Easy
        // to graph from logs today; trivially re-routed to a real metrics
        // pipeline once one exists.
        NSLog("[CrowTelemetry tmux:tab_switch_ms=\(elapsedMS) terminal=\(id)]")
    }

    /// Settle time between `paste-buffer` and the submitting `Enter`.
    ///
    /// Bracketed-paste TUIs (Claude Code, Cursor's `agent`) need the
    /// `\e[201~` bracket-end to finish before Enter arrives. 50ms was enough
    /// for short Claude auto-respond lines (#272) but large Cursor pastes
    /// (multi-KB Manager / job prompts) still race: the agent starts working
    /// while sticky text remains in the composer, looking like a double paste
    /// (#631). 200ms clears the composer for those payloads without a second
    /// Enter (which would re-submit leftover text).
    public static let pasteEnterSettleDelay: TimeInterval = 0.2

    /// Send text to `id`'s window via the buffer-paste path. Works for
    /// arbitrary-size payloads (Phase 3 §3 finding: send-keys -l fails
    /// on >10KB; load-buffer + paste-buffer scales to 50KB+ in 133ms).
    ///
    /// Quirk: agent TUIs enable bracketed-paste mode, which wraps
    /// `paste-buffer` output in `\e[200~…\e[201~`. A trailing `\n` inside the
    /// bracket is treated as literal text, not as Enter — so prompts that
    /// rely on `\n` to submit (quick actions, auto-respond) get pasted but
    /// never submitted (#264). Strip the trailing newline before pasting and
    /// deliver a separate `Enter` via `send-keys` afterwards.
    ///
    /// `pasteEnterSettleDelay` between the paste and the Enter keystroke
    /// gives the TUI time to process the bracket-end sequence (`\e[201~`).
    /// Without this, Enter can arrive early: Claude may drop it entirely
    /// (#272); Cursor may submit but leave the prompt sitting in the input
    /// box (#631).
    ///
    /// We also pre-cancel copy-mode on the pane before any delivery (#486).
    /// The bundled `crow-tmux.conf` keeps `mouse on` so wheel scrollback
    /// works (#452), but the default `WheelUpPane` puts the pane into
    /// copy-mode, where both `paste-buffer` and `send-keys Enter` are
    /// silently consumed by copy-mode key bindings instead of reaching the
    /// underlying shell. Without the cancel, every programmatic send into
    /// a pane the user has scrolled (Manager paste, auto-respond, quick
    /// actions, bare-Enter submits) is dropped.
    public func sendText(id: UUID, text: String) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            let endsWithNewline = text.hasSuffix("\n")
            let payload = endsWithNewline ? String(text.dropLast()) : text

            // Cancel copy-mode if the user scrolled the pane into it before
            // we deliver anything. Covers both the paste-buffer path (which
            // is a no-op in copy-mode) and the bare-Enter path (where
            // `send-keys Enter` would otherwise hit the copy-mode key table
            // — default emacs `copy-selection-and-cancel`, vi `cancel` —
            // exiting copy-mode without delivering a CR to the shell (#486).
            try ctrl.cancelCopyModeIfActive(target: target)

            var didPaste = false
            if !payload.isEmpty {
                let bufferName = "crow-\(id.uuidString)"
                try ctrl.loadBufferFromStdin(name: bufferName, data: Data(payload.utf8))
                defer { ctrl.deleteBuffer(name: bufferName) }
                try ctrl.pasteBuffer(name: bufferName, target: target)
                didPaste = true
            }
            if endsWithNewline {
                // Give the TUI time to process the paste bracket-end before
                // the Enter key arrives. Only needed when we actually pasted
                // content — a bare "\n" (Enter-only) needs no delay.
                if didPaste {
                    Thread.sleep(forTimeInterval: Self.pasteEnterSettleDelay)
                }
                try ctrl.sendKeys(target: target, keys: ["Enter"])
            }
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Drop the scrollback buffer for terminal `id` via `tmux clear-history`.
    /// On-screen rows survive — only the off-screen history is wiped — matching
    /// what macOS Terminal "Clear" and iTerm2 "Clear Buffer" do. Surfaced from
    /// the terminal context menu.
    public func clearHistory(id: UUID) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            _ = try ctrl.run(["clear-history", "-t", target])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Enter tmux copy-mode and select the entire scrollback for terminal
    /// `id` — the "Select All" equivalent for a terminal pane. Surfaced from
    /// the terminal context menu. After this, Copy
    /// (or Cmd+C) writes the captured text to the macOS pasteboard via the
    /// existing `copy-pipe-no-clear` binding.
    public func selectAll(id: UUID) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            // -H makes copy-mode enter without scrolling the screen first.
            _ = try ctrl.run(["copy-mode", "-H", "-t", target])
            try ctrl.sendKeys(target: target, keys: ["-X", "history-top"])
            try ctrl.sendKeys(target: target, keys: ["-X", "begin-selection"])
            try ctrl.sendKeys(target: target, keys: ["-X", "history-bottom"])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Read the live working directory of terminal `id`'s pane via
    /// `tmux display-message -p -F '#{pane_current_path}'`. Used by
    /// smart-detect `path:line` resolution (#471 gap 5) to honour the
    /// pane's *current* cwd rather than the cockpit surface's static
    /// `workingDirectory` (which is fixed to `$HOME` at create time and
    /// never tracks the shell's `cd`s). Returns nil on any error so the
    /// caller can fall back without crashing.
    public func activePaneCwd(id: UUID) -> String? {
        guard let windowIndex = bindings[id] else { return nil }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            let raw = try ctrl.displayMessage(target: target, format: "#{pane_current_path}")
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            reportIfTimeout(error)
            return nil
        }
    }

    /// Direction for `searchInScrollback`. `backward` walks toward older
    /// output (the common case for Cmd+F on terminal history); `forward`
    /// walks toward newer output.
    public enum SearchDirection {
        case backward
        case forward
    }

    /// Enter tmux copy-mode and start a search for `query` in the
    /// scrollback of terminal `id` (#471 gap 2). Powers the Cmd+F search
    /// affordance. `tmux send-keys -X search-backward "<query>"` jumps the
    /// copy-mode cursor to the most recent match; subsequent calls to
    /// `searchAgain` step through additional matches without re-running
    /// the search. The pane stays in copy-mode until the caller invokes
    /// `exitCopyMode` (or the user hits ESC).
    public func searchInScrollback(
        id: UUID,
        query: String,
        direction: SearchDirection
    ) throws {
        guard !query.isEmpty else { return }
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            _ = try ctrl.run(["copy-mode", "-H", "-t", target])
            let command = direction == .backward ? "search-backward" : "search-forward"
            try ctrl.sendKeys(target: target, keys: ["-X", command, query])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Step to the next/previous match for the active search in terminal
    /// `id`'s copy-mode (#471 gap 2). Maps to `search-again` /
    /// `search-reverse` per tmux's own conventions.
    public func searchAgain(id: UUID, reverse: Bool) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            let command = reverse ? "search-reverse" : "search-again"
            try ctrl.sendKeys(target: target, keys: ["-X", command])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Leave copy-mode in terminal `id`, restoring normal shell input.
    /// Used by the search bar's Done button (#471 gap 2) and by callers
    /// that want to abandon a prompt-jump (#471 gap 6).
    public func exitCopyMode(id: UUID) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            try ctrl.sendKeys(target: target, keys: ["-X", "cancel"])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Jump the copy-mode cursor to the previous OSC 133;A prompt-start
    /// marker in terminal `id` (#471 gap 6). Requires the shell wrapper
    /// to emit a non-passthrough OSC 133;A so tmux's emulator sees it.
    /// Enters copy-mode if not already there.
    public func previousPrompt(id: UUID) throws {
        try sendPromptNav(id: id, command: "previous-prompt")
    }

    /// Sibling of `previousPrompt`. Steps forward through OSC 133;A marks.
    public func nextPrompt(id: UUID) throws {
        try sendPromptNav(id: id, command: "next-prompt")
    }

    private func sendPromptNav(id: UUID, command: String) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            _ = try ctrl.run(["copy-mode", "-H", "-t", target])
            try ctrl.sendKeys(target: target, keys: ["-X", command])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Destroy the tmux window backing `id` and forget the binding.
    public func destroyTerminal(id: UUID) {
        if let windowIndex = bindings[id] {
            controller?.killWindow(index: windowIndex)
        }
        bindings.removeValue(forKey: id)
        // Forget the active marker if this was the selected terminal, so a
        // window index tmux later reuses can't be wrongly deduped away.
        if activeTerminalID == id { activeTerminalID = nil }
        // Cancel in-flight readiness watch Tasks so a 30s waiter doesn't
        // fire `onReadinessChanged` against a stale id long after the tab
        // is gone (issue #282).
        readinessTasks.removeValue(forKey: id)?.forEach { $0.cancel() }
        if let sentinelPath = sentinels.removeValue(forKey: id) {
            try? FileManager.default.removeItem(atPath: sentinelPath)
        }
        if let logPath = wrapperLogs.removeValue(forKey: id) {
            try? FileManager.default.removeItem(atPath: logPath)
        }
    }

    /// Bare login shells we consider "orphaned" when a cockpit window is not
    /// referenced by any terminal — i.e. a window left at a shell with no agent
    /// running (#408). Anything else (claude/codex/node/an editor/…) is left
    /// alone. tmux reports `pane_current_command` without the login-shell `-`
    /// prefix, but we match both forms defensively.
    nonisolated static let orphanLoginShells: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "sh", "-sh",
        "fish", "-fish", "dash", "-dash", "ksh", "tcsh", "csh", "login",
    ]

    /// Decide whether a single cockpit window should be reaped. Pure so the
    /// policy is unit-testable: reap only when the window is NOT referenced by a
    /// live terminal AND its pane is sitting at a bare login shell. Never reaps
    /// a window running an agent (or any non-shell process), so an agent that
    /// exited and left the user at a shell — but whose terminal still references
    /// the window — is preserved (it's in `keep`).
    nonisolated static func shouldReapWindow(index: Int, command: String, keep: Set<Int>) -> Bool {
        if keep.contains(index) { return false }
        return orphanLoginShells.contains(command)
    }

    /// Targeted-auto orphan policy (CROW-581). Reap a cockpit window that no live
    /// terminal references (`!keep.contains`) when it is either a forgotten bare
    /// login shell OR a positively-identified coding-agent window (its pinned
    /// name is one of `agentWindowNames`) that has stayed orphaned across two
    /// passes (`seenOrphanedLastPass`, the grace). NEVER reaps the session anchor
    /// (index 0), a bound window, an unknown/infra window, or a **Manager**
    /// (name contains "manager") — Managers are long-lived and may be unbound.
    /// Pure so the policy is unit-testable without tmux.
    nonisolated static func shouldReapOrphanWindow(
        index: Int, name: String, command: String, keep: Set<Int>,
        agentWindowNames: Set<String>, seenOrphanedLastPass: Bool
    ) -> Bool {
        if index == 0 { return false }
        if keep.contains(index) { return false }
        if name.range(of: "manager", options: [.caseInsensitive]) != nil { return false }
        if orphanLoginShells.contains(command) { return true }
        if agentWindowNames.contains(name) { return seenOrphanedLastPass }
        return false
    }

    /// Live cockpit windows as (index, pinned name, foreground command). `[]` if
    /// tmux is unavailable or the read fails.
    public func listCockpitWindows() -> [(index: Int, name: String, command: String)] {
        guard let ctrl = controller else { return [] }
        do { return try ctrl.listWindows() }
        catch { reportIfTimeout(error); return [] }
    }

    // MARK: - Scrollback health (CROW-804)

    /// Pure policy: a window's scroll-up can't show the full transcript when its
    /// pane is in the alternate buffer (no scrollback) OR its `history_limit` is
    /// below the ceiling we bake into new windows. tmux freezes both at window
    /// birth and can't resize/undo either in place (see `crow-tmux.conf`
    /// history-limit caveat), so a degraded window's only remedy is recreation.
    /// `nonisolated static` so the policy is unit-testable without tmux.
    ///
    /// `alternateScreenEnabled` makes the alt-buffer half of that test
    /// KIND-AWARE (ADR-0013). Under the per-surface hybrid scroll model an
    /// agent-TUI window deliberately runs with `alternate-screen on`, so
    /// `alternateOn == true` there is the design working, not a stuck window —
    /// flagging it would badge every agent tab with the ⚠ "Recreate" affordance.
    /// The `history_limit` floor still applies to those windows, and it is what
    /// keeps the CROW-804/#821 detection meaningful: the real pre-config
    /// casualties measured `history_limit=5000` alongside `alternate_on=1`, so
    /// they stay caught by the floor.
    ///
    /// Known blind spot: an agent window genuinely wedged in the alt buffer at
    /// the full 50000 limit is now indistinguishable from the normal state.
    /// That is the accepted cost of the hybrid model — the alternative is a
    /// false ⚠ on every healthy agent surface.
    nonisolated public static func isScrollbackDegraded(
        historyLimit: Int,
        alternateOn: Bool,
        alternateScreenEnabled: Bool = false,
        floor: Int = TmuxBackend.scrollbackHistoryLimit
    ) -> Bool {
        if historyLimit < floor { return true }
        // An agent surface is SUPPOSED to be in the alt buffer.
        return alternateScreenEnabled ? false : alternateOn
    }

    /// Both per-window classifications the web UI needs, from ONE `list-windows`
    /// read: which windows are scrollback-degraded (CROW-804 ⚠ Recreate) and
    /// which run the agent-TUI scroll model (ADR-0013 wheel/mouse routing).
    ///
    /// They ship together on every `list-terminals` RPC, and each is derived
    /// from the same three fields, so reading twice would fork a second `tmux`
    /// subprocess per call for nothing.
    ///
    /// Returns `nil` when tmux is unavailable or the read fails — deliberately
    /// NOT a pair of empty sets. Empty is a perfectly valid SUCCESS (a server
    /// of nothing but plain shells), so emptiness cannot double as a failure
    /// signal. Callers that need to fall back to a different source of truth on
    /// failure — `list-terminals` re-deriving `agent_surface` from
    /// `SessionTerminal.isAgentSurface` — can only do that if failure is
    /// distinguishable. Callers that are happy to fail open collapse it with
    /// `?? []`.
    public func windowScrollbackClassification(
        floor: Int = TmuxBackend.scrollbackHistoryLimit
    ) -> (degraded: Set<Int>, agentSurfaces: Set<Int>)? {
        guard let ctrl = controller else { return nil }
        do {
            let windows = try ctrl.listWindowScrollback()
            let degraded = windows.filter {
                Self.isScrollbackDegraded(
                    historyLimit: $0.historyLimit,
                    alternateOn: $0.alternateOn,
                    alternateScreenEnabled: $0.alternateScreenEnabled,
                    floor: floor)
            }
            let agents = windows.filter(\.alternateScreenEnabled)
            return (Set(degraded.map(\.index)), Set(agents.map(\.index)))
        } catch {
            reportIfTimeout(error)
            return nil
        }
    }

    /// Window indices whose scrollback is degraded per `isScrollbackDegraded`.
    /// Fails open (`[]`) — not badging a window on a failed read is the safe
    /// direction, and matches `listCockpitWindows`. Callers needing BOTH this
    /// and the agent-surface set should use `windowScrollbackClassification`
    /// so tmux is only read once.
    public func degradedWindowIndices(floor: Int = TmuxBackend.scrollbackHistoryLimit) -> Set<Int> {
        windowScrollbackClassification(floor: floor)?.degraded ?? []
    }

    /// Window indices configured as agent-TUI surfaces (`alternate-screen on`),
    /// i.e. the windows that own their own viewport + scrollback under the
    /// hybrid scroll model (ADR-0013). Read from tmux rather than inferred from
    /// window names so the daemon and the web client route on the SAME ground
    /// truth the daemon actually applied.
    public func agentSurfaceWindowIndices() -> Set<Int> {
        windowScrollbackClassification()?.agentSurfaces ?? []
    }

    /// Give one window the agent-TUI scroll model: `alternate-screen on`, so a
    /// repainting agent keeps its frames in the alt buffer (which has no
    /// scrollback) instead of depositing every repaint into the shared 50k
    /// history as duplicate-frame sediment (#822, ADR-0013).
    ///
    /// Best-effort by design: the window is already usable without it, so a
    /// failure here must never fail terminal creation. Returns whether it stuck.
    @discardableResult
    public func enableAlternateScreen(index: Int) -> Bool {
        guard let ctrl = controller else { return false }
        do {
            try ctrl.setWindowOption(index: index, name: "alternate-screen", value: "on")
            return true
        } catch {
            reportIfTimeout(error)
            NSLog("[Crow] could not set alternate-screen on window \(index): \(error)")
            return false
        }
    }

    /// Kill the cockpit window at `index`. Passthrough to the controller so
    /// callers outside `TmuxBackend` (e.g. the CROW-804 terminal recreate in
    /// `SessionService`) can drop a degraded window before re-registering a
    /// fresh one. No-op when tmux is unavailable.
    public func killWindow(index: Int) {
        controller?.killWindow(index: index)
    }

    /// Reap orphaned cockpit windows per `shouldReapOrphanWindow` (targeted-auto).
    /// `keepWindowIndices` are windows referenced by persisted terminals — unioned
    /// with the in-memory `bindings` so a just-adopted window is never reaped.
    /// `agentWindowNames` are the display names `new-terminal` pins on managed
    /// agent windows. Tracks the agent-orphan set for the next pass's grace.
    /// Best-effort; returns the count reaped (CROW-581).
    @discardableResult
    public func reconcileOrphanWindows(keepWindowIndices: Set<Int>, agentWindowNames: Set<String>) -> Int {
        guard let ctrl = controller else { return 0 }
        let keep = keepWindowIndices.union(bindings.values)
        let windows = listCockpitWindows()
        let previouslyOrphaned = orphanGraceWindows
        var stillOrphanedAgents: Set<Int> = []
        var reaped = 0
        for w in windows {
            // Agent-named orphans are grace candidates for the next pass.
            if w.index != 0, !keep.contains(w.index), agentWindowNames.contains(w.name),
               w.name.range(of: "manager", options: [.caseInsensitive]) == nil {
                stillOrphanedAgents.insert(w.index)
            }
            if Self.shouldReapOrphanWindow(
                index: w.index, name: w.name, command: w.command, keep: keep,
                agentWindowNames: agentWindowNames,
                seenOrphanedLastPass: previouslyOrphaned.contains(w.index)) {
                ctrl.killWindow(index: w.index)
                NSLog("[CrowTelemetry tmux:orphan_window_reaped index=\(w.index) name=\(w.name) command=\(w.command)]")
                reaped += 1
            }
        }
        orphanGraceWindows = stillOrphanedAgents
        if reaped > 0 { NSLog("[Crow] Reaped \(reaped) orphaned cockpit window(s) (CROW-581)") }
        return reaped
    }

    /// Decide whether the Manager agent has exited, from one poll sample of its
    /// window's foreground command (#558). Because the agent (`claude …`) runs
    /// *inside* the window's shell wrapper rather than as the pane's direct
    /// child, its exit doesn't kill the pane — the foreground just falls back to
    /// a bare login shell. So we report an exit only once we've seen the agent
    /// actually running (`sawAgentRunning`, a non-shell foreground) and now see
    /// a bare login shell. `nil` (window gone / read failed) is never an exit —
    /// that path also covers teardown, keeping restart/shutdown false-positive
    /// free. Pure so the transition policy is unit-testable without tmux.
    nonisolated static func managerAgentDidExit(paneCommand: String?, sawAgentRunning: Bool) -> Bool {
        guard sawAgentRunning, let command = paneCommand else { return false }
        return orphanLoginShells.contains(command)
    }

    /// Advance the exit-monitor state machine by one poll sample, so the whole
    /// transition — not just its terminal condition — is unit-testable without
    /// tmux (#558). `sample` is the window's foreground command, or `nil` when
    /// the read was inconclusive (binding absent / `display-message` threw /
    /// window gone). Returns the updated `sawAgentRunning` latch and whether an
    /// exit should fire. A non-empty non-shell command latches "agent running";
    /// a bare login shell after that latch fires; `nil` and `""` are no-ops.
    nonisolated static func advanceExitMonitor(
        sawAgentRunning: Bool, sample: String?
    ) -> (sawAgentRunning: Bool, fired: Bool) {
        guard let command = sample else { return (sawAgentRunning, false) }
        if orphanLoginShells.contains(command) {
            return (sawAgentRunning, managerAgentDidExit(paneCommand: command, sawAgentRunning: sawAgentRunning))
        }
        if !command.isEmpty { return (true, false) }
        return (sawAgentRunning, false)
    }

    /// Reap cockpit windows that no live terminal references AND that are
    /// sitting at a bare login shell — leaked windows from a timed-out
    /// `new-window` or a forgotten terminal (#408). `keepWindowIndices` is the
    /// set of window indices referenced by persisted terminals; it is unioned
    /// with the in-memory `bindings` so a window created/adopted this run is
    /// never reaped. Best-effort; returns the count reaped.
    @discardableResult
    public func reapUnboundCockpitWindows(keepWindowIndices: Set<Int>) -> Int {
        guard let ctrl = controller else { return 0 }
        let keep = keepWindowIndices.union(bindings.values)
        let windows: [(index: Int, command: String)]
        do {
            windows = try ctrl.listWindowCommands()
        } catch {
            reportIfTimeout(error)
            return 0
        }
        var reaped = 0
        for window in windows where Self.shouldReapWindow(index: window.index, command: window.command, keep: keep) {
            ctrl.killWindow(index: window.index)
            NSLog("[CrowTelemetry tmux:orphan_window_reaped index=\(window.index) command=\(window.command)]")
            reaped += 1
        }
        if reaped > 0 {
            NSLog("[Crow] Reaped \(reaped) orphaned bare-shell cockpit window(s) (#408)")
        }
        return reaped
    }

    // MARK: - Manager exit monitor (#558)

    /// Watch the Manager terminal's tmux window and fire `onExit` the first time
    /// its foreground command falls back to a bare login shell after the agent
    /// was seen running — i.e. the Manager's `claude`/`codex`/… process exited.
    ///
    /// Under the shared xterm.js cockpit, `XTermSurfaceView.onProcessExit` only
    /// fires when the whole `tmux attach-session` client dies, so it can't tell
    /// a per-window agent exit apart (#558). We poll `#{pane_current_command}`
    /// for the Manager window instead — the same signal the orphan reaper reads.
    ///
    /// At most one monitor runs; a second call cancels the first. The poll skips
    /// samples where the binding is absent (async adopt on launch hasn't landed
    /// yet) or the `display-message` throws (window gone / server down), so
    /// attach-client teardown and restart/shutdown never false-positive. Stops
    /// after firing once; `SessionService` re-arms it on the next Manager launch.
    ///
    /// The blocking `display-message` runs off the main actor (`Task.detached`)
    /// and only the `onExit` hop-back touches the UI thread — a perpetual poll
    /// must never stall AppKit even if the tmux subprocess wedges to its
    /// watchdog timeout.
    ///
    /// Sampling floor: an agent that both launches and exits inside one
    /// `pollInterval` is never observed running, so `sawAgentRunning` stays
    /// false and no banner fires. That's an accepted missed-detection inherent
    /// to polling, not a false positive.
    public func startManagerExitMonitor(
        id: UUID,
        pollInterval: TimeInterval = 3.0,
        onExit: @escaping @MainActor () -> Void
    ) {
        stopManagerExitMonitor()
        let nanos = UInt64(pollInterval * 1_000_000_000)
        managerExitMonitor = Task { [weak self] in
            var sawAgentRunning = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                guard let self else { return }
                // Capture the tmux handle + window index on the main actor, then
                // read `#{pane_current_command}` off it: `TmuxController.run`
                // blocks on `waitUntilExit()`, so keep that subprocess off the UI
                // thread. A missing binding/controller yields a `nil` sample (skip).
                let ctrl = self.controller
                let windowIndex = self.bindings[id]
                let raw: String? = await Task.detached { () -> String? in
                    guard let ctrl, let windowIndex else { return nil }
                    return try? ctrl.displayMessage(
                        target: "\(ctrl.sessionName):\(windowIndex)",
                        format: "#{pane_current_command}"
                    )
                }.value
                let sample = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
                if Task.isCancelled { return }
                let (nextSaw, fired) = Self.advanceExitMonitor(sawAgentRunning: sawAgentRunning, sample: sample)
                sawAgentRunning = nextSaw
                if fired {
                    NSLog("[CrowTelemetry manager:exit_detected terminal=\(id) command=\(sample ?? "")]")
                    onExit()
                    return
                }
            }
        }
    }

    /// Cancel the Manager exit monitor if one is running. Idempotent.
    public func stopManagerExitMonitor() {
        managerExitMonitor?.cancel()
        managerExitMonitor = nil
    }

    /// Return the shared cockpit xterm surface, lazily creating it the
    /// first time. The surface attaches to the live tmux session via
    /// `tmux -S … attach-session -t …` as its child command.
    #if canImport(AppKit)
    public func cockpitSurface() throws -> XTermSurfaceView {
        if let existing = sharedSurface { return existing }
        let ctrl = try ensureRunningServer()
        let attachCommand =
            "\(shellQuote(tmuxBinary)) -S \(shellQuote(ctrl.socketPath)) " +
            "attach-session -t \(shellQuote(ctrl.sessionName))"
        let view = XTermSurfaceView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            workingDirectory: NSHomeDirectory(),
            command: attachCommand
        )
        // The attach client exiting on its own means the server crashed or the
        // user detached — deliberate teardown goes through destroy(), which
        // nils onProcessExit first, so this only fires for the unexpected case
        // (#588). Wired here (not by the caller) so every recreated surface is
        // automatically re-armed after recovery.
        view.onProcessExit = { [weak self] code in
            NSLog("[CrowTelemetry tmux:cockpit_client_exited code=\(code)]")
            self?.onCockpitExit?(code)
        }
        NSLog("[TmuxBackend] created cockpit surface attach=%@", attachCommand)
        // Cache before SwiftUI re-parents into the visible tab container.
        // WKWebView must load in a visible window — do not park offscreen or
        // xterm.js never initializes.
        sharedSurface = view
        return view
    }

    /// Cached cockpit surface, or nil if it hasn't been created yet. Use this
    /// from call sites that want to act ONLY when the cockpit is already live
    /// (e.g. SwiftUI's updateNSView re-parent path) — unlike `cockpitSurface()`
    /// this never creates the surface as a side effect.
    public var existingCockpitSurface: XTermSurfaceView? {
        sharedSurface
    }
    #endif

    /// Destroy only the cockpit attach surface; the server, window bindings,
    /// sentinels and readiness watches all survive. The next `cockpitSurface()`
    /// call re-attaches to the live session. Used when the attach client died
    /// but the server is still healthy (e.g. the user hit prefix-d) (#588).
    public func recycleCockpitSurface() {
        sharedSurface?.destroy()
        sharedSurface = nil
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

    // MARK: - Internal helpers

    private func ensureRunningServer() throws -> TmuxController {
        try ensureRunningServerReportingResurrection().ctrl
    }

    /// Like `ensureRunningServer()`, but also reports whether the cockpit
    /// session had to be created from scratch (`resurrected == true`) —
    /// i.e. the server was NOT running when the caller needed it. Callers
    /// that see a persisted binding fail against a resurrected server know
    /// the whole server died, not just one window (#588).
    private func ensureRunningServerReportingResurrection()
        throws -> (ctrl: TmuxController, resurrected: Bool)
    {
        if let ctrl = controller {
            if ctrl.hasSession() { return (ctrl, false) }
            // We had a live cockpit this run and it's gone — the server died
            // mid-run (or is hung past the watchdog; recovery handles both
            // identically). Fire BEFORE resurrecting so the handler can
            // observe the dead state; it's reentrancy-guarded and hops to a
            // later main-actor turn, so recovery never races this call.
            NSLog("[CrowTelemetry tmux:server_died_midrun bindings=\(bindings.count)]")
            onServerLost?()
        }
        guard !tmuxBinary.isEmpty, !socketPath.isEmpty else {
            // Backend wasn't configured this run (tmux not discovered).
            // Throw rather than precondition-crash — callers catch and surface
            // an error overlay.
            throw TmuxBackendError.notConfigured
        }
        let ctrl = TmuxController(
            tmuxBinary: tmuxBinary,
            socketPath: socketPath,
            sessionName: TmuxBackend.cockpitSessionName
        )
        guard let confURL = BundledResources.tmuxConfURL else {
            throw TmuxBackendError.bundledResourceMissing("crow-tmux.conf")
        }
        // The cockpit session may already be live from a prior Crow launch
        // (#330 stable socket). If so, the bundled conf the server loaded at
        // `-f` time may now be stale relative to the file on disk (#450) —
        // capture the pre-attach state so we can reconcile below.
        let serverWasAlreadyLive = ctrl.hasSession()
        try Self.ensureCockpitSession(ctrl, configPath: confURL.path)
        controller = ctrl
        if serverWasAlreadyLive {
            Self.reconcileBundledConfigIfStale(controller: ctrl, configURL: confURL)
        }
        return (ctrl, !serverWasAlreadyLive)
    }

    // MARK: - Stale-config reconciliation (#450)

    /// Re-source the bundled tmux conf on a live server iff the file on disk
    /// has been modified since the server started. Non-destructive: existing
    /// windows/sessions survive a `source-file` — server-scoped options
    /// (mouse, status, escape-time, …) update in place. Failures are logged
    /// and swallowed; a stale conf is not worth aborting startup over.
    ///
    /// Caveat: the bundled conf includes `set -gas terminal-features ',…'`
    /// which re-appends on each source-file. tmux tolerates duplicate feature
    /// flags (merged by name) so the duplication is benign.
    nonisolated static func reconcileBundledConfigIfStale(
        controller: TmuxController,
        configURL: URL
    ) {
        let confPath = configURL.path
        let confMTime = (try? FileManager.default.attributesOfItem(atPath: confPath))?[.modificationDate] as? Date
        let serverStart = serverStartTime(controller: controller)

        guard shouldReconcile(configMTime: confMTime, serverStartTime: serverStart) else {
            NSLog("[CrowTelemetry tmux:config_reconcile_skipped reason=fresh]")
            return
        }

        do {
            try controller.run(["source-file", confPath])
            NSLog("[CrowTelemetry tmux:config_reconciled path=\(confPath)]")
        } catch {
            NSLog("[CrowTelemetry tmux:config_reconcile_failed error=\"\(error)\"]")
        }
    }

    /// Re-source the bundled `crow-tmux.conf` against the live tmux server
    /// unconditionally — driven by the "Reload Terminal Config" menu item
    /// (#475), where the user has explicitly asked for a reload. Unlike
    /// `reconcileBundledConfigIfStale`, this skips the mtime gate.
    ///
    /// Returns `nil` on success, or a human-readable error string the caller
    /// can surface in a banner. Idempotent: `source-file` against a live
    /// server updates server-scoped options in place; existing windows and
    /// sessions are unaffected.
    @MainActor
    public func reloadBundledConfig() -> String? {
        guard let ctrl = controller, ctrl.hasSession() else {
            return "tmux server is not running"
        }
        guard let confURL = BundledResources.tmuxConfURL else {
            return "bundled crow-tmux.conf not found"
        }
        do {
            try ctrl.run(["source-file", confURL.path])
            NSLog("[CrowTelemetry tmux:config_reloaded_by_user path=\(confURL.path)]")
            return nil
        } catch {
            NSLog("[CrowTelemetry tmux:config_reload_failed error=\"\(error)\"]")
            return "\(error)"
        }
    }

    /// Pure policy: reconcile when either timestamp is missing (conservative
    /// — a redundant `source-file` is cheap) or when the conf is newer than
    /// the running server.
    nonisolated static func shouldReconcile(configMTime: Date?, serverStartTime: Date?) -> Bool {
        guard let configMTime, let serverStartTime else { return true }
        return configMTime > serverStartTime
    }

    /// `tmux display -p '#{start_time}'` → Unix epoch as a string. Returns
    /// nil on any IO/parse failure; callers treat nil as "unknown — reconcile
    /// to be safe".
    nonisolated static func serverStartTime(controller: TmuxController) -> Date? {
        guard let raw = try? controller.run(["display", "-p", "#{start_time}"]) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let epoch = TimeInterval(trimmed) else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    /// Ensure the cockpit session is live, adopting an existing one if a
    /// concurrent caller won the `new-session` race.
    ///
    /// The cockpit session may already be live even though `controller` is
    /// nil. `TmuxController.run` blocks on `Process.waitUntilExit()`, which
    /// pumps the main run loop — so the `new-session` we're about to issue can
    /// be re-entered by another `ensureRunningServer()` caller before we cache
    /// `controller`. On launch this is the norm: every persisted terminal
    /// hydrates as its own `Task { @MainActor }` (#293) and, with multiple
    /// Manager sessions (#326), six-plus of them race here at once. Whoever
    /// wins creates `crow-cockpit`; the rest must ADOPT it, not re-create it
    /// (`new-session` errors with "duplicate session", and because that throws
    /// the loser never cached `controller` — so every subsequent call kept
    /// failing and every terminal rendered blank).
    ///
    /// `nonisolated static` so the adopt branch is testable without a real
    /// tmux server or the main actor — it touches no instance/actor state.
    nonisolated static func ensureCockpitSession(
        _ ctrl: CockpitSessionStarter,
        configPath: String?,
        // The "session anchor" is a no-op long-running command — kept alive so
        // the session persists even if every window is closed by the user.
        // /usr/bin/tail -f /dev/null is the conventional choice.
        anchorCommand: String = "/usr/bin/tail -f /dev/null"
    ) throws {
        if ctrl.hasSession() { return }
        do {
            try ctrl.newSessionDetached(configPath: configPath, env: [:], command: anchorCommand)
        } catch {
            // Lost the creation race after the `hasSession()` check above: a
            // reentrant caller created the session while our `new-session`
            // subprocess was starting. The session exists, which is exactly
            // the post-condition we want — adopt it rather than propagating
            // the spurious "duplicate session" failure.
            guard ctrl.hasSession() else { throw error }
        }
    }

    private func sentinelPath(for id: UUID) -> String {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        return (dir as NSString)
            .appendingPathComponent("crow-ready-\(id.uuidString).sentinel")
    }

    /// Per-terminal log path for `crow-shell-wrapper.sh` stage breadcrumbs
    /// (issue #256). Stable across `registerTerminal` / `adoptTerminal` /
    /// `retryReadinessWatch` for a given terminal UUID.
    private func wrapperLogPath(for id: UUID) -> String {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        return (dir as NSString)
            .appendingPathComponent("crow-wrapper-\(id.uuidString).log")
    }

    private func startReadinessWatch(id: UUID, sentinelPath: String) {
        startReadinessWatch(id: id, sentinelPath: sentinelPath, timeoutBudget: 30.0)
    }

    private func startReadinessWatch(id: UUID, sentinelPath: String, timeoutBudget: TimeInterval) {
        let waiter = SentinelWaiter()
        // Periodic progress beacon every 10s so operators tailing the log can
        // see the watch is alive and whether the sentinel has appeared yet
        // (issue #256). Cancelled when the waiter resolves.
        let progressTask = Task { [weak self] in
            let startedAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                let exists = FileManager.default.fileExists(atPath: sentinelPath)
                _ = self  // keep the capture; method-level NSLog is fine
                NSLog("[CrowTelemetry tmux:first_prompt_progress terminal=\(id) elapsed_ms=\(elapsed) sentinel_exists=\(exists)]")
            }
        }
        let waiterTask = Task { [weak self] in
            // 30s default budget (was 5s). On app restart with many managed
            // terminals hydrating concurrently, shell startup is CPU-contended
            // and the wrapper's first precmd may not fire within 5s. Callers
            // can pass a longer budget for retries (see retryReadinessWatch).
            let elapsed = await waiter.waitForPrompt(
                sentinelPath: sentinelPath,
                timeout: timeoutBudget
            )
            progressTask.cancel()
            await MainActor.run { [weak self] in
                // Bail if the terminal was destroyed (or the backend went
                // away) while we were waiting. Without this guard a 30s
                // waiter could fire readiness for a tab the user closed
                // 29s ago — issue #282.
                guard let self, self.bindings[id] != nil else { return }
                if let elapsed {
                    let ms = Int(elapsed * 1000)
                    NSLog("[CrowTelemetry tmux:first_prompt_ms=\(ms) terminal=\(id)]")
                    self.onReadinessChanged?(id, .shellReady)
                } else {
                    // Genuine timeout. Most likely the shell is alive but its
                    // startup is pathologically slow (heavy zshrc + concurrent
                    // hydrate, cold tmux server + App Nap on a backgrounded
                    // app); less likely the wrapper failed to install the
                    // precmd hook (exotic shell) or the shell crashed at start.
                    //
                    // Surface this via `.timedOut` rather than lying about
                    // readiness. Auto-paste of the launch command relies on a
                    // live `zle`, so pasting blind here can leave the pane in
                    // an unrecoverable state (visible command, no Claude TUI,
                    // bytes consumed by half-initialized subshells). The UI
                    // renders a Retry affordance for `.timedOut`; the
                    // `didBecomeActive` observer also re-arms automatically
                    // when the app returns to the foreground.
                    let ms = Int(timeoutBudget * 1000)
                    NSLog("[CrowTelemetry tmux:first_prompt_timeout terminal=\(id) budget_ms=\(ms)]")
                    // Capture stage-by-stage diagnostics and dump them to the
                    // system log alongside the timeout marker. The UI surfaces
                    // the same bundle via "Copy diagnostics" (issue #256).
                    let bundle = self.captureDiagnostics(id: id)
                    NSLog("[CrowTelemetry tmux:first_prompt_diagnostics terminal=\(id)]\n\(bundle)")
                    self.onReadinessChanged?(id, .timedOut)
                }
            }
        }
        // Track both Tasks so `destroyTerminal` can cancel them (#282).
        // `retryReadinessWatch` may call us again for the same id; the
        // previous Tasks are already resolved (or about to be), so appending
        // here rather than replacing keeps the contract simple.
        readinessTasks[id, default: []].append(contentsOf: [progressTask, waiterTask])
    }

    /// Re-arm the readiness watch for a terminal whose first attempt timed
    /// out. Clears the stale sentinel file (in case the wrapper now writes
    /// to it asynchronously) and starts a fresh watch with a longer budget.
    /// Safe to call repeatedly; previous watches resolve independently.
    public func retryReadinessWatch(id: UUID, timeoutBudget: TimeInterval = 120.0) {
        guard let sentinelPath = sentinels[id] else { return }
        try? FileManager.default.removeItem(atPath: sentinelPath)
        startReadinessWatch(id: id, sentinelPath: sentinelPath, timeoutBudget: timeoutBudget)
    }

    /// Build a stage-by-stage diagnostic bundle for terminal `id`. Captures
    /// pane contents, pane PID + process tree, sentinel state, and the
    /// wrapper's breadcrumb log. Each section is wrapped so a single missing
    /// piece doesn't lose the rest; per-section output is capped to keep the
    /// clipboard payload sane. Called from the readiness-watch timeout path
    /// (logged via NSLog) and from the UI "Copy diagnostics" button
    /// (issue #256).
    public func captureDiagnostics(id: UUID) -> String {
        let sectionCap = 8_192
        var lines: [String] = []
        lines.append("=== Crow tmux readiness diagnostics ===")
        lines.append("terminal=\(id)")
        lines.append("captured_at=\(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        // Section 1: environment & host
        lines.append("--- environment ---")
        let env = ProcessInfo.processInfo.environment
        lines.append("SHELL=\(env["SHELL"] ?? "")")
        lines.append("PATH=\(env["PATH"] ?? "")")
        lines.append("TERM=\(env["TERM"] ?? "")")
        lines.append("USER=\(env["USER"] ?? "")")
        if !tmuxBinary.isEmpty,
           let ver = TmuxController.versionString(tmuxBinary: tmuxBinary) {
            lines.append("tmux=\(ver)")
        } else {
            lines.append("tmux=<unknown>")
        }
        if let dscl = runShortCommand(
            "/usr/bin/dscl",
            ["." , "-read", "/Users/\(env["USER"] ?? "")", "UserShell"]
        ) {
            lines.append("dscl=\(dscl.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        lines.append("")

        // Section 2: tmux state for this terminal's window
        lines.append("--- tmux state ---")
        guard let windowIndex = bindings[id] else {
            lines.append("no binding for terminal \(id) — window never created")
            lines.append("")
            return appendSentinelAndLog(id: id, sectionCap: sectionCap, lines: lines)
        }
        let ctrl = controller
        if let ctrl {
            let target = "\(ctrl.sessionName):\(windowIndex)"
            lines.append("target=\(target)")

            // pane_pid + pane_current_command — what's actually running in
            // the pane right now.
            var panePID: Int32?
            if let info = try? ctrl.displayMessage(
                target: target,
                format: "#{pane_pid} #{pane_current_command}"
            ) {
                let trimmed = info.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("display_message=\(trimmed)")
                if let firstField = trimmed.split(separator: " ").first,
                   let pid = Int32(firstField) {
                    panePID = pid
                }
            } else {
                lines.append("display_message=<failed>")
            }
            lines.append("")

            // ps on the pane PID + immediate descendants. Reveals whether the
            // wrapper is still alive or has exec'd into the shell.
            lines.append("--- process tree ---")
            if let pid = panePID {
                if let ps = runShortCommand(
                    "/bin/ps",
                    ["-o", "pid,ppid,stat,etime,command", "-p", "\(pid)"]
                ) {
                    lines.append(ps.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if let children = runShortCommand("/usr/bin/pgrep", ["-P", "\(pid)"]) {
                    let childPIDs = children.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
                    for child in childPIDs {
                        if let ps = runShortCommand(
                            "/bin/ps",
                            ["-o", "pid,ppid,stat,etime,command", "-p", child]
                        ) {
                            lines.append(ps.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
            } else {
                lines.append("<no pane pid available>")
            }
            lines.append("")

            // Pane capture — usually the single most useful signal: shows
            // whether we're stuck at the shell prompt, mid-.zshrc, or showing
            // a python traceback from oh-my-zsh.
            lines.append("--- pane capture (last 200 lines) ---")
            if let pane = try? ctrl.capturePane(target: target, linesBack: 200) {
                lines.append(truncated(pane, max: sectionCap))
            } else {
                lines.append("<capture-pane failed>")
            }
            lines.append("")
        } else {
            lines.append("controller not initialized")
            lines.append("")
        }

        return appendSentinelAndLog(id: id, sectionCap: sectionCap, lines: lines)
    }

    private func appendSentinelAndLog(id: UUID, sectionCap: Int, lines: [String]) -> String {
        var out = lines

        // Sentinel state — exists? size? parent writable?
        out.append("--- sentinel ---")
        if let path = sentinels[id] {
            out.append("path=\(path)")
            let fm = FileManager.default
            let exists = fm.fileExists(atPath: path)
            out.append("exists=\(exists)")
            if exists, let attrs = try? fm.attributesOfItem(atPath: path) {
                if let size = attrs[.size] as? Int { out.append("size=\(size)") }
                if let mtime = attrs[.modificationDate] as? Date {
                    out.append("mtime=\(ISO8601DateFormatter().string(from: mtime))")
                }
            }
            let parent = (path as NSString).deletingLastPathComponent
            out.append("parent=\(parent) parent_writable=\(fm.isWritableFile(atPath: parent))")
        } else {
            out.append("no sentinel path recorded for terminal \(id)")
        }
        out.append("")

        // Wrapper log — the breadcrumb trail.
        out.append("--- wrapper log ---")
        if let path = wrapperLogs[id] {
            out.append("path=\(path)")
            if let data = try? String(contentsOfFile: path, encoding: .utf8) {
                out.append(truncated(data, max: sectionCap))
            } else {
                out.append("<log not readable or absent>")
            }
        } else {
            out.append("no wrapper log path recorded for terminal \(id)")
        }
        out.append("")
        out.append("=== end diagnostics ===")
        return out.joined(separator: "\n")
    }

    /// Run a short command and return its stdout (≤2s timeout). Used by
    /// `captureDiagnostics` so any single subprocess hanging can't wedge the
    /// main actor. Returns `nil` on any failure (missing binary, non-zero
    /// exit, timeout) so the caller can fall back gracefully.
    private func runShortCommand(_ launchPath: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let queue = DispatchQueue.global(qos: .utility)
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        queue.asyncAfter(deadline: .now() + 2.0, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func truncated(_ s: String, max: Int) -> String {
        if s.count <= max { return s }
        let head = s.prefix(max)
        return head + "\n…(truncated; \(s.count - max) chars omitted)"
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Forward .timedOut errors to the unresponsive callback. Other errors
    /// pass through silently — they're regular CLI failures the caller
    /// already handles.
    private func reportIfTimeout(_ error: Error) {
        if let tmuxError = error as? TmuxError, case .timedOut = tmuxError {
            NSLog("[CrowTelemetry tmux:server_unresponsive error=\"\(tmuxError)\"]")
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
