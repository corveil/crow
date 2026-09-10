import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// CROW-1218 — the first worktree of a session is primary even without the flag.
@Suite struct AddWorktreePrimaryTests {
    @MainActor
    private func router(appState: AppState, store: JSONStore, devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: store, git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    private func materialize(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "gitdir: /dev/null".write(
            toFile: (path as NSString).appendingPathComponent(".git"),
            atomically: true, encoding: .utf8)
    }

    @Test @MainActor func firstWorktreeIsPrimaryWithoutFlag() async throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1218-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wt = (root as NSString).appendingPathComponent("wt-1")
        try materialize(wt)

        let appState = AppState()
        let store = JSONStore.temporary()
        let session = Session(name: "crow-1218")
        appState.sessions.append(session)

        let resp = await router(appState: appState, store: store, devRoot: root).handle(
            request: JSONRPCRequest(id: 1, method: "add-worktree", params: [
                "session_id": .string(session.id.uuidString),
                "repo": .string("crow"),
                "path": .string(wt),
                "branch": .string("feature/crow-1218"),
            ]))
        #expect(resp.error == nil)
        #expect(resp.result?["primary"]?.boolValue == true)
        let stored = appState.worktrees(for: session.id)
        #expect(stored.count == 1)
        #expect(stored[0].isPrimary == true)
        #expect(stored[0].branch == "feature/crow-1218")
    }

    @Test @MainActor func secondWorktreeIsNotPrimaryWithoutFlag() async throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1218-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wt1 = (root as NSString).appendingPathComponent("wt-1")
        let wt2 = (root as NSString).appendingPathComponent("wt-2")
        try materialize(wt1)
        try materialize(wt2)

        let appState = AppState()
        let store = JSONStore.temporary()
        let session = Session(name: "crow-1218")
        appState.sessions.append(session)

        let r = router(appState: appState, store: store, devRoot: root)
        let first = await r.handle(request: JSONRPCRequest(id: 1, method: "add-worktree", params: [
            "session_id": .string(session.id.uuidString),
            "repo": .string("crow"),
            "path": .string(wt1),
            "branch": .string("feature/one"),
        ]))
        #expect(first.error == nil)
        #expect(first.result?["primary"]?.boolValue == true)

        let second = await r.handle(request: JSONRPCRequest(id: 2, method: "add-worktree", params: [
            "session_id": .string(session.id.uuidString),
            "repo": .string("other"),
            "path": .string(wt2),
            "branch": .string("feature/two"),
        ]))
        #expect(second.error == nil)
        #expect(second.result?["primary"]?.boolValue == false)

        let stored = appState.worktrees(for: session.id)
        #expect(stored.count == 2)
        #expect(stored[0].isPrimary == true)
        #expect(stored[1].isPrimary == false)
        #expect(appState.primaryWorktree(for: session.id)?.worktreePath == wt1)
    }

    @Test @MainActor func explicitPrimaryStillMarksFirst() async throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1218-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wt = (root as NSString).appendingPathComponent("wt-1")
        try materialize(wt)

        let appState = AppState()
        let session = Session(name: "crow-1218")
        appState.sessions.append(session)

        let resp = await router(appState: appState, store: JSONStore.temporary(), devRoot: root).handle(
            request: JSONRPCRequest(id: 1, method: "add-worktree", params: [
                "session_id": .string(session.id.uuidString),
                "repo": .string("crow"),
                "path": .string(wt),
                "branch": .string("feature/crow-1218"),
                "primary": .bool(true),
            ]))
        #expect(resp.error == nil)
        #expect(appState.worktrees(for: session.id).first?.isPrimary == true)
    }
}
