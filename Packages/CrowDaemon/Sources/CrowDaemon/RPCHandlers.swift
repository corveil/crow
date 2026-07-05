import CrowCore
import CrowEngine
import CrowGit
import CrowIPC
import CrowPersistence
import CrowTerminal
import Foundation

/// JSON-RPC errors thrown by the daemon's handlers, carrying the right
/// JSON-RPC error code. Mirrors the app's `AppDelegate.RPCError` (which is not
/// reachable from the headless daemon — it lives in the AppKit target).
enum DaemonRPCError: Error, LocalizedError, RPCErrorCoded {
    case invalidParams(String)
    case applicationError(String)

    var rpcErrorCode: Int {
        switch self {
        case .invalidParams: return RPCErrorCode.invalidParams
        case .applicationError: return RPCErrorCode.applicationError
        }
    }

    var errorDescription: String? {
        switch self {
        case let .invalidParams(message), let .applicationError(message):
            return message
        }
    }
}

/// Forward a write RPC to the desktop app's Unix socket (the source of truth),
/// so the app applies the mutation with all its side effects (Jira transitions,
/// notifications) and the daemon never clobbers its state. Throws
/// `DaemonRPCError` on an app-level error; rethrows the underlying socket error
/// (connection refused → app not running) so callers can fall back to local
/// handling (CROW-581).
private func forwardToApp(
    _ method: String, _ params: [String: JSONValue], socket: String
) throws -> [String: JSONValue] {
    let response = try SocketClient(socketPath: socket).send(method: method, params: params)
    if let error = response.error {
        throw DaemonRPCError.applicationError(error.message)
    }
    return response.result ?? [:]
}

/// App-down local path for the `session.status` transitions (mark-in-review /
/// complete-session / set-session-active): write the status to both the
/// observable `appState` and the persisted `store`, exactly like `set-status`.
/// Runs only when the app isn't forwarding, so there's no two-writer divergence
/// (CROW-581, M-E). Must be called on the main actor (`appState` isolation).
@MainActor
private func setSessionStatusLocally(
    id: UUID, to status: SessionStatus, appState: AppState, store: JSONStore
) throws -> [String: JSONValue] {
    guard let idx = appState.sessions.firstIndex(where: { $0.id == id }) else {
        throw DaemonRPCError.applicationError("Session not found")
    }
    let now = Date()
    appState.sessions[idx].status = status
    appState.sessions[idx].updatedAt = now
    store.mutate { data in
        if let i = data.sessions.firstIndex(where: { $0.id == id }) {
            data.sessions[i].status = status
            data.sessions[i].updatedAt = now
        }
    }
    return ["session_id": .string(id.uuidString), "status": .string(status.rawValue)]
}

