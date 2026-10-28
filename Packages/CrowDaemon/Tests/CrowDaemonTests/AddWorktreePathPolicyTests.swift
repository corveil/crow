import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// CROW-1396 — `add-worktree` accepts only `{devRoot}/{workspace}/{dir}` for a
/// configured workspace, or `{devRoot}/crow-reviews/{dir}`, and refuses
/// everything else before creating anything (no git, no directory, no row).
@Suite struct AddWorktreePathPolicyTests {
    private struct Fixture {
        let root: String
        let appState: AppState
        let session: Session
        let router: CommandRouter
    }

    @MainActor
    private func fixture() throws -> Fixture {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1396-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try ConfigStore.saveConfig(
            AppConfig(workspaces: [WorkspaceInfo(name: "Corveil"), WorkspaceInfo(name: "personal")]),
            devRoot: root)
        let appState = AppState()
        let session = Session(name: "crow-1396")
        appState.sessions.append(session)
        let router = makeCommandRouter(
            appState: appState, store: JSONStore.temporary(), git: GitManager(),
            devRoot: root, cockpit: nil)
        return Fixture(root: root, appState: appState, session: session, router: router)
    }

    /// Mirror `setup.sh`: the checkout already exists, so an accepted path
    /// records metadata only.
    private func materialize(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try "gitdir: /dev/null".write(
            toFile: (path as NSString).appendingPathComponent(".git"),
            atomically: true, encoding: .utf8)
    }

    @MainActor
    private func add(_ f: Fixture, path: String) async -> JSONRPCResponse {
        await f.router.handle(request: JSONRPCRequest(id: 1, method: "add-worktree", params: [
            "session_id": .string(f.session.id.uuidString),
            "repo": .string("crow"),
            "path": .string(path),
            "branch": .string("feature/crow-1396"),
        ]))
    }

    // MARK: - Accepted

    @Test @MainActor func acceptsWorkspaceFolder() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let wt = "\(f.root)/Corveil/crow-1396-x"
        try materialize(wt)
        let resp = await add(f, path: wt)
        #expect(resp.error == nil)
        #expect(f.appState.worktrees(for: f.session.id).count == 1)
    }

    /// Case-insensitive, as the rest of Crow is: the folder `corveil` is the
    /// configured workspace `Corveil`.
    @Test @MainActor func acceptsDifferentlyCasedWorkspace() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let wt = "\(f.root)/PERSONAL/crow-1396-x"
        try materialize(wt)
        let resp = await add(f, path: wt)
        #expect(resp.error == nil)
    }

    @Test @MainActor func acceptsReviewClone() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let wt = "\(f.root)/\(DevRootLayout.reviewsDirName)/crow-pr-1"
        try materialize(wt)
        let resp = await add(f, path: wt)
        #expect(resp.error == nil)
    }

    // MARK: - Rejected, nothing created

    @MainActor
    private func expectRejected(_ f: Fixture, path: String, mentioning needle: String) async {
        let resp = await add(f, path: path)
        #expect(resp.error?.code == RPCErrorCode.invalidParams)
        let message = resp.error?.message ?? ""
        #expect(message.contains(needle), "\(message)")
        #expect(message.contains("Corveil, personal"), "names the configured workspaces: \(message)")
        #expect(message.contains("crow workspace add"), "names the fix: \(message)")
        #expect(f.appState.worktrees(for: f.session.id).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test @MainActor func rejectsDirectlyInDevRoot() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        await expectRejected(f, path: "\(f.root)/corveil-3004-dock-greeting", mentioning: "directly in the dev root")
    }

    @Test @MainActor func rejectsNestedTooDeep() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        await expectRejected(f, path: "\(f.root)/Corveil/worktrees/x", mentioning: "too deep")
    }

    @Test @MainActor func rejectsUnconfiguredWorkspace() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        await expectRejected(f, path: "\(f.root)/bmlt-enabled/x", mentioning: "'bmlt-enabled' is not a configured workspace")
    }

    @Test @MainActor func rejectsOutsideDevRoot() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let outside = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("crow-1396-outside-\(UUID().uuidString)/x")
        await expectRejected(f, path: outside, mentioning: "outside the dev root")
    }

    @Test @MainActor func rejectsDotDotEscape() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(atPath: f.root) }
        let escape = "\(f.root)/Corveil/../../crow-1396-escape-\(UUID().uuidString)"
        await expectRejected(f, path: escape, mentioning: "outside the dev root")
    }
}
