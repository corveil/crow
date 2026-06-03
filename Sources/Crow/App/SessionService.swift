import AppKit
import Foundation
import CrowClaude
import CrowCore
import CrowGit
import CrowPersistence
import CrowProvider
import CrowTerminal

/// Simplified session service — CRUD only. Orchestration moved to Claude Code via crow CLI.
@MainActor
final class SessionService {
    private let store: JSONStore
    private let appState: AppState
    let telemetryPort: UInt16?
    /// Backend factory for ticket/PR lookups during recovery. Optional so unit-tests
    /// that don't exercise recovery paths needn't construct one. See ADR 0005.
    private let providerManager: ProviderManager?

    init(store: JSONStore, appState: AppState, telemetryPort: UInt16? = nil, providerManager: ProviderManager? = nil) {
        self.store = store
        self.appState = appState
        self.telemetryPort = telemetryPort
        self.providerManager = providerManager
    }

    /// Upgrade the well-known primary Manager session from `.work` (how it was
    /// persisted before `SessionKind.manager` existed) to `.manager`. Returns
    /// `true` when a migration was applied. Pure/`nonisolated` so it can run on
    /// both the in-memory `appState.sessions` and the persisted `store` copy,
    /// and be unit-tested without a live app.
    nonisolated static func migrateLegacyManagerKind(_ sessions: inout [Session]) -> Bool {
        guard let idx = sessions.firstIndex(where: {
            $0.id == AppState.managerSessionID && $0.kind != .manager
        }) else { return false }
        sessions[idx].kind = .manager
        return true
    }

    // MARK: - Hydrate State from Store

    func hydrateState() {
        let data = store.data
        appState.sessions = data.sessions

        // Migrate a legacy primary Manager (persisted as `.work` before
        // SessionKind.manager existed) to `.manager` BEFORE the per-session loop.
        // Otherwise the `!session.isManager` hydration branch clears its claude
        // command and reroutes it through the work-session auto-launch path,
        // silently dropping the Manager's --auto-permission-mode args (#316).
        // Persist so the upgrade is one-shot.
        if Self.migrateLegacyManagerKind(&appState.sessions) {
            store.mutate { data in
                _ = Self.migrateLegacyManagerKind(&data.sessions)
            }
        }

        // Backfill provider from ticketURL for sessions that predate provider tracking
        for i in appState.sessions.indices {
            if appState.sessions[i].provider == nil, let url = appState.sessions[i].ticketURL {
                appState.sessions[i].provider = Validation.detectProviderFromURL(url)
            }
        }

        // Restore persisted hook state so sidebar status colors reflect the true
        // state immediately on relaunch — before any live hook event arrives.
        // Since #330 the adopt path no longer re-runs `claude --continue`, so no
        // SessionStart fires to repopulate this; without restore the colors sit
        // on a stale default until the user next interacts with Claude (#367).
        // Restore only for sessions that still exist so stale entries for
        // deleted sessions are never resurrected.
        if let persisted = data.hookStates {
            let liveIDs = Set(appState.sessions.map(\.id))
            for (key, snapshot) in persisted {
                guard let sid = UUID(uuidString: key), liveIDs.contains(sid) else { continue }
                appState.restoreHookState(snapshot, for: sid)
            }
        }

        for session in appState.sessions {
            appState.worktrees[session.id] = data.worktrees.filter { $0.sessionID == session.id }
            appState.links[session.id] = data.links.filter { $0.sessionID == session.id }

            var terminals = data.terminals.filter { $0.sessionID == session.id }
            if !session.isManager {
                // Backward-compat migration: if no terminal is marked managed,
                // heuristically mark the first "Claude Code" terminal.
                let hasManagedTerminal = terminals.contains { $0.isManaged }
                if !hasManagedTerminal, let idx = terminals.firstIndex(where: {
                    $0.name == "Claude Code" || ($0.command?.contains("claude") ?? false)
                }) {
                    // Mutate in place so tmuxBinding (and every other field) is
                    // preserved — reconstructing via the memberwise init defaults
                    // tmuxBinding to nil and breaks adopt-on-relaunch (#374).
                    terminals[idx].isManaged = true
                }

                // For managed terminals, clear the claude command so they start as plain shells.
                // We'll send `claude --continue` after the surfaces are created.
                for i in terminals.indices {
                    if terminals[i].isManaged,
                       let cmd = terminals[i].command, cmd.contains("claude") {
                        // In-place so tmuxBinding survives the rebuild (#374).
                        terminals[i].command = nil
                    }
                }
            } else {
                // Manager terminal: rebuild its claude command to match the
                // current remoteControlEnabled and managerAutoPermissionMode
                // preferences, using this session's own name for the --name
                // label. Unlike worker sessions the Manager launches claude
                // directly as the shell command, so the stored string needs to
                // be correct before preInitialize runs. Built via the shared
                // `managerCommand` helper so the name flow has one source.
                let rebuiltCommand = managerCommand(sessionName: session.name)
                for i in terminals.indices {
                    if let cmd = terminals[i].command, cmd.contains("claude") {
                        // Mutate in place rather than reconstructing the row:
                        // the memberwise init drops tmuxBinding, which made the
                        // Manager spawn a fresh window + claude every relaunch
                        // instead of re-attaching to its live window (#374).
                        terminals[i].command = rebuiltCommand
                        if appState.remoteControlEnabled {
                            appState.remoteControlActiveTerminals.insert(terminals[i].id)
                        }
                    }
                }
            }
            appState.terminals[session.id] = terminals

            // Pre-create terminalReadiness slots for managed work session
            // terminals so the readiness callbacks (Ghostty's surfaceCreated
            // and tmux's onReadinessChanged) have something to update. The
            // actual trackReadiness/registerTerminal call happens in
            // rehydrateTerminalSurface below.
            if !session.isManager {
                for terminal in terminals where terminal.isManaged {
                    appState.terminalReadiness[terminal.id] = .uninitialized
                    appState.autoLaunchTerminals.insert(terminal.id)
                }
            }
        }

        // Purge any persisted standalone-terminal rows left over from the
        // removed global-terminals feature — multiple Manager sessions replaced
        // it. These are never re-hydrated or rendered, so drop them from disk
        // so they don't accumulate across launches.
        if data.terminals.contains(where: { $0.sessionID == AppState.globalTerminalSessionID }) {
            store.mutate { data in
                data.terminals.removeAll { $0.sessionID == AppState.globalTerminalSessionID }
            }
        }

        // Wire the readiness callback and re-hydrate every persisted terminal.
        // Since #330 the tmux server outlives the app, so on launch
        // rehydrateTerminalSurface adopts the persisted window when it's still
        // live and only re-registers a fresh one as a fallback (post-reboot,
        // closed window, or a legacy socket). `forceRegister: false` keeps that
        // adopt-first behavior; the manual "Restart tmux Server" path passes
        // true. If both adopt and register fail (e.g. tmux uninstalled) the row
        // is left as-is and simply won't render this launch.
        rebuildAllSurfaces(forceRegister: false)
    }

    /// Wire the tmux readiness callback, then re-register a tmux window and
    /// relaunch claude for every persisted terminal across all sessions. Shared
    /// by `hydrateState` (launch) and `restartTmuxServer` (manual recycle).
    ///
    /// `forceRegister: true` drops each terminal's persisted `tmuxBinding` so
    /// `rehydrateTerminalSurface` always takes the `registerTerminal` path —
    /// used after the server was killed, when every binding is dead — and
    /// re-arms the managed work terminals' readiness/auto-launch state so the
    /// fresh shell's `.shellReady` fire drives `launchClaude`. On launch the
    /// pre-seed already happened in `hydrateState`, so `forceRegister: false`
    /// skips it and preserves the adopt-first behavior.
    ///
    /// Each per-terminal rehydration is dispatched as its own @MainActor task
    /// so the run loop can service AppKit/SwiftUI between them. Running the loop
    /// synchronously pinned the main actor for seconds on profiles with many
    /// persisted rows (each `registerTerminal` spawns a subprocess) — #293.
    @MainActor
    func rebuildAllSurfaces(forceRegister: Bool = false) {
        // Wire BEFORE re-registering so the sentinel's .shellReady is never lost.
        wireTerminalReadiness()

        for session in appState.sessions {
            guard let terminals = appState.terminals[session.id] else { continue }
            let isManagerSession = session.isManager
            let sid = session.id

            if forceRegister, !isManagerSession {
                // The previous adopt (#367) / launchClaude cleared these; re-arm
                // so the fresh shell's .shellReady relaunches claude --continue.
                for terminal in terminals where terminal.isManaged {
                    appState.terminalReadiness[terminal.id] = .uninitialized
                    appState.autoLaunchTerminals.insert(terminal.id)
                }
            }

            for original in terminals {
                let trackReadiness = !isManagerSession && original.isManaged
                // Server was just killed → binding is dead. Drop it so
                // rehydrateTerminalSurface skips adopt and registers a fresh
                // window (and persists the new windowIndex).
                var seed = original
                if forceRegister { seed.tmuxBinding = nil }
                Task { @MainActor in
                    let updated = self.rehydrateTerminalSurface(seed, trackReadiness: trackReadiness)
                    self.applyRehydrationResult(sessionID: sid, original: seed, updated: updated)
                }
            }
        }
    }

