import CrowCore
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
    cockpit: TerminalCockpit?
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
    ])
}
