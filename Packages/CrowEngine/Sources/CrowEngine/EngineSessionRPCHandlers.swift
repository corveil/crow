import CrowCore
import CrowIPC
import CrowPersistence
import Foundation

/// Session reads, ticket metadata, and `list-worktrees`.
///
/// Extracted from `makeEngineRouter`'s dictionary literal (CROW-1174). These
/// methods have no daemon registration — `crowd` answers them only via
/// `fallback: makeEngineRouter(ctx)`.
@MainActor
func makeEngineSessionHandlers(
    appState: AppState,
    store: JSONStore,
    sessionService: SessionService,
    tracker: IssueTracker?
) -> [String: CommandRouter.Handler] {
    let capturedAppState = appState
    let capturedStore = store
    let capturedService = sessionService
    let capturedTracker = tracker
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134 / CROW-1174).
    let handlers: [String: CommandRouter.Handler] = [
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
                    "is_explore": .bool(s.isExplore),
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
        // characters) as the sibling free-text handlers (`rename-session`
        // via `SessionService`, daemon `new-session`), since this newly
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
    ]
    return handlers
}
