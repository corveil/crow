import Foundation

/// A coding agent that Crow can launch in a terminal and observe via hook
/// events. Phase A wraps the existing Claude Code integration; later phases
/// introduce additional conformers.
public protocol CodingAgent: Sendable {
    /// Stable identifier for this agent implementation.
    var kind: AgentKind { get }

    /// Human-readable name shown in pickers, tooltips, and the session detail
    /// header (e.g. "Claude Code").
    var displayName: String { get }

    /// SF Symbol name rendered in the sidebar row and pickers. Kept as a
    /// string so `CrowCore` stays SwiftUI-free; consumers resolve it via
    /// `Image(systemName:)`.
    var iconSystemName: String { get }

    /// Whether this agent supports Crow's "remote control" feature (the
    /// `--rc --name` flags Claude Code uses to register a session in
    /// claude.ai's Remote Control panel). Drives whether the remote-control
    /// badge is shown for this agent's sessions.
    var supportsRemoteControl: Bool { get }

    /// The shell token that identifies a command as launching this agent.
    /// Used by the `send` RPC handler to decide whether a managed-terminal
    /// command needs hook-config + env-var prep before being forwarded.
    /// Examples: `"claude"`, `"codex"`.
    var launchCommandToken: String { get }

    /// Writer for the per-worktree hook configuration file.
    var hookConfigWriter: any HookConfigWriter { get }

    /// State-machine implementation that converts hook events into
    /// `AgentStateTransition` values.
    var stateSignalSource: any StateSignalSource { get }

    /// Last-resort hardcoded paths for the agent's CLI binary, checked after
    /// the user's explicit `BinaryOverrides` and a PATH walk both miss. Used
    /// only when the user's resolved PATH is unusually narrow (CROW-484). An
    /// empty list is fine — most agents will resolve through PATH first.
    var fallbackCandidates: [String] { get }

    /// Resolve this agent's binary on disk, or return `nil` if it isn't
    /// installed. Drives binary-presence gating for the per-session picker
    /// and the launch-command builder below.
    func findBinary() -> String?

    /// Build the full shell command (ending with `\n`) that auto-launches
    /// this agent in `worktreePath`. Returns `nil` when the agent can't be
    /// launched — typically because the binary is missing or the session
    /// kind is unsupported.
    ///
    /// `autoPermissionMode` requests that the agent skip per-call permission
    /// prompts where possible (used for unattended `.job` sessions). Agents
    /// that don't surface this concept can ignore it.
    func autoLaunchCommand(
        session: Session,
        worktreePath: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String?

    /// Build the initial prompt for this agent based on the session context.
    ///
    /// `provider` is the **task** provider (where the ticket lives); `codeProvider`
    /// is the **code** provider (where the PR lives), defaulting to `provider`
    /// when `nil`. They differ for cross-backend sessions (e.g. Jira task + GitHub
    /// code) so the ticket fetch and the PR step route to different CLIs (ADR 0005).
    func generatePrompt(
        session: Session,
        worktrees: [SessionWorktree],
        ticketURL: String?,
        provider: Provider?,
        codeProvider: Provider?
    ) async -> String

    /// Materialize `prompt` to disk (if needed) and return the shell command
    /// that starts the agent with that prompt in `worktreePath`.
    func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String
    ) async throws -> String

    /// Build the shell command that the Manager tab uses to launch this
    /// agent in the devRoot. Unlike `autoLaunchCommand`, this is the
    /// terminal's pre-populated `command` string — it runs before the
    /// shell prompt is ready, with no auto-prompt or `--continue` flag.
    ///
    /// `sessionName` labels the agent's session in claude.ai's Remote
    /// Control panel (and analogous systems if other agents support it).
    /// `autoPermissionMode` mirrors `ClaudeCodeAgent`'s `--permission-mode auto`
    /// — agents that don't surface this concept can ignore it. `telemetryPort`
    /// is passed through for consistency with `autoLaunchCommand`; most
    /// agents won't need it for Manager terminals (CROW-433).
    func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String

    /// Slash-command text to paste into a running agent TUI so its session
    /// title matches Crow's rename, or `nil` when the agent has no rename
    /// surface. Crow sends this after `renameSession` (CROW-629). Opt-in:
    /// the protocol default returns `nil` so future agents cannot inherit a
    /// spurious `/rename` paste; Claude/Cursor/Codex/OpenCode override.
    func sessionRenameSlashCommand(newName: String) -> String?
}

public extension CodingAgent {
    /// Default empty `fallbackCandidates` so simple conformers don't have to
    /// declare an empty array. Agents with known install locations should
    /// override this.
    var fallbackCandidates: [String] { [] }

    /// Default binary discovery: explicit `BinaryOverrides` → PATH walk
    /// (using the agent's `launchCommandToken` as the binary name) →
    /// hardcoded `fallbackCandidates`. Returns the first resolved absolute
    /// path, or `nil` if nothing matches.
    ///
    /// This replaces the per-agent hardcoded-list-only impl that left
    /// nvm/Volta/pnpm/asdf installs invisible to Crow (CROW-484).
    func findBinary() -> String? {
        let fm = FileManager.default
        // 1. Explicit user override from `defaults.binaries.<kind>`. Verify
        //    the path is still executable so a stale override falls through
        //    to discovery rather than breaking registration outright.
        if let configured = BinaryOverrides.shared.path(for: kind),
           fm.isExecutableFile(atPath: configured) {
            return configured
        }
        // 2. Walk the user's resolved PATH the same way `command -v` does.
        if let found = ShellEnvironment.shared.findExecutable(launchCommandToken) {
            return found
        }
        // 3. Hardcoded last-resort fallback covers the exotic-PATH case.
        return fallbackCandidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Default Manager launch command: invoke the agent's CLI binary by
    /// name with no extra flags. The tmux terminal backend owns
    /// the submitting Enter — return the raw command without a trailing
    /// newline so the convention is uniform across agents (CROW-433 review).
    func managerLaunchCommand(
        sessionName: String,
        remoteControlEnabled: Bool,
        autoPermissionMode: Bool,
        telemetryPort: UInt16?
    ) -> String {
        return launchCommandToken
    }

    /// Opt-out default: no rename slash command. Agents that expose `/rename`
    /// (Claude Code, Cursor, Codex, OpenCode) override this. Returning `nil`
    /// here prevents a future agent from silently inheriting a paste that
    /// would be sent to the model as a stray prompt (CROW-629 review).
    func sessionRenameSlashCommand(newName: String) -> String? { nil }
}
