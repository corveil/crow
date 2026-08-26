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

/// Review-session creation + clone preparation (CROW-1113), extracted from
/// `SessionService`. Owns `createReviewSession`, the off-main-actor
/// `prepareReviewClone`, every per-agent review-clone strip (the security
/// boundary for a hostile PR head — Grok/Cursor/Antigravity/Muse/Codex), the
/// Grok-handoff compat-hook strip, and the review-prompt builders. This is a
/// **behavior-preserving** move: the strip rules, prompt format, clone/checkout
/// steps, and kickoff dedup are unchanged (extract the region as-is; the
/// behavior is the spec). Reaches `appState`, the shared **injected**
/// `JSONStore`, `providerManager`, and the shared shell / `prepareTerminal`
/// primitives through an unowned back-reference (ADR 0012 / #728). The static
/// strips/prompt helpers and `createReviewSession` are re-exposed on
/// `SessionService` as facades so the launch gate, tests, and other modules
/// call them unchanged.
@MainActor
final class ReviewSessionController {
    unowned let owner: SessionService
    private var appState: AppState { owner.appState }
    private var store: JSONStore { owner.store }
    private var providerManager: ProviderManager? { owner.providerManager }
    private var telemetryPort: UInt16? { owner.telemetryPort }

    init(owner: SessionService) { self.owner = owner }

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
        // The duplicate/round guard lives *below*, after `fetchPRMetadata`,
        // because deciding it needs the PR's real head — see the note there.

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
        // Which severities gate this review's verdict (CROW-963). Resolved by repo
        // slug, NOT by worktree path: a review clone lives at
        // `{devRoot}/crow-reviews/…`, whose first path component matches no
        // workspace — the same trap that silently unset the gateway for every
        // review in CROW-891. Sampled here, on the main actor and before the
        // `await`s, for the same reason `reviewAgentKind` is: a config save
        // landing mid-clone would otherwise render a policy the session was never
        // launched under. Nil (no workspace claims the repo, or it never set the
        // field) means Crow's default, not "nothing blocks".
        let reviewBlocking = ConfigStore.loadConfig(devRoot: devRoot)?
            .workspace(forRepoSlug: repoSlug)?
            .effectiveReviewBlockingSeverities ?? ReviewSeverity.defaultBlocking
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

        // Duplicate/round guard — the *one* kickoff decision, run through the
        // same pure function the daemon's auto-review hook uses so the
        // manual/board path and the `autoReviewRepos` path can't disagree about
        // whether a round is still open (CROW-945; before this there were two
        // divergent dedup rules and only the auto path could ever re-review).
        //
        // Deliberately placed here, after the metadata fetch, for two reasons.
        // It needs the PR's *real* head to tell "already covered" from "the
        // author pushed and this is a new round" — `appState.reviewRequests` is
        // up to a poll stale and is simply absent for a PR hidden by the board
        // filters or for a voluntary `crow start-review` on a PR nobody asked
        // you to review, which would pin the decision to `.skip` forever with
        // no way out. And reading `existingReviewSession` *after* the awaits
        // keeps the CROW-406 property the old top-of-function check had: a
        // session that landed while we were fetching is still seen. (Callers
        // are serialized on the review kickoff queue, so this is belt and
        // braces.) The fetch is not extra work — the clone below needs it
        // regardless.
        if let existing = appState.existingReviewSession(forPRURL: prURL) {
            let action = IssueTracker.reviewKickoffAction(
                reviewSessionID: existing.id,
                headRefOid: prMetadata.headRefOid,
                linkedSession: existing,
                existingByPRSessionID: existing.id
            )
            switch action {
            case .skip, .create:
                // `.create` is unreachable here (it requires no existing
                // session) — treat it as `.skip` rather than racing the live
                // session with a second one for the same PR.
                CrowLog.info("[SessionService] Skipping duplicate review session for \(prURL); reusing \(existing.id)")
                if selectAfterCreate { appState.selectedSessionID = existing.id }
                return existing.id
            case .reReview(let staleID):
                // Retire the stale round before creating the new one. Called
                // directly rather than through `appState.onCompleteSession`:
                // that callback is optional and only CrowDaemon wires it, so a
                // nil one would complete nothing and then leave two live
                // sessions on one PR — the CROW-406 double-session this guard
                // exists to prevent. Completing (not deleting) also writes the
                // round's end-of-run analytics snapshot, and makes it invisible
                // to `existingReviewSession`, which is what lets the create
                // below proceed.
                CrowLog.info("[SessionService] PR head advanced past review session \(staleID); completing it and starting a new round for \(prURL)")
                self.owner.completeSession(id: staleID)
            }
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
                    reviewBlocking: reviewBlocking,
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
        let preparedTerminal = self.owner.prepareTerminal(terminal, trackReadiness: true)

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

    /// Whether Cursor is about to open a `.review` clone and must therefore strip
    /// its committed `.cursor/` first — the launch-path gate, as opposed to the
    /// creation-time (`prepareReviewClone`) arm.
    ///
    /// This subsumes the former `shouldStripCursorReviewCloneOnHandoff`, retired in
    /// the CROW-954 review (Green 1): `handoffAgent` routes through
    /// `prepareWorktreeForAgentLaunch` with the *target* kind, so the handoff case
    /// — flipping a review created under another agent onto Cursor, in a clone
    /// `prepareReviewClone` never stripped for Cursor (#829 review round 10, Red 1)
    /// — is covered here, leaving one strip path per agent as with Antigravity.
    ///
    /// Added with CROW-954, which made Cursor seed `--trust` on `.review`. Before
    /// that, a review clone launched untrusted and Cursor's folder-trust dialog
    /// stood between a restored `.cursor/hooks.json` and execution, so stripping at
    /// creation was enough. Now the clone launches pre-trusted, so the strip is the
    /// **only** thing between a hostile committed hook and the reviewer's machine —
    /// exactly the position Antigravity is in (`shouldStripAntigravityReviewClone`,
    /// #902 review Red), and for the same reason it must re-fire on every launch,
    /// not just at creation: the review skill's `gh pr checkout` (or a
    /// head-advancing re-review) restores the attacker's `.cursor/` from the PR
    /// head, and a warm `crowd` restart or `crow send` reopens the clone through
    /// neither the creation nor the handoff arm.
    nonisolated static func shouldStripCursorReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .cursor && sessionKind == .review
    }

