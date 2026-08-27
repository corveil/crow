import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// Session lifecycle verbs (`create-manager`, `mark-in-review`, …) and `job-*`.
///
/// Extracted from `makeCommandRouter`'s dictionary literal (CROW-1134).
func makeLifecycleHandlers(
    appState: AppState,
    store: JSONStore,
    sessionService: SessionService?,
    jobScheduler: JobScheduler?,
    tracker: IssueTracker?,
    devRoot: String
) -> [String: CommandRouter.Handler] {
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134).
    let handlers: [String: CommandRouter.Handler] = [
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
    ]
    return handlers
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
