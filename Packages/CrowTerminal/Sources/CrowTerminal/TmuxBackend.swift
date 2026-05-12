import AppKit
import CrowCore
import Foundation

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
///     sleep at `TerminalManager.swift:113-126`).
///
/// Thread-safety: `@MainActor` — same constraint as `TerminalManager` and
/// libghostty (which requires AppKit-thread access for surface ops).
@MainActor
public final class TmuxBackend {
    public static let shared = TmuxBackend()

    /// Fired when a tmux-backed terminal's readiness state changes.
    /// Callers wire this through to the same readiness state machine the
    /// Ghostty path uses, so downstream consumers (e.g. `ClaudeLauncher`)
    /// don't have to special-case backends.
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

    /// UUID → per-terminal sentinel path. Cleared on destroy.
    private var sentinels: [UUID: String] = [:]

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

    /// Persistent socket path — Crow uses one explicit socket per app
    /// instance so it never collides with a user's own tmux.
    public private(set) var socketPath: String = ""

    public func configure(tmuxBinary: String, socketPath: String) {
        self.tmuxBinary = tmuxBinary
        self.socketPath = socketPath
    }

    // MARK: - Lifecycle

    /// Whether the cockpit session has been started this app launch.
    public var isRunning: Bool { controller?.hasSession() ?? false }

    /// Tear down the tmux server (used by the crash-watchdog in PROD #5,
    /// and by app quit). Resets internal state.
    public func shutdown() {
        if controller != nil {
            NSLog("[CrowTelemetry tmux:server_shutdown bindings=\(bindings.count)]")
        }
        controller?.killServer()
        sharedSurface?.destroy()
        sharedSurface = nil
        controller = nil
        bindings.removeAll()
        for path in sentinels.values {
            try? FileManager.default.removeItem(atPath: path)
        }
        sentinels.removeAll()
    }

    // MARK: - Per-terminal API (mirrors TerminalManager surface)

    /// Create a new tmux window for `id`. If the cockpit session doesn't
    /// exist yet, starts it. Returns the binding so callers can persist
    /// it on the `SessionTerminal` row.
    @discardableResult
    public func registerTerminal(
        id: UUID,
        name: String,
        cwd: String,
        command: String?,
        trackReadiness: Bool
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

        // Shell wrapper does the readiness markers + sources user's shell
        // config. Each tmux window's child process *is* the wrapper.
        guard let wrapperURL = BundledResources.shellWrapperScriptURL else {
            throw TmuxBackendError.bundledResourceMissing("crow-shell-wrapper.sh")
        }
        let wrapperPath = wrapperURL.path

        var env = ["CROW_SENTINEL": sentinelPath]
        if !cwd.isEmpty { env["PWD"] = cwd }

        let windowIndex = try ctrl.newWindow(
            name: name,
            cwd: cwd.isEmpty ? nil : cwd,
            env: env,
            command: wrapperPath
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
        let start = Date()
        do {
            try ensureRunningServer().selectWindow(index: windowIndex)
        } catch {
            reportIfTimeout(error)
            throw error
        }
        let elapsedMS = Int((Date().timeIntervalSince(start)) * 1000)
        // Operator-greppable: `[CrowTelemetry tmux:tab_switch_ms=…]`. Easy
        // to graph from logs today; trivially re-routed to a real metrics
        // pipeline once one exists.
        NSLog("[CrowTelemetry tmux:tab_switch_ms=\(elapsedMS) terminal=\(id)]")
    }

    /// Send text to `id`'s window via the buffer-paste path. Works for
    /// arbitrary-size payloads (Phase 3 §3 finding: send-keys -l fails
    /// on >10KB; load-buffer + paste-buffer scales to 50KB+ in 133ms).
    public func sendText(id: UUID, text: String) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let bufferName = "crow-\(id.uuidString)"
            try ctrl.loadBufferFromStdin(name: bufferName, data: Data(text.utf8))
            defer { ctrl.deleteBuffer(name: bufferName) }
            try ctrl.pasteBuffer(name: bufferName, target: "\(ctrl.sessionName):\(windowIndex)")
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
        if let sentinelPath = sentinels.removeValue(forKey: id) {
            try? FileManager.default.removeItem(atPath: sentinelPath)
        }
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
        let confPath = BundledResources.tmuxConfURL?.path
        if confPath == nil {
            throw TmuxBackendError.bundledResourceMissing("crow-tmux.conf")
        }
        // The "session anchor" is a no-op long-running command — kept alive
        // so the session persists even if every window is closed by the
        // user. /usr/bin/tail -f /dev/null is the conventional choice.
        try ctrl.newSessionDetached(
            configPath: confPath,
            command: "/usr/bin/tail -f /dev/null"
        )
        controller = ctrl
        return ctrl
    }

    private func sentinelPath(for id: UUID) -> String {
        let dir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp/"
        return (dir as NSString)
            .appendingPathComponent("crow-ready-\(id.uuidString).sentinel")
    }

    private func startReadinessWatch(id: UUID, sentinelPath: String) {
        startReadinessWatch(id: id, sentinelPath: sentinelPath, timeoutBudget: 30.0)
    }

    private func startReadinessWatch(id: UUID, sentinelPath: String, timeoutBudget: TimeInterval) {
        let waiter = SentinelWaiter()
        Task { [weak self] in
            // 30s default budget (was 5s). On app restart with many managed
            // terminals hydrating concurrently, shell startup is CPU-contended
            // and the wrapper's first precmd may not fire within 5s. Callers
            // can pass a longer budget for retries (see retryReadinessWatch).
            let elapsed = await waiter.waitForPrompt(
                sentinelPath: sentinelPath,
                timeout: timeoutBudget
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
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
                    self.onReadinessChanged?(id, .timedOut)
                }
            }
        }
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
            return "TmuxBackend.configure(...) was not called this run (CROW_TMUX_BACKEND off and no Settings → Experimental override)"
        }
    }
}