    /// Gate for refusing a review-session handoff (and `crow agents set
    /// --review <kind>`) to an agent that can't perform reviews. **No agent is
    /// review-incapable today** — Antigravity was the last one and its review
    /// dispatch landed in #902 (`autoLaunchCommand(.review)` inlines the SKILL
    /// body; `prepareReviewClone` **and every launch path**
    /// (`prepareWorktreeForAgentLaunch`) strip its `.agents/`, not just at
    /// creation — a warm `crowd` restart / `crow send "agy -c"` reopens the clone
    /// through neither creation nor a handoff arm). The predicate is retained as
    /// the single coupling point both surfaces share (`handoffAgent` and
    /// `AgentsRPCSupport.validateRoleSupportsAgent`) so a future review-incapable
    /// harness can be gated in one place without the two drifting. Extracted as a
    /// pure predicate so the gate stays unit-testable without the full
    /// `handoffAgent` machinery (mirrors `shouldStripCursorReviewClone`).
    nonisolated static func shouldRefuseReviewHandoff(
        targetKind: AgentKind, sessionKind: SessionKind) -> Bool {
        // Intentionally always `false`: every registered harness now supports
        // review. Add a `targetKind == X && sessionKind == .review` clause here
        // if a future agent ships without review dispatch.
        false
    }

