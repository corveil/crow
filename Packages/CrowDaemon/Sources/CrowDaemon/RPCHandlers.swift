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
/// A ticket/PR URL is sent verbatim as Manager keystrokes, so accept only a
/// plain http(s) URL with no whitespace or control characters — otherwise a
/// crafted url could inject extra submitted lines into the agent (review #4).
/// Shared by `work-on-issue` and `batch-work-on-issues` so the two can't drift.
func isSafeIssueURL(_ url: String) -> Bool {
    guard !url.isEmpty,
          url.range(of: #"^https?://[^\s]+$"#, options: .regularExpression) != nil else { return false }
    return !url.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
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

/// The PR-status JSON the app's `makeEngineRouter` emits for a populated
/// `PRStatus` (the `get-pr-status` body and the per-session `pr` entry in
/// `list-sessions-live`). Kept in one place so both daemon handlers stay
/// byte-identical to the app's shape (CROW-581, M-E).
private func prStatusJSON(_ pr: PRStatus) -> [String: JSONValue] {
    [
        "has_pr": .bool(true),
        "checks": .string(pr.checksPass.rawValue),
        "review": .string(pr.reviewStatus.rawValue),
        "merge": .string(pr.mergeable.rawValue),
        "is_open": .bool(pr.isOpen),
        "is_merged": .bool(pr.isMerged),
        "ready_to_merge": .bool(pr.isReadyToMerge),
        "has_blockers": .bool(pr.hasBlockers),
        "failed_checks": .array(pr.failedCheckNames.map { .string($0) }),
        // `crow:merge` label presence — the *request* for auto-merge, distinct
        // from `session.auto_merge` (Crow already enabled it). The web row
        // renders them as two indicators (CROW-773).
        "has_merge_label": .bool(pr.hasMergeLabel),
    ]
}

/// Launch a detached GUI process on the daemon host (open the worktree in VS
/// Code / a Terminal window). Fire-and-forget: we don't wait for the app to
/// exit, we only surface a launch failure. Backs the `open-in-vscode` /
/// `open-terminal` RPCs, which restore the retired native `SessionDetailView`'s
/// "Open in VS Code" / "Open Terminal" buttons now that the web UI is the sole
/// client (ADR 0007). The daemon uses a `NoopHostBridge`, so the old
/// `SessionService.openInVSCode/openTerminal` do nothing here — the handler
/// launches the process itself (CROW-749).
private func launchHostProcess(_ executable: String, _ arguments: [String]) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    // Reap the child: `code` / `/usr/bin/open` exit almost immediately, and
    // Foundation only harvests the zombie once a `terminationHandler` or
    // `waitUntilExit()` is attached. Without this the long-lived `crowd`
    // daemon would accumulate defunct entries (matches the `terminationHandler`
    // pattern already used in TmuxController / SessionService — review Yellow).
    proc.terminationHandler = { _ in }
    try proc.run()
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
    tracker: IssueTracker? = nil,
    allowList: AllowListService? = nil,
    sessionService: SessionService? = nil,
    autoRespond: AutoRespondCoordinator? = nil,
    jobScheduler: JobScheduler? = nil,
    fallback: CommandRouter? = nil
) -> CommandRouter {
    // Serializes review kickoffs (see start-review) — one per router instance.
    let reviewSerializer = ReviewKickoffSerializer()
    return CommandRouter(handlers: [
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
        // worktree), plus ticket labels and hook-activity state. Live PR status
        // is not here — it comes from `list-sessions-live`.
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
                        "review_author": session.reviewAuthor.map { .string($0) } ?? .null,
                        // Org-goal tag (#723; ADR 0008 follow-up 8) — drives the
                        // web tag display (sidebar badge + detail header). The
                        // computed `alignment_weight` / `ticket_priority` are
                        // intentionally NOT sent: nothing on the web renders
                        // them today, so shipping them in every poll to every
                        // client was dead payload. A future consumer (scorecard
                        // / session strip) can add them back alongside its use.
                        "org_goal": session.orgGoal.map { .string($0) } ?? .null,
                        // Project-board "In Review" permission gate — mirrors the
                        // retired native `canSetProjectStatus(for:)` (GitHub/Jira
                        // yes, GitLab no). Gates the web "In Review" button (CROW-749).
                        "can_set_project_status": .bool(tracker?.canSetProjectStatus(for: session) ?? false),
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
                    // Ticket/review labels for the sidebar row's label pills —
                    // restores native `SessionRow`'s LabelPillsView, which read
                    // the same `labels(forSession:)` source (CROW-773).
                    let labels = appState.labels(forSession: session)
                    if !labels.isEmpty {
                        object["labels"] = .array(labels.map { label in
                            .object([
                                "name": .string(label.name),
                                "color": label.color.map { .string($0) } ?? .null,
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

        // Terminal-surface ops (rename / (re)launch agent / retry readiness /
        // restart Manager / restart tmux server). Forwarded to the app when it's
        // running (its SessionService owns the surface); with the app down the
        // daemon runs them on its OWN SessionService. Needs tmux; without a
        // SessionService they error, as before (ADR 0007; CROW-581, Stage 3b/F).
        "rename-terminal": { params in
            guard let sidStr = params["session_id"]?.stringValue, let sid = UUID(uuidString: sidStr),
                  let tidStr = params["terminal_id"]?.stringValue, let tid = UUID(uuidString: tidStr),
                  let name = params["name"]?.stringValue else {
                throw DaemonRPCError.invalidParams("session_id, terminal_id, name required")
            }
            guard let sessionService else {
                throw DaemonRPCError.applicationError("Renaming a terminal requires tmux on the daemon host")
            }
            let ok = await MainActor.run { sessionService.renameTerminal(sessionID: sid, terminalID: tid, name: name) }
            return ["ok": .bool(ok)]
        },
        "launch-agent": { params in
            guard let tidStr = params["terminal_id"]?.stringValue, let tid = UUID(uuidString: tidStr) else {
                throw DaemonRPCError.invalidParams("terminal_id required")
            }
            guard let sessionService else {
                throw DaemonRPCError.applicationError("Launching an agent requires tmux on the daemon host")
            }
            await MainActor.run { sessionService.launchAgent(terminalID: tid) }
            return ["ok": .bool(true)]
        },
        "retry-readiness": { params in
            guard let tidStr = params["terminal_id"]?.stringValue, let tid = UUID(uuidString: tidStr) else {
                throw DaemonRPCError.invalidParams("terminal_id required")
            }
            guard let sessionService else {
                throw DaemonRPCError.applicationError("Retrying readiness requires tmux on the daemon host")
            }
            await MainActor.run { sessionService.retryReadiness(terminalID: tid) }
            return ["ok": .bool(true)]
        },
        "restart-manager": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError("Restarting the Manager requires tmux on the daemon host")
            }
            await MainActor.run { sessionService.restartManager(devRoot: devRoot) }
            return ["ok": .bool(true)]
        },
        // Mid-session agent switch when credits run out (CROW-627). Preserves
        // session/worktree/ticket; replaces the managed agent terminal and
        // seeds the incoming agent with a handoff prompt.
        "handoff-agent": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                  let kindStr = params["agent_kind"]?.stringValue, !kindStr.isEmpty else {
                throw DaemonRPCError.invalidParams("session_id and agent_kind required")
            }
            let targetKind = AgentKind(rawValue: kindStr)
            let note = params["note"]?.stringValue
            guard let sessionService else {
                throw DaemonRPCError.applicationError("Agent handoff requires tmux on the daemon host")
            }
            do {
                let terminalID = try await sessionService.handoffAgent(
                    sessionID: id, to: targetKind, note: note)
                return [
                    "session_id": .string(idStr),
                    "agent_kind": .string(targetKind.rawValue),
                    "terminal_id": .string(terminalID.uuidString),
                ]
            } catch let error as AgentHandoffError {
                throw DaemonRPCError.applicationError(error.localizedDescription)
            }
        },
        "restart-tmux-server": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError("Restarting the tmux server requires tmux on the daemon host")
            }
            await MainActor.run { sessionService.restartTmuxServer() }
            return ["ok": .bool(true)]
        },
        // Reload the bundled tmux config into the live server (`tmux source-file`)
        // without restarting it — windows/sessions are unaffected. Mirrors the old
        // desktop app's "Reload tmux config" menu item (CROW-593).
        "reload-tmux-config": { params in
            guard sessionService != nil else {
                throw DaemonRPCError.applicationError("Reloading tmux config requires tmux on the daemon host")
            }
            if let err = await MainActor.run(body: { TmuxBackend.shared.reloadBundledConfig() }) {
                throw DaemonRPCError.applicationError(err)
            }
            return ["ok": .bool(true)]
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
            // When setup.sh (or the user) already created the checkout, register
            // metadata only — do not fail or re-run git worktree add.
            let gitMarker = (path as NSString).appendingPathComponent(".git")
            let alreadyMaterialized = FileManager.default.fileExists(atPath: gitMarker)
            if !alreadyMaterialized {
                do {
                    try await git.createWorktree(repoPath: repoPath, worktreePath: path, branch: branch)
                } catch {
                    throw DaemonRPCError.applicationError("git worktree add failed: \(error.localizedDescription)")
                }
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
            return try await MainActor.run {
                guard let idx = appState.sessions.firstIndex(where: { $0.id == id }) else {
                    throw DaemonRPCError.applicationError("Session not found")
                }
                // Preserve updatedAt — lock/unlock must not reset the auto-cleanup
                // retention clock (matches the engine's setLocked; review).
                appState.sessions[idx].locked = locked
                store.mutate { data in
                    if let i = data.sessions.firstIndex(where: { $0.id == id }) {
                        data.sessions[i].locked = locked
                    }
                }
                return ["session_id": .string(idStr), "locked": .bool(locked)]
            }
        },

        // Forwarded to the app when it's running (its SessionService teardown is
        // the source of truth). With the app down, the daemon runs the same
        // teardown on its OWN SessionService — worktree/branch cleanup, tmux
        // window destroy, store removal — guarding the manager session like the
        // app does. Needs tmux; without a SessionService it errors, as before
        // (ADR 0007; CROW-581, M-E).
        "delete-session": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError("Deleting a session requires tmux on the daemon host")
            }
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            guard id != AppState.managerSessionID else {
                throw DaemonRPCError.applicationError("Cannot delete manager session")
            }
            await sessionService.deleteSession(id: id)
            return ["deleted": .bool(true)]
        },

        // Live PR status (checks/review/merge). Forwarded to the app when it's
        // running; with the app down, read the daemon's OWN `appState.prStatus`
        // — populated by its IssueTracker on every board poll (startBoardPoll) —
        // so the web renders the same PR badge headless. Same 9-field shape as
        // the app's makeEngineRouter (CROW-581, M-E).
        "get-pr-status": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            return await MainActor.run {
                guard let pr = appState.prStatus[id] else { return ["has_pr": .bool(false)] }
                return prStatusJSON(pr)
            }
        },

        // Trigger a PR quick action — forwarded to the app when running; with the
        // app down the daemon dispatches on its OWN AutoRespondCoordinator, which
        // pastes the deterministic prompt into the session's managed tmux
        // terminal (best-effort: silently skips if there's no live sendable
        // managed terminal, exactly like the app). Needs tmux (ADR 0007; M-E).
        "quick-action": { params in
            guard let autoRespond else {
                throw DaemonRPCError.applicationError("Quick actions require the Crow desktop app or tmux on the daemon host")
            }
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            guard let actionStr = params["action"]?.stringValue, let action = QuickAction(rawValue: actionStr) else {
                throw DaemonRPCError.invalidParams("action required (fixConflicts, addressChanges, fixChecks, mergePR, reReview)")
            }
            // `dispatchManual` silently skips (no managed terminal / surface not
            // ready / no PR link); report that faithfully as `dispatched:false`
            // + a reason instead of a false success, so the web UI can surface an
            // actionable message rather than echoing "dispatched" (#730).
            let result = await MainActor.run { autoRespond.dispatchManual(action: action, sessionID: id) }
            if let reason = result.skipReason {
                return ["dispatched": .bool(false), "action": .string(action.rawValue), "reason": .string(reason)]
            }
            return ["dispatched": .bool(true), "action": .string(action.rawValue)]
        },

        // Open the session's primary worktree in VS Code on the daemon host —
        // restores the retired native "Open in VS Code" button (CROW-749). Gated
        // to loopback callers in `RPCWebSocketHandler.localOnlyDenial` since it
        // launches a GUI app on the host. Shown by the web only when the `code`
        // CLI is present (see `vs_code_available` in get-config).
        "open-in-vscode": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            let path = await MainActor.run { appState.primaryWorktree(for: id)?.worktreePath }
            guard let path else {
                throw DaemonRPCError.applicationError("No worktree for session")
            }
            guard let code = SessionService.findVSCodeBinary() else {
                throw DaemonRPCError.applicationError("VS Code CLI not found")
            }
            do {
                try launchHostProcess(code, [path])
            } catch {
                throw DaemonRPCError.applicationError("Failed to launch VS Code: \(error.localizedDescription)")
            }
            return ["opened": .bool(true)]
        },

        // Open a host Terminal window at the session's primary worktree —
        // restores the retired native "Open Terminal" button (CROW-749). macOS
        // only (native used NSWorkspace); loopback-gated like `open-in-vscode`.
        "open-terminal": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            let path = await MainActor.run { appState.primaryWorktree(for: id)?.worktreePath }
            guard let path else {
                throw DaemonRPCError.applicationError("No worktree for session")
            }
            #if os(macOS)
            do {
                // `--` terminates option parsing so an unusual worktree path can
                // never be read as an `open` flag (defense in depth; review Green).
                try launchHostProcess("/usr/bin/open", ["-a", "Terminal", "--", path])
            } catch {
                throw DaemonRPCError.applicationError("Failed to open Terminal: \(error.localizedDescription)")
            }
            return ["opened": .bool(true)]
            #else
            throw DaemonRPCError.applicationError("Opening a host terminal is only supported on macOS")
            #endif
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
        // Per-session generated images from the scratch dir. Local + read-only —
        // the browser then GETs each `url` from the sandboxed /artifacts route
        // (CROW-593).
        "list-artifacts": { params in
            guard let sessionID = params["session_id"]?.stringValue else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            let fmt = ISO8601DateFormatter()
            let images: [JSONValue] = Artifacts.list(sessionID: sessionID).map { item in
                let encoded = item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.name
                return .object([
                    "name": .string(item.name),
                    "size": .int(item.size),
                    "mtime": .string(fmt.string(from: item.mtime)),
                    "url": .string("/artifacts/\(sessionID)/\(encoded)"),
                ])
            }
            return ["images": .array(images)]
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
                            // Richer board detail (#751) — all optional/back-compatible.
                            "body": issue.body.map { .string($0) } ?? .null,
                            "author": issue.author.map { .string($0) } ?? .null,
                            "created_at": issue.createdAt.map { .string(fmt.string(from: $0)) } ?? .null,
                            "comments_count": issue.commentsCount.map { .int($0) } ?? .null,
                            "pr_state": issue.prState.map { .string($0) } ?? .null,
                            "checks": issue.checksState.map { .object(["state": .string($0), "failed": .array((issue.failedCheckNames ?? []).map { .string($0) })]) } ?? .null,
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
            return empty
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
            return empty
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
            return empty
        },

        // Board actions — forward-only (need the app's coordinators to spawn
        // workspaces / mutate the global allowlist). Error when the app isn't
        // running, like quick-action.
        // Work-on-issue types `/crow-workspace <url>` into the primary Manager
        // terminal and lets that agent do the worktree/session setup. Forwarded
        // to the app when it's running; with the app down the daemon drives its
        // OWN Manager window directly — it registered that window, so it holds
        // the live tmux binding (no stale-index adoption). (ADR 0007; M-E2)
        "work-on-issue": { params in
            guard sessionService != nil else {
                throw DaemonRPCError.applicationError(
                    "Working on an issue requires tmux on the daemon host")
            }
            guard let url = params["url"]?.stringValue, !url.isEmpty else {
                throw DaemonRPCError.invalidParams("url required")
            }
            guard isSafeIssueURL(url) else {
                throw DaemonRPCError.invalidParams("url must be a well-formed http(s) URL with no control characters")
            }
            return try await MainActor.run {
                guard let managerTerminal = appState.terminals[AppState.managerSessionID]?.first else {
                    throw DaemonRPCError.applicationError("The Manager is still starting — try again in a moment")
                }
                TerminalRouter.send(managerTerminal, text: "/crow-workspace \(url)\n")
                return ["ok": .bool(true)]
            }
        },
        // Batch counterpart of work-on-issue (#752): types ONE
        // `/crow-batch-workspace <url1> <url2> …` line, so the Manager runs the
        // parallel batch skill once instead of N sequential `/crow-workspace`
        // submissions. Single-line by construction — TerminalRouter turns
        // newlines into Enter presses, so an embedded newline would split the
        // prompt (cf. #161). Unsafe URLs are dropped and reported back in
        // `rejected` rather than failing the whole batch, so one bad ticket
        // can't block the rest.
        "batch-work-on-issues": { params in
            guard sessionService != nil else {
                throw DaemonRPCError.applicationError(
                    "Working on an issue requires tmux on the daemon host")
            }
            guard let arr = params["urls"]?.arrayValue, !arr.isEmpty else {
                throw DaemonRPCError.invalidParams("urls array required")
            }
            var valid: [String] = []
            var rejected: [String] = []
            for value in arr {
                let url = value.stringValue ?? ""
                if isSafeIssueURL(url) {
                    if !valid.contains(url) { valid.append(url) }
                } else {
                    rejected.append(url)
                }
            }
            guard !valid.isEmpty else {
                throw DaemonRPCError.invalidParams("urls must be well-formed http(s) URLs with no control characters")
            }
            return try await MainActor.run {
                guard let managerTerminal = appState.terminals[AppState.managerSessionID]?.first else {
                    throw DaemonRPCError.applicationError("The Manager is still starting — try again in a moment")
                }
                TerminalRouter.send(
                    managerTerminal,
                    text: "/crow-batch-workspace \(valid.joined(separator: " "))\n")
                return [
                    "ok": .bool(true),
                    "sent": .int(valid.count),
                    "rejected": .array(rejected.map { .string($0) }),
                ]
            }
        },
        // Starting a review forwards to the app when it's running; with the app
        // down it runs on the daemon's own SessionService — cloning the PR,
        // scaffolding the review skill, and spawning a tmux window + agent
        // (ADR 0007; CROW-581, M-E2). Kickoffs are serialized so the internal
        // dedupe stays race-free. Without tmux it errors, as before.
        "start-review": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError(
                    "Starting a review requires tmux on the daemon host")
            }
            guard let url = params["url"]?.stringValue, !url.isEmpty else {
                throw DaemonRPCError.invalidParams("url required")
            }
            let task = await reviewSerializer.enqueue {
                await sessionService.createReviewSession(prURL: url, selectAfterCreate: false)
            }
            guard let id = await task.value else {
                throw DaemonRPCError.applicationError("Could not start a review for \(url)")
            }
            return ["session_id": .string(id.uuidString)]
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
            throw DaemonRPCError.applicationError("Promoting allowlist patterns requires a provider-configured daemon")
        },
        "refresh-tickets": { params in
            if let tracker {
                await tracker.refresh()
                return ["ok": .bool(true)]
            }
            throw DaemonRPCError.applicationError("Refreshing tickets requires a provider-configured daemon")
        },
        "refresh-allowlist": { params in
            if let allowList {
                await MainActor.run { allowList.scan() }
                return ["ok": .bool(true)]
            }
            throw DaemonRPCError.applicationError("Refreshing the allowlist requires a provider-configured daemon")
        },

        // Batched live per-session state (remote-control + PR + PR link).
        // Forwarded to the app when running; with the app down the daemon builds
        // the same map from its OWN appState — prStatus from the board poll, RC
        // flags from the runtime terminal set, and the (possibly memory-only) PR
        // link from `links(for:)`. Matches the app's makeEngineRouter shape so the
        // web shows PR badges wherever the desktop does (CROW-581, M-E).
        "list-sessions-live": { params in
            return await MainActor.run {
                var out: [String: JSONValue] = [:]
                for session in appState.sessions {
                    let id = session.id
                    let available = AgentRegistry.shared.agent(for: session.agentKind)?.supportsRemoteControl ?? false
                    let rcActive = appState.terminals(for: id)
                        .contains { appState.remoteControlActiveTerminals.contains($0.id) }
                    var entry: [String: JSONValue] = [
                        "remote_control_active": .bool(rcActive),
                        "remote_control_available": .bool(available),
                        // PR quick-actions need a managed Claude Code terminal to
                        // dispatch into — mirrors native `canDispatchQuickAction`.
                        // The web disables the quick-action buttons when false (CROW-749).
                        "can_dispatch": .bool(appState.terminals(for: id).contains { $0.isManaged }),
                    ]
                    entry["pr"] = appState.prStatus[id].map { .object(prStatusJSON($0)) }
                        ?? .object(["has_pr": .bool(false)])
                    if let prLink = appState.links(for: id).first(where: { $0.linkType == .pr }) {
                        entry["pr_link"] = .object(["label": .string(prLink.label), "url": .string(prLink.url)])
                    }
                    // Per-session analytics strip (CROW-722). Prefer the live
                    // in-memory hook aggregate (open sessions); fall back to the
                    // durable end-of-session snapshot (terminal sessions). Mirrors
                    // `writeAnalyticsSnapshot`'s own source preference. Never for the
                    // Manager, and never an all-zeros aggregate — the web renders
                    // the strip only when this key is present (chips-only empty
                    // state), so absence IS the empty state.
                    if !appState.isManagerSession(id) {
                        let dto: SessionAnalyticsDTO?
                        if let live = appState.existingHookState(for: id)?.analytics, !live.isEmpty {
                            dto = SessionAnalyticsDTO(live: live, wallClockDuration: session.wallClockDuration)
                        } else if let snapshot = appState.analyticsSnapshots[id.uuidString] {
                            dto = SessionAnalyticsDTO(snapshot: snapshot)
                        } else {
                            dto = nil
                        }
                        if let dto, let encoded = try? JSONValue(encoding: dto) {
                            entry["analytics"] = encoded
                        }
                    }
                    out[id.uuidString] = .object(entry)
                }
                return ["sessions": .object(out)]
            }
        },

        // Full render-state snapshot so a rich client (the macOS app) can rebuild
        // its entire AppState in ONE call, then keep it fresh by re-fetching on
        // each EventHub `changed` push. Read-only and always local — the daemon's
        // own AppState is the live view whether or not the desktop app is up, and
        // there is nothing to forward (ADR 0007; CROW-581, Stage 2 / F). The
        // response object *is* a `DaemonStateSnapshot` — the client decodes the
        // whole result into that type.
        "get-state": { _ in
            let snapshot = await MainActor.run { () -> DaemonStateSnapshot in
                // Strip credentials (Jira token, gateway auth headers, web-password
                // hash+salt) before sending state to any authenticated /rpc client —
                // the same treatment get-config applies. Without this, get-state
                // shipped the raw AppConfig secrets over the wire (review: Red 1).
                let safeConfig = ConfigStore.loadConfig(devRoot: devRoot)
                    .map(SettingsSecrets.strippedForTransport)
                return DaemonStateSnapshot(appState: appState, config: safeConfig)
            }
            do {
                guard case .object(let dict) = try JSONValue(encoding: snapshot) else {
                    throw DaemonRPCError.applicationError("state snapshot did not encode to an object")
                }
                return dict
            } catch let error as DaemonRPCError {
                throw error
            } catch {
                throw DaemonRPCError.applicationError("Failed to encode state snapshot: \(error)")
            }
        },

        // Private efficiency scorecard (ADR 0008; web parity #721). The desktop
        // `ScorecardView` reads `ScorecardModel` off `appState.analyticsSnapshots`
        // + `appState.prAttributions` directly; the web has no Swift value types,
        // so we build the ONE Core `ScorecardModel.build(...)` here and ship its
        // flattened `ScorecardDTO`. Building server-side is what guarantees the
        // web grade/throughput/combined/baseline can never drift from desktop —
        // there is no JS re-implementation of the grading to keep in sync.
        // Read-only and always local (same posture as get-state).
        "get-scorecard": { _ in
            let dto = await MainActor.run { () -> ScorecardDTO in
                let model = ScorecardModel.build(
                    snapshots: Array(appState.analyticsSnapshots.values),
                    attributions: Array(appState.prAttributions.values),
                    now: Date(),
                    calendar: .current
                )
                let telemetryEnabled = ConfigStore.loadConfig(devRoot: devRoot)?.telemetry.enabled ?? false
                return ScorecardDTO(
                    model,
                    telemetryEnabled: telemetryEnabled,
                    snapshotCount: appState.analyticsSnapshots.count
                )
            }
            do {
                guard case .object(let dict) = try JSONValue(encoding: dto) else {
                    throw DaemonRPCError.applicationError("scorecard did not encode to an object")
                }
                return dict
            } catch let error as DaemonRPCError {
                throw error
            } catch {
                throw DaemonRPCError.applicationError("Failed to encode scorecard: \(error)")
            }
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
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let stripped = SettingsSecrets.strippedForTransport(config)
            guard let data = try? JSONEncoder().encode(stripped),
                  let json = String(data: data, encoding: .utf8) else {
                throw DaemonRPCError.applicationError("Failed to encode config")
            }
            // `configured` mirrors the desktop's first-run gate
            // (`ConfigStore.loadDevRoot() == nil`); `dev_root` itself is never
            // empty (cwd fallback), so it can't detect first-run. `default_dev_root`
            // lets the web wizard prefill step 1 without knowing $HOME (CROW-605).
            let defaultDevRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Dev").path
            return [
                "config": .string(json),
                "dev_root": .string(devRoot),
                "app_running": .bool(false),
                "configured": .bool(ConfigStore.loadDevRoot() != nil),
                "default_dev_root": .string(defaultDevRoot),
                // Host capability: is the VS Code `code` CLI installed? Gates the
                // web "Open in VS Code" button, mirroring native `vsCodeAvailable`.
                // Computed here (not off `sessionService`) so it's independent of
                // tmux presence (CROW-749).
                "vs_code_available": .bool(SessionService.findVSCodeBinary() != nil),
            ]
        },
        // Non-secret settings write. `defaults.binaries` is held to the same
        // local-direct bar as secret writes — the `/rpc` WebSocket handler rejects
        // that field change from non-local peers before this runs (review Yellow).
        // Scheduled `jobs` are NOT gated (CROW-665): an authenticated remote
        // session may edit them. Unix-socket / CLI callers are always local.
        "set-config": { params in
            guard let json = params["config"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let incoming = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                throw DaemonRPCError.invalidParams("config must be a valid AppConfig JSON string")
            }
            // The browser can't see or change credentials, so keep whatever is
            // already on disk (nil-current drops any credential shell — see
            // SettingsSecrets). Load+save under the shared lock so a concurrent
            // set-web-password / onJobRan can't clobber this write (review #10).
            let merged: AppConfig
            do {
                merged = try ConfigStore.withConfigLock {
                    let current = ConfigStore.loadConfig(devRoot: devRoot)
                    let m = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
                    try ConfigStore.saveConfig(m, devRoot: devRoot)
                    return m
                }
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

        // First-run setup wizard (CROW-605). Scaffolds the chosen dev root,
        // writes config.json + the App Support pointer, then asks the daemon to
        // re-exec so every subsystem that captured `devRoot` at startup adopts
        // the new path. Rejected once a pointer already exists.
        //
        // Local-direct only: the `/rpc` WebSocket handler rejects non-local
        // callers before this runs (review Yellow). Documented here so a future
        // Unix-socket / CLI path doesn't reintroduce a remote write+re-exec.
        "run-setup": { params in
            if ConfigStore.loadDevRoot() != nil {
                throw DaemonRPCError.invalidParams("Already configured — setup wizard is one-shot")
            }
            guard let rawRoot = params["dev_root"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawRoot.isEmpty else {
                throw DaemonRPCError.invalidParams("dev_root required")
            }
            let chosen = expandSetupDevRoot(rawRoot)
            guard !chosen.isEmpty else {
                throw DaemonRPCError.invalidParams("dev_root required")
            }
            guard let json = params["config"]?.stringValue,
                  let data = json.data(using: .utf8),
                  let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                throw DaemonRPCError.invalidParams("config must be a valid AppConfig JSON string")
            }
            do {
                try ConfigStore.withConfigLock {
                    try Scaffolder(devRoot: chosen).scaffold(
                        workspaceNames: config.workspaces.map(\.name))
                    try ConfigStore.saveConfig(config, devRoot: chosen)
                    try ConfigStore.saveDevRoot(chosen)
                }
            } catch {
                throw DaemonRPCError.applicationError(
                    "Setup failed: \(error.localizedDescription)")
            }
            CrowDaemon.requestReexec()
            return ["ok": .bool(true), "dev_root": .string(chosen)]
        },

        // NOTE: the web-access password and AI gateways are secret writes and
        // are managed via local-only, Origin-checked HTTP POSTs in
        // `SecretRoutes`, never here. A JSON-RPC method on this shared router is
        // reachable over the possibly-remote `/rpc` WebSocket and can't tell a
        // local caller from a logged-in remote one, so it must not carry secret
        // writes — that would let a remote client change the password that gates
        // remote access (CROW-593). The same local-direct bar applies to
        // `set-config` changes of `defaults.binaries` (gated in
        // `RPCWebSocketHandler`) — those absolute binary paths execute at the next
        // launch. Scheduled `jobs` are no longer gated (CROW-665).

        // Session/board actions — forward-only (need the app's coordinators).
        // Spawning a Manager forwards to the app when it's running (its
        // SessionService is the source of truth), and runs on the daemon's own
        // SessionService when the app is down — spawning a real tmux window +
        // agent on the shared cockpit (ADR 0007; CROW-581, M-E2). Without tmux
        // (sessionService == nil) it errors, as before.
        "create-manager": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError(
                    "Creating a manager requires tmux on the daemon host")
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
            return try await MainActor.run {
                try setSessionStatusLocally(id: id, to: .inReview, appState: appState, store: store)
            }
        },
        // Provider ticket transition (close / project-board move). Forwarded to
        // the app when running; with the app down the daemon runs it on its OWN
        // IssueTracker — a pure provider CLI call (gh/glab/Jira/Corveil), no
        // terminal needed, fully headless (CROW-581, M-E).
        "mark-issue-done": { params in
            guard let tracker else {
                throw DaemonRPCError.applicationError("Marking the issue done requires a provider-configured daemon")
            }
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            await tracker.markIssueDone(sessionID: id)
            return ["ok": .bool(true)]
        },
        "complete-session": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            return try await MainActor.run {
                try setSessionStatusLocally(id: id, to: .completed, appState: appState, store: store)
            }
        },
        "set-session-active": { params in
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            return try await MainActor.run {
                try setSessionStatusLocally(id: id, to: .active, appState: appState, store: store)
            }
        },
        // Add the `crow:merge` label to the session's PR. Forwarded to the app
        // when running; with the app down the daemon runs it on its OWN
        // IssueTracker — a pure provider CLI call, fully headless (CROW-581, M-E).
        "add-merge-label": { params in
            guard let tracker else {
                throw DaemonRPCError.applicationError("Adding the merge label requires a provider-configured daemon")
            }
            guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            await tracker.addMergeLabel(sessionID: id)
            return ["ok": .bool(true)]
        },

        // Run a scheduled job on demand. Forwarded to the app when it's running (its
        // JobScheduler is the source of truth then); with the app down the daemon
        // runs it on its OWN JobScheduler — spawning the worktree/session/agent
        // headlessly. Needs tmux (a SessionService-backed scheduler); without one
        // it errors, as before (ADR 0007; CROW-581, M-E2).
        "run-job": { params in
            guard let jobScheduler else {
                throw DaemonRPCError.applicationError("Running a job requires tmux on the daemon host")
            }
            guard let idStr = params["job_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                throw DaemonRPCError.invalidParams("job_id required")
            }
            await MainActor.run { jobScheduler.runNow(id) }
            return ["ok": .bool(true)]
        },

        // Job management for `crow job` (CROW-604). Mutating verbs change
        // `AppConfig.jobs` under the shared config lock — the same source the
        // scheduler's `jobsProvider` and the web Settings UI read. Write verbs
        // are local-direct on `/rpc` (see `RPCWebSocketHandler.localOnlyDenial`).
        "job-list": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return ["jobs": .array(config.jobs.map { JobRPC.jobJSON($0) })]
        },
        "job-get": { params in
            let id = try jobIDParam(params)
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            guard let job = config.jobs.first(where: { $0.id == id }) else {
                throw DaemonRPCError.applicationError("Job not found")
            }
            return ["job": JobRPC.jobJSON(job)]
        },
        "job-add": { params in
            try mapJobRPCError {
                let name = try JobRPC.decodeName(params["name"])
                guard let workspace = params["workspace"]?.stringValue else {
                    throw RPCError.invalidParams("workspace required")
                }
                let repo = try JobRPC.validateRepoSlug(params["repo"]?.stringValue ?? "")
                guard let scheduleValue = params["schedule"] else {
                    throw RPCError.invalidParams("schedule required")
                }
                let schedule = try JobRPC.decodeSchedule(scheduleValue)
                let prompts = try JobRPC.decodePrompts(params["prompts"])
                let enabled = params["enabled"]?.boolValue ?? true
                let job = try mutateJobs(devRoot: devRoot) { config -> JobConfig in
                    try validateJobWorkspace(workspace, config: config)
                    if let error = JobConfig.validateName(name, existingNames: config.jobs.map(\.name)) {
                        throw RPCError.invalidParams(error)
                    }
                    let job = JobConfig(
                        name: name, workspace: workspace, repo: repo,
                        prompts: prompts, schedule: schedule, enabled: enabled)
                    config.jobs.append(job)
                    return job
                }
                return ["job": JobRPC.jobJSON(job)]
            }
        },
        "job-edit": { params in
            try mapJobRPCError {
                let id = try jobIDParam(params)
                let newSchedule = try params["schedule"].map { try JobRPC.decodeSchedule($0) }
                let newPrompts = try params["prompts"].map { try JobRPC.decodePrompts($0) }
                let job = try mutateJobs(devRoot: devRoot) { config -> JobConfig in
                    guard let idx = config.jobs.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Job not found")
                    }
                    var job = config.jobs[idx]
                    if params["name"] != nil {
                        let name = try JobRPC.decodeName(params["name"])
                        if name != job.name {
                            let otherNames = config.jobs.filter { $0.id != id }.map(\.name)
                            if let error = JobConfig.validateName(name, existingNames: otherNames) {
                                throw RPCError.invalidParams(error)
                            }
                            job.name = name
                        }
                    }
                    if let workspace = params["workspace"]?.stringValue {
                        try validateJobWorkspace(workspace, config: config)
                        job.workspace = workspace
                    }
                    if let repo = params["repo"]?.stringValue {
                        job.repo = try JobRPC.validateRepoSlug(repo)
                    }
                    if let newPrompts { job.prompts = newPrompts }
                    if let newSchedule { job.schedule = newSchedule }
                    config.jobs[idx] = job
                    return job
                }
                return ["job": JobRPC.jobJSON(job)]
            }
        },
        "job-enable": { params in
            try mapJobRPCError {
                let id = try jobIDParam(params)
                let job = try mutateJobs(devRoot: devRoot) { config -> JobConfig in
                    guard let idx = config.jobs.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Job not found")
                    }
                    config.jobs[idx].enabled = true
                    return config.jobs[idx]
                }
                return ["job": JobRPC.jobJSON(job)]
            }
        },
        "job-disable": { params in
            try mapJobRPCError {
                let id = try jobIDParam(params)
                let job = try mutateJobs(devRoot: devRoot) { config -> JobConfig in
                    guard let idx = config.jobs.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Job not found")
                    }
                    config.jobs[idx].enabled = false
                    return config.jobs[idx]
                }
                return ["job": JobRPC.jobJSON(job)]
            }
        },
        "job-delete": { params in
            try mapJobRPCError {
                let id = try jobIDParam(params)
                try mutateJobs(devRoot: devRoot) { config in
                    guard config.jobs.contains(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Job not found")
                    }
                    config.jobs.removeAll { $0.id == id }
                }
                return ["deleted": .bool(true), "job_id": .string(id.uuidString)]
            }
        },
        "job-duplicate": { params in
            try mapJobRPCError {
                let id = try jobIDParam(params)
                let copy = try mutateJobs(devRoot: devRoot) { config -> JobConfig in
                    guard let original = config.jobs.first(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Job not found")
                    }
                    let copy = original.duplicated(existingNames: config.jobs.map(\.name))
                    config.jobs.append(copy)
                    return copy
                }
                return ["job": JobRPC.jobJSON(copy)]
            }
        },
        "job-run": { params in
            let id = try jobIDParam(params)
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            guard config.jobs.contains(where: { $0.id == id }) else {
                throw DaemonRPCError.applicationError("Job not found")
            }
            guard let jobScheduler else {
                throw DaemonRPCError.applicationError("Running a job requires tmux on the daemon host")
            }
            do {
                let result = try await jobScheduler.runNowReporting(id)
                return [
                    "job_id": .string(id.uuidString),
                    "session_id": .string(result.sessionID.uuidString),
                    "terminal_id": .string(result.terminalID.uuidString),
                ]
            } catch let error as JobScheduler.RunNowError {
                throw DaemonRPCError.applicationError(error.localizedDescription)
            }
        },
    ], fallback: fallback)
}

