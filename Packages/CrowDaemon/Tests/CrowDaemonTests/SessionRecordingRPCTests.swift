import Foundation
import Testing
import CrowCore
import CrowGit
import CrowIPC
import CrowPersistence
@testable import CrowDaemon

/// CROW-1423: `list-sessions` carries the `recording` object only while debug
/// mode is on, and never a credential (it is readable by remote `/rpc` peers).
@Suite struct SessionRecordingRPCTests {
    @MainActor
    private func router(_ appState: AppState, devRoot: String) -> CommandRouter {
        makeCommandRouter(
            appState: appState, store: JSONStore.temporary(), git: GitManager(),
            devRoot: devRoot, cockpit: nil)
    }

    private func tempDevRoot() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-rec-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func config(debug: Bool) -> AppConfig {
        var config = AppConfig(workspaces: [WorkspaceInfo(
            name: "corveil", uploadSessionLogs: true,
            gateway: WorkspaceGateway(
                baseURL: "https://corveil.test",
                customHeaders: ["x-citadel-api-key": "Bearer sk-citadel-ROW-SECRET"]))])
        config.debugMode.enabled = debug
        config.managerGateway = WorkspaceGateway(
            baseURL: "https://corveil.test", customHeaders: ["Authorization": "Bearer sk-citadel-MGR-SECRET"])
        return config
    }

    @MainActor
    private func listSessions(debug: Bool) async throws -> (rows: [[String: JSONValue]], raw: String) {
        let devRoot = tempDevRoot()
        defer { try? FileManager.default.removeItem(atPath: devRoot) }
        try ConfigStore.saveConfig(config(debug: debug), devRoot: devRoot)
        let appState = AppState()
        let work = Session(name: "work", kind: .work)
        appState.sessions = [Session(name: "mgr", kind: .manager), work]
        appState.worktrees[work.id] = [SessionWorktree(
            sessionID: work.id, repoName: "crow", repoPath: "\(devRoot)/corveil/crow",
            worktreePath: "\(devRoot)/corveil/crow-1-x", branch: "b", isPrimary: true)]
        let resp = await router(appState, devRoot: devRoot)
            .handle(request: JSONRPCRequest(id: 1, method: "list-sessions"))
        #expect(resp.error == nil)
        let raw = String(decoding: try JSONEncoder().encode(resp.result ?? [:]), as: UTF8.self)
        return ((resp.result?["sessions"]?.arrayValue ?? []).compactMap(\.objectValue), raw)
    }

    @Test @MainActor func noRecordingFieldWhileDebugModeIsOff() async throws {
        let (rows, _) = try await listSessions(debug: false)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0["recording"] == nil })
    }

    @Test @MainActor func everyRowCarriesBothIndicatorsWhenOn() async throws {
        let (rows, raw) = try await listSessions(debug: true)
        #expect(rows.count == 2)
        for row in rows {
            let rec = row["recording"]?.objectValue
            #expect(rec?["gateway"]?.objectValue?["state"]?.stringValue != nil)
            #expect(rec?["transcripts"]?.objectValue?["state"]?.stringValue != nil)
        }
        for secret in ["sk-citadel", "x-citadel-api-key", "Authorization", "authorization", "Bearer"] {
            #expect(!raw.contains(secret), "list-sessions leaks \(secret)")
        }
    }
}
