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
}
