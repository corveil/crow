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

/// Extract the tool name from a hook payload, tolerating each harness's shape.
/// Claude/Cursor/Codex send a flat `tool_name`; Antigravity nests it as
/// `toolCall.name` (camelCase) — but **only on `PreToolUse`**. Antigravity's
/// `PostToolUse` stdin carries no tool name at all (only `stepIdx`/`error`/common
/// fields), and Crow deliberately doesn't register `PreToolUse` (its strict
/// decision gate), so for Antigravity this fallback is future-proofing for a
/// possible `PreToolUse` re-enable, not a live path — Antigravity's registered
/// `PostToolUse` tool activity is unnamed by design (a documented Tier-2 gap;
/// see `AntigravitySignalSource`). Harmless for the other harnesses (they have
/// no `toolCall` object).
func hookToolName(from payload: [String: JSONValue]) -> String? {
    if let flat = payload["tool_name"]?.stringValue { return flat }
    return payload["toolCall"]?.objectValue?["name"]?.stringValue
}

/// Payload `cwd`s already logged as unresolved hook-event drops. An unmapped
/// global hook config re-fires on every event, so without this the only
/// diagnostic channel left after #903 (see the hook-event handler) would flood
/// an unrotated launchd log. Capped so a pathological spread of cwds can't grow
/// it without limit; MainActor-isolated since its sole caller runs inside the
/// handler's `MainActor.run`. Never reset for the daemon's lifetime, so a drop
/// that gets fixed (worktree registered) and later regresses won't re-log —
/// acceptable for a diagnostic.
@MainActor private var loggedUnresolvedHookDrops: Set<String> = []

