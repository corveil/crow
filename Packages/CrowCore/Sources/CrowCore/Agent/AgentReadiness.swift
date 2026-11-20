import Foundation

/// Whether a session's coding agent can take input right now (CROW-1475).
///
/// Reported as `agent_state` on `get-session` and `list-sessions`, and what
/// `crow wait` and `crow send --wait-ready` / `--wait-ack` poll. It folds the
/// signals Crow already has into one answer a script or another agent can act
/// on: the hook-driven ``AgentActivityState``, whether the agent has sent any
/// hook since it was (re)launched, the terminal's ``TerminalReadiness``, and
/// the live foreground command in the agent's tmux pane.
public enum AgentReadinessState: String, Codable, Sendable, CaseIterable {
    /// Launched (or about to be) but has not announced itself with a hook
    /// event yet, or announced less than ``AgentReadiness/composerSettle`` ago.
    /// Text pasted now can land in the shell or a half-drawn TUI.
    case starting
    /// At its prompt, ready for input.
    case idle
    /// Running a turn.
    case working
    /// Blocked on the operator: a permission prompt or a question.
    case waitingPermission = "waiting_permission"
    /// The agent process is gone (the pane is back at a shell), or the
    /// terminal never came up. It will not become ready on its own.
    case exited
}

/// Pure derivation of ``AgentReadinessState`` (CROW-1475). Kept free of
/// `AppState` and tmux so every rule is unit-testable.
public enum AgentReadiness {

    /// After the first hook of a fresh launch, the agent's composer can still
    /// need a moment before it accepts a paste. Cursor's `SessionStart` fires
    /// before its composer owns stdin (CROW-1237). `TodoRPC.composerSettleNanos`
    /// is derived from this, so Explore/Talk and `agent_state` wait the same.
    public static let composerSettle: TimeInterval = 1.5

    /// How long after a launch an agent that owns its pane but has sent no
    /// hook is taken as up anyway. Antigravity has no startup hook, and
    /// OpenCode may not emit `SessionStart` before its first prompt, so
    /// without this they would read `starting` until the first prompt and
    /// `crow send --wait-ready` could never send it.
    public static let hooklessLaunchGrace: TimeInterval = 10

    /// The facts the derivation reads. Callers fill them from `AppState`
    /// (hook state, terminal readiness) and one tmux read.
    public struct Inputs: Sendable, Equatable {
        /// The session has an agent terminal at all. False for a session with
        /// no agent pane (no terminal yet, or only Shell tabs).
        public var hasAgentTerminal: Bool
        /// The agent terminal's readiness. Nil when it isn't tracked (Manager
        /// terminals don't track readiness).
        public var readiness: TerminalReadiness?
        /// Live `#{pane_current_command}` of the agent pane. Nil when unknown
        /// (no tmux window bound, or the read failed).
        public var paneCommand: String?
        /// The primary Manager's exit monitor saw its agent exit.
        public var processExited: Bool
        /// The agent was launched and no hook event has arrived since.
        public var launchPending: Bool
        /// When that launch was marked. Drives ``AgentReadiness/hooklessLaunchGrace``.
        public var launchedAt: Date?
        /// When the first hook event after the latest launch arrived.
        public var announcedAt: Date?
        /// Hook-driven activity.
        public var activity: AgentActivityState
        /// A permission prompt or question is pending.
        public var hasPendingNotification: Bool
        /// The current turn has ended (a top-level `Stop` / `StopFailure` since
        /// the last prompt).
        public var turnEnded: Bool

        public init(
            hasAgentTerminal: Bool,
            readiness: TerminalReadiness? = nil,
            paneCommand: String? = nil,
            processExited: Bool = false,
            launchPending: Bool = false,
            launchedAt: Date? = nil,
            announcedAt: Date? = nil,
            activity: AgentActivityState = .idle,
            hasPendingNotification: Bool = false,
            turnEnded: Bool = false
        ) {
            self.hasAgentTerminal = hasAgentTerminal
            self.readiness = readiness
            self.paneCommand = paneCommand
            self.processExited = processExited
            self.launchPending = launchPending
            self.launchedAt = launchedAt
            self.announcedAt = announcedAt
            self.activity = activity
            self.hasPendingNotification = hasPendingNotification
            self.turnEnded = turnEnded
        }
    }

    /// The session's agent state, or nil when it has no agent terminal.
    public static func state(_ inputs: Inputs, now: Date = Date()) -> AgentReadinessState? {
        guard inputs.hasAgentTerminal else { return nil }
        if inputs.processExited { return .exited }
        switch inputs.readiness {
        case .failed?, .timedOut?:
            // The surface never came up, so nothing will launch on its own.
            return .exited
        case .uninitialized?, .surfaceCreated?, .shellReady?:
            // A work terminal whose deferred launch hasn't been typed yet.
            return .starting
        case .agentLaunched?, nil:
            break
        }
        let paneIsShell = inputs.paneCommand.map(paneIsShell)
        // No hook since the launch: the agent may not own the pane yet. A
        // shell pane here is "not exec'd yet", not "exited". Past the grace,
        // an agent process that does own the pane is taken as up.
        if inputs.launchPending {
            guard paneIsShell == false,
                  let launchedAt = inputs.launchedAt,
                  now.timeIntervalSince(launchedAt) >= hooklessLaunchGrace else {
                return .starting
            }
        }
        if paneIsShell == true { return .exited }
        switch inputs.activity {
        case .working:
            return .working
        case .waiting:
            // `StopFailure` (an API error) also sets `.waiting`, with no
            // notification and the turn over: the agent is back at its prompt.
            if !inputs.hasPendingNotification && inputs.turnEnded { return settled(inputs, now: now) }
            return .waitingPermission
        case .idle, .done:
            return settled(inputs, now: now)
        }
    }

    /// `idle`, held at `starting` for ``composerSettle`` after the launch's
    /// first hook. Only `idle` waits: an agent that took its prompt as argv is
    /// `working` straight away.
    private static func settled(_ inputs: Inputs, now: Date) -> AgentReadinessState {
        if let announcedAt = inputs.announcedAt,
           now.timeIntervalSince(announcedAt) < composerSettle {
            return .starting
        }
        return .idle
    }

    /// Shells and wrappers an agent pane is born as and falls back to when
    /// the agent exits. Matching shells (not agents) keeps an agent whose
    /// process shows up as `node` or a version string from reading as exited.
    public static let shellCommands: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "login", "tmux",
        "crow-shell-wrapper.sh",
    ]

    /// `#{pane_current_command}` is a shell or Crow's shell wrapper.
    public static func paneIsShell(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var token = (trimmed as NSString).lastPathComponent.lowercased()
        // A login shell can report itself as `-zsh`.
        if token.hasPrefix("-") { token.removeFirst() }
        return shellCommands.contains(token)
    }
}
