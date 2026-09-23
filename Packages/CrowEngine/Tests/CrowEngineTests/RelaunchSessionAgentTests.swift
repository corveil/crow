import Foundation
import Testing
import CrowCore
import CrowPersistence
@testable import CrowEngine

/// CROW-1295: relaunch refuses the cases that must not open a tmux window.
/// The happy path registers a real window, so these stop at the guards.
@Suite("relaunch-agent guards")
@MainActor
struct RelaunchSessionAgentTests {
    private func harness(devRoot: String = "/dev-root") -> (SessionService, AppState) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-relaunch-\(UUID().uuidString)")
        let appState = AppState()
        let service = SessionService(store: JSONStore(directory: dir), appState: appState, hostBridge: NoopHostBridge())
        return (service, appState)
    }

    private func workSession(in appState: AppState, branch: String = "feature/x", worktreePath: String = "/dev-root/repo") -> Session {
        let session = Session(name: "work", kind: .work, agentKind: .grok)
        appState.sessions.append(session)
        appState.worktrees[session.id] = [
            SessionWorktree(
                sessionID: session.id, repoName: "repo", repoPath: "/dev-root/repo.git",
                worktreePath: worktreePath, branch: branch, isPrimary: true),
        ]
        return session
    }

    @Test func missingSessionIsRejected() {
        let (service, _) = harness()
        #expect(throws: RPCError.self) {
            try service.relaunchSessionAgent(sessionID: UUID(), devRoot: "/dev-root")
        }
    }

    @Test func managerIsRejected() {
        let (service, appState) = harness()
        let manager = Session(name: "Manager", kind: .manager)
        appState.sessions.append(manager)
        #expect(throws: RPCError.self) {
            try service.relaunchSessionAgent(sessionID: manager.id, devRoot: "/dev-root")
        }
        #expect(appState.terminals[manager.id] == nil)
    }

    @Test func existingManagedTerminalIsRejected() {
        let (service, appState) = harness()
        let session = workSession(in: appState)
        let existing = SessionTerminal(sessionID: session.id, name: "Grok", cwd: "/dev-root/repo", isManaged: true)
        appState.terminals[session.id] = [existing]
        #expect(throws: RPCError.self) {
            try service.relaunchSessionAgent(sessionID: session.id, devRoot: "/dev-root")
        }
        #expect(appState.terminals[session.id]?.count == 1)
        #expect(appState.autoLaunchTerminals.isEmpty)
    }

    @Test func workSessionWithoutAWorktreeIsRejected() {
        let (service, appState) = harness()
        let session = Session(name: "bare", kind: .work)
        appState.sessions.append(session)
        #expect(throws: RPCError.self) {
            try service.relaunchSessionAgent(sessionID: session.id, devRoot: "/dev-root")
        }
        #expect(appState.terminals[session.id] == nil)
    }

    @Test func worktreeOutsideDevRootIsRejectedBeforeRegister() {
        let (service, appState) = harness()
        let session = workSession(in: appState, worktreePath: "/elsewhere/repo")
        #expect(throws: RPCError.self) {
            try service.relaunchSessionAgent(sessionID: session.id, devRoot: "/dev-root")
        }
        #expect(appState.terminals[session.id] == nil)
        #expect(appState.autoLaunchTerminals.isEmpty)
        #expect(appState.terminalReadiness.isEmpty)
    }
}
