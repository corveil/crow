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

/// Manager-session lifecycle + AI-gateway resolution (CROW-1113), extracted from
/// `SessionService`. Owns ensure/restart/create-Manager, the Manager launch
/// command + hook config + gateway env writes, the Cursor MCP bridge sync, the
/// exit monitor, and the pure workspace-gateway match rules (CROW-402/891/969).
/// Behavior-preserving: same launch-command shape, same per-agent gateway/hook
/// gating, same two-lookup workspace match. Reaches `appState`, the shared
/// **injected** `JSONStore`, and the shared launch-gate / `prepareTerminal`
/// primitives through an unowned back-reference (ADR 0012 / #728).
///
/// KNOWN LIMITATION (#861 review r10, deferred — carried over verbatim in
/// `writeManagerHookConfig`): running Grok as the Manager double-fires hook
/// events, because a prior Claude Manager's devRoot `.claude/settings.local.json`
/// (same fixed `managerSessionID`, same event names) fires alongside Grok's own
/// `.grok/hooks/crow.json`. Left as-is here (the wholesale-removal + concurrent-
/// live-Claude-Manager reasons are on the method); this split does not "fix" it.
@MainActor
final class ManagerSessionController {
    unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }
    private var telemetryPort: UInt16? { owner.telemetryPort }

    init(owner: SessionService) { self.owner = owner }

    // MARK: - Ensure / restart Manager
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
            if SessionService.migrateLegacyManagerKind(&appState.sessions) {
                store.mutate { data in
                    _ = SessionService.migrateLegacyManagerKind(&data.sessions)
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
    func armManagerExitMonitor() {
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
        let claudePath = SessionService.findClaudeBinary() ?? "claude"
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
    /// inherit the same routing as the initial launch (CROW-402). `managerKind` gates
    /// the bearer: a non-Claude Manager (Grok/Codex) compat-loads this file, so it
    /// gets `resolved: nil` — clearing any prior Claude Manager's token rather than
    /// re-applying it into another vendor's env on every hydrate (#861 review r17/r18,
    /// Yellow 2). Scoped to compat-loaders: a Cursor/OpenCode/Antigravity Manager
    /// never reads this file, so it's left untouched (no per-hydrate rewrite churn).
    /// Mirrors the `createManagerTerminal` write site.
    func writeManagerGatewayEnv(managerKind: AgentKind) {
        guard let devRoot = ConfigStore.loadDevRoot() else { return }
        if managerKind == .claudeCode {
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: devRoot, resolved: managerGatewayResolved())
        } else if SessionService.readsClaudeCompatSettings(managerKind) {
            ClaudeHookConfigWriter.writeGatewayEnv(dirPath: devRoot, resolved: nil)
        }
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
    func writeManagerHookConfig(for session: Session, dirPath: String) {
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
        // Claude is skipped from this loop — but NOT because a stale Claude config
        // is inert. For a **Grok** Manager it is not: Grok compat-loads the
        // devRoot's `.claude/settings.local.json` (the same fact that makes
        // `stripGrokConfigFromReviewClone` / `stripPriorCompatHooksForGrokHandoff`
        // strip it on the review + handoff paths). It's skipped because Claude's
        // `removeHookConfig` is wholesale — it drops the entire managed event key,
        // taking any user's hand-authored devRoot Manager hook under that name with
        // it (unlike Cursor's marker-scoped removal) — and the devRoot commonly
        // holds exactly such user config, so auto-stripping on every Manager boot
        // would risk dropping it.
        //
        // KNOWN LIMITATION (#861 review r10, deferred): running Grok as the Manager
        // therefore double-fires — the prior Claude Manager's devRoot
        // `.claude/settings.local.json` (same fixed managerSessionID, same event
        // names) fires alongside Grok's own `.grok/hooks/crow.json`. Left as-is for
        // the wholesale-removal reason above, and because a *concurrent* live Claude
        // Manager in the same devRoot (`crow create-manager --agent grok` beside a
        // Claude primary) has load-bearing hooks we must not strip — so a blanket
        // extension would break that. Mitigation if it bites: clear the devRoot
        // `.claude/settings.local.json` by hand when switching the Manager to Grok.
        for other in AgentRegistry.shared.allAgents()
            where other.kind != session.agentKind && other.kind != .claudeCode {
            other.hookConfigWriter.removeHookConfig(worktreePath: dirPath)
        }
        guard let agent = AgentRegistry.shared.agent(for: session.agentKind),
              let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: ConfigStore.loadDevRoot()) else { return }
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
    func syncCursorMCPBridge() {
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

    /// The Manager's gateway as a ``SessionService.GatewayMatch``, for read paths that report a
    /// session's gateway uniformly (CROW-969).
    ///
    /// A Manager session has no worktree and no PR links, so `gatewayMatch` can
    /// never claim one — without this arm, `crow get-session` would report
    /// "no gateway" for a Manager that has one, recreating the exact blind spot
    /// this ticket exists to close. Cheap for the same reason as
    /// ``workspaceGatewayMatch(for:)``: config read only, no `op read`.
    public func managerGatewayMatch() -> SessionService.GatewayMatch? {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot)
        else { return nil }
        return SessionService.GatewayMatch(managerGateway: config.managerGateway)
    }

    /// Resolve the AI gateway for a non-Manager session (CROW-402, CROW-891).
    ///
    /// Delegates the "which workspace claims this session" question to
    /// ``workspaceGatewayMatch(for:)`` — see there for the two-lookup rule — then
    /// resolves that workspace's gateway and logs the decision.
    ///
    /// Returns nil when nothing claims the session, or when the workspace that
    /// does has no gateway. Deliberate and logged, not an oversight: the callers
    /// then **unset** `ANTHROPIC_*` so a global `~/.zshrc` export (or a sibling
    /// workspace's gateway) can't bleed into a session Crow has no gateway for.
    /// There is no `managerGateway` fallback — the Manager's gateway is the
    /// Manager's alone.
    ///
    /// ⚠️ Calls ``GatewayResolver/resolve(_:resolveSecret:)``, which shells out to
    /// `op read` with a **15-second timeout per header**. This is a launch-path
    /// method only. A read RPC wanting the same information must call
    /// ``workspaceGatewayMatch(for:)`` instead, which touches no subprocess.
    func workspaceGatewayResolved(for sessionID: UUID) -> GatewayResolver.Resolved? {
        let match = workspaceGatewayMatch(for: sessionID)
        logGatewayLaunchDecision(sessionID: sessionID, match: match)
        guard let gateway = match?.gateway, !gateway.isEmpty else { return nil }
        return GatewayResolver.resolve(gateway)
    }

    /// One line per Claude launch/handoff naming where the session's gateway came
    /// from, so a rejection at the gateway can be traced to a workspace instead of
    /// guessed at (CROW-969). Before this, a bad gateway surfaced only as a bare
    /// "API error" with nothing pointing at the gateway, the workspace, or the
    /// header.
    ///
    /// Header **names** only — a value is a credential, and this line goes to
    /// stderr and the unified log. Headers whose `op://` reference fails to
    /// resolve are not re-reported here; `GatewayResolver` already names each one
    /// it drops. Clean division: this line says *which gateway*, that one says
    /// *which header failed*.
    private func logGatewayLaunchDecision(sessionID: UUID, match: SessionService.GatewayMatch?) {
        let prefix = "[SessionService] Gateway for session \(sessionID)"
        guard let match else {
            // Also covers an unreadable devRoot/config. Two distinct lines, because
            // "no workspace claims this repo" and "this session has no PR link to
            // claim by" need different fixes.
            if let slug = Self.repoSlug(fromPRLinks: appState.links(for: sessionID)) {
                CrowLog.info(
                    "\(prefix): No workspace claims repo \(slug); ANTHROPIC_* will be unset")
            } else {
                CrowLog.info(
                    "\(prefix): no workspace claims this session; ANTHROPIC_* will be unset")
            }
            return
        }
        let via = "workspace '\(match.workspaceName ?? "—")' (matched by \(match.source.rawValue))"
        guard let gateway = match.gateway, !gateway.isEmpty else {
            CrowLog.info("\(prefix): \(via) has no gateway; ANTHROPIC_* will be unset")
            return
        }
        let names = gateway.customHeaders.keys.sorted().joined(separator: ", ")
        CrowLog.info("\(prefix): \(via) -> \(gateway.baseURL), headers: \(names)")
    }

    /// Which workspace claims a session, against live config — the cheap half of
    /// ``workspaceGatewayResolved(for:)``.
    ///
    /// Cheap by construction: two small file reads plus a JSON decode, then pure
    /// string work. **No subprocess**, unlike `workspaceGatewayResolved`, so this
    /// is the one safe to call from a read RPC on the MainActor.
    public func workspaceGatewayMatch(for sessionID: UUID) -> SessionService.GatewayMatch? {
        guard let devRoot = ConfigStore.loadDevRoot(),
              let config = ConfigStore.loadConfig(devRoot: devRoot)
        else { return nil }
        return Self.gatewayMatch(
            worktreePath: appState.primaryWorktree(for: sessionID)?.worktreePath,
            prLinks: appState.links(for: sessionID),
            devRoot: devRoot,
            config: config)
    }

    /// Decide which workspace claims a session, from inputs the caller has already
    /// gathered. Two lookups, in order:
    ///
    /// 1. **Path** — `.work`/`.job` worktrees live at `{devRoot}/{workspace}/…`,
    ///    so the first component under devRoot names the workspace. Fast, and the
    ///    only lookup that can tell apart two workspaces sharing a repo.
    /// 2. **Repo slug** — a `.review` clone lives at `{devRoot}/crow-reviews/…`,
    ///    so path math yields the literal `"crow-reviews"` and matches nothing.
    ///    That silently unset the gateway for *every* review (CROW-891). Fall back
    ///    to the PR link's `owner/repo` and ask which workspace claims it.
    ///
    /// Because the two lookups can land on *different* workspaces for the same
    /// repo, a work session and a review of that repo's PR may resolve to
    /// different gateways — which is exactly the divergence CROW-969 found, and
    /// why ``SessionService.GatewayMatch/source`` is reported rather than discarded.
    ///
    /// The match carries its workspace's `gateway` even when that is nil, so
    /// callers can tell "no workspace claimed this session" from "a workspace
    /// claimed it and has no gateway" — two states with identical behavior but
    /// different fixes.
    ///
    /// Pure — no `ConfigStore`, no actor state — so the whole rule is directly
    /// unit-testable, which the resolver it was extracted from never was
    /// (ADR 0012). Logs nothing: `get-session` calls this on every read, and a
    /// resolution decision is a *launch*-time event.
    public nonisolated static func gatewayMatch(
        worktreePath: String?,
        prLinks: [SessionLink],
        devRoot: String,
        config: AppConfig
    ) -> SessionService.GatewayMatch? {
        // 1. Path fast path. Case-insensitive: APFS is case-preserving but
        // case-insensitive, so an on-disk folder can differ in case from the
        // configured workspace name and still be the same directory.
        //
        // Reserved dev-root directories are skipped rather than looked up. A
        // review clone's first path component is `crow-reviews`, so a workspace
        // that had taken that name would match here and bind *every* review to
        // itself, shadowing the slug fallback below. `validateName` now rejects
        // the name, but a config written before that still has to resolve
        // correctly.
        if let worktreePath,
           let wsName = workspaceName(forWorktreePath: worktreePath, devRoot: devRoot),
           !DevRootLayout.isReservedWorkspaceName(wsName),
           let workspace = config.workspaces.first(where: { $0.name.lowercased() == wsName.lowercased() }) {
            return SessionService.GatewayMatch(workspace: workspace, source: .worktreePath)
        }

        // 2. Repo-slug fallback — reviews, and any session whose worktree isn't
        // under a configured workspace folder. Gated on the precondition rather
        // than `session.kind == .review` because work sessions also carry `.pr`
        // links once their PR opens, and one whose path lookup failed should
        // inherit its repo's workspace gateway too.
        if let slug = repoSlug(fromPRLinks: prLinks),
           let workspace = config.workspace(forRepoSlug: slug) {
            return SessionService.GatewayMatch(workspace: workspace, source: .repoSlug)
        }

        return nil
    }

    /// First parseable `owner/repo` slug among a session's PR links, or nil.
    ///
    /// Uses the same `Session.parseReviewPR` that `createReviewSession` used to
    /// build the clone directory, so gateway resolution can never disagree with
    /// what creation decided the repo was. Extracted as a pure function so the
    /// link-selection rule is unit-testable without standing up the terminal
    /// machinery (same reasoning as `shouldStripCursorReviewClone`).
    ///
    /// GitLab MR URLs don't fit `parseReviewPR`'s shape and yield a slug that
    /// claims nothing — which lands on "unset", exactly today's behavior. The
    /// mis-parse is upstream of here (clone naming uses the same parser).
    nonisolated static func repoSlug(fromPRLinks links: [SessionLink]) -> String? {
        for link in links where link.linkType == .pr {
            if let parsed = Session.parseReviewPR(url: link.url) {
                return "\(parsed.owner)/\(parsed.repo)"
            }
        }
        return nil
    }

    /// Derive the workspace folder name from a worktree path:
    /// `{devRoot}/{workspace}/{repo-folder}` → `{workspace}`. Pure path math, so
    /// `nonisolated` — it touches no instance state and is unit-testable without
    /// hopping to the main actor.
    ///
    /// Public because this string *is* the link between a session and its
    /// workspace — there is no id on either side — so `workspace-edit` and
    /// `workspace-remove` need it to count what a rename or removal would orphan
    /// (CROW-809).
    ///
    /// Review clones live at `{devRoot}/crow-reviews/{repo}-pr-{N}`, so this
    /// returns the literal `"crow-reviews"` for them — never a workspace name.
    /// That's what `workspaceGatewayResolved`'s slug fallback exists for
    /// (CROW-891).
    public nonisolated static func workspaceName(forWorktreePath path: String, devRoot: String) -> String? {
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
        // CROW-600: a brand-new devRoot would otherwise block the Manager on the
        // agent's trust gate. No-ops when already trusted (#830 Codex, #861 Grok).
        // ⚠️ Grok's folder trust cascades to subdirectories, so seeding the devRoot
        // makes every review clone under `{devRoot}` Grok-trusted — the review-clone
        // strip is therefore the *only* guard between that cascade and committed-hook
        // RCE, so every path that opens Grok in a review clone MUST strip before it
        // opens. That invariant now lives in ONE place: every launch path routes
        // through `prepareWorktreeForAgentLaunch` (grep its call sites), so a new
        // path can't forget the strip (#861 review r8/r17). Manager sessions are
        // never `.review`, so here the shared helper only seeds (the strip no-ops).
        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: session.agentKind, sessionKind: session.kind, worktreePath: cwd,
            ownership: SessionService.HookOwnership.snapshot(
                appState,
                crowPath: ClaudeHookConfigWriter.resolveCrowBinary(devRoot: ConfigStore.loadDevRoot())))
        // CROW-402: write the Manager gateway env block to {devRoot}/.claude so
        // manual `claude` re-runs in this terminal inherit the same routing. The
        // Manager's cwd is the devRoot. #861 review r17/r18 (Yellow 2): the env can
        // carry an `Authorization: Bearer`, and a Grok/Codex Manager compat-loads
        // `.claude/settings.local.json` in a devRoot the seed above just trusted —
        // so write the bearer only for a Claude Manager, and for a compat-loading
        // Manager actively CLEAR it (`resolved: nil`) so a prior Claude Manager's
        // token can't linger in a now-trusted devRoot. A Cursor/OpenCode/Antigravity
        // Manager never reads the file, so it's left untouched (no rewrite churn).
        if session.agentKind == .claudeCode {
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: cwd, resolved: managerGatewayResolved())
        } else if SessionService.readsClaudeCompatSettings(session.agentKind) {
            ClaudeHookConfigWriter.writeGatewayEnv(dirPath: cwd, resolved: nil)
        }
        let rawTerminal = SessionTerminal(
            sessionID: session.id,
            name: session.name,
            cwd: cwd,
            command: command
        )

        let terminal = owner.prepareTerminal(rawTerminal, trackReadiness: false)
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
    /// the web RPC and the daemon RPC (`createManagerSession` directly). Routing the registry
    /// gate here (CROW-593; #834, via `AgentRegistry.registeredKind`) keeps the
    /// two symmetric — neither can persist a Manager with an unregistered kind
    /// that `managerCommand` would then silently launch as the default.
    func resolvedManagerAgentKind(_ explicit: AgentKind?) -> AgentKind {
        AgentRegistry.shared.registeredKind(explicit) ?? appState.agentKind(for: .manager)
    }
}

// MARK: - Gateway resolution reporting (CROW-969)

extension SessionService {
    /// Which lookup claimed a session's gateway.
    ///
    /// Raw values are the strings `crow get-session` reports as
    /// `workspace_match`, so they are API — renaming one breaks scripts.
    public enum GatewayMatchSource: String, Sendable {
        /// `{devRoot}/{workspace}/…` path math — work and job sessions.
        case worktreePath = "worktree_path"
        /// The PR link's `owner/repo`, matched against a workspace's
        /// `alwaysInclude`/`autoReviewRepos` — the CROW-891 review-clone path.
        case repoSlug = "repo_slug"
        /// The Manager's own gateway, which belongs to no workspace. Produced
        /// only by ``SessionService/managerGatewayMatch()``, never by the pure
        /// ``SessionService/gatewayMatch(worktreePath:prLinks:devRoot:config:)``,
        /// so it can't leak into the workspace launch log.
        case manager
    }

    /// Which workspace claims a session, and how.
    ///
    /// Carries the claimed workspace's `gateway` — **possibly nil** — so callers
    /// can tell "no workspace claimed this session" from "a workspace claimed it
    /// and has no gateway". Those two states produce identical behavior
    /// (`ANTHROPIC_*` unset) but need different fixes, and collapsing them is part
    /// of why CROW-969 took so long to diagnose.
    public struct GatewayMatch: Sendable {
        /// Nil for ``GatewayMatchSource/manager`` — the Manager gateway is not a
        /// workspace's.
        public var workspaceID: UUID?
        public var workspaceName: String?
        public var source: GatewayMatchSource
        public var gateway: WorkspaceGateway?

        init(workspace: WorkspaceInfo, source: GatewayMatchSource) {
            self.workspaceID = workspace.id
            self.workspaceName = workspace.name
            self.source = source
            self.gateway = workspace.gateway
        }

        init(managerGateway: WorkspaceGateway?) {
            self.workspaceID = nil
            self.workspaceName = nil
            self.source = .manager
            self.gateway = managerGateway
        }
    }
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    public func ensureManagerSession(devRoot: String) { manager.ensureManagerSession(devRoot: devRoot) }
    public func restartManager(devRoot: String) { manager.restartManager(devRoot: devRoot) }
    func armManagerExitMonitor() { manager.armManagerExitMonitor() }

    func managerCommand(for session: Session) -> String { manager.managerCommand(for: session) }
    func managerCommand(sessionName: String) -> String { manager.managerCommand(sessionName: sessionName) }
    func writeManagerGatewayEnv(managerKind: AgentKind) { manager.writeManagerGatewayEnv(managerKind: managerKind) }
    func writeManagerHookConfig(for session: Session, dirPath: String) {
        manager.writeManagerHookConfig(for: session, dirPath: dirPath)
    }
    func syncCursorMCPBridge() { manager.syncCursorMCPBridge() }
    func workspaceGatewayResolved(for sessionID: UUID) -> GatewayResolver.Resolved? {
        manager.workspaceGatewayResolved(for: sessionID)
    }

    public func managerGatewayMatch() -> GatewayMatch? { manager.managerGatewayMatch() }
    public func workspaceGatewayMatch(for sessionID: UUID) -> GatewayMatch? {
        manager.workspaceGatewayMatch(for: sessionID)
    }

    @discardableResult
    public func createManagerSession(name: String, cwd: String, agentKind override: AgentKind? = nil) -> UUID {
        manager.createManagerSession(name: name, cwd: cwd, agentKind: override)
    }
    func resolvedManagerAgentKind(_ explicit: AgentKind?) -> AgentKind {
        manager.resolvedManagerAgentKind(explicit)
    }

    /// Decide which workspace claims a session (see `ManagerSessionController.gatewayMatch`).
    public nonisolated static func gatewayMatch(
        worktreePath: String?, prLinks: [SessionLink], devRoot: String, config: AppConfig
    ) -> GatewayMatch? {
        ManagerSessionController.gatewayMatch(
            worktreePath: worktreePath, prLinks: prLinks, devRoot: devRoot, config: config)
    }

    /// First `owner/repo` slug among a session's PR links (see `ManagerSessionController.repoSlug`).
    nonisolated static func repoSlug(fromPRLinks links: [SessionLink]) -> String? {
        ManagerSessionController.repoSlug(fromPRLinks: links)
    }

    /// Derive the workspace folder name from a worktree path (see `ManagerSessionController.workspaceName`).
    public nonisolated static func workspaceName(forWorktreePath path: String, devRoot: String) -> String? {
        ManagerSessionController.workspaceName(forWorktreePath: path, devRoot: devRoot)
    }
}
