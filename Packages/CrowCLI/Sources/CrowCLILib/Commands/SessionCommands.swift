import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Session Commands

/// Create a new development session.
///
/// Returns the new session's UUID and name as JSON. Pass `--kind manager` to
/// create a Manager (orchestration) session with its own Claude Code terminal
/// running in the devRoot.
public struct NewSession: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "new-session", abstract: "Create a new session")
    @Option(name: .long, help: "Session name") var name: String
    @Option(name: .long, help: "Session kind: work (default), review, or manager") var kind: String?

    public init() {}

    public func validate() throws {
        if let kind, !["work", "review", "manager"].contains(kind) {
            throw ValidationError("kind must be one of: work, review, manager")
        }
    }

    public func run() throws {
        var params: [String: JSONValue] = ["name": .string(name)]
        if let kind { params["kind"] = .string(kind) }
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
