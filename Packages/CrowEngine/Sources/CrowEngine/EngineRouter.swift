import Foundation
import CrowCore
import CrowIPC
import CrowPersistence
import CrowProvider
import CrowGit
import CrowTerminal
import CrowClaude

/// The RPC command router for the Crow engine, extracted from `AppDelegate` so
/// both the macOS app and the `crowd` daemon can build the same handler set
/// (CROW-581 headless-engine migration). Host-only touchpoints go through
/// `EngineContext.hostBridge`; app settings I/O goes through the injected
/// `loadConfig`/`applyConfig` closures.
@MainActor
public struct EngineContext {
    public let appState: AppState
    public let store: JSONStore
    public let sessionService: SessionService
    public let issueTracker: IssueTracker?
    public let telemetryPort: UInt16?
    public let devRoot: String
    public let hostBridge: HostBridge
    public let loadConfig: @Sendable () async -> (String, AppConfig)?
    public let applyConfig: @Sendable (AppConfig) async -> AppConfig?

    public init(
        appState: AppState,
        store: JSONStore,
        sessionService: SessionService,
        issueTracker: IssueTracker?,
        telemetryPort: UInt16?,
        devRoot: String,
        hostBridge: HostBridge,
        loadConfig: @escaping @Sendable () async -> (String, AppConfig)?,
        applyConfig: @escaping @Sendable (AppConfig) async -> AppConfig?
    ) {
        self.appState = appState
        self.store = store
        self.sessionService = sessionService
        self.issueTracker = issueTracker
        self.telemetryPort = telemetryPort
        self.devRoot = devRoot
        self.hostBridge = hostBridge
        self.loadConfig = loadConfig
        self.applyConfig = applyConfig
    }
}

