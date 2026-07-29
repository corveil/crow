import ArgumentParser
import CrowIPC
import Foundation

// MARK: - Hook Event Command

/// Forward an agent hook event to the running Crow app.
///
/// Reads a JSON payload from stdin (piped by the agent) and forwards it
/// as an RPC call. Silent on success to avoid polluting hook output.
///
/// `--session` is optional: agents whose hook config carries the Crow
/// session UUID (Claude Code) include it; agents whose hook config is
/// global (Codex) omit it, and the server resolves the session by matching
/// the payload's `cwd` against registered worktree paths.
public struct HookEventCmd: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hook-event",
        abstract: "Forward an agent hook event to the app (reads JSON from stdin)"
    )
    @Option(name: .long, help: "Session UUID (omit to resolve from payload cwd)")
    var session: String?
    @Option(name: .long, help: "Event name (e.g., Stop, Notification, PreToolUse)") var event: String
    @Option(name: .long, help: "Agent kind (e.g., claude-code, codex). Defaults to the session's stored agent.")
    var agent: String?

    public init() {}

    public func validate() throws {
        if let session, !session.isEmpty {
            try validateUUID(session, label: "session UUID")
        }
    }

    public func run() throws {
        let payload = parseHookPayload(from: FileHandle.standardInput.readDataToEndOfFile())

        var params: [String: JSONValue] = [
            "event_name": .string(event),
            "payload": .object(payload),
        ]
        if let session, !session.isEmpty {
            params["session_id"] = .string(session)
        }
        if let agent, !agent.isEmpty {
            params["agent_kind"] = .string(agent)
        }

        try forwardHookEvent(params: params)
    }
}

/// Forward a hook-event RPC over the Unix socket, fire-and-forget.
///
/// Hooks are fire-and-forget: we write the event and return without reading the
/// daemon's reply. Because the daemon serializes every request on its
/// `@MainActor`, the old blocking round-trip stalled the hook whenever the
/// daemon was busy (board poll, git op, whole-store write, a burst of
/// hook-events) — right up to the agent's hook timeout (#903). Dropping the read
/// removes that stall; the daemon still processes the event once its MainActor
/// frees.
///
/// The only behavior this drops is error *surfacing*. The old call went through
/// `rpc()`, which throws on a daemon RPC error, so a failed hook-event exited
/// non-zero with a stderr message; the `printJSON(result)` branch it also had
/// was dead, since `rpc()` returns only the success `result`, which never
/// carries an `error` key. Losing that surfacing is a win here: it silences the
/// `session_id required or resolvable from payload cwd` noise that global-hook
/// agents hit (#897) and keeps any error text off the hook's output.
///
/// Silently no-ops when the Crow app is not running (socket connection refused
/// or socket file absent): a missing listener is an expected state, not an
/// error, so we must not exit non-zero or write to stderr (it pollutes the
/// agent's hook output). Other socket errors (create/write failures) still
/// propagate so genuine misbehavior is visible.
func forwardHookEvent(params: [String: JSONValue]) throws {
    do {
        try rpcNotify("hook-event", params: params)
    } catch SocketError.connectionFailed {
        return
    }
}

/// Parse a JSON payload from stdin data for hook events.
///
/// Returns the decoded dictionary, or an empty dictionary if the data is empty or
/// cannot be parsed (with a warning written to stderr).
func parseHookPayload(from data: Data) -> [String: JSONValue] {
    guard !data.isEmpty else { return [:] }
    do {
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    } catch {
        FileHandle.standardError.write(
            "crow: warning: failed to parse stdin JSON: \(error.localizedDescription)\n"
                .data(using: .utf8)!
        )
        return [:]
    }
}
