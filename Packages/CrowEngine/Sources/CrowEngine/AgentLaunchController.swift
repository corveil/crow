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

/// Agent launch (CROW-1113), extracted from `SessionService`. Owns the one
/// pre-launch worktree gate (`prepareWorktreeForAgentLaunch`: review-clone
/// strip → folder-trust seed → main-clone hook reconcile), the deferred paste
/// for brand-new managed terminals (#408), and `launchAgent` (the restored /
/// recovered auto-launch). Behavior-preserving: the launch-command shape, the
/// strip/seed/reconcile order, and the gateway/OTEL gating are unchanged.
/// Reaches `appState`, the shared **injected** `JSONStore`, and the Manager /
/// review-strip collaborators through an unowned back-reference (ADR 0012 /
/// #728). The gate helpers + `HookOwnership` + `launchAgent` stay on
/// `SessionService` as facades so EngineRouter, tests, and the other launch
/// paths call them unchanged.
///
/// **The call sites of `SessionService.prepareWorktreeForAgentLaunch` ARE the
/// answer to "how many launch paths open a review clone"** — `rg
/// prepareWorktreeForAgentLaunch`, never a hand-maintained count.
@MainActor
final class AgentLaunchController {
    unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }
    private var telemetryPort: UInt16? { owner.telemetryPort }

    init(owner: SessionService) { self.owner = owner }

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
            let worktreePath = appState.primaryWorktree(for: sessionID)?.worktreePath
            let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: ConfigStore.loadDevRoot())
            // Strip a Grok `.review` clone's committed config, then pre-seed folder
            // trust — both via the one shared gate (#861 review r11/r14, unified r17).
            // A brand-new managed terminal from `crow new-terminal --command` — how
            // `/crow-workspace` creates `.work` sessions, and how a `.review` clone can
            // be (re)opened in Grok — dispatches here, not through `launchAgent`. Must
            // precede `prepareAgentLaunchText` below, which (re)writes Crow's own clean
            // `.grok/hooks/crow.json`. The strip is a no-op unless this is a Grok
            // `.review` clone; the seed a no-op for `.review` or a trustless agent.
            if let worktreePath {
                Self.prepareWorktreeForAgentLaunch(
                    agentKind: session.agentKind,
                    sessionKind: session.kind,
                    worktreePath: worktreePath,
                    ownership: HookOwnership.snapshot(appState, crowPath: crowPath))
            }
            text = AgentLaunch.prepareAgentLaunchText(
                command: command,
                agent: agent,
                sessionID: sessionID,
                worktreePath: worktreePath,
                crowPath: crowPath,
                telemetryPort: telemetryPort
            ).text
        }
        // Ensure a trailing newline so TmuxBackend.sendText delivers Enter.
        TerminalRouter.send(routedTerminal, text: text.hasSuffix("\n") ? text : text + "\n")
        appState.terminalReadiness[terminalID] = .agentLaunched
    }

    /// Whether to pre-seed the agent's folder-trust store for a launch of
    /// `agentKind` on a `sessionKind` worktree. Pure so the gate is testable
    /// without touching the user's real global trust files.
    ///
    /// Claude seeds unconditionally (its trust file is the only gate; CROW-600).
    /// Codex (#830) and Grok (#859) seed too — but **never a `.review` clone**: its
    /// tree is `gh repo clone` output at the PR author's head, so trusting it would
    /// arm a committed `.codex`/`.grok` hook on launch. Review falls back to the
    /// agent's own trust prompt (the human-gated path), and `prepareReviewClone`
    /// strips committed agent config as defense-in-depth. Cursor/OpenCode/
    /// Antigravity have no folder-trust store *this seeder can write*, so they
    /// never seed here — note that does **not** mean Cursor launches untrusted: it
    /// trusts per-launch via the `--trust` flag (`CursorLaunchArgs.trustSuffix`),
    /// on every kind including `.review` (CROW-954), which is why its review clones
    /// are stripped on every launch path rather than gated by a dialog.
    nonisolated static func shouldSeedFolderTrust(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        switch agentKind {
        case .claudeCode: return true
        case .codex, .grok: return sessionKind != .review
        default: return false
        }
    }

    /// Whether `agentKind` compat-loads Crow's `.claude/settings.local.json` — i.e.
    /// its `env` (which can hold the gateway `Authorization: Bearer`) and `hooks`
    /// run under that harness. Grok and Codex read Claude's project settings for
    /// compatibility; Cursor/OpenCode/Antigravity do not read that file at all.
    ///
    /// Gates the *gateway-env clear* on a non-Claude launch (#861 review r18,
    /// Yellow 2): a compat-loader must have any prior Claude bearer cleared, but
    /// clearing it for a non-reader would be a pure rewrite of a file it never
    /// reads — per-launch churn `Scaffolder` deliberately avoids, and (if the user
    /// hand-edited the file into invalid JSON) a silent overwrite that drops their
    /// `permissions.allow`. Claude itself takes the *write* arm, not the clear arm,
    /// so it's intentionally not listed here. A future compat-loading harness is a
    /// one-line addition.
    nonisolated static func readsClaudeCompatSettings(_ agentKind: AgentKind) -> Bool {
        switch agentKind {
        case .grok, .codex: return true
        default: return false
        }
    }

    /// The AppState facts `ClaudeHookRepair.reconcileMainClone` needs, captured
    /// as values so the reconciliation needs no actor of its own.
    ///
    /// That is what lets the **reaper** run it inside `Task.detached`
    /// (`performDiskCleanup`). The **launch** path deliberately runs it inline on
    /// the MainActor instead — see `reconcileMainCloneHooks` for why detaching
    /// there would race the launch it protects.
    struct HookOwnership: Sendable {
        /// The binary to write into repaired commands. `nil` means nothing can
        /// be repaired, so a foreign block is stripped instead — which still
        /// stops the hook errors.
        let crowPath: String?
        let liveSessionIDs: Set<UUID>
        /// `standardizingPath`-normalized worktree path → owning session.
        let sessionByWorktreePath: [String: UUID]

        /// No binary, no sessions — every directory reads as unowned. For tests
        /// exercising the *other* steps of the launch gate, and as the safe
        /// value when there is nothing to snapshot. Deliberately not a default
        /// argument on `prepareWorktreeForAgentLaunch`: a default is how a new
        /// launch path silently skips reconciliation.
        static let empty = HookOwnership(
            crowPath: nil, liveSessionIDs: [], sessionByWorktreePath: [:])

        @MainActor
        static func snapshot(_ appState: AppState, crowPath: String?) -> HookOwnership {
            HookOwnership(
                crowPath: crowPath,
                liveSessionIDs: Set(appState.sessions.map(\.id)),
                // `uniquingKeysWith`, not `uniqueKeysWithValues`: the latter
                // traps on duplicate keys, and two rows sharing a worktree path
                // is reachable through orphan recovery. Matches
                // `LaunchScaffold.repairStaleHooks`.
                sessionByWorktreePath: Dictionary(
                    appState.worktrees.values.flatMap { $0 }.map {
                        (($0.worktreePath as NSString).standardizingPath, $0.sessionID)
                    },
                    uniquingKeysWith: { first, _ in first }))
        }

        /// The same snapshot with one session treated as already gone — what the
        /// retention reaper needs, since it runs while the session is still in
        /// `AppState`.
        func excluding(sessionID: UUID) -> HookOwnership {
            HookOwnership(
                crowPath: crowPath,
                liveSessionIDs: liveSessionIDs.subtracting([sessionID]),
                sessionByWorktreePath: sessionByWorktreePath.filter { $0.value != sessionID })
        }
    }

    /// Everything that must be applied to a worktree **before an agent process
    /// opens it**, as ONE gate so no launch path can drift (#861 review r17,
    /// Yellow 1 / Green 1). Three independent, each self-gated steps:
    ///
    ///  1. **Strip** a Grok `.review` clone's committed config (`.grok/`,
    ///     `.cursor/`, `.claude/settings{,.local}.json`, repo-root `.mcp.json`)
    ///     BEFORE any hook rewrite, so a hostile hook restored by the review
    ///     skill's `gh pr checkout` can't fire once the clone is (cascade-)trusted.
    ///     Gated to Grok + `.review` via `shouldStripGrokReviewClone`. Same for an
    ///     Antigravity `.review` clone's `.agents/` (`shouldStripAntigravityReviewClone`,
    ///     #902 review Red): `agy` runs committed `.agents/hooks.json` with **no**
    ///     approval gate and Antigravity seeds no trust, so the strip is the *only*
    ///     defense — it MUST re-run here, not just at creation, because the review
    ///     skill's `gh pr checkout` (or a head-advancing re-review) restores the
    ///     attacker's hooks from the PR head. Same again for a Cursor `.review`
    ///     clone's `.cursor/` (`shouldStripCursorReviewClone`, CROW-954): now that
    ///     Cursor seeds `--trust` on review, no folder-trust dialog stands behind
    ///     the strip either, so it joins the every-launch set for the same reason.
    ///  2. **Seed** the agent's folder trust (Claude and — via the per-launch
    ///     `--trust` flag, not this step — Cursor on every kind; Codex/Grok on
    ///     everything but `.review`), gated via `shouldSeedFolderTrust`.
    ///  3. **Reconcile the main clone's** hook block (#915). A linked worktree
    ///     loads the main clone's `.claude/settings.local.json` in addition to
    ///     its own, so a stale block there breaks hooks and telemetry for every
    ///     session on that repo, and a merely foreign one misattributes their
    ///     events. No-op when `worktreePath` is not a linked worktree. Like the
    ///     other two, it runs **inline on the MainActor** — every step of this
    ///     gate must complete before the caller launches the agent, so none of
    ///     them may be detached (`reconcileMainCloneHooks` documents the cost).
    ///
    /// All are no-ops for the agents/kinds/layouts that don't need them, so this
    /// is safe to call from every launch path unconditionally. **The call sites of
    /// this symbol ARE the answer to "how many Grok/Antigravity/Cursor launch paths
    /// open a review clone"** — `rg prepareWorktreeForAgentLaunch`, never a hand-maintained
    /// count (which went stale four rounds running). Today: `pasteDeferredLaunch`,
    /// `launchAgent`, `handoffAgent`, `createManagerTerminal` (seed only — Manager
    /// is never `.review`), and the `send` RPC (`EngineRouter`). `prepareReviewClone`
    /// strips at *clone-creation* time and deliberately does NOT go through here:
    /// it must strip WITHOUT seeding, since the clone is not yet a launch target.
    ///
    /// `ownership` is required rather than defaulted: a default would let a new
    /// launch path silently skip step 3, which is the drift this gate exists to
    /// prevent.
    nonisolated static func prepareWorktreeForAgentLaunch(
        agentKind: AgentKind, sessionKind: SessionKind, worktreePath: String,
        ownership: HookOwnership) {
        if SessionService.shouldStripGrokReviewClone(agentKind: agentKind, sessionKind: sessionKind) {
            SessionService.stripGrokConfigFromReviewClone(clonePath: worktreePath)
        }
        if SessionService.shouldStripAntigravityReviewClone(agentKind: agentKind, sessionKind: sessionKind) {
            SessionService.stripAntigravityConfigFromReviewClone(clonePath: worktreePath)
        }
        if SessionService.shouldStripCursorReviewClone(agentKind: agentKind, sessionKind: sessionKind) {
            SessionService.stripCursorConfigFromReviewClone(clonePath: worktreePath)
        }
        if SessionService.shouldStripMuseReviewClone(agentKind: agentKind, sessionKind: sessionKind) {
            SessionService.stripMuseConfigFromReviewClone(clonePath: worktreePath)
        }
        seedTrustIfNeeded(
            agentKind: agentKind, sessionKind: sessionKind, worktreePath: worktreePath)
        reconcileMainCloneHooks(worktreePath: worktreePath, ownership: ownership)
    }

    /// Step 3 of the launch gate: clear or repair the main clone's inherited
    /// hook block (#915).
    ///
    /// Runs for every agent kind, not just Claude. The inherited file is
    /// `.claude/settings.local.json` either way, and Grok/Codex read Claude-compat
    /// settings — so a Cursor or Codex session in a worktree is just as exposed to
    /// a stale block in the repo's main clone as a Claude one.
    ///
    /// **Runs inline on the MainActor, by design.** `prepareWorktreeForAgentLaunch`
    /// is synchronous and MainActor-bound, and its callers type the agent's launch
    /// command into the pane in the same block — so the reconcile must finish
    /// first. Detaching it (the reflex for blocking I/O under #892) would let the
    /// agent start while the inherited block is still on disk, which is precisely
    /// the failure this exists to prevent. The I/O is bounded to a single `stat`
    /// for anything that is not a linked worktree and three small reads for one
    /// that is; see `ClaudeHookRepair.reconcileMainClone` for the full accounting.
    nonisolated static func reconcileMainCloneHooks(
        worktreePath: String, ownership: HookOwnership) {
        logMainCloneOutcome(ClaudeHookRepair.reconcileMainClone(
            worktreePath: worktreePath,
            crowPath: ownership.crowPath,
            liveSessionIDs: ownership.liveSessionIDs,
            sessionByWorktreePath: ownership.sessionByWorktreePath))
    }

    /// The same reconciliation for a directory already known to be a main clone
    /// — the retention reaper's entry point, where the worktree that would have
    /// resolved it is being deleted.
    nonisolated static func reconcileMainCloneHooks(
        directory: String, ownership: HookOwnership) {
        logMainCloneOutcome(ClaudeHookRepair.reconcileHookBlock(
            inDirectory: directory,
            crowPath: ownership.crowPath,
            liveSessionIDs: ownership.liveSessionIDs,
            sessionByWorktreePath: ownership.sessionByWorktreePath))
    }

    private nonisolated static func logMainCloneOutcome(
        _ outcome: ClaudeHookRepair.MainCloneOutcome) {
        switch outcome {
        case .notAWorktree, .noBlock, .healthy:
            break  // The common case — stay quiet.
        case .repaired(let dir):
            CrowLog.info("[SessionService] repaired inherited hook block in main clone \(dir)")
        case .stripped(let dir):
            CrowLog.info("[SessionService] stripped inherited hook block from main clone \(dir)")
        case .skipped(let dir):
            CrowLog.info(
                "[SessionService] could not reconcile the hook block in main clone \(dir)"
                + " — sessions in this repo's worktrees may keep emitting hook errors.")
        }
    }

    /// Pre-seed the agent's folder trust for `worktreePath` so an unattended launch
    /// isn't blocked (Claude/Codex) or silently hook-skipped (Grok) on the "trust
    /// this folder?" gate. `nonisolated static` so `prepareWorktreeForAgentLaunch`
    /// (and, through it, the `send` RPC in `EngineRouter`) can reach it off the
    /// MainActor. Callers route through `prepareWorktreeForAgentLaunch`, not here
    /// directly, so the strip can't be forgotten alongside the seed.
    /// Gating lives in `shouldSeedFolderTrust`; a real seed failure is audible.
    nonisolated static func seedTrustIfNeeded(
        agentKind: AgentKind, sessionKind: SessionKind, worktreePath: String) {
        guard Self.shouldSeedFolderTrust(agentKind: agentKind, sessionKind: sessionKind) else { return }
        switch agentKind {
        case .claudeCode:
            ClaudeTrustSeeder.seedTrust(projectPath: worktreePath)
        case .codex:
            if case let .failed(msg) = CodexTrustSeeder.seedTrust(projectPath: worktreePath) {
                CrowLog.info("[SessionService] Codex trust seed failed for \(worktreePath): \(msg)")
            }
        case .grok:
            if case let .failed(msg) = GrokTrustSeeder.seedTrust(projectPath: worktreePath) {
                CrowLog.info("[SessionService] Grok trust seed failed for \(worktreePath): \(msg)")
            }
        default:
            break
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

        // Strip a Grok `.review` clone's committed config, then pre-seed folder
        // trust — one shared gate so a launch path can't do one without the other
        // (#861 review r11/r17). Strip MUST precede `writeHookConfig` below (which
        // recreates Crow's clean `.grok/hooks/crow.json`): `launchAgent` fires on
        // every warm crowd restart (`hydrateState` re-arms managed review terminals)
        // and via `crow launch-agent`, and the review skill's `gh pr checkout`
        // restores the attacker's `.grok/hooks/*.json` from the PR head, so the
        // creation-time strip alone is not enough. The strip is a no-op unless this
        // is a Grok `.review` clone; the seed a no-op for `.review` / a trustless
        // agent (never `--dangerously-bypass`; Claude CROW-600, Codex #830, Grok #859).
        let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: ConfigStore.loadDevRoot())
        Self.prepareWorktreeForAgentLaunch(
            agentKind: agent.kind, sessionKind: session.kind,
            worktreePath: worktree.worktreePath,
            ownership: HookOwnership.snapshot(appState, crowPath: crowPath))

        // Write/refresh hook config (Claude path). Codex's writer is a
        // no-op — its global config was installed once at app launch.
        if let crowPath {
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


        // Resolve and apply the workspace's AI gateway for Claude sessions
        // (CROW-402). Write the resolved env block into the worktree's
        // settings.local.json so manual `claude` re-runs inherit it, and build a
        // launch-line prefix for the initial launch. Always called (resolved or
        // nil) so switching a workspace off its gateway clears the stale env
        // keys. Gated to the Claude agent — the ANTHROPIC_* vars are
        // Claude-specific; the Manager uses `managerGateway` instead.
        var gatewayPrefix = ""
        if agent.kind == .claudeCode {
            let gatewayResolved = owner.workspaceGatewayResolved(for: sessionID)
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: worktree.worktreePath, resolved: gatewayResolved)
            gatewayPrefix = ClaudeLaunchArgs.gatewayEnvPrefix(gatewayResolved)
        } else if Self.readsClaudeCompatSettings(agent.kind) {
            // #861 review r17/r18 (Yellow 2): the gateway `env` block carries the
            // workspace's `ANTHROPIC_*` / `Authorization: Bearer` header, and
            // Grok/Codex compat-load `.claude/settings.local.json` (that's exactly
            // why the review-clone strip deletes it). So on a launch of a
            // compat-loading harness — e.g. a `.work` session first run under Claude,
            // then handed off to Grok, relaunched here — actively CLEAR the env
            // (`resolved: nil`) so a prior Claude launch's bearer can't enter it.
            // Scoped to compat-loaders: Cursor/OpenCode/Antigravity never read this
            // file, so a clear there would be a pure rewrite (churn + a data-loss
            // risk on a user's hand-edited `permissions`). `writeGatewayEnv` rewrites
            // whenever a file exists; it only truly no-ops when none is present.
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: worktree.worktreePath, resolved: nil)
        }
        // Cursor worker launching → ensure its global Jira MCP is synced.
        if agent.kind == .cursor {
            owner.syncCursorMCPBridge()
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
        // via `ShellLaunchArgs.evalPromptLaunch`. If that file isn't on disk when the
        // shell substitution runs, the agent launches with an empty string and
        // silently idles. Refuse to dispatch and surface the missing path
        // instead so the user sees why nothing happened.
        if reviewPromptJustDispatched,
           let initialPromptFile = SessionService.initialPromptFileName(for: session.kind) {
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
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    /// The AppState facts `ClaudeHookRepair.reconcileMainClone` needs, captured
    /// as values (see `AgentLaunchController.HookOwnership`).
    typealias HookOwnership = AgentLaunchController.HookOwnership

    public func launchAgent(terminalID: UUID) { launch.launchAgent(terminalID: terminalID) }

    func pasteDeferredLaunch(terminalID: UUID, command: String) {
        launch.pasteDeferredLaunch(terminalID: terminalID, command: command)
    }

    /// The one pre-launch worktree gate (see `AgentLaunchController.prepareWorktreeForAgentLaunch`).
    nonisolated static func prepareWorktreeForAgentLaunch(
        agentKind: AgentKind, sessionKind: SessionKind, worktreePath: String,
        ownership: HookOwnership
    ) {
        AgentLaunchController.prepareWorktreeForAgentLaunch(
            agentKind: agentKind, sessionKind: sessionKind,
            worktreePath: worktreePath, ownership: ownership)
    }

    nonisolated static func shouldSeedFolderTrust(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        AgentLaunchController.shouldSeedFolderTrust(agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func readsClaudeCompatSettings(_ agentKind: AgentKind) -> Bool {
        AgentLaunchController.readsClaudeCompatSettings(agentKind)
    }

    nonisolated static func seedTrustIfNeeded(
        agentKind: AgentKind, sessionKind: SessionKind, worktreePath: String) {
        AgentLaunchController.seedTrustIfNeeded(
            agentKind: agentKind, sessionKind: sessionKind, worktreePath: worktreePath)
    }

    nonisolated static func reconcileMainCloneHooks(worktreePath: String, ownership: HookOwnership) {
        AgentLaunchController.reconcileMainCloneHooks(worktreePath: worktreePath, ownership: ownership)
    }

    nonisolated static func reconcileMainCloneHooks(directory: String, ownership: HookOwnership) {
        AgentLaunchController.reconcileMainCloneHooks(directory: directory, ownership: ownership)
    }
}