    /// Whether Antigravity is about to open a `.review` clone and must therefore
    /// strip its committed `.agents/` first. This is only the pure *predicate*;
    /// the anti-drift guarantee comes from routing — every launch path calls
    /// `prepareWorktreeForAgentLaunch` (grep its call sites), and creation-time
    /// `prepareReviewClone` strips directly — not from any enumeration here (#902
    /// review, Red; mirrors `shouldStripGrokReviewClone`). Only a `.review`
    /// session on Antigravity strips: `.work`/`.job` branch off a trusted base,
    /// and a `.review` on any other agent must not strip a surface that agent
    /// doesn't load. Antigravity has no trust gate (`agy` runs `.agents/hooks.json`
    /// unapproved and seeds no folder trust), so unlike Cursor — whose bespoke
    /// handoff strip is defense-in-depth behind its `.review` trust carve-out —
    /// the strip is Antigravity's *only* defense and must re-fire on every launch,
    /// which is why this routes through the shared gate rather than a handoff arm.
    nonisolated static func shouldStripAntigravityReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .antigravity && sessionKind == .review
    }

    /// Whether Muse is about to open a `.review` clone and must therefore strip
    /// its committed config layers first. Only a `.review` session on Muse
    /// strips: `.work`/`.job` branch off a trusted base, and a `.review` on any
    /// other agent must not strip a surface that agent doesn't load. Muse
    /// withholds `--trust-workspace` from review (so project hooks/skills/rules
    /// do not load) but **project memory under `.agents/memory/` is injected
    /// even in an untrusted workspace** (official configuration docs,
    /// 2026-08-14), so the strip is load-bearing for that layer and must
    /// re-fire on every launch via `prepareWorktreeForAgentLaunch`.
    nonisolated static func shouldStripMuseReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .muse && sessionKind == .review
    }

    /// Neutralize a review clone's committed Muse config layers. A hostile PR
    /// head can commit:
    ///  - `.muse/hooks.json` — project hooks that `--trust-workspace` (or a
    ///    later `muse hooks trust`) would run outside the sandbox.
    ///  - `.agents/` — project skills (`<repo>/.agents/skills/`) plus
    ///    **project memory** (`<repo>/.agents/memory/`), which Muse injects
    ///    even in an untrusted workspace. Prompt injection, and the one
    ///    layer withholding `--trust-workspace` does not cover.
    /// Working-tree removal only (the git index entry survives). Shared by
    /// `prepareReviewClone` and `prepareWorktreeForAgentLaunch`. Idempotent;
    /// each layer no-ops when absent. A genuine removal failure is audible.
    nonisolated static func stripMuseConfigFromReviewClone(clonePath: String) {
        let base = clonePath as NSString
        removeReviewCloneConfig(
            base.appendingPathComponent(".muse"),
            label: ".muse/", clonePath: clonePath)
        removeReviewCloneConfig(
            base.appendingPathComponent(".agents"),
            label: ".agents/", clonePath: clonePath)
    }

    /// Neutralize a review clone's committed Antigravity config layers by removing
    /// the working-tree config dirs `agy` may discover. A hostile PR head can
    /// commit `.agents/hooks.json` with arbitrary command hooks that `agy` runs
    /// with no approval gate, so once Antigravity loads the clone as its project
    /// root the hooks fire unsandboxed on the reviewer's machine. Because this is
    /// Antigravity's **only** defense (no trust gate behind it), it strips the
    /// whole plausibly-discovered surface rather than the native dir alone —
    /// mirroring `stripGrokConfigFromReviewClone`, which strips `.grok/` **plus**
    /// `.cursor/`/`.claude/`/`.mcp.json` for the same reason (#861 r12, Red):
    ///  - `.agents/` — Antigravity's native project hooks (and any project-scope
    ///    config Crow's deferred MCP bridge would place there, modeled on
    ///    `CursorMCPConfigWriter`'s `.cursor/mcp.json`).
    ///  - `.gemini/` — `agy` is Gemini-derived (`GEMINI_CONFIG_HOME`, default
    ///    `~/.gemini/config`, `LaunchScaffold`), so a project-scope
    ///    `.gemini/settings.json` can carry `mcpServers` (a `{command,args}` server
    ///    spawned at startup) or an `always-proceed` approval mode that would
    ///    disarm the gate the review otherwise leans on. Stripped **defensively**
    ///    pending the v1.1.7 probe (#902 review r7, Red): removing a path `agy`
    ///    turns out not to read costs nothing on a throwaway review clone, and a
    ///    miss here is unsandboxed RCE with no second layer.
    /// Working-tree removal only (the git index entry survives), same as
    /// `stripCursorConfigFromReviewClone` — so a *committed* `.agents/hooks.json`
    /// still trips `AntigravityHookConfigWriter`'s git-tracked guard and Crow's
    /// own state-detection hooks aren't written for that clone; that is expected,
    /// not a regression. Shared by `prepareReviewClone` (creation-time) and
    /// `prepareWorktreeForAgentLaunch` (every launch path — where the review
    /// skill's `gh pr checkout` may have restored a committed layer from the head)
    /// so the gate can't drift. Idempotent; each layer no-ops when absent.
    /// Delegates to `removeReviewCloneConfig` so a genuine removal failure is
    /// **audible** (`CrowLog.error`, not `info`): the strip is Antigravity's only
    /// defense, so a swallowed failure would leave live attacker config in place
    /// with nothing to show for it (#902 review r3, Yellow 1).
    nonisolated static func stripAntigravityConfigFromReviewClone(clonePath: String) {
        let base = clonePath as NSString
        removeReviewCloneConfig(
            base.appendingPathComponent(".agents"),
            label: ".agents/", clonePath: clonePath)
        removeReviewCloneConfig(
            base.appendingPathComponent(".gemini"),
            label: ".gemini/", clonePath: clonePath)
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
    /// Shared rather than inlined so the gate can't drift (#829 review round 10):
    /// `prepareReviewClone` strips at creation time,
    /// `prepareWorktreeForAgentLaunch` on every launch path (via
    /// `shouldStripCursorReviewClone` — CROW-954), and
    /// `stripGrokConfigFromReviewClone` reuses it for the `.cursor/` layer Grok
    /// also discovers. `rg stripCursorConfigFromReviewClone` is the authority on
    /// that set — never a hand-maintained count here, which is what went stale
    /// four rounds running on the sibling helpers. Working-tree removal only: the
    /// git index entry survives (`removeItem` doesn't stage a deletion), so
    /// `CursorHookConfigWriter.writeHookConfig` still correctly declines to
    /// overwrite a *committed* hooks file and the review runs without Crow's
    /// hook-based state signals — a bounded, pre-existing limitation for repos
    /// that commit their own `.cursor/`, independent of this security strip.
    /// Idempotent; no-ops when the clone ships no `.cursor/`.
    ///
    /// Delegates to `removeReviewCloneConfig` so a genuine removal failure is
    /// **audible** (`CrowLog.error`, not `info`). That matters as of CROW-954:
    /// Cursor review clones now launch pre-trusted (`--trust`) with `--force
    /// --approve-mcps`, so this strip is the *only* thing standing between a
    /// committed `.cursor/hooks.json` and unsandboxed execution. A swallowed
    /// failure would leave live attacker config in place with nothing to show for
    /// it — the same rationale already spelled out on
    /// `stripAntigravityConfigFromReviewClone` (#902 review r3, Yellow 1), which
    /// this now matches. Before CROW-954 an `info` line was tolerable because
    /// Cursor's folder-trust dialog stood behind the strip; this PR removed that
    /// backstop (CROW-954 review, Yellow 1).
    nonisolated static func stripCursorConfigFromReviewClone(clonePath: String) {
        removeReviewCloneConfig(
            (clonePath as NSString).appendingPathComponent(".cursor"),
            label: ".cursor/", clonePath: clonePath)
    }

    /// Whether Grok is about to open a `.review` clone and must therefore strip
    /// its committed config layers first. This is only the pure *predicate*; the
    /// anti-drift guarantee comes from routing — every launch path calls
    /// `prepareWorktreeForAgentLaunch` (grep its call sites), and creation-time
    /// `prepareReviewClone` strips directly — not from any enumeration here (#861
    /// review, Red; mirrors `shouldStripCursorReviewClone`). Only a
    /// `.review` session on Grok strips: `.work`/`.job` branch off a trusted base,
    /// and a `.review` on any other agent must not strip a surface that agent
    /// doesn't load.
    nonisolated static func shouldStripGrokReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        agentKind == .grok && sessionKind == .review
    }

    /// Neutralize a review clone's committed config layers that **Grok
    /// discovers and merges** — not just `.grok/`. With `compat.*.hooks = true`
    /// (on by default), Grok loads project hooks from `.grok/hooks/*.json`,
    /// `.claude/settings.json` **and** `.claude/settings.local.json`, and
    /// `.cursor/hooks.json`; and it loads project MCP servers from
    /// `.cursor/mcp.json`, `.grok/config.toml [mcp_servers]`, **and repo-root
    /// `.mcp.json`** (verified against `xai-org/grok-build`: `10-hooks.md`,
    /// `07-mcp-servers.md`, and `xai-grok-workspace/src/{folder_trust,servers}.rs`,
    /// where `.mcp.json` is scanned from repo root down to cwd). On an
    /// attacker-controlled review-clone head every one is arbitrary-command RCE
    /// once the folder is trusted — and on a local/dev Grok build folder-trust is
    /// inert (everything trusted), or on a release build trust cascades from a
    /// trusted parent — so the strip is the durable defense (#861 review rounds
    /// 2-3, Red).
    ///
    /// So this neutralizes the whole discovered surface:
    /// - `.grok/` — Grok's native project hooks, plus `.grok/config.toml`
    ///   `[mcp_servers]` and `.grok/lsp.json` (all removed by the dir wipe).
    /// - `.cursor/` — `hooks.json` + `mcp.json` Grok loads via Cursor compat.
    ///   Reuses `stripCursorConfigFromReviewClone` so both agents share one
    ///   primitive.
    /// - `.claude/settings.local.json` **and** `.claude/settings.json` — both
    ///   loaded via Claude compat (their `hooks` + `env` spawn subprocesses).
    ///   Removing `settings.json` here is safe at creation: this strip runs
    ///   *before* `prepareReviewClone` rewrites it with bundled-safe content
    ///   (`Scaffolder.bundledSettings()`), so the clone still ends Crow-owned. On
    ///   the re-strip paths (`launchAgent`/handoff) it removes a hostile
    ///   `settings.json` that `git restore`/`gh pr checkout` brought back — which
    ///   the one-shot creation overwrite can't reach (#861 review r12, Red).
    ///   `.claude/skills/` is untouched (the Grok review inlines the skill into
    ///   its prompt, so it isn't read as a file).
    /// - `.mcp.json` (repo root) — a project MCP source independent of
    ///   `.cursor/mcp.json`; a `{mcpServers:{…command}}` there auto-spawns.
    ///
    /// Idempotent; no-ops for any layer the clone doesn't ship. Two kinds of
    /// caller: creation-time `prepareReviewClone` (strip only — the clone isn't a
    /// launch target yet), and every *launch* path via the shared
    /// `prepareWorktreeForAgentLaunch` gate (grep its call sites) — so no path can
    /// open Grok in a review clone without stripping first. A real removal failure
    /// is audible (`CrowLog.error`).
    nonisolated static func stripGrokConfigFromReviewClone(clonePath: String) {
        let base = clonePath as NSString
        removeReviewCloneConfig(
            base.appendingPathComponent(".grok"), label: ".grok/", clonePath: clonePath)
        // .cursor/ (hooks.json + mcp.json) — same primitive Cursor reviews use.
        stripCursorConfigFromReviewClone(clonePath: clonePath)
        // `.claude/settings.local.json` + `.claude/settings.json` — both loaded
        // via Claude compat. See the doc above for why removing `settings.json`
        // is safe at creation (strip precedes the bundled rewrite) yet essential
        // on the re-strip paths (a restored hostile one, #861 review r12, Red).
        removeReviewCloneConfig(
            base.appendingPathComponent(".claude/settings.local.json"),
            label: ".claude/settings.local.json", clonePath: clonePath)
        removeReviewCloneConfig(
            base.appendingPathComponent(".claude/settings.json"),
            label: ".claude/settings.json", clonePath: clonePath)
        // Repo-root `.mcp.json` — a project MCP source Grok loads independently
        // of `.cursor/mcp.json`. For a review clone cwd == clone root, so the
        // repo-root file is the only one in Grok's root→cwd scan chain.
        removeReviewCloneConfig(
            base.appendingPathComponent(".mcp.json"),
            label: ".mcp.json", clonePath: clonePath)
    }

    /// Strip the PRIOR agent's Crow-managed hook config from the two project
    /// compat sources Grok also loads — `.claude/settings.local.json` (Claude)
    /// and `.cursor/hooks.json` (Cursor) — on a `.work`/`.job` handoff to Grok.
    ///
    /// Distinct from `stripGrokConfigFromReviewClone` in both scope and method:
    /// that wholesale-wipes attacker config *files* off a hostile *review* clone;
    /// this runs on a *trusted* work worktree and calls each writer's
    /// `removeHookConfig`, which touches only the hook config — never the file's
    /// other settings (Claude's `permissions` block, the gateway `env`, Cursor's
    /// non-hook keys) nor a user's own `.grok/hooks/*.json`.
    ///
    /// ⚠️ The two writers differ in granularity, and the Claude arm is **not**
    /// marker-scoped: `CursorHookConfigWriter.removeHookConfig` prunes only Crow's
    /// own groups (a user's hooks under the same event name survive), but
    /// `ClaudeHookConfigWriter.removeHookConfig` drops each managed event key
    /// *wholesale* — so a user's hand-authored `Stop`/`PreToolUse`/… hook in the
    /// worktree's `.claude/settings.local.json` is removed with it (the same caveat
    /// spelled out at `writeManagerHookConfig`). An accepted trade for closing the
    /// double-fire: hand-authored hooks in a per-session `.work` worktree are rare,
    /// and leaving the double-fire is worse.
    ///
    /// Why it's needed: nothing else on the worker path removes a prior agent's
    /// hooks — `launchAgent` / the deferred-paste only *write* the incoming
    /// agent's, and the cross-agent loop in `writeManagerHookConfig` is
    /// Manager-only. So a Claude→Grok (or Cursor→Grok) handoff leaves the prior
    /// `.claude/settings.local.json` / `.cursor/hooks.json` — same session UUID,
    /// same PascalCase event names Grok registers — on disk, and Grok (compat on
    /// by default) loads BOTH it and its own `.grok/hooks/crow.json`. Every hook
    /// event then fires twice: doubled `taskComplete`/`agentWaiting` notifications
    /// and a doubled `crow hook-event` subprocess for the session's life, because
    /// `EngineRouter.presentHookNotification` is per-event, not state-gated
    /// (#861 review r8).
    ///
    /// Idempotent and no-op when the file/keys are absent, so it's called
    /// unconditionally (prior Codex/OpenCode → nothing to strip) and never
    /// touches the incoming `.grok/hooks/crow.json` (a separate file, written
    /// later on the deferred paste).
    nonisolated static func stripPriorCompatHooksForGrokHandoff(worktreePath: String) {
        ClaudeHookConfigWriter().removeHookConfig(worktreePath: worktreePath)
        CursorHookConfigWriter().removeHookConfig(worktreePath: worktreePath)
    }

    /// Remove one review-clone config path, quiet when it isn't present (the
    /// common case) but **audible** on a real removal failure — a swallowed
    /// error would leave an attacker-controlled config layer in place. Shared by
    /// **all three** review-clone strips — Grok's several layers, Antigravity's
    /// `.agents/`+`.gemini/`, and Cursor's `.cursor/` (CROW-954) — so every strip
    /// reports a failure at one log level.
    private nonisolated static func removeReviewCloneConfig(
        _ path: String, label: String, clonePath: String) {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // Not shipped — the common, expected case. Stay quiet.
        } catch {
            CrowLog.error("[SessionService] Failed to strip \(label) from review clone \(clonePath): \(error.localizedDescription)")
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
        reviewBlocking: [ReviewSeverity] = ReviewSeverity.defaultBlocking,
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

        let reviewsDir = DevRootLayout.reviewsDir(devRoot: devRoot)
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
                _ = try await SessionService.runShellAsync(env: env, args: ["gh", "repo", "clone", repoSlug, clonePath])
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
            _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", ".codex"])
        }
        // Same restore-before-pull for Cursor reviews (#829 review round 9):
        // the `.cursor/` strip below applies as an unstaged deletion of tracked
        // files, so `git pull` would refuse if the new head touches `.cursor/`.
        if reviewAgentKind == .cursor {
            _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", ".cursor"])
        }
        // Same restore-before-pull for Grok reviews (#859, extended #861 rounds
        // 2-3, r12): Grok's strip below neutralizes *every* project source Grok
        // discovers (`.grok/`, `.cursor/`, **both** `.claude/settings.json` and
        // `settings.local.json`, repo-root `.mcp.json`), each applied as an
        // unstaged deletion of tracked files — so restore all of them before the
        // pull, or `git pull` refuses when the new head touches any.
        if reviewAgentKind == .grok {
            for path in [".grok", ".cursor", ".claude/settings.json", ".claude/settings.local.json", ".mcp.json"] {
                _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", path])
            }
        }
        // Same restore-before-pull for Antigravity reviews (#902 review): the
        // strip below applies as an unstaged deletion of tracked files.
        // A fast-forward `git pull` silently restores the deleted paths (verified),
        // but a non-fast-forward merge that touches them refuses ("local changes
        // would be overwritten"); since the pull is `try?`-swallowed, that would
        // leave the clone at the stale head while `.crow-review-prompt.md` is
        // rewritten with the current PR URL. Restore both stripped layers
        // (`.agents/` **and** `.gemini/`, #902 review r7) first, for parity with the
        // `.codex`/`.cursor`/`.grok` arms and clean re-prep. This is re-prep
        // hygiene, NOT the security boundary: the load-bearing defense is the strip
        // in `prepareWorktreeForAgentLaunch`, which re-fires on every launch after
        // the SKILL's `gh pr checkout` may have restored a committed layer.
        if reviewAgentKind == .antigravity {
            for path in [".agents", ".gemini"] {
                _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", path])
            }
        }
        // Same restore-before-pull for Muse reviews (#1033): the strip below
        // applies as an unstaged deletion of `.muse/` + `.agents/`. Restore
        // first so `git pull` cannot refuse when the new head touches them.
        if reviewAgentKind == .muse {
            for path in [".muse", ".agents"] {
                _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", "--", path])
            }
        }
        _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "fetch", "origin", headBranch])
        _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "checkout", headBranch])
        _ = try? await SessionService.runShellAsync(env: env, args: ["git", "-C", clonePath, "pull", "origin", headBranch])

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
        // Defense-in-depth for Antigravity review clones (#862 review, #902): a
        // hostile PR head can commit `.agents/hooks.json` with arbitrary command
        // hooks that `agy` runs with no approval gate. Now that Antigravity
        // supports review (`autoLaunchCommand(.review)` dispatches the inlined
        // SKILL), this strip is load-bearing — and because `agy` has no trust
        // gate, `stripAntigravityConfigFromReviewClone` is also wired into
        // `prepareWorktreeForAgentLaunch` (every launch path), so the review
        // skill's `gh pr checkout` / a head-advancing re-review can't restore the
        // hooks for the next `agy` launch. Gated to Antigravity reviews for the
        // same reason as `.codex`/`.cursor`: only Antigravity loads `.agents/`, so
        // stripping it for another agent's review would just hide the files a
        // hostile PR ships. Re-run on every prep so a `git pull` can't
        // reintroduce it.
        if reviewAgentKind == .antigravity {
            Self.stripAntigravityConfigFromReviewClone(clonePath: clonePath)
        }
        // Defense-in-depth for Muse review clones (#1033): withhold
        // `--trust-workspace` so project hooks/skills/rules do not load, and
        // strip `.muse/` + `.agents/` (memory loads even untrusted). The
        // launch-path strip in `prepareWorktreeForAgentLaunch` is load-bearing
        // — the review skill's `gh pr checkout` can restore a committed layer.
        if reviewAgentKind == .muse {
            Self.stripMuseConfigFromReviewClone(clonePath: clonePath)
        }
        // Defense-in-depth for Grok reviews (#859, extended #861 rounds 2-3, r12):
        // Grok discovers & merges project config from `.grok/hooks/*.json`,
        // `.claude/settings.json` + `settings.local.json`, `.cursor/hooks.json`,
        // and project MCP servers from `.cursor/mcp.json` +
        // `.grok/config.toml` + repo-root `.mcp.json` — `compat.*.hooks = true`
        // by default. On an attacker-controlled review head each is
        // arbitrary-command RCE once the folder is trusted, and the strip is the
        // durable guard (dev builds trust everything; a trusted parent cascades
        // on release). `stripGrokConfigFromReviewClone` neutralizes the full set
        // (`.grok/` + `.cursor/` + `.claude/settings{,.local}.json` + `.mcp.json`);
        // `.claude/settings.json` is re-written bundled-safe below at creation, and
        // left absent on the launch-time re-strip paths, which is safe. This is the
        // creation-time strip; every launch-time strip runs via the shared
        // `prepareWorktreeForAgentLaunch` gate (grep its call sites), so the set of
        // paths can't drift out of sync with a stale count here.
        if reviewAgentKind == .grok {
            Self.stripGrokConfigFromReviewClone(clonePath: clonePath)
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

        // Render the workspace's verdict policy into the SKILL body ONCE, here,
        // before the two launch paths diverge (CROW-963). Both consumers below
        // take `policySkillBody`: the inlined prompt (Cursor/OpenCode/Codex/Grok/
        // Antigravity, via `buildReviewPrompt`) and the copied `.claude/skills/…/
        // SKILL.md` (Claude). Hooking only the file copy would leave every
        // inlining agent on the default rule — and `agentsByKind.review` is
        // commonly Cursor, so that failure mode is the normal case, not an edge
        // one. `expandSkillBody` runs the same expansion again downstream with the
        // default set; it is idempotent, so that pass finds no placeholders left.
        let policySkillBody = ReviewVerdictPolicy.expand(
            Scaffolder.bundledReviewSkill(), blocking: reviewBlocking)

        // Write review prompt file into the clone directory. Write failures
        // MUST surface (CROW-439): the launcher's prompt-file shell substitution
        // substitution will yield an empty string and the agent will idle if
        // the file isn't there.
        let promptPath = (clonePath as NSString).appendingPathComponent(".crow-review-prompt.md")
        let reviewPrompt = Self.buildReviewPrompt(prURL: prURL, prTitle: prTitle, repoSlug: repoSlug, prNumber: prNumber, agentKind: reviewAgentKind, skillBody: policySkillBody)
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
        // heredocs in gh/glab calls don't expand shell variables). The verdict policy is already
        // rendered into `policySkillBody` above (CROW-963).
        //
        // This copy keeps its YAML frontmatter — Claude Code's skill engine needs the
        // `name`/`description` block to load it at all. Only the *inlined* prompt written
        // above is frontmatter-stripped (`cursorReviewPrompt`, CROW-968); don't be tempted
        // to hoist that strip up to `policySkillBody`, which would break this file.
        let cloneSkillsDir = (clonePath as NSString).appendingPathComponent(".claude/skills/crow-review-pr")
        try? fm.createDirectory(atPath: cloneSkillsDir, withIntermediateDirectories: true)
        let resolvedSkillContent = CrowAttribution.expandSkillBody(policySkillBody, agentKind: reviewAgentKind)
        try? resolvedSkillContent.write(
            toFile: (cloneSkillsDir as NSString).appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )

        // (Re)write `.claude/settings.json` with Crow's bundled-safe permissions
        // at creation. `stripGrokConfigFromReviewClone` above already removed any
        // committed `settings.json` for Grok reviews (Grok, like Claude, loads it
        // via compat — hooks + `env` run subprocesses, #861 review r12); this is
        // what gives the fresh clone a valid Crow-owned one, for Claude and Grok
        // reviews alike. **Fail closed** (#861 review round 4, Yellow): remove any
        // file FIRST, then write, so a write failure can't leave a stale/attacker
        // file — and make a real write failure audible. NB the two Grok re-strip
        // paths (`launchAgent`/handoff) do NOT re-run this write: there a restored
        // hostile `settings.json` is removed and left absent, which is safe — Grok
        // just falls back to no compat settings.
        let cloneSettingsDir = (clonePath as NSString).appendingPathComponent(".claude")
        let settingsPath = (cloneSettingsDir as NSString).appendingPathComponent("settings.json")
        removeReviewCloneConfig(settingsPath, label: ".claude/settings.json", clonePath: clonePath)
        let settingsContent = Scaffolder.bundledSettings()
        do {
            try fm.createDirectory(atPath: cloneSettingsDir, withIntermediateDirectories: true)
            try settingsContent.write(toFile: settingsPath, atomically: true, encoding: .utf8)
        } catch {
            CrowLog.error("[SessionService] Failed to write bundled .claude/settings.json to review clone \(clonePath): \(error.localizedDescription) (any committed file was already removed — fail-closed)")
        }

        return ReviewClonePrep(
            prTitle: prTitle,
            headBranch: headBranch,
            headRefOid: headRefOid,
            clonePath: clonePath
        )
    }

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
    ///
    /// `skillBody` is a parameter rather than a fresh `bundledReviewSkill()` read
    /// so the caller can hand in a body whose verdict policy is already rendered
    /// for the session's workspace (CROW-963). It defaults to the bundled body
    /// (which renders the default policy downstream), keeping existing callers
    /// and tests unchanged.
    nonisolated static func buildReviewPrompt(
        prURL: String,
        prTitle: String,
        repoSlug: String,
        prNumber: Int,
        agentKind: AgentKind,
        skillBody: String? = nil
    ) -> String {
        switch agentKind {
        case .cursor, .openCode, .codex, .grok, .antigravity, .muse:
            // Cursor, OpenCode, Codex, Grok, Antigravity, and Muse all lack a Crow
            // slash-command engine, so they get the whole crow-review-pr SKILL
            // body inlined into the prompt file (a self-contained brief). Without
            // this, the review would receive a bare `/crow-review-pr <URL>` line
            // it can't resolve, never run `gh pr review`, and so never satisfy the
            // review-completion contract — the loop #830 set out to remove (#843
            // review round 2 for Codex; #861 review round 5 for Grok; Antigravity
            // wired the same way, #902). `agentKind` is threaded through so the
            // posted review footer names the right agent.
            //
            // This is the branch that carries the per-workspace verdict policy for
            // most installs (CROW-963) — the copied SKILL.md below it is read only
            // by Claude.
            return cursorReviewPrompt(
                skillBody: skillBody ?? Scaffolder.bundledReviewSkill(),
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
    /// strip the YAML frontmatter, replace `$ARGUMENTS` with the PR URL, and
    /// expand `${CROW_AGENT_DISPLAY_NAME:-…}` / legacy "via Claude Code" wording
    /// so the posted GitHub review identifies the reviewing agent correctly.
    ///
    /// The frontmatter strip (CROW-968) is what makes the inlined body safe to
    /// pass as a positional argument. The SKILL file opens with a `---` block
    /// because Claude Code's skill engine requires `name`/`description`; inlined,
    /// that block made the prompt's first byte a `-`, which Cursor's commander-
    /// based `agent` parsed as a flag — `error: unknown option '---` — killing the
    /// session before it started. Shell quoting never covered this: `printf %q`
    /// protects the string from the shell, but a leading hyphen is not
    /// shell-special and survives into argv. Stripping is right on its own merits
    /// too — the metadata has no reader in an inlined brief and costs tokens on
    /// every review.
    ///
    /// It belongs **here**, not upstream, and not in
    /// `CrowAttribution.expandSkillBody`: `prepareReviewClone` renders the
    /// workspace policy into one `policySkillBody` and forks it two ways, and the
    /// other consumer — the `.claude/skills/crow-review-pr/SKILL.md` copy written
    /// into the review clone — **must keep** its frontmatter or Claude Code won't
    /// load the skill. Only the inlined side is stripped.
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
            MarkdownFrontmatter.stripped(skillBody)
                .replacingOccurrences(of: "$ARGUMENTS", with: prURL),
            agentKind: agentKind
        )
    }
}

