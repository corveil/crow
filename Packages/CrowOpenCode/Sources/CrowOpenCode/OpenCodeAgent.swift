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
///  1. **Initial prompt uses run-then-continue.** Cursor seeds its TUI with
///     `agent "<prompt>"`. OpenCode has no positional TUI prompt, so first
///     dispatch runs headless `opencode run "$(cat …)"` (consumes the prompt
///     reliably), then chains `; opencode --continue` to drop into the
///     interactive TUI with a fresh terminal stdin for `crow send` (#547).
///     Bare `opencode`, stdin pipes, and `--prompt` alone were rejected:
///     pipes bind fd 0 and break keyboard input; `--prompt` may only pre-fill.
///  2. **State hooks are a JS plugin, not a `hooks.json`.** OpenCode has no
///     command-based hook file; `OpenCodeHookConfigWriter` installs a plugin
///     into `~/.config/opencode/plugins/` that shells out to `crow
///     hook-event`. See that type for details.
///
/// OpenCode has no `--rc`/`--name`/`--permission-mode` analog. The closest
/// permission knob is `--auto` / `--dangerously-skip-permissions`, probed via
/// `OpenCodeLaunchArgs` only for `.job` sessions with auto-permission mode.
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
            // First launch: headless `run` consumes the prompt file, then
            // `; --continue` opens the interactive TUI (#547). Subsequent
            // restarts skip the headless re-run and resume the TUI only.
            // Capability probes run only for `.job` + autoPermissionMode —
            // reviews never auto-approve and don't need subprocess `--help`
            // calls on the main thread. `reviewPromptDispatched` gates both kinds.
            //
            // Review prompts are agent-aware: SessionService.buildReviewPrompt
            // inlines the crow-review-pr SKILL body for OpenCode (same as
            // Cursor) so the CLI gets a self-contained brief — OpenCode has
            // no Crow slash-command engine.
            let autoForJob = (session.kind == .job) && autoPermissionMode
            let tuiSupportsAuto = autoForJob
                ? OpenCodeLaunchArgs.tuiSupportsAuto(binary: opencodePath)
                : false
            let runHelp = autoForJob
                ? OpenCodeLaunchArgs.runHelpText(binary: opencodePath)
                : ""
            if !session.reviewPromptDispatched {
                let promptFile = session.kind == .review
                    ? ".crow-review-prompt.md"
                    : ".crow-job-prompt.md"
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(promptFile)
                return OpenCodeLaunchArgs.firstLaunchChainedCommand(
                    binary: opencodePath,
                    promptPath: promptPath,
                    autoPermissionMode: autoForJob,
                    tuiSupportsAuto: tuiSupportsAuto,
                    runHelpText: runHelp
                )
            }
            let autoOnResume = autoForJob
            let resumeTuiSupportsAuto = autoOnResume
                ? OpenCodeLaunchArgs.tuiSupportsAuto(binary: opencodePath)
                : false
            return OpenCodeLaunchArgs.resumeTUICommand(
                binary: opencodePath,
                autoPermissionMode: autoOnResume,
                tuiSupportsAuto: resumeTuiSupportsAuto
            )
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
