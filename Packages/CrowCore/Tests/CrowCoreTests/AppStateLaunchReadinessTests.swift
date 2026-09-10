import Foundation
import Testing
@testable import CrowCore

/// CROW-1218 — a `.work` session is not launch-ready without a registered
/// worktree whose branch is non-empty. Manager / review / job skip the gate.
@MainActor
@Suite struct AppStateLaunchReadinessTests {
    private func workSession(ticketed: Bool = true) -> Session {
        Session(
            name: "crow-1218",
            kind: .work,
            ticketURL: ticketed ? "https://github.com/corveil/crow/issues/1218" : nil,
            ticketNumber: ticketed ? 1218 : nil
        )
    }

    @Test func workSessionWithoutWorktreeIsNotReady() {
        let appState = AppState()
        let session = workSession()
        appState.sessions.append(session)
        #expect(!appState.isReadyToLaunchAgent(session))
    }

    @Test func workSessionWithEmptyBranchIsNotReady() {
        let appState = AppState()
        let session = workSession()
        appState.sessions.append(session)
        appState.worktrees[session.id] = [
            SessionWorktree(
                sessionID: session.id, repoName: "crow",
                repoPath: "/repo", worktreePath: "/wt",
                branch: "   ", isPrimary: true
            ),
        ]
        #expect(!appState.isReadyToLaunchAgent(session))
    }

    @Test func workSessionWithPrimaryBranchIsReady() {
        let appState = AppState()
        let session = workSession()
        appState.sessions.append(session)
        appState.worktrees[session.id] = [
            SessionWorktree(
                sessionID: session.id, repoName: "crow",
                repoPath: "/repo", worktreePath: "/wt",
                branch: "feature/crow-1218", isPrimary: true
            ),
        ]
        #expect(appState.isReadyToLaunchAgent(session))
    }

    @Test func workSessionFallsBackToFirstWorktreeWhenNonePrimary() {
        let appState = AppState()
        let session = workSession(ticketed: false)
        appState.sessions.append(session)
        appState.worktrees[session.id] = [
            SessionWorktree(
                sessionID: session.id, repoName: "crow",
                repoPath: "/repo", worktreePath: "/wt",
                branch: "feature/crow-1218", isPrimary: false
            ),
        ]
        #expect(appState.isReadyToLaunchAgent(session))
    }

    @Test func managerIsReadyWithoutWorktree() {
        let appState = AppState()
        let session = Session(name: "Manager", kind: .manager)
        appState.sessions.append(session)
        #expect(appState.isReadyToLaunchAgent(session))
    }

    @Test func reviewIsReadyWithoutThisGate() {
        // Review registers a primary at create; the gate must not block a
        // review that somehow has no row (create-path coverage lives elsewhere).
        let appState = AppState()
        let session = Session(name: "review", kind: .review)
        appState.sessions.append(session)
        #expect(appState.isReadyToLaunchAgent(session))
    }
}
