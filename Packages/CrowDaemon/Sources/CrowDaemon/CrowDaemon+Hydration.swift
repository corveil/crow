import CrowAntigravity
import CrowClaude
import CrowCodex
import CrowCore
import CrowCursor
import CrowGrok
import CrowMuse
import CrowOpenCode
import CrowPersistence
import Foundation

/// AppState seeding, agent registration, and config→state sync extracted from
/// `CrowDaemon` (CROW-1279). Claude stays unconditionally available (#879);
/// other harnesses go through `registerDiscovered`.
extension CrowDaemon {
    @MainActor
    static func seedAppState(from store: JSONStore) -> AppState {
        let appState = AppState()
        reseed(appState, from: store)
        return appState
    }

    /// Register the coding agents in this process's `AgentRegistry`, mirroring
    /// the desktop app's registration (AppDelegate): Claude is always present
    /// and launchable; Codex/Cursor/OpenCode/Antigravity are all registered as
    /// *known* so they surface in the pickers, but marked **available** only
    /// when their binary resolves on PATH (or a `defaults.binaries.*` override).
    /// Unavailable ones show greyed-out with a help tooltip and stay unlaunchable
    /// (#879). Reads binary overrides from the same on-disk config the app uses
    /// so both hosts gate identically (CROW-581, M-B).
    @MainActor
    static func registerAgents(devRoot: String) async {
        if let config = ConfigStore.loadConfig(devRoot: devRoot) {
            BinaryOverrides.shared.set(config.defaults.binaries)
        }

        // Register a discovered agent as *known*, marking it available iff its
        // binary resolves **and** passes identity checks. `AgentDiscovery.evaluate`
        // owns the decision (resolve → probe a non-override match); this wrapper
        // only writes the registry + logs, so the "greyed-out row ⇒ matching boot
        // log line" contract (#879) holds for all three outcomes.
        //
        // A resolved binary is identity-probed for collision-prone launch tokens
        // so a foreign same-named binary is shown disabled rather than falsely
        // active: Grok Build, whose `grok` token collides with
        // `superagent-ai/grok-cli` (CROW-911), and Cursor, whose legacy `agent`
        // alias collides with grok-build's own `~/.grok/bin/agent` (CROW-989).
        // The probe is skipped for an explicit `defaults.binaries.<kind>` pin
        // (`.available(viaOverride:)`): the user has named the exact binary, so
        // it's authoritative.
        func registerDiscovered(_ agent: any CodingAgent) async {
            switch await AgentDiscovery.evaluate(agent) {
            case .unavailableNotFound:
                AgentRegistry.shared.registerKnown(agent, available: false)
                log("\(agent.displayName) agent not found on PATH — shown disabled in the picker")
            case .unavailableFailedProbe(let path):
                AgentRegistry.shared.registerKnown(agent, available: false)
                log("\(agent.displayName) binary at \(path) failed the identity probe (likely a different tool sharing the name) — shown disabled; pin the real path via defaults.binaries.\(agent.kind.rawValue)")
            case .available(let path, _):
                AgentRegistry.shared.registerKnown(agent, available: true)
                log("\(agent.displayName) agent registered at \(path)")
            }
        }

        // Claude Code is the baseline harness and the registry fallback default,
        // so it's registered available **unconditionally** — deliberately without
        // probing `findBinary()`. Greying out the default would break the common
        // case, and if `claude` were somehow off-PATH the Manager's own legacy-
        // `claude` fallback (`managerCommand`) still applies. This one exemption
        // to the honest-availability rule is intentional; don't "fix" it.
        AgentRegistry.shared.registerKnown(ClaudeCodeAgent(), available: true)

        await registerDiscovered(OpenAICodexAgent())
        await registerDiscovered(CursorAgent())
        await registerDiscovered(OpenCodeAgent())
        // Google Antigravity (`agy`) — Tier-2 / experimental (#860). Surfaced in
        // the picker regardless of install state; off-PATH ⇒ shown disabled with
        // a "not found on PATH" tooltip rather than silently absent (#879,
        // updating ADR 0014). Crow never installs `agy` itself — it only resolves
        // whatever the official `antigravity.google` installer placed.
        await registerDiscovered(AntigravityAgent())
        // Grok Build (`grok`, xai-org/grok-build) — #859. `registerDiscovered`
        // uses the override-aware `findBinary()`, so a `defaults.binaries.grok`
        // pin resolves the `superagent-ai/grok-cli` name collision; without a
        // pin, a bare PATH match is identity-probed (`grok --version`/`--help`)
        // so the foreign `grok` is shown disabled rather than falsely active
        // (CROW-911); genuinely off-PATH ⇒ shown disabled too (#879).
        await registerDiscovered(GrokAgent())
        // Muse Code (`muse`, Meta) — #1033. Tier-2 / experimental: closed-source
        // and Meta-auth-locked (same class as Antigravity). Surfaced in the
        // picker regardless of install state; off-PATH ⇒ shown disabled (#879).
        // A bare PATH match is identity-probed because `muse` collides with the
        // Muse Sequencer; an explicit `defaults.binaries.muse` pin skips the
        // probe. Crow never installs `muse` itself.
        await registerDiscovered(MuseAgent())
    }

