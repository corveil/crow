import Foundation

/// Which terminal backend hosts a `SessionTerminal`'s shell.
///
/// tmux is the only backend (#198 → defaulted on in #301 → legacy
/// per-terminal Ghostty path removed in #303): all terminals share a single
/// embedded Ghostty surface that's attached to a tmux session, and each
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
    /// custom decoder maps legacy `"ghostty"` rows forward.
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
        // anything that isn't a known case — including legacy `"ghostty"` rows
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
