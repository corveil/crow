import CrowCore
import CrowIPC
import Foundation

/// The web Chat view's RPCs:
///
/// - `get-session-transcript` — the session's agent transcript reduced to chat
///   events (`ChatTranscript`), tailed by byte cursor, plus context usage.
/// - `list-chat-commands` — the composer's `/` menu (`ChatCommandCatalog`).
/// - `chat-driver-*` — the EXPERIMENTAL headless Claude driver
///   (`ClaudeStreamDriver`), refused unless crowd runs with `CROW_CHAT_DRIVER=1`.
///
/// The transcript read is read-only: a tmux agent keeps running and input still
/// goes through `send`.
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
            let driver = await MainActor.run { ChatDriverRegistry.shared.driver(for: id) }
            var base: [String: JSONValue] = [
                "session_id": .string(idStr),
                "agent_kind": .string(ctx.kind.rawValue),
                "terminal_id": ctx.terminalID.map { .string($0.uuidString) } ?? .null,
                "driver_enabled": .bool(ChatDriverRegistry.enabled && ctx.kind == .claudeCode
                    && ctx.sessionKind != .review),
                "driver": driver.map(driverJSON) ?? .null,
            ]
            // A driven session's conversation is the driver's, not the TUI's.
            let conversationID = driver?.conversationID ?? ctx.conversationID
            // File I/O stays off the MainActor (#892).
            guard let source = HarnessTranscriptLocator.chatSource(
                kind: ctx.kind, conversationID: conversationID, cwd: ctx.cwd) else {
                let known = ctx.kind == .claudeCode || ctx.kind == .codex
                base["supported"] = .bool(known)
                base["events"] = .array([])
                base["reason"] = .string(known
                    ? "No transcript found yet for this session."
                    : "Chat view is not supported for \(ctx.kind.rawValue) yet.")
                return base
            }
            // A different file than the client was tailing (`/clear`, a resume
            // that forked the conversation, a driver taking over): start over.
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
            base["usage"] = usageJSON(page.usage, driver: driver?.usage) ?? .null
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

        "chat-driver-start": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            return try await MainActor.run {
                let ctx = try chatContext(capturedAppState, id)
                // Session gates run before the feature flag, so they hold (and
                // are testable) whether or not the flag is on.
                // `claude -p` skips the workspace-trust dialog, and a review
                // clone's `.claude/` is the PR author's: never drive one headless.
                guard ctx.sessionKind != .review else {
                    throw RPCError.applicationError("Chat driver is not available for review sessions")
                }
                guard ctx.kind == .claudeCode else {
                    throw RPCError.applicationError("Chat driver supports Claude Code only")
                }
                guard ChatDriverRegistry.enabled else {
                    throw RPCError.applicationError("Chat driver is off (start crowd with CROW_CHAT_DRIVER=1)")
                }
                let driver = try ChatDriverRegistry.shared.start(
                    sessionID: id, cwd: ctx.cwd, appState: capturedAppState)
                return ["started": .bool(true), "log_path": .string(driver.logURL.path)]
            }
        },

        "chat-driver-send": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                  let text = params["text"]?.stringValue, !text.isEmpty else {
                throw RPCError.invalidParams("session_id and text required")
            }
            guard let driver = await MainActor.run(body: { ChatDriverRegistry.shared.driver(for: id) }) else {
                throw RPCError.applicationError("No chat driver running for this session")
            }
            try driver.sendUser(text)
            return ["sent": .bool(true)]
        },

        "chat-driver-permission": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                  let requestID = params["request_id"]?.stringValue,
                  let allow = params["allow"]?.boolValue else {
                throw RPCError.invalidParams("session_id, request_id and allow required")
            }
            guard let driver = await MainActor.run(body: { ChatDriverRegistry.shared.driver(for: id) }) else {
                throw RPCError.applicationError("No chat driver running for this session")
            }
            try driver.respondPermission(requestID: requestID, allow: allow)
            return ["ok": .bool(true)]
        },

        "chat-driver-stop": { @Sendable params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw RPCError.invalidParams("session_id required")
            }
            let stopped = await MainActor.run {
                ChatDriverRegistry.shared.stop(sessionID: id, appState: capturedAppState)
            }
            return ["stopped": .bool(stopped)]
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

private func driverJSON(_ d: ClaudeStreamDriver) -> JSONValue {
    .object([
        "running": .bool(d.isRunning),
        "conversation_id": d.conversationID.map { .string($0) } ?? .null,
        "pending": .array(d.pendingPermissions.map { p in
            .object([
                "request_id": .string(p.requestID),
                "tool_name": .string(p.toolName),
                "summary": .string(p.summary),
            ])
        }),
    ])
}