/// Builds the daemon's `CommandRouter`. Handlers mirror the corresponding
/// closures in the macOS app's `AppDelegate.startSocketServer`, but operate
/// purely on `AppState` + `JSONStore` (+ `GitManager` / the tmux `cockpit`)
/// with no AppKit or `SessionService` dependency, so the same domain logic
/// runs on a headless Linux `crowd` (CROW-581).
///
/// Method set:
/// - M0: `new-session`, `list-sessions`, `add-worktree`.
/// - M2 (web UI): expanded `list-sessions`, plus `list-terminals`,
///   `new-terminal`, `close-terminal` (per-session tmux windows).
///
/// `appState` is `@MainActor`-isolated; each handler hops to the main actor for
/// the in-memory mutation exactly as the app does, keeping the persisted
/// `store` and the observable `appState` in lockstep. `cockpit` is nil when no
/// tmux binary was found — terminal handlers then return an application error.
func makeCommandRouter(
    appState: AppState,
    store: JSONStore,
    git: GitManager,
    devRoot: String,
    cockpit: TerminalCockpit?,
    forwardSocket: String? = nil,
    tracker: IssueTracker? = nil,
    allowList: AllowListService? = nil,
    sessionService: SessionService? = nil
) -> CommandRouter {
    CommandRouter(handlers: [
        "new-session": { params in
            let name = params["name"]?.stringValue ?? "untitled"
            guard Validation.isValidSessionName(name) else {
                throw DaemonRPCError.invalidParams(
                    "Invalid session name (max \(Validation.maxSessionNameLength) chars, no control characters)")
            }
            // The daemon creates only `work` sessions. `manager` sessions need
            // the app's `SessionService` (terminal + agent wiring), which is
            // AppKit-locked and out of scope for M0.
            let kindStr = params["kind"]?.stringValue
            guard kindStr == nil || kindStr == "work" else {
                throw DaemonRPCError.invalidParams(
                    "Only work sessions are supported by the daemon (manager sessions require the desktop app)")
            }
            let requestedAgentKind = params["agent_kind"]?.stringValue
                .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }
            return await MainActor.run {
                let agentKind = requestedAgentKind ?? appState.agentKind(for: .work)
                let session = Session(name: name, kind: .work, agentKind: agentKind)
                appState.sessions.append(session)
                store.mutate { $0.sessions.append(session) }
                return [
                    "session_id": .string(session.id.uuidString),
                    "name": .string(session.name),
                    "agent_kind": .string(session.agentKind.rawValue),
                ]
            }
        },

        // Expanded for the web UI: enough per session to render the sidebar
        // rows and the detail header (status/kind/agent/ticket + primary
        // worktree). PR status, labels, and hook-activity state need RPC the
        // daemon doesn't expose yet and are omitted.
        "list-sessions": { _ in
            let items: [JSONValue] = await MainActor.run {
                appState.sessions.map { session in
                    var object: [String: JSONValue] = [
                        "id": .string(session.id.uuidString),
                        "name": .string(session.name),
                        "status": .string(session.status.rawValue),
                        "kind": .string(session.kind.rawValue),
                        "agent_kind": .string(session.agentKind.rawValue),
                        "agent_display_name": .string(CrowAttribution.agentDisplayName(for: session.agentKind)),
                        "locked": .bool(session.locked),
                        "auto_merge": .bool(session.autoMergeEnabledAt != nil),
                        "ticket_title": session.ticketTitle.map { .string($0) } ?? .null,
                        "ticket_url": session.ticketURL.map { .string($0) } ?? .null,
                        "ticket_badge": session.ticketBadgeLabel.map { .string($0) } ?? .null,
                        "provider": session.provider.map { .string($0.rawValue) } ?? .null,
                    ]
                    if let worktree = appState.primaryWorktree(for: session.id) {
                        object["repo"] = .string(worktree.repoName)
                        object["branch"] = .string(worktree.branch)
                        object["worktree_path"] = .string(worktree.worktreePath)
                    }
                    // Issue/PR/repo links for the detail header (from the store).
                    let links = appState.links(for: session.id)
                    if !links.isEmpty {
                        object["links"] = .array(links.map { link in
                            .object([
                                "label": .string(link.label),
                                "url": .string(link.url),
                                "type": .string(link.linkType.rawValue),
                            ])
                        })
                    }
                    // Hook-driven activity (persisted) → sidebar dot parity.
                    let hook = appState.hookState(for: session.id)
                    object["activity"] = .string(hook.activityState.rawValue)
                    if let notification = hook.pendingNotification {
                        object["attention"] = .string(notification.notificationType)
                    }
                    return .object(object)
                }
            }
            return ["sessions": .array(items)]
        },

        "list-terminals": { params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            let items: [JSONValue] = await MainActor.run {
                appState.terminals(for: sessionID).map { terminal in
                    .object([
                        "id": .string(terminal.id.uuidString),
                        "name": .string(terminal.name),
                        "managed": .bool(terminal.isManaged),
                        "window": terminal.tmuxBinding.map { .int($0.windowIndex) } ?? .null,
                    ])
                }
            }
            return ["terminals": .array(items)]
        },

        // Create a per-session terminal = a tmux window in the shared cockpit.
        // Uses the portable `TmuxController.newWindow` directly (no @MainActor
        // TmuxBackend); readiness/sentinel wiring is app-only and skipped.
        // Terminals are in-memory for M2 (not persisted): a fresh cockpit has
        // no windows on restart, so live-only avoids stale-index bugs.
        "new-terminal": { params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            guard let cockpit else {
                throw DaemonRPCError.applicationError("tmux unavailable; terminals are disabled")
            }
            let managed = params["managed"]?.boolValue ?? false
            let resolved = await MainActor.run { () -> (exists: Bool, cwd: String, agentKind: AgentKind)? in
                guard let session = appState.sessions.first(where: { $0.id == sessionID }) else { return nil }
                let cwd = appState.primaryWorktree(for: sessionID)?.worktreePath ?? devRoot
                return (true, cwd, session.agentKind)
            }
            guard let resolved else { throw DaemonRPCError.applicationError("Session not found") }
            // Resolved cwd comes from a worktree already gated at add-worktree,
            // or devRoot; re-check to stay defensive against tampered stores.
            guard Validation.isPathWithinRoot(resolved.cwd, root: devRoot) else {
                throw DaemonRPCError.invalidParams("resolved terminal cwd is outside devRoot")
            }
            let name = params["name"]?.stringValue
                ?? (managed ? CrowAttribution.agentDisplayName(for: resolved.agentKind) : "Shell")
            // Default to the session's default shell — a guaranteed-live window
            // like the cockpit anchor. Wrapping in crow-shell-wrapper.sh (OSC
            // readiness / agent auto-launch) is opt-in via an explicit command
            // and deferred to a follow-up (it needs sentinel env to stay alive).
            let command = params["command"]?.stringValue
            var env: [String: String] = [:]
            if !resolved.cwd.isEmpty { env["PWD"] = resolved.cwd }
            if managed {
                for (key, value) in CrowAttribution.environmentEntries(for: resolved.agentKind) { env[key] = value }
            }
            let windowIndex: Int
            do {
                windowIndex = try cockpit.controller.newWindow(
                    name: name, cwd: resolved.cwd, env: env, command: command, timeout: 3.0)
            } catch {
                throw DaemonRPCError.applicationError("tmux new-window failed: \(error)")
            }
            let terminal = SessionTerminal(
                sessionID: sessionID, name: name, cwd: resolved.cwd, command: command, isManaged: managed,
                tmuxBinding: TmuxBinding(
                    socketPath: cockpit.controller.socketPath,
                    sessionName: TerminalCockpit.sessionName,
                    windowIndex: windowIndex))
            await MainActor.run { appState.terminals[sessionID, default: []].append(terminal) }
            return [
                "terminal_id": .string(terminal.id.uuidString),
                "window": .int(windowIndex),
                "name": .string(name),
            ]
        },

        "close-terminal": { params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                  let tidStr = params["terminal_id"]?.stringValue, let terminalID = UUID(uuidString: tidStr) else {
                throw DaemonRPCError.invalidParams("session_id and terminal_id required")
            }
            let windowIndex: Int? = await MainActor.run {
                let index = appState.terminals(for: sessionID)
                    .first(where: { $0.id == terminalID })?.tmuxBinding?.windowIndex
                appState.terminals[sessionID]?.removeAll { $0.id == terminalID }
                return index
            }
            if let windowIndex, let cockpit {
                cockpit.controller.killWindow(index: windowIndex)
            }
            return ["closed": .bool(true)]
        },

        "add-worktree": { params in
            guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                  let repo = params["repo"]?.stringValue, !repo.isEmpty,
                  let path = params["path"]?.stringValue, !path.isEmpty,
                  let branch = params["branch"]?.stringValue, !branch.isEmpty else {
                throw DaemonRPCError.invalidParams("session_id, repo, path, branch required (non-empty)")
            }
            // Defense-in-depth: a leading-dash branch would be parsed as an option
            // by `git ls-remote --heads origin <branch>` (option injection).
            guard !branch.hasPrefix("-") else {
                throw DaemonRPCError.invalidParams("branch must not start with '-'")
            }
            // Don't persist a worktree row for a session that doesn't exist.
            let sessionExists = await MainActor.run { appState.sessions.contains { $0.id == sessionID } }
            guard sessionExists else {
                throw DaemonRPCError.invalidParams("Unknown session_id (no such session)")
            }
            // Path-traversal guard: worktree + repo paths must live under devRoot.
            guard Validation.isPathWithinRoot(path, root: devRoot) else {
                throw DaemonRPCError.invalidParams("Worktree path must be within the configured devRoot")
            }
            let repoPath = params["repo_path"]?.stringValue ?? path
            guard Validation.isPathWithinRoot(repoPath, root: devRoot) else {
                throw DaemonRPCError.invalidParams("repo_path must be within the configured devRoot")
            }
            // Unlike the app (which records metadata and lets `setup.sh` create
            // the worktree), the daemon materializes it here via CrowGit — this
            // exercises the reused git layer end-to-end on Linux (CROW-581).
            do {
                try await git.createWorktree(repoPath: repoPath, worktreePath: path, branch: branch)
            } catch {
                throw DaemonRPCError.applicationError("git worktree add failed: \(error.localizedDescription)")
            }
            let worktree = SessionWorktree(
                sessionID: sessionID, repoName: repo, repoPath: repoPath, worktreePath: path,
                branch: branch, isPrimary: params["primary"]?.boolValue ?? false)
            return await MainActor.run {
                appState.worktrees[sessionID, default: []].append(worktree)
                store.mutate { $0.worktrees.append(worktree) }
                return [
                    "worktree_id": .string(worktree.id.uuidString),
                    "session_id": .string(idStr),
                    "path": .string(path),
                ]
            }
        },

        // Write-actions: forwarded to the desktop app (source of truth) when it's
        // running, so its side effects run and its newer state isn't clobbered;
        // handled locally only when the app is off (daemon owns the store then).
        "set-status": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                  let statusStr = params["status"]?.stringValue, let status = SessionStatus(rawValue: statusStr) else {
                throw DaemonRPCError.invalidParams("session_id and status required")
            }
            if let forwardSocket {
                do { return try forwardToApp("set-status", params, socket: forwardSocket) }
                catch let error as DaemonRPCError { throw error }
                catch { /* app not running → fall through to local */ }
            }
            return try await MainActor.run {
                guard let idx = appState.sessions.firstIndex(where: { $0.id == id }) else {
                    throw DaemonRPCError.applicationError("Session not found")
                }
                appState.sessions[idx].status = status
                appState.sessions[idx].updatedAt = Date()
                store.mutate { data in
                    if let i = data.sessions.firstIndex(where: { $0.id == id }) {
                        data.sessions[i].status = status
                        data.sessions[i].updatedAt = Date()
                    }
                }
                return ["session_id": .string(idStr), "status": .string(statusStr)]
            }
        },

        // Lock/unlock a session (protects it from auto-cleanup). Mirrors
        // `set-status`: forwarded to the app when running, handled locally
        // otherwise. The web Lock/Unlock action calls this; without it the
        // daemon returned "unknown method" (CROW-593).
        "set-locked": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                  let locked = params["locked"]?.boolValue else {
                throw DaemonRPCError.invalidParams("session_id and locked required")
            }
            if let forwardSocket {
                do { return try forwardToApp("set-locked", params, socket: forwardSocket) }
                catch let error as DaemonRPCError { throw error }
                catch { /* app not running → fall through to local */ }
            }
            return try await MainActor.run {
                guard let idx = appState.sessions.firstIndex(where: { $0.id == id }) else {
                    throw DaemonRPCError.applicationError("Session not found")
                }
                appState.sessions[idx].locked = locked
                appState.sessions[idx].updatedAt = Date()
                store.mutate { data in
                    if let i = data.sessions.firstIndex(where: { $0.id == id }) {
                        data.sessions[i].locked = locked
                        data.sessions[i].updatedAt = Date()
                    }
                }
                return ["session_id": .string(idStr), "locked": .bool(locked)]
            }
        },

        "rename-session": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                  let name = params["name"]?.stringValue else {
                throw DaemonRPCError.invalidParams("session_id and name required")
            }
            guard Validation.isValidSessionName(name) else {
                throw DaemonRPCError.invalidParams(
                    "Invalid session name (max \(Validation.maxSessionNameLength) chars, no control characters)")
            }
            if let forwardSocket {
                do { return try forwardToApp("rename-session", params, socket: forwardSocket) }
                catch let error as DaemonRPCError { throw error }
                catch { /* app not running → fall through to local */ }
            }
            return try await MainActor.run {
                guard let idx = appState.sessions.firstIndex(where: { $0.id == id }) else {
                    throw DaemonRPCError.applicationError("Session not found")
                }
                appState.sessions[idx].name = name
                store.mutate { data in
                    if let i = data.sessions.firstIndex(where: { $0.id == id }) { data.sessions[i].name = name }
                }
                return ["session_id": .string(idStr), "name": .string(name)]
            }
        },

        // Delete is forward-only: the app's teardown (worktree removal, tmux
        // window kill, scheduler cleanup) lives in SessionService, so we don't
        // attempt a partial local delete when the app isn't running.
        "delete-session": { params in
            guard let idStr = params["session_id"]?.stringValue, UUID(uuidString: idStr) != nil else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Deleting a session requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("delete-session", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable; cannot delete session") }
        },

        // Live PR status (checks/review/merge) — in-memory on the app, so
        // forward-only; report no PR when the app isn't running.
        "get-pr-status": { params in
            guard let forwardSocket else { return ["has_pr": .bool(false)] }
            do { return try forwardToApp("get-pr-status", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { return ["has_pr": .bool(false)] }
        },

        // Trigger a PR quick action — forward-only (needs the app's agent
        // terminal + coordinator to dispatch the prompt).
        "quick-action": { params in
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Quick actions require the Crow desktop app to be running")
            }
            do { return try forwardToApp("quick-action", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },

        // Board data (Ticket Board / Reviews / Allowlist) is in-memory on the app
        // (IssueTracker / AllowListService), so these reads are forward-only.
        // Coding agents are registered in the daemon's own AgentRegistry at
        // startup, so `list-agents` answers locally — no app required (CROW-581).
        "list-agents": { _ in
            await MainActor.run {
                let defaultKind = AgentRegistry.shared.defaultAgent?.kind
                let items: [JSONValue] = AgentRegistry.shared.allAgents()
                    .sorted { $0.displayName < $1.displayName }
                    .map { agent in
                        .object([
                            "kind": .string(agent.kind.rawValue),
                            "name": .string(agent.displayName),
                            "default": .bool(agent.kind == defaultKind),
                        ])
                    }
                return ["agents": .array(items)]
            }
        },
        // Board reads. When the daemon owns the tracker/allowList (CROW-581 M-C)
        // they answer locally off `appState` — populated by the daemon's own
        // IssueTracker/AllowListService — so the boards work with the app down.
        // Without those services (tests, stripped builds) they fall back to
        // forwarding to the app / an empty board, like get-pr-status. NOTE: while
        // both the app and daemon run, each polls its providers → transient
        // double-polling until the app becomes a pure client (Milestone F).
        "list-tickets": { _ in
            if tracker != nil {
                return await MainActor.run {
                    let fmt = ISO8601DateFormatter()
                    let issues: [JSONValue] = appState.filteredAssignedIssues.map { issue in
                        let status = issue.projectStatus == .unknown ? TicketStatus.backlog : issue.projectStatus
                        return .object([
                            "id": .string(issue.id),
                            "number": .int(issue.number),
                            "title": .string(issue.title),
                            "state": .string(issue.state),
                            "url": .string(issue.url),
                            "repo": .string(issue.repo),
                            "provider": .string(issue.provider.rawValue),
                            "pr_number": issue.prNumber.map { .int($0) } ?? .null,
                            "pr_url": issue.prURL.map { .string($0) } ?? .null,
                            "updated_at": issue.updatedAt.map { .string(fmt.string(from: $0)) } ?? .null,
                            "project_status": .string(status.rawValue),
                            "labels": .array(issue.labels.map { .object(["name": .string($0.name), "color": $0.color.map { .string($0) } ?? .null]) }),
                            "linked_session_id": appState.linkedSession(for: issue).map { .string($0.id.uuidString) } ?? .null,
                        ])
                    }
                    var counts: [String: JSONValue] = [:]
                    for status in TicketStatus.pipelineStatuses {
                        counts[status.rawValue] = .int(appState.issueCount(for: status))
                    }
                    counts["All"] = .int(appState.filteredAssignedIssues.count)
                    return [
                        "issues": .array(issues),
                        "counts": .object(counts),
                        "done_last_24h": .int(appState.doneIssuesLast24h),
                        "loading": .bool(appState.isLoadingIssues),
                    ]
                }
            }
            let empty: [String: JSONValue] = [
                "issues": .array([]), "counts": .object([:]),
                "done_last_24h": .int(0), "loading": .bool(false),
            ]
            guard let forwardSocket else { return empty }
            do { return try forwardToApp("list-tickets", [:], socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { return empty }
        },
        "list-reviews": { _ in
            if tracker != nil {
                return await MainActor.run {
                    let fmt = ISO8601DateFormatter()
                    let reviews: [JSONValue] = appState.filteredReviewRequests.map { r in
                        .object([
                            "id": .string(r.id),
                            "pr_number": .int(r.prNumber),
                            "title": .string(r.title),
                            "url": .string(r.url),
                            "repo": .string(r.repo),
                            "author": .string(r.author),
                            "head_branch": .string(r.headBranch),
                            "base_branch": .string(r.baseBranch),
                            "is_draft": .bool(r.isDraft),
                            "requested_at": r.requestedAt.map { .string(fmt.string(from: $0)) } ?? .null,
                            "labels": .array(r.labels.map { .object(["name": .string($0.name), "color": $0.color.map { .string($0) } ?? .null]) }),
                            "provider": .string(r.provider.rawValue),
                            "review_session_id": r.reviewSessionID.map { .string($0.uuidString) } ?? .null,
                        ])
                    }
                    return [
                        "reviews": .array(reviews),
                        "loading": .bool(appState.isLoadingReviews),
                        "unseen": .int(appState.unseenReviewCount),
                    ]
                }
            }
            let empty: [String: JSONValue] = ["reviews": .array([]), "loading": .bool(false), "unseen": .int(0)]
            guard let forwardSocket else { return empty }
            do { return try forwardToApp("list-reviews", [:], socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { return empty }
        },
        "list-allowlist": { _ in
            if allowList != nil {
                return await MainActor.run {
                    let entries: [JSONValue] = appState.allowEntries.map { e in
                        .object([
                            "pattern": .string(e.pattern),
                            "is_global": .bool(e.isInGlobal),
                            "worktree_session_names": .array(e.worktreeSessionNames.map { .string($0) }),
                        ])
                    }
                    return ["entries": .array(entries), "loading": .bool(appState.isLoadingAllowList)]
                }
            }
            let empty: [String: JSONValue] = ["entries": .array([]), "loading": .bool(false)]
            guard let forwardSocket else { return empty }
            do { return try forwardToApp("list-allowlist", [:], socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { return empty }
        },

        // Board actions — forward-only (need the app's coordinators to spawn
        // workspaces / mutate the global allowlist). Error when the app isn't
        // running, like quick-action.
        "work-on-issue": { params in
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Starting work on an issue requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("work-on-issue", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },
        "start-review": { params in
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Starting a review requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("start-review", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },
        // Allowlist writes/refreshes run locally when the daemon owns the
        // AllowListService (pure disk — no app needed); otherwise forward.
        "promote-allowlist": { params in
            if let allowList {
                guard let arr = params["patterns"]?.arrayValue else {
                    throw DaemonRPCError.invalidParams("patterns array required")
                }
                let patterns = Set(arr.compactMap { $0.stringValue })
                guard !patterns.isEmpty else { throw DaemonRPCError.invalidParams("patterns array required") }
                await MainActor.run { allowList.promoteToGlobal(patterns: patterns) }
                return ["ok": .bool(true)]
            }
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Promoting allowlist patterns requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("promote-allowlist", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },
        "refresh-tickets": { params in
            if let tracker {
                await tracker.refresh()
                return ["ok": .bool(true)]
            }
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Refreshing tickets requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("refresh-tickets", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },
        "refresh-allowlist": { params in
            if let allowList {
                await MainActor.run { allowList.scan() }
                return ["ok": .bool(true)]
            }
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Refreshing the allowlist requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("refresh-allowlist", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },

        // Batched live per-session state (remote-control + PR) — runtime-only on
        // the app, so forward-only. Empty map when the app isn't running so the
        // web keeps rendering its store-derived base list.
        "list-sessions-live": { params in
            let empty: [String: JSONValue] = ["sessions": .object([:])]
            guard let forwardSocket else { return empty }
            do { return try forwardToApp("list-sessions-live", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { return empty }
        },

        // App config (the web Settings modal). Forward to the app when it's
        // running so its `saveSettings` side effects run (AppState mirror,
        // notification settings); read/write `{devRoot}/.claude/config.json`
        // directly when it's off so Settings still work headless (the app picks
        // up the change on next launch). Credential values are stripped on the
        // way out and preserved on the way in — never editable from the browser
        // (CROW-581, desktop-only creds). Only one writer at a time: forward when
        // reachable, else write locally.
        "get-config": { params in
            // Forward to the app when it's reachable AND recognizes the method;
            // otherwise read {devRoot}/.claude/config.json directly. The fallback
            // covers both the app being down (socket error) and an app too old to
            // know get-config (method-not-found) during a daemon-ahead rollout.
            if let forwardSocket,
               let response = try? SocketClient(socketPath: forwardSocket).send(method: "get-config", params: params) {
                if let error = response.error {
                    if error.code != RPCErrorCode.methodNotFound {
                        throw DaemonRPCError.applicationError(error.message)
                    }
                    // else: old app → fall through to disk
                } else {
                    return response.result ?? [:]
                }
            }
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let stripped = SettingsSecrets.strippedForTransport(config)
            guard let data = try? JSONEncoder().encode(stripped),
                  let json = String(data: data, encoding: .utf8) else {
                throw DaemonRPCError.applicationError("Failed to encode config")
            }
            return ["config": .string(json), "dev_root": .string(devRoot), "app_running": .bool(false)]
        },
        "set-config": { params in
            guard let json = params["config"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let incoming = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                throw DaemonRPCError.invalidParams("config must be a valid AppConfig JSON string")
            }
            if let forwardSocket,
               let response = try? SocketClient(socketPath: forwardSocket).send(method: "set-config", params: params) {
                if let error = response.error {
                    if error.code != RPCErrorCode.methodNotFound {
                        throw DaemonRPCError.applicationError(error.message)
                    }
                    // else: old app → write to disk below
                } else {
                    return response.result ?? [:]
                }
            }
            // The browser can't see or change credentials, so keep whatever is
            // already on disk (nil-current drops any credential shell — see
            // SettingsSecrets).
            let current = ConfigStore.loadConfig(devRoot: devRoot)
            let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
            do {
                try ConfigStore.saveConfig(merged, devRoot: devRoot)
            } catch {
                throw DaemonRPCError.applicationError("Failed to save config: \(error.localizedDescription)")
            }
            let stripped = SettingsSecrets.strippedForTransport(merged)
            guard let outData = try? JSONEncoder().encode(stripped),
                  let outJSON = String(data: outData, encoding: .utf8) else {
                throw DaemonRPCError.applicationError("Failed to encode config")
            }
            return ["config": .string(outJSON), "saved": .bool(true)]
        },

        // Session/board actions — forward-only (need the app's coordinators).
        // Spawning a Manager forwards to the app when it's running (its
        // SessionService is the source of truth), and runs on the daemon's own
        // SessionService when the app is down — spawning a real tmux window +
        // agent on the shared cockpit (ADR 0007; CROW-581, M-E2). Without tmux
        // (sessionService == nil) it errors, as before.
        "create-manager": { params in
            if let forwardSocket {
                do { return try forwardToApp("create-manager", params, socket: forwardSocket) }
                catch let error as DaemonRPCError { throw error }
                catch { /* app not running → fall through to local spawn */ }
            }
            guard let sessionService else {
                throw DaemonRPCError.applicationError(
                    "Creating a manager requires either the Crow desktop app or tmux on the daemon host")
            }
            let requestedAgentKind = params["agent_kind"]?.stringValue
                .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }
            return await MainActor.run {
                // Lowest unused "Manager N", matching the app's picker so a
                // delete-in-the-middle doesn't collide (AppDelegate.onCreateManager).
                let existing = Set(appState.managerSessions.map(\.name))
                var n = 2
                while existing.contains("Manager \(n)") { n += 1 }
                let id = sessionService.createManagerSession(
                    name: "Manager \(n)", cwd: devRoot, agentKind: requestedAgentKind)
                return ["session_id": .string(id.uuidString), "name": .string("Manager \(n)")]
            }
        },
        // Status transitions mirror `set-status`: forwarded to the app when
        // running (so its SessionService side effects fire), handled locally
        // against the store when it's down — a pure `session.status` write, so
        // no divergence (the local path only runs with the app off). (CROW-581)
        "mark-in-review": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            if let forwardSocket {
                do { return try forwardToApp("mark-in-review", params, socket: forwardSocket) }
                catch let error as DaemonRPCError { throw error }
                catch { /* app not running → fall through to local */ }
            }
            return try await MainActor.run {
                try setSessionStatusLocally(id: id, to: .inReview, appState: appState, store: store)
            }
        },
        "mark-issue-done": { params in
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Marking the issue done requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("mark-issue-done", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },
        "complete-session": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            if let forwardSocket {
                do { return try forwardToApp("complete-session", params, socket: forwardSocket) }
                catch let error as DaemonRPCError { throw error }
                catch { /* app not running → fall through to local */ }
            }
            return try await MainActor.run {
                try setSessionStatusLocally(id: id, to: .completed, appState: appState, store: store)
            }
        },
        "set-session-active": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            if let forwardSocket {
                do { return try forwardToApp("set-session-active", params, socket: forwardSocket) }
                catch let error as DaemonRPCError { throw error }
                catch { /* app not running → fall through to local */ }
            }
            return try await MainActor.run {
                try setSessionStatusLocally(id: id, to: .active, appState: appState, store: store)
            }
        },
        "add-merge-label": { params in
            guard let forwardSocket else {
                throw DaemonRPCError.applicationError("Adding the merge label requires the Crow desktop app to be running")
            }
            do { return try forwardToApp("add-merge-label", params, socket: forwardSocket) }
            catch let error as DaemonRPCError { throw error }
            catch { throw DaemonRPCError.applicationError("Crow desktop app not reachable") }
        },
    ])
}
