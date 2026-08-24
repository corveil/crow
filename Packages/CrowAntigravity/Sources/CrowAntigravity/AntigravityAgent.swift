import Foundation
import CrowCore

/// `CodingAgent` conformer for Google Antigravity's CLI (binary `agy`) — the
/// terminal surface of Google's agent-first dev platform (Gemini 3). **Tier-2 /
/// experimental** (ADR 0015): a real, driveable CLI, but it lands below the
/// self-hostable harnesses and ships with honest, documented gaps (#860).
///
/// Structurally a near-clone of `CursorAgent`: hooks are Claude-Code-style, so
/// the `HookConfigWriter` / `StateSignalSource` pair does real work (not a
/// `cwd`-scoped fallback); remote control is faked via `crow send` typing into
/// the interactive TUI (no native RC protocol); `.review` dispatches the
/// inlined `crow-review-pr` SKILL body via `-p` (like Cursor/Codex/OpenCode —
/// #902). What Antigravity *can't* do is self-host — the CLI is closed-source
/// and Google-Sign-In/GCP-authed, so it runs only against Google's cloud models
/// (Gemini 3 Pro default, Claude Sonnet 4.5). That fails Corveil's self-host
/// axis and is a **permanent** gap, not a phase.
public struct AntigravityAgent: CodingAgent {
    public let kind: AgentKind = .antigravity
    public let displayName: String = "Antigravity"
    /// Thematically "anti-gravity" (up), and visually distinct from Claude's
    /// `"sparkles"`, Cursor's `"cursorarrow.rays"`, and Codex's `"terminal.fill"`.
    public let iconSystemName: String = "arrow.up.circle"
    /// `true`, but faked: Antigravity has no `--rc`/`--name` protocol, so remote
    /// driving is `crow send` typing into the interactive TUI (the agent-agnostic
    /// stdin path). The badge reflects that Crow *can* drive it, not a native RC
    /// surface — same as Cursor/OpenCode.
    public let supportsRemoteControl: Bool = true
    /// Antigravity's CLI binary is `agy` (not `antigravity`) — low collision risk.
    public let launchCommandToken: String = "agy"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: AntigravityLauncher