    /// (Re)populate `appState` from the store snapshot — sessions + their
    /// worktrees, terminals, and links. Called at boot and by the live-reload
    /// poll when the desktop app writes `store.json`. (The app's fuller
    /// `SessionService.hydrateState` — hook state, migrations, agent wiring — is
    /// AppKit-bound and out of scope for the daemon.)
    @MainActor
    static func reseed(_ appState: AppState, from store: JSONStore) {
        let data = store.data
        appState.sessions = data.sessions
        appState.worktrees = [:]
        appState.terminals = [:]
        appState.links = [:]
        for session in appState.sessions {
            appState.worktrees[session.id] = data.worktrees.filter { $0.sessionID == session.id }
            appState.terminals[session.id] = data.terminals.filter { $0.sessionID == session.id }
            appState.links[session.id] = data.links.filter { $0.sessionID == session.id }
        }
        // Restore persisted hook state so the sidebar can show activity dots
        // (working / needs-attention / done), mirroring the desktop app.
        if let hookStates = data.hookStates {
            let liveIDs = Set(appState.sessions.map(\.id))
            for (key, snapshot) in hookStates {
                guard let sid = UUID(uuidString: key), liveIDs.contains(sid) else { continue }
                appState.restoreHookState(snapshot, for: sid)
            }
        }
        // Mirror persisted analytics snapshots so the per-session strip
        // (CROW-722) and the scorecard (#724) survive a daemon restart. Both read
        // `appState.analyticsSnapshots`, and nothing else populates it in crowd —
        // `SessionService.hydrateState` (the app's fuller restore) is AppKit-bound
        // and never runs here, so without this the snapshot fallback is dead for
        // any session that completed before this daemon process started (#736 review).
        appState.analyticsSnapshots = data.analyticsSnapshots ?? [:]
        // Same reasoning for the ungraded Manager rollups (#767): `get-scorecard`
        // reads `appState.managerUsageWeekly`, `hydrateState` never runs here, and
        // the detached launch rebuild may not have finished (or never runs when
        // telemetry is off). Without this mirror, persisted Manager weeks in
        // store.json stay invisible on the cold / telemetry-off path — the very
        // #745 empty-state invisibility this restores.
        appState.managerUsageWeekly = data.managerUsageWeekly ?? [:]
    }

    /// Mirror the config-derived `AppState` fields the desktop app syncs in
    /// `AppDelegate` (remote-control, the three auto-permission-mode gates, and
    /// the board exclude/ignore filters). In headless crowd nothing else copies
    /// these out of `config.json`, so without this: the ticket board ignores
    /// `defaults.excludeTicketRepos`, and Manager/job/work sessions never see
    /// their configured auto-permission mode or `--rc`. `reseed` (store-driven)
    /// leaves these fields untouched, so this is the sole writer — called at boot
    /// (before the first takeover's `ensureManagerSession`) and each board tick so
    /// runtime settings edits take effect within one poll (CROW-581).
    @MainActor
    static func applyConfigToAppState(_ appState: AppState, devRoot: String) {
        guard let config = ConfigStore.loadConfig(devRoot: devRoot) else { return }
        appState.remoteControlEnabled = config.remoteControlEnabled
        appState.managerAutoPermissionMode = config.managerAutoPermissionMode
        appState.jobsAutoPermissionMode = config.jobsAutoPermissionMode
        appState.reviewAutoPermissionMode = config.reviewAutoPermissionMode
        appState.coderViewAutoPermissionMode = config.coderViewAutoPermissionMode
        appState.excludeReviewRepos = config.effectiveExcludeReviewRepos
        appState.excludeTicketRepos = config.defaults.excludeTicketRepos
        appState.ignoreReviewLabels = config.defaults.ignoreReviewLabels
        // Configured agent selection. Without this the headless daemon always
        // resolves the built-in default (.claudeCode) via appState.agentKind(for:),
        // so the Settings manager/coder agent pickers are ignored on
        // restart/respawn even though they persist to config (CROW-433 / CROW-581).
        // Route through the single choke point so no field is silently missed on
        // any sync path and the next launched job resolves the just-saved agent
        // without a config reload (CROW-733).
        appState.applyAgentConfig(config)
    }
}
