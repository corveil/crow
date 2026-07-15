import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowIPC
@testable import CrowEngine

/// Proves the engine's RPC router can be constructed and driven headlessly with
/// a `NoopHostBridge` — no AppKit, no desktop app. This is the invariant that
/// lets the `crowd` daemon host `makeEngineRouter` in a later milestone
/// (CROW-581 headless-engine migration, A7).
@Suite("makeEngineRouter smoke")
@MainActor
struct EngineRouterSmokeTests {
    @Test("router builds with NoopHostBridge and dispatches list-sessions")
    func listSessionsDispatch() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-engine-smoke-\(UUID().uuidString)")
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())

        let ctx = EngineContext(
            appState: appState,
            store: store,
            sessionService: service,
            issueTracker: nil,
            telemetryPort: nil,
            devRoot: tmp.path,
            hostBridge: NoopHostBridge(),
            loadConfig: { nil },
            applyConfig: { _ in nil }
        )
        let router = makeEngineRouter(ctx)

        let response = await router.handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
        #expect(response.error == nil)
        #expect(response.result != nil)
    }

    /// #639: the web UI's "+" add-terminal button sends only `session_id` (it
    /// can't know the worktree path). `new-terminal` must no longer reject that
    /// with `invalidParams("session_id and cwd required")` — it derives `cwd`
    /// from the session's primary worktree instead.
    ///
    /// We deliberately point the primary worktree *outside* devRoot so the
    /// derived cwd trips the path-traversal guard, which fires *before* the
    /// handler touches `TmuxBackend` (a real-tmux dependency the smoke suite
    /// avoids). Reaching that downstream guard at all proves the missing-cwd
    /// guard passed and the worktree path was derived — the #639 fix — without
    /// needing a live tmux server.
    @Test("new-terminal without cwd derives it from the primary worktree, not rejecting the request")
    func newTerminalDerivesCwdFromPrimaryWorktree() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-engine-smoke-\(UUID().uuidString)")
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())

        // Primary worktree lives OUTSIDE devRoot (home ≠ the temp devRoot), so
        // the derived cwd fails the traversal guard rather than reaching tmux.
        let sessionID = UUID()
        let outsidePath = FileManager.default.homeDirectoryForCurrentUser.path
        appState.worktrees[sessionID] = [
            SessionWorktree(sessionID: sessionID, repoName: "repo", repoPath: outsidePath,
                            worktreePath: outsidePath, branch: "feature/x", isPrimary: true),
        ]

        let ctx = EngineContext(
            appState: appState,
            store: store,
            sessionService: service,
            issueTracker: nil,
            telemetryPort: nil,
            devRoot: tmp.path,
            hostBridge: NoopHostBridge(),
            loadConfig: { nil },
            applyConfig: { _ in nil }
        )
        let router = makeEngineRouter(ctx)

        // Only session_id — no cwd, exactly like the web UI's addTerminal().
        let response = await router.handle(request: JSONRPCRequest(
            id: 2, method: "new-terminal", params: ["session_id": .string(sessionID.uuidString)]))

        // The request is no longer rejected for a missing cwd (the #639 bug)...
        #expect(response.error?.message != "session_id and cwd required")
        // ...instead the derived worktree cwd (outside devRoot here) trips the
        // traversal guard — proving cwd was derived from the primary worktree.
        #expect(response.error?.message == "Terminal cwd must be within the configured devRoot")
    }

    /// #723 (ADR 0008 follow-up 8): the `set-goal` data model, `SessionService`
    /// mutator, and `crow set-goal` CLI all shipped with #696, but no RPC ever
    /// routed the method — so the whole path silently no-op'd with nothing to
    /// catch it. This locks in the newly-wired route (`EngineRouter.swift`) and
    /// its contract, which mirrors the CLI's `validateSetGoal`: reject both /
    /// neither / a blank goal (so a missing or typo'd param can't silently wipe
    /// an existing tag), and exclude the manager session.
    @Test("set-goal routes to the mutator and enforces the CLI's validation contract")
    func setGoalRoutesToMutator() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-engine-smoke-\(UUID().uuidString)")
        let appState = AppState()
        let store = JSONStore(directory: tmp)
        let service = SessionService(store: store, appState: appState, hostBridge: NoopHostBridge())

        let session = Session(name: "goal-test")   // default kind .work; orgGoal nil
        appState.sessions.append(session)
        let id = session.id
        // A manager session — org goals don't apply to orchestration sessions.
        let manager = Session(name: "manager", kind: .manager)
        appState.sessions.append(manager)

        let ctx = EngineContext(
            appState: appState,
            store: store,
            sessionService: service,
            issueTracker: nil,
            telemetryPort: nil,
            devRoot: tmp.path,
            hostBridge: NoopHostBridge(),
            loadConfig: { nil },
            applyConfig: { _ in nil }
        )
        let router = makeEngineRouter(ctx)

        func handle(_ params: [String: JSONValue]) async -> JSONRPCResponse {
            await router.handle(request: JSONRPCRequest(id: 1, method: "set-goal", params: params))
        }
        func currentGoal() -> String? {
            appState.sessions.first(where: { $0.id == id })?.orgGoal
        }

        // Route reaches the mutator: a goal is set on the session.
        let set = await handle(["session_id": .string(id.uuidString), "goal": .string("Q3 revenue")])
        #expect(set.error == nil)
        #expect(currentGoal() == "Q3 revenue")

        // `clear: true` clears the tag.
        let cleared = await handle(["session_id": .string(id.uuidString), "clear": .bool(true)])
        #expect(cleared.error == nil)
        #expect(currentGoal() == nil)

        // Contract (mirrors CLI `validateSetGoal`) — each malformed shape is
        // rejected *without* mutating. Re-set a goal so we can prove the
        // rejected calls leave it untouched rather than clearing it.
        _ = await handle(["session_id": .string(id.uuidString), "goal": .string("keep me")])
        #expect(currentGoal() == "keep me")

        // both goal + clear → mutually exclusive.
        let both = await handle([
            "session_id": .string(id.uuidString), "clear": .bool(true), "goal": .string("x"),
        ])
        #expect(both.error != nil)
        #expect(currentGoal() == "keep me")

        // neither goal nor clear → exactly-one-required (the silent-wipe bug).
        let neither = await handle(["session_id": .string(id.uuidString)])
        #expect(neither.error != nil)
        #expect(currentGoal() == "keep me")

        // blank/whitespace goal → rejected (an empty tag can't buy the on-goal
        // alignment multiplier).
        let blank = await handle(["session_id": .string(id.uuidString), "goal": .string("   ")])
        #expect(blank.error != nil)
        #expect(currentGoal() == "keep me")

        // Over-length goal → rejected by the same `isValidSessionName` bound the
        // sibling handlers keep (a remote web client can't persist a
        // multi-megabyte tag that rides every list-sessions payload).
        let tooLong = await handle([
            "session_id": .string(id.uuidString), "goal": .string(String(repeating: "a", count: 257)),
        ])
        #expect(tooLong.error != nil)
        #expect(currentGoal() == "keep me")

        // Control characters in the goal → rejected (no escape sequences).
        let control = await handle([
            "session_id": .string(id.uuidString), "goal": .string("bad\u{07}goal"),
        ])
        #expect(control.error != nil)
        #expect(currentGoal() == "keep me")

        // Unknown session → applicationError, not a silent no-op.
        let missing = await handle(["session_id": .string(UUID().uuidString), "goal": .string("x")])
        #expect(missing.error?.message == "Session not found")

        // Manager session → rejected; org goals don't apply to orchestration.
        let mgr = await handle(["session_id": .string(manager.id.uuidString), "goal": .string("x")])
        #expect(mgr.error != nil)
        #expect(appState.sessions.first(where: { $0.id == manager.id })?.orgGoal == nil)
    }
}
