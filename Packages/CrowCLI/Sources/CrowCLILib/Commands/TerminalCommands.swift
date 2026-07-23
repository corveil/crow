import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Terminal Commands

/// Create a new terminal tab in a session.
public struct NewTerminal: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "new-terminal", abstract: "Create a terminal in a session")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Working directory") var cwd: String
    @Option(name: .long, help: "Terminal name") var name: String?
    @Option(name: .long, help: "Command to run") var command: String?
    @Flag(name: .long, help: "Mark as managed Claude Code terminal") var managed: Bool = false

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        var params: [String: JSONValue] = [
            "session_id": .string(session),
            "cwd": .string(cwd),
        ]
        if let name { params["name"] = .string(name) }
        if let command { params["command"] = .string(command) }
        if managed { params["managed"] = .bool(true) }
        let result = try rpc("new-terminal", params: params)
        printJSON(result)
    }
}

/// List terminal tabs for a session.
public struct ListTerminals: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "list-terminals", abstract: "List terminals for a session")
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("list-terminals", params: ["session_id": .string(session)])
        printJSON(result)
    }
}

/// Close a terminal tab in a session.
public struct CloseTerminal: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "close-terminal", abstract: "Close a terminal tab in a session")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Terminal UUID") var terminal: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateUUID(terminal, label: "terminal UUID")
    }

    public func run() throws {
        let result = try rpc("close-terminal", params: [
            "session_id": .string(session),
            "terminal_id": .string(terminal),
        ])
        printJSON(result)
    }
}

/// Recreate a terminal whose tmux window has degraded scrollback (CROW-804).
/// Kills the stale window and rebuilds a fresh, correctly-configured one,
/// relaunching the agent (`claude --continue`). Destructive to the running
/// agent — the web UI confirms first; from the CLI the caller owns that choice.
public struct RecreateTerminal: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "recreate-terminal", abstract: "Recreate a terminal to restore full scrollback (CROW-804)")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Terminal UUID") var terminal: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateUUID(terminal, label: "terminal UUID")
    }

    public func run() throws {
        let result = try rpc("recreate-terminal", params: [
            "session_id": .string(session),
            "terminal_id": .string(terminal),
        ])
        printJSON(result)
    }
}

/// Rename a terminal tab.
public struct RenameTerminal: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "rename-terminal", abstract: "Rename a terminal tab")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Terminal UUID") var terminal: String
    @Argument(help: "New name") var name: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateUUID(terminal, label: "terminal UUID")
    }

    public func run() throws {
        let result = try rpc("rename-terminal", params: [
            "session_id": .string(session),
            "terminal_id": .string(terminal),
            "name": .string(name),
        ])
        printJSON(result)
    }
}

/// Send text to a terminal tab.
public struct Send: ParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "send", abstract: "Send text to a terminal")
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Terminal UUID") var terminal: String
    @Argument(help: "Text to send") var text: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateUUID(terminal, label: "terminal UUID")
    }

    public func run() throws {
        let result = try rpc("send", params: [
            "session_id": .string(session),
            "terminal_id": .string(terminal),
            "text": .string(text),
        ])
        printJSON(result)
    }
}
