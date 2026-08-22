import Foundation
import CrowCore

/// `CodingAgent` conformer for the OpenAI Codex CLI. Mirrors the shape of
/// `ClaudeCodeAgent` while honoring Codex's quirks — per-worktree
/// `.codex/hooks.json` with the session UUID baked in (CROW-1060; the daemon
/// re-registers this agent with a `CodexHookConfigWriter(asyncHooksSupported:)`
/// once `CodexVersionProbe` has run) and no `--rc` launch flag (remote driving
/// is the shared `crow send` paste path; see `supportsRemoteControl`).
///
/// `codex` 0.141.0 closed the early-MVP gaps (#830): restarts now `codex
/// resume --last` (cwd-scoped by default — `--all` is what disables cwd
/// filtering), unattended `.job` sessions launch the interactive TUI with
/// approval off and the sandbox bounded (`codex -a never -s workspace-write
/// "$(cat …)"`) — deliberately *not* headless `codex exec`, which is one-shot
/// and would drop a multi-prompt job's typed follow-ups into the shell — and
/// `.review` sessions inline the `/crow-review-pr` skill so they post a real
/// GitHub verdict (the native `codex review` subcommand only prints local
/// findings, so it can't satisfy Crow's review-completion contract).
public struct OpenAICodexAgent: CodingAgent {
    public let kind: AgentKind = .codex
    public let displayName: String = "OpenAI Codex"
    /// Visually distinct from Claude's `"sparkles"`. Easy to swap once
    /// branding firms up.
    public let iconSystemName: String = "terminal.fill"
    /// `true` on the same basis as Cursor/OpenCode/Grok/Antigravity: the badge
    /// means *Crow* can drive the session remotely, not that the harness ships
    /// a native RC protocol. It does **not** put `--rc` on any launch — Codex
    /// has no such flag and `autoLaunchCommand` ignores `remoteControlEnabled`.
    ///
    /// This was `false` on the claim that "Codex's TUI isn't stdin-drivable the
    /// way `crow send` fakes RC for the others" — which is wrong, and was never
    /// what `crow send` does. `TerminalRouter.send` is agent-agnostic: it goes
    /// through tmux `load-buffer` → `paste-buffer` → `send-keys Enter`
    /// (`TmuxBackend.sendText`), a paste into the pane, not a write to the
    /// process's stdin. Verified end-to-end against `codex-cli 0.141.0` in a
    /// live pane (CROW-1001): the pasted payload lands in the composer verbatim
    /// and the trailing Enter submits it. So Codex sessions were already
    /// remotely drivable from Crow's web UI and the badge just said otherwise.
    ///
    /// Native `codex remote-control` is **not** why this is true, and is not
    /// wired — three blockers, any one disqualifying (see the harness matrix):
    /// it demands the managed standalone install at
    /// `~/.codex/packages/standalone/current/codex` and refuses on the npm
    /// build every Crow resolves; its daemon is a machine-global singleton on a
    /// fixed control socket with no per-instance flag, so N per-worktree
    /// sessions can't be addressed individually; and `--remote` points a local
    /// TUI at a remote app server, which is the reverse of Crow's direction —
    /// Crow already *is* the remote surface.
    public let supportsRemoteControl: Bool = true
    public let launchCommandToken: String = "codex"
    public let hookConfigWriter: any HookConfigWriter
    public let stateSignalSource: any StateSignalSource

    private let launcher: CodexLauncher

    /// Last-resort search paths for the `codex` binary, used only when the
    /// configured `BinaryOverrides` and a PATH walk both miss. Most users will
    /// resolve through PATH (codex ships via `npm i -g @openai/codex` and
    /// lives wherever the user's Node manager puts globals); this list is just
    /// the historical hardcoded set we used to check first (CROW-484).
    public let fallbackCandidates: [String] = [
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
    ]

