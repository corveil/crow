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

/// #915 — once cwd decides hook-event routing, "the first match" is no longer
/// good enough: `worktrees` is a dictionary, so a path registered by two
/// sessions would resolve nondeterministically, and a losing coin flip means a
/// session records nothing for the life of the daemon.
@MainActor
@Test func sessionIDsForWorktreePathReturnsEveryOwnerDeterministically() {
    let appState = AppState()
    let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    for id in [second, first] {  // inserted out of order on purpose
        appState.worktrees[id] = [
            SessionWorktree(
                sessionID: id, repoName: "shared",
                repoPath: "/repos/shared", worktreePath: "/wt/shared",
                branch: "main"
            ),
        ]
    }

    #expect(appState.sessionIDs(forWorktreePath: "/wt/shared") == [first, second])
    #expect(appState.sessionIDs(forWorktreePath: "/wt/absent").isEmpty)
}

/// An agent's reported cwd and the stored row can disagree on spelling. A miss
/// makes the #915 routing silently inert, so both sides are normalized —
/// matching what `LaunchScaffold.repairStaleHooks` already does to the same data.
@MainActor
@Test func sessionIDForWorktreePathNormalizesBothSides() {
    let appState = AppState()
    let session = UUID()
    appState.worktrees[session] = [
        SessionWorktree(
            sessionID: session, repoName: "alpha",
            repoPath: "/repos/alpha", worktreePath: "/wt/alpha/",
            branch: "main"
        ),
    ]

    #expect(appState.sessionID(forWorktreePath: "/wt/alpha") == session)
    #expect(appState.sessionID(forWorktreePath: "/wt/./alpha") == session)
    // Exact-match, not prefix: a sibling worktree whose name extends the main
    // clone's must never resolve to it.
    #expect(appState.sessionID(forWorktreePath: "/wt/alpha-1-slug") == nil)
}
