import CrowCore
import CrowIPC
import Foundation

/// The web Chat view's RPCs:
///
/// - `get-session-transcript` — the session's agent transcript reduced to chat
///   events (`ChatTranscript`), tailed by byte cursor, plus context usage.
/// - `list-chat-commands` — the composer's `/` menu (`ChatCommandCatalog`).
///
/// - `answer-question` — the Chat question card's answers to a Claude
///   `AskUserQuestion`, typed into the TUI picker (`AskUserQuestionDriver`).
///
/// The first two are read-only. Input still goes through the terminal: `send`
/// for messages, and `answer-question` only presses keys in the picker that is
/// already waiting (or, as a fallback, dismisses it and sends a message).
@MainActor
func makeEngineChatHandlers(
    appState: AppState, questionIO: AskUserQuestionDriver.IO = .live,
    transcriptRoots: HarnessTranscriptLocator.Roots = .live
) -> [String: CommandRouter.Handler] {
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
                kind: ctx.kind, conversationID: ctx.conversationID, cwd: ctx.cwd, roots: transcriptRoots) else {
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

        "answer-question": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                  let toolID = params["tool_id"]?.stringValue, !toolID.isEmpty,
                  case .array(let rawAnswers)? = params["answers"] else {
                throw RPCError.invalidParams("session_id, tool_id and answers required")
            }
            let answers = try rawAnswers.map(parseQuestionAnswer)
            let ctx = try await MainActor.run { try chatContext(capturedAppState, id) }
            guard ctx.kind == .claudeCode else {
                throw RPCError.applicationError("Only Claude sessions ask questions this way.")
            }
            guard let terminalID = ctx.terminalID else {
                throw RPCError.applicationError("This session has no agent terminal.")
            }
            // The questions come from the transcript, not the client: the keys
            // are planned against what the agent actually asked. File I/O stays
            // off the MainActor (#892).
            guard let source = HarnessTranscriptLocator.chatSource(
                kind: ctx.kind, conversationID: ctx.conversationID, cwd: ctx.cwd, roots: transcriptRoots) else {
                throw RPCError.applicationError("No transcript found for this session.")
            }
            let page = try ChatTranscript.read(path: source.path, format: source.format, cursor: nil)
            if page.events.contains(where: { $0.kind == .toolResult && $0.toolID == toolID }) {
                throw RPCError.applicationError("This question was already answered.")
            }
            guard let call = page.events.last(where: { $0.kind == .toolCall && $0.toolID == toolID }),
                  let questions = call.questions else {
                throw RPCError.applicationError("That question isn't in the session's transcript.")
            }
            if let problem = AskUserQuestionPicker.validate(answers, for: questions) {
                throw RPCError.invalidParams(problem)
            }
            do {
                switch try await AskUserQuestionDriver.answer(
                    terminalID: terminalID, questions: questions, answers: answers, io: questionIO) {
                case .picker:
                    return ["delivered": .string("picker")]
                case .fallback(let reason):
                    return ["delivered": .string("fallback"), "reason": .string(reason)]
                }
            } catch let failure as AskUserQuestionDriver.Failure {
                throw RPCError.applicationError(failure.message)
            }
        },
    ]
    return handlers
}

/// One entry of `answer-question`'s `answers`: `{selected: [Int], other: String?}`.
private func parseQuestionAnswer(_ v: JSONValue) throws -> AskUserQuestionPicker.Answer {
    guard case .object(let o) = v else { throw RPCError.invalidParams("each answer must be an object") }
    var selected: [Int] = []
    if case .array(let items)? = o["selected"] {
        for item in items {
            guard let i = item.intValue else { throw RPCError.invalidParams("selected holds option indices") }
            selected.append(i)
        }
    }
    let other = o["other"]?.stringValue
    if let other, other.count > AskUserQuestionPicker.maxOtherChars * 2 {
        throw RPCError.invalidParams("other is too long")
    }
    return AskUserQuestionPicker.Answer(selected: selected, other: other)
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
    if let qs = e.questions { o["questions"] = .array(qs.map(questionJSON)) }
    if let a = e.answers { o["answers"] = .object(a.mapValues { .string($0) }) }
    return .object(o)
}

private func questionJSON(_ q: ChatQuestion) -> JSONValue {
    .object([
        "question": .string(q.question),
        "header": .string(q.header),
        "multi_select": .bool(q.multiSelect),
        "options": .array(q.options.map { .object(["label": .string($0.label), "description": .string($0.description)]) }),
    ])
}
