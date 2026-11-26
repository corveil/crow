import ArgumentParser
import CrowCore
import CrowIPC
import Foundation

// MARK: - Agent readiness waits (CROW-1475)

/// Polling behind `crow wait` and `crow send --wait-ready` / `--wait-ack`.
///
/// The waits run here, in the CLI, by polling `get-session`, not as a
/// long-running RPC. `send` and other session writes are serialized per
/// session (`RPCLanePolicy`), so a daemon-side wait would hold that lane for
/// its whole timeout. The caller still makes one blocking call instead of a
/// sleep loop.
public enum AgentWait {

    /// Seconds between `get-session` polls.
    public static let pollInterval: TimeInterval = 0.25
    /// Default for `--timeout` on `crow wait` and `crow send`.
    public static let defaultTimeout: Double = 60
    /// Longest `--timeout` accepted.
    public static let maxTimeout: Double = 3600

    /// The readiness fields of one `get-session` result.
    public struct Snapshot: Equatable, Sendable {
        public var agentState: String?
        public var lastPromptAt: String?
        public var agentTerminalID: String?
        /// `get-session`'s `context` object (CROW-1493), read by `crow send`'s
        /// cold-cache warning (``ColdCacheWarning``).
        public var context: [String: JSONValue]?

        public init(
            agentState: String?, lastPromptAt: String? = nil, agentTerminalID: String? = nil,
            context: [String: JSONValue]? = nil
        ) {
            self.agentState = agentState
            self.lastPromptAt = lastPromptAt
            self.agentTerminalID = agentTerminalID
            self.context = context
        }

        public init(_ result: [String: JSONValue]) {
            agentState = result["agent_state"]?.stringValue
            lastPromptAt = result["last_prompt_at"]?.stringValue
            agentTerminalID = result["agent_terminal_id"]?.stringValue
            context = result["context"]?.objectValue
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The condition held.
        case reached(Snapshot)
        /// The agent exited before the condition held.
        case exited(Snapshot)
        /// The session has no agent terminal, so there is nothing to wait on.
        case noAgent
        /// The timeout passed. Carries the last snapshot read.
        case timedOut(Snapshot)
    }

    /// Poll `fetch` until `done` holds, the agent exits, or `timeout` passes.
    /// `done` is checked before the exit test, so waiting *for* `exited`
    /// works. The clock and sleep are injected for tests.
    public static func poll(
        timeout: TimeInterval,
        interval: TimeInterval = pollInterval,
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        fetch: () throws -> Snapshot,
        done: (Snapshot) -> Bool
    ) throws -> Outcome {
        let deadline = now().addingTimeInterval(timeout)
        while true {
            let snap = try fetch()
            if done(snap) { return .reached(snap) }
            guard let state = snap.agentState else { return .noAgent }
            if state == AgentReadinessState.exited.rawValue { return .exited(snap) }
            if now() >= deadline { return .timedOut(snap) }
            sleep(max(0, min(interval, deadline.timeIntervalSince(now()))))
        }
    }

    /// Whether the agent picked up text sent when `before` was read: it is
    /// running a turn (or asking permission for one), or it stamped a new
    /// `last_prompt_at` — which also catches a turn that finished between
    /// two polls. When the agent was already busy at `before`, being busy
    /// proves nothing (the text may sit queued in its composer), so only a
    /// new `last_prompt_at` counts.
    public static func isAccepted(_ snap: Snapshot, before: Snapshot) -> Bool {
        if let after = snap.lastPromptAt, after != before.lastPromptAt { return true }
        guard !isBusy(before.agentState) else { return false }
        return isBusy(snap.agentState)
    }

    private static func isBusy(_ state: String?) -> Bool {
        state == AgentReadinessState.working.rawValue
            || state == AgentReadinessState.waitingPermission.rawValue
    }

    /// Fetch one session's readiness fields.
    static func fetch(session: String) throws -> Snapshot {
        Snapshot(try rpc("get-session", params: ["session_id": .string(session)]))
    }

    static func validateTimeout(_ timeout: Double) throws {
        guard timeout > 0, timeout <= maxTimeout else {
            throw ValidationError("--timeout must be greater than 0 and at most \(Int(maxTimeout)) seconds.")
        }
    }

    /// The error for an outcome that isn't `.reached`.
    static func failure(_ outcome: Outcome, waitingFor: String, timeout: Double) -> ValidationError {
        switch outcome {
        case .reached:
            return ValidationError("internal: not a failure")
        case .noAgent:
            return ValidationError("The session has no agent terminal, so there is no agent_state to wait on.")
        case .exited:
            return ValidationError(
                "The agent exited (agent_state=exited) before it was \(waitingFor). "
                + "Relaunch it (crow relaunch-agent / crow launch-agent) and try again.")
        case .timedOut(let snap):
            var message = "Timed out after \(formatSeconds(timeout))s waiting for the agent to be \(waitingFor)"
                + " (last agent_state=\(snap.agentState ?? "null"))."
            if snap.agentState == AgentReadinessState.starting.rawValue {
                message += " It has sent no hook since launch: check its terminal."
            }
            return ValidationError(message)
        }
    }

    static func formatSeconds(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

/// Block until a session's agent reaches a state.
public struct Wait: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait until a session's agent reaches a state (idle, working, ...)",
        discussion: """
            Polls the session's agent_state (see get-session) until it equals --until, \
            then prints the session's readiness fields. Fails when the agent exits first \
            (unless --until exited), when the session has no agent terminal, or on timeout.
            """)
    @Option(name: .long, help: "Session UUID") var session: String
    @Option(name: .long, help: "State to wait for: starting, idle, working, waiting_permission, exited")
    var until: String
    @Option(name: .long, help: "Seconds to wait before failing (default 60, max 3600)")
    var timeout: Double = AgentWait.defaultTimeout

    public init() {}

    public func validate() throws {
        try validateUUID(session, label: "session UUID")
        guard AgentReadinessState(rawValue: until) != nil else {
            throw ValidationError(
                "'\(until)' is not an agent state. Expected one of: "
                + AgentReadinessState.allCases.map(\.rawValue).joined(separator: ", "))
        }
        try AgentWait.validateTimeout(timeout)
    }

    public func run() throws {
        let start = Date()
        let target = until
        let outcome = try AgentWait.poll(
            timeout: timeout,
            fetch: { try AgentWait.fetch(session: session) },
            done: { $0.agentState == target })
        guard case .reached(let snap) = outcome else {
            throw AgentWait.failure(outcome, waitingFor: target, timeout: timeout)
        }
        printJSON([
            "session_id": .string(session),
            "agent_state": snap.agentState.map { .string($0) } ?? .null,
            "last_prompt_at": snap.lastPromptAt.map { .string($0) } ?? .null,
            "agent_terminal_id": snap.agentTerminalID.map { .string($0) } ?? .null,
            "waited_seconds": .double((Date().timeIntervalSince(start) * 100).rounded() / 100),
        ])
    }
}
