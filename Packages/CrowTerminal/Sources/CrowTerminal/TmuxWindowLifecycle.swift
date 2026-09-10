import CrowCore
import Foundation

/// Window register / adopt / destroy / kill / list, plus `makeActive`.
///
/// Extracted from `TmuxBackend` (CROW-1222). Public methods stay on
/// `TmuxBackend` via this extension so callers keep `TmuxBackend.shared.*`
/// and shared state stays on the facade — no second singleton.

extension TmuxBackend {
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
    ///
    /// `usesAlternateScreen` is the per-agent capability (CROW-1008 / CROW-1010).
    /// `true` (Claude Code) relies on the alt buffer to kill sediment. `false`
    /// (Cursor, and any inline renderer) still gets `alternate-screen on` so
    /// `list-terminals` classifies the window as an agent surface, but keeps
    /// the unified 50k history — its transcript is legitimate native scrollback
    /// and the wheel at a non-mouse-tracking prompt scrolls it (#850). The
    /// CROW-1008 `history-limit 0` clamp is retracted: it deleted Cursor's only
    /// scroll path. The flag is forwarded to the client as
    /// `uses_alternate_screen` so `applySurfaceScrollback` caps xterm only for
    /// true alt-buffer agents.
    @discardableResult
    public func registerTerminal(
        id: UUID,
        name: String,
        cwd: String,
        command: String?,
        trackReadiness: Bool,
        agentKind: AgentKind? = nil,
        agentSurface: Bool = false,
        usesAlternateScreen _: Bool = true,
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

        // CROW-1010: do not clamp `history-limit` for inline agents. Cursor's
        // history is a clean transcript and the local-viewport wheel (#850) is
        // its only scroll path; `history-limit 0` made that wheel a no-op.
        // Alt-buffer agents (Claude Code) don't need a clamp either — the alt
        // buffer has no history. `usesAlternateScreen` is still accepted so
        // callers keep passing the capability; list-terminals reads it from
        // AgentRegistry and forwards `uses_alternate_screen` to the client.

        let windowIndex = try ctrl.newWindow(
            name: name,
            cwd: cwd.isEmpty ? nil : cwd,
            env: env,
            command: wrapperPath,
            timeout: newWindowTimeout
        )
        bindings[id] = windowIndex
        // CROW-1023: a freshly created window has not entered the alt buffer
        // yet, so forget any observation a prior tenant of this index left
        // behind (tmux reuses freed indices). Detection re-latches on the next
        // `list-windows` read once this window actually enters the alt screen.
        observedAltBufferWindows.remove(windowIndex)

        // Hand agent-TUI windows their own viewport BEFORE the launch command
        // below is pasted, so an agent that *does* request smcup enters the alt
        // buffer on its very first repaint and never deposits a frame into the
        // shared history (#822). For inline renderers the option is inert but
        // still the source of truth for `agent_surface` on list-terminals.
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
    /// leave tmux focused on the wrong window until the next `makeActive`
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
        CrowLog.info("[CrowTelemetry tmux:tab_switch_ms=\(elapsedMS) terminal=\(id)]")
    }

    /// Destroy the tmux window backing `id` and forget the binding.
    public func destroyTerminal(id: UUID) {
        if let windowIndex = bindings[id] {
            controller?.killWindow(index: windowIndex)
            // CROW-1023: drop the alt-buffer latch on this path too — close-tab
            // goes straight to `controller?.killWindow`, not `killWindow(index:)`,
            // so the ADR's "cleared at kill" would otherwise not hold here. Prune
            // + the register-time remove already cover a recycled index; this
            // keeps every teardown path consistent (review).
            observedAltBufferWindows.remove(windowIndex)
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

    /// Live cockpit windows as (index, pinned name, foreground command). `[]` if
    /// tmux is unavailable or the read fails.
    public func listCockpitWindows() -> [(index: Int, name: String, command: String)] {
        guard let ctrl = controller else { return [] }
        do { return try ctrl.listWindows() }
        catch { reportIfTimeout(error); return [] }
    }

    /// Kill the cockpit window at `index`. Passthrough to the controller so
    /// callers outside `TmuxBackend` (e.g. the CROW-804 terminal recreate in
    /// `SessionService`) can drop a degraded window before re-registering a
    /// fresh one. No-op when tmux is unavailable.
    public func killWindow(index: Int) {
        controller?.killWindow(index: index)
        // CROW-1023: drop the alt-buffer latch for a killed index up front, so a
        // recreate that reuses it starts inline until it re-enters the alt screen.
        observedAltBufferWindows.remove(index)
    }
}