/// Neutralize a caller-supplied value before it reaches the log: cap length (the
/// per-set count caps bound record *count*; this bounds record *size*), and
/// escape every C0 control (and DEL) so an embedded ESC/ANSI sequence can't
/// mangle a terminal that `cat`s the launchd log. `\n`/`\r` get readable forms;
/// the rest become `\xNN`. Shared by both hook-drop loggers below.
private func oneLineForLog(_ s: String) -> String {
    var out = ""
    for scalar in String(s.prefix(200)).unicodeScalars {
        switch scalar {
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case let c where c.value < 0x20 || c.value == 0x7F:
            out += String(format: "\\x%02x", c.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// Log an unresolved hook-event drop at most once per `cwd`. Only the no-id /
/// no-cwd-match branch calls this, where `session_id` is always absent — so the
/// key is `cwd` alone (a `nil` cwd and a literal cwd of "none" are kept
/// distinct).
@MainActor private func logUnresolvedHookDropOnce(eventName: String, cwd: String?) {
    // Distinguish nil from a literal "none" path so the dedup key can't collide.
    let key = cwd.map { "cwd:" + $0 } ?? "<nil>"
    guard !loggedUnresolvedHookDrops.contains(key) else { return }
    // Hold the cap by refusing new keys once full (rather than clearing, which
    // would re-log every already-seen key on the next cycle). Beyond the cap,
    // novel cwds go unlogged — acceptable for a diagnostic bounded to the small
    // set of real worktrees in practice. `hook-event` is gated local-only
    // (RPCWebSocketHandler.localOnlyDenial), so filling this cap needs local
    // socket access, not a remote /rpc peer.
    guard loggedUnresolvedHookDrops.count < 256 else { return }
    loggedUnresolvedHookDrops.insert(key)
    CrowLog.error(
        "[hook-event] dropped \(oneLineForLog(eventName)): unresolved session "
        + "(no session_id, cwd=\(cwd.map(oneLineForLog) ?? "<none>"))"
    )
}

/// Inherited-config drops already logged, keyed on `cwd` **and** the foreign
/// session id — unlike the unresolved set above, one cwd can legitimately see
/// several foreign ids over a daemon's life (a main clone rewritten for a new
/// session while its worktrees keep running), and collapsing them onto `cwd`
/// alone would hide all but the first.
@MainActor private var loggedForeignHookDrops: Set<String> = []

/// Log an inherited-block drop at most once per (cwd, foreign id) pair.
///
/// This one is worth a log line rather than silence: it is the visible symptom
/// of a main clone still carrying a hook block, which `reconcileMainClone`
/// should have cleared at launch. Seeing it repeatedly means reconciliation is
/// not reaching that directory.
///
/// Same shape as the unresolved logger — 256-key cap held by refusing new keys,
/// never reset for the daemon's lifetime — because this fires on essentially
/// every tool call of every affected session.
@MainActor private func logForeignHookDropOnce(
    eventName: String, cwd: String, provided: UUID, resolved: UUID
) {
    let key = "\(cwd)|\(provided.uuidString)"
    guard !loggedForeignHookDrops.contains(key) else { return }
    guard loggedForeignHookDrops.count < 256 else { return }
    loggedForeignHookDrops.insert(key)
    CrowLog.error(
        "[hook-event] dropped \(oneLineForLog(eventName)): hook config for session "
        + "\(provided.uuidString) fired in \(oneLineForLog(cwd)), which belongs to "
        + "\(resolved.uuidString) — an inherited main-clone block (#915). "
        + "Its .claude/settings.local.json still carries Crow hooks."
    )
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
                // Preserve stored secrets the browser can't see, and never echo
                // them back — mirror the daemon handler so this surface stays safe
                // if it ever becomes web-facing (review #3).
                let current = await loadConfigForRPC()?.1
                let merged = SettingsSecrets.preservingSecrets(incoming: incoming, current: current)
                guard let saved = await applyConfigForRPC(merged) else {
                    throw RPCError.applicationError("Config not loaded yet")
                }
                let safe = SettingsSecrets.strippedForTransport(saved)
                guard let outData = try? JSONEncoder().encode(safe),
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
                    // Registry gate (CROW-593; #834): honor the requested kind
                    // only if an agent is registered for it, else fall back to
                    // the configured default — so this surface can't persist a
                    // session with an unregistered kind that `launchAgent` would
                    // then silently no-op on.
                    let agentKind = AgentRegistry.shared.registeredKind(requestedAgentKind)
                        ?? capturedAppState.agentKind(for: .work)
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
                    // rename also pushes `/rename <name>` to the running agent
                    // (Manager terminals for any agent that supports rename;
                    // Claude `--rc` workers for the claude.ai panel label).
                    // The web/CLI RPC path skipped that before (CROW-593 / CROW-629).
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
                    // CROW-969: which gateway this session launches with, and where
                    // it came from — so a rejected credential can be traced to a
                    // workspace without launching a session to find out. A Manager
                    // has no worktree and no PR links, so it reports its own
                    // gateway rather than a workspace's.
                    //
                    // ⚠️ `workspaceGatewayMatch`, NOT `workspaceGatewayResolved`:
                    // the latter shells out to `op read` with a 15s timeout PER
                    // HEADER, and this closure runs on the MainActor — a gateway
                    // whose `op` is blocked on a biometric prompt would wedge the
                    // whole daemon. The match path is config-read only.
                    let match = s.kind == .manager
                        ? capturedService.managerGatewayMatch()
                        : capturedService.workspaceGatewayMatch(for: id)
                    return [
                        "id": .string(s.id.uuidString),
                        "name": .string(s.name),
                        "status": .string(s.status.rawValue),
                        "agent_kind": .string(s.agentKind.rawValue),
                        "agent_display_name": .string(CrowAttribution.agentDisplayName(for: s.agentKind)),
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
                        // Org-goal tag + alignment inputs (#723; ADR 0008
                        // follow-up 8) — surfaced here so `crow get-session`
                        // reflects a goal set from the web and matches the
                        // documented read-back contract (docs/cli-reference.md).
                        // Unlike the web `list-sessions` poll (which sends only
                        // `org_goal`), this is a deliberate single-session read,
                        // so the computed `alignment_weight` + `ticket_priority`
                        // ride along too.
                        "org_goal": s.orgGoal.map { .string($0) } ?? .null,
                        "ticket_priority": s.ticketPriority.map { .string($0.rawValue) } ?? .null,
                        "alignment_weight": .double(s.alignmentWeight),
                        // ⚠️ REDACTION. `get-session` is NOT in
                        // `RPCWebSocketHandler.localOnlyDenial`, so a remote /rpc
                        // peer reads this. These fields therefore match
                        // `WorkspaceRPC.workspaceJSON` exactly: a `gateway_set`
                        // flag and the non-secret base URL, and nothing else.
                        // Header names and values stay with `crow gateway get`,
                        // which IS local-gated. Adding `headers` here would
                        // silently un-gate a credential.
                        "workspace_id": match?.workspaceID.map { .string($0.uuidString) } ?? .null,
                        "workspace_name": match?.workspaceName.map { .string($0) } ?? .null,
                        "workspace_match": match.map { .string($0.source.rawValue) } ?? .null,
                        "gateway_set": .bool(!(match?.gateway?.isEmpty ?? true)),
                        "gateway_base_url": match?.gateway.map { .string($0.baseURL) } ?? .null,
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
                        "has_merge_label": .bool(pr.hasMergeLabel),
                    ]
                }
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
                            // Richer board detail (#751) — all optional/back-compatible.
                            "body": issue.body.map { .string($0) } ?? .null,
                            "author": issue.author.map { .string($0) } ?? .null,
                            "created_at": issue.createdAt.map { .string(fmt.string(from: $0)) } ?? .null,
                            "comments_count": issue.commentsCount.map { .int($0) } ?? .null,
                            "pr_state": issue.prState.map { .string($0) } ?? .null,
                            "checks": issue.checksState.map { .object(["state": .string($0), "failed": .array((issue.failedCheckNames ?? []).map { .string($0) })]) } ?? .null,
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
                await MainActor.run { ReviewsPayload.build(appState: capturedAppState) }
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
                        // A session is remote-control-active when any of its
                        // terminals launched with --rc.
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
                                "has_merge_label": .bool(pr.hasMergeLabel),
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
            // Available coding agents for the web's new-manager menu (#2 /
            // CROW-593). Mirrors the desktop's AgentRegistry-backed picker.
            // Returns **all known** agents with an `available` flag + `binary`
            // token so off-PATH ones surface greyed-out, not hidden (#879).
            "list-agents": { @Sendable _ in
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
            // Mid-session agent switch when credits run out (CROW-627).
            "handoff-agent": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr),
                      let kindStr = params["agent_kind"]?.stringValue, !kindStr.isEmpty else {
                    throw RPCError.invalidParams("session_id and agent_kind required")
                }
                let targetKind = AgentKind(rawValue: kindStr)
                let note = params["note"]?.stringValue
                do {
                    let terminalID = try await capturedService.handoffAgent(
                        sessionID: id, to: targetKind, note: note)
                    return [
                        "session_id": .string(idStr),
                        "agent_kind": .string(targetKind.rawValue),
                        "terminal_id": .string(terminalID.uuidString),
                    ]
                } catch let error as AgentHandoffError {
                    throw RPCError.applicationError(error.localizedDescription)
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
            // Set or clear the org-goal tag on a session (#723; ADR 0008
            // follow-up 8). The data model + `SessionService.setOrgGoal` and the
            // `crow set-goal` CLI shipped with #696, but no RPC ever routed the
            // method — this wires the CLI socket *and* the web WebSocket (both
            // share this router) to the mutator.
            //
            // The goal/clear/blank rules mirror the CLI's `validateSetGoal`
            // (CrowCLI Validation.swift) so the two surfaces agree on ONE
            // contract: reject both, neither, and a blank goal. The CLI's
            // `validate()` guards only the CLI path, so for the web this RPC is
            // the sole enforcement point — a missing/typo'd param must error,
            // not silently wipe an existing tag. (The web only ever sends
            // `{goal}` or `{clear:true}` — app.js `setSessionGoal` — so this
            // rejects nothing it emits.) The goal string is additionally held to
            // the same `isValidSessionName` bound (≤256 chars, no control
            // characters) as the sibling free-text handlers (`new-session`
            // above, `rename-session` via `SessionService`), since this newly
            // exposes a free-text field to an authenticated *remote* web client
            // that gets re-broadcast in every `list-sessions` payload. Managers
            // are excluded — a server-side-only rule (not from the CLI) matching
            // the web menu: orchestration sessions don't ladder up to an org KPI.
            "set-goal": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let id = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let clear = params["clear"]?.boolValue ?? false
                let rawGoal = params["goal"]?.stringValue
                // Bind `goal` in-pattern (no force-unwrap): the switch is
                // exhaustive over (goal?, clear), and the only arm that yields a
                // value validates it — blank rejected, then the same
                // `isValidSessionName` bound (≤256 chars, no control chars) the
                // sibling free-text handlers keep.
                let goal: String?
                switch (rawGoal, clear) {
                case (.some, true):
                    throw RPCError.invalidParams("`goal` and `clear` are mutually exclusive")
                case (nil, false):
                    throw RPCError.invalidParams("Exactly one of `goal` or `clear` is required")
                case (.some(let g), false):
                    let trimmed = g.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw RPCError.invalidParams("`goal` must not be blank")
                    }
                    guard Validation.isValidSessionName(trimmed) else {
                        throw RPCError.invalidParams("Invalid goal (max \(Validation.maxSessionNameLength) chars, no control characters)")
                    }
                    goal = trimmed
                case (nil, true):
                    goal = nil
                }
                return try await MainActor.run {
                    guard let session = capturedAppState.sessions.first(where: { $0.id == id }) else {
                        throw RPCError.applicationError("Session not found")
                    }
                    guard session.kind != .manager else {
                        throw RPCError.applicationError("Org goals don't apply to the manager session")
                    }
                    capturedService.setOrgGoal(id: id, goal: goal)
                    return ["session_id": .string(idStr), "org_goal": goal.map { .string($0) } ?? .null]
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
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                // cwd is optional (#639): the web UI's "+" add-terminal button
                // sends only session_id — it can't reliably know the worktree
                // path. Default to the session's primary worktree — mirroring
                // SessionService.addTerminal — then devRoot, so the derived
                // path always satisfies the traversal guard below.
                let cwd: String
                if let explicit = params["cwd"]?.stringValue, !explicit.isEmpty {
                    cwd = explicit
                } else {
                    cwd = await MainActor.run {
                        capturedAppState.primaryWorktree(for: sessionID)?.worktreePath ?? devRoot
                    }
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
                                // Agent TUIs get the alt-buffer scroll model;
                                // plain shells keep the unified scrollback
                                // (ADR-0013). `agentKind` can't discriminate —
                                // it always resolves to a default.
                                agentSurface: terminal.isAgentSurface(session: session),
                                usesAlternateScreen: AgentRegistry.shared.usesAlternateScreen(for: session?.agentKind),
                                newWindowTimeout: 3.0
                            )
                        }
                        terminal.tmuxBinding = binding
                    } catch {
                        // The tmux window never materialized. Don't pretend the
                        // launch succeeded (#408): surface it so the UI shows a
                        // Retry affordance and the CLI caller reports honestly
                        // instead of leaving a silent window-less terminal.
                        CrowLog.info("[Crow] tmux registerTerminal failed after retries (\(error)); surfacing launch failure")
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
                // Windows stuck in the alternate-screen buffer or capped at the
                // old 5000-line history-limit can't show full scroll-up history
                // and can only be healed by recreation (CROW-804). Read the live
                // set once so the web UI can badge the affected tabs.
                // Paired with which windows run the agent-TUI scroll model
                // (ADR-0013) — read from tmux (`alternate-screen` per window)
                // rather than inferred client-side, so `app.js` routes the wheel
                // on the SAME ground truth the daemon actually applied. One
                // combined read so this RPC forks a single `tmux` subprocess.
                // `nil` means the read FAILED (tmux down / timed out), which is
                // not the same as "no such windows" — see the agent_surface
                // fallback below.
                let classification = await MainActor.run {
                    TmuxBackend.shared.windowScrollbackClassification()
                }
                let degraded = classification?.degraded ?? []
                // For the fallback below, when tmux couldn't answer.
                let session = await MainActor.run {
                    capturedAppState.sessions.first(where: { $0.id == id })
                }
                let items: [JSONValue] = terms.map { t in
                    // `readiness` lets CLI callers (setup.sh) verify the agent
                    // actually started rather than assuming a launch succeeded
                    // (#408). Defaults to `uninitialized` for un-tracked shells.
                    .object([
                        "id": .string(t.id.uuidString),
                        "name": .string(t.name),
                        "session_id": .string(t.sessionID.uuidString),
                        "managed": .bool(t.isManaged),
                        // `window` is the tmux window index the web `/terminal` WS
                        // selects to stream this terminal. The web UI shows a blank
                        // pane without it (the retired curated daemon handler used
                        // to provide it — CROW-593 review regression).
                        "window": t.tmuxBinding.map { .int($0.windowIndex) } ?? .null,
                        "readiness": .string((readiness[t.id] ?? .uninitialized).rawValue),
                        // True when this terminal's window has degraded scrollback
                        // and needs a recreate (CROW-804). Never degraded when
                        // there's no window binding yet.
                        "scrollback_degraded": .bool(t.tmuxBinding.map { degraded.contains($0.windowIndex) } ?? false),
                        // True when this terminal is an agent-TUI surface that
                        // owns its own viewport + scrollback (ADR-0013). The web
                        // client routes the wheel and the mouse-mode swallow on
                        // this.
                        //
                        // tmux is authoritative when it ANSWERED and this
                        // terminal has a window. Otherwise — no binding yet, or
                        // the read failed — fall back to the SAME predicate the
                        // daemon registers the window with, so the two agree
                        // (including for the Manager, whose terminal carries no
                        // `isManaged` flag). Failing to `false` instead would
                        // tell the client to swallow mouse modes and scroll
                        // locally while tmux has that window in the alt buffer,
                        // where there is no scrollback to scroll.
                        "agent_surface": .bool(
                            classification.flatMap { c in
                                t.tmuxBinding.map { c.agentSurfaces.contains($0.windowIndex) }
                            } ?? t.isAgentSurface(session: session)),
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
            // Heal a terminal whose tmux window has degraded scrollback — stuck
            // in the alternate-screen buffer and/or capped at the old 5000-line
            // history-limit, which tmux can't fix in place (CROW-804). Kills the
            // window and rebuilds a fresh, correctly-configured one, relaunching
            // the agent (`claude --continue`). Destructive to the running agent,
            // so the web UI confirms before calling this.
            "recreate-terminal": { @Sendable params in
                guard let sessionIDStr = params["session_id"]?.stringValue,
                      let sessionID = UUID(uuidString: sessionIDStr),
                      let terminalIDStr = params["terminal_id"]?.stringValue,
                      let terminalID = UUID(uuidString: terminalIDStr) else {
                    throw RPCError.invalidParams("session_id and terminal_id required")
                }
                return try await MainActor.run {
                    guard capturedService.recreateTerminalSurface(
                        sessionID: sessionID, terminalID: terminalID, devRoot: devRoot) else {
                        // False = terminal not found OR the fresh tmux window
                        // failed to register (the old window was killed, so the
                        // terminal is now unbound). Surface it either way (CROW-804).
                        throw RPCError.applicationError("Could not recreate terminal (not found or tmux window failed to register)")
                    }
                    return ["recreated": .bool(true)]
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
                CrowLog.info("crow send: text length=\(text.count), ends_with_newline=\(text.hasSuffix("\n")), ends_with_cr=\(text.hasSuffix("\r"))")
                // Resolved OFF the MainActor: `resolveCrowBinary` stats and may
                // create the `.claude/bin/crow` symlink, and blocking I/O on the
                // MainActor is what wedged the daemon's RPC surface in #892.
                // It only needs `devRoot`, so hoisting costs nothing.
                let crowPath = ClaudeHookConfigWriter.resolveCrowBinary(devRoot: devRoot)
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
                        let wtPath = capturedAppState.primaryWorktree(for: sessionID)?.worktreePath
                        // #861 review r17 (Yellow 1): the `send` RPC is a launch path
                        // too. An operator recovering a dead Grok `.review` pane the
                        // documented way — `crow send <term> "grok -c"` — reopens the
                        // clone right here; `commandLaunchesToken("grok -c", "grok")`
                        // matches. So strip the clone's committed config + seed trust
                        // FIRST, via the SAME shared gate as the four SessionService
                        // paths, before `prepareAgentLaunchText` (re)writes Crow's clean
                        // `.grok/hooks/crow.json` — otherwise a hostile `.grok/hooks/*.json`
                        // restored by the review skill's `gh pr checkout` fires on that
                        // resume. Gated on the same agent-launch detection as the hook
                        // write, so a plain `crow send "yes"` doesn't re-strip. Strip is
                        // a no-op unless this is a Grok `.review` clone.
                        if let wtPath,
                           AgentLaunch.commandLaunchesAgent(text, agent: agent) {
                            SessionService.prepareWorktreeForAgentLaunch(
                                agentKind: session.agentKind,
                                sessionKind: session.kind,
                                worktreePath: wtPath,
                                ownership: SessionService.HookOwnership.snapshot(
                                    capturedAppState, crowPath: crowPath))
                        }
                        let prepared = AgentLaunch.prepareAgentLaunchText(
                            command: text,
                            agent: agent,
                            sessionID: sessionID,
                            worktreePath: wtPath,
                            crowPath: crowPath,
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
                        CrowLog.info("[Crow] crow send for unknown terminal \(terminalID); ignoring")
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
            "edit-link": { @Sendable params in
                guard let idStr = params["session_id"]?.stringValue, let sessionID = UUID(uuidString: idStr) else {
                    throw RPCError.invalidParams("session_id required")
                }
                let linkID = params["link_id"]?.stringValue.flatMap { UUID(uuidString: $0) }
                let selectorURL = params["url"]?.stringValue
                guard linkID != nil || selectorURL != nil else {
                    throw RPCError.invalidParams("link_id or url required to identify the link")
                }
                let newLabel = params["label"]?.stringValue
                let newURL = params["new_url"]?.stringValue
                // Blank label/URL would break URL-keyed consumers; reject them
                // like add-link does rather than silently wiping a field.
                if let newLabel, newLabel.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw RPCError.invalidParams("label must not be empty")
                }
                if let newURL, newURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw RPCError.invalidParams("new_url must not be empty")
                }
                var newType: LinkType?
                if let typeStr = params["type"]?.stringValue {
                    guard let parsed = LinkType(rawValue: typeStr) else {
                        throw RPCError.invalidParams("invalid type '\(typeStr)' (expected ticket, pr, repo, or custom)")
                    }
                    newType = parsed
                }
                guard newLabel != nil || newURL != nil || newType != nil else {
                    throw RPCError.invalidParams("at least one of label, new_url, type required")
                }
                func matches(_ l: SessionLink) -> Bool {
                    (linkID != nil && l.id == linkID) || (selectorURL != nil && l.url == selectorURL)
                }
                func apply(_ l: inout SessionLink) {
                    if let newLabel { l.label = newLabel }
                    if let newURL { l.url = newURL }
                    if let newType { l.linkType = newType }
                }
                return await MainActor.run {
                    var updated = 0
                    if var existing = capturedAppState.links[sessionID] {
                        for i in existing.indices where matches(existing[i]) {
                            apply(&existing[i])
                            updated += 1
                        }
                        capturedAppState.links[sessionID] = existing
                    }
                    capturedStore.mutate { data in
                        for i in data.links.indices where data.links[i].sessionID == sessionID && matches(data.links[i]) {
                            apply(&data.links[i])
                        }
                    }
                    return ["updated": .int(updated)]
                }
            },
            "hook-event": { @Sendable params in
                guard let eventName = params["event_name"]?.stringValue else {
                    // Deliberately not logged: a params-shaped request is a
                    // caller bug (the CLI makes --event required), the RPC error
                    // already signals it, and an un-deduped per-request log here
                    // would be the flood the unresolved-session site below is
                    // written to avoid (#903 review).
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
                        let tool = hookToolName(from: payload) ?? "unknown"
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
                    // Resolve session — `cwd` is authoritative, and a provided
                    // id is trusted only when cwd can't answer.
                    //
                    // cwd wins because it describes which session is *actually
                    // running*, whereas `--session` only describes which file
                    // the command was written into — and one settings file is
                    // read by more sessions than the one it was written for. A
                    // git worktree's `.git` is a file pointing at the main
                    // clone, and project-root resolution follows it, so a
                    // worktree session loads the **main clone's**
                    // `.claude/settings.local.json` in addition to its own
                    // (#915). The main clone's block therefore fires inside
                    // every worktree session of that repo.
                    //
                    // That block is not necessarily stale — if a session really
                    // does run in the main clone, its uuid is live and
                    // `ClaudeHookRepair` rightly leaves the file alone — so the
                    // old "a live id wins" rule attributed every worktree
                    // session's events to the main clone's session, and fired
                    // each event twice (once per block). Dropping the mismatch
                    // fixes attribution and the duplicate in one step, for the
                    // files already on disk, with no change to what we write.
                    //
                    // Unchanged below the first branch: an unknown-but-provided
                    // id is still recorded rather than dropped (#897 — a stale
                    // file's uuid can outlive its session, and recording under
                    // the id we were handed beats losing the event), and an
                    // agent whose cwd matches no registered worktree still
                    // falls back to the provided id.
                    let liveSessionIDs = Set(capturedAppState.sessions.map(\.id))
                    let sessionID: UUID
                    // Only *live* owners count. A row can outlive its session
                    // (orphan recovery, a failed delete), and letting a dead one
                    // own the directory would drop a live session's events.
                    let owners = cwd.map {
                        capturedAppState.sessionIDs(forWorktreePath: $0)
                            .filter(liveSessionIDs.contains)
                    } ?? []
                    if let cwd, !owners.isEmpty {
                        let provided = providedSessionID
                        // Ids we honor over `owners`' arbitrary pick:
                        //
                        //  - One that owns the directory. With two rows on one
                        //    path the pick is a coin flip, so an id that owns it
                        //    is always preferred over whichever came first.
                        //  - The Manager. Its block lives at devRoot and is
                        //    matched by constant, never by path, everywhere else
                        //    (cf. `ClaudeHookRepair.sweep`); if devRoot were ever
                        //    registered as a worktree, path-based routing would
                        //    hijack — or silence — the session that orchestrates
                        //    everything.
                        let honored = provided.map {
                            owners.contains($0) || $0 == AppState.managerSessionID
                        } ?? false
                        // Anything else that is live is foreign to this
                        // directory: an inherited block. A provided id that is
                        // *not* live is #897's stale uuid, which
                        // `unknownSessionFallsBackToCwd` re-routes here rather
                        // than discards.
                        if let provided, !honored, liveSessionIDs.contains(provided) {
                            logForeignHookDropOnce(
                                eventName: eventName, cwd: cwd,
                                provided: provided, resolved: owners[0])
                            throw RPCError.invalidParams(
                                "hook config for session \(provided.uuidString) fired in a"
                                + " worktree owned by \(owners[0].uuidString); dropped as inherited")
                        }
                        if let provided, honored {
                            sessionID = provided
                        } else {
                            sessionID = owners[0]
                        }
                    } else if let provided = providedSessionID {
                        sessionID = provided
                    } else {
                        // No id, and no worktree matched the payload cwd: every
                        // event for this session is dropped. Since the client no
                        // longer surfaces this (fire-and-forget, #903), log it —
                        // deduped per cwd, because a global hook config with no
                        // --session run from a cwd outside any registered
                        // worktree (Codex/OpenCode/Antigravity; cf. #897)
                        // re-fires it on every event.
                        logUnresolvedHookDropOnce(eventName: eventName, cwd: cwd)
                        throw RPCError.invalidParams("session_id required or resolvable from payload cwd")
                    }
                    let sessionIsLive = liveSessionIDs.contains(sessionID)
                    let sessionIDStr = sessionID.uuidString

                    if hookDebug {
                        let shortID = String(sessionIDStr.prefix(8))
                        let keys = payload.keys.sorted().joined(separator: ",")
                        CrowLog.info("[hook-event] session=\(shortID) event=\(eventName) payload-keys=[\(keys)]")
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
                        toolName: hookToolName(from: payload),
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

                    // Count completed compactions (ADR 0008 follow-up 3).
                    // `noteCompactionEvent` and the persist path shipped with
                    // #704, but nothing ever called this — `PostCompact` fell
                    // through to the signal source's `default`, so the grade's
                    // heaviest penalty was inert on real data. Wired in
                    // CROW-983.
                    if eventName == SessionHookState.compactionEventName {
                        state.noteCompactionEvent(eventName)
                        // A Manager never reaches a terminal status, so it has
                        // no snapshot to persist the running total into.
                        // Attribute its compactions to the current ISO week as
                        // they happen.
                        if capturedAppState.isManagerSession(sessionID) {
                            capturedService.noteManagerCompaction(sessionID: sessionID)
                        }
                    }

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
                        CrowLog.info("[hook-event] session=\(shortID) event=\(eventName) state=\(stateBefore.rawValue)→\(state.activityState.rawValue)")
                    }

                    // Persist the color-driving state only when it actually changed,
                    // so sidebar colors survive a quit→relaunch (#367). Excluding
                    // lastToolActivity means frequent PostToolUse events don't write.
                    //
                    // Gated on the session still existing: a stale hook block
                    // naming a deleted session would otherwise keep appending
                    // `hookStates` rows keyed to a uuid nothing ever prunes
                    // (#897). `reseed` only filters those on read.
                    let snapshotAfter = state.persistedSnapshot
                    if sessionIsLive && snapshotAfter != snapshotBefore {
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
