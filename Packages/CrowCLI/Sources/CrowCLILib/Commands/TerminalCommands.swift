import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

// MARK: - Terminal Commands

/// Create a new terminal tab in a session.
public struct NewTerminal: ParsableCommand {
    // Not to be confused with `open-terminal`, which opens Terminal.app on the
    // host GUI rather than a tab inside Crow (CROW-818).
    public static let configuration = CommandConfiguration(commandName: "new-terminal", abstract: "Create a terminal tab inside Crow (tmux)")
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

/// Open a managed agent terminal for a session that no longer has one
/// (CROW-1295) and resume the agent the way a recovered terminal does.
public struct RelaunchAgent: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "relaunch-agent",
        abstract: "Relaunch a session's agent into a new terminal (CROW-1295)"
    )
    @Option(name: .long, help: "Session UUID") var session: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
    }

    public func run() throws {
        let result = try rpc("relaunch-agent", params: ["session_id": .string(session)])
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
    public static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send text to a terminal",
        discussion: """
            --wait-ready waits until the session's agent is idle before pasting, and fails \
            on timeout. --wait-ack waits after the paste until the agent picks the text up \
            (agent_state moves to working, or last_prompt_at changes) and reports \
            "accepted"; it exits non-zero with "accepted": false on timeout. Both need \
            --terminal to be the session's agent terminal (agent_terminal_id in get-session). \
            Sending to the agent terminal of a session whose context is large and whose prompt \
            cache has expired (context.large and context.cache_expired in get-session) prints a \
            warning on stderr; the text is still sent and stdout is unchanged.
            """)
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "Terminal UUID") var terminal: String
    @Flag(name: .long, help: "Wait until the agent is idle and ready for input before sending")
    var waitReady: Bool = false
    @Flag(name: .long, help: "After sending, wait until the agent picks the text up and report \"accepted\"")
    var waitAck: Bool = false
    @Option(name: .long, help: "Seconds each wait may take (default 60, max 3600)")
    var timeout: Double = AgentWait.defaultTimeout
    @Argument(help: "Text to send") var text: String

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        try validateUUID(terminal, label: "terminal UUID")
        try AgentWait.validateTimeout(timeout)
    }

    public func run() throws {
        var before: AgentWait.Snapshot?
        if waitReady || waitAck {
            let snap = try AgentWait.fetch(session: session)
            try checkAgentTerminal(snap)
            before = snap
        }
        if waitReady {
            let outcome = try AgentWait.poll(
                timeout: timeout,
                fetch: { try AgentWait.fetch(session: session) },
                done: { $0.agentState == AgentReadinessState.idle.rawValue })
            guard case .reached(let snap) = outcome else {
                throw AgentWait.failure(outcome, waitingFor: "idle and ready for input", timeout: timeout)
            }
            before = snap
        }
        // Read before the send: once the agent starts the turn, the cache is
        // being rebuilt and `context` stops reading cold. Best effort: a
        // failed read never blocks the send, and a slow one waits 5s at most.
        let contextSnap = before ?? (try? rpc(
            "get-session", params: ["session_id": .string(session)], timeoutSeconds: 5
        )).map(AgentWait.Snapshot.init)
        var result = try rpc("send", params: [
            "session_id": .string(session),
            "terminal_id": .string(terminal),
            "text": .string(text),
        ])
        if let contextSnap, let message = ColdCacheWarning.message(for: contextSnap, terminal: terminal) {
            warn(message)
        }
        guard waitAck, let before else {
            printJSON(result)
            return
        }
        let outcome = try AgentWait.poll(
            timeout: timeout,
            fetch: { try AgentWait.fetch(session: session) },
            done: { AgentWait.isAccepted($0, before: before) })
        let accepted: Bool
        let last: AgentWait.Snapshot?
        switch outcome {
        case .reached(let snap): accepted = true; last = snap
        case .exited(let snap), .timedOut(let snap): accepted = false; last = snap
        case .noAgent: accepted = false; last = nil
        }
        result["accepted"] = .bool(accepted)
        result["agent_state"] = last?.agentState.map { .string($0) } ?? .null
        result["last_prompt_at"] = last?.lastPromptAt.map { .string($0) } ?? .null
        printJSON(result)
        if !accepted {
            warn("the agent did not pick the text up within \(AgentWait.formatSeconds(timeout))s"
                 + " (agent_state=\(last?.agentState ?? "null")).")
            throw ExitCode.failure
        }
    }

    /// `--wait-ready` / `--wait-ack` read the session's agent, so they only
    /// mean something when the text goes to that agent's terminal.
    private func checkAgentTerminal(_ snap: AgentWait.Snapshot) throws {
        guard let agentTerminal = snap.agentTerminalID else {
            throw ValidationError("The session has no agent terminal, so --wait-ready / --wait-ack have no agent to wait on.")
        }
        guard agentTerminal.caseInsensitiveCompare(terminal) == .orderedSame else {
            throw ValidationError(
                "--terminal \(terminal) is not the session's agent terminal (\(agentTerminal)). "
                + "--wait-ready / --wait-ack wait on the agent, so send to its terminal.")
        }
    }
}
