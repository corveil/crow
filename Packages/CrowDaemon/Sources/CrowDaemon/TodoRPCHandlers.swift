import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import CrowProvider
import Foundation

/// Scratch list (CROW-1231). Mutations go through the injected `JSONStore`
/// via `TodoRepository` — never a throwaway store.
func makeTodoHandlers(
    appState: AppState,
    store: JSONStore,
    sessionService: SessionService?,
    devRoot: String
) -> [String: CommandRouter.Handler] {
    let repo = TodoRepository(store: store)
    let handlers: [String: CommandRouter.Handler] = [
        "todo-list": { params in
            try await mapRPCError {
                let items = try TodoRPC.filtered(repo.all(), params: params)
                return ["todos": .array(items.map { TodoRPC.todoJSON($0) })]
            }
        },
        "todo-get": { params in
            try await mapRPCError {
                let item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
                return ["todo": TodoRPC.todoJSON(item)]
            }
        },
        "todo-add": { params in
            try await mapRPCError {
                let item = TodoItem(
                    text: try TodoRPC.decodeText(params["text"]),
                    note: TodoRPC.decodeNote(params["note"]),
                    tags: try TodoRPC.decodeTags(params["tags"]),
                    priority: try TodoRPC.decodePriority(params["priority"])
                )
                repo.save(item)
                return ["todo": TodoRPC.todoJSON(item)]
            }
        },
        "todo-edit": { params in
            try await mapRPCError {
                var item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
                item = try TodoRPC.applyingEdit(item, params: params)
                repo.save(item)
                return ["todo": TodoRPC.todoJSON(item)]
            }
        },
        "todo-delete": { params in
            try await mapRPCError {
                let id = try TodoRPC.decodeID(params)
                _ = try requireTodo(id: id, repo: repo)
                _ = repo.delete(id: id)
                return ["deleted": .bool(true), "todo_id": .string(id.uuidString)]
            }
        },
        "todo-done": { params in
            try await mapRPCError { try setTodoState(.done, params: params, repo: repo) }
        },
        "todo-reopen": { params in
            try await mapRPCError { try setTodoState(.captured, params: params, repo: repo) }
        },
        "todo-park": { params in
            try await mapRPCError { try setTodoState(.parked, params: params, repo: repo) }
        },
        "todo-drop": { params in
            try await mapRPCError { try setTodoState(.dropped, params: params, repo: repo) }
        },
        "todo-link": { params in
            try await mapRPCError {
                var item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
                let type = try TodoRPC.decodeLinkType(params["type"])
                let url = params["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let nonemptyURL = (url?.isEmpty == false) ? url : nil
                let sessionID = params["session_id"]?.stringValue.flatMap(UUID.init)
                    ?? nonemptyURL.flatMap(UUID.init)
                let label = params["label"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let link: TodoLink
                switch type {
                case .session:
                    guard let sessionID else {
                        throw RPCError.invalidParams(
                            "session links need --session (a session UUID) or --url set to a session UUID")
                    }
                    link = TodoLink(
                        type: .session,
                        url: nonemptyURL,
                        sessionID: sessionID,
                        label: (label?.isEmpty == false) ? label! : "session")
                case .ticket, .pr, .custom:
                    guard let nonemptyURL else {
                        throw RPCError.invalidParams("url is required for type \(type.rawValue)")
                    }
                    if type != .custom, !isSafeIssueURL(nonemptyURL) {
                        throw RPCError.invalidParams(
                            "url must be a well-formed http(s) URL with no control characters")
                    }
                    link = TodoLink(
                        type: type,
                        url: nonemptyURL,
                        label: (label?.isEmpty == false) ? label! : type.rawValue)
                }
                item.links.append(link)
                item.updatedAt = Date()
                repo.save(item)
                return ["todo": TodoRPC.todoJSON(item)]
            }
        },
        "todo-explore": { params in
            try await mapRPCError {
                try await exploreTodo(
                    params: params, repo: repo, appState: appState,
                    sessionService: sessionService, devRoot: devRoot)
            }
        },
        "todo-ticket": { params in
            try await mapRPCError {
                try await fileTicket(params: params, repo: repo, devRoot: devRoot)
            }
        },
        "todo-work": { params in
            try await mapRPCError {
                try await workTodo(
                    params: params, repo: repo, appState: appState,
                    sessionService: sessionService)
            }
        },
        "todo-talk": { params in
            try await mapRPCError {
                try await talkTodo(params: params, repo: repo, appState: appState)
            }
        },
    ]
    return handlers
}

private func requireTodo(id: UUID, repo: TodoRepository) throws -> TodoItem {
    guard let item = repo.find(id: id) else {
        throw RPCError.applicationError("Todo not found")
    }
    return item
}

private func setTodoState(
    _ state: TodoState, params: [String: JSONValue], repo: TodoRepository
) throws -> [String: JSONValue] {
    var item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
    item.state = state
    item.updatedAt = Date()
    repo.save(item)
    return ["todo": TodoRPC.todoJSON(item)]
}

private func exploreTodo(
    params: [String: JSONValue],
    repo: TodoRepository,
    appState: AppState,
    sessionService: SessionService?,
    devRoot: String
) async throws -> [String: JSONValue] {
    guard let sessionService else {
        throw RPCError.applicationError("Exploring a todo requires tmux on the daemon host")
    }
    var item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
    let requestedAgentKind = params["agent_kind"]?.stringValue
        .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }

    if let existing = item.linkedSessionID {
        let alive = await MainActor.run {
            appState.sessions.contains { $0.id == existing && $0.kind == .manager }
        }
        if alive {
            let seeded = await sendToManager(
                sessionID: existing, text: TodoRPC.exploreBrief(for: item),
                appState: appState, waitForAgent: false)
            if item.state != .exploring {
                item.state = .exploring
                item.updatedAt = Date()
                repo.save(item)
            }
            var result: [String: JSONValue] = [
                "todo": TodoRPC.todoJSON(item),
                "session_id": .string(existing.uuidString),
                "seeded": .bool(seeded),
            ]
            if !seeded {
                result["warning"] = .string(
                    "Manager is still starting — use `crow todo talk` once it is ready")
            }
            return result
        }
    }

    let brief = TodoRPC.exploreBrief(for: item)
    let (sessionID, name) = await MainActor.run { () -> (UUID, String) in
        // Name the session after the item at create time. A follow-up
        // `renameSession` would paste `/rename` into the pane before the
        // agent TUI owns stdin and offset/eat the explore brief (CROW-1237).
        let display = TodoRPC.managerName(from: item.text)
        let id = sessionService.createManagerSession(
            name: display, cwd: devRoot, agentKind: requestedAgentKind,
            initialPrompt: brief)
        return (id, display)
    }

    let seeded = await sendToManager(
        sessionID: sessionID, text: brief,
        appState: appState, waitForAgent: true)
    item.links.append(TodoLink(type: .session, sessionID: sessionID, label: name))
    item.state = .exploring
    item.updatedAt = Date()
    repo.save(item)

    var result: [String: JSONValue] = [
        "todo": TodoRPC.todoJSON(item),
        "session_id": .string(sessionID.uuidString),
        "name": .string(name),
        "seeded": .bool(seeded),
    ]
    if !seeded {
        result["warning"] = .string(
            "Manager is still starting — use `crow todo talk` once it is ready")
    }
    return result
}

/// Wait for the Manager pane (and, on a fresh launch, for the agent to
/// announce via SessionStart or to own the pane), then deliver `text`.
///
/// Fresh Explore Managers seed the brief as argv on launch (job-style,
/// CROW-1237) so this returns without pasting when UserPromptSubmit /
/// `.working` already prove the agent started. Paste is the fallback for
/// Talk, re-Explore, and harnesses that ignore a positional prompt.
///
/// After a paste: wait for acceptance, retry a bare Enter if the agent
/// stayed idle ("words in the box"), then re-paste the full brief if
/// Enter was not enough (paste eaten/offset). `seeded`/`sent` still mean
/// "we delivered to a live pane" when no acceptance hook arrives.
private func sendToManager(
    sessionID: UUID,
    text: String,
    appState: AppState,
    waitForAgent: Bool
) async -> Bool {
    var terminal: SessionTerminal?
    for _ in 0..<TodoRPC.managerTerminalPolls {
        terminal = await MainActor.run { appState.terminals[sessionID]?.first }
        if terminal != nil { break }
        try? await Task.sleep(nanoseconds: TodoRPC.managerTerminalPollNanos)
    }
    guard let terminal else { return false }

    func hookEventNames() async -> [String] {
        await MainActor.run {
            appState.hookState(for: sessionID).hookEvents.map(\.eventName)
        }
    }
    func activity() async -> AgentActivityState {
        await MainActor.run {
            appState.hookState(for: sessionID).activityState
        }
    }
    func promptAccepted() async -> Bool {
        TodoRPC.promptWasAccepted(
            hookEventNames: await hookEventNames(), activity: await activity())
    }
    func paneCommand() async -> String? {
        await MainActor.run { TerminalRouter.paneCurrentCommand(terminal) }
    }

    var announced = TodoRPC.agentHasAnnounced(hookEventNames: await hookEventNames())
    var agentInPane = TodoRPC.paneLooksLikeAgent(await paneCommand() ?? "")
    let alreadyAnnounced = announced
    if !announced && !agentInPane {
        let polls = waitForAgent
            ? TodoRPC.agentAnnouncePolls
            : TodoRPC.existingAgentAnnouncePolls
        for _ in 0..<polls {
            announced = TodoRPC.agentHasAnnounced(hookEventNames: await hookEventNames())
            agentInPane = TodoRPC.paneLooksLikeAgent(await paneCommand() ?? "")
            if announced || agentInPane { break }
            try? await Task.sleep(nanoseconds: TodoRPC.agentAnnouncePollNanos)
        }
    }
    let composerReady = announced || agentInPane
    try? await Task.sleep(nanoseconds: alreadyAnnounced
        ? TodoRPC.alreadyUpSettleNanos
        : TodoRPC.composerSettleNanos)

    // Seed-at-launch already running — don't paste a second copy.
    if await promptAccepted() { return true }
    if waitForAgent && composerReady {
        for _ in 0..<4 {
            if await promptAccepted() { return true }
            try? await Task.sleep(nanoseconds: TodoRPC.agentAnnouncePollNanos)
        }
        if await promptAccepted() { return true }
    }

    var payload = text
    if !payload.hasSuffix("\n") { payload += "\n" }
    await MainActor.run {
        TerminalRouter.send(terminal, text: payload)
    }

    try? await Task.sleep(nanoseconds: TodoRPC.submitConfirmNanos)
    if await promptAccepted() { return true }
    if TodoRPC.shouldRetryEnter(
        activity: await activity(),
        agentAnnounced: composerReady,
        promptAccepted: false
    ) {
        await MainActor.run {
            TerminalRouter.send(terminal, text: "\n")
        }
        try? await Task.sleep(nanoseconds: TodoRPC.submitConfirmNanos)
        if await promptAccepted() { return true }
        // Paste was eaten or offset — Enter on leftover composer text is
        // not enough. Re-send the whole brief (CROW-1237).
        if TodoRPC.shouldRetryEnter(
            activity: await activity(),
            agentAnnounced: composerReady,
            promptAccepted: false
        ) {
            await MainActor.run {
                TerminalRouter.send(terminal, text: payload)
            }
        }
    }
    return true
}

private func fileTicket(
    params: [String: JSONValue],
    repo: TodoRepository,
    devRoot: String
) async throws -> [String: JSONValue] {
    var item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
    if let existing = item.linkedTicketURL {
        throw RPCError.applicationError(
            "This item already has a ticket (\(existing)). Use `crow todo work` to start a session.")
    }
    guard let workspaceRef = params["workspace"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !workspaceRef.isEmpty else {
        throw RPCError.invalidParams("workspace is required")
    }
    let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
    let index = try WorkspaceRPC.resolveIndex(workspaceRef, in: config)
    let workspace = config.workspaces[index]
    let provider = Provider(rawValue: workspace.derivedTaskProvider) ?? .github
    let requestedRepo = params["repo"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let repoSlug: String
    if let requestedRepo, !requestedRepo.isEmpty {
        repoSlug = requestedRepo
    } else if provider == .jira, let key = workspace.jiraProjectKey, !key.isEmpty {
        repoSlug = key
    } else {
        let concrete = (workspace.alwaysInclude + workspace.autoReviewRepos)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("*") }
        guard concrete.count == 1, let only = concrete.first else {
            throw RPCError.invalidParams(
                "repo is required (workspace '\(workspace.name)' does not have exactly one always-include repo)")
        }
        repoSlug = only
    }

    let backend = ProviderManager().taskBackend(
        for: provider,
        host: workspace.host,
        jira: JiraConfig(
            site: workspace.jiraSite,
            projectKey: workspace.jiraProjectKey,
            jql: workspace.jiraJQL,
            statusMap: workspace.jiraStatusMap)
    )
    // Crow tags stay in the body. Passing them as GitHub/GitLab labels would
    // fail the create when the label does not already exist on the repo.
    let info = try await backend.createTask(
        repo: repoSlug,
        title: item.text,
        body: TodoRPC.ticketBody(for: item),
        labels: []
    )
    item.links.append(TodoLink(
        type: .ticket,
        url: info.url,
        label: "#\(info.number)"))
    item.state = .ticketed
    item.updatedAt = Date()
    repo.save(item)
    return [
        "todo": TodoRPC.todoJSON(item),
        "ticket_url": .string(info.url),
        "ticket_number": .int(info.number),
    ]
}

private func workTodo(
    params: [String: JSONValue],
    repo: TodoRepository,
    appState: AppState,
    sessionService: SessionService?
) async throws -> [String: JSONValue] {
    var item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
    guard let url = item.linkedTicketURL else {
        throw RPCError.applicationError("File a ticket first (`crow todo ticket`)")
    }
    guard sessionService != nil else {
        throw RPCError.applicationError("Working a todo requires tmux on the daemon host")
    }
    guard isSafeIssueURL(url) else {
        throw RPCError.invalidParams("linked ticket url is not a well-formed http(s) URL")
    }
    try await MainActor.run {
        guard let managerTerminal = appState.terminals[AppState.managerSessionID]?.first else {
            throw DaemonRPCError.applicationError("The Manager is still starting — try again in a moment")
        }
        TerminalRouter.send(managerTerminal, text: workspaceLaunchCommand(urls: [url], explore: false))
    }
    item.state = .working
    item.updatedAt = Date()
    repo.save(item)
    return ["todo": TodoRPC.todoJSON(item), "ok": .bool(true)]
}

private func talkTodo(
    params: [String: JSONValue],
    repo: TodoRepository,
    appState: AppState
) async throws -> [String: JSONValue] {
    let item = try requireTodo(id: try TodoRPC.decodeID(params), repo: repo)
    guard let sessionID = item.linkedSessionID else {
        throw RPCError.applicationError("Explore this item first (`crow todo explore`)")
    }
    guard let text = params["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw RPCError.invalidParams("text is required")
    }
    let sent = await sendToManager(
        sessionID: sessionID, text: text, appState: appState, waitForAgent: false)
    guard sent else {
        throw RPCError.applicationError("The linked Manager has no terminal")
    }
    return ["todo": TodoRPC.todoJSON(item), "sent": .bool(true), "session_id": .string(sessionID.uuidString)]
}
