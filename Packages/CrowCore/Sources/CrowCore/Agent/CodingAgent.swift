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

    /// Every PATH hit for `tokens`, token-major and de-duplicated — the plural
    /// form of `firstOnPath`, with the same ordering guarantee.
    ///
    /// `firstOnPath` answers "which binary do we launch?" with one sample per
    /// token, which is only sound when a token names exactly one tool. It does
    /// not for Cursor's legacy `agent`: with grok-build's `~/.grok/bin/agent`
    /// earlier on PATH than Cursor's own, the single sample *is* the foreign
    /// binary and Cursor is written off as unavailable even though a genuine
    /// install is sitting further down PATH (CROW-989's documented residual).
    /// Returning the whole list lets `AgentDiscovery.evaluate` keep probing past
    /// an impostor instead of stopping at it (CROW-1058).
    ///
    /// Preference order is preserved end-to-end: every hit for the preferred
    /// token comes before any hit for an alias, so a verified `cursor-agent`
    /// still wins over a verified `agent` regardless of PATH order.
    public static func allOnPath(
        tokens: [String],
        lookup: (String) -> [String]
    ) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for token in tokens {
            for path in lookup(token) where seen.insert(path).inserted {
                found.append(path)
            }
        }
        return found
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

    /// Every binary this agent could plausibly launch, most-preferred first:
    /// an explicit `defaults.binaries.<kind>` pin alone (authoritative), else
    /// **all** PATH hits across `binaryTokens` (token-major) followed by every
    /// executable `fallbackCandidates` entry.
    ///
    /// `resolveBinary()` is the head of this list. The tail exists for
    /// `AgentDiscovery.evaluate`, which identity-probes down the list rather
    /// than judging the agent on its first sample — the difference between
    /// "the first `agent` on PATH is grok-build, so Cursor is unavailable" and
    /// "keep looking; Cursor's own `agent` is two entries further along"
    /// (CROW-1058).
    func resolveBinaryCandidates() -> [ResolvedBinary]

    /// Resolve this agent's binary on disk, or return `nil` if it isn't
    /// installed. Convenience over `resolveBinary()` for the many callers that
    /// only need the path.
    ///
    /// ⚠️ **Presence check, not a launch target.** This is a fresh walk every
    /// call, and since discovery may now probe *past* a candidate that failed
    /// identity, the head of the walk is no longer necessarily the binary
    /// discovery approved. Use `launchBinary()` for anything that will be
    /// exec'd; keep this for "is it installed?" questions.
    func findBinary() -> String?

    /// The binary to actually **exec**, or `nil` when none can be trusted.
    ///
    /// `findBinary()` answers "is this agent installed?"; this answers "what do
    /// we put in the pane command?", and the two are deliberately not the same
    /// function. Launch prefers the path that passed the identity probe at
    /// registration over a fresh walk, because a fresh walk is free to land on
    /// a *different* binary than the one Crow verified — which is exactly how a
    /// Cursor session came up running grok-build (CROW-1058).
    ///
    /// Returning `nil` means **do not launch**. For a colliding token that is
    /// the required outcome: running the foreign binary is not a success.
    func launchBinary() -> String?

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
    /// **Muse overrides this** to withhold `--trust-workspace` from `.review`
    /// handoff clones (strip-not-trust — skills/rules load after workspace
    /// trust even when `.muse/` + `.agents/` have been stripped). Cursor used
    /// to, then CROW-954 dropped that carve-out (review clones now launch
    /// pre-trusted, defended by the launch-path `.cursor/` strip). The
    /// requirement is the seam a harness needs to treat a hostile review
    /// checkout differently from a `.work` worktree;
    /// `SessionService.handoffAgent` already calls through it with the live
    /// `session.kind`.
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
    /// three-argument `launchCommand`. Overridden by agents whose launch
    /// varies by kind (Muse withholds `--trust-workspace` from `.review`).
    /// A protocol *requirement* with an extension default, so a call on
    /// `any CodingAgent` still dynamically dispatches to an overriding conformer.
    func launchCommand(
        sessionID: UUID,
        worktreePath: String,
        prompt: String,
        sessionKind: SessionKind
    ) async throws -> String {
        try await launchCommand(
            sessionID: sessionID, worktreePath: worktreePath, prompt: prompt)
    }

    /// Default binary discovery with provenance: the head of
    /// `resolveBinaryCandidates()` — explicit `BinaryOverrides` (`.override`) →
    /// PATH walk over `binaryTokens` (`.path`) → hardcoded `fallbackCandidates`
    /// (`.fallback`). Returns the first resolved absolute path + how it was
    /// found, or `nil` if nothing matches.
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
    func resolveBinary() -> ResolvedBinary? { resolveBinaryCandidates().first }

    /// Default candidate enumeration, in the precedence `resolveBinary()`
    /// documents: `.override` (alone, and authoritative) → every PATH hit across
    /// `binaryTokens`, token-major (`.path`) → every executable
    /// `fallbackCandidates` entry (`.fallback`).
    ///
    /// The head of this list is byte-identical to the pre-CROW-1058
    /// `resolveBinary()`, so nothing about which binary Crow *picks* changes
    /// here. What changes is that the runners-up survive: discovery can probe
    /// past an impostor sitting in front of a genuine install instead of
    /// judging the whole token by its first sample.
    func resolveBinaryCandidates() -> [ResolvedBinary] {
        let fm = FileManager.default
        // 1. Explicit user override from `defaults.binaries.<kind>`. Verify
        //    the path is still executable so a stale override falls through
        //    to discovery rather than breaking registration outright. When it
        //    holds it is the *only* candidate — the user named the exact
        //    binary, so there is nothing to fall back to and nothing to probe.
        if let configured = BinaryOverrides.shared.path(for: kind),
           fm.isExecutableFile(atPath: configured) {
            return [ResolvedBinary(path: configured, source: .override)]
        }
        var candidates: [ResolvedBinary] = []
        // `allOnPath` already de-duplicates within itself; `seen` carries that
        // across the two legs, so a `fallbackCandidates` entry that PATH also
        // resolves isn't probed twice.
        var seen = Set<String>()
        // 2. Walk the user's resolved PATH the same way `command -v` does, once
        //    per token in preference order — but keeping every hit, not just
        //    the first (CROW-1058).
        for path in BinaryTokenResolver.allOnPath(
            tokens: binaryTokens,
            lookup: { ShellEnvironment.shared.findExecutables($0) }
        ) where seen.insert(path).inserted {
            candidates.append(ResolvedBinary(path: path, source: .path))
        }
        // 3. Hardcoded last-resort fallback covers the exotic-PATH case.
        for fb in fallbackCandidates
        where fm.isExecutableFile(atPath: fb) && seen.insert(fb).inserted {
            candidates.append(ResolvedBinary(path: fb, source: .fallback))
        }
        return candidates
    }

    /// Default `findBinary()`: the resolved path from `resolveBinary()`, or `nil`.
    func findBinary() -> String? { resolveBinary()?.path }

    /// Default launch binary: the user's pin, else the path that passed the
    /// identity probe at registration, else — only for an agent whose token
    /// cannot collide — a fresh resolution.
    ///
    /// The last leg is where CROW-1058 is closed. An agent that declares an
    /// alias in `alternateLaunchCommandTokens` has, by that declaration, said
    /// its binary answers to an ambiguous name; handing back an *unverified*
    /// path whose basename is that alias is how Crow came to exec grok-build's
    /// `~/.grok/bin/agent` for a session configured as Cursor. So for those
    /// agents the unverified fallback is narrowed to the unambiguous preferred
    /// name, and anything else resolves to `nil` — refuse to launch rather than
    /// "succeed" by running the colliding binary.
    ///
    /// Agents with no aliases (every conformer but Cursor) skip that narrowing
    /// entirely and behave exactly as before: pin → verified → resolved.
    ///
    /// Executability is re-checked on both cached legs so an uninstall between
    /// boot and launch degrades to "not installed" rather than to a dead path
    /// interpolated into the pane.
    func launchBinary() -> String? {
        let fm = FileManager.default
        if let pinned = BinaryOverrides.shared.path(for: kind),
           fm.isExecutableFile(atPath: pinned) {
            return pinned
        }
        if let verified = VerifiedBinaries.shared.path(for: kind),
           fm.isExecutableFile(atPath: verified) {
            return verified
        }
        guard let resolved = findBinary() else { return nil }
        guard !alternateLaunchCommandTokens.isEmpty else { return resolved }
        guard (resolved as NSString).lastPathComponent == launchCommandToken else { return nil }
        return resolved
    }

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