// MARK: - SessionService facades (CROW-1113)

extension SessionService {
    @discardableResult
    public func createReviewSession(prURL: String, selectAfterCreate: Bool = false) async -> UUID? {
        await review.createReviewSession(prURL: prURL, selectAfterCreate: selectAfterCreate)
    }

    /// Filename of the launcher's initial prompt file for a session kind
    /// (see `ReviewSessionController.initialPromptFileName`).
    nonisolated static func initialPromptFileName(for kind: SessionKind) -> String? {
        ReviewSessionController.initialPromptFileName(for: kind)
    }

    /// Build the initial prompt for a review session
    /// (see `ReviewSessionController.buildReviewPrompt`).
    nonisolated static func buildReviewPrompt(
        prURL: String, prTitle: String, repoSlug: String, prNumber: Int,
        agentKind: AgentKind, skillBody: String? = nil
    ) -> String {
        ReviewSessionController.buildReviewPrompt(
            prURL: prURL, prTitle: prTitle, repoSlug: repoSlug, prNumber: prNumber,
            agentKind: agentKind, skillBody: skillBody)
    }

    /// Inlined-SKILL substitutions for slash-command-less review agents
    /// (see `ReviewSessionController.cursorReviewPrompt`).
    nonisolated static func cursorReviewPrompt(
        skillBody: String, prURL: String, agentKind: AgentKind = .cursor
    ) -> String {
        ReviewSessionController.cursorReviewPrompt(
            skillBody: skillBody, prURL: prURL, agentKind: agentKind)
    }

    nonisolated static func shouldRefuseReviewHandoff(
        targetKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldRefuseReviewHandoff(
            targetKind: targetKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripCursorReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripCursorReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripAntigravityReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripAntigravityReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripMuseReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripMuseReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func shouldStripGrokReviewClone(
        agentKind: AgentKind, sessionKind: SessionKind) -> Bool {
        ReviewSessionController.shouldStripGrokReviewClone(
            agentKind: agentKind, sessionKind: sessionKind)
    }

    nonisolated static func stripMuseConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripMuseConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripAntigravityConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripAntigravityConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripCursorConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripCursorConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripGrokConfigFromReviewClone(clonePath: String) {
        ReviewSessionController.stripGrokConfigFromReviewClone(clonePath: clonePath)
    }

    nonisolated static func stripPriorCompatHooksForGrokHandoff(worktreePath: String) {
        ReviewSessionController.stripPriorCompatHooksForGrokHandoff(worktreePath: worktreePath)
    }
}
