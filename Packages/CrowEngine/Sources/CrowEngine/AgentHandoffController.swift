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

/// Mid-flight agent handoff (CROW-627), extracted from `SessionService`
/// (CROW-1113). Switches a non-Manager session to a different coding agent:
/// preserves identity/worktrees/ticket/links, tears down managed agent
/// terminals, and recreates one seeded with the handoff prompt via the deferred
/// paste. Behavior-preserving: same launch-binary identity gate, same
/// review-refuse gate, same eager strip+seed before teardown, same
/// per-agent gateway/compat-hook handling. The *errors* and resume brief live
/// in `AgentHandoff.swift`; this owns the orchestration. Reaches `appState`, the
/// shared **injected** `JSONStore`, and the launch-gate / Manager / review-strip
/// collaborators through an unowned back-reference (ADR 0012 / #728).
/// `handoffAgent` stays on `SessionService` as a facade.
@MainActor
final class AgentHandoffController {
    unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }

    init(owner: SessionService) { self.owner = owner }

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
        // `launchBinary()`, not `findBinary()` — the gate must ask the same
        // question the launch will. `findBinary()` says "some binary by that
        // name exists", which for a colliding token can be a foreign tool; the
        // handoff would then pass here and fail (or worse, exec the impostor)
        // one step later. `launchBinary()` returns the identity-verified path or
        // nothing, so a Cursor handoff on a box where the only `agent` is
        // grok-build is refused here with a named error (CROW-1058).
        guard target.launchBinary() != nil else {
            throw AgentHandoffError.agentBinaryMissing(targetKind.rawValue)
        }
        // Review-handoff gate. `shouldRefuseReviewHandoff` is now `false` for
        // every registered agent (Antigravity's review dispatch landed in #902),
        // so this never throws today — it's retained as the single place a future
        // review-incapable harness would be refused, kept in lockstep with
        // `AgentsRPCSupport.validateRoleSupportsAgent`. Handing a review session
        // off to Antigravity is safe because the shared launch gate below
        // (`prepareWorktreeForAgentLaunch`, which this handoff routes through)
        // strips the clone's attacker-committed `.agents/` before `agy` launches —
        // there is no bespoke Antigravity handoff arm.
        guard !SessionService.shouldRefuseReviewHandoff(targetKind: targetKind, sessionKind: session.kind) else {
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
                prompt: prompt,
                sessionKind: session.kind
            )
        } catch {
            throw AgentHandoffError.launchFailed(error.localizedDescription)
        }

        // Agent-specific prep before the new process starts. Idempotent file
        // writes — safe to run before teardown. Handoff dispatches via
        // `pendingLaunchCommands`, which `pasteDeferredLaunch` consumes on
        // `.shellReady` (that later paste re-runs this same strip+seed and writes
        // the handed-off session's `.grok/hooks/crow.json`). We do the strip+seed
        // **eagerly here** anyway so it lands before teardown and doesn't depend on
        // the readiness watch firing (which can time out). For a Grok `.review`
        // handoff this strips every project config layer Grok discovers (`.grok/`,
        // `.claude/settings{,.local}.json`, `.cursor/`, repo-root `.mcp.json`) that
        // `prepareReviewClone` only stripped if Grok was the *creation-time* review
        // agent — a handoff flips a review created under another agent onto a clone
        // never stripped for Grok. Same for an Antigravity `.review` handoff — the
        // gate strips `.agents/` (#902 review Red), which is why this PR needs no
        // bespoke Antigravity handoff arm — and, as of CROW-954, same for a Cursor
        // `.review` handoff, whose `.cursor/` the gate now strips too (that is what
        // retired Cursor's own handoff arm below). Seed is a no-op for `.review` /
        // trustless agents.
        SessionService.prepareWorktreeForAgentLaunch(
            agentKind: target.kind, sessionKind: session.kind,
            worktreePath: worktree.worktreePath,
            ownership: SessionService.HookOwnership.snapshot(
                appState,
                crowPath: ClaudeHookConfigWriter.resolveCrowBinary(devRoot: ConfigStore.loadDevRoot())))
        if target.kind == .claudeCode {
            // Claude inherits the workspace AI gateway env on handoff.
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: worktree.worktreePath,
                resolved: owner.workspaceGatewayResolved(for: sessionID))
        } else if SessionService.readsClaudeCompatSettings(target.kind) {
            // #861 review r17/r18 (Yellow 2): a Grok/Codex target compat-loads
            // `.claude/settings.local.json`, so clear any `Authorization: Bearer`
            // env a prior Claude launch wrote — otherwise a corporate gateway
            // credential goes live inside a different vendor's binary. (`.review`
            // already had the whole file deleted by the strip above.) Scoped to
            // compat-loaders — Cursor/OpenCode/Antigravity never read the file, so a
            // clear there is churn + a data-loss risk, not a security gain.
            ClaudeHookConfigWriter.writeGatewayEnv(
                dirPath: worktree.worktreePath, resolved: nil)
        }
        if target.kind == .grok, session.kind != .review {
            // A `.work`/`.job` handoff from Claude/Cursor leaves that prior
            // agent's Crow-managed hook config on disk (same session UUID, same
            // event names Grok registers), which Grok compat-loads alongside its
            // own `.grok/hooks/crow.json` → every hook event fires twice. Strip
            // the prior compat hooks — touches only hook config, never the file's
            // permissions/`env`/non-hook keys (though the Claude arm drops managed
            // event keys wholesale — see helper doc). The incoming Grok config is a
            // separate `.grok/` file. Full double-fire rationale in the helper (r8).
            SessionService.stripPriorCompatHooksForGrokHandoff(worktreePath: worktree.worktreePath)
        }
        // Handing off to Cursor → sync its global Jira MCP (this path selects
        // Cursor without touching config, so the boot-time gate would miss it).
        //
        // No bespoke `.cursor/` strip arm here: the shared
        // `prepareWorktreeForAgentLaunch` above already ran with `target.kind`, so
        // a handoff that flips a review created under Claude/Codex/OpenCode onto
        // Cursor is stripped before launch (#829 review round 10, Red 1 — the
        // hazard is unchanged, only its owner moved). CROW-954 routed Cursor
        // through that gate, which retired the duplicate arm and leaves one strip
        // path per agent, same as Antigravity (CROW-954 review, Green 1).
        if target.kind == .cursor {
            owner.syncCursorMCPBridge()
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

        let prepared = owner.prepareTerminal(raw, trackReadiness: true)
        appState.terminals[sessionID] = unmanaged + [prepared]
        appState.activeTerminalID[sessionID] = prepared.id
        store.mutate { data in
            data.terminals.append(prepared)
        }

        CrowLog.info("[CrowTelemetry agent:handoff] session=\(sessionID.uuidString) from=\(priorKind.rawValue) to=\(targetKind.rawValue) terminal=\(prepared.id.uuidString)")
        return prepared.id
    }
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    @MainActor
    @discardableResult
    public func handoffAgent(
        sessionID: UUID, to targetKind: AgentKind, note: String? = nil
    ) async throws -> UUID {
        try await handoff.handoffAgent(sessionID: sessionID, to: targetKind, note: note)
    }
}
