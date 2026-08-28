import CrowCore
import CrowEngine
import CrowGit
import CrowIPC
import CrowPersistence
import CrowTerminal
import Foundation

/// Session CRUD, terminal/agent ops, host GUI launch, and session-local
/// reads (`list-agents`, `list-artifacts`, `get-session-terminal-preview`).
///
/// Extracted from `makeCommandRouter`'s dictionary literal (CROW-1134).
func makeSessionHandlers(
    appState: AppState,
    store: JSONStore,
    git: GitManager,
    devRoot: String,
    cockpit: TerminalCockpit?,
    tracker: IssueTracker?,
    sessionService: SessionService?,
    autoRespond: AutoRespondCoordinator?
) -> [String: CommandRouter.Handler] {
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134).
    let handlers: [String: CommandRouter.Handler] = [
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
            let isExplore = params["explore"]?.boolValue == true
            return await MainActor.run {
                // Registry gate (CROW-593; #834), matching the app's new-session
                // surface: honor the requested kind only if registered, else the
                // configured default — no unregistered kind persists here either.
                let agentKind = AgentRegistry.shared.registeredKind(requestedAgentKind)
                    ?? appState.agentKind(for: .work)
                let session = Session(name: name, kind: .work, agentKind: agentKind,
                                      isExplore: isExplore)
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
                        // Explore-mode tag (CROW-1149) — drives the board/sidebar
                        // "Exploring" badge so a bootstrap-only session isn't
                        // mistaken for a build. Additive; older clients ignore it.
                        "is_explore": .bool(session.isExplore),
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
    ]
    return handlers
}
