import Foundation
import CrowClaude
import CrowCodex
import CrowCore
import CrowCursor
import CrowGit
import CrowGrok
import CrowPersistence
import CrowProvider
import CrowTerminal

/// tmux surface lifecycle (CROW-1113), extracted from `SessionService`. Owns
/// store→state hydration, client-mode adopt, cold-start takeover + surface
/// rebuild, single-terminal recreate, per-terminal rehydration, the tmux
/// readiness bridge, orphan-window reaping/reconcile, the manual tmux-server
/// restart, and the mid-run crash auto-recovery (#588) — including the only
/// mutable crash-recovery state. Behavior-preserving: same adopt-first policy,
/// same forceRegister semantics, same crash-debounce, same readiness state
/// machine. Reaches `appState`, the shared **injected** `JSONStore`,
/// `hostBridge`, and the launch / Manager collaborators through an unowned
/// back-reference (ADR 0012 / #728). The public entry points +
/// takeover/recreate policy statics stay on `SessionService` as facades.
@MainActor
final class SessionSurfaceController {
    unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }
    private var hostBridge: HostBridge { owner.hostBridge }

    /// Wall-clock of the last crash auto-recovery, to debounce a tight
    /// crash → recover → crash loop (e.g. a broken tmux install).
    private var lastCrashRecoveryAt: Date?

    /// Force-clears `tmuxCrashRecovering` if readiness callbacks never settle
    /// (e.g. tmux unconfigured so no terminal was re-registered at all).
    private var crashRecoveryClearFallback: Task<Void, Never>?

    init(owner: SessionService) { self.owner = owner }

    // MARK: - Hydrate State from Store
    public func hydrateState() {
        let data = store.data
        appState.sessions = data.sessions
        // Mirror persisted analytics snapshots for the scorecard (#710) —
        // the web client can't read the store, so the scorecard computes from this.
        appState.analyticsSnapshots = data.analyticsSnapshots ?? [:]
        // Same for PR attributions: the v2 combined score's hygiene factor
        // (#699) reads this mirror; IssueTracker resyncs it after writes.
        appState.prAttributions = data.prAttributions ?? [:]
        // And the Manager weekly usage rollups (#745, CROW-983).
        appState.managerUsageWeekly = data.managerUsageWeekly ?? [:]

        // Migrate a legacy primary Manager (persisted as `.work` before
        // SessionKind.manager existed) to `.manager` BEFORE the per-session loop.
        // Otherwise the `!session.isManager` hydration branch clears its claude
        // command and reroutes it through the work-session auto-launch path,
        // silently dropping the Manager's --auto-permission-mode args (#316).
        // Persist so the upgrade is one-shot.
        if SessionService.migrateLegacyManagerKind(&appState.sessions) {
            store.mutate { data in
                _ = SessionService.migrateLegacyManagerKind(&data.sessions)
            }
        }

        // Backfill provider from ticketURL for sessions that predate provider tracking
        for i in appState.sessions.indices {
            if appState.sessions[i].provider == nil, let url = appState.sessions[i].ticketURL {
                let detected = Validation.detectProviderFromURL(url)
                appState.sessions[i].provider = detected
                // Task-only trackers (Jira/Corveil) have no code backend — pair
                // with the workspace's code provider so PR/git flows resolve.
                if appState.sessions[i].codeProvider == nil, detected?.isTaskOnly == true {
                    let wtPath = appState.worktrees[appState.sessions[i].id]?
                        .first(where: { $0.isPrimary })?.worktreePath
                        ?? appState.worktrees[appState.sessions[i].id]?.first?.worktreePath
                    appState.sessions[i].codeProvider = SessionService.resolvedCodeProvider(forTask: detected, worktreePath: wtPath)
                }
            }
        }

        // One-time backfill: legacy review sessions were persisted before
        // `reviewAuthor` existed, so they show no author when the Reviews board
        // is empty. Re-fetch it from the PR and persist, once (CROW-593).
        owner.backfillReviewAuthors()

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
                // Manager terminal: rebuild its agent command to match the
                // current remoteControlEnabled / managerAutoPermissionMode
                // preferences AND the currently-configured Manager agent
                // (CROW-433). Unlike worker sessions the Manager launches its
                // agent directly as the shell command, so the stored string
                // needs to be correct before preInitialize runs. Built via
                // the shared `managerCommand(for:)` helper so the dispatch
                // has one source. Rebuilds any non-empty existing command so
                // a Cursor/Codex Manager (whose command never contained
                // "claude") still gets refreshed across restarts.
                //
                // Reconcile `session.agentKind` to the currently-configured
                // Manager agent BEFORE the command rebuild. `ensureManagerSession`
                // also performs this reconciliation, but it runs after
                // `hydrateState` — on the reboot / dead-tmux path
                // `rebuildAllSurfaces` registers a fresh window and pastes
                // the just-rebuilt command, so if hydrate keyed off the
                // stale persisted kind the change would only take effect on
                // the second respawn (CROW-433 review).
                let configuredKind = appState.agentKind(for: .manager)
                var reconciled = session
                if reconciled.agentKind != configuredKind {
                    reconciled.agentKind = configuredKind
                    if let idx = appState.sessions.firstIndex(where: { $0.id == session.id }) {
                        appState.sessions[idx].agentKind = configuredKind
                    }
                    store.mutate { data in
                        if let i = data.sessions.firstIndex(where: { $0.id == session.id }) {
                            data.sessions[i].agentKind = configuredKind
                        }
                    }
                }
                let rebuiltCommand = owner.managerCommand(for: reconciled)
                // CROW-539: (re)write the Manager's hook config on every launch.
                // The Manager terminal is adopted here, not recreated, so
                // createManagerTerminal's hook write doesn't run — without this a
                // Manager whose terminal predates the hooks never emits events and
                // its card never lights up. Write to the terminal's own cwd so an
                // additional Manager running outside the dev root is covered too.
                // Before writeManagerGatewayEnv() so its 0o600 re-apply is last.
                if let managerCwd = terminals.first?.cwd {
                    owner.writeManagerHookConfig(for: reconciled, dirPath: managerCwd)
                    // CROW-600: pre-trust the Manager's cwd so a devRoot the
                    // user hasn't opened Claude Code in before doesn't block
                    // on the trust dialog. No-ops when already trusted.
                    if reconciled.agentKind == .claudeCode {
                        ClaudeTrustSeeder.seedTrust(projectPath: managerCwd)
                    }
                }
                owner.writeManagerGatewayEnv(managerKind: reconciled.agentKind)
                // Remote-control bookkeeping reflects what the agent actually
                // emitted — `supportsRemoteControl` is per-agent capability,
                // but per-launch the Cursor Manager intentionally omits `--rc`
                // even though Cursor reports the capability. Gate on the flag
                // appearing in the built command so the RC badge and
                // `/rename` injection don't fire for a Cursor Manager
                // (CROW-433 review).
                let rebuiltCarriesRC = rebuiltCommand.contains(" --rc")
                for i in terminals.indices {
                    if terminals[i].command != nil {
                        // Mutate in place rather than reconstructing the row:
                        // the memberwise init drops tmuxBinding, which made the
                        // Manager spawn a fresh window + claude every relaunch
                        // instead of re-attaching to its live window (#374).
                        terminals[i].command = rebuiltCommand
                        if rebuiltCarriesRC {
                            appState.remoteControlActiveTerminals.insert(terminals[i].id)
                        } else {
                            appState.remoteControlActiveTerminals.remove(terminals[i].id)
                        }
                    }
                }
            }
            appState.terminals[session.id] = terminals

            // Pre-create terminalReadiness slots for managed work session
            // terminals so the readiness callbacks (surfaceCreated and
            // tmux's onReadinessChanged) have something to update. The
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
    /// Client-mode surface adoption (ADR 0007; CROW-581, Stage 3b/F). Attach
    /// in-process to the tmux windows `crowd` created — the terminals in a
    /// `get-state` snapshot — so they render and take input, WITHOUT ever
    /// spawning a fresh window or writing the store: `crowd` owns spawning and
    /// the store in client mode. Only adopts windows this process hasn't
    /// registered yet, so it's cheap and idempotent to call after every hydrate.
    /// Unlike `rebuildAllSurfaces`, a failed adopt is logged and skipped (the
    /// window simply won't render) rather than recreated.
    @MainActor
    public func adoptExistingSurfaces() {
        wireTerminalReadiness()
        for terminals in appState.terminals.values {
            for terminal in terminals {
                guard let binding = terminal.tmuxBinding,
                      !TmuxBackend.shared.isRegistered(id: terminal.id) else { continue }
                do {
                    try TmuxBackend.shared.adoptTerminal(id: terminal.id, binding: binding, trackReadiness: false)
                } catch {
                    CrowLog.info("[SessionService] client-mode adopt failed for \(terminal.id): \(error.localizedDescription)")
                }
            }
        }
    }

    @MainActor
    public func rebuildAllSurfaces(forceRegister: Bool = false) {
        // Wire BEFORE re-registering so the sentinel's .shellReady is never lost.
        wireTerminalReadiness()

        for session in appState.sessions {
            guard var terminals = appState.terminals[session.id] else { continue }
            let isManagerSession = session.isManager
            let sid = session.id

            // Seed managed work terminals' readiness + auto-launch, and on a
            // forced rebuild clear any stored claude command. `forceRegister`
            // resets every readiness slot (dead server → the fresh shell's
            // `.shellReady` relaunches `claude --continue`); the normal adopt
            // path fills only a MISSING slot, which the headless daemon needs:
            // it calls `rebuildAllSurfaces` directly rather than via
            // `hydrateState` (where the app pre-seeds this), and the adopt
            // branch only promotes an *existing* slot to `.agentLaunched`
            // (`if terminalReadiness[id] != nil`). Without a non-nil slot the
            // adopted work terminal's readiness stays nil, so the auto-refine
            // idle-gate (`IssueTracker.isManagedTerminalIdle`, which requires
            // `.agentLaunched`) can never become true and "changes requested"
            // never dispatches with the app down (CROW-581). Only-fill-when-nil
            // on the normal path so a prior adopt's live `.agentLaunched` isn't
            // clobbered on a later takeover.
            if !isManagerSession {
                for i in terminals.indices where terminals[i].isManaged {
                    let tid = terminals[i].id
                    if forceRegister || appState.terminalReadiness[tid] == nil {
                        appState.terminalReadiness[tid] = .uninitialized
                        appState.autoLaunchTerminals.insert(tid)
                    }
                    // Mirror the hydrate-clear (#374/#588): on a forced rebuild a
                    // managed terminal must never re-run a stored claude command
                    // verbatim — the relaunch goes through autoLaunchCommand
                    // (`claude --continue`) instead. In-memory rows are already
                    // nil today (the new-terminal RPC persists nil); this makes
                    // the re-run-the-initial-plan failure impossible (#588).
                    if forceRegister, let cmd = terminals[i].command, cmd.contains("claude") {
                        terminals[i].command = nil
                    }
                }
                appState.terminals[session.id] = terminals
            }

            for original in terminals {
                let trackReadiness = !isManagerSession && original.isManaged
                // Server was just killed → binding is dead. Drop it so
                // rehydrateTerminalSurface skips adopt and registers a fresh
                // window (and persists the new windowIndex).
                var seed = original
                if forceRegister { seed.tmuxBinding = nil }
                // Capture `owner` strongly so the rehydration completes even if
                // the caller drops its `SessionService` reference before this
                // task runs — the exact lifetime the pre-CROW-1113 strong `self`
                // (then the SessionService itself) capture provided. `self` (this
                // controller) is captured strongly too but reaches state through
                // the now-`unowned` `owner`, so retaining `self` alone would leave
                // `owner` dangling.
                Task { @MainActor [owner] in
                    _ = owner
                    let updated = self.rehydrateTerminalSurface(seed, trackReadiness: trackReadiness)
                    self.applyRehydrationResult(sessionID: sid, original: seed, updated: updated)
                }
            }
        }
    }

    /// Cold-start terminal takeover for the headless daemon (CROW-747). Probes
    /// whether the tmux cockpit session survived, then restores accordingly:
    ///
    ///   - **Cockpit alive** — a warm `crowd` restart: the daemon process
    ///     bounced but tmux and its windows kept running, so each agent is still
    ///     live in its pane. Adopt the surviving windows in place via
    ///     `rebuildAllSurfaces(forceRegister: false)`; nothing is relaunched.
    ///   - **Cockpit gone** — a machine reboot or `tmux kill-server`: the server
    ///     and every window (and the agent process inside each) were destroyed,
    ///     but session metadata persisted to disk. Recreate each persisted
    ///     terminal's window and relaunch its session's agent via
    ///     `rebuildAllSurfaces(forceRegister: true)` — the same
    ///     recreate-and-relaunch machinery the mid-run crash auto-recovery uses
    ///     (#588). The relaunch routes through `launchAgent →
    ///     agent.autoLaunchCommand` keyed on the session's `agentKind`, so every
    ///     supported agent resumes per its own rules (Claude via `--continue`,
    ///     Cursor/Codex/OpenCode via their equivalents; branches an agent marks
    ///     unsupported simply stay unlaunched).
    ///
    /// Correct against the warm-restart regression the ticket warns about:
    /// `forceRegister: true` is gated on the server actually being gone, so a
    /// live pane is never re-registered and no agent is double-launched into a
    /// running one. Returns whether the recreate path was taken (for tests).
    @MainActor
    @discardableResult
    public func takeOverTerminalSurfaces() -> Bool {
        let recreate = Self.shouldRecreateSurfacesOnTakeover(
            cockpitSessionIsLive: TmuxBackend.shared.cockpitSessionIsLive())
        CrowLog.info(recreate
            ? "[CrowTelemetry takeover:recreate] tmux cockpit gone (reboot/kill-server) — recreating windows + relaunching agents (CROW-747)"
            : "[CrowTelemetry takeover:adopt] tmux cockpit alive — adopting surviving surfaces in place")
        rebuildAllSurfaces(forceRegister: recreate)
        return recreate
    }

    /// Pure takeover policy (CROW-747): recreate + relaunch when the cockpit
    /// session did NOT survive (reboot / server kill), adopt when it did (warm
    /// crowd restart). Split out so the decision is unit-testable without tmux.
    nonisolated static func shouldRecreateSurfacesOnTakeover(cockpitSessionIsLive: Bool) -> Bool {
        !cockpitSessionIsLive
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

    /// Heal one terminal whose tmux window is stuck with degraded scrollback —
    /// created before the current `crow-tmux.conf` so it's frozen in the
    /// alternate-screen buffer and/or capped at the old 5000-line history-limit,
    /// neither of which tmux can fix in place (CROW-804). Kills the degraded
    /// window and rebuilds a fresh, correctly-configured one (50000-line main
    /// buffer), relaunching the agent — the exact per-terminal work
    /// `rebuildAllSurfaces(forceRegister:true)` does on a cold-start takeover,
    /// applied to a single terminal on user request. Returns whether a recreate
    /// was performed (false if the terminal wasn't found).
    ///
    /// The **primary** Manager terminal has its own purpose-built recreate that
    /// preserves `managerSessionID` and re-arms the exit monitor, so it delegates
    /// to `restartManager`. Secondary Manager sessions (also `kind == .manager`,
    /// but NOT the well-known primary) fall through to the general rehydrate path
    /// — `restartManager` hard-codes `AppState.managerSessionID`, so routing them
    /// there would restart the *primary* Manager and leave the selected window
    /// untouched (review). Their command-launches-agent terminal re-runs its
    /// stored `managerCommand` via `registerTerminal` on rehydrate, healing the
    /// correct window. Recreating interrupts whatever agent is running in the
    /// window — the caller is expected to have confirmed with the user first.
    @MainActor
    @discardableResult
    public func recreateTerminalSurface(sessionID: UUID, terminalID: UUID, devRoot: String) -> Bool {
        guard appState.sessions.contains(where: { $0.id == sessionID }),
              let terminal = appState.terminals(for: sessionID).first(where: { $0.id == terminalID }) else {
            CrowLog.info("[SessionService] recreateTerminalSurface: terminal \(terminalID) not found in session \(sessionID)")
            return false
        }

        // Only the PRIMARY Manager routes to its dedicated recreate — that path
        // is keyed on the well-known managerSessionID. Everything else (work,
        // review, job, AND secondary Managers) heals via the rehydrate path.
        if Self.shouldRestartPrimaryManagerOnRecreate(sessionID: sessionID) {
            owner.restartManager(devRoot: devRoot)
            return true
        }

        wireTerminalReadiness()

        let trackReadiness = terminal.isManaged
        // Register-then-kill (review): register the fresh window FIRST and only
        // drop the old (degraded) window once the replacement is bound. On a
        // register failure the old window stays live, so the terminal remains
        // degraded-but-live (still badged + recreatable) instead of unbound with
        // a dead pane. A brief duplicate-agent overlap is the accepted cost.
        let oldIndex = terminal.tmuxBinding?.windowIndex
        // Snapshot the readiness state we're about to re-arm so a failed register
        // can restore it — otherwise a managed terminal is left half-armed
        // pointing at a window that never got created.
        let priorReadiness = appState.terminalReadiness[terminalID]
        let priorAutoLaunch = appState.autoLaunchTerminals.contains(terminalID)

        var seed = terminal
        seed.tmuxBinding = nil
        // Re-arm managed work terminals so the fresh shell's `.shellReady` drives
        // the agent relaunch via `claude --continue` (never the stored initial
        // command) — same seeding as `rebuildAllSurfaces(forceRegister:true)`.
        if trackReadiness {
            appState.terminalReadiness[terminalID] = .uninitialized
            appState.autoLaunchTerminals.insert(terminalID)
            if let cmd = seed.command, cmd.contains("claude") {
                seed.command = nil
            }
        }

        CrowLog.info("[CrowTelemetry tmux:scrollback_recreate terminal=\(terminalID) session=\(sessionID)]")
        let updated = rehydrateTerminalSurface(seed, trackReadiness: trackReadiness)

        guard updated.tmuxBinding != nil else {
            // Register failed. Leave the terminal exactly as it was — the old
            // window is untouched (still live/degraded), so restore the readiness
            // we re-armed and report failure. The RPC surfaces it and the ⚠ /
            // Recreate affordance persists for a retry (review).
            CrowLog.info("[SessionService] recreateTerminalSurface: re-register failed for \(terminalID); keeping the existing degraded window")
            if trackReadiness {
                appState.terminalReadiness[terminalID] = priorReadiness
                if !priorAutoLaunch { appState.autoLaunchTerminals.remove(terminalID) }
            }
            return false
        }

        // Replacement bound — persist the new window index, then drop the old
        // degraded window so its (now-duplicate) agent doesn't linger.
        applyRehydrationResult(sessionID: sessionID, original: seed, updated: updated)
        if let oldIndex { TmuxBackend.shared.killWindow(index: oldIndex) }
        return true
    }

    /// Pure policy (CROW-804): only the well-known **primary** Manager session
    /// routes a recreate to `restartManager`, which hard-codes
    /// `AppState.managerSessionID`. Secondary Manager sessions (created via
    /// `createManagerSession`) are also `kind == .manager` but must NOT restart
    /// the primary — they fall through to the rehydrate path. `nonisolated static`
    /// so the branch is unit-testable without a live app.
    nonisolated static func shouldRestartPrimaryManagerOnRecreate(sessionID: UUID) -> Bool {
        sessionID == AppState.managerSessionID
    }

    /// Re-hydrate one persisted terminal's tmux window on app launch. Returns
    /// the (possibly-modified) row with `tmuxBinding.windowIndex` updated to
    /// the freshly-registered window. If tmux is unavailable or registration
    /// fails, the row is returned unchanged and simply won't render this run.
    @MainActor
    private func rehydrateTerminalSurface(_ terminal: SessionTerminal, trackReadiness: Bool) -> SessionTerminal {
        guard !TmuxBackend.shared.tmuxBinary.isEmpty else {
            CrowLog.info("[SessionService] tmux not configured this run — terminal \(terminal.id) will not render")
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
                // Adopted windows were born under whatever conf was live at the
                // time, and `alternate-screen` is a per-WINDOW option that a
                // `source-file` reload does NOT retrofit. Re-apply the agent
                // scroll model here so a window predating ADR-0013 stops
                // accumulating duplicate-frame sediment once its agent next
                // enters the alt screen. Idempotent and best-effort — no live
                // agent is interrupted, so an already-running agent keeps its
                // current buffer until it restarts (the ⚠ Recreate affordance
                // remains the immediate manual path).
                let session = appState.sessions.first(where: { $0.id == terminal.sessionID })
                if terminal.isAgentSurface(session: session) {
                    TmuxBackend.shared.enableAlternateScreen(index: binding.windowIndex)
                    // history-limit is frozen at birth. CROW-1008 clamped
                    // inline agents to 0; CROW-1010 retracted that (Cursor's
                    // transcript is real scrollback). A leftover 0-limit
                    // window fails the history floor and is badged ⚠ Recreate.
                }
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
                    // Re-write the adopted session's OWN hook config so its hooks
                    // still route back to the correct session if the config was
                    // lost. Resolve the session's agent writer rather than
                    // hardcoding `ClaudeHookConfigWriter`: for a Grok session that
                    // would plant `.claude/settings.local.json`, which Grok
                    // compat-loads alongside its own `.grok/hooks/crow.json` — every
                    // event then double-fires, reverting
                    // `stripPriorCompatHooksForGrokHandoff` on the next warm crowd
                    // restart (#861 review r10). Every writer this now reaches is
                    // per-worktree and session-scoped (Cursor `.cursor/hooks.json`,
                    // OpenCode `.opencode/plugins/crow-hooks.js`, Grok
                    // `.grok/hooks/crow.json`, Antigravity `.agents/hooks.json`) or a
                    // literal no-op (Codex — its config is global, installed once at
                    // boot), so the widened write rewrites each session's own config
                    // with its own UUID — the repair, not a new risk. It also fixes
                    // an adopted Cursor/OpenCode/Antigravity session whose own config
                    // was lost, which the Claude-hardcoded version silently skipped.
                    if let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: ConfigStore.loadDevRoot()),
                       let worktree = appState.primaryWorktree(for: terminal.sessionID),
                       let session = appState.sessions.first(where: { $0.id == terminal.sessionID }),
                       let agent = AgentRegistry.shared.agent(for: session.agentKind) {
                        do {
                            try agent.hookConfigWriter.writeHookConfig(
                                worktreePath: worktree.worktreePath,
                                sessionID: terminal.sessionID,
                                crowPath: crowPath
                            )
                        } catch {
                            CrowLog.info("[SessionService] adopt: hook config rewrite failed for \(terminal.sessionID): \(error.localizedDescription)")
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
                CrowLog.info("[SessionService] tmux adopt failed (\(error)) for \(terminal.id); creating a fresh window")
            }
        }

        // No prior binding, or adoption failed (post-reboot clean slate, the
        // window was closed, or a legacy per-PID socketPath that no longer
        // matches the stable socket). Create a fresh window as before.
        do {
            let session = appState.sessions.first(where: { $0.id == terminal.sessionID })
            let binding = try TmuxBackend.shared.registerTerminal(
                id: terminal.id,
                name: terminal.name,
                cwd: terminal.cwd,
                command: terminal.command,
                trackReadiness: trackReadiness,
                agentKind: session?.agentKind,
                agentSurface: terminal.isAgentSurface(session: session),
                usesAlternateScreen: AgentRegistry.shared.usesAlternateScreen(for: session?.agentKind),
                extraEnv: Self.artifactsEnv(sessionID: terminal.sessionID)
            )
            var updated = terminal
            updated.tmuxBinding = binding
            return updated
        } catch {
            CrowLog.info("[SessionService] tmux re-register failed on hydrate (\(error)) for \(terminal.id); terminal will not render this run")
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
    /// Env handed to every session terminal so agents (and the crow-show-image
    /// skill) know where to drop images for Crow's viewer, without guessing the
    /// path or the session id (CROW-593). Shares `ArtifactPaths` with the
    /// daemon that serves them, so write path == serve path.
    nonisolated static func artifactsEnv(sessionID: UUID) -> [String: String] {
        [
            "CROW_ARTIFACTS_DIR": ArtifactPaths.dir(sessionID: sessionID).path,
            "CROW_SESSION_ID": sessionID.uuidString,
        ]
    }

    public func wireTerminalReadiness() {
        CrowLog.info("[SessionService] wireTerminalReadiness — setting tmux readiness callback")
        TmuxBackend.shared.onReadinessChanged = { [weak self] terminalID, readiness in
            guard let self else { return }
            guard let currentState = self.appState.terminalReadiness[terminalID] else { return }
            CrowLog.info("[SessionService] tmux readiness: terminal=\(terminalID), state=\(readiness), current=\(currentState)")
            if readiness == .shellReady, currentState < .shellReady {
                self.appState.terminalReadiness[terminalID] = .shellReady
                // Brand-new managed terminals created via `new-terminal --command`
                // hold their launch in `pendingLaunchCommands` and paste it HERE,
                // now that the shell's line editor is live — the race-free
                // replacement for setup.sh's old `sleep 3` + `crow send` (#408).
                // Restored/recovered terminals have no pending command and fall
                // through to `launchAgent` (rebuild via autoLaunchCommand).
                switch SessionSurfaceController.resolveLaunch(pending: self.appState.pendingLaunchCommands[terminalID]) {
                case .pastePending(let command):
                    self.owner.pasteDeferredLaunch(terminalID: terminalID, command: command)
                case .launchAgent:
                    self.owner.launchAgent(terminalID: terminalID)
                }
            } else if readiness == .timedOut, currentState < .shellReady {
                // First-prompt watch expired. Do NOT advance to .shellReady or
                // auto-paste — the shell may still be starting and a paste now
                // can land in a pane without a live line editor. The UI shows
                // a Retry affordance; `didBecomeActive` also re-arms us
                // automatically when the app returns to the foreground.
                self.appState.terminalReadiness[terminalID] = .timedOut
            }
            self.clearCrashRecoveryFlagIfSettled()
        }
    }

    /// End the "tmux server crashed — reconnecting…" state once every tracked
    /// terminal has settled (reached `.shellReady`/beyond, or `.timedOut` —
    /// which then shows the normal Retry overlay in its crash flavor) (#588).
    @MainActor
    private func clearCrashRecoveryFlagIfSettled() {
        guard appState.tmuxCrashRecovering else { return }
        let stillPending = appState.terminalReadiness.values.contains {
            $0 == .uninitialized || $0 == .surfaceCreated
        }
        if !stillPending {
            appState.tmuxCrashRecovering = false
            crashRecoveryClearFallback?.cancel()
            crashRecoveryClearFallback = nil
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

    /// Re-arm the tmux readiness watch for a terminal whose first attempt
    /// timed out. Reverts AppState back to `.surfaceCreated` so the UI
    /// transitions out of the Retry overlay, and starts a longer-budget
    /// watch on the backend. Leaves the terminal in `autoLaunchTerminals`
    /// so a successful sentinel fire still triggers `launchAgent`.
    public func retryReadiness(terminalID: UUID) {
        guard let current = appState.terminalReadiness[terminalID] else { return }
        guard current == .timedOut || current < .shellReady else { return }
        appState.terminalReadiness[terminalID] = .surfaceCreated
        TmuxBackend.shared.retryReadinessWatch(id: terminalID)
    }

    /// Capture a stage-by-stage diagnostic bundle for `terminalID` (wrapper
    /// log, pane capture, ps tree, sentinel state) and copy it to the
    /// clipboard so a teammate hitting the .timedOut state can paste it
    /// into a comment without screenshot-archaeology (issue #256).
    public func copyDiagnostics(terminalID: UUID) {
        let bundle = TmuxBackend.shared.captureDiagnostics(id: terminalID)
        hostBridge.copyToClipboard(bundle)
        CrowLog.info("[SessionService] copied tmux diagnostics for terminal=\(terminalID) bytes=\(bundle.utf8.count)")
    }

    /// Reap leaked orphan cockpit windows once at launch — bare-shell windows
    /// that no persisted terminal references (#408). The keep-set is built from
    /// the persisted terminals' window bindings; `reapUnboundCockpitWindows`
    /// additionally unions the in-memory bindings, so a window adopted or freshly
    /// registered this run is never reaped. Call AFTER the async per-terminal
    /// rehydration has settled. Safe: never reaps a window running an agent.
    @MainActor
    public func reapOrphanedCockpitWindows() {
        let keep = Set(appState.terminals.values.flatMap { $0 }.compactMap { $0.tmuxBinding?.windowIndex })
        let n = TmuxBackend.shared.reapUnboundCockpitWindows(keepWindowIndices: keep)
        if n > 0 { CrowLog.info("[SessionService] reaped \(n) orphaned cockpit window(s) at launch (#408)") }
    }

    /// Reconcile persisted terminals ↔ live cockpit tmux windows (CROW-581).
    /// (1) Prune terminal records whose bound tmux window is gone — from BOTH
    ///     `appState` and the store, else the store-reload poll resurrects a
    ///     terminal the user can't attach to. (2) Reap orphaned cockpit windows
    ///     that no terminal references (targeted-auto: forgotten bare shells +
    ///     recognized agent windows after a one-pass grace, never a Manager).
    /// Idempotent; meant to run at takeover and on a periodic tick. crowd owns
    /// this because the desktop app is now a client (ADR 0007).
    @MainActor
    public func reconcileTerminalSurfaces() {
        let liveIndices = Set(TmuxBackend.shared.listCockpitWindows().map(\.index))
        guard !liveIndices.isEmpty else { return }   // tmux read failed → don't prune blindly

        // (1) Prune dead terminal records.
        var deadIDs: [UUID] = []
        for (sessionID, terminals) in appState.terminals {
            var alive: [SessionTerminal] = []
            for t in terminals {
                if let idx = t.tmuxBinding?.windowIndex, !liveIndices.contains(idx) {
                    deadIDs.append(t.id)
                } else {
                    alive.append(t)
                }
            }
            if alive.count != terminals.count {
                appState.terminals[sessionID] = alive.isEmpty ? nil : alive
            }
        }
        if !deadIDs.isEmpty {
            let dead = Set(deadIDs)
            store.mutate { $0.terminals.removeAll { dead.contains($0.id) } }
            CrowLog.info("[SessionService] pruned \(deadIDs.count) dead terminal record(s) (CROW-581)")
        }

        // (2) Reap orphaned cockpit windows. Agent window names are exactly what
        // `new-terminal` pins on managed agent windows, so orphaned agents are
        // identified positively and the anchor/infra is never touched.
        let keep = Set(appState.terminals.values.flatMap { $0 }.compactMap { $0.tmuxBinding?.windowIndex })
        // Derive the agent-window-name set from the registry (windows are pinned
        // with the agent's `displayName` — `registerTerminal` → `newWindow(name:)`,
        // and on handoff `target.displayName`), unioned with the registration-
        // independent `CrowAttribution.allKnownDisplayNames`. The union keeps both
        // properties (#861 review r9-r10): registry covers any downstream-only kind
        // not in the static table, and the static table still matches a built-in
        // kind whose binary later stopped resolving (uninstalled / mid-upgrade /
        // shim dir dropped from the login-shell PATH) — whose orphaned pane the
        // registry alone would miss. No per-kind edit here either way; mirrors the
        // cross-agent cleanup loop in `writeManagerHookConfig`.
        let agentNames = CrowAttribution.allKnownDisplayNames
            .union(AgentRegistry.shared.allAgents().map(\.displayName))
        TmuxBackend.shared.reconcileOrphanWindows(keepWindowIndices: keep, agentWindowNames: agentNames)
    }

    /// Re-arm any tmux readiness watches that have stalled while the app
    /// was backgrounded. Called from `NSApplication.didBecomeActiveNotification`
    /// so a user who returns to a long-idle app doesn't have to click
    /// Retry on every review session.
    public func reArmStuckReadinessWatches() {
        for (terminalID, state) in appState.terminalReadiness {
            guard appState.autoLaunchTerminals.contains(terminalID) else { continue }
            guard state == .timedOut else { continue }
            CrowLog.info("[SessionService] re-arming stuck tmux readiness watch for terminal=\(terminalID)")
            retryReadiness(terminalID: terminalID)
        }
    }

    /// Tear down the tmux server and rebuild every terminal surface from
    /// scratch. Manual recovery for a wedged/leaked cockpit session (#375):
    /// kills the server — every pane's claude included — then re-registers a
    /// fresh window and relaunches claude for every persisted terminal across
    /// all sessions (Manager via its stored command, work sessions via
    /// `claude --continue`). The destructive teardown is guarded by a
    /// confirmation alert in `AppDelegate.restartTmuxServer`.
    @MainActor
    public func restartTmuxServer() {
        CrowLog.info("[CrowTelemetry tmux:server_restart_by_user]")
        // A manual restart supersedes any in-flight crash recovery — clear the
        // flag so the crash overlay doesn't linger over the user-driven rebuild.
        appState.tmuxCrashRecovering = false
        recycleTmuxServerAndRebuild()
    }

    /// Shared server-recycle routine: tear down the tmux server and rebuild
    /// every terminal surface + agent from scratch. Used by the manual menu
    /// path (`restartTmuxServer`) and crash auto-recovery (#588).
    @MainActor
    private func recycleTmuxServerAndRebuild() {
        let savedSelection = appState.selectedSessionID
        let savedActive = appState.activeTerminalID

        // kill-server + unlink scratch/sentinel files. The first registerTerminal
        // in rebuildAllSurfaces lazily recreates the controller + cockpit session
        // via ensureRunningServer, so no explicit reconfigure is needed.
        TmuxBackend.shared.shutdown(killServer: true)

        rebuildAllSurfaces(forceRegister: true)

        // A full server restart relaunches a fresh Manager agent, so clear any
        // showing exit banner — mirrors `restartManager` (#558). The re-arm's
        // `!managerProcessExited` guard only blocks re-firing, it can't clear a
        // stale flag, so an already-visible banner would otherwise persist over
        // a healthy Manager.
        appState.managerProcessExited = false

        // `shutdown` cancelled the exit monitor and `rebuildAllSurfaces` doesn't
        // route through `ensureManagerSession`, so re-arm it here (#558).
        owner.armManagerExitMonitor()

        // Re-assign selection (even to the same values) to force the UI to
        // re-render and re-attach a fresh tmux client after the rebuild;
        // preserves focus.
        appState.selectedSessionID = savedSelection
        appState.activeTerminalID = savedActive
    }

    // MARK: - tmux crash auto-recovery (#588)

    /// The cockpit attach client exited on its own. Probe the server: dead →
    /// full crash recovery; alive (user detach / client-only death) → just
    /// recreate the attach surface and leave every window running.
    @MainActor
    public func handleCockpitClientExit() {
        guard !appState.tmuxCrashRecovering else { return }
        if TmuxBackend.shared.isRunning {
            CrowLog.info("[CrowTelemetry tmux:cockpit_client_reattach]")
            TmuxBackend.shared.recycleCockpitSurface()
            // Same re-render trick as recycleTmuxServerAndRebuild: a
            // same-value reassignment forces the UI to re-render and re-attach
            // a fresh tmux client.
            let savedSelection = appState.selectedSessionID
            let savedActive = appState.activeTerminalID
            appState.selectedSessionID = savedSelection
            appState.activeTerminalID = savedActive
        } else {
            handleTmuxServerCrash()
        }
    }

    /// The tmux server died mid-run. Automatically re-register every terminal
    /// window and relaunch each session's agent — work/review/job sessions
    /// resume via `claude --continue` (their initial prompt was already
    /// dispatched and is never re-pasted); a terminal still holding its
    /// never-dispatched launch in `pendingLaunchCommands` pastes it exactly
    /// once, as on first creation. No per-session user clicks required (#588).
    @MainActor
    public func handleTmuxServerCrash() {
        guard !appState.tmuxCrashRecovering else { return }
        if let last = lastCrashRecoveryAt, Date().timeIntervalSince(last) < 10 {
            CrowLog.info("[CrowTelemetry tmux:server_crash_recovery_debounced]")
            return
        }
        lastCrashRecoveryAt = Date()
        CrowLog.info("[CrowTelemetry tmux:server_crash_autorecovery]")
        // Set the flag BEFORE shutdown: the subprocess waits inside the rebuild
        // pump the main run loop, so a re-entrant crash signal during recovery
        // must find the guard already up.
        appState.tmuxCrashRecovering = true
        recycleTmuxServerAndRebuild()

        // Belt-and-braces: if no readiness callback ever settles the flag
        // (nothing was re-registered), don't leave the crash overlay up forever.
        crashRecoveryClearFallback?.cancel()
        crashRecoveryClearFallback = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.appState.tmuxCrashRecovering {
                CrowLog.info("[CrowTelemetry tmux:server_crash_recovery_timeout]")
                self.appState.tmuxCrashRecovering = false
            }
        }
    }
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    public func hydrateState() { surfaces.hydrateState() }
    public func adoptExistingSurfaces() { surfaces.adoptExistingSurfaces() }
    public func rebuildAllSurfaces(forceRegister: Bool = false) {
        surfaces.rebuildAllSurfaces(forceRegister: forceRegister)
    }

    @discardableResult
    public func takeOverTerminalSurfaces() -> Bool { surfaces.takeOverTerminalSurfaces() }

    @discardableResult
    public func recreateTerminalSurface(sessionID: UUID, terminalID: UUID, devRoot: String) -> Bool {
        surfaces.recreateTerminalSurface(sessionID: sessionID, terminalID: terminalID, devRoot: devRoot)
    }

    public func wireTerminalReadiness() { surfaces.wireTerminalReadiness() }
    public func retryReadiness(terminalID: UUID) { surfaces.retryReadiness(terminalID: terminalID) }
    public func copyDiagnostics(terminalID: UUID) { surfaces.copyDiagnostics(terminalID: terminalID) }
    public func reapOrphanedCockpitWindows() { surfaces.reapOrphanedCockpitWindows() }
    public func reconcileTerminalSurfaces() { surfaces.reconcileTerminalSurfaces() }
    public func reArmStuckReadinessWatches() { surfaces.reArmStuckReadinessWatches() }
    public func restartTmuxServer() { surfaces.restartTmuxServer() }
    public func handleCockpitClientExit() { surfaces.handleCockpitClientExit() }
    public func handleTmuxServerCrash() { surfaces.handleTmuxServerCrash() }

    /// Pure takeover policy (see `SessionSurfaceController.shouldRecreateSurfacesOnTakeover`).
    nonisolated static func shouldRecreateSurfacesOnTakeover(cockpitSessionIsLive: Bool) -> Bool {
        SessionSurfaceController.shouldRecreateSurfacesOnTakeover(cockpitSessionIsLive: cockpitSessionIsLive)
    }

    /// Pure recreate policy (see `SessionSurfaceController.shouldRestartPrimaryManagerOnRecreate`).
    nonisolated static func shouldRestartPrimaryManagerOnRecreate(sessionID: UUID) -> Bool {
        SessionSurfaceController.shouldRestartPrimaryManagerOnRecreate(sessionID: sessionID)
    }

    /// Env handed to every session terminal (see `SessionSurfaceController.artifactsEnv`).
    nonisolated static func artifactsEnv(sessionID: UUID) -> [String: String] {
        SessionSurfaceController.artifactsEnv(sessionID: sessionID)
    }
}
