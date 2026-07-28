import Foundation
import CrowClaude
import CrowCodex
import CrowCore
import CrowCursor
import CrowGit
import CrowPersistence
import CrowProvider
import CrowTerminal

/// Simplified session service — CRUD only. Orchestration moved to Claude Code via crow CLI.
@MainActor
public final class SessionService {
    private let store: JSONStore
    private let appState: AppState
    public let telemetryPort: UInt16?
    /// Backend factory for ticket/PR lookups during recovery. Optional so unit-tests
    /// that don't exercise recovery paths needn't construct one. See ADR 0005.
    private let providerManager: ProviderManager?
    /// Fresh session aggregate from telemetry.db, used when persisting the
    /// end-of-session analytics snapshot (#690). Optional so unit tests and
    /// telemetry-off launches fall back to the in-memory aggregate.
    private let analyticsProvider: (@Sendable (UUID) async -> SessionAnalytics?)?
    /// Crow session IDs with telemetry rows in telemetry.db, driving the
    /// snapshot backfill (#745). Optional so unit tests and telemetry-off
    /// launches make the backfill a no-op.
    private let telemetrySessionIDsProvider: (@Sendable () async -> [UUID])?
    /// Windowed Manager-session aggregate from telemetry.db for the ungraded
    /// weekly usage bucket (#745). Optional for the same reason.
    private let managerUsageProvider: (@Sendable (Date, Date) async -> SessionAnalytics)?
    /// Drops a session's rows from telemetry.db as part of `deleteSession`
    /// (#772). Injected here rather than at each call site so all three delete
    /// paths — the daemon's `delete-session` handler, the engine-router
    /// fallback, and the auto-cleanup reaper — clean up through one choke
    /// point. Optional: telemetry-off hosts and unit tests pass nil.
    private let telemetryDeleteProvider: (@Sendable (UUID) async -> Void)?
    /// Host-only affordances (clipboard, editor/terminal launching, hook
    /// notifications). Defaults to a headless no-op so tests and the daemon
    /// need not supply one; the macOS app injects a real `AppHostBridge`.
    private let hostBridge: HostBridge

    public init(
        store: JSONStore,
        appState: AppState,
        telemetryPort: UInt16? = nil,
        providerManager: ProviderManager? = nil,
        analyticsProvider: (@Sendable (UUID) async -> SessionAnalytics?)? = nil,
        telemetrySessionIDsProvider: (@Sendable () async -> [UUID])? = nil,
        managerUsageProvider: (@Sendable (Date, Date) async -> SessionAnalytics)? = nil,
        telemetryDeleteProvider: (@Sendable (UUID) async -> Void)? = nil,
        hostBridge: HostBridge = NoopHostBridge()
    ) {
        self.store = store
        self.appState = appState
        self.telemetryPort = telemetryPort
        self.providerManager = providerManager
        self.analyticsProvider = analyticsProvider
        self.telemetrySessionIDsProvider = telemetrySessionIDsProvider
        self.managerUsageProvider = managerUsageProvider
        self.telemetryDeleteProvider = telemetryDeleteProvider
        self.hostBridge = hostBridge
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

    /// One-time backfill of `reviewAuthor` for legacy review sessions that
    /// predate the field. For each review session missing an author, re-fetch it
    /// from the PR (via the stored `.pr` link) and persist. Runs detached and is
    /// idempotent — after the first fill the value is on disk (CROW-593).
    private func backfillReviewAuthors() {
        guard let manager = providerManager else { return }
        let targets: [(id: UUID, url: String)] = appState.sessions.compactMap { session in
            guard session.kind == .review, (session.reviewAuthor ?? "").isEmpty,
                  let link = store.data.links.first(where: { $0.sessionID == session.id && $0.linkType == .pr })
            else { return nil }
            return (session.id, link.url)
        }
        guard !targets.isEmpty else { return }
        Task { @MainActor in
            for target in targets {
                guard let backend = manager.codeBackend(for: .github),
                      let meta = try? await backend.fetchPRMetadata(prURL: target.url),
                      !meta.author.isEmpty else { continue }
                if let i = appState.sessions.firstIndex(where: { $0.id == target.id }) {
                    appState.sessions[i].reviewAuthor = meta.author
                }
                store.mutate { data in
                    if let i = data.sessions.firstIndex(where: { $0.id == target.id }) {
                        data.sessions[i].reviewAuthor = meta.author
                    }
                }
            }
        }
    }

    // MARK: - Hydrate State from Store

    public func hydrateState() {
        let data = store.data
        appState.sessions = data.sessions
        // Mirror persisted analytics snapshots for the scorecard (#710) —
        // CrowUI can't read the store, so the view computes from this.
        appState.analyticsSnapshots = data.analyticsSnapshots ?? [:]
        // Same for PR attributions: the v2 combined score's hygiene factor
        // (#699) reads this mirror; IssueTracker resyncs it after writes.
        appState.prAttributions = data.prAttributions ?? [:]
        // And the Manager weekly usage rollups (#745) for the ungraded bucket.
        appState.managerUsageWeekly = data.managerUsageWeekly ?? [:]

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
                let detected = Validation.detectProviderFromURL(url)
                appState.sessions[i].provider = detected
                // Task-only trackers (Jira/Corveil) have no code backend — pair
                // with the workspace's code provider so PR/git flows resolve.
                if appState.sessions[i].codeProvider == nil, detected?.isTaskOnly == true {
                    let wtPath = appState.worktrees[appState.sessions[i].id]?
                        .first(where: { $0.isPrimary })?.worktreePath
                        ?? appState.worktrees[appState.sessions[i].id]?.first?.worktreePath
                    appState.sessions[i].codeProvider = Self.resolvedCodeProvider(forTask: detected, worktreePath: wtPath)
                }
            }
        }

