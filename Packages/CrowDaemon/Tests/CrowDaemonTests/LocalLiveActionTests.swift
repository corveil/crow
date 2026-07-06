import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowEngine
import CrowProvider
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// M-E slice (CROW-581): the six formerly forward-only handlers gained app-down
/// local paths off the services the daemon already owns — so the web UI looks
/// the same app-up or app-down. Reads (`get-pr-status` / `list-sessions-live`)
/// answer from the daemon's own `appState` (PR status populated by its board
/// poll); actions (`mark-issue-done` / `add-merge-label` / `delete-session` /
/// `quick-action`) delegate to the owned IssueTracker / SessionService /
/// AutoRespondCoordinator, and error clearly when that owning service is absent.
///
/// These suites pin the **app-down** contract (`forwardSocket: nil`). The
/// forward-when-app-up path is unchanged (forward runs first), so nothing here
/// exercises a live app socket.
@Suite struct LocalLiveReadTests {
    @MainActor
    private func offlineRouter(appState: AppState) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: JSONStore(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil, forwardSocket: nil)
    }

    @Test @MainActor func getPRStatusReadsLocalAppStateWhenAppDown() async {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.prStatus[session.id] = PRStatus(
            checksPass: .failing, reviewStatus: .approved, mergeable: .mergeable,
            failedCheckNames: ["build"], headSha: "abc", isOpen: true)

        let resp = await offlineRouter(appState: appState).handle(request: JSONRPCRequest(
            id: 1, method: "get-pr-status", params: ["session_id": .string(session.id.uuidString)]))
        #expect(resp.error == nil)
        #expect(resp.result?["has_pr"]?.boolValue == true)
        #expect(resp.result?["checks"]?.stringValue == "failing")
        #expect(resp.result?["review"]?.stringValue == "approved")
        #expect(resp.result?["merge"]?.stringValue == "mergeable")
        #expect(resp.result?["is_open"]?.boolValue == true)
        #expect(resp.result?["failed_checks"]?.arrayValue?.first?.stringValue == "build")
    }

    @Test @MainActor func getPRStatusReturnsNoPRWhenUnknown() async {
        let resp = await offlineRouter(appState: AppState()).handle(request: JSONRPCRequest(
            id: 1, method: "get-pr-status", params: ["session_id": .string(UUID().uuidString)]))
        #expect(resp.error == nil)
        #expect(resp.result?["has_pr"]?.boolValue == false)
    }

    @Test @MainActor func getPRStatusRejectsMissingSessionID() async {
        let resp = await offlineRouter(appState: AppState())
            .handle(request: JSONRPCRequest(id: 1, method: "get-pr-status"))
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }

    @Test @MainActor func listSessionsLiveBuildsMapFromLocalAppState() async {
        AgentRegistry.shared.register(ClaudeCodeAgent())
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        appState.prStatus[session.id] = PRStatus(
            checksPass: .passing, reviewStatus: .reviewRequired, mergeable: .mergeable,
            failedCheckNames: [], headSha: "abc", isOpen: true)
        appState.links[session.id] = [SessionLink(
            sessionID: session.id, label: "PR #7", url: "https://github.com/acme/api/pull/7", linkType: .pr)]
        // Remote-control active = a session terminal launched with --rc.
        let term = SessionTerminal(sessionID: session.id, name: "agent", cwd: "/tmp", isManaged: true)
        appState.terminals[session.id] = [term]
        appState.remoteControlActiveTerminals.insert(term.id)

        let resp = await offlineRouter(appState: appState)
            .handle(request: JSONRPCRequest(id: 1, method: "list-sessions-live"))
        #expect(resp.error == nil)
        let entry = resp.result?["sessions"]?.objectValue?[session.id.uuidString]?.objectValue
        #expect(entry?["remote_control_available"]?.boolValue == true)   // claudeCode supports RC
        #expect(entry?["remote_control_active"]?.boolValue == true)
        #expect(entry?["pr"]?.objectValue?["has_pr"]?.boolValue == true)
        #expect(entry?["pr"]?.objectValue?["review"]?.stringValue == "reviewRequired")
        #expect(entry?["pr_link"]?.objectValue?["url"]?.stringValue == "https://github.com/acme/api/pull/7")
    }

    @Test @MainActor func listSessionsLiveReportsNoPRWhenUnknown() async {
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        let resp = await offlineRouter(appState: appState)
            .handle(request: JSONRPCRequest(id: 1, method: "list-sessions-live"))
        let entry = resp.result?["sessions"]?.objectValue?[session.id.uuidString]?.objectValue
        #expect(entry?["pr"]?.objectValue?["has_pr"]?.boolValue == false)
        #expect(entry?["remote_control_active"]?.boolValue == false)
    }
}

