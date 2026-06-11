import AppKit
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
///   - Lazily create ONE `GhosttySurfaceView` whose command is
///     `tmux attach-session …` (the "shared cockpit" surface that every
///     tmux-backed Crow tab re-parents into).
///   - Map terminal UUIDs to tmux window indices.
///   - Drive `select-window` / `new-window` / `kill-window` / `paste-buffer`
///     in response to UI events from the rest of the app.
///   - Track readiness via `SentinelWaiter` (replaces the historical 5s
///     sleep used by the now-removed per-terminal Ghostty path).
///
/// Thread-safety: `@MainActor` — same constraint as libghostty, which
/// requires AppKit-thread access for surface ops.
@MainActor
public final class TmuxBackend {
    public static let shared = TmuxBackend()

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

    // MARK: - Internal state

    /// Created on first use of the backend. Survives until app exit (or a
    /// `shutdown()` call from the watchdog flow in PROD #5).
    private var controller: TmuxController?

    /// The single embedded surface attached to the cockpit session. Lazy
    /// because libghostty needs an NSWindow before `ghostty_surface_new`
    /// fires.
    private var sharedSurface: GhosttySurfaceView?

    /// UUID → tmux window index for tabs registered with us.
    private var bindings: [UUID: Int] = [:]

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

    /// Offscreen window the shared surface lives in until SwiftUI re-parents
    /// it into the visible UI. Same trick the Ghostty path uses for
    /// background surface creation.
    private lazy var offscreenWindow: NSWindow = {
        let w = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 600),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false
        return w
    }()

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

    public func configure(tmuxBinary: String, socketPath: String) {
        self.tmuxBinary = tmuxBinary
        self.socketPath = socketPath
    }

    // MARK: - Lifecycle

    /// Whether the cockpit session is live. Note this may be true on a fresh
    /// app launch (before this process has created anything) when a prior Crow
    /// quit left the server running at the stable socket — see #330.
    public var isRunning: Bool { controller?.hasSession() ?? false }

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
        if killServer {
            controller?.killServer()
        }
        sharedSurface?.destroy()
        sharedSurface = nil
        controller = nil
        bindings.removeAll()
        activeTerminalID = nil
        // Cancel any in-flight readiness watches so they don't keep polling
        // after we let go of the backend. Mirrors the `destroyTerminal`
        // cleanup (#282).
        for tasks in readinessTasks.values { tasks.forEach { $0.cancel() } }
        readinessTasks.removeAll()
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
    @discardableResult
    public func registerTerminal(
        id: UUID,
        name: String,
        cwd: String,
        command: String?,
        trackReadiness: Bool,
        agentKind: AgentKind? = nil,
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
        if let agentKind {
            for (key, value) in CrowAttribution.environmentEntries(for: agentKind) {
                env[key] = value
            }
        }
        if !cwd.isEmpty { env["PWD"] = cwd }

        let windowIndex = try ctrl.newWindow(
            name: name,
            cwd: cwd.isEmpty ? nil : cwd,
            env: env,
            command: wrapperPath,
            timeout: newWindowTimeout
        )
        bindings[id] = windowIndex

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
        let ctrl = try ensureRunningServer()
        guard ctrl.socketPath == binding.socketPath, ctrl.sessionName == binding.sessionName else {
            throw TmuxBackendError.bindingMismatch(
                expected: binding.socketPath + ":" + binding.sessionName,
                actual: ctrl.socketPath + ":" + ctrl.sessionName
            )
        }
        let liveIndices = try ctrl.listWindowIndices()
        guard liveIndices.contains(binding.windowIndex) else {
            throw TmuxBackendError.windowNotFound(binding.windowIndex)
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

    /// Send text to `id`'s window via the buffer-paste path. Works for
    /// arbitrary-size payloads (Phase 3 §3 finding: send-keys -l fails
    /// on >10KB; load-buffer + paste-buffer scales to 50KB+ in 133ms).
    ///
    /// Quirk: Claude Code's TUI enables bracketed-paste mode, which wraps
    /// `paste-buffer` output in `\e[200~…\e[201~`. A trailing `\n` inside the
    /// bracket is treated as literal text, not as Enter — so prompts that
    /// rely on `\n` to submit (quick actions, auto-respond) get pasted but
    /// never submitted (#264). Strip the trailing newline before pasting and
    /// deliver a separate `Enter` via `send-keys` afterwards, mirroring what
    /// `GhosttySurfaceView.writeText` does with keycode 36.
    ///
    /// A 50ms delay between the paste and the Enter keystroke gives the TUI
    /// time to process the bracket-end sequence (`\e[201~`). Without this,
    /// auto-respond prompts (which fire when the terminal has been idle) can
    /// race: the Enter arrives before the TUI finishes handling the paste,
    /// causing it to be silently dropped (#272).
    ///
    /// We also pre-cancel copy-mode on the pane before pasting (#486). The
    /// bundled `crow-tmux.conf` keeps `mouse on` so wheel scrollback works
    /// (#452), but the default `WheelUpPane` puts the pane into copy-mode,
    /// where `paste-buffer` does not deliver content. Without the cancel,
    /// every programmatic send into a pane the user has scrolled (Manager
    /// paste, auto-respond, quick actions) is silently dropped.
    public func sendText(id: UUID, text: String) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            let endsWithNewline = text.hasSuffix("\n")
            let payload = endsWithNewline ? String(text.dropLast()) : text

            var didPaste = false
            if !payload.isEmpty {
                let bufferName = "crow-\(id.uuidString)"
                try ctrl.loadBufferFromStdin(name: bufferName, data: Data(payload.utf8))
                defer { ctrl.deleteBuffer(name: bufferName) }
                // Cancel copy-mode if the user scrolled the pane into it
                // — paste-buffer is a no-op while the pane is in a mode
                // (#486).
                try ctrl.cancelCopyModeIfActive(target: target)
                try ctrl.pasteBuffer(name: bufferName, target: target)
                didPaste = true
            }
            if endsWithNewline {
                // Give the TUI time to process the paste bracket-end before
                // the Enter key arrives. Only needed when we actually pasted
                // content — a bare "\n" (Enter-only) needs no delay.
                if didPaste {
                    Thread.sleep(forTimeInterval: 0.05)
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
    /// the right-click context menu in `GhosttySurfaceView`.
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
    /// the right-click context menu in `GhosttySurfaceView`. After this, Copy
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

    /// Return the shared cockpit Ghostty surface, lazily creating it the
    /// first time. The surface attaches to the live tmux session via
    /// `tmux -S … attach-session -t …` as its child command.
    public func cockpitSurface() throws -> GhosttySurfaceView {
        if let existing = sharedSurface { return existing }
        let ctrl = try ensureRunningServer()
        let attachCommand =
            "\(shellQuote(tmuxBinary)) -S \(shellQuote(ctrl.socketPath)) " +
            "attach-session -t \(shellQuote(ctrl.sessionName))"
        let view = GhosttySurfaceView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            workingDirectory: NSHomeDirectory(),
            command: attachCommand
        )
        // CRITICAL ORDER: cache the view in sharedSurface BEFORE adding it to
        // a window. addSubview synchronously triggers viewDidMoveToWindow →
        // createSurface → ghostty_surface_new, which can pump the main runloop
        // briefly while libghostty's renderer registers. Any re-entrant
        // cockpitSurface() call during that window must see the cached view
        // and short-circuit, otherwise it observes sharedSurface == nil and
        // spawns a second GhosttySurfaceView with the attach command — which
        // attaches a duplicate tmux client (visible via `tmux list-clients`).
        // This was the root cause of the duplicate-client bug observed during
        // PR #229 dogfood.
        sharedSurface = view
        // Park in offscreen window so libghostty's viewDidMoveToWindow
        // fires and the attach process starts in the background. SwiftUI
        // re-parents into the real container when a tab becomes visible.
        offscreenWindow.contentView?.addSubview(view)
        return view
    }

    /// Cached cockpit surface, or nil if it hasn't been created yet. Use this
    /// from call sites that want to act ONLY when the cockpit is already live
    /// (e.g. SwiftUI's updateNSView re-parent path) — unlike `cockpitSurface()`
    /// this never creates the surface as a side effect.
    public var existingCockpitSurface: GhosttySurfaceView? {
        sharedSurface
    }

    /// Whether `id` has a live tmux-window binding. Used by callers that
    /// want to gate a send/destroy/makeActive on "this terminal is actually
    /// wired up" without relying on the throwing dispatch path.
    public func isRegistered(id: UUID) -> Bool {
        bindings[id] != nil
    }

    // MARK: - Internal helpers

    private func ensureRunningServer() throws -> TmuxController {
        if let ctrl = controller, ctrl.hasSession() {
            return ctrl
        }
        guard !tmuxBinary.isEmpty, !socketPath.isEmpty else {
            // Backend wasn't configured this run (flag off, or tmux not
            // discovered). Throw rather than precondition-crash — callers
            // (notably TerminalSurfaceView's surfaceForBackend) catch and
            // fall back to per-terminal Ghostty rendering.
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
        return ctrl
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
        case .notConfigured:
            return "TmuxBackend.configure(...) was not called this run (no tmux ≥ 3.3 binary was found)"
        }
    }
}