/// The context meter's numbers. The driver's live `result` data wins when a
/// driver runs; otherwise the transcript's latest call plus the model table.
/// Nil when this page saw no usage and no driver has reported any — the client
/// keeps showing its previous value.
func usageJSON(_ page: ChatUsage?, driver: ClaudeStreamDriver.Usage?) -> JSONValue? {
    let used = driver?.usedTokens ?? page?.usedTokens
    guard let used else { return nil }
    let model = driver?.model ?? page?.model
    var o: [String: JSONValue] = [
        "used_tokens": .int(used),
        "model": model.map { .string($0) } ?? .null,
    ]
    if let w = driver?.contextWindow {
        o["max_tokens"] = .int(w)
        o["max_source"] = .string("driver")
    } else if let w = page?.maxTokens {
        o["max_tokens"] = .int(w)
        o["max_source"] = .string("transcript")
    } else if let w = ChatContextWindow.maxTokens(model: model) {
        o["max_tokens"] = .int(w)
        o["max_source"] = .string("model_table")
    } else {
        o["max_tokens"] = .null
    }
    if let cost = driver?.costUSD { o["cost_usd"] = .double(cost) }
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

/// EXPERIMENTAL: one `ClaudeStreamDriver` per session, daemon-lifetime only (not
/// persisted — a crowd restart drops the process; the conversation survives on
/// disk and could be `--resume`d).
@MainActor
final class ChatDriverRegistry {
    static let shared = ChatDriverRegistry()
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["CROW_CHAT_DRIVER"] == "1"
    }

    private var drivers: [UUID: ClaudeStreamDriver] = [:]

    func driver(for sessionID: UUID) -> ClaudeStreamDriver? { drivers[sessionID] }

    /// `command` overrides the `claude -p` argv (tests run a fake child).
    func start(
        sessionID: UUID, cwd: String, appState: AppState,
        command: (executable: String, arguments: [String])? = nil
    ) throws -> ClaudeStreamDriver {
        if let existing = drivers[sessionID], existing.isRunning { return existing }
        let (exe, args) = command ?? {
            let claude = AgentRegistry.shared.agent(for: .claudeCode)?.launchBinary() ?? "claude"
            // A fresh conversation, deliberately: resuming the TUI's conversation
            // while that TUI is still live would interleave two writers on one
            // transcript.
            return ClaudeStreamDriver.defaultCommand(claudePath: claude, resumeID: nil)
        }()
        let log = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-chat-driver", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).ndjson")
        // Events carry the driver they came from, so a replaced or stopped
        // driver's late events (its `.exited` above all) never touch the
        // current one.
        let source = WeakDriver()
        let driver = ClaudeStreamDriver(
            sessionID: sessionID, cwd: cwd, logURL: log, executable: exe, arguments: args
        ) { [weak self, weak appState] event in
            Task { @MainActor in
                guard let self, let appState else { return }
                self.apply(event, sessionID: sessionID, from: source.driver, appState: appState)
            }
        }
        source.driver = driver
        drivers[sessionID]?.stop()
        try driver.start()
        drivers[sessionID] = driver
        return driver
    }

    /// Stop and forget the session's driver. Session deletion calls this too,
    /// so no `claude -p` outlives the worktree it runs in.
    @discardableResult
    func stop(sessionID: UUID, appState: AppState? = nil) -> Bool {
        guard let d = drivers.removeValue(forKey: sessionID) else { return false }
        d.stop()
        appState?.hookState(for: sessionID).activityState = .idle
        return true
    }

    /// Driver events → the same `AgentActivityState` the hook path drives, so the
    /// sidebar dot and notifications don't care which transport ran the turn.
    /// Events from anything but the session's current driver are dropped.
    func apply(
        _ event: ClaudeStreamDriver.Event, sessionID: UUID,
        from source: ClaudeStreamDriver?, appState: AppState
    ) {
        guard let source, let current = drivers[sessionID], current === source else { return }
        let state = appState.hookState(for: sessionID)
        switch event {
        case .turnStarted: state.activityState = .working
        case .permissionRequested: state.activityState = .waiting
        case .turnEnded: state.activityState = .done
        case .exited:
            drivers[sessionID] = nil
            state.activityState = .idle
        case .conversationStarted: break
        }
    }
}

/// A weak back-reference from a driver's event closure to the driver itself
/// (the closure is built before the driver exists).
private final class WeakDriver: @unchecked Sendable {
    weak var driver: ClaudeStreamDriver?
}
