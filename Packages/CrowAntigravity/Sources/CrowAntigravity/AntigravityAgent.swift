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
/// the interactive TUI (no native RC protocol); `.review` is unsupported in
/// Phase A (like Codex). What Antigravity *can't* do is self-host — the CLI is
/// closed-source and Google-Sign-In/GCP-authed, so it runs only against Google's
/// cloud models (Gemini 3 Pro default, Claude Sonnet 4.5). That fails Corveil's
/// self-host axis and is a **permanent** gap, not a phase.
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
        let agentPath = AntigravityLaunchArgs.shellQuote(findBinary() ?? "agy")
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
        case .job:
            // Unattended dispatch: feed the pre-written `.crow-job-prompt.md` as
            // the initial prompt via `-p` on first launch. Crow runs `agy` inside
            // a tmux window — a real PTY — so the non-TTY `-p` stdout-drop
            // (headless *pipe* case, upstream FRs #119/#597) doesn't apply here;
            // no PTY shim is needed on this path.
            //
            // On restart we resume with `-c` (continue most-recent conversation).
            // Caveat (documented Tier-2 gap): `-c` is machine-global "most recent"
            // and `--print` never surfaces the conversation id (upstream FR #7),
            // so we can't capture a specific handle — in a per-worktree tmux
            // window the most-recent conversation is almost always this session's,
            // the same heuristic Cursor/OpenCode rely on.
            if !session.reviewPromptDispatched {
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(".crow-job-prompt.md")
                // Quote the path so a devRoot containing spaces doesn't split
                // `cat`'s argv and resolve the prompt to empty.
                return "\(agentPath)\(autoArgs) -p \"$(cat \(AntigravityLaunchArgs.shellQuote(promptPath)))\"\n"
            }
            return "\(agentPath)\(autoArgs) -c\n"
        case .review:
            // Review-on-Antigravity is unsupported in Phase A — like Codex, the
            // `/crow-review-pr` flow isn't wired for this harness. Returning nil
            // makes Crow log the skip rather than dispatch a review it can't
            // satisfy (no posted-verdict path). A documented Tier-2 gap.
            return nil
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
            binary: findBinary() ?? "agy"
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
        let agentPath = AntigravityLaunchArgs.shellQuote(findBinary() ?? "agy")
        return agentPath + AntigravityLaunchArgs.autoPermissionSuffix(autoPermissionMode)
    }

    // `sessionRenameSlashCommand` is intentionally NOT overridden: `agy` v1.1.7's
    // rename surface is unverified, so it inherits the protocol's opt-out `nil`
    // default rather than risk pasting a stray `/rename` prompt into the model
    // (CROW-629). A documented Tier-2 gap; override once a rename command is
    // confirmed.
}