/// Parse the `job_id` param shared by every id-taking `job-*` method.
private func jobIDParam(_ params: [String: JSONValue]) throws -> UUID {
    guard let idStr = params["job_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
        throw DaemonRPCError.invalidParams("job_id required (UUID)")
    }
    return id
}

private func validateJobWorkspace(_ workspace: String, config: AppConfig) throws {
    guard config.workspaces.contains(where: { $0.name == workspace }) else {
        throw RPCError.invalidParams("Unknown workspace '\(workspace)'")
    }
}

/// Persist a job-config mutation under the shared lock. Disk write first so a
/// failed save leaves memory and disk consistent.
@discardableResult
private func mutateJobs<T>(devRoot: String, _ transform: (inout AppConfig) throws -> T) throws -> T {
    try ConfigStore.withConfigLock {
        var config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
        let result = try transform(&config)
        do {
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        } catch {
            throw RPCError.applicationError("Failed to persist job change: \(error.localizedDescription)")
        }
        return result
    }
}

/// `JobRPC` throws `RPCError`; map to `DaemonRPCError` for the daemon router.
private func mapJobRPCError<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as RPCError {
        switch error {
        case .invalidParams(let msg): throw DaemonRPCError.invalidParams(msg)
        case .applicationError(let msg): throw DaemonRPCError.applicationError(msg)
        }
    } catch let error as DaemonRPCError {
        throw error
    } catch {
        throw DaemonRPCError.applicationError(error.localizedDescription)
    }
}

/// Expand a wizard-supplied `dev_root`: leading `~` → home; relative paths
/// resolve under home. Absolute paths pass through unchanged (CROW-605).
private func expandSetupDevRoot(_ raw: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if raw == "~" { return home }
    if raw.hasPrefix("~/") {
        return (home as NSString).appendingPathComponent(String(raw.dropFirst(2)))
    }
    if (raw as NSString).isAbsolutePath { return raw }
    return (home as NSString).appendingPathComponent(raw)
}