    /// Commit the result of a per-terminal rehydration task back to
    /// `appState.terminals`, locating the row by ID since the array may
    /// have shifted while the task awaited. If the `tmuxBinding` changed
    /// (re-registration bound a new window index), persist the updated row.
    @MainActor
    private func applyRehydrationResult(sessionID: UUID, original: SessionTerminal, updated: SessionTerminal) {
        if var terminals = appState.terminals[sessionID],
           let idx = terminals.firstIndex(where: { $0.id == updated.id }) {
            terminals[idx] = updated
            appState.terminals[sessionID] = terminals
        }
        if updated.tmuxBinding != original.tmuxBinding {
            store.mutate { data in
                if let i = data.terminals.firstIndex(where: { $0.id == updated.id }) {
                    data.terminals[i] = updated
                }
            }
        }
    }

    /// Re-hydrate one persisted terminal's tmux window on app launch. Returns
    /// the (possibly-modified) row with `tmuxBinding.windowIndex` updated to
    /// the freshly-registered window. If tmux is unavailable or registration
    /// fails, the row is returned unchanged and simply won't render this run.
    @MainActor
    private func rehydrateTerminalSurface(_ terminal: SessionTerminal, trackReadiness: Bool) -> SessionTerminal {
        guard !TmuxBackend.shared.tmuxBinary.isEmpty else {
            NSLog("[SessionService] tmux not configured this run — terminal \(terminal.id) will not render")
            return terminal
        }

        // #330: the tmux server now outlives the app, so on relaunch the
        // window from last time is (usually) still live with its Claude TUI
        // running. Re-attach to it rather than spawning a fresh window.
        if let binding = terminal.tmuxBinding {
            do {
                // trackReadiness:false so adoptTerminal does NOT re-fire the
                // sentinel's `.shellReady` — otherwise wireTerminalReadiness
                // would drive launchClaude and paste a *second* `claude
                // --continue` into a pane where Claude is already running.
                try TmuxBackend.shared.adoptTerminal(id: terminal.id, binding: binding, trackReadiness: false)
                // The window survived the prior quit → Claude is already up.
                // Belt-and-suspenders against any other readiness path: drop
                // the terminal from autoLaunchTerminals (also stops the
                // didBecomeActive re-arm) and mark readiness terminal so
                // launchClaude's `== .shellReady` guard can never fire.
                appState.autoLaunchTerminals.remove(terminal.id)
                // Defensive: a brand-new terminal's deferred launch must not
                // survive into an adopt (#408). In-memory only, so normally
                // empty at launch — clear anyway to be safe.
                appState.pendingLaunchCommands.removeValue(forKey: terminal.id)
                if appState.terminalReadiness[terminal.id] != nil {
                    appState.terminalReadiness[terminal.id] = .agentLaunched
                }
                // Adoption skips launchClaude, so re-apply its two UI-affecting
                // side effects here (#367). Gate on trackReadiness — true only for
                // managed work terminals, exactly the set launchClaude handles —
                // so the Manager (whose RC is seeded in hydrateState) is untouched.
                if trackReadiness {
                    // Re-write hook config so the adopted Claude's hooks still
                    // route back to the correct session if the config was lost.
                    if let crowPath = ClaudeHookConfigWriter.findCrowBinary(),
                       let worktree = appState.primaryWorktree(for: terminal.sessionID) {
                        do {
                            try ClaudeHookConfigWriter().writeHookConfig(
                                worktreePath: worktree.worktreePath,
                                sessionID: terminal.sessionID,
                                crowPath: crowPath
                            )
                        } catch {
                            NSLog("[SessionService] adopt: hook config rewrite failed for \(terminal.sessionID): \(error.localizedDescription)")
                        }
                    }
                    // Re-seed the RemoteControl badge for adopted --rc terminals.
                    if appState.remoteControlEnabled {
                        appState.remoteControlActiveTerminals.insert(terminal.id)
                    }
                    // Emulate the SessionStart(source: resume) hook that pre-#330
                    // relaunch fired (via re-running `claude --continue`), which set
                    // activityState to .done — so an adopted, idle-at-the-prompt Claude
                    // shows the "done" green card like it used to (#367). A persisted
                    // in-progress state (working/waiting) was already restored in
                    // hydrateState and is more specific, so only fill in .done when
                    // nothing meaningful was restored (still the .idle default).
                    let hookState = appState.hookState(for: terminal.sessionID)
                    if hookState.activityState == .idle {
                        hookState.activityState = .done
                    }
                }
                return terminal  // binding unchanged → no redundant persist
            } catch {
                NSLog("[SessionService] tmux adopt failed (\(error)) for \(terminal.id); creating a fresh window")
            }
        }

        // No prior binding, or adoption failed (post-reboot clean slate, the
        // window was closed, or a legacy per-PID socketPath that no longer
        // matches the stable socket). Create a fresh window as before.
        do {
            let binding = try TmuxBackend.shared.registerTerminal(
                id: terminal.id,
                name: terminal.name,
                cwd: terminal.cwd,
                command: terminal.command,
                trackReadiness: trackReadiness
            )
            var updated = terminal
            updated.tmuxBinding = binding
            return updated
        } catch {
            NSLog("[SessionService] tmux re-register failed on hydrate (\(error)) for \(terminal.id); terminal will not render this run")
            return terminal
        }
    }

    /// Bridge tmux readiness callbacks to `AppState.terminalReadiness`.
    ///
    /// tmux-backed terminals report readiness via SentinelWaiter. We funnel
    /// that into the `TerminalReadiness` state machine so downstream consumers
    /// (launchClaude) work without backend-specific branches. The tmux backend
    /// skips the `.surfaceCreated` intermediate state — its window is created
    /// synchronously by registerTerminal — so we go straight to `.shellReady`.
    func wireTerminalReadiness() {
        NSLog("[SessionService] wireTerminalReadiness — setting tmux readiness callback")
        TmuxBackend.shared.onReadinessChanged = { [weak self] terminalID, readiness in
            guard let self else { return }
            guard let currentState = self.appState.terminalReadiness[terminalID] else { return }
            NSLog("[SessionService] tmux readiness: terminal=\(terminalID), state=\(readiness), current=\(currentState)")
            if readiness == .shellReady, currentState < .shellReady {
                self.appState.terminalReadiness[terminalID] = .shellReady
                // Brand-new managed terminals created via `new-terminal --command`
                // hold their launch in `pendingLaunchCommands` and paste it HERE,
                // now that the shell's line editor is live — the race-free
                // replacement for setup.sh's old `sleep 3` + `crow send` (#408).
                // Restored/recovered terminals have no pending command and fall
                // through to `launchAgent` (rebuild via autoLaunchCommand).
                switch SessionService.resolveLaunch(pending: self.appState.pendingLaunchCommands[terminalID]) {
                case .pastePending(let command):
                    self.pasteDeferredLaunch(terminalID: terminalID, command: command)
                case .launchAgent:
                    self.launchAgent(terminalID: terminalID)
                }
            } else if readiness == .timedOut, currentState < .shellReady {
                // First-prompt watch expired. Do NOT advance to .shellReady or
                // auto-paste — the shell may still be starting and a paste now
                // can land in a pane without a live line editor. The UI shows
                // a Retry affordance; `didBecomeActive` also re-arms us
                // automatically when the app returns to the foreground.
                self.appState.terminalReadiness[terminalID] = .timedOut
            }
        }
    }

    /// What the `.shellReady` handler should do for a managed terminal. Pure
    /// so the brand-new-vs-restored branch is unit-testable without tmux or a
    /// live AppState (#408).
    enum LaunchAction: Equatable {
        /// Brand-new terminal launched via `new-terminal --command`: paste the
        /// stored command now that the shell is ready.
        case pastePending(String)
        /// Restored/recovered terminal: rebuild the command via the agent's
        /// `autoLaunchCommand` (the existing `launchAgent` path).
        case launchAgent
    }

    nonisolated static func resolveLaunch(pending: String?) -> LaunchAction {
        if let pending, !pending.isEmpty { return .pastePending(pending) }
        return .launchAgent
    }

    /// Paste the deferred agent-launch command for a brand-new managed terminal
    /// now that its shell's line editor is live (#408). Consumes BOTH the
    /// pending command and the `autoLaunchTerminals` membership so `launchAgent`
    /// can never also fire (e.g. a later spurious `.shellReady` after adopt),
    /// preventing a double launch.
    func pasteDeferredLaunch(terminalID: UUID, command: String) {
        guard appState.pendingLaunchCommands.removeValue(forKey: terminalID) != nil else { return }
        appState.autoLaunchTerminals.remove(terminalID)

        guard let sessionID = appState.terminals.first(where: { _, terminals in
            terminals.contains(where: { $0.id == terminalID })
        })?.key,
              let routedTerminal = appState.terminals[sessionID]?.first(where: { $0.id == terminalID }) else {
            NSLog("[SessionService] pasteDeferredLaunch: no terminal record for \(terminalID); cannot send")
            return
        }

        // Apply the same prep the legacy `crow send` path got from the `send`
        // RPC (hook config + OTEL env vars) so hooks route back to this session
        // and Claude telemetry is exported — via the shared helper so the two
        // launch paths never drift.
        var text = command
        if let session = appState.sessions.first(where: { $0.id == sessionID }),
           let agent = AgentRegistry.shared.agent(for: session.agentKind) {
            text = AppDelegate.prepareAgentLaunchText(
                command: command,
                agent: agent,
                sessionID: sessionID,
                worktreePath: appState.primaryWorktree(for: sessionID)?.worktreePath,
                crowPath: ClaudeHookConfigWriter.findCrowBinary(),
                telemetryPort: telemetryPort
            ).text
        }
        // Ensure a trailing newline so TmuxBackend.sendText delivers Enter.
        TerminalRouter.send(routedTerminal, text: text.hasSuffix("\n") ? text : text + "\n")
        appState.terminalReadiness[terminalID] = .agentLaunched
    }

