import Foundation
import Testing
import CrowCore
import CrowClaude
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// #897: a `settings.local.json` bakes `--session <uuid>` into every hook
/// command, so a settings file can outlive the session it names — indefinitely,
/// in a long-lived main clone that nothing ever rewrites. The `hook-event`
/// handler used to trust that uuid unconditionally, minting hook state and a
/// persisted `hookStates` row for a session that no longer exists.
@Suite("hook-event session resolution")
@MainActor
struct HookEventSessionResolutionTests {

    private func makeRouter(
        _ appState: AppState, _ store: JSONStore, devRoot: String
    ) -> CommandRouter {
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())
        return makeEngineRouter(EngineContext(
            appState: appState,
            store: store,
            sessionService: service,
            issueTracker: nil,
            telemetryPort: nil,
            devRoot: devRoot,
            hostBridge: NoopHostBridge(),
            loadConfig: { nil },
            applyConfig: { _ in nil }
        ))
    }

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-hookevent-\(UUID().uuidString)")
    }

    /// The repair case: a stale command names a dead session, but the payload's
    /// `cwd` still identifies a live worktree — so the event is re-routed there
    /// rather than attributed to a session that no longer exists.
    @Test("an unknown session_id falls back to the worktree matching cwd")
    func unknownSessionFallsBackToCwd() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)

        let live = Session(name: "live")
        appState.sessions.append(live)
        let worktreePath = tmp.appendingPathComponent("ws/repo-1").path
        appState.worktrees[live.id] = [
            SessionWorktree(sessionID: live.id, repoName: "repo", repoPath: worktreePath,
                            worktreePath: worktreePath, branch: "feature/x", isPrimary: true),
        ]

        let router = makeRouter(appState, store, devRoot: tmp.path)
        let deadSession = UUID()
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(deadSession.uuidString),
                "event_name": .string("Stop"),
                "payload": .object(["cwd": .string(worktreePath)]),
            ]))

        #expect(response.error == nil)
        #expect(response.result?["session_id"]?.stringValue == live.id.uuidString)
    }

    /// A live session id always wins, even when `cwd` would resolve elsewhere —
    /// the fallback must not change routing for anything that works today.
    @Test("a live session_id is used verbatim")
    func liveSessionIDWins() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)

        let a = Session(name: "a")
        let b = Session(name: "b")
        appState.sessions.append(contentsOf: [a, b])
        let bPath = tmp.appendingPathComponent("ws/repo-b").path
        appState.worktrees[b.id] = [
            SessionWorktree(sessionID: b.id, repoName: "repo", repoPath: bPath,
                            worktreePath: bPath, branch: "feature/b", isPrimary: true),
        ]

        let router = makeRouter(appState, store, devRoot: tmp.path)
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(a.id.uuidString),
                "event_name": .string("Stop"),
                "payload": .object(["cwd": .string(bPath)]),
            ]))

        #expect(response.result?["session_id"]?.stringValue == a.id.uuidString)
    }

    /// An unresolvable id must still succeed. `crow hook-event` surfaces an RPC
    /// error as a non-zero exit, which Claude Code renders as exactly the
    /// "hook error" noise this work exists to remove — so we accept the event
    /// and simply decline to persist state for a session we don't have.
    @Test("an unresolvable session_id still succeeds and writes no hookStates row")
    func unresolvableSessionDoesNotErrorOrPersist() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let router = makeRouter(appState, store, devRoot: tmp.path)

        let deadSession = UUID()
        // SessionStart drives an activity-state change, so this would persist a
        // snapshot if the live-session gate were missing.
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(deadSession.uuidString),
                "event_name": .string("SessionStart"),
                "payload": .object([:]),
            ]))

        #expect(response.error == nil)
        #expect(response.result?["received"]?.boolValue == true)
        #expect(store.data.hookStates?[deadSession.uuidString] == nil)
    }
}
