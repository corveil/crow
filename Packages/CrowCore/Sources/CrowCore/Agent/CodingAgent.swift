import Foundation

/// How `CodingAgent.resolveBinary()` located a binary. Lets registration branch
/// on provenance — an explicit `.override` pin is authoritative and bypasses the
/// identity probe — from one source of truth instead of re-deriving the
/// override-first precedence a second time (CROW-911 review).
public enum BinaryResolutionSource: Sendable, Equatable {
    /// An explicit `defaults.binaries.<kind>` pin.
    case override
    /// A `command -v`-style PATH walk on `launchCommandToken`.
    case path
    /// A hardcoded `fallbackCandidates` entry (exotic-PATH last resort).
    case fallback
}

/// A resolved agent binary and how it was found.
public struct ResolvedBinary: Sendable, Equatable {
    public let path: String
    public let source: BinaryResolutionSource
    public init(path: String, source: BinaryResolutionSource) {
        self.path = path
        self.source = source
    }
}

/// The PATH leg of `CodingAgent.resolveBinary()`, factored out of the protocol
/// extension so the ordering guarantee is unit-testable — `ShellEnvironment` is
/// a singleton that snapshots the real PATH at init, so the walk can't otherwise
/// be exercised against a synthetic one.
public enum BinaryTokenResolver {
    /// Return the first `lookup` hit, trying `tokens` in order.
    ///
    /// **Token-major, not directory-major** — and that's the whole point. A
    /// directory-major walk (each PATH entry checked for every token) would let
    /// PATH *order* decide between an agent's preferred binary name and its
    /// ambiguous alias, which is exactly how a foreign `~/.grok/bin/agent` early
    /// in PATH beat Cursor's own CLI (CROW-989). Trying every PATH entry for
    /// `cursor-agent` before any is tried for `agent` makes the choice depend on
    /// the *name*, not on install order.
    ///
    /// Single-token agents are unaffected: one pass, identical to the old walk.
    public static func firstOnPath(
        tokens: [String],
        lookup: (String) -> String?
    ) -> String? {
        for token in tokens {
            if let found = lookup(token) { return found }
        }
        return nil
    }
}

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

    /// Whether this agent's interactive TUI enters the terminal alternate
    /// screen (`smcup` / DECSET 1049). Crow still classifies the window as an
    /// agent surface either way (ADR-0013); this flag selects the scroll
    /// model: alt-buffer sediment kill (true) vs unified 50k native
    /// scrollback, like a plain shell (false, CROW-1010).
    ///
    /// CROW-1023: this static capability is now only the PRE-WINDOW prior. Once
    /// a tmux window exists, `list-terminals` reports `uses_alternate_screen`
    /// from a per-window runtime read of `#{alternate_on}` (latched), because
    /// Claude Code builds diverge — some enter the alt buffer, some render
    /// inline — and a single per-kind value cannot describe both. Keep this in
    /// sync with the *common* build's behavior so the brief pre-window window is
    /// right, but the runtime read is the source of truth thereafter.
    ///
    /// Claude Code's common build is `true`. Cursor's `agent` CLI paints
    /// inline and never requests the alt buffer — its history is a clean
    /// transcript, so it must keep terminal scrollback (the CROW-1008
    /// `history-limit 0` clamp deleted its only wheel path). The default is
    /// `false` so an unverified harness (Codex, OpenCode, Grok, Antigravity)
    /// scrolls like a shell. Opt in with `true` once a live pane shows
    /// `alternate_on=1`.
    var usesAlternateScreen: Bool { get }

    /// The shell token that identifies a command as launching this agent.
    /// Used by the `send` RPC handler to decide whether a managed-terminal
    /// command needs hook-config + env-var prep before being forwarded.
    /// Examples: `"claude"`, `"codex"`.
    ///
    /// Also the **preferred** binary name for the PATH walk in
    /// `resolveBinary()`. When a harness ships more than one name for the same
    /// executable, this is the unambiguous one; see
    /// `alternateLaunchCommandTokens` for the legacy/ambiguous aliases.
    var launchCommandToken: String { get }

    /// Additional binary names this agent may be installed under, in descending
    /// preference order after `launchCommandToken`.
    ///
    /// Two uses, deliberately one list (search order *is* preference order):
    ///  - `resolveBinary()` walks PATH for `launchCommandToken` first, then each
    ///    of these — so an unambiguous name always wins over an ambiguous alias
    ///    regardless of PATH ordering.
    ///  - `AgentLaunch.commandLaunchesAgent` matches a command against **any** of
    ///    them, so a legacy install invoked under its old name still gets
    ///    hook-config + env prep.
    ///
    /// Empty for every agent whose CLI ships a single name. Cursor is the one
    /// conformer today: it prefers `cursor-agent` and keeps the generic `agent`
    /// as an alias, because xAI's grok-build installs its own `~/.grok/bin/agent`
    /// and won the PATH walk (CROW-989).
    var alternateLaunchCommandTokens: [String] { get }

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

    /// Resolve this agent's binary on disk **with its provenance**, or `nil` if
    /// it isn't installed. The single owner of the override → PATH → fallback
    /// precedence; `findBinary()` and registration both read from it so the two
    /// can't drift (CROW-911 review). Drives binary-presence gating for the
    /// per-session picker and the launch-command builder below.
    func resolveBinary() -> ResolvedBinary?

    /// Resolve this agent's binary on disk, or return `nil` if it isn't
    /// installed. Convenience over `resolveBinary()` for the many callers that
    /// only need the path.
    func findBinary() -> String?

    /// Confirm the binary resolved at `path` is genuinely *this* agent and not
    /// a different tool that happens to share the launch token (CROW-911).
    ///
    /// Registration runs this after `findBinary()` resolves a path **via the
    /// PATH walk or `fallbackCandidates`** — never for an explicit
    /// `defaults.binaries.<kind>` pin, which is authoritative (the user has
    /// named the exact binary). A `false` return marks the agent unavailable
    /// even though a same-named binary exists, so a colliding tool is shown
    /// disabled rather than falsely active.
    ///
    /// The default returns `true`: an unambiguous launch token is trusted on a
    /// bare match, preserving today's behavior for every agent. Only agents
    /// whose token is known to collide override this to run a cheap
    /// `--version` / `--help` identity probe — Grok Build (`grok` collides with
    /// the community `superagent-ai/grok-cli`) and Cursor (whose legacy `agent`
    /// alias collides with xAI's `~/.grok/bin/agent`, CROW-989). Both share
    /// `BinaryIdentityProbe` rather than reimplementing the bounded subprocess
    /// race.
    func verifyBinaryIdentity(atPath path: String) async -> Bool

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

    /// Kind-aware variant of `launchCommand`, for agents whose handoff launch
    /// depends on the session kind. The protocol-extension default ignores
    /// `sessionKind` and delegates to the three-argument `launchCommand`, so an
    /// agent with no kind-dependent launch need not implement it.
    ///
    /// **No agent overrides this today.** Cursor was the only one — it withheld
    /// its `--trust` workspace-trust seed from `.review` handoff clones — and
    /// CROW-954 dropped that carve-out (review clones now launch pre-trusted,
    /// defended by the launch-path `.cursor/` strip instead of a folder-trust
    /// dialog). The requirement is kept because it is the seam a future harness
    /// needs to treat a hostile review checkout differently from a `.work`
    /// worktree; `SessionService.handoffAgent` already calls through it with the
    /// live `session.kind`, so adding one is a single override.
    func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String,
        sessionKind: SessionKind
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

    /// Default: the TUI is an inline renderer and keeps the unified 50k
    /// scrollback (CROW-1010). Only Claude Code currently opts into the
    /// alt-buffer path; see `usesAlternateScreen` on the protocol.
    var usesAlternateScreen: Bool { false }

    /// Default: no aliases — the agent's CLI ships exactly one binary name.
    var alternateLaunchCommandTokens: [String] { [] }

    /// Every binary name this agent answers to, most-preferred first. The single
    /// ordering used by both the PATH walk and command-token matching, so those
    /// two can't disagree about which names count as "this agent".
    var binaryTokens: [String] { [launchCommandToken] + alternateLaunchCommandTokens }

    /// Default kind-aware launch: ignore `sessionKind` and delegate to the
    /// three-argument `launchCommand`. Overridden only by agents whose launch
    /// varies by kind (today just Cursor's trust seed). A protocol *requirement*
    /// with an extension default, so a call on `any CodingAgent` still
    /// dynamically dispatches to an overriding conformer.
    func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String,
        sessionKind: SessionKind
    ) async throws -> String {
        try await launchCommand(
            sessionID: sessionID, worktreePath: worktreePath, prompt: prompt)
    }

    /// Default binary discovery with provenance: explicit `BinaryOverrides`
    /// (`.override`) → PATH walk over `binaryTokens` (`.path`) → hardcoded
    /// `fallbackCandidates` (`.fallback`). Returns the first resolved absolute
    /// path + how it was found, or `nil` if nothing matches.
    ///
    /// This replaces the per-agent hardcoded-list-only impl that left
    /// nvm/Volta/pnpm/asdf installs invisible to Crow (CROW-484).
    ///
    /// The PATH walk is **token-major, not directory-major**: every PATH entry is
    /// searched for the preferred token before any is searched for an alias. That
    /// ordering is the point — it makes resolution independent of PATH order, so
    /// an unambiguous `cursor-agent` late in PATH still beats a foreign `agent`
    /// early in it (CROW-989). Agents with no aliases are unaffected: one token,
    /// one walk, byte-identical behavior.
    func resolveBinary() -> ResolvedBinary? {
        let fm = FileManager.default
        // 1. Explicit user override from `defaults.binaries.<kind>`. Verify
        //    the path is still executable so a stale override falls through
        //    to discovery rather than breaking registration outright.
        if let configured = BinaryOverrides.shared.path(for: kind),
           fm.isExecutableFile(atPath: configured) {
            return ResolvedBinary(path: configured, source: .override)
        }
        // 2. Walk the user's resolved PATH the same way `command -v` does, once
        //    per token in preference order.
        if let found = BinaryTokenResolver.firstOnPath(
            tokens: binaryTokens,
            lookup: { ShellEnvironment.shared.findExecutable($0) }
        ) {
            return ResolvedBinary(path: found, source: .path)
        }
        // 3. Hardcoded last-resort fallback covers the exotic-PATH case.
        if let fb = fallbackCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return ResolvedBinary(path: fb, source: .fallback)
        }
        return nil
    }

    /// Default `findBinary()`: the resolved path from `resolveBinary()`, or `nil`.
    func findBinary() -> String? { resolveBinary()?.path }

    /// Default identity check: trust a bare match. Agents with an unambiguous
    /// launch token don't need to probe — overridden only by collision-prone
    /// tokens (Grok Build, Cursor) so a foreign same-named binary is shown
    /// disabled instead of falsely active (CROW-911, CROW-989).
    func verifyBinaryIdentity(atPath path: String) async -> Bool { true }

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
