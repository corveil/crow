import CrowCore
import Foundation

/// Cockpit session ensure / resurrect, bundled-conf reconcile (#450),
/// and user-driven `reloadBundledConfig` (#475 / CROW-874).
///
/// Extracted from `TmuxBackend` (CROW-1222). `configure` / `shutdown`
/// stay on the facade because they own the shared in-memory state.
/// `CockpitSessionStarter` stays faked by tests.

extension TmuxBackend {
    // MARK: - Internal helpers

    func ensureRunningServer() throws -> TmuxController {
        try ensureRunningServerReportingResurrection().ctrl
    }

    /// Like `ensureRunningServer()`, but also reports whether the cockpit
    /// session had to be created from scratch (`resurrected == true`) —
    /// i.e. the server was NOT running when the caller needed it. Callers
    /// that see a persisted binding fail against a resurrected server know
    /// the whole server died, not just one window (#588).
    func ensureRunningServerReportingResurrection()
        throws -> (ctrl: TmuxController, resurrected: Bool)
    {
        if let ctrl = controller {
            if ctrl.hasSession() { return (ctrl, false) }
            // We had a live cockpit this run and it's gone — the server died
            // mid-run (or is hung past the watchdog; recovery handles both
            // identically). Fire BEFORE resurrecting so the handler can
            // observe the dead state; it's reentrancy-guarded and hops to a
            // later main-actor turn, so recovery never races this call.
            CrowLog.info("[CrowTelemetry tmux:server_died_midrun bindings=\(bindings.count)]")
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
            CrowLog.info("[CrowTelemetry tmux:config_reconcile_skipped reason=fresh]")
            return
        }

        do {
            try controller.run(["source-file", confPath])
            CrowLog.info("[CrowTelemetry tmux:config_reconciled path=\(confPath)]")
        } catch {
            CrowLog.info("[CrowTelemetry tmux:config_reconcile_failed error=\"\(error)\"]")
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
    ///
    /// `async` and off the main actor: both `hasSession()` and `run()` block the
    /// calling thread, and the RPC handler invokes this from `MainActor.run`, so
    /// on the main actor they stall every other MainActor-bound RPC behind them
    /// (CROW-874). `TmuxController` is a `Sendable` struct of three strings, so
    /// it crosses cleanly — the same shape `startManagerExitMonitor` uses.
    ///
    /// This is one of ~24 `@MainActor` entry points on this type that call
    /// `TmuxController` synchronously; bounding `run()` itself is what fixes the
    /// class. Moving the rest needs `sendText`/`makeActive` and friends to stop
    /// being sync `throws` APIs, which touches every caller.
    public func reloadBundledConfig() async -> String? {
        guard let ctrl = controller else {
            return "tmux server is not running"
        }
        guard let confURL = BundledResources.tmuxConfURL else {
            return "bundled crow-tmux.conf not found"
        }
        return await Task.detached {
            guard ctrl.hasSession() else {
                return "tmux server is not running"
            }
            do {
                try ctrl.run(["source-file", confURL.path])
                CrowLog.info("[CrowTelemetry tmux:config_reloaded_by_user path=\(confURL.path)]")
                return nil
            } catch {
                CrowLog.info("[CrowTelemetry tmux:config_reload_failed error=\"\(error)\"]")
                return "\(error)"
            }
        }.value
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
    /// **The adopt branch below is load-bearing — do not delete it.** Its
    /// original justification was in-process: `TmuxController.run` blocked on
    /// `Process.waitUntilExit()`, which pumps the main run loop, so a
    /// `new-session` could be re-entered by another `ensureRunningServer()`
    /// caller before `controller` was cached. That mechanism is gone — since
    /// #653 the wait is a semaphore that does not pump — but the race is not.
    ///
    /// It is now a **cross-process** TOCTOU, which no in-process argument can
    /// close: `TerminalCockpit.ensureSession` in `crowd` performs the identical
    /// `hasSession()` → `newSessionDetached` against the *same* socket
    /// (`appTmuxSocketPath()`, #330), and runs it on every daemon startup.
    /// Whoever wins creates `crow-cockpit`; the rest must ADOPT it, not
    /// re-create it — `new-session` errors with "duplicate session", and
    /// because that throws, the loser never cached `controller`, so every
    /// subsequent call kept failing and every terminal rendered blank (#326).
    ///
    /// `nonisolated static` so the adopt branch is testable without a real
    /// tmux server or the main actor — it touches no instance/actor state, and
    /// nothing pins it to the main actor.
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
}
