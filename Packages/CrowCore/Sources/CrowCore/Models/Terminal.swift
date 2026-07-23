import Foundation

/// Which terminal backend hosts a `SessionTerminal`'s shell.
///
/// tmux is the only backend (#198 → defaulted on in #301 → legacy
/// per-terminal path removed in #303): all terminals share a single
/// embedded xterm.js surface that's attached to a tmux session, and each
/// terminal is one tmux window inside that session. The enum is retained as
/// a single-case discriminator so the persisted schema is stable and a
/// future backend can be added without another migration.
public enum TerminalBackend: String, Codable, Sendable {
    case tmux
}

/// Identifies the tmux window that backs a `.tmux` terminal.
///
/// Persisted alongside the terminal so the app can rebind to the same
/// window across restart (when the user opts in to keeping the tmux
/// server alive between Crow launches).
public struct TmuxBinding: Codable, Sendable, Equatable {
    public let socketPath: String
    public let sessionName: String
    public var windowIndex: Int

    public init(socketPath: String, sessionName: String, windowIndex: Int) {
        self.socketPath = socketPath
        self.sessionName = sessionName
        self.windowIndex = windowIndex
    }
}

/// A terminal instance within a session.
public struct SessionTerminal: Identifiable, Codable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var name: String
    public var cwd: String
    public var command: String?
    public var isManaged: Bool
    public var createdAt: Date
    /// Which backend hosts this terminal. Always `.tmux` since #303; the
    /// custom decoder maps legacy/unknown backend strings forward.
    public var backend: TerminalBackend
    /// The tmux window that backs this terminal. Nil only when registration
    /// hasn't happened yet or failed this run.
    public var tmuxBinding: TmuxBinding?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        name: String = "Shell",
        cwd: String,
        command: String? = nil,
        isManaged: Bool = false,
        createdAt: Date = Date(),
        backend: TerminalBackend = .tmux,
        tmuxBinding: TmuxBinding? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.cwd = cwd
        self.command = command
        self.isManaged = isManaged
        self.createdAt = createdAt
        self.backend = backend
        self.tmuxBinding = tmuxBinding
    }

    // Custom decoder for backward compatibility — existing data lacks
    // isManaged, backend, and tmuxBinding.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        name = try container.decode(String.self, forKey: .name)
        cwd = try container.decode(String.self, forKey: .cwd)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        isManaged = try container.decodeIfPresent(Bool.self, forKey: .isManaged) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        // tmux is the only backend since #303. Decode the raw string and map
        // anything that isn't a known case — including legacy backend values
        // and rows written before this field existed — forward to `.tmux`, so
        // an upgrade never throws on an old store.
        if let raw = try container.decodeIfPresent(String.self, forKey: .backend) {
            backend = TerminalBackend(rawValue: raw) ?? .tmux
        } else {
            backend = .tmux
        }
        tmuxBinding = try container.decodeIfPresent(TmuxBinding.self, forKey: .tmuxBinding)
    }
}

extension SessionTerminal {
    /// Whether this terminal hosts a repainting agent TUI, and so takes the
    /// alt-buffer scroll model instead of the unified scrollback (ADR-0013).
    /// Single source of truth for that classification — the daemon uses it to
    /// set `alternate-screen on` at window creation/adopt, and `list-terminals`
    /// uses it for the `agent_surface` fallback, so the two can't disagree.
    ///
    /// TWO shapes qualify, and both are load-bearing:
    ///   * a managed work terminal (`isManaged`), and
    ///   * a Manager session's **agent** terminal, which launches an agent via
    ///     `command` but is built WITHOUT `isManaged` — `createManagerTerminal`
    ///     relies on the memberwise default of `false`. Keying on `isManaged`
    ///     alone silently excludes the Manager, itself one of the repainting
    ///     agent windows #822 was reported against.
    ///
    /// The `command != nil` half of the Manager test is what keeps this from
    /// over-classifying. A Manager session can hold ADDITIONAL plain shells —
    /// `new-terminal` with just a `session_id` (the `+` button, or
    /// `crow new-terminal --session <manager-uuid>`) yields `isManaged: false`
    /// with no command. Those are line-streaming surfaces and must keep the
    /// unified 50k scrollback; only the terminal that actually launches the
    /// agent gets the alt-buffer model. `createManagerTerminal` always passes a
    /// non-nil `managerCommand(for:)`, so the two are cleanly separable.
    ///
    /// Deliberately NOT `agentKind` (it always resolves to a configured
    /// default, so it never discriminates) and NOT `trackReadiness` (false for
    /// Manager sessions precisely because they launch the agent via `command`).
    ///
    /// Known boundary: an extra Manager-session terminal created with an
    /// explicit `--command` is treated as an agent surface. That is a deliberate
    /// trade — the alternative is persisting a new per-terminal field — and the
    /// cost is only that a hand-launched full-screen program there gets the
    /// naked-terminal scroll model instead of the unified one.
    ///
    /// `session` is this terminal's session; `nil` (not yet hydrated) falls
    /// back to `isManaged` alone.
    public func isAgentSurface(session: Session?) -> Bool {
        if isManaged { return true }
        guard session?.isManager == true else { return false }
        return command != nil
    }
}
