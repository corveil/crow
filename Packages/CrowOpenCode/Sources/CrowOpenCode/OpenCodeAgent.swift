import Foundation
import CrowCore

/// `CodingAgent` conformer for the OpenCode CLI (`opencode` binary,
/// sst/opencode). Structurally mirrors `CursorAgent`: OpenCode runs an
/// interactive TUI, so remote control is `crow send` typing into the TUI
/// (the agent-agnostic stdin-paste path in `SessionService`) rather than a
/// launch flag, and its hook configuration is global rather than
/// per-worktree.
///
/// Two genuine divergences from Cursor, handled below and flagged in
/// CROW-545 as the closest OpenCode equivalents rather than 1:1 parity:
///
///  1. **Unattended launch is headless.** Cursor seeds its TUI with an
///     initial prompt via `agent "<prompt>"` and stays interactive.
///     OpenCode's positional prompt lives on the `opencode run` subcommand,
///     which drives the agent to completion and exits — it does not drop
///     into a watchable TUI. `opencode run` is the documented unattended
///     form, so `.job`/`.review` use it; whether a seed-the-TUI variant
///     exists should be confirmed empirically.
///  2. **State hooks are a JS plugin, not a `hooks.json`.** OpenCode has no
///     command-based hook file; `OpenCodeHookConfigWriter` installs a plugin
///     into `~/.config/opencode/plugins/` that shells out to `crow
///     hook-event`. See that type for details.
///
/// OpenCode has no `--rc`/`--name`/`--permission-mode` analog. The closest
/// permission knob is `--dangerously-skip-permissions` (used only for
/// unattended `.job` dispatch when Crow requests auto-permission mode).
public struct OpenCodeAgent: CodingAgent {
    public let kind: AgentKind = .openCode
    public let displayName: String = "OpenCode"
    /// Code-brackets glyph — visually distinct from Claude's `"sparkles"`,
    /// Codex's `"terminal.fill"`, and Cursor's `"cursorarrow.rays"`.
    public let iconSystemName: String = "chevron.left.forwardslash.chevron.right"
    /// TUI is remote-driven by `crow send`, so remote control is supported
    /// even though OpenCode has no `--rc` flag (parity with `CursorAgent`).
    public let supportsRemoteControl: Bool = true
    public let launchCommandToken: String = "opencode"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: OpenCodeLauncher

    /// Last-resort search paths for the `opencode` binary, used only when the
    /// configured `BinaryOverrides` and a PATH walk both miss (CROW-484).
    /// Includes `~/.opencode/bin/opencode`, the location OpenCode's own
    /// install script uses in addition to the usual Homebrew/local prefixes.
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/opencode",
        "/usr/local/bin/opencode",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/opencode").path,
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin/opencode").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = OpenCodeHookConfigWriter(),
        stateSignalSource: any StateSignalSource = OpenCodeSignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = OpenCodeLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let opencodePath = findBinary() ?? "opencode"

        switch session.kind {
        case .work:
            // Bare `opencode` launch — the user types their prompt into the
            // TUI. No env prefix (OpenCode reads provider creds from its own
            // config / env), no `--continue` (MVP doesn't auto-resume), no
            // remote-control flag (remote control is `crow send` typing into
            // the TUI — agent-agnostic, handled by `SessionService.send`).
            // OpenCode has no `--rc`/`--name` analog anyway.
            return "\(opencodePath)\n"
        case .job, .review:
            // Unattended dispatch. Unlike Cursor's `agent "<prompt>"` (which
            // seeds the interactive TUI), OpenCode's positional prompt lives
            // on the `run` subcommand, which is HEADLESS — it drives the
            // agent to completion and exits rather than dropping into a
            // watchable TUI. `opencode run` is the closest documented
            // OpenCode unattended form (CROW-545 gap: confirm empirically
            // whether a seed-the-TUI variant exists). On subsequent app
            // restarts we fall back to a bare `opencode` (the TUI) rather
            // than re-running the whole prompt headlessly — mirrors the
            // Cursor/Claude subsequent-launch contract. `reviewPromptDispatched`
            // gates both `.review` and `.job` first-launch.
            //
            // Review prompts are agent-aware: SessionService.buildReviewPrompt
            // inlines the crow-review-pr SKILL body for OpenCode (same as
            // Cursor) so the CLI gets a self-contained brief — OpenCode has
            // no Crow slash-command engine.
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                // `--dangerously-skip-permissions` is OpenCode's unattended
                // auto-approve flag — the closest analog to Claude's
                // `--permission-mode auto`. Applied only when Crow requests
                // it (`.job` + jobsAutoPermissionMode); `.review` leaves it
                // off so the reviewer still gates writes.
                let permFlag = autoPermissionMode ? " --dangerously-skip-permissions" : ""
                return "\(opencodePath) run \"$(cat \(promptPath))\"\(permFlag)\n"
            }
            return "\(opencodePath)\n"
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
        // OpenCode's Manager is a plain orchestration TUI in the devRoot — no
        // auto-prompt, no `--continue`. OpenCode has no `--rc`/`--name`
        // equivalent, so the remote-control / auto-permission knobs don't
        // apply (parity with `CursorAgent`). Terminal backend appends the
        // submitting Enter, so we return the bare command without a trailing
        // newline to match the cross-agent convention.
        return findBinary() ?? "opencode"
    }
}
