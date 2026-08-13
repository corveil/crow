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

/// The `session.status` transitions behind `mark-in-review` / `complete-session`
/// / `set-session-active` (and their `crow` verbs, CROW-816).
///
/// Prefers `SessionService.updateSessionStatus`, which also schedules the
/// analytics snapshot a `.completed` transition is supposed to record. The
/// direct `appState` + `store` write is the fallback for a daemon with no
/// `SessionService` at all — that's the no-tmux host (`CrowDaemon.run()`), not a
/// defensive branch. Must be called on the main actor (`appState` isolation).
@MainActor
private func applySessionStatus(
    id: UUID, to status: SessionStatus,
    appState: AppState, store: JSONStore, sessionService: SessionService?
) throws -> [String: JSONValue] {
    guard appState.sessions.contains(where: { $0.id == id }) else {
        throw DaemonRPCError.applicationError("Session not found")
    }
    // `updateSessionStatus` silently skips managers. Surface that instead, so a
    // CLI caller never gets a success receipt for a write that didn't happen.
    guard !appState.isManagerSession(id) else {
        throw DaemonRPCError.applicationError("Manager sessions have no review/complete lifecycle")
    }

    if let sessionService {
        switch status {
        case .inReview: sessionService.setSessionInReview(id: id)
        case .completed: sessionService.completeSession(id: id)
        case .active: sessionService.setSessionActive(id: id)
        default: throw DaemonRPCError.invalidParams("Unsupported lifecycle status: \(status.rawValue)")
        }
    } else {
        let now = Date()
        if let idx = appState.sessions.firstIndex(where: { $0.id == id }) {
            appState.sessions[idx].status = status
            appState.sessions[idx].updatedAt = now
        }
        store.mutate { data in
            if let i = data.sessions.firstIndex(where: { $0.id == id }) {
                data.sessions[i].status = status
                data.sessions[i].updatedAt = now
            }
        }
    }
    return SessionLifecycleRPC.statusResult(id: id, status: status)
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
    // Backs `rebuild-scorecard` (#767). Defined by the daemon where both the
    // SessionService and the telemetry receiver are in scope; nil when telemetry
    // is off (there'd be no DB to rebuild from).
    rebuildScorecard: (@MainActor @Sendable () async -> Void)? = nil,
    versionUpdateService: VersionUpdateService? = nil,
    fallback: CommandRouter? = nil
) -> CommandRouter {
    // Serializes review kickoffs (see start-review) — one per router instance.
    let reviewSerializer = ReviewKickoffSerializer()
    // The explicit annotation is load-bearing, not decoration: this literal is
    // ~65 closures in one expression, and without a contextual type Swift both
    // re-derives the dictionary type from scratch (blowing the type checker's
    // solver budget) and loses the `@Sendable` context each closure is checked
    // against. Keep it — and keep new verb groups in their own function, as
    // `makeWorkspaceHandlers` does below.
    var handlers: [String: CommandRouter.Handler] = [
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
                // Registry gate (CROW-593; #834), matching the app's new-session
                // surface: honor the requested kind only if registered, else the
                // configured default — no unregistered kind persists here either.
                let agentKind = AgentRegistry.shared.registeredKind(requestedAgentKind)
                    ?? appState.agentKind(for: .work)
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
                    // Board issue linked to this session (exact ticket URL, plus
                    // the Jira-key fallback). Also backs `labels` below.
                    let issue = appState.assignedIssue(for: session)
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
                        // Linked issue's open/closed state (#792) — drives the
                        // sidebar ticket pill's closed color, parity with the
                        // merged-PR pill. Null when no board issue matches.
                        "ticket_state": issue.map { .string($0.state) } ?? .null,
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
                        // When the wait started. Already persisted on
                        // `HookNotification` and previously dropped here; emitted so
                        // "waiting" can be told from "waiting too long" (CROW-1004,
                        // `list_stuck_sessions`). Additive — the web client ignores
                        // keys it doesn't read.
                        object["attention_since"] = .string(
                            ISO8601DateFormatter().string(from: notification.timestamp))
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
            if let err = await TmuxBackend.shared.reloadBundledConfig() {
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
        // Returns **all known** agents, each with an `available` flag + `binary`
        // token, so the pickers can grey out off-PATH ones with a help tooltip
        // instead of hiding them (#879).
        "list-agents": { _ in
            await MainActor.run {
                let items: [JSONValue] = AgentRegistry.shared.agentListings().map { a in
                    .object([
                        "kind": .string(a.kind.rawValue),
                        "name": .string(a.displayName),
                        "default": .bool(a.isDefault),
                        "available": .bool(a.available),
                        "binary": .string(a.binary),
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
            // Absolute on-disk location, for `crow list-artifacts` and for agents
            // that wrote here via $CROW_ARTIFACTS_DIR — the `url` below is only
            // resolvable against the daemon's own web server, so a shell caller
            // can do nothing with it. Computed here rather than in the CLI
            // because ArtifactPaths owns the $TMPDIR convention and a CLI
            // process's $TMPDIR need not match a launchd-spawned crowd's (#819).
            let dir = Artifacts.dir(sessionID: sessionID)
            let images: [JSONValue] = Artifacts.list(sessionID: sessionID).map { item in
                let encoded = item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.name
                var object: [String: JSONValue] = [
                    "name": .string(item.name),
                    "size": .int(item.size),
                    "mtime": .string(fmt.string(from: item.mtime)),
                    "url": .string("/artifacts/\(sessionID)/\(encoded)"),
                ]
                if let dir {
                    object["path"] = .string(dir.appendingPathComponent(item.name).path)
                }
                return .object(object)
            }
            var result: [String: JSONValue] = ["images": .array(images)]
            // Omitted (along with every `path`) when session_id isn't a UUID —
            // Artifacts.dir's traversal guard. Kept as an empty list rather than
            // an error to preserve the web caller's behavior; the CLI validates
            // the UUID client-side before it ever gets here.
            if let dir { result["dir"] = .string(dir.path) }
            return result
        },
        // Best-effort tmux pane tail for the session-switcher preview card
        // (CROW-976). Returns plain text or null — never errors on a missing pane.
        "get-session-terminal-preview": { params in
            guard let sidStr = params["session_id"]?.stringValue,
                  let sid = UUID(uuidString: sidStr) else {
                throw DaemonRPCError.invalidParams("session_id required")
            }
            guard let cockpit else {
                return ["preview": .null]
            }
            let windowIndex: Int? = await MainActor.run {
                appState.terminalPreviewWindowIndex(for: sid)
            }
            guard let index = windowIndex,
                  let preview = cockpit.previewText(windowIndex: index) else {
                return ["preview": .null]
            }
            return ["preview": .string(preview)]
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
                return await MainActor.run { ReviewsPayload.build(appState: appState) }
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
        // Batch counterpart of start-review (CROW-865), backing the Reviews
        // board's "Start Review (N)". Unlike batch-work-on-issues this types
        // nothing at the Manager — it enqueues N kickoffs on the same
        // serializer, so the dedupe stays race-free (the old desktop
        // `onBatchStartReview` fanned out in parallel and did race, #212/#266).
        //
        // The enqueued tasks are deliberately NOT awaited: each one clones a PR
        // and spawns a tmux window, far past the web client's 10s rpc timeout,
        // and they run one at a time. So this acks as soon as the work is
        // queued and the new sessions surface via the sidebar poll — the same
        // "let it show up" contract `spawnAction` already relies on.
        //
        // Unsafe urls are dropped and reported in `rejected` rather than
        // failing the whole batch, so one bad PR can't block the rest.
        "batch-start-review": { params in
            guard let sessionService else {
                throw DaemonRPCError.applicationError(
                    "Starting a review requires tmux on the daemon host")
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
            for url in valid {
                _ = await reviewSerializer.enqueue {
                    await sessionService.createReviewSession(prURL: url, selectAfterCreate: false)
                }
            }
            return [
                "ok": .bool(true),
                "started": .int(valid.count),
                "rejected": .array(rejected.map { .string($0) }),
            ]
        },
        // Allowlist writes/refreshes run locally when the daemon owns the
        // AllowListService (pure disk — no app needed); otherwise forward.
        "promote-allowlist": { params in
            guard let allowList else {
                // Pure disk I/O — no provider involved. (The old copy said
                // "provider-configured daemon", pasted from refresh-tickets.)
                throw DaemonRPCError.applicationError(
                    "Promoting allowlist patterns requires a daemon with the allowlist service")
            }
            let patterns = try await mapRPCError { try AllowlistRPC.decodePatterns(params["patterns"]) }
            do {
                let promotion = try await MainActor.run {
                    try allowList.promoteToGlobal(patterns: patterns)
                }
                return AllowlistRPC.promotionJSON(promotion)
            } catch {
                // Never report success for a write that didn't land (#819) — the
                // failure used to be an NSLog behind an unconditional ok:true.
                throw DaemonRPCError.applicationError(
                    "Failed to promote \(patterns.count) allowlist pattern(s): \(error.localizedDescription)")
            }
        },
        "refresh-tickets": { params in
            if let tracker {
                await tracker.refresh()
                return ["ok": .bool(true)]
            }
            throw DaemonRPCError.applicationError("Refreshing tickets requires a provider-configured daemon")
        },
        "refresh-allowlist": { _ in
            if let allowList {
                await MainActor.run { allowList.scan() }
                return ["ok": .bool(true)]
            }
            throw DaemonRPCError.applicationError(
                "Refreshing the allowlist requires a daemon with the allowlist service")
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
                    // What the auto-merge watcher decided about this PR — a
                    // SIBLING of `pr`, not a member of it. `pr` mirrors what the
                    // forge says about the pull request; this is what *Crow*
                    // decided about it, and the two have different lifetimes: a
                    // PR missing from the viewer fetch has no `prStatus` at all,
                    // yet that absence is itself a verdict worth showing (#888).
                    // Absent key means "nothing to report", which is also what
                    // every pre-#888 daemon sends — so old clients degrade to
                    // the persisted `auto_merge` bool on `list-sessions`.
                    if let autoMerge = appState.autoMergeState[id] {
                        entry["auto_merge_state"] = .object([
                            "phase": .string(autoMerge.phase.rawValue),
                            "reason": .string(autoMerge.reason),
                            "message": .string(autoMerge.message),
                            "permanent": .bool(autoMerge.permanent),
                        ])
                    }
                    // What the auto-rebase watcher decided about this branch
                    // (#944). Same sibling-of-`pr` contract as `auto_merge_state`
                    // above, and for a sharper reason: `prStatusJSON` never ships
                    // `mergeStateStatus`, so a PR that is BEHIND its base is
                    // invisible in `pr` entirely — a wedged branch renders as a
                    // fully green pill. Absent key means "nothing to report".
                    if let autoRebase = appState.autoRebaseState[id] {
                        entry["auto_rebase_state"] = .object([
                            "phase": .string(autoRebase.phase.rawValue),
                            "reason": .string(autoRebase.reason),
                            "message": .string(autoRebase.message),
                            "permanent": .bool(autoRebase.permanent),
                        ])
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

        // Private efficiency scorecard (ADR 0008; web parity #721). The web has
        // no Swift value types, so we build the ONE Core `ScorecardModel.build(...)`
        // here — off `appState.analyticsSnapshots` + `appState.prAttributions` —
        // and ship its flattened `ScorecardDTO`. Building the model server-side is
        // the single source of truth for the grade/throughput/combined/baseline —
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
                    snapshotCount: appState.analyticsSnapshots.count,
                    // Manager rollups ride alongside the model rather than
                    // through it (#767) — see `ScorecardDTO.managerWeeks`.
                    managerUsage: Array(appState.managerUsageWeekly.values),
                    // Names for the per-Manager breakdown (CROW-983). Only
                    // live sessions resolve; a deleted Manager's persisted
                    // weeks still render, just without a name.
                    managerNames: Dictionary(
                        appState.managerSessions.map { ($0.id, $0.name) },
                        uniquingKeysWith: { first, _ in first }),
                    captureStatus: appState.telemetryCaptureStatus
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

        // Manual scorecard rebuild (#745, #767) — backs the web Rebuild button,
        // the port of the desktop's `AppDelegate.rebuildScorecard()`. Backfills
        // snapshots for sessions recorded before snapshotting existed (without
        // re-running them), recomputes the ungraded Manager weekly rollups, and
        // refreshes the capture-status line. Idempotent, local-only, and a
        // no-op error when telemetry is off (there'd be no DB to read).
        "rebuild-scorecard": { _ in
            guard let rebuildScorecard else {
                throw DaemonRPCError.applicationError(
                    "Rebuilding the scorecard requires telemetry — enable it in Settings and restart crowd")
            }
            await rebuildScorecard()
            return ["rebuilt": .bool(true)]
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
            // web-password-set / gateway-set / onJobRan can't clobber this
            // write (review #10).
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

        // Secret surfaces: the web-access password and the AI gateways. The
        // browser reaches these through the local-only, Origin-checked HTTP POSTs
        // in `SecretRoutes`; the methods below are the CLI's equivalent over the
        // Unix socket (CROW-815).
        //
        // A JSON-RPC method on this shared router is *also* reachable over the
        // possibly-remote `/rpc` WebSocket, which can't tell a local caller from
        // a logged-in remote one — so each of these is listed in
        // `RPCWebSocketHandler.localOnlyDenial` and refused for non-local peers.
        // Without that gate a remote client could change the very password that
        // gates remote access (CROW-593). Reads are gated too: `gateway-get`
        // with `reveal` returns header secrets. Any new method here that touches
        // `webAuth` or a gateway MUST be added to that switch.
        //
        // The same local-direct bar applies to `set-config` changes of
        // `defaults.binaries` — those absolute binary paths execute at the next
        // launch. Scheduled `jobs` are not gated (CROW-665).
        "gateway-get": { params in
            let target = try SecretsRPC.decodeTarget(params)
            // Fail safe: a caller that omits `reveal` gets redacted values.
            let reveal = params["reveal"]?.boolValue ?? false
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            switch target {
            case .manager:
                var result = SecretsRPC.gatewayJSON(config.managerGateway, reveal: reveal)
                result["target"] = .string("manager")
                return result
            case .workspace(let ref):
                let index = try SecretsRPC.resolveWorkspace(ref, in: config)
                let workspace = config.workspaces[index]
                var result = SecretsRPC.gatewayJSON(workspace.gateway, reveal: reveal)
                result["workspace_id"] = .string(workspace.id.uuidString)
                result["workspace_name"] = .string(workspace.name)
                return result
            }
        },
        // Set or clear a gateway. `clear: true` removes it; otherwise `base_url`
        // plus at least one `header_lines` entry is required (both-or-neither).
        // A blank header value keeps the currently-stored secret, so the CLI can
        // change a base URL without restating the key.
        //
        // Writes go through `mutateConfig`, which refuses to overwrite a
        // `config.json` that exists but won't decode (CROW-814) — otherwise a
        // corrupt file plus one `crow gateway set` would silently replace every
        // workspace, job and credential with defaults.
        "gateway-set": { params in
            let target = try SecretsRPC.decodeTarget(params)
            let clear = params["clear"]?.boolValue ?? false
            let headers = clear ? nil : try SecretsRPC.decodeHeaderLines(params["header_lines"])
            let body = SecretRoutes.GatewayBody(
                baseURL: params["base_url"]?.stringValue, headers: headers, clear: clear)
            let incoming: WorkspaceGateway?
            switch SecretRoutes.buildGateway(body) {
            case .failure(let error): throw DaemonRPCError.invalidParams(error.message)
            case .success(let gateway): incoming = gateway
            }
            return try mapGatewayError {
                try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                    switch target {
                    case .manager:
                        let merged = try SecretRoutes.mergingPreservedHeaders(
                            incoming: incoming, stored: config.managerGateway).get()
                        config.managerGateway = merged
                        return ["saved": .bool(true), "gateway_set": .bool(merged != nil),
                                "target": .string("manager")]
                    case .workspace(let ref):
                        let index = try SecretsRPC.resolveWorkspace(ref, in: config)
                        let merged = try SecretRoutes.mergingPreservedHeaders(
                            incoming: incoming, stored: config.workspaces[index].gateway).get()
                        config.workspaces[index].gateway = merged
                        return ["saved": .bool(true), "gateway_set": .bool(merged != nil),
                                "workspace_id": .string(config.workspaces[index].id.uuidString),
                                "workspace_name": .string(config.workspaces[index].name)]
                    }
                }
            }
        },
        // Whether a web-access password is set, and at what PBKDF2 cost. The
        // hash and salt are never returned.
        "web-password-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return [
                "password_set": .bool(config.webAuth != nil),
                "iterations": .int(config.webAuth?.iterations ?? 0),
            ]
        },
        // Set, change, or clear the web-access password. Changing does not
        // require the old password — matching the web UI, where the local-direct
        // gate is the control. The plaintext is hashed here and never persisted.
        "web-password-set": { params in
            let clear = params["clear"]?.boolValue ?? false
            let password = params["password"]?.stringValue ?? ""
            if !clear, password.isEmpty {
                throw DaemonRPCError.invalidParams("password must be a non-empty string (or clear: true)")
            }
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                config.webAuth = clear ? nil : PasswordHash.make(password: password)
                return ["saved": .bool(true), "password_set": .bool(config.webAuth != nil)]
            }
        },

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
        // Session-lifecycle verbs, shared by the web session menu and the `crow`
        // CLI (CROW-816).
        //
        // Deliberately NOT gated on the session's *current* status: the UI's
        // active/inReview/completed conditions decide which menu items to draw,
        // not what's legal. Enforcing them would break idempotent scripting
        // (running `crow complete-session` twice must not fail).
        //
        // Moves the provider's board to In Review *and* flips the Crow session
        // (#876). Board first: a failed board move must not leave a success
        // receipt behind, exactly as `mark-issue-done` orders it. Runs on the
        // daemon's own IssueTracker — a pure provider CLI call, fully headless.
        "mark-in-review": { params in
            // Tracker guard first, matching `mark-issue-done`: a provider-less
            // daemon reports the missing capability rather than quietly
            // degrading to a status-only write — which is the exact half-action
            // this verb spent the post-ADR-0010 window performing.
            guard let tracker else {
                throw DaemonRPCError.applicationError(
                    "Marking a session in review requires a provider-configured daemon")
            }
            return try await mapRPCError {
                let id = try SessionLifecycleRPC.sessionID(from: params)
                // Preconditions (session, Manager, ticket, provider) and every
                // provider failure surface as typed `SessionActionError`s — the
                // tracker is the single source of truth for them, so there is
                // nothing to re-check here. A non-nil return is additive: the
                // board could not move, but the session transition below can.
                let warning = try await tracker.markInReview(sessionID: id)
                // The tracker moves the session via `onSetSessionInReview`,
                // which is only wired when the daemon has a SessionService
                // (`wireTerminalAutomations`) — on a no-tmux host it is nil, so
                // a transitioned board would leave the session active while we
                // returned a success receipt. Apply the transition here too:
                // idempotent when the callback already fired, and it reuses the
                // same SessionService-or-direct-write fallback as
                // `complete-session`.
                _ = try await MainActor.run {
                    try applySessionStatus(
                        id: id, to: .inReview,
                        appState: appState, store: store, sessionService: sessionService)
                }
                return SessionLifecycleRPC.statusResult(id: id, status: .inReview, warning: warning)
            }
        },
        // Provider ticket transition (close / project-board move) run on the
        // daemon's own IssueTracker — a pure provider CLI call (gh/glab/Jira/
        // Corveil), no terminal needed, fully headless (CROW-581, M-E).
        "mark-issue-done": { params in
            // Tracker guard stays first: `LocalLiveActionTests` pins that a
            // provider-less daemon reports the missing capability before it
            // bothers validating params.
            guard let tracker else {
                throw DaemonRPCError.applicationError("Marking the issue done requires a provider-configured daemon")
            }
            return try await mapRPCError {
                let id = try SessionLifecycleRPC.sessionID(from: params)
                // Preconditions and provider failures both surface as typed
                // `SessionActionError`s — the tracker is the single source of
                // truth for them, so there's nothing to re-check here.
                try await tracker.markIssueDone(sessionID: id)
                // The tracker completes the session via `onCompleteSession`,
                // which is only wired when the daemon has a SessionService
                // (`wireTerminalAutomations`) — on a no-tmux host it is nil, so
                // a closed issue would leave the session active while we
                // returned a success receipt. Apply the transition here too:
                // idempotent when the callback already fired, and it reuses the
                // same SessionService-or-direct-write fallback as
                // `complete-session`.
                _ = try await MainActor.run {
                    try applySessionStatus(
                        id: id, to: .completed,
                        appState: appState, store: store, sessionService: sessionService)
                }
                return SessionLifecycleRPC.okResult(id: id)
            }
        },
        "complete-session": { params in
            return try await mapRPCError {
                let id = try SessionLifecycleRPC.sessionID(from: params)
                return try await MainActor.run {
                    try applySessionStatus(
                        id: id, to: .completed,
                        appState: appState, store: store, sessionService: sessionService)
                }
            }
        },
        "set-session-active": { params in
            return try await mapRPCError {
                let id = try SessionLifecycleRPC.sessionID(from: params)
                return try await MainActor.run {
                    try applySessionStatus(
                        id: id, to: .active,
                        appState: appState, store: store, sessionService: sessionService)
                }
            }
        },
        // Add the `crow:merge` label to the session's PR, on the daemon's own
        // IssueTracker — a pure provider CLI call, fully headless (CROW-581, M-E).
        "add-merge-label": { params in
            guard let tracker else {
                throw DaemonRPCError.applicationError("Adding the merge label requires a provider-configured daemon")
            }
            return try await mapRPCError {
                let id = try SessionLifecycleRPC.sessionID(from: params)
                // The label really did land (a failure throws above), so `ok`
                // stays true — but a label the watcher will never act on is
                // exactly #888's silent failure, hence the additive warning.
                let warning = try await tracker.addMergeLabel(sessionID: id)
                return SessionLifecycleRPC.okResult(id: id, warning: warning)
            }
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
            try await mapRPCError {
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
                let job = try mutateConfig(devRoot: devRoot) { config -> JobConfig in
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
            try await mapRPCError {
                let id = try jobIDParam(params)
                let newSchedule = try params["schedule"].map { try JobRPC.decodeSchedule($0) }
                let newPrompts = try params["prompts"].map { try JobRPC.decodePrompts($0) }
                let job = try mutateConfig(devRoot: devRoot) { config -> JobConfig in
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
            try await mapRPCError {
                let id = try jobIDParam(params)
                let job = try mutateConfig(devRoot: devRoot) { config -> JobConfig in
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
            try await mapRPCError {
                let id = try jobIDParam(params)
                let job = try mutateConfig(devRoot: devRoot) { config -> JobConfig in
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
            try await mapRPCError {
                let id = try jobIDParam(params)
                try mutateConfig(devRoot: devRoot) { config in
                    guard config.jobs.contains(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Job not found")
                    }
                    config.jobs.removeAll { $0.id == id }
                }
                return ["deleted": .bool(true), "job_id": .string(id.uuidString)]
            }
        },
        "job-duplicate": { params in
            try await mapRPCError {
                let id = try jobIDParam(params)
                let copy = try mutateConfig(devRoot: devRoot) { config -> JobConfig in
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

        // General-tab settings for `crow telemetry` / `crow cleanup` / `crow ui`
        // (CROW-814). Granular PATCH methods rather than a CLI-side read-modify-
        // write of the whole blob: `set-config` replaces the entire `AppConfig`,
        // and CrowCLI can't decode one (it doesn't depend on CrowCore), so a blob
        // round-trip would make the CLI a second writer racing the web Settings
        // modal. Each write is a locked read-modify-write of one subtree via
        // `mutateConfig`, the same lock `set-config` and the scheduler take.
        //
        // Deliberately NOT gated in `RPCWebSocketHandler.localOnlyDenial` — see
        // the rationale ledger there.
        "telemetry-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return ["telemetry": SettingsRPC.telemetryJSON(config.telemetry)]
        },
        "telemetry-set": { params in
            try await mapRPCError {
                let enabled = try SettingsRPC.patchBool(params, "enabled")
                let port = try SettingsRPC.patchPort(params)
                let retentionDays = try SettingsRPC.patchRetentionDays(params)
                guard enabled != nil || port != nil || retentionDays != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of enabled, port, retention_days.")
                }
                let (old, new) = try mutateConfig(devRoot: devRoot) {
                    config -> (TelemetryConfig, TelemetryConfig) in
                    let before = config.telemetry
                    if let enabled { config.telemetry.enabled = enabled }
                    if let port { config.telemetry.port = port }
                    if let retentionDays { config.telemetry.retentionDays = retentionDays }
                    return (before, config.telemetry)
                }
                return [
                    "telemetry": SettingsRPC.telemetryJSON(new),
                    "restart_required": .bool(
                        SettingsRPC.telemetryRestartRequired(old: old, new: new)),
                ]
            }
        },
        "cleanup-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return ["cleanup": SettingsRPC.cleanupJSON(config.cleanup)]
        },
        "cleanup-set": { params in
            try await mapRPCError {
                let enabled = try SettingsRPC.patchBool(params, "enabled")
                let retentionHours = try SettingsRPC.patchRetentionHours(params)
                guard enabled != nil || retentionHours != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of enabled, retention_hours.")
                }
                let cleanup = try mutateConfig(devRoot: devRoot) { config -> CleanupConfig in
                    if let enabled { config.cleanup.enabled = enabled }
                    if let retentionHours { config.cleanup.retentionHours = retentionHours }
                    return config.cleanup
                }
                // The board poll re-reads config from disk every cycle, so this
                // takes effect within ~60s — no restart.
                return [
                    "cleanup": SettingsRPC.cleanupJSON(cleanup),
                    "restart_required": .bool(false),
                ]
            }
        },
        "ui-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return ["ui": SettingsRPC.uiJSON(sidebar: config.sidebar, switcher: config.switcher)]
        },
        "ui-set": { params in
            try await mapRPCError {
                let hideSessionDetails = try SettingsRPC.patchBool(params, "hide_session_details")
                let switcherEnabled = try SettingsRPC.patchBool(params, "switcher_enabled")
                let switcherBinding = try SettingsRPC.patchNonEmptyString(params, "switcher_binding")
                let switcherCapture = try SettingsRPC.patchBool(params, "switcher_capture_in_terminal")
                let switcherOrder = try SettingsRPC.patchSwitcherOrder(params)
                let switcherPreview = try SettingsRPC.patchBool(params, "switcher_preview")
                let includePatches = try SettingsRPC.patchSwitcherIncludeKey(params)
                // Reject the chord agents reserve rather than storing it and
                // rewriting it on the next decode — a silent revert leaves the
                // user with no idea why their setting didn't stick (CROW-1002).
                if let switcherBinding, SwitcherSettings.isReservedBinding(switcherBinding) {
                    throw RPCError.invalidParams(
                        "Switcher binding '\(switcherBinding)' is reserved: coding agents cycle "
                        + "permission modes with Shift+Tab, and the switcher would swallow it in "
                        + "every focused terminal. Pick another chord (default: "
                        + "\(SwitcherSettings.defaultBinding)).")
                }
                guard hideSessionDetails != nil || switcherEnabled != nil || switcherBinding != nil
                    || switcherCapture != nil || switcherOrder != nil || switcherPreview != nil
                    || !includePatches.isEmpty else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one UI preference flag.")
                }
                let (sidebar, switcher) = try mutateConfig(devRoot: devRoot) {
                    config -> (SidebarSettings, SwitcherSettings) in
                    if let hideSessionDetails {
                        config.sidebar.hideSessionDetails = hideSessionDetails
                    }
                    if let switcherEnabled { config.switcher.enabled = switcherEnabled }
                    if let switcherBinding { config.switcher.binding = switcherBinding }
                    if let switcherCapture {
                        config.switcher.captureInTerminal = switcherCapture
                    }
                    if let switcherOrder { config.switcher.order = switcherOrder }
                    if let switcherPreview { config.switcher.preview = switcherPreview }
                    for (path, value) in includePatches {
                        config.switcher.include[keyPath: path] = value
                    }
                    return (config.sidebar, config.switcher)
                }
                // Connected browsers re-read the view-affecting config slice off
                // the `configReloaded` push that `startStoreReloadPoll` fires when
                // config.json's mtime moves — no restart, no reload.
                return [
                    "ui": SettingsRPC.uiJSON(sidebar: sidebar, switcher: switcher),
                    "restart_required": .bool(false),
                ]
            }
        },

        // Version update check (CROW-938) — `crow version get|set|--check`.
        "version-update-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let status = await versionUpdateService?.cachedStatus
            return [
                "version_update": VersionUpdateRPC.configJSON(config.versionUpdate),
                "status": VersionUpdateRPC.statusJSON(status),
            ]
        },
        "version-update-set": { params in
            try await mapRPCError {
                let enabled = try SettingsRPC.patchBool(params, "enabled")
                let intervalHours = try VersionUpdateRPC.patchIntervalHours(params)
                guard enabled != nil || intervalHours != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of enabled, interval_hours.")
                }
                let versionUpdate = try mutateConfig(devRoot: devRoot) { config -> VersionUpdateConfig in
                    if let enabled { config.versionUpdate.enabled = enabled }
                    if let intervalHours {
                        config.versionUpdate.intervalHours = max(
                            VersionUpdateConfig.minimumIntervalHours, intervalHours)
                    }
                    return config.versionUpdate
                }
                return [
                    "version_update": VersionUpdateRPC.configJSON(versionUpdate),
                    "saved": .bool(true),
                ]
            }
        },
        "version-update-check": { params in
            let force = params["force"]?.boolValue ?? false
            guard let versionUpdateService else {
                return ["status": VersionUpdateRPC.statusJSON(nil)]
            }
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let status: VersionUpdateStatus?
            if force {
                status = await versionUpdateService.runCheck()
            } else {
                status = await versionUpdateService.checkIfDue(
                    enabled: config.versionUpdate.enabled,
                    intervalHours: config.versionUpdate.intervalHours,
                    force: false)
            }
            return ["status": VersionUpdateRPC.statusJSON(status)]
        },

        // Settings → Automation for `crow automation` (CROW-812). Same shape and
        // the same `mutateConfig` lock as the CROW-814 settings verbs above, and
        // likewise un-gated on remote `/rpc` — see the ledger in
        // `RPCWebSocketHandler.localOnlyDenial`.
        //
        // Writes the twelve booleans only. The Automation tab also renders three
        // board-filter lists, but those are `AppConfig.defaults` fields owned by
        // `defaults-set` (CROW-810) — two writers for one field with two sets of
        // list semantics is exactly the drift the parity work exists to prevent.
        // `automation-get` echoes them read-only so the tab still reads as a
        // whole from one call.
        //
        // Writing config is the *whole* job here: flipping one of these in the
        // web Settings modal has no side effect either (`toggleField`'s onchange
        // only marks the form dirty), because every consumer pulls from disk —
        // `applyConfigToAppState` re-runs each board tick, the `IssueTracker`
        // watcher gates are closures that reload config on every call, and
        // `AutoRespondCoordinator` takes a `settingsProvider` closure.
        "automation-get": { _ in
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return ["automation": SettingsRPC.automationJSON(config, configReadable: readable)]
        },
        "automation-set": { params in
            try await mapRPCError {
                let remoteControl = try SettingsRPC.patchBool(params, "remote_control_enabled")
                let managerMode = try SettingsRPC.patchBool(
                    params, "manager_auto_permission_mode")
                let reviewMode = try SettingsRPC.patchBool(params, "review_auto_permission_mode")
                let coderViewMode = try SettingsRPC.patchBool(
                    params, "coder_view_auto_permission_mode")
                let jobsMode = try SettingsRPC.patchBool(params, "jobs_auto_permission_mode")
                let trailers = try SettingsRPC.patchBool(params, "attribution_trailers")
                let autoCreate = try SettingsRPC.patchBool(params, "auto_create_watcher_enabled")
                let autoMerge = try SettingsRPC.patchBool(params, "auto_merge_watcher_enabled")
                let changesRequested = try SettingsRPC.patchBool(
                    params, "respond_to_changes_requested")
                let failedChecks = try SettingsRPC.patchBool(params, "respond_to_failed_checks")
                let autoRebase = try SettingsRPC.patchBool(
                    params, "auto_rebase_and_resolve_conflicts")
                let autoReRequest = try SettingsRPC.patchBool(params, "auto_re_request_review")

                let booleans = [
                    remoteControl, managerMode, reviewMode, coderViewMode, jobsMode, trailers,
                    autoCreate, autoMerge, changesRequested, failedChecks, autoRebase,
                    autoReRequest,
                ]
                guard booleans.contains(where: { $0 != nil }) else {
                    throw RPCError.invalidParams("Nothing to set — provide at least one field")
                }

                let (config, managerModeChanged) = try mutateConfig(devRoot: devRoot) {
                    config -> (AppConfig, Bool) in
                    let managerModeBefore = config.managerAutoPermissionMode
                    if let remoteControl { config.remoteControlEnabled = remoteControl }
                    if let managerMode { config.managerAutoPermissionMode = managerMode }
                    if let reviewMode { config.reviewAutoPermissionMode = reviewMode }
                    if let coderViewMode { config.coderViewAutoPermissionMode = coderViewMode }
                    if let jobsMode { config.jobsAutoPermissionMode = jobsMode }
                    if let trailers { config.attributionTrailers = trailers }
                    if let autoCreate { config.autoCreateWatcherEnabled = autoCreate }
                    if let autoMerge { config.autoMergeWatcherEnabled = autoMerge }
                    if let changesRequested {
                        config.autoRespond.respondToChangesRequested = changesRequested
                    }
                    if let failedChecks {
                        config.autoRespond.respondToFailedChecks = failedChecks
                    }
                    if let autoRebase {
                        config.autoRespond.autoRebaseAndResolveConflicts = autoRebase
                    }
                    if let autoReRequest {
                        config.autoRespond.autoReRequestReview = autoReRequest
                    }
                    return (config, managerModeBefore != config.managerAutoPermissionMode)
                }
                return [
                    "automation": SettingsRPC.automationJSON(config),
                    // `crowd` never needs a restart for any of these — reported
                    // for symmetry with the other settings verbs.
                    "restart_required": .bool(false),
                    // `managerAutoPermissionMode` is the one exception to the
                    // "everything re-reads from disk" rule: it is baked into the
                    // Manager terminal's stored shell command by
                    // `SessionService.managerCommand(for:)` and only re-read on a
                    // Manager rebuild. Reported only when the value actually
                    // moved, so re-setting it to what it already was doesn't nag.
                    "manager_restart_required": .bool(managerModeChanged),
                ]
            }
        },

        // Notification settings for `crow notifications` (CROW-813). Same
        // `AppConfig.notifications` subtree the web Settings → Notifications tab
        // edits; the write goes through the shared config lock, and the daemon's
        // mtime poll broadcasts `configReloaded` so an open tab refreshes.
        // Un-gated on remote `/rpc` for the same reason as `job-*`: this is a
        // core web-Settings surface carrying no secrets
        // (see `RPCWebSocketHandler.localOnlyDenial`).
        "notifications-get": { params in
            try await mapRPCError {
                let event = try params["event"].map { try NotificationRPC.decodeEvent($0) }
                let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
                return ["notifications": NotificationRPC.settingsJSON(
                    config.notifications, only: event, configReadable: readable)]
            }
        },
        "notifications-set": { params in
            try await mapRPCError {
                let globalMute = params["global_mute"]?.boolValue
                let soundEnabled = params["sound_enabled"]?.boolValue
                let systemNotificationsEnabled = params["system_notifications_enabled"]?.boolValue
                let event = try params["event"].map { try NotificationRPC.decodeEvent($0) }
                let eventEnabled = params["event_enabled"]?.boolValue
                let eventSoundEnabled = params["event_sound_enabled"]?.boolValue
                let eventSystemEnabled = params["event_system_notification_enabled"]?.boolValue
                let eventSoundName = try params["event_sound_name"].map {
                    try NotificationRPC.decodeSoundName($0)
                }

                let hasEventField = eventEnabled != nil || eventSoundEnabled != nil
                    || eventSystemEnabled != nil || eventSoundName != nil
                let hasGlobalField = globalMute != nil || soundEnabled != nil
                    || systemNotificationsEnabled != nil
                if event == nil, hasEventField {
                    throw RPCError.invalidParams("event is required when setting any event_* field")
                }
                if event != nil, !hasEventField {
                    throw RPCError.invalidParams(
                        "event given with nothing to change — provide at least one event_* field")
                }
                guard hasGlobalField || hasEventField else {
                    throw RPCError.invalidParams("Nothing to set — provide at least one field")
                }

                let settings = try mutateConfig(devRoot: devRoot) { config -> NotificationSettings in
                    if let globalMute { config.notifications.globalMute = globalMute }
                    if let soundEnabled { config.notifications.soundEnabled = soundEnabled }
                    if let systemNotificationsEnabled {
                        config.notifications.systemNotificationsEnabled = systemNotificationsEnabled
                    }
                    if let event {
                        // Read through `config(for:)`, which supplies the event's
                        // defaults when it's absent from disk — the common case,
                        // since most configs predate the automation events. A
                        // `eventSettings[event]?.enabled = x` subscript write
                        // would be a silent no-op there. Only the event being
                        // written is materialized: freezing all ten in on a
                        // one-field edit would opt the user out of future
                        // `defaultSound` changes.
                        var eventConfig = config.notifications.config(for: event)
                        if let eventEnabled { eventConfig.enabled = eventEnabled }
                        if let eventSoundEnabled { eventConfig.soundEnabled = eventSoundEnabled }
                        if let eventSystemEnabled {
                            eventConfig.systemNotificationEnabled = eventSystemEnabled
                        }
                        if let eventSoundName { eventConfig.soundName = eventSoundName }
                        config.notifications.eventSettings[event] = eventConfig
                    }
                    return config.notifications
                }
                return [
                    "notifications": NotificationRPC.settingsJSON(settings, only: event),
                    "saved": .bool(true),
                ]
            }
        },

        // Workspace/automation defaults for `crow defaults` (CROW-810) — the
        // `AppConfig.defaults` subtree behind Settings → Workspaces (provider,
        // branch prefix), → Automation (the review/ticket exclude lists) and
        // → General (the corveil binary path).
        //
        // This is the one granular settings verb that can reach
        // `defaults.binaries`, so `defaults-set` IS gated in
        // `RPCWebSocketHandler.localOnlyDenial` — but only when the request
        // carries a `binaries` param. `defaults-get` is un-gated; see the
        // rationale ledger there.
        "defaults-get": { _ in
            // `loadConfigReportingReadability`, not the bare
            // `loadConfig ?? AppConfig()` the telemetry/cleanup/ui gets use:
            // `ConfigStore.loadConfig` returns nil both for "no config yet"
            // (the defaults really do apply) and "present but undecodable" (they
            // are a fiction). Someone debugging why an exclude list isn't
            // working must not be shown an invented empty list as fact.
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return [
                "defaults": DefaultsRPC.defaultsJSON(config.defaults),
                "config_readable": .bool(readable),
            ]
        },
        "defaults-set": { params in
            try await mapRPCError {
                let provider = try DefaultsRPC.patchProvider(params)
                let cli = try DefaultsRPC.patchCLI(params)
                let branchPrefix = try DefaultsRPC.patchBranchPrefix(params)
                let binaries = try DefaultsRPC.patchBinaries(params)
                let excludeReviewRepos =
                    try DefaultsRPC.patchStringList(params, "exclude_review_repos")
                let excludeTicketRepos =
                    try DefaultsRPC.patchStringList(params, "exclude_ticket_repos")
                let ignoreReviewLabels =
                    try DefaultsRPC.patchStringList(params, "ignore_review_labels")

                guard provider != nil || cli != nil || branchPrefix != nil || binaries != nil
                        || excludeReviewRepos != nil || excludeTicketRepos != nil
                        || ignoreReviewLabels != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of provider, cli, branch_prefix, "
                      + "binaries, or an add_/remove_/clear_ param for a list.")
                }

                let (old, new) = try mutateConfig(devRoot: devRoot) {
                    config -> (ConfigDefaults, ConfigDefaults) in
                    let before = config.defaults
                    if let provider { config.defaults.provider = provider }
                    if let cli { config.defaults.cli = cli }
                    if let branchPrefix { config.defaults.branchPrefix = branchPrefix }
                    if let binaries {
                        config.defaults.binaries =
                            DefaultsRPC.mergeBinaries(binaries, into: config.defaults.binaries)
                    }
                    if let patch = excludeReviewRepos {
                        config.defaults.excludeReviewRepos =
                            patch.apply(to: config.defaults.excludeReviewRepos)
                    }
                    if let patch = excludeTicketRepos {
                        config.defaults.excludeTicketRepos =
                            patch.apply(to: config.defaults.excludeTicketRepos)
                    }
                    if let patch = ignoreReviewLabels {
                        config.defaults.ignoreReviewLabels =
                            patch.apply(to: config.defaults.ignoreReviewLabels)
                    }
                    return (before, config.defaults)
                }

                return [
                    "defaults": DefaultsRPC.defaultsJSON(new),
                    "saved": .bool(true),
                    "restart_required": .bool(DefaultsRPC.restartRequired(old: old, new: new)),
                    // Both advisories are always present — like `promotionJSON`'s
                    // `added`/`already_global` — so a scripted caller can test
                    // them without a key-presence dance.
                    "binaries_not_executable": .array(
                        nonExecutableBinaryPaths(binaries ?? [:]).map { .string($0) }),
                    "provider_cli_mismatch": .bool(
                        DefaultsRPC.providerCLIMismatch(provider: new.provider, cli: new.cli)),
                ]
            }
        },

        // Agent selection for `crow agents` (CROW-811) — `AppConfig.defaultAgentKind`
        // and `AppConfig.agentsByKind`, the Settings → General "Agent" group. Same
        // locked read-modify-write as the settings verbs above. No
        // `restart_required`: the board tick calls `applyConfigToAppState` ->
        // `AppState.applyAgentConfig`, so a change is live within one poll.
        //
        // Distinct from `list-agents` further up, which answers "what harnesses are
        // registered in this process" and returns `agents` as an *array*. Its
        // per-agent `default` flag is the *registry* default (first-registered);
        // `default_agent_kind` here is the *configured* default. `available`
        // deliberately carries no such field so the two can't be read as one thing.
        //
        // Un-gated in `RPCWebSocketHandler.localOnlyDenial` for the same reason as
        // `notifications-*`: agent kinds carry no secrets, and a remote peer can
        // already change both fields through the un-gated `set-config` blob.
        "agents-get": { _ in
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return ["agents": AgentsRPC.agentsJSON(
                config, available: knownAgents(), configReadable: readable)]
        },
        "agents-set": { params in
            try await mapRPCError {
                // One snapshot for the whole call, so the gate that rejects a kind
                // and the `available` list echoed back can't disagree mid-flight.
                let available = knownAgents()
                let defaultKind = try AgentsRPC.decodeDefaultAgentKind(params, available: available)
                let setting = try AgentsRPC.decodeByKind(params, available: available)
                let clearing = try AgentsRPC.decodeClear(params)
                // Conflict before emptiness: a call carrying both a value and a
                // clear for the same role passes the emptiness check, so the
                // generic message would bury the actual mistake.
                try AgentsRPC.validateNoClearConflict(setting: setting, clearing: clearing)
                guard defaultKind != nil || !setting.isEmpty || !clearing.isEmpty else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of default_agent_kind, by_kind, clear.")
                }
                // Every decode above throws before `mutateConfig` is entered, so a
                // rejected kind or role leaves config.json untouched — no lock
                // taken, no partial write, no mtime bump.
                let config = try mutateConfig(devRoot: devRoot) { config -> AppConfig in
                    if let defaultKind { config.defaultAgentKind = defaultKind }
                    AgentsRPC.applyByKind(
                        &config.agentsByKind, setting: setting, clearing: clearing)
                    return config
                }
                return [
                    "agents": AgentsRPC.agentsJSON(config, available: available),
                    "saved": .bool(true),
                ]
            }
        },
    ]
    handlers.merge(makeWorkspaceHandlers(appState: appState, devRoot: devRoot)) { existing, _ in existing }
    handlers.merge(makeMCPTokenHandlers(devRoot: devRoot)) { existing, _ in existing }
    return CommandRouter(handlers: handlers, fallback: fallback)
}

/// The `mcp-token-*` verb group (CROW-1004).
///
/// In its own function for the reason stated on the main `handlers` literal above:
/// that dictionary is already ~65 closures in one expression, and adding a group
/// inline blows the type checker's solver budget. `makeWorkspaceHandlers` set the
/// precedent. It must stay in **this file** regardless, because
/// `scripts/check-cli-parity.sh` greps `RPCHandlers.swift` for handler
/// registrations and would not see a new file.
///
/// All three are local-only on `/rpc`
/// (``RPCWebSocketHandler/localOnlyDenial(for:devRoot:)``): `mcp-token-mint` returns
/// the plaintext token exactly once, so a remote peer able to call it would be
/// minting itself the credential that gates remote MCP access. `mcp-token-list`
/// carries no secret but is gated alongside them, matching `web-password-get`.
///
/// These are **not** MCP-exported. The MCP surface is read-only and reaches only
/// `MCPToolCatalog`'s allowlist; `MCPLedgerExportTests` asserts that the exported
/// set and `ParityLedger.localOnlyRPCMethods` are disjoint.
private func makeMCPTokenHandlers(devRoot: String) -> [String: CommandRouter.Handler] {
    [
        "mcp-token-list": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let now = Date()
            return [
                "tokens": .array(config.mcpTokens.map { .object($0.publicJSON(now: now)) }),
                "count": .int(config.mcpTokens.count),
            ]
        },
        // Mint a token. The plaintext is in the response and nowhere else — not in
        // config.json, not in the daemon log. A caller that loses it mints another.
        // Validation and expiry resolution live in `MCPTokenRPC` so this and the
        // browser's `POST /config/mcp-tokens` cannot drift.
        "mcp-token-mint": { params in
            let minted: MCPTokenStore.Minted
            do {
                minted = try MCPTokenRPC.mint(
                    name: params["name"]?.stringValue ?? "",
                    rawScopes: (params["scopes"]?.arrayValue ?? []).compactMap(\.stringValue),
                    noExpiry: params["no_expiry"]?.boolValue ?? false,
                    expiresInSeconds: params["expires_in_seconds"]?.intValue)
            } catch let error as MCPTokenRPC.Invalid {
                throw DaemonRPCError.invalidParams(error.message)
            }
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                config.mcpTokens.append(minted.record)
                return MCPTokenRPC.mintedJSON(minted)
            }
        },
        // Revoke by id, or by name when the name is unambiguous.
        "mcp-token-revoke": { params in
            let id = params["id"]?.stringValue
            let name = params["name"]?.stringValue
            return try mutateConfig(devRoot: devRoot) { config -> [String: JSONValue] in
                let removed: MCPTokenRecord
                do {
                    removed = try MCPTokenRPC.tokenToRevoke(id: id, name: name, in: config.mcpTokens)
                } catch let error as MCPTokenRPC.Invalid {
                    throw RPCError.invalidParams(error.message)
                }
                config.mcpTokens.removeAll { $0.id == removed.id }
                return [
                    "revoked": .bool(true),
                    "id": .string(removed.id.uuidString),
                    "name": .string(removed.name),
                    "remaining": .int(config.mcpTokens.count),
                ]
            }
        },
    ]
}

/// Paths this call just set that aren't executable right now.
///
/// Advisory only: pointing at a tool you haven't installed yet is a legitimate
/// flow, and `Scaffolder` already skips a non-executable target rather than
/// failing the scaffold. But its only signal today is an `NSLog` in the daemon's
/// stderr, which a CLI user never sees — so a typo'd path would otherwise land
/// as an unqualified `{"saved": true}`.
///
/// Only the paths this call SET are checked: a pre-existing broken entry
/// shouldn't generate noise on an unrelated `--provider` write. Lives here
/// rather than in `DefaultsRPC` because it touches disk, and that enum's
/// contract — like `SettingsRPC`'s — is "no socket, no disk".
private func nonExecutableBinaryPaths(_ patch: [String: String]) -> [String] {
    let fm = FileManager.default
    return patch.values.filter { !$0.isEmpty && !fm.isExecutableFile(atPath: $0) }.sorted()
}

/// Snapshot this process's known agents for the `agents-*` handlers.
///
/// Reuses `AgentRegistry.agentListings()` — the shared projection #879/#880 added
/// so every surface serializes one contract — rather than re-deriving the roster.
/// That means `crow agents list` shows the same five rows the web pickers do,
/// each carrying `available`, instead of silently omitting an off-PATH agent
/// (the exact complaint #879 filed against the web).
///
/// Availability rides along per row rather than filtering the list: the launch
/// gate stays `available == true` (an unavailable kind never enters the
/// registry's launchable map, so `registeredKind`/`agent(for:)` still refuse
/// it), but a caller can now see that Antigravity exists and needs installing.
///
/// No `MainActor.run` hop, unlike the neighbouring `list-agents`: `AgentRegistry`
/// is `@unchecked Sendable` behind its own `NSLock` and `CodingAgent` is
/// `Sendable`, so nothing here is main-actor bound. Kept a named function rather
/// than inlined twice so a future `@MainActor` on `CodingAgent` has exactly one
/// place to break.
private func knownAgents() -> [AgentsRPC.KnownAgent] {
    AgentRegistry.shared.agentListings().map {
        AgentsRPC.KnownAgent(
            kind: $0.kind, name: $0.displayName, binary: $0.binary, available: $0.available)
    }
}

/// The `workspace-*` methods, kept in their own function rather than added to
/// `makeCommandRouter`'s dictionary literal above.
///
/// That is a compile-time constraint, not taste: the literal is ~65 closures in
/// one expression, and appending these five pushed Swift's type checker past its
/// solver budget ("unable to type-check this expression in reasonable time") on
/// an unrelated line. Splitting the literal gives each half its own inference
/// problem. Any further verb group should get the same treatment.
///
/// Workspace management for `crow workspace` (CROW-809) — the same
/// `AppConfig.workspaces` array the web Settings → Workspaces tab edits, but
/// per-workspace rather than whole-blob: `set-config` ships every workspace,
/// job, gateway URL and credential shell over the wire to change one field, and
/// CrowCLI can't author an `AppConfig` anyway.
///
/// These are the first production callers of `WorkspaceInfo.validateName` — the
/// Settings form checks only "non-blank", so duplicate and path-unsafe names
/// have been persistable all along.
///
/// Deliberately NOT gated in `RPCWebSocketHandler.localOnlyDenial`; the gateway
/// credential is excluded from every payload here. See the ledger there.
private func makeWorkspaceHandlers(
    appState: AppState, devRoot: String
) -> [String: CommandRouter.Handler] {
    [
        "workspace-list": { _ in
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return [
                "workspaces": .array(config.workspaces.map(WorkspaceRPC.workspaceJSON)),
                "config_readable": .bool(readable),
            ]
        },
        "workspace-get": { params in
            try await mapRPCError {
                let ref = try workspaceRefParam(params)
                let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                return ["workspace": WorkspaceRPC.workspaceJSON(config.workspaces[index])]
            }
        },
        "workspace-add": { params in
            try await mapRPCError {
                guard let rawName = try WorkspaceRPC.patchString(params, "name") else {
                    throw RPCError.invalidParams("name is required")
                }
                let workspace = try mutateConfig(devRoot: devRoot) { config -> WorkspaceInfo in
                    let name = try WorkspaceRPC.validateName(rawName, in: config)
                    // Built from the memberwise init so a new workspace starts at
                    // the model's documented defaults, then patched — rather than
                    // assembling it field by field here, which would silently miss
                    // any field added to `WorkspaceInfo` later.
                    var workspace = WorkspaceInfo(name: name)
                    try WorkspaceRPC.applyPatch(params, to: &workspace, name: name)
                    config.workspaces.append(workspace)
                    return workspace
                }
                return ["workspace": WorkspaceRPC.workspaceJSON(workspace), "saved": .bool(true)]
            }
        },
        "workspace-edit": { params in
            try await mapRPCError {
                let ref = try workspaceRefParam(params)
                guard WorkspaceRPC.hasAnyField(params) else {
                    throw RPCError.invalidParams("Nothing to edit — provide at least one field")
                }
                let force = try WorkspaceRPC.flag(params, "force")

                // The rename guard needs AppState (session worktrees), which is
                // main-actor; resolve and count before taking the config lock so
                // no hop happens inside it. This pre-flight read decides whether
                // to guard and gives fast rejection — the authoritative name
                // check runs again under the lock below.
                let rawName = try WorkspaceRPC.patchString(params, "name")
                let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                let current = config.workspaces[index]
                let newName = try rawName
                    .map { try WorkspaceRPC.validateName($0, in: config, excludingID: current.id) }
                let renaming = newName.map { $0 != current.name } ?? false

                var references = (sessions: 0, jobs: 0)
                if renaming {
                    references = await MainActor.run {
                        workspaceReferences(
                            to: current.name, appState: appState, config: config, devRoot: devRoot)
                    }
                    if !force, let denial = workspaceReferenceDenial(
                        references, verb: "Renaming", name: current.name, devRoot: devRoot) {
                        throw RPCError.invalidParams(denial)
                    }
                }

                let (changed, workspace) = try mutateConfigIfChanged(devRoot: devRoot) {
                    config -> (changed: Bool, value: WorkspaceInfo) in
                    // Re-resolve *and* re-validate under the lock: another writer
                    // may have reordered the array or claimed the new name since
                    // the pre-flight read above, and name uniqueness is only
                    // meaningful against the config actually being written.
                    let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                    let name = try rawName.map {
                        try WorkspaceRPC.validateName(
                            $0, in: config, excludingID: config.workspaces[index].id)
                    }
                    let changed = try WorkspaceRPC.applyPatch(
                        params, to: &config.workspaces[index], name: name)
                    return (changed, config.workspaces[index])
                }

                var result: [String: JSONValue] = [
                    "workspace": WorkspaceRPC.workspaceJSON(workspace),
                    "saved": .bool(changed),
                ]
                if renaming {
                    result["renamed_from"] = .string(current.name)
                    result["orphaned_sessions"] = .int(references.sessions)
                    result["orphaned_jobs"] = .int(references.jobs)
                }
                return result
            }
        },
        "workspace-remove": { params in
            try await mapRPCError {
                let ref = try workspaceRefParam(params)
                let force = try WorkspaceRPC.flag(params, "force")

                let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
                let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                let current = config.workspaces[index]
                let references = await MainActor.run {
                    workspaceReferences(
                        to: current.name, appState: appState, config: config, devRoot: devRoot)
                }
                if !force, let denial = workspaceReferenceDenial(
                    references, verb: "Removing", name: current.name, devRoot: devRoot) {
                    throw RPCError.invalidParams(denial)
                }

                let removed = try mutateConfig(devRoot: devRoot) { config -> WorkspaceInfo in
                    let index = try WorkspaceRPC.resolveIndex(ref, in: config)
                    return config.workspaces.remove(at: index)
                }
                return [
                    "removed": .bool(true),
                    "id": .string(removed.id.uuidString),
                    "name": .string(removed.name),
                    // Removal drops the config entry only — `{devRoot}/{name}/`
                    // and its worktrees stay on disk, same as the web UI.
                    "worktree_dir_kept": .string("\(devRoot)/\(removed.name)"),
                    // The workspace's AI-gateway credential goes with it; there is
                    // no undo, so say so rather than letting it vanish quietly.
                    "gateway_discarded": .bool(!(removed.gateway?.isEmpty ?? true)),
                    "orphaned_sessions": .int(references.sessions),
                    "orphaned_jobs": .int(references.jobs),
                ]
            }
        },
    ]
}
/// Load the config, reporting whether it was actually readable.
///
/// `ConfigStore.loadConfig` returns nil both for "no config yet" (defaults really
/// do apply) and for "present but undecodable" (the defaults are a fiction).
/// `notifications-get` passes the distinction through as `config_readable` so a
/// caller isn't shown invented settings as fact (CROW-813).
private func loadConfigReportingReadability(devRoot: String) -> (AppConfig, Bool) {
    if let config = ConfigStore.loadConfig(devRoot: devRoot) { return (config, true) }
    return (AppConfig(), !ConfigStore.configExists(devRoot: devRoot))
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

/// Persist an `AppConfig` mutation under the shared lock. Disk write first so a
/// failed save leaves memory and disk consistent.
///
/// A `config.json` that exists but won't decode is NOT replaced with defaults:
/// `ConfigStore.loadConfig` returns nil for both "missing" and "malformed", and
/// blindly falling back to `AppConfig()` would silently destroy every workspace,
/// job and credential on the next write (CROW-814, found independently by
/// CROW-813 — the notifications verbs are callers too).
@discardableResult
private func mutateConfig<T>(devRoot: String, _ transform: (inout AppConfig) throws -> T) throws -> T {
    try ConfigStore.withConfigLock {
        var config: AppConfig
        if let loaded = ConfigStore.loadConfig(devRoot: devRoot) {
            config = loaded
        } else if ConfigStore.configExists(devRoot: devRoot) {
            throw RPCError.applicationError(
                "config.json exists but could not be decoded — refusing to overwrite it. Fix or move \(ConfigStore.configURL(devRoot: devRoot).path).")
        } else {
            config = AppConfig()
        }
        let result = try transform(&config)
        do {
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        } catch {
            throw RPCError.applicationError("Failed to persist config change: \(error.localizedDescription)")
        }
        return result
    }
}

/// Like ``mutateConfig(devRoot:_:)`` but skips the disk write when `transform`
/// reports that nothing changed.
///
/// `workspace-edit` takes ~20 optional field flags, so re-running the same
/// invocation (a script converging config, say) is the expected case rather than
/// an odd one. Writing anyway would bump `config.json`'s mtime and fire a
/// "Config reloaded" chime in every open browser for a change that isn't one —
/// the same spurious-notification hazard the settings verbs avoid by rejecting
/// an empty patch. Rejecting isn't right here: the user *did* pass flags, they
/// just already held.
private func mutateConfigIfChanged<T>(
    devRoot: String, _ transform: (inout AppConfig) throws -> (changed: Bool, value: T)
) throws -> (changed: Bool, value: T) {
    try ConfigStore.withConfigLock {
        var config: AppConfig
        if let loaded = ConfigStore.loadConfig(devRoot: devRoot) {
            config = loaded
        } else if ConfigStore.configExists(devRoot: devRoot) {
            throw RPCError.applicationError(
                "config.json exists but could not be decoded — refusing to overwrite it. Fix or move \(ConfigStore.configURL(devRoot: devRoot).path).")
        } else {
            config = AppConfig()
        }
        let result = try transform(&config)
        guard result.changed else { return result }
        do {
            try ConfigStore.saveConfig(config, devRoot: devRoot)
        } catch {
            throw RPCError.applicationError("Failed to persist config change: \(error.localizedDescription)")
        }
        return result
    }
}

/// Parse the `workspace: "<name|uuid>"` selector shared by every `workspace-*`
/// method that addresses an existing workspace.
private func workspaceRefParam(_ params: [String: JSONValue]) throws -> String {
    let ref = params["workspace"]?.stringValue?.trimmingCharacters(in: .whitespaces) ?? ""
    guard !ref.isEmpty else {
        throw RPCError.invalidParams("workspace is required (a workspace name or UUID)")
    }
    return ref
}

/// Count what renaming or removing workspace `name` would orphan.
///
/// Nothing holds a workspace *id*: a session is tied to its workspace only by
/// its worktree living at `{devRoot}/{workspace}/{repo}`, and a job only by the
/// `job.workspace` string. So a rename silently breaks gateway resolution
/// (`SessionService.workspaceGatewayResolved`), code-provider detection (which
/// falls back to GitHub), and job launches — while `Scaffolder` creates a fresh
/// empty directory beside the old populated one. Hence the `--force` gate on
/// both verbs (CROW-809).
///
/// Sessions compare case-insensitively because the on-disk folder's case is the
/// filesystem's to decide; jobs compare exactly, matching `validateJobWorkspace`
/// — a job whose case already differs is already orphaned, not orphaned by this.
///
/// **Best-effort, by design.** The count is taken *before* `withConfigLock`, so a
/// session or job created in the window between counting and writing is orphaned
/// without ever tripping the guard. Closing that would mean re-counting under the
/// lock, and the count reads `AppState` — a main-actor hop inside a held
/// `NSLock`, which is exactly the shape that wedges the daemon (#874). The guard
/// exists to stop a user renaming a workspace they can see is in use, not to be a
/// transactional invariant; a rename racing a session launch is not a case worth
/// deadlock risk to catch. The returned counts are likewise a snapshot.
@MainActor
private func workspaceReferences(
    to name: String, appState: AppState, config: AppConfig, devRoot: String
) -> (sessions: Int, jobs: Int) {
    let lowered = name.lowercased()
    let sessions = appState.worktrees.values.filter { worktrees in
        worktrees.contains {
            SessionService.workspaceName(forWorktreePath: $0.worktreePath, devRoot: devRoot)?
                .lowercased() == lowered
        }
    }.count
    return (sessions, config.jobs.filter { $0.workspace == name }.count)
}

/// Render the reference counts as a refusal, or nil when nothing is referenced.
private func workspaceReferenceDenial(
    _ references: (sessions: Int, jobs: Int), verb: String, name: String, devRoot: String
) -> String? {
    guard references.sessions > 0 || references.jobs > 0 else { return nil }
    var parts: [String] = []
    if references.sessions > 0 {
        parts.append("\(references.sessions) session\(references.sessions == 1 ? "" : "s") (worktrees stay under \(devRoot)/\(name)/)")
    }
    if references.jobs > 0 {
        parts.append("\(references.jobs) job\(references.jobs == 1 ? "" : "s")")
    }
    return "\(verb) '\(name)' orphans \(parts.joined(separator: " and ")). Re-run with force to proceed anyway."
}

/// `SecretRoutes` reports a bad gateway shape as `GatewayValidationError`
/// (the HTTP routes turn it into a 400); surface it as `invalidParams` here.
private func mapGatewayError<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as SecretRoutes.GatewayValidationError {
        throw DaemonRPCError.invalidParams(error.message)
    }
}

/// The engine's pure RPC support (`JobRPC`, `AllowlistRPC`, `SettingsRPC`,
/// `SessionLifecycleRPC`, `NotificationRPC`) throws `RPCError`; map to
/// `DaemonRPCError` for the daemon router. Async so the lifecycle handlers can
/// `await` a main-actor hop inside the mapped body; a synchronous body satisfies
/// it unchanged.
private func mapRPCError<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as RPCError {
        switch error {
        case .invalidParams(let msg): throw DaemonRPCError.invalidParams(msg)
        case .applicationError(let msg): throw DaemonRPCError.applicationError(msg)
        }
    } catch let error as DaemonRPCError {
        throw error
    } catch let error as SessionActionError {
        // Unmet precondition or a failed provider call — either way the action
        // did not happen, so the caller must see an error, not a receipt.
        throw DaemonRPCError.applicationError(error.localizedDescription)
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
