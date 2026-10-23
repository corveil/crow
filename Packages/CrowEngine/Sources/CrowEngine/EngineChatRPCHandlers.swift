import CrowCore
import CrowIPC
import Foundation

/// SPIKE (chat view): `get-session-transcript` — the session's agent transcript
/// reduced to chat events (`ChatTranscript`), tailed by byte cursor.
///
/// Read-only. The agent keeps running in tmux; input still goes through `send`.
@MainActor
func makeEngineChatHandlers(appState: AppState) -> [String: CommandRouter.Handler] {
    let capturedAppState = appState
    let handlers: [String: CommandRouter.Handler] = [
        "get-session-transcript": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            let cursorParam = params["cursor"]?.intValue
            let clientPath = params["path"]?.stringValue
            let resolved = try await MainActor.run { () -> (AgentKind, String?, String, UUID?) in
                guard let s = capturedAppState.sessions.first(where: { $0.id == id }) else {
                    throw RPCError.applicationError("Session not found")
                }
                let terms = capturedAppState.terminals(for: id)
                let agentTerm = terms.first(where: { $0.isManaged }) ?? terms.first
                let cwd = agentTerm?.cwd
                    ?? capturedAppState.primaryWorktree(for: id)?.worktreePath
                    ?? ""
                return (s.agentKind, s.harnessConversationID, cwd, agentTerm?.id)
            }
            let (kind, conversationID, cwd, terminalID) = resolved
            var base: [String: JSONValue] = [
                "session_id": .string(idStr),
                "agent_kind": .string(kind.rawValue),
                "terminal_id": terminalID.map { .string($0.uuidString) } ?? .null,
            ]
            // File I/O stays off the MainActor (#892).
            guard let source = HarnessTranscriptLocator.chatSource(
                kind: kind, conversationID: conversationID, cwd: cwd) else {
                base["supported"] = .bool(kind == .claudeCode || kind == .codex)
                base["events"] = .array([])
                base["reason"] = .string(kind == .claudeCode || kind == .codex
                    ? "No transcript found yet for this session."
                    : "Chat view is not supported for \(kind.rawValue) yet.")
                return base
            }
            // A different file than the client was tailing (`/clear`, a resume
            // that forked the conversation): ignore its cursor and start over.
            let reset = clientPath != nil && clientPath != source.path
            let cursor = reset ? nil : cursorParam
            let page = try ChatTranscript.read(path: source.path, format: source.format, cursor: cursor)
            base["supported"] = .bool(true)
            base["path"] = .string(source.path)
            base["format"] = .string(source.format.rawValue)
            base["cursor"] = .int(page.cursor)
            base["truncated"] = .bool(page.truncated)
            base["reset"] = .bool(reset || cursor == nil)
            base["events"] = .array(page.events.map(eventJSON))
            return base
        },
    ]
    return handlers
}

private func eventJSON(_ e: ChatEvent) -> JSONValue {
    var o: [String: JSONValue] = [
        "kind": .string(e.kind.rawValue),
        "text": .string(e.text),
    ]
    if let v = e.toolName { o["tool_name"] = .string(v) }
    if let v = e.toolID { o["tool_id"] = .string(v) }
    if e.isError { o["is_error"] = .bool(true) }
    if let v = e.timestamp { o["ts"] = .string(v) }
    if let v = e.durationMs { o["duration_ms"] = .int(v) }
    return .object(o)
}
