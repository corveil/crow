import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Session Commands

/// Create a new development session.
///
/// Returns the new session's UUID and name as JSON. Pass `--kind manager` to
/// create a Manager (orchestration) session with its own Claude Code terminal
/// running in the devRoot. The supplied name is used verbatim (the caller is
/// responsible for uniqueness — sessions are identified by UUID, not name).
/// Review and job sessions are created through their own setup flows, not here.
public struct NewSession: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "new-session", abstract: "Create a new session")
    @Option(name: .long, help: "Session name") var name: String
    @Option(name: .long, help: "Session kind: work (default) or manager") var kind: String?
    @Option(name: .long, help: "Agent kind (e.g. claude-code). Defaults to the configured default agent.")
    var agent: String?

    public init() {}

    public func validate() throws {
        if let kind, !["work", "manager"].contains(kind) {
            throw ValidationError("kind must be one of: work, manager")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let kind { params["kind"] = .string(kind) }
        if let agent, !agent.isEmpty {
            params["agent_kind"] = .string(agent)
        }
        let result = try rpc("new-session", params: params)
        printJSON(result)
    }
}

/// Rename an existing session.
public struct RenameSession: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "rename-session", abstract: "Rename a session")
    @Option(name: .long, help: "Session UUID") var session: String
    @Argument(help: "New name") var name: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("rename-session", params: ["session_id": .string(session), "name": .string(name)])
        printJSON(result)
    }
}

/// Switch to a session, making it the active selection in the app.
public struct SelectSession: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "select-session", abstract: "Switch to a session")
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("select-session", params: ["session_id": .string(session)])
        printJSON(result)
    }
}

/// List all sessions.
public struct ListSessions: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list-sessions", abstract: "List all sessions")

    public init() {}

    public func run() throws {
        let result = try rpc("list-sessions")
        printJSON(result)
    }
}

/// Get detailed information about a session.
public struct GetSession: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "get-session", abstract: "Get session details")
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("get-session", params: ["session_id": .string(session)])
        printJSON(result)
    }
}

/// Set the status of a session (active, paused, inReview, completed, archived).
public struct SetStatus: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "set-status", abstract: "Set session status")
    @Option(name: .long, help: "Session UUID") var session: String
    @Argument(help: "Status: active, paused, inReview, completed, archived") var status: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateSessionStatus(status)
    }

    public func run() throws {
        let result = try rpc("set-status", params: ["session_id": .string(session), "status": .string(status)])
        printJSON(result)
    }
}

/// Lock or unlock a session, exempting it from (or restoring it to) the
/// retention cleanup reaper.
public struct SetLocked: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "set-locked", abstract: "Lock/unlock a session to protect it from auto-cleanup")
    @Option(name: .long, help: "Session UUID") var session: String
    @Argument(help: "Locked state: true or false") var locked: Bool

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("set-locked", params: ["session_id": .string(session), "locked": .bool(locked)])
        printJSON(result)
    }
}

/// Deprecated alias for `set-locked` (renamed in CROW-573). Hidden from help but
/// still accepted so existing scripts keep working.
public struct SetPinned: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "set-pinned", abstract: "Deprecated alias for set-locked", shouldDisplay: false)
    @Option(name: .long, help: "Session UUID") var session: String
    @Argument(help: "Locked state: true or false") var pinned: Bool

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("set-locked", params: ["session_id": .string(session), "locked": .bool(pinned)])
        printJSON(result)
    }
}

/// Delete a session.
public struct DeleteSession: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "delete-session", abstract: "Delete a session")
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("delete-session", params: ["session_id": .string(session)])
        printJSON(result)
    }
}

/// Hand a session off to a different coding agent mid-flight (CROW-627).
///
/// Preserves session identity, worktree, branch, and ticket context. Tears
/// down the managed agent terminal and launches the target agent with a
/// handoff prompt. Conversation history does not transfer across agents.
public struct HandoffAgent: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "handoff-agent",
        abstract: "Switch a session to a different coding agent (e.g. when credits run out)"
    )
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Target agent kind (claude-code, cursor, codex, opencode)")
    var agent: String
    @Option(name: .long, help: "Optional note for the incoming agent about where to resume")
    var note: String?

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        guard !agent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("agent must be non-empty (claude-code, cursor, codex, or opencode)")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = [
            "session_id": .string(session),
            "agent_kind": .string(agent),
        ]
        if let note, !note.isEmpty {
            params["note"] = .string(note)
        }
        let result = try rpc("handoff-agent", params: params)
        printJSON(result)
    }
}
