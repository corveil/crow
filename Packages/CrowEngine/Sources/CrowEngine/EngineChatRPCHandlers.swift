import CrowCore
import CrowIPC
import Foundation

/// The web Chat view's RPCs:
///
/// - `get-session-transcript` — the session's agent transcript reduced to chat
///   events (`ChatTranscript`), tailed by byte cursor, plus context usage.
/// - `list-chat-commands` — the composer's `/` menu (`ChatCommandCatalog`).
///
/// Both are read-only: the agent keeps running in tmux and input still goes
/// through `send`.
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
            let ctx = try await MainActor.run { try chatContext(capturedAppState, id) }
            var base: [String: JSONValue] = [
                "session_id": .string(idStr),
                "agent_kind": .string(ctx.kind.rawValue),
                "terminal_id": ctx.terminalID.map { .string($0.uuidString) } ?? .null,
            ]
            // File I/O stays off the MainActor (#892).
            guard let source = HarnessTranscriptLocator.chatSource(
                kind: ctx.kind, conversationID: ctx.conversationID, cwd: ctx.cwd) else {
                let known = ctx.kind == .claudeCode || ctx.kind == .codex
                base["supported"] = .bool(known)
                base["events"] = .array([])
                base["reason"] = .string(known
                    ? "No transcript found yet for this session."
                    : "Chat view is not supported for \(ctx.kind.rawValue) yet.")
                return base
            }
            // A different file than the client was tailing (`/clear`, a resume
            // that forked the conversation): start over.
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
            base["usage"] = usageJSON(page.usage) ?? .null
            return base
        },

        "list-chat-commands": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            let ctx = try await MainActor.run { try chatContext(capturedAppState, id) }
            // Claude Code only for now: other harnesses expand slash input differently.
            guard ctx.kind == .claudeCode else {
                return ["supported": .bool(false), "commands": .array([])]
            }
            // A review worktree's `.claude/` is the PR author's: list only the
            // operator's own skills and commands there (defense in depth — a
            // pick only inserts `/name `, which still has to be sent).
            let projectDir = (ctx.cwd.isEmpty || ctx.sessionKind == .review) ? nil : ctx.cwd
            // Directory walks stay off the MainActor (#892).
            let cmds = ChatCommandCatalog.discover(.live(projectDir: projectDir))
            return [
                "supported": .bool(true),
                "commands": .array(cmds.map { c in
                    .object([
                        "name": .string(c.name),
                        "description": .string(c.description),
                        "kind": .string(c.kind.rawValue),
                        "scope": .string(c.scope.rawValue),
                    ])
                }),
            ]
        },
    ]
    return handlers
}

private struct ChatContext {
    var kind: AgentKind
    var conversationID: String?
    var cwd: String
    var terminalID: UUID?
    var sessionKind: SessionKind
}

@MainActor
private func chatContext(_ appState: AppState, _ id: UUID) throws -> ChatContext {
    guard let s = appState.sessions.first(where: { $0.id == id }) else {
        throw RPCError.applicationError("Session not found")
    }
    let terms = appState.terminals(for: id)
    let agentTerm = terms.first(where: { $0.isManaged }) ?? terms.first
    let cwd = agentTerm?.cwd ?? appState.primaryWorktree(for: id)?.worktreePath ?? ""
    return ChatContext(kind: s.agentKind, conversationID: s.harnessConversationID, cwd: cwd, terminalID: agentTerm?.id,
                       sessionKind: s.kind)
}

/// The context meter's numbers: the transcript's latest call, with the window
/// from the transcript itself (Codex) or the model table. Nil when this page
/// saw no usage — the client keeps showing its previous value.
func usageJSON(_ page: ChatUsage?) -> JSONValue? {
    guard let page else { return nil }
    var o: [String: JSONValue] = [
        "used_tokens": .int(page.usedTokens),
        "model": page.model.map { .string($0) } ?? .null,
    ]
    if let w = page.maxTokens {
        o["max_tokens"] = .int(w)
        o["max_source"] = .string("transcript")
    } else if let w = ChatContextWindow.maxTokens(model: page.model) {
        o["max_tokens"] = .int(w)
        o["max_source"] = .string("model_table")
    } else {
        o["max_tokens"] = .null
    }
    return .object(o)
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
