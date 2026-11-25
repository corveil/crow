import CrowCore
import CrowEngine
import CrowIPC
import Foundation

/// THROWAWAY SPIKE (CROW-1524, ADR 0033): Web Chat on the Claude Agent SDK.
///
/// - `get-sdk-chat-events` — whether the spike is on, and one session's SDK events
///   after a cursor. Without `session_id` it answers only `{enabled}`.
/// - `sdk-chat-input` — `op`: `message` (starts the sidecar if needed),
///   `respond` (a tool approval or question answer), `interrupt`, `stop`.
///
/// Both are always registered so the parity ledger doesn't depend on an env
/// var; with the spike off, `get-sdk-chat-events` says `enabled: false` and
/// `sdk-chat-input` refuses.
func makeAgentSDKSpikeHandlers(
    appState: AppState,
    spike: AgentSDKSpike?
) -> [String: CommandRouter.Handler] {
    [
        "get-sdk-chat-events": { params in
            try await mapRPCError {
                guard let spike, await spike.enabled else { return ["enabled": .bool(false)] }
                guard let raw = params["session_id"]?.stringValue else { return ["enabled": .bool(true)] }
                guard let id = UUID(uuidString: raw) else { throw DaemonRPCError.invalidParams("session_id must be a UUID") }
                let page = await spike.page(session: id, after: params["cursor"]?.intValue)
                return [
                    "enabled": .bool(true),
                    "session_id": .string(raw),
                    "events": .array(page.events),
                    "cursor": .int(page.cursor),
                    "running": .bool(page.running),
                    "reset": .bool(page.reset),
                    "pending": .array(page.pending.map { .string($0) }),
                    "sdk_session_id": page.sdkSessionID.map { .string($0) } ?? .null,
                ]
            }
        },
        "sdk-chat-input": { params in
            try await mapRPCError {
                guard let spike, await spike.enabled else {
                    throw DaemonRPCError.applicationError(
                        "The Agent SDK spike is off (start crowd with \(AgentSDKSpikeConfig.envKey)).")
                }
                guard let raw = params["session_id"]?.stringValue, let id = UUID(uuidString: raw) else {
                    throw DaemonRPCError.invalidParams("session_id required")
                }
                let cwd = try await MainActor.run { try AgentSDKSpikeRPC.cwd(appState: appState, session: id) }
                do {
                    try await spike.input(session: id, cwd: cwd, command: params)
                } catch let error as AgentSDKSpikeError {
                    switch error {
                    case .badCommand(let why): throw DaemonRPCError.invalidParams(why)
                    default: throw DaemonRPCError.applicationError(error.localizedDescription)
                    }
                }
                return ["ok": .bool(true)]
            }
        },
    ]
}

enum AgentSDKSpikeRPC {
    /// Where the SDK runs: the agent terminal's directory, else the primary
    /// worktree — the same place the terminal agent runs.
    @MainActor
    static func cwd(appState: AppState, session id: UUID) throws -> String {
        guard let s = appState.sessions.first(where: { $0.id == id }) else {
            throw DaemonRPCError.applicationError("Session not found")
        }
        guard s.agentKind == .claudeCode else {
            throw DaemonRPCError.applicationError("The Agent SDK spike runs Claude sessions only.")
        }
        // A review clone's `.claude/` is the PR author's, and the SDK would load it.
        guard s.kind != .review else {
            throw DaemonRPCError.applicationError("The Agent SDK spike doesn't run in review sessions.")
        }
        let terms = appState.terminals(for: id)
        let agentTerm = terms.first(where: { $0.isManaged }) ?? terms.first
        let cwd = agentTerm?.cwd ?? appState.primaryWorktree(for: id)?.worktreePath ?? ""
        guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else {
            throw DaemonRPCError.applicationError("This session has no working directory.")
        }
        return cwd
    }
}