    public init(
        hookConfigWriter: any HookConfigWriter = CodexHookConfigWriter(),
        stateSignalSource: any StateSignalSource = CodexSignalSource()
    ) {
        self.hookConfigWriter = hookConfigWriter
        self.stateSignalSource = stateSignalSource
        self.launcher = CodexLauncher()
    }

    public func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String? {
        let codexPath = launchBinary() ?? "codex"

        switch session.kind {
        case .work:
            // App-restart / terminal-recovery path (`autoLaunchCommand` only
            // fires for restored terminals — brand-new `.work` sessions are
            // seeded by `launch_codex` in `crow-workspace/setup.sh` via
            // `--command`). Resume the most recent recorded thread instead of
            // reopening a blank TUI (#830 — the "no `--continue` in MVP" pin is
            // gone). `--last` is cwd-scoped (`--all` is the flag that *disables*
            // cwd filtering), so it selects this worktree's own thread; and when
            // no thread exists yet (fresh/pruned worktree, or Codex was opened
            // but never took a turn) `codex resume --last` gracefully opens a new
            // interactive TUI rather than erroring — verified against 0.141.0 in
            // a pty, so no `|| codex` fallback is needed (#843 review round 3).
            // No env prefix (Codex has no OTEL equivalent), and no `--rc` —
            // Codex ships no such flag, so `remoteControlEnabled` never changes
            // the launch text even though `supportsRemoteControl` is `true`
            // (the badge tracks the `crow send` paste path, CROW-1001).
            // Mirrors Claude's `--continue`.
            return "\(codexPath) resume --last\n"
        case .job:
            if !session.reviewPromptDispatched {
                // First launch: feed `.crow-job-prompt.md` as the initial
                // message so Codex starts working unattended. `SessionService`
                // wrote the file and flips `reviewPromptDispatched` after the
                // command goes out.
                //
                // Always the **interactive** TUI, never headless `codex exec`:
                // a job may carry multiple prompts, and `JobScheduler`
                // (`sendSequentially`) types the follow-up prompts into the same
                // tmux pane after the first. `codex exec` is one-shot — it exits
                // after prompt 1, so prompt 2 would be typed at the *shell*,
                // which then executes prose (backticks / `&&` / `$(…)` in the
                // prompt evaluate). The TUI stays alive and consumes typed lines
                // as prompts, matching every other agent's job path (#843 review
                // round 3). Auto-permission just adds the bounded approval +
                // sandbox flags to the same interactive launch.
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(".crow-job-prompt.md")
                if autoPermissionMode {
                    // Approval off, workspace-write sandbox still ON — the
                    // bounded analogue of Claude's `--permission-mode auto`
                    // (#830). Deliberately NOT
                    // `--dangerously-bypass-approvals-and-sandbox` /
                    // `-s danger-full-access` (those disable the sandbox; only
                    // for externally-sandboxed runners). Options precede the
                    // positional prompt.
                    return ShellLaunchArgs.evalPromptLaunch(
                        prefix: "\(codexPath) -a never -s workspace-write",
                        promptPath: promptPath)
                }
                // Auto-permission off: interactive TUI with the initial prompt,
                // default approval policy so the user approves each step.
                return ShellLaunchArgs.evalPromptLaunch(
                    prefix: codexPath,
                    promptPath: promptPath)
            }
            // Subsequent restarts resume the prior thread — interactive, so
            // plain `--last` (cwd-scoped) selects it. Carry the same bounded
            // auto-permission flags when they're on, so an unattended job
            // resumed after a crowd/app restart doesn't stall at Codex's default
            // approval policy (#843 review round 4 — `codex resume` accepts
            // `-a`/`-s`). `.work`/`.review` resume flagless (`.work` isn't
            // auto-driven; `.review` is human-gated by design).
            if autoPermissionMode {
                return "\(codexPath) resume --last -a never -s workspace-write\n"
            }
            return "\(codexPath) resume --last\n"
        case .review:
            // Review sessions inline `.crow-review-prompt.md` (the expanded
            // `/crow-review-pr` skill), exactly like Cursor/OpenCode — the skill
            // body runs `gh pr review …`, which is what satisfies Crow's review
            // completion contract (`IssueTracker.decideReviewCompletions` closes
            // a review only once the viewer has a *posted* GitHub verdict). The
            // native `codex review --base` subcommand only prints local findings
            // and posts nothing, so a review driven by it could never complete
            // and would be re-kicked on every head-SHA advance (#830 review).
            //
            // Kept interactive (not the headless `exec -a never -s
            // workspace-write` path the `.job` branch could use): the inlined
            // skill's `gh pr review` posting step needs network, and the
            // workspace-write sandbox blocks it — so the same TUI path Cursor
            // uses is the one that actually lands a verdict. Consequence: an
            // unattended review stalls at Codex's first approval prompt
            // (human-gated, same as Cursor; documented in the matrix). First
            // launch feeds the prompt; restarts resume the thread.
            if !session.reviewPromptDispatched {
                let promptPath = (worktreePath as NSString)
                    .appendingPathComponent(".crow-review-prompt.md")
                return ShellLaunchArgs.evalPromptLaunch(
                    prefix: codexPath,
                    promptPath: promptPath)
            }
            return "\(codexPath) resume --last\n"
        case .manager:
            // Manager sessions never auto-launch an agent — Crow drives them
            // externally. Matches `CursorAgent`'s `.manager` contract.
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
        // Codex's Manager is a plain TUI in the devRoot — no auto-prompt,
        // no `--rc` flag, no auto-permission knob (CROW-433). Terminal
        // backend appends the submitting Enter, so we return the bare
        // command without a trailing newline.
        //
        // Emitting no `--rc` also keeps the Manager off the RC badge: the
        // Manager's bookkeeping gates on `" --rc"` appearing in the built
        // command rather than on `supportsRemoteControl`
        // (`SessionService.ensureManagerSession`), so the CROW-1001 flip
        // leaves this path exactly as it was — same as Cursor's Manager.
        return launchBinary() ?? "codex"
    }

    /// Codex TUI exposes `/rename` for the current thread (CROW-629).
    public func sessionRenameSlashCommand(newName: String) -> String? {
        "/rename \(newName)\n"
    }

    /// Codex writes one NDJSON rollout per session under a global, date-partitioned
    /// tree — `~/.codex/sessions/<YYYY>/<MM>/<DD>/rollout-<ISO-ts>-<uuid>.jsonl` —
    /// and records the working directory it ran in on the first line
    /// (`session_meta.payload.cwd`, verified against `codex-cli` 0.100–0.141 rollouts).
    ///
    /// Unlike Claude, the rollouts are NOT partitioned by working directory, so a
    /// worktree path can't be turned into a directory path. Attribution is instead
    /// by **content**: the source scans the whole `sessions` tree recursively but
    /// carries a `cwdFilter`, and the collector keeps only the rollouts whose
    /// recorded `cwd` equals this worktree (`AgentLogCwdReader`). A rollout with no
    /// readable cwd is dropped rather than guessed — an unattributable transcript
    /// is worse than a missing one (CROW-1089).
    ///
    /// `harnessSessionID` is unused: the exact rollout filename also encodes a
    /// timestamp, so a bare session id can't name the file, and cwd-matching is
    /// the reliable selector regardless. The format is `.logDir` (the reserved
    /// "concatenate per-session files into one NDJSON artifact" case) because a
    /// Crow session may span several `codex`/`codex resume` invocations in the same
    /// worktree, each its own rollout; the collector concatenates all cwd-matches
    /// chronologically.
    public func logSources(worktreePath: String, harnessSessionID: String?) -> [AgentLogSource] {
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        return [.directory(
            sessionsDir.path, format: .logDir, fileExtension: "jsonl",
            recursive: true, cwdFilter: worktreePath)]
    }
}
