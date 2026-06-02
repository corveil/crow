import ArgumentParser
import CrowCodex
import CrowIPC
import Foundation

/// Bridge OpenAI Codex's `notify` command into Crow's hook-event RPC.
///
/// Codex invokes `notify = ["crow", "codex-notify"]` after each turn
/// completion, passing the JSON payload as the final positional argument.
/// We translate that payload into a hook-event RPC with `agent_kind=codex`,
/// letting the server's existing pipeline drive state transitions and
/// notifications. The session is resolved server-side from the `cwd` field
/// in the payload — no `--session` flag is needed (and Codex couldn't
/// supply one anyway, since its config is global).
public struct CodexNotify: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "codex-notify",
        abstract: "Bridge Codex's notify command into Crow's hook-event pipeline"
    )

    @Argument(parsing: .remaining, help: "Codex notify JSON payload (final positional arg)")
    var payloadArg: [String] = []

    public init() {}

    public func run() throws {
        // Codex invokes us as `crow codex-notify <json-payload>`. Fall back
        // to stdin so the command is testable / scriptable manually.
        let json: String = {
            if let last = payloadArg.last, !last.isEmpty { return last }
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }()

        let translation = CodexNotifyPayload.translate(json)

        // Convert the [String: String] payload into the JSON-RPC value shape.
        // (CrowCodex doesn't depend on JSONValue; the boundary lives here.)
        let payload: [String: JSONValue] = translation.payload.reduce(into: [:]) {
            $0[$1.key] = .string($1.value)
        }

        // Use the shared forwarder so a missing Crow app silently no-ops
        // (otherwise we'd pollute Codex's notify output with a stack trace).
        try forwardHookEvent(params: [
            "event_name": .string(translation.eventName),
            "agent_kind": .string("codex"),
            "payload": .object(payload),
        ])
    }
}
