import Foundation
import Testing
@testable import CrowCore

@MainActor
@Test func sessionIDForWorktreePathReturnsMatchingSession() {
    let appState = AppState()
    let sessionA = UUID()
    let sessionB = UUID()
    appState.worktrees[sessionA] = [
        SessionWorktree(
            sessionID: sessionA, repoName: "alpha",
            repoPath: "/repos/alpha", worktreePath: "/wt/alpha",
            branch: "main"
        ),
    ]
    appState.worktrees[sessionB] = [
        SessionWorktree(
            sessionID: sessionB, repoName: "beta",
            repoPath: "/repos/beta", worktreePath: "/wt/beta",
            branch: "main"
        ),
    ]

    #expect(appState.sessionID(forWorktreePath: "/wt/alpha") == sessionA)
    #expect(appState.sessionID(forWorktreePath: "/wt/beta") == sessionB)
}

@MainActor
@Test func sessionIDForUnknownWorktreePathReturnsNil() {
    let appState = AppState()
    appState.worktrees[UUID()] = [
        SessionWorktree(
            sessionID: UUID(), repoName: "foo",
            repoPath: "/r", worktreePath: "/wt/foo",
            branch: "main"
        ),
    ]
    #expect(appState.sessionID(forWorktreePath: "/wt/does-not-exist") == nil)
}
