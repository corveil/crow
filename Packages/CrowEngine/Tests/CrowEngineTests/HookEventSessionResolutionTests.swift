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
    @Test("a live session_id is used verbatim when no worktree matches the cwd")
    func liveSessionIDWins() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)

        let a = Session(name: "a")
        appState.sessions.append(a)

        let router = makeRouter(appState, store, devRoot: tmp.path)
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(a.id.uuidString),
                "event_name": .string("Stop"),
                // An agent that `cd`s outside its worktree, or a directory Crow
                // has no row for: cwd can't answer, so the provided id stands.
                "payload": .object(["cwd": .string(tmp.appendingPathComponent("elsewhere").path)]),
            ]))

        #expect(response.result?["session_id"]?.stringValue == a.id.uuidString)
    }

    /// #915 — the inversion of the old `liveSessionIDWins` contract.
    ///
    /// That test asserted a live `session_id` beat a `cwd` resolving elsewhere.
    /// It was the bug: a linked worktree also loads its **main clone's**
    /// `.claude/settings.local.json`, so the main clone's block fires inside
    /// every worktree session of that repo. If the main clone hosts a live
    /// session, the old rule attributed the worktree session's events to it and
    /// double-counted every one (both blocks fire). cwd is the only signal that
    /// says which session is actually running, so it wins — and a live id that
    /// does not own this directory is an inherited copy, not an event.
    @Test("a live session_id that doesn't own the cwd is dropped as inherited")
    func foreignLiveSessionIDIsDropped() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)

        let mainClone = Session(name: "main-clone")
        let worktree = Session(name: "worktree")
        appState.sessions.append(contentsOf: [mainClone, worktree])
        let worktreePath = tmp.appendingPathComponent("ws/repo-1").path
        appState.worktrees[worktree.id] = [
            SessionWorktree(sessionID: worktree.id, repoName: "repo", repoPath: worktreePath,
                            worktreePath: worktreePath, branch: "feature/x", isPrimary: true),
        ]

        let router = makeRouter(appState, store, devRoot: tmp.path)
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(mainClone.id.uuidString),
                "event_name": .string("Stop"),
                "payload": .object(["cwd": .string(worktreePath)]),
            ]))

        #expect(response.result == nil)
        #expect(response.error != nil)
        // The worktree session's own block reports the same event, so nothing
        // is lost — and neither session gets a spurious row from this copy.
        #expect(store.data.hookStates?[mainClone.id.uuidString] == nil)
    }

    @Test("a session_id that owns the cwd is used")
    func owningSessionIDIsUsed() async throws {
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
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(live.id.uuidString),
                "event_name": .string("Stop"),
                "payload": .object(["cwd": .string(worktreePath)]),
            ]))

        #expect(response.result?["session_id"]?.stringValue == live.id.uuidString)
    }

    /// A worktree row can outlive its session (orphan recovery, a failed
    /// delete). A dead owner must not be allowed to drop a live session's
    /// events — the old code never liveness-checked the cwd side.
    @Test("a worktree row for a dead session doesn't drop a live session's event")
    func deadOwnerDoesNotDropLiveSession() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)

        let live = Session(name: "live")
        appState.sessions.append(live)
        let ghost = UUID()  // never added to `sessions`
        let worktreePath = tmp.appendingPathComponent("ws/repo-1").path
        appState.worktrees[ghost] = [
            SessionWorktree(sessionID: ghost, repoName: "repo", repoPath: worktreePath,
                            worktreePath: worktreePath, branch: "feature/x", isPrimary: true),
        ]

        let router = makeRouter(appState, store, devRoot: tmp.path)
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(live.id.uuidString),
                "event_name": .string("Stop"),
                "payload": .object(["cwd": .string(worktreePath)]),
            ]))

        #expect(response.result?["session_id"]?.stringValue == live.id.uuidString)
    }

    /// Two sessions on one path is reachable (orphan recovery, a `setup.sh`
    /// retry, a shared secondary repo). The winner is then an arbitrary
    /// dictionary pick, so a provided id that is *among* the owners must be
    /// honored — otherwise a coin flip decides whether a session records
    /// anything at all for the life of the daemon.
    @Test("an ambiguous worktree path honors the provided owner")
    func ambiguousPathPrefersProvidedOwner() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)

        let a = Session(name: "a")
        let b = Session(name: "b")
        appState.sessions.append(contentsOf: [a, b])
        let shared = tmp.appendingPathComponent("ws/repo-1").path
        for id in [a.id, b.id] {
            appState.worktrees[id] = [
                SessionWorktree(sessionID: id, repoName: "repo", repoPath: shared,
                                worktreePath: shared, branch: "feature/x", isPrimary: true),
            ]
        }

        let router = makeRouter(appState, store, devRoot: tmp.path)
        for session in [a, b] {
            let response = await router.handle(request: JSONRPCRequest(
                id: 1, method: "hook-event", params: [
                    "session_id": .string(session.id.uuidString),
                    "event_name": .string("Stop"),
                    "payload": .object(["cwd": .string(shared)]),
                ]))
            #expect(response.result?["session_id"]?.stringValue == session.id.uuidString)
        }
    }

    /// The Manager's cwd is the dev root and it has no `SessionWorktree` row, so
    /// it normally lands in the provided-id branch. Should devRoot ever be
    /// registered as a worktree, a path-based drop would silence the session
    /// that orchestrates everything — so the Manager is never dropped.
    @Test("the Manager is never dropped, even if its cwd is a registered worktree")
    func managerIsNeverDropped() async throws {
        let tmp = tempDir()
        let appState = AppState()
        let store = JSONStore(directory: tmp)

        let manager = Session(id: AppState.managerSessionID, name: "Manager")
        let other = Session(name: "other")
        appState.sessions.append(contentsOf: [manager, other])
        appState.worktrees[other.id] = [
            SessionWorktree(sessionID: other.id, repoName: "repo", repoPath: tmp.path,
                            worktreePath: tmp.path, branch: "main", isPrimary: true),
        ]

        let router = makeRouter(appState, store, devRoot: tmp.path)
        let response = await router.handle(request: JSONRPCRequest(
            id: 1, method: "hook-event", params: [
                "session_id": .string(AppState.managerSessionID.uuidString),
                "event_name": .string("Stop"),
                "payload": .object(["cwd": .string(tmp.path)]),
            ]))

        #expect(response.result?["session_id"]?.stringValue
                == AppState.managerSessionID.uuidString)
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
