import Foundation
import CrowCore

/// `CodingAgent` conformer for the Cursor CLI (`agent` binary). Mirrors the
/// shape of `OpenAICodexAgent` but enables remote control — Cursor runs an
/// interactive TUI, so `crow send` (the agent-agnostic stdin-paste path in
/// `SessionService`) is sufficient for remote-driving it; no per-agent
/// hookery needed. Cursor's hook engine itself is a superset of Claude
/// Code's — same exit-code 0/2 protocol, accepts `CLAUDE_PROJECT_DIR` as
/// an alias — which is why the `HookConfigWriter` / `StateSignalSource`
/// pair below works rather than being a no-op like Codex's per-session
/// writer.
public struct CursorAgent: CodingAgent {
    public let kind: AgentKind = .cursor
    public let displayName: String = "Cursor"
    /// Visually distinct from Claude's `"sparkles"` and Codex's
    /// `"terminal.fill"`. Easy to swap once branding firms up.
    public let iconSystemName: String = "cursorarrow.rays"
    public let supportsRemoteControl: Bool = true
    /// Cursor's CLI binary is named `agent`, not `cursor`.
    ///
    /// `agent` is a generic name — CI runner installs (Azure DevOps, TeamCity)
    /// also ship a binary called `agent`, so the PATH-walk discovery in
    /// `CodingAgent.findBinary()` can in principle resolve a non-Cursor
    /// executable on a build machine. If that happens, set
    /// `defaults.binaries.cursor` to the absolute path of Cursor's CLI in
    /// `{devRoot}/.claude/config.json` — the explicit override is consulted
    /// before the PATH walk and pins the resolution. We accept the false-
    /// positive risk here (CROW-484) because real workstations don't usually
    /// have a competing `agent` on PATH, and the override knob exists for
    /// the exotic case.
    public let launchCommandToken: String = "agent"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: CursorLauncher

    /// Last-resort search paths for the `agent` binary (Cursor's CLI), used
    /// only when the configured `BinaryOverrides` and a PATH walk both miss.
    /// The Cursor app bundle's embedded CLI is usually symlinked into PATH or
    /// installed via the Cursor app's "Install 'cursor' command" action; this
    /// list is the historical hardcoded set we used to check first (CROW-484).
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/agent",
        "/usr/local/bin/agent",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agent").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = CursorHookConfigWriter(),
        stateSignalSource: any StateSignalSource = CursorSignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = CursorLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let agentPath = findBinary() ?? "agent"

        switch session.kind {
        case .work:
            // Bare `agent` launch — the user types their prompt into the TUI.
            // No env prefix (Cursor reads `CURSOR_API_KEY` from the shell;
            // GUI-stored creds are inherited otherwise), no `--continue`
            // (MVP doesn't auto-resume), no remote-control flag (remote
            // control is `crow send` typing into the TUI — agent-agnostic,
            // handled by `SessionService.send`, not a per-launch flag).
            return "\(agentPath)\n"
        case .job, .review:
            // Jobs and reviews share the same dispatch shape: a pre-written
            // initial prompt file (`.crow-job-prompt.md` / `.crow-review-prompt.md`)
            // is passed as argv on first launch so Cursor starts working
            // unattended. On subsequent app restarts we fall back to a bare
            // `agent` (Cursor has no `--continue` equivalent in MVP), so the
            // user resumes the TUI rather than re-running the full prompt.
            //
            // Review prompts are agent-aware: SessionService.buildReviewPrompt
            // inlines the crow-review-pr SKILL body for Cursor so the `agent`
            // CLI gets a self-contained brief — no slash-command engine
            // needed (#431). `reviewPromptDispatched` gates both kinds.
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                return "\(agentPath) \"$(cat \(promptPath))\"\n"
            }
            return "\(agentPath)\n"
        case .manager:
            // Manager sessions never auto-launch an agent — Crow drives them
            // externally. Returning nil here is the contract, not a gap.
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
            prompt: prompt
        )
    }

    public func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        // Cursor's Manager is a plain orchestration TUI in the devRoot — no
        // auto-prompt, no `--continue`. Cursor has no `--rc`/`--name`
        // equivalent, so the remote-control / auto-permission knobs don't
        // apply (CROW-433). Terminal backend appends the submitting Enter,
        // so we return the bare command without a trailing newline to match
        // the cross-agent convention.
        return findBinary() ?? "agent"
    }

    /// Cursor CLI exposes `/rename` for naming sessions (CROW-629).
    public func sessionRenameSlashCommand(newName: String) -> String? {
        "/rename \(newName)\n"
    }
}