    /// Re-arm the tmux readiness watch for a terminal whose first attempt
    /// timed out. Reverts AppState back to `.surfaceCreated` so the UI
    /// transitions out of the Retry overlay, and starts a longer-budget
    /// watch on the backend. Leaves the terminal in `autoLaunchTerminals`
    /// so a successful sentinel fire still triggers `launchAgent`.
    func retryReadiness(terminalID: UUID) {
        guard let current = appState.terminalReadiness[terminalID] else { return }
        guard current == .timedOut || current < .shellReady else { return }
        appState.terminalReadiness[terminalID] = .surfaceCreated
        TmuxBackend.shared.retryReadinessWatch(id: terminalID)
    }

    /// Capture a stage-by-stage diagnostic bundle for `terminalID` (wrapper
    /// log, pane capture, ps tree, sentinel state) and copy it to the
    /// clipboard so a teammate hitting the .timedOut state can paste it
    /// into a comment without screenshot-archaeology (issue #256).
    func copyDiagnostics(terminalID: UUID) {
        let bundle = TmuxBackend.shared.captureDiagnostics(id: terminalID)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bundle, forType: .string)
        NSLog("[SessionService] copied tmux diagnostics for terminal=\(terminalID) bytes=\(bundle.utf8.count)")
    }

    /// Reap leaked orphan cockpit windows once at launch — bare-shell windows
    /// that no persisted terminal references (#408). The keep-set is built from
    /// the persisted terminals' window bindings; `reapUnboundCockpitWindows`
    /// additionally unions the in-memory bindings, so a window adopted or freshly
    /// registered this run is never reaped. Call AFTER the async per-terminal
    /// rehydration has settled. Safe: never reaps a window running an agent.
    @MainActor
    func reapOrphanedCockpitWindows() {
        let keep = Set(appState.terminals.values.flatMap { $0 }.compactMap { $0.tmuxBinding?.windowIndex })
        let n = TmuxBackend.shared.reapUnboundCockpitWindows(keepWindowIndices: keep)
        if n > 0 { NSLog("[SessionService] reaped \(n) orphaned cockpit window(s) at launch (#408)") }
    }

    /// Re-arm any tmux readiness watches that have stalled while the app
    /// was backgrounded. Called from `NSApplication.didBecomeActiveNotification`
    /// so a user who returns to a long-idle app doesn't have to click
    /// Retry on every review session.
    func reArmStuckReadinessWatches() {
        for (terminalID, state) in appState.terminalReadiness {
            guard appState.autoLaunchTerminals.contains(terminalID) else { continue }
            guard state == .timedOut else { continue }
            NSLog("[SessionService] re-arming stuck tmux readiness watch for terminal=\(terminalID)")
            retryReadiness(terminalID: terminalID)
        }
    }

    /// Auto-launch the session's coding agent in `terminalID`. Dispatches via
    /// the registered `CodingAgent` for the session's `agentKind`, which
    /// builds both the hook configuration and the launch command.
    func launchAgent(terminalID: UUID) {
        guard appState.terminalReadiness[terminalID] == .shellReady else { return }
        // Only auto-launch for restored/recovered terminals, not brand-new ones
        guard appState.autoLaunchTerminals.remove(terminalID) != nil else { return }

        // Find the session this terminal belongs to
        guard let sessionID = appState.terminals.first(where: { _, terminals in
            terminals.contains(where: { $0.id == terminalID })
        })?.key,
              let session = appState.sessions.first(where: { $0.id == sessionID }),
              let worktree = appState.primaryWorktree(for: sessionID),
              let agent = AgentRegistry.shared.agent(for: session.agentKind) else { return }

        // Write/refresh hook config (Claude path). Codex's writer is a
        // no-op — its global config was installed once at app launch.
        if let crowPath = ClaudeHookConfigWriter.findCrowBinary() {
            do {
                try agent.hookConfigWriter.writeHookConfig(
                    worktreePath: worktree.worktreePath,
                    sessionID: sessionID,
                    crowPath: crowPath
                )
            } catch {
                NSLog("[SessionService] Failed to write hook config for session %@: %@",
                      sessionID.uuidString, error.localizedDescription)
            }
        }

        let rcEnabled = appState.remoteControlEnabled
        // Jobs are unattended, so opt-in (default-on) auto-permission mode lets
        // their prompts run crow/gh/git without per-call approval. Scoped to
        // .job kind so review and other session kinds are unaffected.
        let autoPermissionMode = (session.kind == .job) && appState.jobsAutoPermissionMode
        // The agent's autoLaunchCommand mirrors this condition — the initial
        // prompt file is only used on first launch (CROW-224, CROW-317).
        // Compute it here so we know whether to flip `reviewPromptDispatched`
        // (reused as the generic "initial prompt dispatched" gate) after the
        // command goes out.
        let reviewPromptJustDispatched = (session.kind == .review || session.kind == .job)
            && !session.reviewPromptDispatched
        guard let command = agent.autoLaunchCommand(
            session: session,
            worktreePath: worktree.worktreePath,
            remoteControlEnabled: rcEnabled,
            autoPermissionMode: autoPermissionMode,
            telemetryPort: telemetryPort
        ) else {
            NSLog("[SessionService] Agent %@ could not build a launch command for session %@",
                  agent.kind.rawValue, sessionID.uuidString)
            return
        }
        // Route through TerminalRouter so tmux-backed terminals get the text
        // via tmux send-keys.
        if let routedTerminal = appState.terminals[sessionID]?.first(where: { $0.id == terminalID }) {
            TerminalRouter.send(routedTerminal, text: command)
        } else {
            NSLog("[SessionService] launchAgent: no terminal record for \(terminalID); cannot send")
        }

        appState.terminalReadiness[terminalID] = .agentLaunched
        if rcEnabled && agent.supportsRemoteControl {
            appState.remoteControlActiveTerminals.insert(terminalID)
        }

        if reviewPromptJustDispatched {
            if let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) {
                appState.sessions[idx].reviewPromptDispatched = true
            }
            store.mutate { data in
                if let idx = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                    data.sessions[idx].reviewPromptDispatched = true
                }
            }
        }
    }

    // MARK: - Ensure Manager Session

    func ensureManagerSession(devRoot: String) {
        let managerID = AppState.managerSessionID
        if appState.sessions.contains(where: { $0.id == managerID }) {
            // Defense-in-depth: `hydrateState` already migrates a legacy `.work`
            // primary Manager before this runs, but migrate here too in case the
            // session was created/mutated via another path.
            if Self.migrateLegacyManagerKind(&appState.sessions) {
                store.mutate { data in
                    _ = Self.migrateLegacyManagerKind(&data.sessions)
                }
            }
        } else {
            // Manager is pinned to Claude Code per the agent-abstraction
            // spec — never honors AppConfig.defaultAgentKind.
            let manager = Session(
                id: managerID,
                name: "Manager",
                status: .active,
                kind: .manager,
                agentKind: .claudeCode
            )
            appState.sessions.insert(manager, at: 0)

            store.mutate { data in
                if !data.sessions.contains(where: { $0.id == managerID }) {
                    data.sessions.insert(manager, at: 0)
                }
            }
        }

        // Ensure manager has a terminal
        if appState.terminals(for: managerID).isEmpty {
            createManagerTerminal(sessionID: managerID, sessionName: "Manager", cwd: devRoot)
        }

        // Select Manager on launch (selectedSessionID isn't persisted)
        if appState.selectedSessionID == nil {
            appState.selectedSessionID = managerID
        }
    }

    /// Relaunch the Manager's `claude` process in place after it has exited
    /// (crash, kill, OOM). The Manager session row and `AppState.managerSessionID`
    /// are preserved — only the dead terminal/surface is torn down and replaced.
    ///
    /// Tears down the existing Ghostty surface, drops the stale terminal row from
    /// both memory and disk, clears the exited flag, then re-runs
    /// `ensureManagerSession` which recreates a fresh Manager terminal (new
    /// terminal UUID) using the current remote-control / auto-permission args.
    func restartManager(devRoot: String) {
        let managerID = AppState.managerSessionID
        let terminals = appState.terminals(for: managerID)
        // Fall back to a dead terminal's cwd if the caller's devRoot is empty.
        let resolvedDevRoot = devRoot.isEmpty ? (terminals.first?.cwd ?? devRoot) : devRoot

        for terminal in terminals {
            TerminalRouter.destroy(terminal)
        }
        appState.terminals.removeValue(forKey: managerID)
        appState.remoteControlActiveTerminals.subtract(terminals.map(\.id))
        store.mutate { data in
            data.terminals.removeAll { $0.sessionID == managerID }
        }

        appState.managerProcessExited = false
        NSLog("[CrowTelemetry manager:restart]")

        // Session row still exists, so this only recreates the terminal.
        ensureManagerSession(devRoot: resolvedDevRoot)
    }

    /// Tear down the tmux server and rebuild every terminal surface from
    /// scratch. Manual recovery for a wedged/leaked cockpit session (#375):
    /// kills the server — every pane's claude included — then re-registers a
    /// fresh window and relaunches claude for every persisted terminal across
    /// all sessions (Manager via its stored command, work sessions via
    /// `claude --continue`). The destructive teardown is guarded by a
    /// confirmation alert in `AppDelegate.restartTmuxServer`.
    @MainActor
    func restartTmuxServer() {
        NSLog("[CrowTelemetry tmux:server_restart_by_user]")
        let savedSelection = appState.selectedSessionID
        let savedActive = appState.activeTerminalID

        // kill-server + unlink scratch/sentinel files. The first registerTerminal
        // in rebuildAllSurfaces lazily recreates the controller + cockpit session
        // via ensureRunningServer, so no explicit reconfigure is needed.
        TmuxBackend.shared.shutdown(killServer: true)

        rebuildAllSurfaces(forceRegister: true)

        // Re-assign selection (even to the same values) to force a SwiftUI
        // re-render so TerminalSurfaceView re-creates the destroyed cockpit
        // surface and re-attaches a fresh tmux client; preserves focus.
        appState.selectedSessionID = savedSelection
        appState.activeTerminalID = savedActive
    }

    /// Build the claude shell command for a Manager terminal, reflecting the
    /// current remote-control and auto-permission-mode preferences. Managers
    /// launch claude directly as the terminal's shell command. Used by both
    /// fresh-terminal creation and the hydrate rebuild so the per-session
    /// `--name` label has a single source. `internal` for unit testing.
    func managerCommand(sessionName: String) -> String {
        // Find the real claude binary (skip CMUX wrapper)
        let claudePath = Self.findClaudeBinary() ?? "claude"
        return claudePath + ClaudeLaunchArgs.argsSuffix(
            remoteControl: appState.remoteControlEnabled,
            sessionName: sessionName,
            autoPermissionMode: appState.managerAutoPermissionMode
        )
    }

    /// Create the single Claude-Code terminal for a Manager session and persist
    /// it. Routes through the same backend-selection path as work sessions
    /// (#314): on tmux this registers a window and pastes the `claude` command
    /// into it; on Ghostty it pre-initializes the offscreen surface.
    /// `trackReadiness: false` matches the Manager's command-launches-claude
    /// model — no readiness/launchClaude flow.
    @discardableResult
    private func createManagerTerminal(sessionID: UUID, sessionName: String, cwd: String) -> SessionTerminal {
        let command = managerCommand(sessionName: sessionName)
        let rawTerminal = SessionTerminal(
            sessionID: sessionID,
            name: sessionName,
            cwd: cwd,
            command: command
        )

        let terminal = prepareTerminal(rawTerminal, trackReadiness: false)
        appState.terminals[sessionID] = [terminal]

        store.mutate { data in
            if !data.terminals.contains(where: { $0.sessionID == sessionID }) {
                data.terminals.append(terminal)
            }
        }

        if appState.remoteControlEnabled {
            appState.remoteControlActiveTerminals.insert(terminal.id)
        }
        return terminal
    }

    /// Create an additional (non-primary) Manager session in `cwd`. Returns the
    /// new session's id. The terminal is set up by `createManagerTerminal`.
    @discardableResult
    func createManagerSession(name: String, cwd: String) -> UUID {
        let session = Session(name: name, status: .active, kind: .manager)
        appState.sessions.append(session)
        store.mutate { $0.sessions.append(session) }
        createManagerTerminal(sessionID: session.id, sessionName: name, cwd: cwd)
        return session.id
    }

    // MARK: - Delete Session

    /// Snapshot of one worktree's cleanup work, captured on the MainActor and
    /// passed by value into a detached task so disk/git operations don't block UI.
    struct WorktreeCleanupItem: Sendable {
        let repoPath: String
        let worktreePath: String
        let branch: String
        let isMainCheckout: Bool
    }

    /// Delete a session and clean up all associated resources.
    ///
    /// Performs a full cascade: destroys terminal surfaces, removes worktrees from disk
    /// (with branch deletion for non-protected branches), removes hook configs, and cleans
    /// up all in-memory state (sessions, worktrees, links, terminals, hook state, PR status).
    /// The primary Manager session (well-known UUID) cannot be deleted;
    /// additional Manager sessions are deletable.
    ///
    /// The slow filesystem/git work runs in a detached task so the main thread stays
    /// responsive. While cleanup is in flight, `appState.isDeletingSession[id]` is `true`
    /// so the UI can show a spinner. On failure the session is left in place with
    /// `appState.sessionDeletionError[id]` set, allowing the user to retry.
    func deleteSession(id: UUID) async {
        guard id != AppState.managerSessionID else { return }
        guard appState.isDeletingSession[id] != true else { return }

        let session = appState.sessions.first(where: { $0.id == id })
        let wts = appState.worktrees(for: id)
        let terminals = appState.terminals(for: id)
        let isReview = session?.kind == .review
        let items = wts.map {
            WorktreeCleanupItem(
                repoPath: $0.repoPath,
                worktreePath: $0.worktreePath,
                branch: $0.branch,
                isMainCheckout: $0.isMainRepoCheckout
            )
        }

        appState.isDeletingSession[id] = true
        appState.sessionDeletionError.removeValue(forKey: id)

        // Slow git + filesystem work runs on a background thread so the main actor
        // stays free to render the spinner and respond to other input.
        let cleanupError: String? = await Task.detached(priority: .utility) {
            Self.performDiskCleanup(items: items, isReview: isReview)
        }.value

        if let cleanupError {
            // Leave session, terminals, and persisted state intact so the user can
            // retry. Surface the failure inline; auto-clear after a short delay so
            // the row returns to its normal appearance.
            appState.sessionDeletionError[id] = cleanupError
            appState.isDeletingSession.removeValue(forKey: id)
            Task { [weak appState] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                _ = await MainActor.run { appState?.sessionDeletionError.removeValue(forKey: id) }
            }
            return
        }

        // Cleanup succeeded — destroy live terminal surfaces and tear down state.
        for terminal in terminals {
            TerminalRouter.destroy(terminal)
        }

        appState.sessions.removeAll { $0.id == id }
        appState.worktrees.removeValue(forKey: id)
        appState.links.removeValue(forKey: id)
        // Clean up auto-launch and remote-control sets for deleted session's terminals
        if let terms = appState.terminals[id] {
            for t in terms {
                appState.autoLaunchTerminals.remove(t.id)
                appState.remoteControlActiveTerminals.remove(t.id)
            }
        }
        appState.terminals.removeValue(forKey: id)
        appState.activeTerminalID.removeValue(forKey: id)
        appState.removeHookState(for: id)
        appState.prStatus.removeValue(forKey: id)
        appState.isMarkingInReview.removeValue(forKey: id)
        appState.isDeletingSession.removeValue(forKey: id)

        store.mutate { data in
            data.sessions.removeAll { $0.id == id }
            data.worktrees.removeAll { $0.sessionID == id }
            data.links.removeAll { $0.sessionID == id }
            data.terminals.removeAll { $0.sessionID == id }
            data.hookStates?[id.uuidString] = nil
        }

        if appState.selectedSessionID == id {
            appState.selectedSessionID = appState.sessions.first?.id
        }
    }

    /// Run the on-disk portion of session deletion. Safe to call from any thread —
    /// touches no MainActor state. Returns `nil` on success, or a short error
    /// string describing the first fatal failure (a worktree that could be removed
    /// neither by `git worktree remove` nor by direct directory removal).
    /// Soft failures (branch delete, prune) only get NSLog'd.
    nonisolated static func performDiskCleanup(
        items: [WorktreeCleanupItem],
        isReview: Bool
    ) -> String? {
        var firstFatalError: String? = nil

        for item in items {
            // Review clones are standalone `git clone` checkouts (not `git worktree add`
            // artifacts) and always have repoPath == worktreePath, which would otherwise
            // trip the main-checkout guard below and leave the clone orphaned on disk.
            if isReview {
                guard FileManager.default.fileExists(atPath: item.worktreePath) else { continue }
                do {
                    try FileManager.default.removeItem(atPath: item.worktreePath)
                    NSLog("[SessionService] Cleaned up review clone: \(item.worktreePath)")
                } catch {
                    let msg = "Failed to remove review clone: \(error.localizedDescription)"
                    NSLog("[SessionService] \(msg) (\(item.worktreePath))")
                    if firstFatalError == nil { firstFatalError = msg }
                }
                continue
            }

            if item.isMainCheckout {
                NSLog("Skipping worktree cleanup for main checkout: \(item.worktreePath) (branch: \(item.branch))")
                continue
            }

            // Remove our hook config from settings.local.json before deleting the worktree
            ClaudeHookConfigWriter().removeHookConfig(worktreePath: item.worktreePath)

            var gitRemoveFailed = false
            do {
                let removeResult = try runShellSync(["git", "-C", item.repoPath, "worktree", "remove", "--force", item.worktreePath])
                NSLog("Removed worktree: \(item.worktreePath) \(removeResult)")

                if !SessionWorktree.isProtectedBranch(item.branch) {
                    do {
                        _ = try runShellSync(["git", "-C", item.repoPath, "branch", "-D", item.branch])
                    } catch {
                        NSLog("[SessionService] Failed to delete branch \(item.branch): \(error)")
                    }
                }

                do {
                    _ = try runShellSync(["git", "-C", item.repoPath, "worktree", "prune"])
                } catch {
                    NSLog("[SessionService] Failed to prune worktree metadata: \(error)")
                }
            } catch {
                gitRemoveFailed = true
                NSLog("[SessionService] Failed to remove worktree \(item.worktreePath): \(error)")
            }

            // Either way, ensure the directory is gone.
            if FileManager.default.fileExists(atPath: item.worktreePath) {
                do {
                    try FileManager.default.removeItem(atPath: item.worktreePath)
                } catch {
                    NSLog("[SessionService] Failed to remove directory \(item.worktreePath): \(error)")
                    if gitRemoveFailed && firstFatalError == nil {
                        firstFatalError = "Could not remove worktree at \(item.worktreePath): \(error.localizedDescription)"
                    }
                }
            }
        }

        return firstFatalError
    }

    /// Synchronous shell helper safe to call from any thread. Used by
    /// `performDiskCleanup` while running on a detached task.
    nonisolated static func runShellSync(_ args: [String]) throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SessionService", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr])
        }
        return stdout
    }

    // MARK: - Worktree Safety Checks
    // Protected branch and main-checkout detection are centralized on SessionWorktree in CrowCore.

    /// Run `/usr/bin/env <args...>` and return stdout. Marked `nonisolated` and
    /// implemented via `withCheckedThrowingContinuation` + `terminationHandler`
    /// so `await shell(...)` truly suspends the calling task instead of
    /// blocking on `waitUntilExit()`. This is what keeps the main actor free
    /// during review-session kickoff (#404); the prior implementation pinned
    /// every git/gh call to the main thread.
    nonisolated private func shell(env: [String: String] = [:], _ args: String...) async throws -> String {
        let resolvedEnv = env.isEmpty
            ? ShellEnvironment.shared.env
            : ShellEnvironment.shared.merging(env)
        return try await Self.runShellAsync(env: resolvedEnv, args: args)
    }

    /// Shared async Process runner. Hands ownership of the pipes/process to
    /// the termination handler so reads happen after exit (no deadlock from
    /// a full pipe blocking the child) and the continuation is resumed
    /// exactly once.
    nonisolated static func runShellAsync(env: [String: String], args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = args
            process.environment = env
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            process.terminationHandler = { proc in
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "SessionService",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty ? stdout : stderr]
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                // Clear the termination handler so it can't fire after we
                // resume here — Process invokes it on launch failure paths
                // in some macOS versions, which would double-resume.
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// Resolve org/repo slug from a repo's git remote URL.
    private func resolveRepoSlug(repoPath: String) -> String? {
        guard let output = try? shellSync("git", "-C", repoPath, "remote", "get-url", "origin") else { return nil }
        var url = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
        if let match = url.range(of: #"[:/]([^/:]+/[^/:]+)$"#, options: .regularExpression) {
            return String(url[match]).trimmingCharacters(in: CharacterSet(charactersIn: "/:"))
        }
        return nil
    }

    private func shellSync(_ args: String...) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SessionService", code: Int(process.terminationStatus))
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - Orphan Worktree Detection

    /// Scan repos for worktrees that exist on disk but have no session in the store.
    /// Re-imports them as active sessions so they appear in the sidebar.
    /// Runs async and may invoke `gh` CLI for ticket/PR metadata (best-effort).
    func detectOrphanedWorktrees() async {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot) else { return }

        // Save current selection so orphan mutations don't reset it
        let savedSelection = appState.selectedSessionID

        // Collect all known worktree paths from the store
        let knownPaths = Set(
            appState.worktrees.values.flatMap { $0 }
                .map { ($0.worktreePath as NSString).standardizingPath }
        )

        let fm = FileManager.default

        // Scan each workspace for repos
        guard let workspaceDirs = try? fm.contentsOfDirectory(atPath: devRoot) else { return }

        for wsDir in workspaceDirs {
            let wsPath = (devRoot as NSString).appendingPathComponent(wsDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: wsPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !config.defaults.excludeDirs.contains(wsDir) else { continue }

            guard let repoDirs = try? fm.contentsOfDirectory(atPath: wsPath) else { continue }
            for repoDir in repoDirs {
                let repoPath = (wsPath as NSString).appendingPathComponent(repoDir)
                let gitPath = (repoPath as NSString).appendingPathComponent(".git")
                var gitIsDir: ObjCBool = false

                // Only process real repos (not worktrees — .git is a directory for repos, a file for worktrees)
                guard fm.fileExists(atPath: gitPath, isDirectory: &gitIsDir), gitIsDir.boolValue else { continue }

                // Get worktrees for this repo
                guard let output = try? await shell("git", "-C", repoPath, "worktree", "list", "--porcelain") else { continue }
                let worktrees = parseWorktreeList(output)

                for wt in worktrees {
                    let standardPath = (wt.path as NSString).standardizingPath

                    // Skip the main checkout
                    if standardPath == (repoPath as NSString).standardizingPath { continue }

                    // Skip if already tracked
                    if knownPaths.contains(standardPath) { continue }

                    // Skip protected branches
                    if SessionWorktree.isProtectedBranch(wt.branch) { continue }

                    // This is an orphan — recover it
                    NSLog("[SessionService] Recovered orphan worktree: \(wt.path) branch=\(wt.branch)")
                    await recoverOrphan(worktreePath: wt.path, branch: wt.branch, repoName: repoDir, repoPath: repoPath)
                }
            }
        }

        // Restore selection if orphan mutations reset it
        if savedSelection != nil && appState.selectedSessionID != savedSelection {
            appState.selectedSessionID = savedSelection
        }
    }

    private struct WorktreeEntry {
        let path: String
        let branch: String
    }

    private func parseWorktreeList(_ output: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var currentPath: String?
        var currentBranch: String?

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") {
                // Save previous entry
                if let path = currentPath, let branch = currentBranch {
                    entries.append(WorktreeEntry(path: path, branch: branch))
                }
                currentPath = String(line.dropFirst("worktree ".count))
                currentBranch = nil
            } else if line.hasPrefix("branch ") {
                currentBranch = String(line.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        // Don't forget the last entry
        if let path = currentPath, let branch = currentBranch {
            entries.append(WorktreeEntry(path: path, branch: branch))
        }
        return entries
    }

    private struct TicketInfo {
        var number: Int?
        var url: String?
        var title: String?
        var provider: Provider?
    }

    /// Parse ticket number from a directory name and resolve ticket metadata from GitHub.
    private func parseTicketInfo(dirName: String, repoPath: String) async -> TicketInfo {
        var info = TicketInfo()

        let parts = dirName.components(separatedBy: "-")
        // Look for a numeric part after the repo name prefix
        if !parts.isEmpty {
            for (i, part) in parts.enumerated() where i > 0 {
                if let num = Int(part) {
                    info.number = num
                    break
                }
            }
        }

        guard let num = info.number else { return info }

        // Try to construct ticket URL from git remote
        if let remoteURL = try? await shell("git", "-C", repoPath, "remote", "get-url", "origin") {
            var url = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if url.hasSuffix(".git") { url = String(url.dropLast(4)) }
            if url.hasPrefix("git@github.com:") {
                let slug = url.replacingOccurrences(of: "git@github.com:", with: "")
                info.url = "https://github.com/\(slug)/issues/\(num)"
                info.provider = .github
            } else if url.contains("github.com") {
                info.url = "\(url)/issues/\(num)"
                info.provider = .github
            }
        }

        // Try to fetch issue title — prefer the TaskBackend abstraction (ADR 0005)
        // when a manager is wired; fall back to inline `gh` for older call paths.
        if let issueURL = info.url {
            if let manager = providerManager {
                let backend = manager.taskBackend(forURL: issueURL)
                if let ticket = try? await backend.fetchTask(url: issueURL) {
                    info.title = ticket.title
                }
            } else if let output = try? await shell("gh", "issue", "view", issueURL, "--json", "title"),
               let data = output.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let title = json["title"] as? String {
                info.title = title
            }
        }

        return info
    }

    /// Check for a pull request on a branch and return a link if found.
    private func findPRLink(branch: String, repoPath: String, sessionID: UUID) async -> SessionLink? {
        guard let repoSlug = resolveRepoSlug(repoPath: repoPath) else { return nil }
        // Prefer CodeBackend.linkedPR (ADR 0005) when a manager is wired; fall
        // back to the inline `gh pr list` shell-out for legacy call paths.
        if let manager = providerManager,
           let backend = manager.codeBackend(for: .github),
           let pr = try? await backend.linkedPR(repo: repoSlug, branch: branch) {
            NSLog("[SessionService] Found PR #\(pr.number) for branch '\(branch)'")
            return SessionLink(sessionID: sessionID, label: "PR #\(pr.number)", url: pr.url, linkType: .pr)
        }
        guard let prOutput = try? await shell(
            "gh", "pr", "list", "--repo", repoSlug, "--head", branch,
            "--state", "all", "--json", "number,url,state", "--limit", "1"
        ), let prData = prOutput.data(using: .utf8),
           let prItems = try? JSONSerialization.jsonObject(with: prData) as? [[String: Any]],
           let pr = prItems.first,
           let prNum = pr["number"] as? Int,
           let prURL = pr["url"] as? String else { return nil }

        NSLog("[SessionService] Found PR #\(prNum) for branch '\(branch)'")
        return SessionLink(sessionID: sessionID, label: "PR #\(prNum)", url: prURL, linkType: .pr)
    }

    private func recoverOrphan(worktreePath: String, branch: String, repoName: String, repoPath: String) async {
        let dirName = (worktreePath as NSString).lastPathComponent
        let ticket = await parseTicketInfo(dirName: dirName, repoPath: repoPath)

        let session = Session(
            name: dirName,
            status: .active,
            agentKind: appState.defaultAgentKind,
            ticketURL: ticket.url,
            ticketTitle: ticket.title,
            ticketNumber: ticket.number,
            provider: ticket.provider
        )

        let worktree = SessionWorktree(
            sessionID: session.id,
            repoName: repoName,
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch,
            isPrimary: true
        )

        let rawTerminal = SessionTerminal(
            sessionID: session.id,
            name: "Claude Code",
            cwd: worktreePath,
            isManaged: true
        )

        // Collect links
        var links: [SessionLink] = []
        if let ticketURL = ticket.url {
            let label = ticket.number.map { "Issue #\($0)" } ?? "Issue"
            links.append(SessionLink(sessionID: session.id, label: label, url: ticketURL, linkType: .ticket))
        }
        if let prLink = await findPRLink(branch: branch, repoPath: repoPath, sessionID: session.id) {
            links.append(prLink)
        }

        // Backend dispatch — prepareTerminal returns the row with
        // backend/tmuxBinding set and starts the surface or tmux window.
        let terminal = prepareTerminal(rawTerminal, trackReadiness: true)

        // Update state
        appState.sessions.append(session)
        appState.worktrees[session.id] = [worktree]
        appState.terminals[session.id] = [terminal]
        appState.links[session.id] = links.isEmpty ? nil : links
        appState.terminalReadiness[terminal.id] = .uninitialized
        appState.autoLaunchTerminals.insert(terminal.id)

        // Single atomic store mutation
        store.mutate { data in
            data.sessions.append(session)
            data.worktrees.append(worktree)
            data.terminals.append(terminal)
            data.links.append(contentsOf: links)
        }

        NSLog("[SessionService] Recovered session '\(dirName)' — ticket=#\(ticket.number.map(String.init) ?? "none") title=\(ticket.title ?? "unknown")")
    }

    // MARK: - Terminal Tab Management

    /// Add a new plain-shell (unmanaged) terminal tab to a session.
    func addTerminal(sessionID: UUID) {
        let cwd = appState.primaryWorktree(for: sessionID)?.worktreePath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let raw = SessionTerminal(sessionID: sessionID, name: "Shell", cwd: cwd, isManaged: false)
        let terminal = prepareTerminal(raw, trackReadiness: false)
        appState.terminals[sessionID, default: []].append(terminal)
        appState.activeTerminalID[sessionID] = terminal.id
        store.mutate { data in data.terminals.append(terminal) }
    }

    /// Close a non-managed terminal tab. Managed terminals cannot be closed individually.
    func closeTerminal(sessionID: UUID, terminalID: UUID) {
        guard let terminals = appState.terminals[sessionID],
              let terminal = terminals.first(where: { $0.id == terminalID }),
              !terminal.isManaged else { return }

        appState.terminals[sessionID]?.removeAll { $0.id == terminalID }
        appState.terminalReadiness.removeValue(forKey: terminalID)
        appState.autoLaunchTerminals.remove(terminalID)

        if appState.activeTerminalID[sessionID] == terminalID {
            appState.activeTerminalID[sessionID] = appState.terminals[sessionID]?.first?.id
        }

        store.mutate { data in data.terminals.removeAll { $0.id == terminalID } }

        // Defer the backing destroy so SwiftUI's render pass detaches the
        // GhosttySurfaceView from the view hierarchy before we free its
        // underlying `ghostty_surface_t` (or kill the tmux window). Freeing
        // it while AppKit still holds the view risks a Metal/input callback
        // landing on a dangling pointer (issue #282).
        //
        // Note: single-tick defer is a conservative first attempt. Neither
        // Combine nor DispatchQueue strictly guarantee ordering against the
        // SwiftUI CATransaction commit; if #282 recurs the next step is a
        // two-tick defer (nested `DispatchQueue.main.async`) or moving the
        // destroy to a runloop-quiesce sweep.
        DispatchQueue.main.async {
            TerminalRouter.destroy(terminal)
        }
    }

    /// Rename a terminal tab. Returns `false` if the terminal was not found or the name is invalid.
    @discardableResult
    func renameTerminal(sessionID: UUID, terminalID: UUID, name: String) -> Bool {
        guard Validation.isValidSessionName(name),
              let idx = appState.terminals[sessionID]?.firstIndex(where: { $0.id == terminalID }) else { return false }
        appState.terminals[sessionID]![idx].name = name
        store.mutate { data in
            if let i = data.terminals.firstIndex(where: { $0.id == terminalID }) {
                data.terminals[i].name = name
            }
        }
        return true
    }

    /// Rename a session. Returns `false` if the session was not found or the name is invalid.
    @discardableResult
    func renameSession(sessionID: UUID, name: String) -> Bool {
        guard Validation.isValidSessionName(name),
              let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        appState.sessions[idx].name = name
        store.mutate { data in
            if let i = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                data.sessions[i].name = name
            }
        }
        syncRemoteControlName(sessionID: sessionID, newName: name)
        return true
    }

    /// Terminals to push a Remote-Control `/rename` into for a session: those
    /// launched with `--rc` (tracked in `remoteControlActiveTerminals`). That's
    /// the Claude Code instance whose claude.ai panel label is fixed at launch.
    /// Manager terminals qualify even though they aren't flagged `isManaged`.
    /// Pure/`nonisolated` so it can be unit-tested without a live app.
    nonisolated static func remoteControlRenameTargets(
        terminals: [SessionTerminal],
        rcActiveTerminals: Set<UUID>
    ) -> [SessionTerminal] {
        terminals.filter { rcActiveTerminals.contains($0.id) }
    }

    /// After an in-app rename, push the new name to the running Claude Code via
    /// its `/rename` slash command so claude.ai's Remote Control panel label
    /// (fixed at launch via `--name`) stays in sync. No-op when the session has
    /// no `--rc` terminal, or when a terminal's surface isn't ready to receive.
    /// The name is already validated (no control characters) by the caller, so
    /// the trailing newline is the only Enter keypress sent.
    private func syncRemoteControlName(sessionID: UUID, newName: String) {
        let targets = Self.remoteControlRenameTargets(
            terminals: appState.terminals(for: sessionID),
            rcActiveTerminals: appState.remoteControlActiveTerminals
        )
        for terminal in targets where TerminalRouter.canSend(terminal) {
            TerminalRouter.send(terminal, text: "/rename \(newName)\n")
        }
    }

    // MARK: - Global Terminal Management


    // MARK: - Review Session

    /// Create a review session for an incoming PR review request.
    ///
    /// Returns the new session's ID on success, or `nil` if the PR URL could not
    /// be resolved or session creation failed. `selectAfterCreate` defaults to
    /// false: review kickoff is normally driven by `AppDelegate.enqueueReviewKickoff`
    /// which intentionally leaves the user's current detail-pane focus alone, so
    /// new review sessions appear in the sidebar without yanking the view.
    /// Concurrent writes to `appState.selectedSessionID` from racing kickoffs are
    /// what produced the SwiftUI reentrant-layout crash in #266.
    @discardableResult
    func createReviewSession(prURL: String, selectAfterCreate: Bool = false) async -> UUID? {
        // Universal backstop against duplicate sessions for the same PR. The
        // serial kickoff queue in AppDelegate guarantees that by the time a
        // second `createReviewSession` runs, the first has already appended
        // its row to `appState.sessions` — so this check is authoritative,
        // not racy. Belt-and-suspenders for the auto-review watcher race
        // (CROW-406) and any future caller that re-enters during a kickoff.
        if let existing = appState.existingReviewSession(forPRURL: prURL) {
            NSLog("[SessionService] Skipping duplicate review session for \(prURL); reusing \(existing.id)")
            if selectAfterCreate { appState.selectedSessionID = existing.id }
            return existing.id
        }

        // Parse org/repo and PR number from URL like "https://github.com/org/repo/pull/123"
        guard let parsed = Session.parseReviewPR(url: prURL) else {
            NSLog("[SessionService] Could not parse PR URL: \(prURL)")
            return nil
        }
        let owner = parsed.owner
        let repoName = parsed.repo
        let prNumber = parsed.number
        let repoSlug = "\(owner)/\(repoName)"

        // Determine clone path
        guard let devRoot = ConfigStore.loadDevRoot() else {
            NSLog("[SessionService] No devRoot configured")
            return nil
        }

        // All git/network/file-write work runs off the main actor so the UI
        // never beachballs while a review spins up (#404). The detached task
        // hands back just the metadata the main-actor tail needs to build
        // the Session/Worktree/Terminal/Link rows.
        let env = ShellEnvironment.shared.env
        let prep: ReviewClonePrep
        do {
            prep = try await Task.detached(priority: .userInitiated) {
                try await Self.prepareReviewClone(
                    prURL: prURL,
                    repoSlug: repoSlug,
                    repoName: repoName,
                    prNumber: prNumber,
                    devRoot: devRoot,
                    env: env
                )
            }.value
        } catch {
            NSLog("[SessionService] Failed to prepare review clone for \(prURL): \(error.localizedDescription)")
            return nil
        }

        // Create session
        let session = Session(
            name: "review-\(repoName)-\(prNumber)",
            kind: .review,
            agentKind: appState.defaultAgentKind,
            ticketTitle: prep.prTitle,
            provider: .github,
            lastReviewedHeadSha: prep.headRefOid
        )

        let worktree = SessionWorktree(
            sessionID: session.id,
            repoName: repoName,
            repoPath: prep.clonePath,
            worktreePath: prep.clonePath,
            branch: prep.headBranch,
            isPrimary: true
        )

        let terminal = SessionTerminal(
            sessionID: session.id,
            name: "Claude Code",
            cwd: prep.clonePath,
            isManaged: true
        )

        let prLink = SessionLink(
            sessionID: session.id,
            label: "PR #\(prNumber)",
            url: prURL,
            linkType: .pr
        )

        // Backend dispatch — prepareTerminal returns the row with
        // backend/tmuxBinding set and starts the surface or tmux window.
        let preparedTerminal = prepareTerminal(terminal, trackReadiness: true)

        // Add to state
        appState.sessions.append(session)
        appState.worktrees[session.id] = [worktree]
        appState.terminals[session.id] = [preparedTerminal]
        appState.links[session.id] = [prLink]
        appState.terminalReadiness[preparedTerminal.id] = .uninitialized
        appState.autoLaunchTerminals.insert(preparedTerminal.id)

        // Persist
        store.mutate { data in
            data.sessions.append(session)
            data.worktrees.append(worktree)
            data.terminals.append(preparedTerminal)
            data.links.append(prLink)
        }

        // Select the new session
        if selectAfterCreate {
            appState.selectedSessionID = session.id
        }

        NSLog("[SessionService] Created review session '\(session.name)' for \(prURL)")
        return session.id
    }

    /// Metadata produced by the off-main-actor `prepareReviewClone` step.
    /// Holds everything the main-actor tail of `createReviewSession` needs to
    /// build the `Session` / `SessionWorktree` / `SessionTerminal` rows.
    private struct ReviewClonePrep: Sendable {
        let prTitle: String
        let headBranch: String
        let headRefOid: String?
        let clonePath: String
    }

    /// Off-main-actor preparation for a review session: fetch PR metadata,
    /// clone the repo (if needed), check out the PR branch, and stage the
    /// review prompt / skill / settings files. Returns the metadata the
    /// main-actor portion of `createReviewSession` needs. Throws on the only
    /// failure that should abort kickoff entirely (PR metadata fetch). git
    /// fetch/checkout/pull errors are tolerated as before — the worktree may
    /// already be in a usable state from a prior run.
    nonisolated private static func prepareReviewClone(
        prURL: String,
        repoSlug: String,
        repoName: String,
        prNumber: Int,
        devRoot: String,
        env: [String: String]
    ) async throws -> ReviewClonePrep {
        // Fetch PR metadata
        let prOutput = try await runShellAsync(env: env, args: [
            "gh", "pr", "view", prURL,
            "--json", "title,headRefName,headRefOid,baseRefName,number"
        ])

        guard let prData = prOutput.data(using: .utf8),
              let prJSON = try? JSONSerialization.jsonObject(with: prData) as? [String: Any],
              let prTitle = prJSON["title"] as? String,
              let headBranch = prJSON["headRefName"] as? String else {
            throw NSError(
                domain: "SessionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse PR metadata for \(prURL)"]
            )
        }
        // `headRefOid` is the SHA the review session is anchored to. Used by
        // the kickoff guard (AppDelegate) as a fallback re-kick signal when
        // the PR head advances without an explicit re-request (CROW-290).
        let headRefOid = prJSON["headRefOid"] as? String

        let reviewsDir = (devRoot as NSString).appendingPathComponent("crow-reviews")
        let cloneDirName = "\(repoName)-pr-\(prNumber)"
        let clonePath = (reviewsDir as NSString).appendingPathComponent(cloneDirName)

        let fm = FileManager.default

        // Ensure reviews directory exists
        try? fm.createDirectory(atPath: reviewsDir, withIntermediateDirectories: true)

        // Clone or update the repo
        if !fm.fileExists(atPath: (clonePath as NSString).appendingPathComponent(".git")) {
            NSLog("[SessionService] Cloning \(repoSlug) into \(clonePath)")
            _ = try? await runShellAsync(env: env, args: ["gh", "repo", "clone", repoSlug, clonePath])
        }

        // Fetch and checkout the PR branch
        _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "fetch", "origin", headBranch])
        _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", headBranch])
        _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "pull", "origin", headBranch])

        // Write review prompt file into the clone directory
        let promptPath = (clonePath as NSString).appendingPathComponent(".crow-review-prompt.md")
        let reviewPrompt = Self.buildReviewPrompt(prURL: prURL, prTitle: prTitle, repoSlug: repoSlug, prNumber: prNumber)
        try? reviewPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)

        // Copy the crow-review-pr skill into the clone's .claude/skills/ so Claude Code can find it
        let cloneSkillsDir = (clonePath as NSString).appendingPathComponent(".claude/skills/crow-review-pr")
        try? fm.createDirectory(atPath: cloneSkillsDir, withIntermediateDirectories: true)
        let skillContent = Scaffolder.bundledReviewSkill()
        try? skillContent.write(
            toFile: (cloneSkillsDir as NSString).appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        // Copy settings.json into the clone's .claude/ for permissions
        let cloneSettingsDir = (clonePath as NSString).appendingPathComponent(".claude")
        let settingsContent = Scaffolder.bundledSettings()
        try? settingsContent.write(
            toFile: (cloneSettingsDir as NSString).appendingPathComponent("settings.json"),
            atomically: true, encoding: .utf8
        )

        return ReviewClonePrep(
            prTitle: prTitle,
            headBranch: headBranch,
            headRefOid: headRefOid,
            clonePath: clonePath
        )
    }

    // MARK: - Scheduled Jobs (CROW-317)

    /// Run a scheduled job: create a fresh worktree + session + managed Claude
    /// terminal in the job's scoped repo and arm auto-launch so the first prompt
    /// dispatches once the shell is ready.
    ///
    /// Mirrors `createReviewSession`, but the worktree is a real git worktree off
    /// the repo's default branch (via `GitManager`) rather than a clone. The
    /// returned terminal id lets the caller (`JobScheduler`) deliver any
    /// remaining prompts after launch. Returns `nil` if the repo is missing or
    /// the worktree can't be created.
    func runJob(_ job: JobConfig, devRoot: String) async -> (sessionID: UUID, terminalID: UUID)? {
        guard let firstPrompt = job.prompts.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            NSLog("[SessionService] Job '\(job.name)' has no prompts; skipping")
            return nil
        }

        let gitManager = GitManager(config: WorkspaceConfig(
            devRoot: devRoot, workspaces: [:], defaults: WorkspaceDefaults()
        ))

        // Resolve the repo to a local checkout. The job carries a workspace and
        // an `owner/repo` slug (CROW-327): the checkout lives at
        // `{devRoot}/{workspace}/{repoFolder}` where repoFolder is the slug's
        // last component. Clone it on demand if it isn't on disk yet.
        let repoFolder = Self.jobRepoFolder(for: job.repo)
        let repoPath: String
        let workspacePath: String

        if !job.workspace.isEmpty {
            let layout = Self.jobWorktreeLayout(
                devRoot: devRoot, workspace: job.workspace, repo: job.repo
            )
            workspacePath = layout.workspacePath
            repoPath = layout.repoPath
            if !FileManager.default.fileExists(atPath: (repoPath as NSString).appendingPathComponent(".git")) {
                guard await cloneJobRepo(job: job, devRoot: devRoot, into: repoPath) else {
                    NSLog("[SessionService] Job '\(job.name)': repo '\(job.repo)' is not cloned and clone-on-demand failed")
                    return nil
                }
            }
        } else {
            // Back-compat: jobs saved before the workspace field returned store a
            // bare repo name. Resolve by folder name among local checkouts. Sort
            // first so a duplicated name binds deterministically across runs.
            let repos = ((try? await gitManager.discoverRepos()) ?? [])
                .sorted { $0.path < $1.path }
            guard let repoInfo = repos.first(where: { $0.name == job.repo }) else {
                NSLog("[SessionService] Job '\(job.name)': repo '\(job.repo)' not found under devRoot")
                return nil
            }
            repoPath = repoInfo.path
            workspacePath = (repoPath as NSString).deletingLastPathComponent
        }

        let slug = Self.slugify(job.name)
        let stamp = Self.runStamp()
        let branch = "feature/job-\(slug)-\(stamp)"
        let worktreePath = (workspacePath as NSString)
            .appendingPathComponent("\(repoFolder)-job-\(slug)-\(stamp)")

        // Create the worktree on disk (fetch + new branch off default + retry).
        do {
            try await gitManager.createWorktree(
                repoPath: repoPath, worktreePath: worktreePath, branch: branch
            )
        } catch {
            NSLog("[SessionService] Job '\(job.name)': createWorktree failed: \(error.localizedDescription)")
            return nil
        }

        // Write the first prompt to the file launchClaude reads on first launch.
        let promptPath = (worktreePath as NSString).appendingPathComponent(".crow-job-prompt.md")
        try? firstPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)

        let session = Session(
            name: "job-\(slug)-\(stamp)",
            kind: .job
        )
        let worktree = SessionWorktree(
            sessionID: session.id,
            repoName: repoFolder,
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch,
            isPrimary: true
        )
        let terminal = SessionTerminal(
            sessionID: session.id,
            name: "Claude Code",
            cwd: worktreePath,
            isManaged: true
        )

        // Backend dispatch — starts the surface / tmux window and tracks readiness.
        let preparedTerminal = prepareTerminal(terminal, trackReadiness: true)

        appState.sessions.append(session)
        appState.worktrees[session.id] = [worktree]
        appState.terminals[session.id] = [preparedTerminal]
        appState.terminalReadiness[preparedTerminal.id] = .uninitialized
        appState.autoLaunchTerminals.insert(preparedTerminal.id)

        store.mutate { data in
            data.sessions.append(session)
            data.worktrees.append(worktree)
            data.terminals.append(preparedTerminal)
        }

        NSLog("[SessionService] Job '\(job.name)': created session '\(session.name)' at \(worktreePath)")
        return (session.id, preparedTerminal.id)
    }

    /// The local folder name for a job's repo: the slug's last component
    /// (`radiusmethod/api` → `api`, GitLab `group/sub/proj` → `proj`), or the
    /// value verbatim when it isn't a slug (legacy bare-name jobs).
    nonisolated static func jobRepoFolder(for repo: String) -> String {
        repo.contains("/") ? (repo as NSString).lastPathComponent : repo
    }

    /// Where a workspace-scoped job's checkout and worktree parent live:
    /// `{devRoot}/{workspace}/{repoFolder}`. Pure path math (no filesystem),
    /// so it's unit-testable independent of clone/worktree side effects.
    nonisolated static func jobWorktreeLayout(
        devRoot: String, workspace: String, repo: String
    ) -> (workspacePath: String, repoPath: String, repoFolder: String) {
        let repoFolder = jobRepoFolder(for: repo)
        let workspacePath = (devRoot as NSString).appendingPathComponent(workspace)
        let repoPath = (workspacePath as NSString).appendingPathComponent(repoFolder)
        return (workspacePath, repoPath, repoFolder)
    }

    /// Clone a job's repo into `destination` on demand (the provider list can
    /// include repos not yet checked out). Needs an `owner/repo` slug; the
    /// workspace supplies the provider and (for GitLab) the host. Returns
    /// whether a `.git` checkout exists at `destination` afterward.
    private func cloneJobRepo(job: JobConfig, devRoot: String, into destination: String) async -> Bool {
        guard job.repo.contains("/") else {
            NSLog("[SessionService] Job '\(job.name)': repo '\(job.repo)' is not an owner/repo slug; cannot clone")
            return false
        }
        let workspace = ConfigStore.loadConfig(devRoot: devRoot)?
            .workspaces.first { $0.name == job.workspace }
        let provider = workspace?.provider ?? "github"

        // Ensure the workspace parent exists — a brand-new workspace may have no
        // checkouts on disk yet, and git won't create leading directories.
        try? FileManager.default.createDirectory(
            atPath: (destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        NSLog("[SessionService] Job '\(job.name)': cloning \(job.repo) into \(destination)")
        do {
            if provider == "gitlab" {
                var env: [String: String] = [:]
                if let host = workspace?.host, !host.isEmpty { env["GITLAB_HOST"] = host }
                _ = try await shell(env: env, "glab", "repo", "clone", job.repo, destination)
            } else {
                _ = try await shell("gh", "repo", "clone", job.repo, destination)
            }
        } catch {
            NSLog("[SessionService] Job '\(job.name)': clone failed: \(error.localizedDescription)")
        }
        return FileManager.default.fileExists(atPath: (destination as NSString).appendingPathComponent(".git"))
    }

    /// A filesystem/branch-safe slug derived from a job name.
    private static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "job" : String(slug.prefix(40))
    }

    /// A compact `yyyyMMdd-HHmmss` timestamp that makes each run's branch/worktree unique.
    private static func runStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    // MARK: - Review Prompt

    /// Build the initial prompt for a review session.
    nonisolated private static func buildReviewPrompt(prURL: String, prTitle: String, repoSlug: String, prNumber: Int) -> String {
        """
        /crow-review-pr \(prURL)
        """
    }

    // MARK: - Session Status

    /// Update a session's status and persist the change.
    private func updateSessionStatus(_ id: UUID, to status: SessionStatus) {
        // Managers stay always-active; never transition them through the
        // review/complete lifecycle.
        guard !appState.isManagerSession(id) else { return }

        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].status = status
            appState.sessions[idx].updatedAt = Date()
        }

        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[idx].status = status
                data.sessions[idx].updatedAt = Date()
            }
        }
    }

    func completeSession(id: UUID) {
        updateSessionStatus(id, to: .completed)
    }

    func setSessionInReview(id: UUID) {
        updateSessionStatus(id, to: .inReview)
    }

    func setSessionActive(id: UUID) {
        updateSessionStatus(id, to: .active)
    }

    // MARK: - Persist Current State

    /// Sync all in-memory state back to the JSON store on disk.
    func persistState() {
        // Snapshot color-driving hook state so a clean quit (this runs from
        // applicationWillTerminate) captures the final state for relaunch (#367).
        let hookSnapshots = appState.allHookStateSnapshots()
        store.mutate { data in
            data.sessions = appState.sessions
            // Flatten worktrees, links, terminals from dicts
            data.worktrees = appState.worktrees.values.flatMap { $0 }
            data.links = appState.links.values.flatMap { $0 }
            data.terminals = appState.terminals.values.flatMap { $0 }
            data.hookStates = Dictionary(
                uniqueKeysWithValues: hookSnapshots.map { ($0.key.uuidString, $0.value) })
        }
    }

    // MARK: - Find Claude Binary

    /// Standard search paths for the Claude CLI binary, in priority order.
    nonisolated static let claudeBinaryCandidates = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ]

    /// Find the real claude binary, skipping CMUX wrapper.
    static func findClaudeBinary() -> String? {
        let candidates = claudeBinaryCandidates
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    // MARK: - VS Code Integration

    /// Find the VS Code `code` CLI binary.
    static func findVSCodeBinary() -> String? {
        let candidates = [
            "/usr/local/bin/code",
            "/opt/homebrew/bin/code",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/code").path,
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Check if VS Code CLI is available and cache the result in AppState.
    func detectVSCode() {
        appState.vsCodeAvailable = Self.findVSCodeBinary() != nil
    }

    /// Open the primary worktree for a session in VS Code.
    func openInVSCode(sessionID: UUID) {
        guard let codePath = Self.findVSCodeBinary() else { return }
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codePath)
        process.arguments = [wt.worktreePath]
        try? process.run()
    }

    /// Open a terminal window at the primary worktree path for a session.
    func openTerminal(sessionID: UUID) {
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", wt.worktreePath]
        try? process.run()
    }

    // MARK: - Backend dispatch helpers (#198 follow-up)

    /// Register a brand-new SessionTerminal's tmux window and return the row
    /// with its `tmuxBinding` set so the caller can persist it. The Manager
    /// terminal goes through this same path as every other session (#314); for
    /// it, `registerTerminal` pastes the stored `claude` command into the tmux
    /// window directly. If tmux is unavailable or registration fails the row is
    /// returned unbound and simply won't render.
    @MainActor
    private func prepareTerminal(_ terminal: SessionTerminal, trackReadiness: Bool) -> SessionTerminal {
        var t = terminal
        guard !TmuxBackend.shared.tmuxBinary.isEmpty else {
            NSLog("[SessionService] tmux not configured; terminal \(t.id) will not render")
            return t
        }
        do {
            let binding = try TmuxBackend.shared.registerTerminal(
                id: t.id,
                name: t.name,
                cwd: t.cwd,
                command: t.command,
                trackReadiness: trackReadiness
            )
            t.tmuxBinding = binding
        } catch {
            NSLog("[SessionService] tmux registerTerminal failed (\(error)); terminal \(t.id) will not render")
        }
        return t
    }
}