@MainActor
public func makeEngineRouter(_ ctx: EngineContext) -> CommandRouter {
    let capturedAppState = ctx.appState
    let capturedStore = ctx.store
    let capturedService = ctx.sessionService
    let capturedTracker = ctx.issueTracker
    let capturedTelemetryPort = ctx.telemetryPort
    let devRoot = ctx.devRoot
    let hostBridge = ctx.hostBridge
    let loadConfigForRPC = ctx.loadConfig
    let applyConfigForRPC = ctx.applyConfig
    let hookDebug = ProcessInfo.processInfo.environment["CROW_HOOK_DEBUG"] == "1"
    return CommandRouter(handlers: [
            // App config for the web Settings modal (CROW-581): the config JSON is
            // transported as one opaque string so `AppConfig`'s own Codable stays
            // the single shape authority. Credential values are stripped out /
            // preserved by `SettingsSecrets` — desktop-only, read-only on web.
            "get-config": { @Sendable _ in
                guard let (devRoot, config) = await loadConfigForRPC() else {
                    throw RPCError.applicationError("Config not loaded yet")
                }
                let stripped = SettingsSecrets.strippedForTransport(config)
                guard let data = try? JSONEncoder().encode(stripped),
                      let json = String(data: data, encoding: .utf8) else {
                    throw RPCError.applicationError("Failed to encode config")
                }
                return ["config": .string(json), "dev_root": .string(devRoot), "app_running": .bool(true)]
            },
            "set-config": { @Sendable params in
                guard let json = params["config"]?.stringValue,
                      let data = json.data(using: .utf8),
                      let incoming = try? JSONDecoder().decode(AppConfig.self, from: data) else {
                    throw RPCError.invalidParams("config must be a valid AppConfig JSON string")
                }
                guard let saved = await applyConfigForRPC(incoming) else {
                    throw RPCError.applicationError("Config not loaded yet")
                }
                guard let outData = try? JSONEncoder().encode(saved),
                      let outJSON = String(data: outData, encoding: .utf8) else {
                    throw RPCError.applicationError("Failed to encode config")
                }
                return ["config": .string(outJSON), "saved": .bool(true)]
            },
            "new-session": { @Sendable params in
                let name = params["name"]?.stringValue ?? "untitled"
                guard Validation.isValidSessionName(name) else {
                    throw RPCError.invalidParams("Invalid session name (max \(Validation.maxSessionNameLength) chars, no control characters)")
                }
                // Only work and manager sessions can be created here. Review and
                // job sessions need their dedicated setup (worktree, prompt files,
                // scheduler) and would be malformed if created bare via this path.
                let kindStr = params["kind"]?.stringValue
                guard kindStr == nil || kindStr == "work" || kindStr == "manager" else {
                    throw RPCError.invalidParams("Invalid kind (expected work or manager)")
                }
                let isManagerKind = kindStr == "manager"
                // Optional `agent_kind` param (e.g. "claude-code"). Falls
                // back to the app-wide default when absent or empty.
                let requestedAgentKind = params["agent_kind"]?.stringValue
                    .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }
                return await MainActor.run {
                    // Manager sessions get their own agent terminal in the
                    // devRoot, mirroring the primary Manager. The Manager
                    // agent is resolved from `appState.agentKind(for: .manager)`
                    // inside `createManagerSession`, so the request's
                    // `agent_kind` param is ignored for manager kind
                    // (CROW-433).
                    if isManagerKind {
                        let id = capturedService.createManagerSession(name: name, cwd: devRoot)
                        let createdName = capturedAppState.sessions.first(where: { $0.id == id })?.name ?? name
                        return ["session_id": .string(id.uuidString), "name": .string(createdName)]
                    }
                    let agentKind = requestedAgentKind ?? capturedAppState.agentKind(for: .work)
                    let session = Session(name: name, kind: .work, agentKind: agentKind)
                    capturedAppState.sessions.append(session)
                    capturedStore.mutate { $0.sessions.append(session) }
                    return [
                        "session_id": .string(session.id.uuidString),
                        "name": .string(session.name),
                        "agent_kind": .string(session.agentKind.rawValue),
                    ]
                }
            },
            "rename-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue,
                      let id = UUID(uuidString: idStr),
                      let name = params["name"]?.stringValue else {
                    throw RPCError.invalidParams("session_id and name required")
                }
                guard Validation.isValidSessionName(name) else {
                    throw RPCError.invalidParams("Invalid session name (max \(Validation.maxSessionNameLength) chars, no control characters)")
                }
                return try await MainActor.run {
                    // Route through the service (not a direct name write) so the
                    // rename also pushes the `/rename <name>` slash command to the
                    // session's remote-control terminal, keeping the running agent
                    // and its claude.ai panel label in sync. The web/CLI RPC path
                    // skipped that before, so a rename only relabeled the box
                    // (CROW-593).
                    guard capturedService.renameSession(sessionID: id, name: name) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    return ["session_id": .string(idStr), "name": .string(name)]
                }
            },
            "select-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue,
                      let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                await MainActor.run { capturedAppState.selectedSessionID = id }
                return ["session_id": .string(idStr)]
            },
            "list-sessions": { @Sendable _ in
                let sessions = await MainActor.run { capturedAppState.sessions }
                let items: [JSONValue] = sessions.map { s in
                    .object(["id": .string(s.id.uuidString), "name": .string(s.name), "status": .string(s.status.rawValue)])
                }
                return ["sessions": .array(items)]
            },
            "get-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                return try await MainActor.run {
                    guard let s = capturedAppState.sessions.first(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    let fmt = ISO8601DateFormatter()
                    return [
                        "id": .string(s.id.uuidString),
                        "name": .string(s.name),
                        "status": .string(s.status.rawValue),
                        "ticket_url": s.ticketURL.map { .string($0) } ?? .null,
                        "ticket_title": s.ticketTitle.map { .string($0) } ?? .null,
                        "ticket_number": s.ticketNumber.map { .int($0) } ?? .null,
                        "provider": s.provider.map { .string($0.rawValue) } ?? .null,
                        "created_at": .string(fmt.string(from: s.createdAt)),
                        "updated_at": .string(fmt.string(from: s.updatedAt)),
                        "locked": .bool(s.locked),
                        // Legacy alias (CROW-569 named this `pinned`); kept for
                        // one release so existing scripts keep working.
                        "pinned": .bool(s.locked),
                    ]
                }
            },
            // CROW-581: expose live PR status (in-memory, not persisted) so the
            // headless daemon / web UI can render a PR badge matching the app.
            "get-pr-status": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                return await MainActor.run {
                    guard let pr = capturedAppState.prStatus[id] else {
                        return ["has_pr": .bool(false)]
                    }
                    return [
                        "has_pr": .bool(true),
                        "checks": .string(pr.checksPass.rawValue),
                        "review": .string(pr.reviewStatus.rawValue),
                        "merge": .string(pr.mergeable.rawValue),
                        "is_open": .bool(pr.isOpen),
                        "is_merged": .bool(pr.isMerged),
                        "ready_to_merge": .bool(pr.isReadyToMerge),
                        "has_blockers": .bool(pr.hasBlockers),
                        "failed_checks": .array(pr.failedCheckNames.map { .string($0) }),
                    ]
                }
            },
            // CROW-581: trigger a PR-status quick action (fixConflicts /
            // addressChanges / fixChecks / mergePR) — reuses the existing
            // `onQuickAction` hook, which pastes the deterministic prompt into
            // the session's managed agent terminal.
            "quick-action": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                guard let actionStr = params["action"]?.stringValue, let action = QuickAction(rawValue: actionStr) else {
                    throw RPCError.invalidParams("action required (fixConflicts, addressChanges, fixChecks, mergePR)")
                }
                await MainActor.run {
                    capturedAppState.onQuickAction?(id, action)
                }
                return ["dispatched": .bool(true), "action": .string(action.rawValue)]
            },
            // CROW-581: board data for the web UI. Ticket/review/allowlist state
            // lives only in the app's AppState (IssueTracker / AllowListService),
            // so the daemon forwards these reads here. Results are repo-exclude
            // filtered but NOT status-filtered/sorted — the web owns pipeline
            // filtering + sort so it can drive its own segment controls.
            "list-tickets": { @Sendable _ in
                await MainActor.run {
                    let fmt = ISO8601DateFormatter()
                    let issues: [JSONValue] = capturedAppState.filteredAssignedIssues.map { issue in
                        // Fold .unknown into .backlog so the web's pipeline buckets
                        // line up with issueCount(for:) (AppState.effectiveStatus).
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
                            "linked_session_id": capturedAppState.linkedSession(for: issue).map { .string($0.id.uuidString) } ?? .null,
                        ])
                    }
                    var counts: [String: JSONValue] = [:]
                    for status in TicketStatus.pipelineStatuses {
                        counts[status.rawValue] = .int(capturedAppState.issueCount(for: status))
                    }
                    counts["All"] = .int(capturedAppState.filteredAssignedIssues.count)
                    return [
                        "issues": .array(issues),
                        "counts": .object(counts),
                        "done_last_24h": .int(capturedAppState.doneIssuesLast24h),
                        "loading": .bool(capturedAppState.isLoadingIssues),
                    ]
                }
            },
            "list-reviews": { @Sendable _ in
                await MainActor.run {
                    let fmt = ISO8601DateFormatter()
                    let reviews: [JSONValue] = capturedAppState.filteredReviewRequests.map { r in
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
                        "loading": .bool(capturedAppState.isLoadingReviews),
                        "unseen": .int(capturedAppState.unseenReviewCount),
                    ]
                }
            },
            "list-allowlist": { @Sendable _ in
                await MainActor.run {
                    let entries: [JSONValue] = capturedAppState.allowEntries.map { e in
                        .object([
                            "pattern": .string(e.pattern),
                            "is_global": .bool(e.isInGlobal),
                            "worktree_session_names": .array(e.worktreeSessionNames.map { .string($0) }),
                        ])
                    }
                    return [
                        "entries": .array(entries),
                        "loading": .bool(capturedAppState.isLoadingAllowList),
                    ]
                }
            },
            // Board actions — invoke the app's existing callbacks. work-on-issue
            // and start-review spawn workspaces via the same paths the desktop UI
            // uses (onWorkOnIssue / onStartReview).
            "work-on-issue": { @Sendable params in
                guard let url = params["url"]?.stringValue, !url.isEmpty else {
                    throw RPCError.invalidParams("url required")
                }
                await MainActor.run { capturedAppState.onWorkOnIssue?(url) }
                return ["ok": .bool(true)]
            },
            "start-review": { @Sendable params in
                guard let url = params["url"]?.stringValue, !url.isEmpty else {
                    throw RPCError.invalidParams("url required")
                }
                await MainActor.run { capturedAppState.onStartReview?(url) }
                return ["ok": .bool(true)]
            },
            "promote-allowlist": { @Sendable params in
                guard let arr = params["patterns"]?.arrayValue else {
                    throw RPCError.invalidParams("patterns array required")
                }
                let patterns = Set(arr.compactMap { $0.stringValue })
                guard !patterns.isEmpty else { throw RPCError.invalidParams("patterns array required") }
                await MainActor.run { capturedAppState.onPromoteToGlobal?(patterns) }
                return ["ok": .bool(true)]
            },
            "refresh-tickets": { @Sendable _ in
                await MainActor.run { capturedAppState.onManualRefresh?() }
                return ["ok": .bool(true)]
            },
            "refresh-allowlist": { @Sendable _ in
                await MainActor.run { capturedAppState.onLoadAllowList?() }
                return ["ok": .bool(true)]
            },
            // CROW-581: batched live per-session state (remote-control + PR) —
            // runtime-only, not in the store, so the daemon forwards here rather
            // than reading its store-seeded snapshot. One call replaces N
            // per-session get-pr-status calls and carries RC in the same trip.
            "list-sessions-live": { @Sendable _ in
                await MainActor.run {
                    var out: [String: JSONValue] = [:]
                    for session in capturedAppState.sessions {
                        let id = session.id
                        let available = AgentRegistry.shared.agent(for: session.agentKind)?.supportsRemoteControl ?? false
                        // Inline of CrowUI's internal isRemoteControlActive: any of
                        // the session's terminals launched with --rc.
                        let rcActive = capturedAppState.terminals(for: id)
                            .contains { capturedAppState.remoteControlActiveTerminals.contains($0.id) }
                        var entry: [String: JSONValue] = [
                            "remote_control_active": .bool(rcActive),
                            "remote_control_available": .bool(available),
                        ]
                        if let pr = capturedAppState.prStatus[id] {
                            entry["pr"] = .object([
                                "has_pr": .bool(true),
                                "checks": .string(pr.checksPass.rawValue),
                                "review": .string(pr.reviewStatus.rawValue),
                                "merge": .string(pr.mergeable.rawValue),
                                "is_open": .bool(pr.isOpen),
                                "is_merged": .bool(pr.isMerged),
                                "ready_to_merge": .bool(pr.isReadyToMerge),
                                "has_blockers": .bool(pr.hasBlockers),
                                "failed_checks": .array(pr.failedCheckNames.map { .string($0) }),
                            ])
                        } else {
                            entry["pr"] = .object(["has_pr": .bool(false)])
                        }
                        // The session's PR link may live only in memory (derived
                        // from the linked issue), not in the persisted store the
                        // daemon reads — surface it so the web shows a PR badge
                        // wherever the desktop does.
                        if let prLink = capturedAppState.links(for: id).first(where: { $0.linkType == .pr }) {
                            entry["pr_link"] = .object(["label": .string(prLink.label), "url": .string(prLink.url)])
                        }
                        out[id.uuidString] = .object(entry)
                    }
                    return ["sessions": .object(out)]
                }
            },
            // Board/session actions — invoke the app's existing callbacks.
            "create-manager": { @Sendable params in
                // Optional agent override (#583); nil = configured default.
                // Security gate (CROW-593): only honor a kind that is actually
                // registered in AgentRegistry, so a web/daemon caller can't
                // request an arbitrary agent. An unknown/unavailable kind falls
                // back to the configured default (launch is additionally gated
                // in managerCommand's AgentRegistry fallback).
                let requested = params["agent_kind"]?.stringValue.flatMap { AgentKind(rawValue: $0) }
                let agent = requested.flatMap { AgentRegistry.shared.agent(for: $0) != nil ? $0 : nil }
                await MainActor.run { capturedAppState.onCreateManager?(agent) }
                return ["ok": .bool(true)]
            },
            // CROW-593: run a scheduled job on demand from the web Jobs list.
            // Reuses the app's `onRunJob` hook (bound to `JobScheduler.runNow`),
            // which fires the job regardless of its enabled flag or schedule.
            "run-job": { @Sendable params in
                guard let idStr = params["job_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("job_id required")
                }
                await MainActor.run { capturedAppState.onRunJob?(id) }
                return ["ok": .bool(true)]
            },
            // Available coding agents for the web's new-manager menu (#2 /
            // CROW-593). Mirrors the desktop's AgentRegistry-backed picker.
            "list-agents": { @Sendable _ in
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
            "mark-in-review": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                await MainActor.run { capturedAppState.onMarkInReview?(id) }
                return ["ok": .bool(true)]
            },
            "mark-issue-done": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                await MainActor.run { capturedAppState.onMarkIssueDone?(id) }
                return ["ok": .bool(true)]
            },
            "complete-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                await MainActor.run { capturedAppState.onCompleteSession?(id) }
                return ["ok": .bool(true)]
            },
            "set-session-active": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                await MainActor.run { capturedAppState.onSetSessionActive?(id) }
                return ["ok": .bool(true)]
            },
            "add-merge-label": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                await MainActor.run { capturedAppState.onAddMergeLabel?(id) }
                return ["ok": .bool(true)]
            },
            "set-status": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                      let statusStr = params["status"]?.stringValue, let status = SessionStatus(rawValue: statusStr) else {
                    throw RPCError.invalidParams("session_id and status required")
                }
                return try await MainActor.run {
                    guard let idx = capturedAppState.sessions.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    capturedAppState.sessions[idx].status = status
                    capturedAppState.sessions[idx].updatedAt = Date()
                    capturedStore.mutate { data in
                        if let i = data.sessions.firstIndex(where: { $0.id == id }) {
                            data.sessions[i].status = status
                            data.sessions[i].updatedAt = Date()
                        }
                    }
                    return ["session_id": .string(idStr), "status": .string(statusStr)]
                }
            },
            "set-locked": { @Sendable params in
                // Accept the new `locked` param, or the legacy CROW-569 `pinned`
                // param, so the `set-pinned` alias below can share this handler.
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                      let locked = params["locked"]?.boolValue ?? params["pinned"]?.boolValue else {
                    throw RPCError.invalidParams("session_id and locked required")
                }
                return try await MainActor.run {
                    guard capturedAppState.sessions.contains(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    capturedService.setLocked(id: id, locked: locked)
                    return ["session_id": .string(idStr), "locked": .bool(locked)]
                }
            },
            // Deprecated alias for `set-locked` (CROW-569 → CROW-573 rename).
            "set-pinned": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                      let locked = params["pinned"]?.boolValue ?? params["locked"]?.boolValue else {
                    throw RPCError.invalidParams("session_id and pinned required")
                }
                return try await MainActor.run {
                    guard capturedAppState.sessions.contains(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    capturedService.setLocked(id: id, locked: locked)
                    return ["session_id": .string(idStr), "locked": .bool(locked)]
                }
            },
            "delete-session": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                guard id != AppState.managerSessionID else { throw RPCError.applicationError("Cannot delete manager session") }
                await capturedService.deleteSession(id: id)
                return ["deleted": .bool(true)]
            },
            "set-ticket": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                return try await MainActor.run {
                    guard let idx = capturedAppState.sessions.firstIndex(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    if let url = params["url"]?.stringValue {
                        capturedAppState.sessions[idx].ticketURL = url
                        // Auto-detect provider from URL
                        if capturedAppState.sessions[idx].provider == nil {
                            let detected = Validation.detectProviderFromURL(url)
                            capturedAppState.sessions[idx].provider = detected
                            // Task-only trackers (Jira/Corveil) have no code
                            // backend — pair with the workspace's code provider.
                            if capturedAppState.sessions[idx].codeProvider == nil, detected?.isTaskOnly == true {
                                let wtPath = capturedAppState.worktrees[id]?
                                    .first(where: { $0.isPrimary })?.worktreePath
                                    ?? capturedAppState.worktrees[id]?.first?.worktreePath
                                capturedAppState.sessions[idx].codeProvider = SessionService.resolvedCodeProvider(forTask: detected, worktreePath: wtPath)
                            }
                        }
                    }
                    if let title = params["title"]?.stringValue { capturedAppState.sessions[idx].ticketTitle = title }
                    if let num = params["number"]?.intValue { capturedAppState.sessions[idx].ticketNumber = num }
                    capturedStore.mutate { data in
                        if let i = data.sessions.firstIndex(where: { $0.id == id }) { data.sessions[i] = capturedAppState.sessions[idx] }
                    }
                    return ["session_id": .string(idStr)]
                }
            },
            "transition-ticket": { @Sendable params in
                // CROW-529: transition a session's linked ticket to a pipeline
                // status (honoring jiraStatusMap for Jira). `setup.sh` calls this
                // at session start to move a Jira work item to its mapped
                // In-Progress status — the GitHub Projects-v2 mutation setup.sh
                // already does has no Jira equivalent without this.
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                guard let toStr = params["to"]?.stringValue,
                      let status = EngineHelpers.ticketStatus(fromArg: toStr) else {
                    throw RPCError.invalidParams("`to` required (one of: inProgress, inReview, done)")
                }
                guard let tracker = capturedTracker else {
                    throw RPCError.applicationError("Issue tracker not ready")
                }
                await tracker.transitionTicket(sessionID: id, to: status)
                return ["session_id": .string(idStr), "to": .string(status.rawValue)]
            },
            "resync-jira": { @Sendable _ in
                // CROW-529: one-shot remediation for Jira tickets stuck in Backlog
                // because earlier sessions never transitioned them.
                guard let tracker = capturedTracker else {
                    throw RPCError.applicationError("Issue tracker not ready")
                }
                let attempted = await tracker.resyncJira()
                return ["attempted": .int(attempted)]
            },
            "add-worktree": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                      let repo = params["repo"]?.stringValue, !repo.isEmpty,
                      let path = params["path"]?.stringValue, !path.isEmpty,
                      let branch = params["branch"]?.stringValue, !branch.isEmpty else {
                    throw RPCError.invalidParams("session_id, repo, path, branch required (non-empty)")
                }
                // Validate path is within devRoot to prevent path traversal
                guard Validation.isPathWithinRoot(path, root: devRoot) else {
                    throw RPCError.invalidParams("Worktree path must be within the configured devRoot")
                }
                // repo_path is the main repo (for git commands). Defaults to path if not provided.
                let repoPath = params["repo_path"]?.stringValue ?? path
                guard Validation.isPathWithinRoot(repoPath, root: devRoot) else {
                    throw RPCError.invalidParams("repo_path must be within the configured devRoot")
                }
                let wt = SessionWorktree(sessionID: sessionID, repoName: repo, repoPath: repoPath, worktreePath: path,
                                         branch: branch, isPrimary: params["primary"]?.boolValue ?? false)
                return await MainActor.run {
                    capturedAppState.worktrees[sessionID, default: []].append(wt)
                    capturedStore.mutate { $0.worktrees.append(wt) }
                    return ["worktree_id": .string(wt.id.uuidString), "session_id": .string(idStr), "path": .string(path)]
                }
            },
            "list-worktrees": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let wts = await MainActor.run { capturedAppState.worktrees(for: id) }
                let items: [JSONValue] = wts.map { wt in
                    .object(["id": .string(wt.id.uuidString), "repo": .string(wt.repoName), "path": .string(wt.worktreePath),
                             "branch": .string(wt.branch), "primary": .bool(wt.isPrimary)])
                }
                return ["worktrees": .array(items)]
            },
            "new-terminal": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                      let cwd = params["cwd"]?.stringValue else {
                    throw RPCError.invalidParams("session_id and cwd required")
                }
                // Validate cwd is within devRoot to prevent path traversal
                guard Validation.isPathWithinRoot(cwd, root: devRoot) else {
                    throw RPCError.invalidParams("Terminal cwd must be within the configured devRoot")
                }
                let rawCommand = params["command"]?.stringValue
                let isManaged = params["managed"]?.boolValue ?? false
                return await MainActor.run {
                    // Resolve claude binary path if command references claude; also
                    // inject --rc --name when remote control is enabled so the session
                    // appears in claude.ai's Remote Control panel under the Crow
                    // session name.
                    var command = rawCommand
                    var rcInjected = false
                    let session = capturedAppState.sessions.first(where: { $0.id == sessionID })
                    let sessionName = session?.name
                    // The default managed-terminal name is the configured agent's
                    // displayName (CROW-427) — Cursor sessions read "Cursor",
                    // Codex sessions read "OpenAI Codex", etc. When the session
                    // can't be found yet, fall back to the AppState default kind.
                    let agentKind = session?.agentKind ?? capturedAppState.defaultAgentKind
                    let defaultName = isManaged ? agentKind.displayName : "Shell"
                    let terminalName = params["name"]?.stringValue ?? defaultName
                    if let cmd = rawCommand, cmd.contains("claude") {
                        let rcEnabled = capturedAppState.remoteControlEnabled
                        command = EngineHelpers.resolveClaudeInCommand(
                            cmd,
                            remoteControl: rcEnabled,
                            sessionName: sessionName
                        )
                        rcInjected = rcEnabled
                            && !cmd.contains("--rc")
                            && !cmd.contains("--remote-control")
                    }
                    let trackReadiness = isManaged
                    // Brand-new managed terminals DEFER their agent launch until
                    // the shell signals readiness (issue #408). Pasting the launch
                    // command immediately races the shell's line editor (zle): if
                    // the prompt isn't live yet the keystrokes are dropped and the
                    // window is left at a bare zsh with no agent. Instead hold the
                    // command in `pendingLaunchCommands` and register the window
                    // with `command: nil`, so the deferred paste happens in
                    // `SessionService.wireTerminalReadiness` on `.shellReady`.
                    let hasCommand = !(command?.isEmpty ?? true)
                    let deferLaunch = trackReadiness && hasCommand
                    let registerCommand = deferLaunch ? nil : command
                    // Every session, including the Manager (#314), runs on
                    // tmux (#303). Register the tmux window now — its shell
                    // starts immediately, so there's no offscreen pre-init.
                    //
                    // Persist `registerCommand` (nil for a deferred launch), NOT
                    // the raw launch command: the launch lives in
                    // `pendingLaunchCommands` (in-memory) and the persisted row
                    // must not carry it, or the hydrate-fresh fallback would
                    // blind-paste it into a not-yet-ready shell on the recovery
                    // path — the very race this fixes (#408). A restored managed
                    // terminal relaunches via the autoLaunch/launchAgent path.
                    var terminal = SessionTerminal(
                        sessionID: sessionID,
                        name: terminalName,
                        cwd: cwd,
                        command: registerCommand,
                        isManaged: isManaged,
                        backend: .tmux
                    )
                    // Seed readiness + pending-launch state BEFORE registering so
                    // the sentinel's `.shellReady` (which can only fire on a later
                    // main-actor turn) always finds the pending command and the
                    // autoLaunch membership populated.
                    if trackReadiness {
                        capturedAppState.terminalReadiness[terminal.id] = .uninitialized
                    }
                    if deferLaunch, let command {
                        capturedAppState.pendingLaunchCommands[terminal.id] = command
                        // Membership lets the existing `.timedOut` re-arm machinery
                        // (`reArmStuckReadinessWatches`) recover a slow launch.
                        capturedAppState.autoLaunchTerminals.insert(terminal.id)
                    }
                    var launchFailed = false
                    do {
                        // Bounded retry with a modestly-longer per-call `new-window`
                        // budget: under load the tmux subprocess can exceed the 2s
                        // default and get SIGTERM'd, leaving a window-less terminal
                        // (#408). This runs inside `MainActor.run`, so the budget is
                        // kept tight (2 attempts × 3s) to cap worst-case main-actor
                        // stall at ~6s rather than beachballing concurrent RPCs.
                        let binding = try EngineHelpers.registerWithRetry(attempts: 2) { _ in
                            try TmuxBackend.shared.registerTerminal(
                                id: terminal.id,
                                name: terminalName,
                                cwd: cwd,
                                command: registerCommand,
                                trackReadiness: trackReadiness,
                                agentKind: agentKind,
                                newWindowTimeout: 3.0
                            )
                        }
                        terminal.tmuxBinding = binding
                    } catch {
                        // The tmux window never materialized. Don't pretend the
                        // launch succeeded (#408): surface it so the UI shows a
                        // Retry affordance and the CLI caller reports honestly
                        // instead of leaving a silent window-less terminal.
                        NSLog("[Crow] tmux registerTerminal failed after retries (\(error)); surfacing launch failure")
                        launchFailed = true
                        if trackReadiness {
                            capturedAppState.terminalReadiness[terminal.id] = .failed
                        }
                        capturedAppState.pendingLaunchCommands.removeValue(forKey: terminal.id)
                        capturedAppState.autoLaunchTerminals.remove(terminal.id)
                    }
                    capturedAppState.terminals[sessionID, default: []].append(terminal)
                    capturedStore.mutate { $0.terminals.append(terminal) }
                    if trackReadiness {
                        TerminalRouter.trackReadiness(for: terminal)
                    }
                    if rcInjected {
                        capturedAppState.remoteControlActiveTerminals.insert(terminal.id)
                    }
                    var result: [String: JSONValue] = [
                        "terminal_id": .string(terminal.id.uuidString),
                        "session_id": .string(idStr),
                    ]
                    if launchFailed { result["launch_failed"] = .bool(true) }
                    return result
                }
            },
            "list-terminals": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let terms = await MainActor.run { capturedAppState.terminals(for: id) }
                let readiness = await MainActor.run { capturedAppState.terminalReadiness }
                let items: [JSONValue] = terms.map { t in
                    // `readiness` lets CLI callers (setup.sh) verify the agent
                    // actually started rather than assuming a launch succeeded
                    // (#408). Defaults to `uninitialized` for un-tracked shells.
                    .object([
                        "id": .string(t.id.uuidString),
                        "name": .string(t.name),
                        "session_id": .string(t.sessionID.uuidString),
                        "managed": .bool(t.isManaged),
                        "readiness": .string((readiness[t.id] ?? .uninitialized).rawValue),
                    ])
                }
                return ["terminals": .array(items)]
            },
            "close-terminal": { @Sendable params in
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let terminalIDStr = params["terminal_id"]?.stringValue,
                      let terminalID = UUID(uuidString: terminalIDStr) else {
                    throw RPCError.invalidParams("session_id and terminal_id required")
                }
                return try await MainActor.run {
                    guard let terminals = capturedAppState.terminals[sessionID],
                          let terminal = terminals.first(where: { $0.id == terminalID }) else {
                        throw RPCError.applicationError("Terminal not found")
                    }
                    guard !terminal.isManaged else {
                        throw RPCError.applicationError("Cannot close managed terminal")
                    }
                    TerminalRouter.destroy(terminal)
                    capturedAppState.terminals[sessionID]?.removeAll { $0.id == terminalID }
                    capturedAppState.terminalReadiness.removeValue(forKey: terminalID)
                    capturedAppState.autoLaunchTerminals.remove(terminalID)
                    capturedAppState.pendingLaunchCommands.removeValue(forKey: terminalID)
                    if capturedAppState.activeTerminalID[sessionID] == terminalID {
                        capturedAppState.activeTerminalID[sessionID] = capturedAppState.terminals[sessionID]?.first?.id
                    }
                    capturedStore.mutate { data in data.terminals.removeAll { $0.id == terminalID } }
                    return ["deleted": .bool(true)]
                }
            },
            "rename-terminal": { @Sendable params in
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let terminalIDStr = params["terminal_id"]?.stringValue,
                      let terminalID = UUID(uuidString: terminalIDStr),
                      let name = params["name"]?.stringValue else {
                    throw RPCError.invalidParams("session_id, terminal_id, and name required")
                }
                return try await MainActor.run {
                    guard capturedService.renameTerminal(sessionID: sessionID, terminalID: terminalID, name: name) else {
                        throw RPCError.applicationError("Terminal not found or invalid name")
                    }
                    return ["terminal_id": .string(terminalIDStr), "name": .string(name)]
                }
            },
            "send": { @Sendable params in
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let terminalIDStr = params["terminal_id"]?.stringValue,
                      let terminalID = UUID(uuidString: terminalIDStr),
                      var text = params["text"]?.stringValue else {
                    throw RPCError.invalidParams("session_id, terminal_id, and text required")
                }
                // Process escape sequences: literal \n in the text becomes a real newline
                text = text.replacingOccurrences(of: "\\n", with: "\n")
                text = text.replacingOccurrences(of: "\\t", with: "\t")
                NSLog("crow send: text length=\(text.count), ends_with_newline=\(text.hasSuffix("\n")), ends_with_cr=\(text.hasSuffix("\r"))")
                await MainActor.run {
                    let routedTerminal = capturedAppState.terminals[sessionID]?.first(where: { $0.id == terminalID })
                    // tmux-backed terminals already have their window from
                    // registerTerminal — no surface recovery needed before send.

                    // For managed terminals receiving an agent-launching
                    // command, write hook config (and inject OTEL env vars
                    // for Claude) before forwarding so the agent picks up
                    // hooks on startup. The agent dispatch is driven by the
                    // session's `agentKind` and the agent's
                    // `launchCommandToken` (e.g. "claude", "codex").
                    if let terminals = capturedAppState.terminals[sessionID],
                       let terminal = terminals.first(where: { $0.id == terminalID }),
                       terminal.isManaged,
                       let session = capturedAppState.sessions.first(where: { $0.id == sessionID }),
                       let agent = AgentRegistry.shared.agent(for: session.agentKind) {
                        let prepared = AgentLaunch.prepareAgentLaunchText(
                            command: text,
                            agent: agent,
                            sessionID: sessionID,
                            worktreePath: capturedAppState.primaryWorktree(for: sessionID)?.worktreePath,
                            crowPath: ClaudeHookConfigWriter.findCrowBinary(devRoot: devRoot),
                            telemetryPort: capturedTelemetryPort
                        )
                        text = prepared.text
                        if prepared.didLaunch {
                            capturedAppState.terminalReadiness[terminalID] = .agentLaunched
                        }
                    }

                    if let routedTerminal {
                        TerminalRouter.send(routedTerminal, text: text)
                    } else {
                        // No SessionTerminal row known — nothing to route to.
                        NSLog("[Crow] crow send for unknown terminal \(terminalID); ignoring")
                    }
                }
                return ["sent": .bool(true)]
            },
            "add-link": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr),
                      let label = params["label"]?.stringValue, !label.isEmpty,
                      let url = params["url"]?.stringValue, !url.isEmpty else {
                    throw RPCError.invalidParams("session_id, label, url required (non-empty)")
                }
                let link = SessionLink(sessionID: sessionID, label: label, url: url,
                                       linkType: LinkType(rawValue: params["type"]?.stringValue ?? "custom") ?? .custom)
                return await MainActor.run {
                    capturedAppState.links[sessionID, default: []].append(link)
                    capturedStore.mutate { $0.links.append(link) }
                    return ["link_id": .string(link.id.uuidString)]
                }
            },
            "list-links": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let lnks = await MainActor.run { capturedAppState.links(for: id) }
                let items: [JSONValue] = lnks.map { l in
                    .object(["id": .string(l.id.uuidString), "label": .string(l.label), "url": .string(l.url), "type": .string(l.linkType.rawValue)])
                }
                return ["links": .array(items)]
            },
            "remove-link": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let linkID = params["link_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
                let url = params["url"]?.stringValue
                guard linkID != nil || url != nil else {
                    throw RPCError.invalidParams("link_id or url required")
                }
                func matches(_ l: SessionLink) -> Bool {
                    (linkID != nil && l.id == linkID) || (url != nil && l.url == url)
                }
                return await MainActor.run {
                    let before = capturedAppState.links(for: sessionID).count
                    if var existing = capturedAppState.links[sessionID] {
                        existing.removeAll(where: matches)
                        capturedAppState.links[sessionID] = existing.isEmpty ? nil : existing
                    }
                    capturedStore.mutate { data in
                        data.links.removeAll { $0.sessionID == sessionID && matches($0) }
                    }
                    let removed = before - capturedAppState.links(for: sessionID).count
                    return ["removed": .int(removed)]
                }
            },
            "hook-event": { @Sendable params in
                guard let eventName = params["event_name"]?.stringValue else {
                    throw RPCError.invalidParams("event_name required")
                }
                let payload = params["payload"]?.objectValue ?? [:]

                // session_id is now optional — Codex's global hooks don't
                // know the Crow session UUID, so the server resolves it via
                // the `cwd` field in the payload.
                let providedSessionID = params["session_id"]?.stringValue
                    .flatMap(UUID.init(uuidString:))
                let requestedAgentKind = params["agent_kind"]?.stringValue
                    .flatMap { $0.isEmpty ? nil : AgentKind(rawValue: $0) }
                let cwd = payload["cwd"]?.stringValue

                // Build a human-readable summary from the event (independent
                // of session resolution).
                let summary: String = {
                    switch eventName {
                    case "PreToolUse", "PostToolUse", "PostToolUseFailure":
                        let tool = payload["tool_name"]?.stringValue ?? "unknown"
                        return "\(eventName): \(tool)"
                    case "Notification":
                        let msg = payload["message"]?.stringValue ?? ""
                        return "Notification: \(msg.prefix(80))"
                    case "Stop":
                        return "Agent finished responding"
                    case "StopFailure":
                        return "Agent stopped with error"
                    case "SessionStart":
                        return "Session started"
                    case "SessionEnd":
                        return "Session ended"
                    case "PermissionRequest":
                        return "Permission requested"
                    case "PermissionDenied":
                        return "Permission denied"
                    case "UserPromptSubmit":
                        return "User submitted prompt"
                    case "TaskCreated":
                        return "Task created"
                    case "TaskCompleted":
                        return "Task completed"
                    case "SubagentStart":
                        let agentType = payload["agent_type"]?.stringValue ?? "agent"
                        return "Subagent started: \(agentType)"
                    case "SubagentStop":
                        return "Subagent stopped"
                    case "PreCompact":
                        return "Context compaction starting"
                    case "PostCompact":
                        return "Context compaction finished"
                    default:
                        return eventName
                    }
                }()

                return try await MainActor.run {
                    // Resolve session — explicit param wins, else look up by
                    // worktree path matching `cwd`.
                    let sessionID: UUID
                    if let provided = providedSessionID {
                        sessionID = provided
                    } else if let cwd, let resolved = capturedAppState.sessionID(forWorktreePath: cwd) {
                        sessionID = resolved
                    } else {
                        throw RPCError.invalidParams("session_id required or resolvable from payload cwd")
                    }
                    let sessionIDStr = sessionID.uuidString

                    if hookDebug {
                        let shortID = String(sessionIDStr.prefix(8))
                        let keys = payload.keys.sorted().joined(separator: ",")
                        NSLog("[hook-event] session=\(shortID) event=\(eventName) payload-keys=[\(keys)]")
                    }

                    let event = HookEvent(
                        sessionID: sessionID,
                        eventName: eventName,
                        summary: summary
                    )

                    // Flatten the raw JSON payload into the typed AgentHookEvent
                    // that the state-machine signal source consumes. Keeps
                    // CrowCore free of JSONValue, and localizes the field
                    // extraction in one place.
                    let agentEvent = AgentHookEvent(
                        sessionID: sessionID,
                        eventName: eventName,
                        toolName: payload["tool_name"]?.stringValue,
                        source: payload["source"]?.stringValue,
                        message: payload["message"]?.stringValue,
                        notificationType: payload["notification_type"]?.stringValue,
                        agentType: payload["agent_type"]?.stringValue,
                        summary: summary
                    )

                    // Resolve the agent: explicit kind param > session's
                    // stored agentKind > app default.
                    let session = capturedAppState.sessions.first(where: { $0.id == sessionID })
                    let resolvedKind = requestedAgentKind
                        ?? session?.agentKind
                        ?? capturedAppState.defaultAgentKind
                    let signalSource = AgentRegistry.shared.agent(for: resolvedKind)?.stateSignalSource

                    let state = capturedAppState.hookState(for: sessionID)
                    let stateBefore = state.activityState
                    // Snapshot the color-driving subset so we can persist only on a
                    // real change (keeps sidebar colors correct after relaunch — #367).
                    let snapshotBefore = state.persistedSnapshot

                    // Append to ring buffer (keep last 50 events per session)
                    state.hookEvents.append(event)
                    if state.hookEvents.count > 50 { state.hookEvents.removeFirst(state.hookEvents.count - 50) }

                    // Ask the agent for the state transition and apply it.
                    // The signal source is pure — all side effects (persistence,
                    // notifications, etc.) stay here in the handler.
                    if let signalSource {
                        let transition = signalSource.transition(
                            for: agentEvent,
                            currentActivityState: state.activityState,
                            currentNotificationType: state.pendingNotification?.notificationType,
                            currentLastTopLevelStopAt: state.lastTopLevelStopAt
                        )
                        if let newActivityState = transition.newActivityState {
                            state.activityState = newActivityState
                        }
                        switch transition.notification {
                        case .leave:
                            break
                        case .clear:
                            state.pendingNotification = nil
                        case .set(let notification):
                            state.pendingNotification = notification
                        }
                        switch transition.toolActivity {
                        case .leave:
                            break
                        case .clear:
                            state.lastToolActivity = nil
                        case .set(let activity):
                            state.lastToolActivity = activity
                        }
                        switch transition.lastTopLevelStopAt {
                        case .leave:
                            break
                        case .clear:
                            state.lastTopLevelStopAt = nil
                        case .set(let date):
                            state.lastTopLevelStopAt = date
                        }
                    }

                    // Trigger notification/sound for this event
                    hostBridge.presentHookNotification(
                        sessionID: sessionID,
                        eventName: eventName,
                        payload: payload,
                        summary: summary
                    )

                    if hookDebug && state.activityState != stateBefore {
                        let shortID = String(sessionIDStr.prefix(8))
                        NSLog("[hook-event] session=\(shortID) event=\(eventName) state=\(stateBefore.rawValue)→\(state.activityState.rawValue)")
                    }

                    // Persist the color-driving state only when it actually changed,
                    // so sidebar colors survive a quit→relaunch (#367). Excluding
                    // lastToolActivity means frequent PostToolUse events don't write.
                    let snapshotAfter = state.persistedSnapshot
                    if snapshotAfter != snapshotBefore {
                        capturedStore.mutate { data in
                            var map = data.hookStates ?? [:]
                            map[sessionIDStr] = snapshotAfter
                            data.hookStates = map
                        }
                    }

                    return [
                        "received": .bool(true),
                        "session_id": .string(sessionIDStr),
                        "event_name": .string(eventName),
                    ]
                }
            },
    ])
}