    /// Last-resort search paths for `agy`, checked only when a
    /// `defaults.binaries.antigravity` override and a PATH walk both miss.
    ///
    /// ⚠️ **Supply-chain gate (#860).** These are conservative *standard-bin*
    /// locations any well-behaved installer targets, pinned to the **official**
    /// distribution (`antigravity.google`'s installer, which puts `agy` on PATH).
    /// They are deliberately **NOT** wired to the community
    /// `google-antigravity/*` GitHub org: that org is `is_verified: false`
    /// (confirmed via `gh api orgs/google-antigravity`), is not one of Google's
    /// canonical orgs (`google`, `google-gemini`), and its `antigravity-cli`
    /// repo is README-only (no source, no license) — a mirror/tracker, not a
    /// provenance you'd resolve a binary from. PATH resolution is the primary
    /// mechanism (it picks up whatever the official installer placed); this list
    /// only covers an unusually narrow PATH. The exact official install path
    /// must be confirmed before Antigravity is promoted out of Tier-2 — until
    /// then, off-PATH `agy` simply leaves the adapter unregistered (ADR 0014),
    /// which is the safe default.
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".antigravity/bin/agy").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = AntigravityHookConfigWriter(),
        stateSignalSource: any StateSignalSource = AntigravitySignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = AntigravityLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let agentPath = AntigravityLaunchArgs.shellQuote(launchBinary() ?? "agy")
        // Bounded auto-permission — a no-op suffix on the pinned version (see
        // `AntigravityLaunchArgs.autoPermissionSuffix`); kept for call-site
        // uniformity so a future bounded flag lands once for every path.
        let autoArgs = AntigravityLaunchArgs.autoPermissionSuffix(autoPermissionMode)

        switch session.kind {
        case .work:
            // Interactive TUI — the user types their prompt. No prompt injection,
            // no resume flag (a fresh work TUI launching bare is deliberate), no
            // RC flag (remote control is `crow send` into the TUI).
            return "\(agentPath)\(autoArgs)\n"
        case .job, .review:
            // Jobs and reviews share one dispatch shape (collapsed into a single
            // branch so the two can't drift, mirroring Cursor/Grok/OpenCode): feed
            // the pre-written prompt file (`.crow-job-prompt.md` /
            // `.crow-review-prompt.md`) as the initial prompt via `-p` on first
            // launch. Crow runs `agy` inside a tmux window — a real PTY — so the
            // non-TTY `-p` stdout-drop (headless *pipe* case, upstream FRs
            // #119/#597) doesn't apply here; no PTY shim is needed.
            //
            // On restart we resume with `-c` (continue most-recent conversation).
            // Caveat (documented Tier-2 gap): `-c` is machine-global "most recent"
            // and `--print` never surfaces the conversation id (upstream FR #7),
            // so we can't capture a specific handle — in a per-worktree tmux
            // window the most-recent conversation is almost always this session's,
            // the same heuristic Cursor/OpenCode rely on.
            //
            // `.review` is dispatched via the inlined `crow-review-pr` SKILL body
            // (Antigravity has no Crow slash-command engine, so
            // `SessionService.buildReviewPrompt` hands it the self-contained brief).
            // The inlined SKILL runs `gh pr review` itself, so the verdict path
            // needs no extra plumbing.
            //
            // SECURITY (`.review` only): the review clone is an attacker-controlled
            // `gh` checkout at the PR head. Antigravity seeds no folder trust and
            // `agy` runs a committed `.agents/hooks.json` (and a Gemini-derived
            // `.gemini/settings.json` `mcpServers`) with no approval gate, so —
            // unlike Codex/Cursor, where trust-gating is a second layer — stripping
            // that config is the *only* defense. It runs at clone creation
            // (`prepareReviewClone`) AND on every launch path
            // (`prepareWorktreeForAgentLaunch`), and covers the whole
            // plausibly-discovered surface (`.agents/` + `.gemini/`), because the
            // SKILL's `gh pr checkout` / a head-advancing re-review can restore a
            // committed layer from the head between launches (#902 review Red).
            // This launch-time strip assumes `agy` reads config *once at process
            // start*, not per-event — an unverified premise (agy v1.1.7) tracked in
            // the pinned-gaps table and the manual-pass checklist; if it re-reads
            // mid-session, a restore between `gh pr checkout` and `Stop` would fire
            // unmitigated.
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                return ShellLaunchArgs.evalPromptLaunch(
                    prefix: "\(agentPath)\(autoArgs) -p",
                    promptPath: promptPath)
            }
            return "\(agentPath)\(autoArgs) -c\n"
        case .manager:
            // Manager sessions never auto-launch an agent — Crow drives them
            // externally. Returning nil is the contract, not a gap.
            return nil
        }
    }

    public func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?,
        codeProvider: Provider?
    ) async -> String {
        await launcher.generatePrompt(
            session: session,
            worktrees: worktrees,
            ticketURL: ticketURL,
            provider: provider,
            codeProvider: codeProvider
        )
    }

    public func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String
    ) async throws -> String {
        try await launcher.launchCommand(
            sessionID: sessionID,
            worktreePath: worktreePath,
            prompt: prompt,
            binary: launchBinary() ?? "agy"
        )
    }

    public func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        // Antigravity's Manager is an orchestration TUI in the devRoot — no
        // auto-prompt, no resume. No `--rc`/`--name` equivalent, so remote
        // control doesn't apply. Terminal backend appends the submitting Enter,
        // so return the command without a trailing newline (cross-agent
        // convention).
        let agentPath = AntigravityLaunchArgs.shellQuote(launchBinary() ?? "agy")
        return agentPath + AntigravityLaunchArgs.autoPermissionSuffix(autoPermissionMode)
    }

    // `sessionRenameSlashCommand` is intentionally NOT overridden: `agy` v1.1.7's
    // rename surface is unverified, so it inherits the protocol's opt-out `nil`
    // default rather than risk pasting a stray `/rename` prompt into the model
    // (CROW-629). A documented Tier-2 gap; override once a rename command is
    // confirmed.

    // `logSources` is intentionally NOT overridden (CROW-1097, a CROW-1089
    // follow-up). Antigravity's CLI *does* write a durable per-conversation
    // transcript — the earlier "no confirmed location" note is now resolved — but
    // that transcript is **not cwd-attributable by Crow's mechanism**, which is
    // the property the collector needs. So, like Cursor and OpenCode (storage
    // known, attribution/format the blocker), it stays on the `[]` default rather
    // than upload transcripts it can't safely attribute to a worktree.
    //
    // Where `agy` writes (verified from Antigravity CLI docs + community tooling —
    // `agy-explore`, `agentgrep`, the `antigravity-conversation-fix` recovery
    // tool — NOT first-party on-disk inspection: `agy` isn't installed here
    // (`crow agents list` → `available: false`) and running it needs
    // Google-Sign-In/GCP auth, so a live session couldn't be captured):
    //   • App-data root `~/.gemini/antigravity-cli/` (reuses the `~/.gemini`
    //     home; the *IDE* uses `~/.gemini/antigravity-ide/` — a separate tree).
    //   • Durable transcript, JSON Lines:
    //     `…/brain/<conversation-id>/.system_generated/logs/transcript_full.jsonl`
    //     (`transcript.jsonl` alongside it is the known-buggy truncated one).
    //     Step records are `{step_index, type, source, status, created_at}`.
    //   • Storage is **flat/global** — every project's conversations pool in one
    //     `brain/` dir keyed only by id (like Codex's `~/.codex/sessions`, unlike
    //     Claude's per-cwd slug dir), so attribution must be by *content*.
    //
    // Why the current `cwdFilter` path can't consume it: `AgentLogCwdReader` reads
    // the recorded `cwd` from the *transcript head* (top-level `cwd` / Codex's
    // `payload.cwd`). Antigravity records **no cwd in the transcript at all** —
    // nothing on any line says which repo the agent ran in. So a `.logDir` +
    // `cwdFilter: worktreePath` source would drop every file for a missing cwd
    // ("dropped, never guessed", CROW-1089) and collect *zero* — a wiring that
    // only looks wired. The cwd exists, but only in places the shared infra
    // doesn't read: a **separate per-conversation SQLite DB** (`<id>.db`) as
    // opaque protobuf trajectory metadata, and only *conditionally* (an absolute
    // `file:///` path recorded "when `agy` starts inside a workspace it
    // recognises"); or the **ephemeral** hook-stdin / status-line JSON payloads
    // (`conversationId`, `workspacePaths`, `transcriptPath` on the hook; lowercase
    // `cwd` on the status line); or the `…/cache/last_conversations.json`
    // workspace→latest-conversation pointer (latest-only, so it can name a stale
    // conversation — using it would guess). Reading any of those is
    // a new normalizer/attribution subsystem, not a `logSources` override.
    //
    // Downstream, the same no-cwd fact also blocks *backfill*: `BackfillScanner`'s
    // per-harness reconstruction reads cwd from the transcript head too, so a
    // `reconstructAntigravity` written like `reconstructCodex` would resolve every
    // session to `cwd == nil` → `.low`/orphan. NOT a blocker, and explicitly not a
    // prerequisite for wiring: `LogSyncHarness` has no `antigravity` case, but that
    // is by design — it maps to `.unknown`, so an upload is still accepted and
    // attributed, just not harness-typed (`LogSyncSupport`; corveil#2426). Adding a
    // first-class case is a quality-of-typing follow-up that does NOT gate wiring
    // logs (the collector stamps the harness, then skips only when `logSources` is
    // empty).
    //
    // Most promising future path for whoever wires this: Crow already runs
    // Antigravity hooks and knows the worktree it launched `agy` in, and the hook
    // stdin payload carries `conversationId` + `workspacePaths` (and
    // `transcriptPath`, which names the log file directly) — so capturing that at
    // runtime into a Crow-side conversation-id→worktree map would give exact,
    // non-guessed attribution the transcript itself can't. That's a design
    // follow-up, not this ticket.
}