        // One-time backfill: legacy review sessions were persisted before
        // `reviewAuthor` existed, so they show no author when the Reviews board
        // is empty. Re-fetch it from the PR and persist, once (CROW-593).
        backfillReviewAuthors()

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
                let rebuiltCommand = managerCommand(for: reconciled)
                // CROW-539: (re)write the Manager's hook config on every launch.
                // The Manager terminal is adopted here, not recreated, so
                // createManagerTerminal's hook write doesn't run — without this a
                // Manager whose terminal predates the hooks never emits events and
                // its card never lights up. Write to the terminal's own cwd so an
                // additional Manager running outside the dev root is covered too.
                // Before writeManagerGatewayEnv() so its 0o600 re-apply is last.
                if let managerCwd = terminals.first?.cwd {
                    writeManagerHookConfig(for: reconciled, dirPath: managerCwd)
                    // CROW-600: pre-trust the Manager's cwd so a devRoot the
                    // user hasn't opened Claude Code in before doesn't block
                    // on the trust dialog. No-ops when already trusted.
                    if reconciled.agentKind == .claudeCode {
                        ClaudeTrustSeeder.seedTrust(projectPath: managerCwd)
                    }
                }
                writeManagerGatewayEnv()
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
                Task { @MainActor in
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
            restartManager(devRoot: devRoot)
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
                    // Re-write hook config so the adopted Claude's hooks still
                    // route back to the correct session if the config was lost.
                    if let crowPath = ClaudeHookConfigWriter.findCrowBinary(devRoot: ConfigStore.loadDevRoot()),
                       let worktree = appState.primaryWorktree(for: terminal.sessionID) {
                        do {
                            try ClaudeHookConfigWriter().writeHookConfig(
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
            CrowLog.info("[SessionService] pasteDeferredLaunch: no terminal record for \(terminalID); cannot send")
            return
        }

        // Apply the same prep the legacy `crow send` path got from the `send`
        // RPC (hook config + OTEL env vars) so hooks route back to this session
        // and Claude telemetry is exported — via the shared helper so the two
        // launch paths never drift.
        var text = command
        if let session = appState.sessions.first(where: { $0.id == sessionID }),
           let agent = AgentRegistry.shared.agent(for: session.agentKind) {
            text = AgentLaunch.prepareAgentLaunchText(
                command: command,
                agent: agent,
                sessionID: sessionID,
                worktreePath: appState.primaryWorktree(for: sessionID)?.worktreePath,
                crowPath: ClaudeHookConfigWriter.findCrowBinary(devRoot: ConfigStore.loadDevRoot()),
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
        let agentNames = Set([AgentKind.claudeCode, .cursor, .codex, .openCode, .antigravity]
            .map { CrowAttribution.agentDisplayName(for: $0) })
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

    /// Auto-launch the session's coding agent in `terminalID`. Dispatches via
    /// the registered `CodingAgent` for the session's `agentKind`, which
    /// builds both the hook configuration and the launch command.
    public func launchAgent(terminalID: UUID) {
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
        if let crowPath = ClaudeHookConfigWriter.findCrowBinary(devRoot: ConfigStore.loadDevRoot()) {
            do {
                try agent.hookConfigWriter.writeHookConfig(
                    worktreePath: worktree.worktreePath,
                    sessionID: sessionID,
                    crowPath: crowPath
                )
            } catch {
                CrowLog.info("[SessionService] Failed to write hook config for session \(sessionID.uuidString): \(error.localizedDescription)")
            }
        }

        // Pre-trust the worktree so the agent's "do you trust this folder?"
        // gate never blocks an unattended auto-launch. Trust does not inherit
        // from parent directories, so every fresh worktree/clone would
        // otherwise prompt (CROW-600 for Claude; #830 for Codex — persist trust
        // for this worktree, never `--dangerously-bypass`).
        switch agent.kind {
        case .claudeCode:
            ClaudeTrustSeeder.seedTrust(projectPath: worktree.worktreePath)
        case .codex:
            // Never trust a `.review` clone: its working tree is `gh repo clone`
            // output checked out at the PR author's head — attacker-controlled.
            // Trusting it would arm a committed `.codex/hooks.json` on launch
            // (#843 review round 5). `prepareReviewClone` also strips any
            // committed `.codex/` as defense-in-depth. Crow-created `.work`/
            // `.job` worktrees branch off a trusted base, so they're safe to
            // trust; the review clone falls back to Codex's folder-trust prompt
            // (acceptable — review is the human-gated path anyway).
            if session.kind != .review {
                if case let .failed(msg) = CodexTrustSeeder.seedTrust(projectPath: worktree.worktreePath) {
                    CrowLog.info("[SessionService] Codex trust seed failed for \(worktree.worktreePath): \(msg)")
                }
            }
        default:
            break
        }

        // Resolve and apply the workspace's AI gateway for Claude sessions
        // (CROW-402). Write the resolved env block into the worktree's
        // settings.local.json so manual `claude` re-runs inherit it, and build a
        // launch-line prefix for the initial launch. Always called (resolved or
        // nil) so switching a workspace off its gateway clears the stale env
        // keys. Gated to the Claude agent — the ANTHROPIC_* vars are
        // Claude-specific; the Manager uses `managerGateway` instead.
        var gatewayPrefix = ""
        if agent.kind == .claudeCode {
            let gatewayResolved = workspaceGatewayResolved(for: sessionID)
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: worktree.worktreePath, resolved: gatewayResolved)
            gatewayPrefix = ClaudeLaunchArgs.gatewayEnvPrefix(gatewayResolved)
        }
        // Cursor worker launching → ensure its global Jira MCP is synced.
        if agent.kind == .cursor {
            syncCursorMCPBridge()
        }

        let rcEnabled = appState.remoteControlEnabled
        // Jobs are unattended, so opt-in (default-on) auto-permission mode lets
        // their prompts run crow/gh/git without per-call approval. Review
        // sessions get the same default-on treatment via
        // reviewAutoPermissionMode so a kicked-off review runs its prompt flow
        // unattended. Work coder views get auto mode only via the opt-in
        // (default-off) coderViewAutoPermissionMode toggle (#586). The Manager
        // has its own managerAutoPermissionMode path and is unaffected here.
        let autoPermissionMode =
            (session.kind == .job && appState.jobsAutoPermissionMode) ||
            (session.kind == .review && appState.reviewAutoPermissionMode) ||
            (session.kind == .work && appState.coderViewAutoPermissionMode)
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
            CrowLog.info("[SessionService] Agent \(agent.kind.rawValue) could not build a launch command for session \(sessionID.uuidString) (kind=\(String(describing: session.kind)))")
            // Surface the failure where the user is already looking — paste a
            // shell-comment + echo line into the terminal so they aren't stuck
            // staring at an idle prompt wondering why nothing happened (#424).
            if let routedTerminal = appState.terminals[sessionID]?.first(where: { $0.id == terminalID }) {
                let msg = "echo '⚠️  Crow: agent \"\(agent.displayName)\" cannot launch a "
                    + "\(session.kind.rawValue) session. Switch the agent for this action type "
                    + "(Settings → General, or: crow agents set --\(session.kind.rawValue) <kind>) "
                    + "or pick a session kind this agent supports.'\n"
                TerminalRouter.send(routedTerminal, text: msg)
            }
            // Park readiness so the deferred-launch loop doesn't keep retrying.
            appState.terminalReadiness[terminalID] = .agentLaunched
            return
        }
        // Preflight (CROW-439): review/job sessions inline their initial prompt
        // via `$(cat .crow-*-prompt.md)`. If that file isn't on disk when the
        // shell substitution runs, the agent launches with an empty string and
        // silently idles. Refuse to dispatch and surface the missing path
        // instead so the user sees why nothing happened.
        if reviewPromptJustDispatched,
           let initialPromptFile = Self.initialPromptFileName(for: session.kind) {
            let promptPath = (worktree.worktreePath as NSString)
                .appendingPathComponent(initialPromptFile)
            if !FileManager.default.fileExists(atPath: promptPath) {
                CrowLog.info("[SessionService] launchAgent: initial prompt missing at \(promptPath) for session \(sessionID.uuidString); refusing to dispatch")
                if let routedTerminal = appState.terminals[sessionID]?.first(where: { $0.id == terminalID }) {
                    let msg = "echo '⚠️  Crow: \(session.kind.rawValue) prompt missing at \(promptPath); not launching \(agent.displayName).'\n"
                    TerminalRouter.send(routedTerminal, text: msg)
                }
                appState.terminalReadiness[terminalID] = .agentLaunched
                return
            }
        }

        // Route through TerminalRouter so tmux-backed terminals get the text
        // via tmux send-keys. The gateway prefix (empty for non-Claude agents)
        // is prepended here so it composes in front of any OTEL `export … &&`
        // prefix the agent baked into `command` (CROW-402).
        if let routedTerminal = appState.terminals[sessionID]?.first(where: { $0.id == terminalID }) {
            TerminalRouter.send(routedTerminal, text: gatewayPrefix + command)
        } else {
            CrowLog.info("[SessionService] launchAgent: no terminal record for \(terminalID); cannot send")
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

    public func ensureManagerSession(devRoot: String) {
        let managerID = AppState.managerSessionID
        // Configured Manager agent — used both for new sessions and to
        // refresh an existing Manager whose agent setting changed across
        // launches (CROW-433). The running tmux terminal is left alone; the
        // updated `agentKind` is picked up on next Manager respawn.
        let configuredKind = appState.agentKind(for: .manager)
        if let existingIdx = appState.sessions.firstIndex(where: { $0.id == managerID }) {
            // Defense-in-depth: `hydrateState` already migrates a legacy `.work`
            // primary Manager before this runs, but migrate here too in case the
            // session was created/mutated via another path.
            if Self.migrateLegacyManagerKind(&appState.sessions) {
                store.mutate { data in
                    _ = Self.migrateLegacyManagerKind(&data.sessions)
                }
            }
            // Pick up agent-setting changes for next respawn.
            if appState.sessions[existingIdx].agentKind != configuredKind {
                appState.sessions[existingIdx].agentKind = configuredKind
                store.mutate { data in
                    if let i = data.sessions.firstIndex(where: { $0.id == managerID }) {
                        data.sessions[i].agentKind = configuredKind
                    }
                }
            }
        } else {
            let manager = Session(
                id: managerID,
                name: "Manager",
                status: .active,
                kind: .manager,
                agentKind: configuredKind
            )
            appState.sessions.insert(manager, at: 0)

            store.mutate { data in
                if !data.sessions.contains(where: { $0.id == managerID }) {
                    data.sessions.insert(manager, at: 0)
                }
            }
        }

        // Ensure manager has a terminal
        if appState.terminals(for: managerID).isEmpty,
           let session = appState.sessions.first(where: { $0.id == managerID }) {
            createManagerTerminal(session: session, cwd: devRoot)
        }

        // Select Manager on launch (selectedSessionID isn't persisted)
        if appState.selectedSessionID == nil {
            appState.selectedSessionID = managerID
        }

        // (Re)arm the exit monitor so the "Manager process exited" banner
        // reappears under the shared xterm.js cockpit (#558). Covers fresh
        // launch, hydrate/adopt relaunch, and `restartManager` (which routes
        // back through here).
        armManagerExitMonitor()
    }

    /// Start the `TmuxBackend` poll that flips `appState.managerProcessExited`
    /// when the Manager's agent process exits (#558). Idempotent — the backend
    /// cancels any prior monitor. No-op until the Manager terminal row exists;
    /// the poll itself tolerates the tmux binding being registered slightly
    /// later by the async `rebuildAllSurfaces` adopt path.
    private func armManagerExitMonitor() {
        let managerID = AppState.managerSessionID
        guard let managerTerminal = appState.terminals(for: managerID).first else { return }
        TmuxBackend.shared.startManagerExitMonitor(id: managerTerminal.id) { [weak self] in
            guard let self, !self.appState.managerProcessExited else { return }
            self.appState.managerProcessExited = true
        }
    }

    /// Relaunch the Manager's `claude` process in place after it has exited
    /// (crash, kill, OOM). The Manager session row and `AppState.managerSessionID`
    /// are preserved — only the dead terminal/surface is torn down and replaced.
    ///
    /// Tears down the existing terminal surface, drops the stale terminal row from
    /// both memory and disk, clears the exited flag, then re-runs
    /// `ensureManagerSession` which recreates a fresh Manager terminal (new
    /// terminal UUID) using the current remote-control / auto-permission args.
    public func restartManager(devRoot: String) {
        let managerID = AppState.managerSessionID
        let terminals = appState.terminals(for: managerID)
        // Fall back to a dead terminal's cwd if the caller's devRoot is empty.
        let resolvedDevRoot = devRoot.isEmpty ? (terminals.first?.cwd ?? devRoot) : devRoot

        // Stop the exit monitor before tearing down the window so the imminent
        // kill-window isn't mistaken for anything, and the fresh agent launch
        // is observed from scratch. `ensureManagerSession` re-arms it (#558).
        TmuxBackend.shared.stopManagerExitMonitor()

        for terminal in terminals {
            TerminalRouter.destroy(terminal)
        }
        appState.terminals.removeValue(forKey: managerID)
        appState.remoteControlActiveTerminals.subtract(terminals.map(\.id))
        store.mutate { data in
            data.terminals.removeAll { $0.sessionID == managerID }
        }

        appState.managerProcessExited = false
        CrowLog.info("[CrowTelemetry manager:restart]")

        // Session row still exists, so this only recreates the terminal.
        ensureManagerSession(devRoot: resolvedDevRoot)
    }

    /// Switch a non-Manager session to a different coding agent mid-flight
    /// (CROW-627). Preserves session identity, worktrees, ticket, and links;
    /// tears down managed agent terminals and recreates one seeded with a
    /// handoff prompt. Conversation history does not transfer across agents.
    ///
    /// Unmanaged "Shell" tabs are left alone. Manager sessions must use
    /// Settings + `restartManager` instead.
    @MainActor
    @discardableResult
    public func handoffAgent(
        sessionID: UUID,
        to targetKind: AgentKind,
        note: String? = nil
    ) async throws -> UUID {
        guard let sessionIdx = appState.sessions.firstIndex(where: { $0.id == sessionID }) else {
            throw AgentHandoffError.sessionNotFound
        }
        var session = appState.sessions[sessionIdx]
        guard !session.isManager else {
            throw AgentHandoffError.managerNotSupported
        }
        let priorKind = session.agentKind
        guard priorKind != targetKind else {
            throw AgentHandoffError.sameAgent
        }
        guard let target = AgentRegistry.shared.agent(for: targetKind) else {
            throw AgentHandoffError.agentNotRegistered(targetKind.rawValue)
        }
        guard target.findBinary() != nil else {
            throw AgentHandoffError.agentBinaryMissing(targetKind.rawValue)
        }
        // Refuse handing a *review* session off to Antigravity. Review is
        // unsupported on this Tier-2 harness (`autoLaunchCommand(.review)` → nil),
        // and the handoff path launches via `AntigravityLauncher.launchCommand`
        // (`agy -p …`) regardless — which would start `agy` inside the review
        // clone. A hostile PR head can commit `.agents/hooks.json` with arbitrary
        // command hooks that Antigravity runs with **no approval gate**, and
        // Crow's git-tracked guard then declines to overwrite that committed file
        // (leaving the attacker's hooks live) — i.e. RCE on the reviewer's
        // machine. Unlike Cursor/Codex (which support review and strip
        // `.cursor/`/`.codex/` + trust-gate), Antigravity has no legitimate
        // review launch, so refusing the handoff outright closes the vector at
        // its source rather than relying on a strip. `prepareReviewClone` also
        // strips `.agents/` for Antigravity review clones as defense-in-depth.
        guard !Self.shouldRefuseReviewHandoff(targetKind: targetKind, sessionKind: session.kind) else {
            throw AgentHandoffError.reviewNotSupported(targetKind.rawValue)
        }
        guard let worktree = appState.primaryWorktree(for: sessionID) else {
            throw AgentHandoffError.noWorktree
        }
        let worktrees = appState.worktrees(for: sessionID)

        // Build the handoff prompt + launch command *before* mutating session
        // state or destroying terminals. `launchCommand` writes a temp prompt
        // file and can throw on I/O failure — leaving the prior agent running
        // is far better than a flipped agentKind with no managed pane (review).
        let prompt = await AgentHandoff.buildPrompt(
            from: priorKind,
            to: target,
            session: session,
            worktrees: worktrees,
            note: note
        )
        let launchCommand: String
        do {
            launchCommand = try await target.launchCommand(
                sessionID: sessionID,
                worktreePath: worktree.worktreePath,
                prompt: prompt
            )
        } catch {
            throw AgentHandoffError.launchFailed(error.localizedDescription)
        }

        // Agent-specific prep (trust + gateway) before the new process starts.
        // Idempotent file writes — safe to run before teardown.
        if target.kind == .claudeCode {
            ClaudeTrustSeeder.seedTrust(projectPath: worktree.worktreePath)
            let gatewayResolved = workspaceGatewayResolved(for: sessionID)
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: worktree.worktreePath, resolved: gatewayResolved)
        } else if target.kind == .codex, session.kind != .review {
            // Seed Codex trust on handoff too, or `crow handoff-agent --agent
            // codex` opens in an untrusted folder and the (possibly unattended)
            // session stalls on the folder-trust gate (#843 review round 5).
            // Handoff dispatches via `pendingLaunchCommands`, so `launchAgent`'s
            // seeding never fires for it. Skip `.review` for the same
            // attacker-controlled-clone reason as `launchAgent`.
            if case let .failed(msg) = CodexTrustSeeder.seedTrust(projectPath: worktree.worktreePath) {
                CrowLog.info("[SessionService] Codex trust seed failed for \(worktree.worktreePath): \(msg)")
            }
        }
        // Handing off to Cursor → sync its global Jira MCP (this path selects
        // Cursor without touching config, so the boot-time gate would miss it).
        if target.kind == .cursor {
            // Neutralize the review clone's committed `.cursor/` FIRST (#829
            // review round 10, Red 1). `prepareReviewClone` strips it only when
            // Cursor is the *creation-time* review agent; a handoff flips a
            // review session created under Claude/Codex/OpenCode to Cursor in a
            // clone that was never stripped, so without this the attacker's
            // `.cursor/hooks.json` fires on the very first handoff launch (hooks
            // have no approval gate) and its `.cursor/mcp.json` is auto-trusted
            // on the next relaunch. Mirrors the Codex handoff arm's
            // `session.kind != .review` reasoning above, applied to Cursor's
            // config layer rather than its trust seed.
            if Self.shouldStripCursorReviewCloneOnHandoff(
                targetKind: target.kind, sessionKind: session.kind) {
                Self.stripCursorConfigFromReviewClone(clonePath: worktree.worktreePath)
            }
            syncCursorMCPBridge()
        }

        // Persist the new agent only after launch prep succeeds so register /
        // attribution / hooks all see the target kind, and a failed build
        // leaves the prior agent untouched.
        session.agentKind = targetKind
        session.updatedAt = Date()
        appState.sessions[sessionIdx] = session
        store.mutate { data in
            if let i = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                data.sessions[i].agentKind = targetKind
                data.sessions[i].updatedAt = session.updatedAt
            }
        }

        // Tear down managed agent terminals only — keep unmanaged Shell tabs.
        let existing = appState.terminals(for: sessionID)
        let managed = existing.filter(\.isManaged)
        let unmanaged = existing.filter { !$0.isManaged }
        for terminal in managed {
            appState.terminalReadiness.removeValue(forKey: terminal.id)
            appState.autoLaunchTerminals.remove(terminal.id)
            appState.pendingLaunchCommands.removeValue(forKey: terminal.id)
            appState.remoteControlActiveTerminals.remove(terminal.id)
            TerminalRouter.destroy(terminal)
        }
        store.mutate { data in
            data.terminals.removeAll { $0.sessionID == sessionID && $0.isManaged }
        }

        // Deferred paste on `.shellReady` (#408) — same path as `new-terminal --command`.
        let raw = SessionTerminal(
            sessionID: sessionID,
            name: target.displayName,
            cwd: worktree.worktreePath,
            command: nil,
            isManaged: true
        )
        appState.terminalReadiness[raw.id] = .uninitialized
        appState.pendingLaunchCommands[raw.id] = launchCommand
        appState.autoLaunchTerminals.insert(raw.id)

        let prepared = prepareTerminal(raw, trackReadiness: true)
        appState.terminals[sessionID] = unmanaged + [prepared]
        appState.activeTerminalID[sessionID] = prepared.id
        store.mutate { data in
            data.terminals.append(prepared)
        }

        CrowLog.info("[CrowTelemetry agent:handoff] session=\(sessionID.uuidString) from=\(priorKind.rawValue) to=\(targetKind.rawValue) terminal=\(prepared.id.uuidString)")
        return prepared.id
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
        armManagerExitMonitor()

        // Re-assign selection (even to the same values) to force a SwiftUI
        // re-render so TerminalSurfaceView re-creates the destroyed cockpit
        // surface and re-attaches a fresh tmux client; preserves focus.
        appState.selectedSessionID = savedSelection
        appState.activeTerminalID = savedActive
    }

    // MARK: - tmux crash auto-recovery (#588)

    /// Wall-clock of the last crash auto-recovery, to debounce a tight
    /// crash → recover → crash loop (e.g. a broken tmux install).
    private var lastCrashRecoveryAt: Date?

    /// Force-clears `tmuxCrashRecovering` if readiness callbacks never settle
    /// (e.g. tmux unconfigured so no terminal was re-registered at all).
    private var crashRecoveryClearFallback: Task<Void, Never>?

    /// The cockpit attach client exited on its own. Probe the server: dead →
    /// full crash recovery; alive (user detach / client-only death) → just
    /// recreate the attach surface and leave every window running.
    @MainActor
    public func handleCockpitClientExit() {
        guard !appState.tmuxCrashRecovering else { return }
        if TmuxBackend.shared.isRunning {
            CrowLog.info("[CrowTelemetry tmux:cockpit_client_reattach]")
            TmuxBackend.shared.recycleCockpitSurface()
            // Same SwiftUI re-render trick as recycleTmuxServerAndRebuild: a
            // same-value reassignment makes TerminalSurfaceView re-create the
            // destroyed cockpit surface and re-attach a fresh tmux client.
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

    /// Build the shell command for a Manager terminal, dispatched through
    /// the registered agent for `session.agentKind`. Managers launch their
    /// agent CLI directly as the terminal's shell command. Used by both
    /// fresh-terminal creation and the hydrate rebuild so the per-session
    /// `--name` label (and equivalent flags on other agents) has a single
    /// source. `internal` for unit testing (CROW-433).
    func managerCommand(for session: Session) -> String {
        let agentKind = session.agentKind
        let resolved = AgentRegistry.shared.agent(for: agentKind)
            ?? AgentRegistry.shared.defaultAgent
        if let agent = resolved {
            return agent.managerLaunchCommand(
                sessionName: session.name,
                remoteControlEnabled: appState.remoteControlEnabled,
                autoPermissionMode: appState.managerAutoPermissionMode,
                telemetryPort: telemetryPort
            )
        }
        // No agent registered (only happens in tests that skip
        // AgentRegistry setup). Fall back to the legacy Claude command so
        // pre-CROW-433 tests keep producing the same output.
        let claudePath = Self.findClaudeBinary() ?? "claude"
        let suffix = ClaudeLaunchArgs.argsSuffix(
            remoteControl: appState.remoteControlEnabled,
            sessionName: session.name,
            autoPermissionMode: appState.managerAutoPermissionMode
        )
        // CROW-402: prefix the command with the Manager's own gateway
        // (AppConfig.managerGateway) so the initial launch overrides any global
        // ~/.zshrc export. The matching settings.local.json `env` block (for
        // manual re-runs) is written by the terminal-creation / hydrate paths,
        // which own the devRoot write site — keeping this builder pure.
        return ClaudeLaunchArgs.gatewayEnvPrefix(managerGatewayResolved()) + claudePath + suffix
    }

    /// Write the Manager's gateway `env` block to `{devRoot}/.claude/settings.local.json`
    /// (or clear it when unset) so manual `claude` re-runs in the Manager terminal
    /// inherit the same routing as the initial launch (CROW-402).
    private func writeManagerGatewayEnv() {
        guard let devRoot = ConfigStore.loadDevRoot() else { return }
        ClaudeHookConfigWriter.writeGatewayEnv(dirPath: devRoot, resolved: managerGatewayResolved())
    }

    /// Write the Manager's Claude Code hook config into `dirPath`'s
    /// `.claude/settings.local.json` so `crow hook-event` fires for the Manager
    /// and its sidebar activity dot lights up (#539). Idempotent. Call it
    /// wherever the Manager's config is (re)established — terminal creation AND
    /// the hydrate path — because `createManagerTerminal` is skipped when a
    /// Manager terminal is merely restored from a prior launch, so a Manager
    /// that predates hooks (or any existing one) would otherwise never get them.
    /// Takes effect on the Manager's next `claude` (re)launch, since Claude Code
    /// reads hooks at startup. Written before any gateway-env write so the
    /// latter's 0o600 re-apply stays the final write.
    private func writeManagerHookConfig(for session: Session, dirPath: String) {
        // A Cursor Manager launching → sync its global Jira MCP (covers the
        // Manager "+" picker one-shot override, which sets agentKind without
        // mutating config). Independent of the crow-binary resolution below, so
        // it isn't skipped just because hook-config can't be written.
        if session.agentKind == .cursor {
            syncCursorMCPBridge()
        }
        // Clean up any hook config a *previous* Manager agent left in dirPath, so
        // switching the Manager's agent (e.g. Cursor → Claude) doesn't leave a
        // stale `.cursor/hooks.json` pointing at a dead manager UUID. The
        // devRoot isn't a deleted worktree, so nothing else reaps it. Idempotent
        // — no-ops when a sibling agent never wrote here.
        //
        // Runs BEFORE the `crowPath` guard (#829 review round 9, Green 3): the
        // cleanup depends only on `dirPath`/`session.agentKind`, so if
        // `findCrowBinary` misses, switching Cursor → Claude must still reap the
        // stale `.cursor/hooks.json` — otherwise the leak this loop exists to
        // prevent survives exactly when the guard bails. It removes only *other*
        // agents' configs, so ordering it ahead of our own write is safe.
        //
        // Claude is skipped: its `removeHookConfig` strips managed event keys
        // wholesale (not marker-scoped like Cursor's), and the devRoot's
        // `.claude/settings.local.json` commonly holds the user's own Manager
        // config — so cleaning it on every boot could drop a user's hand-authored
        // devRoot hooks. A stale Claude config left when switching to a non-Claude
        // Manager is inert anyway (Claude isn't launched there).
        for other in AgentRegistry.shared.allAgents()
            where other.kind != session.agentKind && other.kind != .claudeCode {
            other.hookConfigWriter.removeHookConfig(worktreePath: dirPath)
        }
        guard let agent = AgentRegistry.shared.agent(for: session.agentKind),
              let crowPath = ClaudeHookConfigWriter.findCrowBinary(devRoot: ConfigStore.loadDevRoot()) else { return }
        do {
            try agent.hookConfigWriter.writeHookConfig(
                worktreePath: dirPath,
                sessionID: session.id,
                crowPath: crowPath
            )
        } catch {
            CrowLog.info("[SessionService] Failed to write Manager hook config for session \(session.id.uuidString): \(error.localizedDescription)")
        }
    }

    /// Sync the user's Jira MCP into Cursor's global `mcp.json` when a Cursor
    /// agent is actually launching — the strongest "Cursor is in use" signal
    /// (#829 review). Called from every Cursor launch path (worker auto-launch,
    /// Manager, handoff, and the brand-new-terminal paste in `AgentLaunch`) so
    /// it fires for Cursor selected via config, `handoff-agent`, or the Manager
    /// picker alike; a CI box that merely ships a binary named `agent` never
    /// launches a Crow Cursor session, so the user's token is never copied
    /// there. Idempotent + marker-guarded — safe to call every launch.
    ///
    /// Dispatched off the main actor: reading a possibly-multi-MB
    /// `~/.claude.json` and writing `~/.cursor/mcp.json` must not block the UI.
    /// The write is global and self-heals on the next launch, so fire-and-forget
    /// is acceptable.
    ///
    /// Fires for `.review` sessions too, by deliberate decision (#829 review
    /// round 11, Green 3): a Cursor review of an untrusted PR loads the user's
    /// Jira MCP and — via `--force --approve-mcps` — auto-approves it, so a
    /// prompt injection in the diff has an authenticated `jira_*` write path.
    /// We accept this as parity with the shipped Claude posture rather than a
    /// Cursor-specific hole: Claude reviews already run with the user-scope
    /// `jira` server from `~/.claude.json` applied to every project (Claude
    /// never scopes MCP per session-kind either). The attacker-controlled
    /// *config layer* in the clone is neutralized separately by
    /// `stripCursorConfigFromReviewClone`; scoping the user's *own* convenience
    /// MCP out of reviews would be a cross-agent policy change, tracked
    /// independently if we decide review sessions should drop user MCP servers.
    private func syncCursorMCPBridge() {
        Task.detached(priority: .utility) {
            CursorMCPConfigWriter.bridgeJiraMCPDefault()
        }
    }

    /// Resolve the Manager's own AI gateway (`AppConfig.managerGateway`) from
    /// disk, or nil when unset/empty (CROW-402).
    private func managerGatewayResolved() -> GatewayResolver.Resolved? {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot),
              let gateway = config.managerGateway, !gateway.isEmpty
        else { return nil }
        return GatewayResolver.resolve(gateway)
    }

    /// Resolve the AI gateway for a non-Manager session from its worktree's
    /// workspace (CROW-402). The worktree lives at `{devRoot}/{workspace}/…`, so
    /// the workspace folder name is the first path component under devRoot.
    /// Returns nil when there's no matching workspace or no (non-empty) gateway.
    private func workspaceGatewayResolved(for sessionID: UUID) -> GatewayResolver.Resolved? {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot),
              let worktree = appState.primaryWorktree(for: sessionID),
              let wsName = Self.workspaceName(forWorktreePath: worktree.worktreePath, devRoot: devRoot),
              let workspace = config.workspaces.first(where: { $0.name == wsName }),
              let gateway = workspace.gateway, !gateway.isEmpty
        else { return nil }
        return GatewayResolver.resolve(gateway)
    }

    /// Derive the workspace folder name from a worktree path:
    /// `{devRoot}/{workspace}/{repo-folder}` → `{workspace}`. Pure path math.
    ///
    /// Public because this string *is* the link between a session and its
    /// workspace — there is no id on either side — so `workspace-edit` and
    /// `workspace-remove` need it to count what a rename or removal would orphan
    /// (CROW-809).
    public static func workspaceName(forWorktreePath path: String, devRoot: String) -> String? {
        let root = (devRoot as NSString).standardizingPath
        let full = (path as NSString).standardizingPath
        guard full.hasPrefix(root + "/") else { return nil }
        let relative = String(full.dropFirst(root.count + 1))
        return relative.split(separator: "/").first.map(String.init)
    }

    /// Legacy entry point preserved for tests that don't have a `Session` in
    /// hand. Builds a Claude-style command keyed only on `sessionName` and
    /// the live remote-control / auto-permission state. New call sites
    /// should use `managerCommand(for:)` instead so the agent is honored.
    func managerCommand(sessionName: String) -> String {
        let stub = Session(name: sessionName, kind: .manager, agentKind: .claudeCode)
        return managerCommand(for: stub)
    }

    /// Create the single agent terminal for a Manager session and persist
    /// it. Routes through the same backend-selection path as work sessions
    /// (#314): on tmux this registers a window and pastes the agent command
    /// into it via the shared xterm.js cockpit surface.
    /// `trackReadiness: false` matches the Manager's command-launches-agent
    /// model — no readiness/launchClaude flow.
    @discardableResult
    private func createManagerTerminal(session: Session, cwd: String) -> SessionTerminal {
        let command = managerCommand(for: session)
        // CROW-539: install hook config so `crow hook-event` fires for the
        // Manager, driving the same activity indicators worker cards get. The
        // Manager has no worktree and runs at the dev root, so hooks carry the
        // explicit `--session <managerID>` (writeHookConfig bakes it in) — the
        // cwd-fallback resolver can't route to the Manager. Written before the
        // gateway-env block below so writeGatewayEnv's 0o600 re-apply (the env
        // can carry a bearer token) is the final write; both merge into the same
        // {devRoot}/.claude/settings.local.json without clobbering each other.
        writeManagerHookConfig(for: session, dirPath: cwd)
        // CROW-600: a brand-new devRoot would otherwise block the Manager on
        // the agent's trust gate. No-ops when already trusted (#830 extends
        // this to Codex Managers).
        switch session.agentKind {
        case .claudeCode:
            ClaudeTrustSeeder.seedTrust(projectPath: cwd)
        case .codex:
            if case let .failed(msg) = CodexTrustSeeder.seedTrust(projectPath: cwd) {
                CrowLog.info("[SessionService] Codex trust seed failed for \(cwd): \(msg)")
            }
        default:
            break
        }
        // CROW-402: write the Manager gateway env block to {devRoot}/.claude so
        // manual `claude` re-runs in this terminal inherit the same routing. The
        // Manager's cwd is the devRoot.
        ClaudeHookConfigWriter.writeGatewayEnv(dirPath: cwd, resolved: managerGatewayResolved())
        let rawTerminal = SessionTerminal(
            sessionID: session.id,
            name: session.name,
            cwd: cwd,
            command: command
        )

        let terminal = prepareTerminal(rawTerminal, trackReadiness: false)
        appState.terminals[session.id] = [terminal]

        store.mutate { data in
            if !data.terminals.contains(where: { $0.sessionID == session.id }) {
                data.terminals.append(terminal)
            }
        }

        if command.contains(" --rc") {
            // See hydrate path: gate on what the agent actually emitted, not
            // on the global toggle, so a Cursor Manager doesn't get a stale
            // RC badge or a `/rename` injection (CROW-433 review).
            appState.remoteControlActiveTerminals.insert(terminal.id)
        }
        return terminal
    }

    /// Create an additional (non-primary) Manager session in `cwd`. Returns the
    /// new session's id. The terminal is set up by `createManagerTerminal`.
    ///
    /// `agentKind` is an optional one-shot override from the "+" picker menu
    /// (#582): when supplied it wins over the configured default for this
    /// session only, without mutating `agentsByKind` / `defaultAgentKind`.
    /// `nil` falls back to the configured Manager agent.
    @discardableResult
    public func createManagerSession(name: String, cwd: String, agentKind override: AgentKind? = nil) -> UUID {
        let agentKind = resolvedManagerAgentKind(override)
        let session = Session(name: name, status: .active, kind: .manager, agentKind: agentKind)
        appState.sessions.append(session)
        store.mutate { $0.sessions.append(session) }
        createManagerTerminal(session: session, cwd: cwd)
        return session.id
    }

    /// Resolve the agent for a new Manager session: an explicit per-session
    /// choice wins **when an agent is registered for it**, otherwise the
    /// configured default (`agentsByKind["manager"] ?? defaultAgentKind`).
    /// Never mutates config.
    ///
    /// The single choke point both `create-manager` surfaces funnel through —
    /// the web RPC (forwarded to `onCreateManager` → `createManagerSession`) and
    /// the daemon RPC (`createManagerSession` directly). Routing the registry
    /// gate here (CROW-593; #834, via `AgentRegistry.registeredKind`) keeps the
    /// two symmetric — neither can persist a Manager with an unregistered kind
    /// that `managerCommand` would then silently launch as the default.
    func resolvedManagerAgentKind(_ explicit: AgentKind?) -> AgentKind {
        AgentRegistry.shared.registeredKind(explicit) ?? appState.agentKind(for: .manager)
    }

    // MARK: - Delete Session

    /// Snapshot of one worktree's cleanup work, captured on the MainActor and
    /// passed by value into a detached task so disk/git operations don't block UI.
    struct WorktreeCleanupItem: Sendable {
        let repoPath: String
        let worktreePath: String
        let branch: String
        let isMainCheckout: Bool
        /// Agent whose per-worktree hook config to remove before deletion, so
        /// the removal dispatches through the right writer (e.g. Cursor's
        /// `.cursor/hooks.json`, not just Claude's `.claude/settings.local.json`).
        var agentKind: AgentKind = .claudeCode
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
    public func deleteSession(id: UUID) async {
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
                isMainCheckout: $0.isMainRepoCheckout,
                agentKind: session?.agentKind ?? .claudeCode
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
        appState.isMarkingIssueDone.removeValue(forKey: id)
        appState.isAddingMergeLabel.removeValue(forKey: id)
        appState.isDeletingSession.removeValue(forKey: id)

        store.mutate { data in
            data.sessions.removeAll { $0.id == id }
            data.worktrees.removeAll { $0.sessionID == id }
            data.links.removeAll { $0.sessionID == id }
            data.terminals.removeAll { $0.sessionID == id }
            data.hookStates?[id.uuidString] = nil
        }

        // Drop the session's raw telemetry rows now that the session itself is
        // gone (#772). Only after the cleanup succeeded — a retryable failure
        // returns above with the session intact, and its metrics with it. Any
        // `SessionAnalyticsSnapshot` is deliberately left alone: the scorecard
        // aggregates historical work whose sessions have since been deleted.
        if let telemetryDeleteProvider {
            await telemetryDeleteProvider(id)
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
                    CrowLog.info("[SessionService] Cleaned up review clone: \(item.worktreePath)")
                } catch {
                    let msg = "Failed to remove review clone: \(error.localizedDescription)"
                    CrowLog.info("[SessionService] \(msg) (\(item.worktreePath))")
                    if firstFatalError == nil { firstFatalError = msg }
                }
                continue
            }

            if item.isMainCheckout {
                CrowLog.info("Skipping worktree cleanup for main checkout: \(item.worktreePath) (branch: \(item.branch))")
                continue
            }

            // Remove our hook config before deleting the worktree, dispatching
            // through the session's own agent so non-Claude configs (e.g.
            // Cursor's `.cursor/hooks.json`) are cleaned by the right writer,
            // not just `.claude/settings.local.json`.
            let cleanupWriter = AgentRegistry.shared.agent(for: item.agentKind)?.hookConfigWriter
                ?? ClaudeHookConfigWriter()
            cleanupWriter.removeHookConfig(worktreePath: item.worktreePath)

            var gitRemoveFailed = false
            do {
                let removeResult = try runShellSync(["git", "-C", item.repoPath, "worktree", "remove", "--force", item.worktreePath])
                CrowLog.info("Removed worktree: \(item.worktreePath) \(removeResult)")

                if !SessionWorktree.isProtectedBranch(item.branch) {
                    do {
                        _ = try runShellSync(["git", "-C", item.repoPath, "branch", "-D", item.branch])
                    } catch {
                        CrowLog.info("[SessionService] Failed to delete branch \(item.branch): \(error)")
                    }
                }

                do {
                    _ = try runShellSync(["git", "-C", item.repoPath, "worktree", "prune"])
                } catch {
                    CrowLog.info("[SessionService] Failed to prune worktree metadata: \(error)")
                }
            } catch {
                gitRemoveFailed = true
                CrowLog.info("[SessionService] Failed to remove worktree \(item.worktreePath): \(error)")
            }

            // Either way, ensure the directory is gone.
            if FileManager.default.fileExists(atPath: item.worktreePath) {
                do {
                    try FileManager.default.removeItem(atPath: item.worktreePath)
                } catch {
                    CrowLog.info("[SessionService] Failed to remove directory \(item.worktreePath): \(error)")
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
    public func detectOrphanedWorktrees() async {
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
                    CrowLog.info("[SessionService] Recovered orphan worktree: \(wt.path) branch=\(wt.branch)")
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

        // Try to fetch issue title via the TaskBackend abstraction (ADR 0005).
        // Falls through silently if no `providerManager` is wired or the fetch
        // fails — title stays whatever the dir-name parser produced.
        if let issueURL = info.url, let manager = providerManager {
            let backend = manager.taskBackend(forURL: issueURL)
            if let ticket = try? await backend.fetchTask(url: issueURL) {
                info.title = ticket.title
            }
        }

        return info
    }

    /// Check for a pull request on a branch and return a link if found.
    private func findPRLink(branch: String, repoPath: String, sessionID: UUID, provider: Provider) async -> SessionLink? {
        guard let repoSlug = resolveRepoSlug(repoPath: repoPath) else { return nil }
        // Route through CodeBackend.linkedPR (ADR 0005). Without a wired
        // providerManager we can't look up a PR; that's the caller's signal
        // to skip the link.
        guard let manager = providerManager,
              let backend = manager.codeBackend(for: provider),
              let pr = try? await backend.linkedPR(repo: repoSlug, branch: branch) else {
            return nil
        }
        CrowLog.info("[SessionService] Found PR #\(pr.number) for branch '\(branch)'")
        return SessionLink(sessionID: sessionID, label: "PR #\(pr.number)", url: pr.url, linkType: .pr)
    }

    /// Resolve the code provider for a task-only tracker (Jira/Corveil) from the
    /// workspace that owns a worktree (`devRoot/<workspace>/<worktree>`). Returns
    /// `nil` for code-bearing task providers (they follow `provider`), and the
    /// workspace's own code provider otherwise — so a Jira-task + GitLab-code
    /// workspace gets `glab`, not a hardcoded `gh`. Falls back to `.github` when
    /// the workspace can't be resolved.
    public static func resolvedCodeProvider(forTask taskProvider: Provider?, worktreePath: String?) -> Provider? {
        guard taskProvider?.isTaskOnly == true else { return nil }
        guard let worktreePath else { return .github }
        let workspaceName = ((worktreePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot),
              let ws = config.workspaces.first(where: { $0.name == workspaceName }),
              let codeProvider = Provider(rawValue: ws.provider) else {
            return .github
        }
        return codeProvider
    }

    private func recoverOrphan(worktreePath: String, branch: String, repoName: String, repoPath: String) async {
        let dirName = (worktreePath as NSString).lastPathComponent
        let ticket = await parseTicketInfo(dirName: dirName, repoPath: repoPath)

        // A task-only tracker (Jira/Corveil) has no code backend — pair it with
        // the workspace's code provider for PR/git flows.
        let codeProvider = Self.resolvedCodeProvider(forTask: ticket.provider, worktreePath: worktreePath)
        let session = Session(
            name: dirName,
            status: .active,
            agentKind: appState.agentKind(for: .work),
            ticketURL: ticket.url,
            ticketTitle: ticket.title,
            ticketNumber: ticket.number,
            provider: ticket.provider,
            codeProvider: codeProvider
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
            name: session.agentKind.displayName,
            cwd: worktreePath,
            isManaged: true
        )

        // Collect links
        var links: [SessionLink] = []
        if let ticketURL = ticket.url {
            let label = ticket.number.map { "Issue #\($0)" } ?? "Issue"
            links.append(SessionLink(sessionID: session.id, label: label, url: ticketURL, linkType: .ticket))
        }
        if let prLink = await findPRLink(branch: branch, repoPath: repoPath, sessionID: session.id, provider: session.codeProvider ?? session.provider ?? .github) {
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

        CrowLog.info("[SessionService] Recovered session '\(dirName)' — ticket=#\(ticket.number.map(String.init) ?? "none") title=\(ticket.title ?? "unknown")")
    }

    // MARK: - Terminal Tab Management

    /// Add a new plain-shell (unmanaged) terminal tab to a session.
    public func addTerminal(sessionID: UUID) {
        let cwd = appState.primaryWorktree(for: sessionID)?.worktreePath
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let raw = SessionTerminal(sessionID: sessionID, name: "Shell", cwd: cwd, isManaged: false)
        let terminal = prepareTerminal(raw, trackReadiness: false)
        appState.terminals[sessionID, default: []].append(terminal)
        appState.activeTerminalID[sessionID] = terminal.id
        store.mutate { data in data.terminals.append(terminal) }
    }

    /// Close a non-managed terminal tab. Managed terminals cannot be closed individually.
    public func closeTerminal(sessionID: UUID, terminalID: UUID) {
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
        // terminal surface from the view hierarchy before we kill the tmux
        // window. Destroying while AppKit still holds the view risks a
        // WebKit callback landing on a freed surface (issue #282).
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
    public func renameTerminal(sessionID: UUID, terminalID: UUID, name: String) -> Bool {
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
    public func renameSession(sessionID: UUID, name: String) -> Bool {
        guard Validation.isValidSessionName(name),
              let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        appState.sessions[idx].name = name
        store.mutate { data in
            if let i = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                data.sessions[i].name = name
            }
        }
        syncAgentSessionName(sessionID: sessionID, newName: name)
        return true
    }

    /// Terminals to push a Remote-Control `/rename` into for a worker session:
    /// those launched with `--rc` (tracked in `remoteControlActiveTerminals`).
    /// That's the Claude Code instance whose claude.ai panel label is fixed at
    /// launch. Manager terminals are handled separately by
    /// `agentRenameTargets` (CROW-629) so Cursor/Codex/OpenCode Managers get
    /// `/rename` without being marked RC-active. Pure/`nonisolated` so it can
    /// be unit-tested without a live app.
    nonisolated static func remoteControlRenameTargets(
        terminals: [SessionTerminal],
        rcActiveTerminals: Set<UUID>
    ) -> [SessionTerminal] {
        terminals.filter { rcActiveTerminals.contains($0.id) }
    }

    /// Terminals that should receive an agent `/rename` after a Crow session
    /// rename (CROW-629). Decouples session-title sync from the Remote Control
    /// badge: Managers forward to command-bearing agent terminals when the
    /// agent supports rename (Cursor / Codex / OpenCode have no `--rc` but
    /// still expose `/rename`) — unmanaged Shell tabs (`command == nil`) are
    /// excluded so `/rename` is not pasted into a live shell; workers stay
    /// gated on `remoteControlActiveTerminals` so Claude's claude.ai panel
    /// label keeps syncing. Pure/`nonisolated` for unit tests.
    nonisolated static func agentRenameTargets(
        session: Session,
        terminals: [SessionTerminal],
        rcActiveTerminals: Set<UUID>,
        supportsRename: Bool
    ) -> [SessionTerminal] {
        guard supportsRename else { return [] }
        if session.isManager {
            // Same discriminator RC bookkeeping uses: only terminals that
            // launched an agent carry a `command`. Extra Shell tabs must not
            // receive `/rename` (would run as a bogus shell command).
            return terminals.filter { $0.command != nil }
        }
        return remoteControlRenameTargets(
            terminals: terminals,
            rcActiveTerminals: rcActiveTerminals
        )
    }

    /// After an in-app rename, push the new name to the running agent via its
    /// `/rename` slash command so the agent session title (and, for Claude
    /// `--rc`, the claude.ai Remote Control panel label) stays in sync.
    /// No-op when the agent has no rename surface, the session has no eligible
    /// terminal, or a terminal's surface isn't ready to receive. The name is
    /// already validated (no control characters) by the caller.
    private func syncAgentSessionName(sessionID: UUID, newName: String) {
        guard let session = appState.sessions.first(where: { $0.id == sessionID }),
              let slash = AgentRegistry.shared.agent(for: session.agentKind)?
                .sessionRenameSlashCommand(newName: newName) else { return }
        let targets = Self.agentRenameTargets(
            session: session,
            terminals: appState.terminals(for: sessionID),
            rcActiveTerminals: appState.remoteControlActiveTerminals,
            supportsRename: true
        )
        for terminal in targets where TerminalRouter.canSend(terminal) {
            TerminalRouter.send(terminal, text: slash)
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
    public func createReviewSession(prURL: String, selectAfterCreate: Bool = false) async -> UUID? {
        // Universal backstop against duplicate sessions for the same PR. The
        // serial kickoff queue in AppDelegate guarantees that by the time a
        // second `createReviewSession` runs, the first has already appended
        // its row to `appState.sessions` — so this check is authoritative,
        // not racy. Belt-and-suspenders for the auto-review watcher race
        // (CROW-406) and any future caller that re-enters during a kickoff.
        if let existing = appState.existingReviewSession(forPRURL: prURL) {
            CrowLog.info("[SessionService] Skipping duplicate review session for \(prURL); reusing \(existing.id)")
            if selectAfterCreate { appState.selectedSessionID = existing.id }
            return existing.id
        }

        // Parse org/repo and PR number from URL like "https://github.com/org/repo/pull/123"
        guard let parsed = Session.parseReviewPR(url: prURL) else {
            CrowLog.info("[SessionService] Could not parse PR URL: \(prURL)")
            return nil
        }
        let owner = parsed.owner
        let repoName = parsed.repo
        let prNumber = parsed.number
        let repoSlug = "\(owner)/\(repoName)"

        // Determine clone path
        guard let devRoot = ConfigStore.loadDevRoot() else {
            CrowLog.info("[SessionService] No devRoot configured")
            return nil
        }

        // All git/network/file-write work runs off the main actor so the UI
        // never beachballs while a review spins up (#404). The detached task
        // hands back just the metadata the main-actor tail needs to build
        // the Session/Worktree/Terminal/Link rows.
        //
        // The resolved review-agent kind is captured here (main actor) so the
        // detached prepareReviewClone can pick the right prompt-file content
        // — Claude reads a `/crow-review-pr` slash command; Cursor reads the
        // expanded SKILL.md body (#431).
        let reviewAgentKind = appState.agentKind(for: .review)
        let env = ShellEnvironment.shared.env

        // Fetch PR metadata via the GitHub CodeBackend (ADR 0005) before
        // dispatching the heavyweight clone work to a detached task. Done
        // here on the main actor so the providerManager dependency doesn't
        // need to cross the actor boundary into the detached task.
        let prMetadata: PRMetadata
        do {
            guard let manager = providerManager else {
                CrowLog.info("[SessionService] No providerManager wired; cannot prepare review for \(prURL)")
                return nil
            }
            let backend = manager.codeBackend(for: .github)!
            prMetadata = try await backend.fetchPRMetadata(prURL: prURL)
        } catch {
            CrowLog.info("[SessionService] Failed to fetch PR metadata for \(prURL): \(error.localizedDescription)")
            return nil
        }

        let prep: ReviewClonePrep
        do {
            prep = try await Task.detached(priority: .userInitiated) {
                try await Self.prepareReviewClone(
                    prURL: prURL,
                    repoSlug: repoSlug,
                    repoName: repoName,
                    prNumber: prNumber,
                    devRoot: devRoot,
                    env: env,
                    reviewAgentKind: reviewAgentKind,
                    prMetadata: prMetadata
                )
            }.value
        } catch {
            CrowLog.info("[SessionService] Failed to prepare review clone for \(prURL): \(error.localizedDescription)")
            return nil
        }

        // Create session
        let session = Session(
            name: "review-\(repoName)-\(prNumber)",
            kind: .review,
            // Reuse the `reviewAgentKind` captured before the clone `await`s
            // (#829 review round 11), NOT a fresh `appState.agentKind(for:)`.
            // `SessionService` is `@MainActor` but the PR-metadata fetch and the
            // `gh repo clone` both suspend, so a config save landing in that
            // window would otherwise make the launching agent differ from the
            // one that gated the `.cursor/`/`.codex/` strip and picked the
            // prompt body — a Claude→Cursor drift would run Cursor unstripped in
            // the hostile clone AND hand it a `/crow-review-pr` slash line it has
            // no engine for. Sampling once makes the strip gate, prompt format,
            // attribution, and launching agent the same value by construction.
            agentKind: reviewAgentKind,
            ticketTitle: prep.prTitle,
            provider: .github,
            lastReviewedHeadSha: prep.headRefOid,
            reviewAuthor: prMetadata.author.isEmpty ? nil : prMetadata.author
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
            name: session.agentKind.displayName,
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

        CrowLog.info("[SessionService] Created review session '\(session.name)' for \(prURL)")
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

    /// Gate for the Cursor-handoff `.cursor/` strip: fire only when handing a
    /// *review* session off to Cursor. Extracted as a pure predicate so the
    /// handoff gate — the dimension both the round-10 and round-11 blockers
    /// lived in — is unit-testable without standing up the full `handoffAgent`
    /// terminal machinery (mirrors `shouldRestartPrimaryManagerOnRecreate`).
    /// `.work`/`.job` handoffs to Cursor, and `.review` handoffs to any other
    /// agent, must NOT strip (#829 review round 11, Green 2).
    nonisolated static func shouldStripCursorReviewCloneOnHandoff(
        targetKind: AgentKind, sessionKind: SessionKind) -> Bool {
        targetKind == .cursor && sessionKind == .review
    }

    /// Gate for refusing a review-session handoff to an agent that can't perform
    /// reviews. Today only Antigravity: its `.review` is unsupported in Phase A
    /// (`autoLaunchCommand(.review)` → nil) AND it has no `.agents/` strip / trust
    /// gate, so a review handoff would launch `agy` in an attacker-controlled
    /// clone and run committed `.agents/hooks.json` unsandboxed. Extracted as a
    /// pure predicate so the security gate is unit-testable without the full
    /// `handoffAgent` machinery (mirrors `shouldStripCursorReviewCloneOnHandoff`).
    /// Codex/Cursor/OpenCode are deliberately excluded — they support review
    /// handoff with their own strip + trust protections.
    nonisolated static func shouldRefuseReviewHandoff(
        targetKind: AgentKind, sessionKind: SessionKind) -> Bool {
        targetKind == .antigravity && sessionKind == .review
    }

    /// Neutralize a review clone's committed Cursor config layer by removing the
    /// working-tree `.cursor/` directory. A hostile PR head can commit
    /// `.cursor/hooks.json` (arbitrary `beforeShellExecution` commands, with no
    /// approval gate at all) or `.cursor/mcp.json` (a project-scope
    /// `{command,args,env}` MCP server that this PR's `--approve-mcps` would
    /// auto-trust), either of which would run unsandboxed on the reviewer's
    /// machine once Cursor loads the clone as its project root. Stripping the
    /// whole directory removes both surfaces.
    ///
    /// Shared by two call sites so the gate can't drift (#829 review round 10):
    /// `prepareReviewClone` (the creation-time default review agent) and the
    /// Cursor branch of `handoffAgent` (`crow handoff-agent --agent cursor` can
    /// flip a review session created under another agent to Cursor *after* the
    /// clone was prepped, landing it in a never-stripped hostile checkout).
    /// Working-tree removal only: the git index entry survives (`removeItem`
    /// doesn't stage a deletion), so `CursorHookConfigWriter.writeHookConfig`
    /// still correctly declines to overwrite a *committed* hooks file and the
    /// review runs without Crow's hook-based state signals — a bounded,
    /// pre-existing limitation for repos that commit their own `.cursor/`,
    /// independent of this security strip. Idempotent; no-ops when the clone
    /// ships no `.cursor/`.
    nonisolated static func stripCursorConfigFromReviewClone(clonePath: String) {
        let cursorDir = (clonePath as NSString).appendingPathComponent(".cursor")
        do {
            try FileManager.default.removeItem(atPath: cursorDir)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // No `.cursor/` shipped — the common, expected case. Stay quiet.
        } catch {
            // A real removal failure (permissions, a `.cursor` that's a busy
            // mount, etc.) leaves the attacker's config layer in place, so this
            // security control must be audible rather than swallowed (#829
            // review round 11, Green 1).
            CrowLog.info("[SessionService] Failed to strip .cursor/ from review clone \(clonePath): \(error.localizedDescription)")
        }
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
        env: [String: String],
        reviewAgentKind: AgentKind,
        prMetadata: PRMetadata
    ) async throws -> ReviewClonePrep {
        let prTitle = prMetadata.title
        let headBranch = prMetadata.headRefName
        guard !headBranch.isEmpty else {
            throw NSError(
                domain: "SessionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "PR metadata missing headRefName for \(prURL)"]
            )
        }
        // `headRefOid` is the SHA the review session is anchored to. Used by
        // the kickoff guard (AppDelegate) as a fallback re-kick signal when
        // the PR head advances without an explicit re-request (CROW-290).
        let headRefOid: String? = prMetadata.headRefOid.isEmpty ? nil : prMetadata.headRefOid

        let reviewsDir = (devRoot as NSString).appendingPathComponent("crow-reviews")
        let cloneDirName = "\(repoName)-pr-\(prNumber)"
        let clonePath = (reviewsDir as NSString).appendingPathComponent(cloneDirName)

        let fm = FileManager.default

        // Ensure reviews directory exists
        try? fm.createDirectory(atPath: reviewsDir, withIntermediateDirectories: true)

        // Clone or update the repo. Clone failures MUST surface (CROW-439): if
        // the checkout directory never gets created, the launcher would still
        // build a `agent "$(cat .crow-review-prompt.md)"` command pointing at a
        // path that doesn't exist, and the agent would launch with an empty
        // prompt. Throwing here aborts session creation cleanly.
        if !fm.fileExists(atPath: (clonePath as NSString).appendingPathComponent(".git")) {
            CrowLog.info("[SessionService] Cloning \(repoSlug) into \(clonePath)")
            do {
                _ = try await runShellAsync(env: env, args: ["gh", "repo", "clone", repoSlug, clonePath])
            } catch {
                throw NSError(
                    domain: "SessionService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to clone \(repoSlug) into \(clonePath): \(error.localizedDescription)"]
                )
            }
        }

        // Defense-in-depth: clone may have "succeeded" (exit 0) but left the
        // directory in an unusable state. Refuse to proceed if the path isn't
        // a real directory.
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: clonePath, isDirectory: &isDir), isDir.boolValue else {
            throw NSError(
                domain: "SessionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Clone path \(clonePath) does not exist after clone step"]
            )
        }

        // Fetch and checkout the PR branch. These are best-effort: the existing
        // working tree may already be on the right branch, and a network blip
        // on `pull` shouldn't abort the launch — the agent can resume from the
        // local state.
        //
        // Restore `.codex` first, but only for Codex reviews (see the strip
        // below): a *re-prep* of this same clone dir starts with the prior
        // prep's `.codex` strip still applied as an unstaged deletion of tracked
        // files, which would make `git pull` refuse ("local changes would be
        // overwritten") if the new head touches `.codex/` — silently reviewing a
        // stale head. Restoring before the pull keeps the tree clean; the strip
        // below re-applies afterward (#843 review round 6).
        if reviewAgentKind == .codex {
            _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", ".codex"])
        }
        // Same restore-before-pull for Cursor reviews (#829 review round 9):
        // the `.cursor/` strip below applies as an unstaged deletion of tracked
        // files, so `git pull` would refuse if the new head touches `.cursor/`.
        if reviewAgentKind == .cursor {
            _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", ".cursor"])
        }
        _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "fetch", "origin", headBranch])
        _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", headBranch])
        _ = try? await runShellAsync(env: env, args: ["git", "-C", clonePath, "pull", "origin", headBranch])

        // Defense-in-depth for Codex reviews (#843 review round 5): strip any
        // committed `.codex/` from the checked-out PR head before the agent
        // launches. The head is attacker-controlled and `.codex/hooks.json` /
        // inline `[hooks]` in `.codex/config.toml` are not conventionally
        // gitignored, so a drive-by PR could ship hooks that Codex would run
        // once the folder is trusted. `launchAgent` already declines to trust a
        // review clone; removing the config layer here means the hooks can't
        // fire even if the folder is trusted by some other path (a globally
        // pre-trusted parent, a manual handoff). Re-run on every prep so a
        // `git pull` on the reused clone dir can't reintroduce it. Mirrors the
        // Claude path's `.claude/settings.json` overwrite below.
        //
        // Gated to Codex reviews (#843 review round 7): only Codex loads
        // `.codex/`, so stripping it for a Claude/Cursor/OpenCode review would
        // just hide from the reviewing agent the exact files a hostile PR ships
        // — the review surface should stay intact for the agents that don't act
        // on `.codex/`.
        if reviewAgentKind == .codex {
            try? fm.removeItem(atPath: (clonePath as NSString).appendingPathComponent(".codex"))
        }
        // Defense-in-depth for Antigravity review clones (#862 review): a hostile
        // PR head can commit `.agents/hooks.json` with arbitrary command hooks
        // that `agy` runs with no approval gate. Antigravity review handoff is
        // refused outright (`shouldRefuseReviewHandoff`), so this normally guards
        // a path that can't be reached today — but if any future code launches
        // `agy` in a review clone (e.g. Antigravity becoming a valid review
        // agent), the committed `.agents/` is already neutralized. Gated to
        // Antigravity reviews for the same reason as `.codex`/`.cursor`: only
        // Antigravity loads `.agents/`, so stripping it for another agent's
        // review would just hide the files a hostile PR ships. Re-run on every
        // prep so a `git pull` can't reintroduce it.
        if reviewAgentKind == .antigravity {
            try? fm.removeItem(atPath: (clonePath as NSString).appendingPathComponent(".agents"))
        }
        // Same defense-in-depth for Cursor reviews (#829 review round 9). This
        // PR makes project `.cursor/hooks.json` Crow's load-bearing hook
        // transport and adds `--force --approve-mcps` on the `.review` path, so
        // a hostile PR head's committed `.cursor/hooks.json` (arbitrary
        // `beforeShellExecution`/`beforeSubmitPrompt` commands) OR `.cursor/mcp.json`
        // (a project-scope MCP server that `--approve-mcps` would auto-trust)
        // would run on the reviewer's machine, unsandboxed, once Cursor loads
        // the clone as its project root. Gated to Cursor reviews for the same
        // reason as `.codex/`: stripping it for an agent that doesn't load it
        // would just hide the files a hostile PR ships. The strip is a
        // working-tree removal — see `stripCursorConfigFromReviewClone` for why
        // this doesn't (and needn't) free `writeHookConfig` to write into a
        // committed hooks file.
        if reviewAgentKind == .cursor {
            Self.stripCursorConfigFromReviewClone(clonePath: clonePath)
        }

        // Write review prompt file into the clone directory. Write failures
        // MUST surface (CROW-439): the launcher's `$(cat ...)` shell
        // substitution will yield an empty string and the agent will idle if
        // the file isn't there.
        let promptPath = (clonePath as NSString).appendingPathComponent(".crow-review-prompt.md")
        let reviewPrompt = Self.buildReviewPrompt(prURL: prURL, prTitle: prTitle, repoSlug: repoSlug, prNumber: prNumber, agentKind: reviewAgentKind)
        try reviewPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        guard fm.fileExists(atPath: promptPath) else {
            throw NSError(
                domain: "SessionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Review prompt file missing at \(promptPath) after write"]
            )
        }

        // Copy the crow-review-pr skill into the clone's .claude/skills/ so Claude Code can find it.
        // Substitute `{{CROW_AGENT_DISPLAY_NAME}}` before writing so the attribution footer is a
        // literal string regardless of how the agent quotes the body (issue #447 — single-quoted
        // heredocs in gh/glab calls don't expand shell variables).
        let cloneSkillsDir = (clonePath as NSString).appendingPathComponent(".claude/skills/crow-review-pr")
        try? fm.createDirectory(atPath: cloneSkillsDir, withIntermediateDirectories: true)
        let skillContent = Scaffolder.bundledReviewSkill()
        let resolvedSkillContent = CrowAttribution.expandSkillBody(skillContent, agentKind: reviewAgentKind)
        try? resolvedSkillContent.write(
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
            CrowLog.info("[SessionService] Job '\(job.name)' has no prompts; skipping")
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
                    CrowLog.info("[SessionService] Job '\(job.name)': repo '\(job.repo)' is not cloned and clone-on-demand failed")
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
                CrowLog.info("[SessionService] Job '\(job.name)': repo '\(job.repo)' not found under devRoot")
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
            CrowLog.info("[SessionService] Job '\(job.name)': createWorktree failed: \(error.localizedDescription)")
            return nil
        }

        // Write the first prompt to the file launchClaude reads on first launch.
        // Write failures MUST surface (CROW-439): if the file isn't there, the
        // launcher's `$(cat .crow-job-prompt.md)` shell substitution yields an
        // empty string and the agent silently idles.
        let promptPath = (worktreePath as NSString).appendingPathComponent(".crow-job-prompt.md")
        do {
            try firstPrompt.write(toFile: promptPath, atomically: true, encoding: .utf8)
        } catch {
            CrowLog.info("[SessionService] Job '\(job.name)': failed to write \(promptPath): \(error.localizedDescription)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: promptPath) else {
            CrowLog.info("[SessionService] Job '\(job.name)': prompt file missing at \(promptPath) after write")
            return nil
        }

        let session = Session(
            name: "job-\(slug)-\(stamp)",
            kind: .job,
            agentKind: appState.agentKind(for: .job)
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
            name: session.agentKind.displayName,
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

        CrowLog.info("[SessionService] Job '\(job.name)': created session '\(session.name)' at \(worktreePath)")
        return (session.id, preparedTerminal.id)
    }

    /// The local folder name for a job's repo: the slug's last component
    /// (`corveil/api` → `api`, GitLab `group/sub/proj` → `proj`), or the
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
            CrowLog.info("[SessionService] Job '\(job.name)': repo '\(job.repo)' is not an owner/repo slug; cannot clone")
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

        CrowLog.info("[SessionService] Job '\(job.name)': cloning \(job.repo) into \(destination)")
        do {
            if provider == "gitlab" {
                var env: [String: String] = [:]
                if let host = workspace?.host, !host.isEmpty { env["GITLAB_HOST"] = host }
                _ = try await shell(env: env, "glab", "repo", "clone", job.repo, destination)
            } else {
                _ = try await shell("gh", "repo", "clone", job.repo, destination)
            }
        } catch {
            CrowLog.info("[SessionService] Job '\(job.name)': clone failed: \(error.localizedDescription)")
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

    /// Filename of the initial prompt file the launcher expects for a given
    /// session kind. `review` and `job` sessions dispatch their first prompt
    /// by shell-substituting the file's contents into the agent's command
    /// (CROW-439); `work` and `manager` have no initial prompt file.
    ///
    /// Both `CursorAgent.autoLaunchCommand` and `ClaudeCodeAgent.autoLaunchCommand`
    /// encode the same mapping inline — this helper is the launcher's preflight
    /// validator, not a refactor of the agents.
    nonisolated static func initialPromptFileName(for kind: SessionKind) -> String? {
        switch kind {
        case .review: return ".crow-review-prompt.md"
        case .job:    return ".crow-job-prompt.md"
        case .work, .manager: return nil
        }
    }

    /// Build the initial prompt for a review session.
    ///
    /// Claude Code resolves `/crow-review-pr <URL>` via its slash-command /
    /// SKILL engine — the prompt file is a one-liner and the bundled
    /// `.claude/skills/crow-review-pr/SKILL.md` (copied alongside) supplies
    /// the actual instructions. Cursor's `agent` CLI has no equivalent slash-
    /// command engine, so for Cursor we expand the SKILL body inline with
    /// `$ARGUMENTS` already substituted to the PR URL — same instructions,
    /// no second-file indirection (#431).
    ///
    /// `internal` (not `private`) so `SessionServiceReviewPromptTests` can
    /// assert the branch dispatch via `@testable import Crow`. The actual
    /// SKILL-body substitution lives in `cursorReviewPrompt(skillBody:prURL:)`
    /// so tests can exercise the substitution logic without depending on
    /// `Scaffolder.bundledReviewSkill()` (which falls back to a trivial stub
    /// in test environments where the repo path can't be resolved from
    /// `ProcessInfo.processInfo.arguments[0]`).
    nonisolated static func buildReviewPrompt(prURL: String, prTitle: String, repoSlug: String, prNumber: Int, agentKind: AgentKind) -> String {
        switch agentKind {
        case .cursor, .openCode, .codex:
            // Cursor, OpenCode, and Codex all lack a Crow slash-command engine,
            // so they get the whole crow-review-pr SKILL body inlined into the
            // prompt file (a self-contained brief). Without this, a Codex review
            // would receive a bare `/crow-review-pr <URL>` line it can't resolve,
            // never run `gh pr review`, and so never satisfy the review-
            // completion contract — the loop #830 set out to remove (#843
            // review round 2). `agentKind` is threaded through so the posted
            // review footer names the right agent.
            return cursorReviewPrompt(
                skillBody: Scaffolder.bundledReviewSkill(),
                prURL: prURL,
                agentKind: agentKind
            )
        default:
            // Claude Code (and any future agent with a compatible slash-
            // command engine) gets the terse `/crow-review-pr <URL>` form.
            return """
            /crow-review-pr \(prURL)
            """
        }
    }

    /// Apply the inlined-SKILL substitutions to a raw `crow-review-pr` SKILL
    /// body for agents without a slash-command engine (Cursor, OpenCode):
    /// replace `$ARGUMENTS` with the PR URL, and expand
    /// `${CROW_AGENT_DISPLAY_NAME:-…}` / legacy "via Claude Code" wording so the
    /// posted GitHub review identifies the reviewing agent correctly.
    ///
    /// `agentKind` defaults to `.cursor` for backward compatibility with the
    /// original single-agent call site (and its unit test); pass the actual
    /// kind (e.g. `.openCode`) so the footer names the right agent.
    ///
    /// Split out from `buildReviewPrompt` so unit tests can verify the
    /// substitutions against a known input without depending on the
    /// scaffolder's file-resolution fallback.
    nonisolated static func cursorReviewPrompt(skillBody: String, prURL: String, agentKind: AgentKind = .cursor) -> String {
        CrowAttribution.expandSkillBody(
            skillBody.replacingOccurrences(of: "$ARGUMENTS", with: prURL),
            agentKind: agentKind
        )
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

        scheduleAnalyticsSnapshot(for: id, status: status)
    }

    /// Stamp agent `SessionStart`/`SessionEnd` wall-clock timestamps on the
    /// session (#692, ADR 0008 follow-up 4). Display-only context —
    /// `activeTimeSeconds` from telemetry stays the penalty-normalization
    /// clock. Like `setLocked`, deliberately leaves `updatedAt` untouched so
    /// the retention clock is unaffected. These events are rare (agent
    /// launch/exit), so the unconditional store write is cheap.
    func recordAgentLifecycleEvent(sessionID: UUID, eventName: String, at date: Date = Date()) {
        guard eventName == "SessionStart" || eventName == "SessionEnd" else { return }

        func apply(_ session: inout Session) {
            if eventName == "SessionStart" {
                session.recordAgentSessionStart(at: date)
            } else {
                session.recordAgentSessionEnd(at: date)
            }
        }
        if let idx = appState.sessions.firstIndex(where: { $0.id == sessionID }) {
            apply(&appState.sessions[idx])
        }
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == sessionID }) {
                apply(&data.sessions[idx])
            }
        }
    }

    // MARK: - Analytics Snapshot (#690, ADR 0008)

    /// Fire-and-forget trigger for the end-of-session analytics snapshot.
    /// Internal (not private) because the `set-status` RPC handler mutates
    /// status directly, bypassing `updateSessionStatus`, and must trigger the
    /// snapshot itself.
    func scheduleAnalyticsSnapshot(for id: UUID, status: SessionStatus) {
        guard status == .completed || status == .archived else { return }
        Task { await writeAnalyticsSnapshot(for: id, status: status) }
    }

    /// Persist a durable `SessionAnalyticsSnapshot` when a session reaches a
    /// terminal status. Prefers a fresh aggregate from telemetry.db — covering
    /// the relaunch-then-complete gap where the in-memory aggregate is still
    /// nil — and falls back to `SessionHookState.analytics`. Skips (with a
    /// diagnostic, #745), preserving any existing snapshot, when both are nil
    /// or empty (telemetry disabled, or a session that never produced data —
    /// the SQL aggregate is all-zeros for unknown sessions, so `isEmpty` is
    /// the real guard). `endedAt` defaults to now for live transitions; the
    /// backfill passes the session's `updatedAt` so historical sessions land
    /// in their true week instead of the current one.
    func writeAnalyticsSnapshot(for id: UUID, status: SessionStatus, endedAt: Date? = nil) async {
        guard status == .completed || status == .archived else { return }
        guard !appState.isManagerSession(id) else { return }

        let fresh = await analyticsProvider?(id)
        let analytics = (fresh?.isEmpty == false)
            ? fresh
            : appState.existingHookState(for: id)?.analytics
        guard let analytics, !analytics.isEmpty else {
            CrowLog.info(
                "[SessionService] Skipped analytics snapshot for \(id.uuidString) (\(status.rawValue)): "
                    + "no telemetry data — telemetry disabled, not restarted since enabling, "
                    + "or the session produced none")
            appState.analyticsSnapshotSkipCount += 1
            appState.lastAnalyticsSnapshotSkipAt = Date()
            return
        }

        // Compaction count only exists on the in-memory hook state — telemetry.db
        // has no compaction rows — so read it there even when `analytics` came
        // from the DB provider (#691).
        let session = appState.sessions.first(where: { $0.id == id })
        let snapshot = SessionAnalyticsSnapshot(
            sessionID: id, endedAt: endedAt ?? Date(), status: status, analytics: analytics,
            compactionCount: appState.existingHookState(for: id)?.compactionCount ?? 0,
            wallClockDurationSeconds: session?.wallClockDuration,
            alignmentWeight: session?.alignmentWeight,
            orgGoal: session?.orgGoal)
        store.mutate { data in
            var snapshots = data.analyticsSnapshots ?? [:]
            snapshots[id.uuidString] = snapshot
            data.analyticsSnapshots = snapshots
        }
        appState.analyticsSnapshots[id.uuidString] = snapshot
    }

    /// Rebuild missing analytics snapshots from telemetry.db (#745): the
    /// one-shot write at a terminal transition means sessions recorded before
    /// snapshotting existed — or whose write raced a quit — never surface on
    /// the scorecard. Runs at launch (before retention pruning) and from the
    /// manual "Rebuild scorecard" action. Idempotent: existing snapshots are
    /// never touched, so re-runs are no-ops. Skips orphaned telemetry
    /// sessions (no Crow session record — their status/endedAt would be
    /// fabricated), non-terminal sessions (they snapshot at completion), and
    /// the Manager session (tracked by `refreshManagerUsage` instead). The
    /// empty-analytics guard in `writeAnalyticsSnapshot` still applies.
    /// Returns the number of snapshots written.
    @discardableResult
    public func backfillAnalyticsSnapshots() async -> Int {
        guard let telemetrySessionIDsProvider else { return 0 }
        var written = 0
        for id in await telemetrySessionIDsProvider() {
            let key = id.uuidString
            guard store.data.analyticsSnapshots?[key] == nil else { continue }
            guard let session = appState.sessions.first(where: { $0.id == id }),
                  session.status == .completed || session.status == .archived,
                  !session.isManager else { continue }
            // updatedAt, not now: the session ended historically and must
            // bucket into its true week (mirrors the quit-race backfill).
            await writeAnalyticsSnapshot(for: id, status: session.status, endedAt: session.updatedAt)
            if store.data.analyticsSnapshots?[key] != nil { written += 1 }
        }
        if written > 0 {
            CrowLog.info("[SessionService] Backfilled \(written) analytics snapshot(s) from telemetry.db")
        }
        return written
    }

    /// Week-start key for the persisted Manager rollups ("yyyy-MM-dd").
    private static let weekKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Recompute the Manager session's ungraded weekly usage rollups from
    /// telemetry.db (#745) — the Manager session never reaches a terminal
    /// status, so it can't produce a `SessionAnalyticsSnapshot`. Covers the
    /// current week plus the trailing baseline window. Merge-only: weeks with
    /// no telemetry rows are skipped rather than zeroed (absence usually
    /// means the rows aged out of retention), so persisted rollups survive
    /// pruning. Known bounded edge: the oldest still-covered week can be
    /// partially pruned mid-week, briefly dipping its recomputed total; it
    /// self-corrects once the week ages out entirely.
    public func refreshManagerUsage(now: Date = Date()) async {
        guard let managerUsageProvider else { return }
        // ISO-8601 weeks in the current timezone — the same bucketing
        // ScorecardModel.build uses, so the Manager card's weeks line up
        // with the graded weeks.
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        guard let currentWeek = calendar.dateInterval(of: .weekOfYear, for: now) else { return }

        var updates: [String: ManagerWeeklyUsage] = [:]
        for offset in 0...EfficiencyGrading.Tuning.baselineWeekCount {
            guard let weekDate = calendar.date(
                      byAdding: .weekOfYear, value: -offset, to: currentWeek.start),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: weekDate)
            else { continue }
            let analytics = await managerUsageProvider(interval.start, interval.end)
            guard !analytics.isEmpty else { continue }
            updates[Self.weekKeyFormatter.string(from: interval.start)] =
                ManagerWeeklyUsage(weekStart: interval.start, analytics: analytics)
        }

        guard !updates.isEmpty else { return }
        store.mutate { data in
            var rollups = data.managerUsageWeekly ?? [:]
            for (key, value) in updates { rollups[key] = value }
            data.managerUsageWeekly = rollups
        }
        appState.managerUsageWeekly = store.data.managerUsageWeekly ?? [:]
    }

    /// Lock or unlock a session to exempt it from (or restore it to) the
    /// retention cleanup reaper (CROW-569 shipped this as "pin"; CROW-573 renamed
    /// it to "lock"). Deliberately leaves `updatedAt` untouched so the retention
    /// clock is preserved — unlocking restores the session's original age-based
    /// eligibility rather than resetting it.
    public func setLocked(id: UUID, locked: Bool) {
        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].locked = locked
        }
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[idx].locked = locked
            }
        }
    }

    /// Set or clear the session's org-goal tag (#696, ADR 0008 follow-up 8).
    /// `nil` clears the tag back to untagged/neutral. The tag feeds
    /// `Session.alignmentWeight`, which is copied onto the analytics snapshot
    /// when the session reaches a terminal status.
    public func setOrgGoal(id: UUID, goal: String?) {
        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].orgGoal = goal
            appState.sessions[idx].updatedAt = Date()
        }
        store.mutate { data in
            if let idx = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[idx].orgGoal = goal
                data.sessions[idx].updatedAt = Date()
            }
        }
    }

    public func completeSession(id: UUID) {        updateSessionStatus(id, to: .completed)
    }

    public func setSessionInReview(id: UUID) {
        updateSessionStatus(id, to: .inReview)
    }

    public func setSessionActive(id: UUID) {
        updateSessionStatus(id, to: .active)
    }

    // MARK: - Persist Current State

    /// Sync all in-memory state back to the JSON store on disk.
    public func persistState() {
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

            // Analytics-snapshot quit-race backfill (#690): a terminal status
            // transition spawns the snapshot write asynchronously, so a fast
            // quit can beat it. Backfill synchronously from the in-memory
            // aggregate — but never overwrite an existing snapshot, which is
            // DB-derived and at least as fresh.
            for session in appState.sessions
            where (session.status == .completed || session.status == .archived)
                && !session.isManager {
                let key = session.id.uuidString
                guard data.analyticsSnapshots?[key] == nil,
                      let analytics = appState.existingHookState(for: session.id)?.analytics,
                      !analytics.isEmpty else { continue }
                var snapshots = data.analyticsSnapshots ?? [:]
                snapshots[key] = SessionAnalyticsSnapshot(
                    sessionID: session.id, endedAt: session.updatedAt,
                    status: session.status, analytics: analytics,
                    compactionCount: appState.existingHookState(for: session.id)?
                        .compactionCount ?? 0,
                    wallClockDurationSeconds: session.wallClockDuration,
                    alignmentWeight: session.alignmentWeight,
                    orgGoal: session.orgGoal)
                data.analyticsSnapshots = snapshots
            }
        }
        // Keep the scorecard mirror in sync with any quit-race backfills.
        appState.analyticsSnapshots = store.data.analyticsSnapshots ?? [:]
    }

    // MARK: - Find Claude Binary

    /// Standard search paths for the Claude CLI binary, in priority order.
    public nonisolated static let claudeBinaryCandidates = [
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

    /// Find the VS Code `code` CLI binary. Pure (no actor state), so `nonisolated`
    /// — the headless daemon calls it off the main actor to gate/launch VS Code.
    public nonisolated static func findVSCodeBinary() -> String? {
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
    public func detectVSCode() {
        appState.vsCodeAvailable = Self.findVSCodeBinary() != nil
    }

    /// Open the primary worktree for a session in VS Code (via the host).
    public func openInVSCode(sessionID: UUID) {
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }
        hostBridge.openInEditor(path: wt.worktreePath)
    }

    /// Open a terminal window at the primary worktree path for a session (via the host).
    public func openTerminal(sessionID: UUID) {
        guard let wt = appState.primaryWorktree(for: sessionID) else { return }
        hostBridge.openTerminalWindow(path: wt.worktreePath)
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
            CrowLog.info("[SessionService] tmux not configured; terminal \(t.id) will not render")
            return t
        }
        let session = appState.sessions.first(where: { $0.id == t.sessionID })
        do {
            let binding = try TmuxBackend.shared.registerTerminal(
                id: t.id,
                name: t.name,
                cwd: t.cwd,
                command: t.command,
                trackReadiness: trackReadiness,
                agentKind: session?.agentKind,
                // Covers the Manager, whose terminal is built without
                // `isManaged` but still runs a repainting agent (ADR-0013).
                agentSurface: t.isAgentSurface(session: session),
                extraEnv: Self.artifactsEnv(sessionID: t.sessionID)
            )
            t.tmuxBinding = binding
        } catch {
            CrowLog.info("[SessionService] tmux registerTerminal failed (\(error)); terminal \(t.id) will not render")
        }
        return t
    }
}