/// App-down local paths for the four action handlers. Where invoking the real
/// engine method would hit a provider CLI / disk teardown, we assert the guard
/// precedence instead (owning-service-nil → applicationError; service-present →
/// param validation is reached) — the underlying behavior is already covered by
/// the CrowEngine tests that own IssueTracker/SessionService.
@Suite struct LocalLiveActionTests {
    @MainActor
    private func router(
        appState: AppState = AppState(),
        tracker: IssueTracker? = nil,
        sessionService: SessionService? = nil,
        autoRespond: AutoRespondCoordinator? = nil,
        jobScheduler: JobScheduler? = nil
    ) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: JSONStore(), git: GitManager(),
            devRoot: NSTemporaryDirectory(), cockpit: nil, forwardSocket: nil,
            tracker: tracker, sessionService: sessionService, autoRespond: autoRespond,
            jobScheduler: jobScheduler)
    }

    // MARK: mark-issue-done / add-merge-label

    @Test @MainActor func ticketActionsErrorWithoutTracker() async {
        for method in ["mark-issue-done", "add-merge-label"] {
            let resp = await router().handle(request: JSONRPCRequest(
                id: 1, method: method, params: ["session_id": .string(UUID().uuidString)]))
            #expect(resp.error?.code == RPCErrorCode.applicationError, "\(method) needs a tracker when app down")
        }
    }

    @Test @MainActor func ticketActionsReachLocalPathAndValidateParams() async {
        // Tracker present → the local path is entered; a missing session_id is
        // then a param error (proves we didn't stop at the tracker guard).
        let appState = AppState()
        let tracker = IssueTracker(appState: appState, providerManager: ProviderManager())
        for method in ["mark-issue-done", "add-merge-label"] {
            let resp = await router(appState: appState, tracker: tracker)
                .handle(request: JSONRPCRequest(id: 1, method: method))
            #expect(resp.error?.code == RPCErrorCode.invalidParams, "\(method) should validate params locally")
        }
    }

    // MARK: delete-session

    @Test @MainActor func deleteSessionErrorsWithoutSessionService() async {
        let resp = await router().handle(request: JSONRPCRequest(
            id: 1, method: "delete-session", params: ["session_id": .string(UUID().uuidString)]))
        #expect(resp.error?.code == RPCErrorCode.applicationError)
    }

    @Test @MainActor func deleteSessionRejectsManagerSession() async {
        let appState = AppState()
        let service = SessionService(
            store: JSONStore(), appState: appState,
            providerManager: ProviderManager(), hostBridge: NoopHostBridge())
        let resp = await router(appState: appState, sessionService: service).handle(request: JSONRPCRequest(
            id: 1, method: "delete-session",
            params: ["session_id": .string(AppState.managerSessionID.uuidString)]))
        #expect(resp.error?.code == RPCErrorCode.applicationError)
        #expect(resp.error?.message == "Cannot delete manager session")
    }

    // MARK: run-job

    @Test @MainActor func runJobErrorsWithoutScheduler() async {
        // App down (forwardSocket nil) and no local JobScheduler → applicationError.
        let resp = await router().handle(request: JSONRPCRequest(
            id: 1, method: "run-job", params: ["job_id": .string(UUID().uuidString)]))
        #expect(resp.error?.code == RPCErrorCode.applicationError)
    }

    @Test @MainActor func runJobReachesLocalPathAndValidatesJobID() async {
        // Scheduler present → the local path is entered; a missing job_id is then a
        // param error (proves we didn't stop at the scheduler guard).
        let appState = AppState()
        let service = SessionService(
            store: JSONStore(), appState: appState,
            providerManager: ProviderManager(), hostBridge: NoopHostBridge())
        let scheduler = JobScheduler(appState: appState, sessionService: service)
        let resp = await router(appState: appState, jobScheduler: scheduler)
            .handle(request: JSONRPCRequest(id: 1, method: "run-job"))
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
    }

    // MARK: get-state

    @Test @MainActor func getStateReturnsDecodableSnapshotOfLocalAppState() async throws {
        let appState = AppState()
        let sid = UUID(), tid = UUID()
        appState.sessions = [Session(id: sid, name: "feat", kind: .work)]
        appState.terminals[sid] = [SessionTerminal(
            id: tid, sessionID: sid, name: "Claude Code", cwd: "/tmp",
            command: nil, isManaged: true, tmuxBinding: nil)]
        appState.terminalReadiness[tid] = .agentLaunched

        let resp = await router(appState: appState)
            .handle(request: JSONRPCRequest(id: 1, method: "get-state"))
        #expect(resp.error == nil)

        // The whole result IS a DaemonStateSnapshot — a client decodes it directly.
        let result = try #require(resp.result)
        let data = try JSONEncoder().encode(result)
        let snap = try JSONDecoder().decode(DaemonStateSnapshot.self, from: data)
        #expect(snap.sessions.map(\.id) == [sid])
        #expect(snap.terminals.map(\.id) == [tid])
        #expect(snap.terminalReadiness[tid.uuidString] == .agentLaunched)
    }

    // MARK: quick-action

    @Test @MainActor func quickActionErrorsWithoutCoordinator() async {
        let resp = await router().handle(request: JSONRPCRequest(
            id: 1, method: "quick-action",
            params: ["session_id": .string(UUID().uuidString), "action": .string("mergePR")]))
        #expect(resp.error?.code == RPCErrorCode.applicationError)
    }

    @Test @MainActor func quickActionValidatesActionWhenCoordinatorPresent() async {
        let appState = AppState()
        let coordinator = AutoRespondCoordinator(
            appState: appState, providerManager: ProviderManager(),
            settingsProvider: { AutoRespondSettings() })
        let resp = await router(appState: appState, autoRespond: coordinator).handle(request: JSONRPCRequest(
            id: 1, method: "quick-action", params: ["session_id": .string(UUID().uuidString)]))
        #expect(resp.error?.code == RPCErrorCode.invalidParams)   // missing/invalid action
    }

    @Test @MainActor func quickActionDispatchesLocallyWhenCoordinatorPresent() async {
        // No managed terminal → dispatchManual silently skips, but the handler
        // still returns the dispatched shape (the app behaves identically).
        let appState = AppState()
        let session = Session(name: "s", kind: .work, agentKind: .claudeCode)
        appState.sessions = [session]
        let coordinator = AutoRespondCoordinator(
            appState: appState, providerManager: ProviderManager(),
            settingsProvider: { AutoRespondSettings() })
        let resp = await router(appState: appState, autoRespond: coordinator).handle(request: JSONRPCRequest(
            id: 1, method: "quick-action",
            params: ["session_id": .string(session.id.uuidString), "action": .string("mergePR")]))
        #expect(resp.error == nil)
        #expect(resp.result?["dispatched"]?.boolValue == true)
        #expect(resp.result?["action"]?.stringValue == "mergePR")
    }
}
