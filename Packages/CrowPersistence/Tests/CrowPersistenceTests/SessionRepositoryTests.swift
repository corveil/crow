import Foundation
import Testing
@testable import CrowPersistence
@testable import CrowCore

@Test func saveAndFind() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    let session = Session(name: "find-test", status: .active, ticketURL: "https://example.com/1")
    repo.save(session)

    let found = repo.find(id: session.id)
    #expect(found != nil)
    #expect(found?.name == "find-test")
    #expect(found?.ticketURL == "https://example.com/1")
}

@Test func saveUpdatesExisting() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    var session = Session(name: "original")
    repo.save(session)
    #expect(repo.all().count == 1)

    session.name = "updated"
    repo.save(session)
    #expect(repo.all().count == 1)
    #expect(repo.find(id: session.id)?.name == "updated")
}

@Test func deleteCascadesAllRelatedData() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    let sessionID = UUID()
    let session = Session(id: sessionID, name: "cascade-test")
    repo.save(session)

    // Add related data directly via store
    store.mutate { data in
        data.worktrees.append(SessionWorktree(
            sessionID: sessionID, repoName: "crow", repoPath: "/repo",
            worktreePath: "/wt", branch: "feature/x"
        ))
        data.links.append(SessionLink(
            sessionID: sessionID, label: "PR", url: "https://example.com", linkType: .pr
        ))
        data.terminals.append(SessionTerminal(
            sessionID: sessionID, name: "Shell", cwd: "/wt"
        ))
    }

    // Verify data exists
    #expect(repo.worktrees(for: sessionID).count == 1)
    #expect(repo.links(for: sessionID).count == 1)
    #expect(store.data.terminals.filter { $0.sessionID == sessionID }.count == 1)

    // Delete should cascade to all related data
    repo.delete(id: sessionID)

    #expect(repo.find(id: sessionID) == nil)
    #expect(repo.worktrees(for: sessionID).isEmpty)
    #expect(repo.links(for: sessionID).isEmpty)
    #expect(store.data.terminals.filter { $0.sessionID == sessionID }.isEmpty)
}

@Test func allReturnsSessions() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    repo.save(Session(name: "session-1"))
    repo.save(Session(name: "session-2"))
    repo.save(Session(name: "session-3"))

    let all = repo.all()
    #expect(all.count == 3)
    #expect(Set(all.map(\.name)) == Set(["session-1", "session-2", "session-3"]))
}

@Test func worktreesAndLinksFilterBySession() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    let session1 = UUID()
    let session2 = UUID()

    store.mutate { data in
        data.worktrees.append(SessionWorktree(
            sessionID: session1, repoName: "a", repoPath: "/a",
            worktreePath: "/wt-a", branch: "feature/a"
        ))
        data.worktrees.append(SessionWorktree(
            sessionID: session2, repoName: "b", repoPath: "/b",
            worktreePath: "/wt-b", branch: "feature/b"
        ))
        data.links.append(SessionLink(
            sessionID: session1, label: "Issue", url: "https://example.com/1", linkType: .ticket
        ))
        data.links.append(SessionLink(
            sessionID: session1, label: "PR", url: "https://example.com/2", linkType: .pr
        ))
        data.links.append(SessionLink(
            sessionID: session2, label: "Repo", url: "https://example.com/3", linkType: .repo
        ))
    }

    #expect(repo.worktrees(for: session1).count == 1)
    #expect(repo.worktrees(for: session2).count == 1)
    #expect(repo.links(for: session1).count == 2)
    #expect(repo.links(for: session2).count == 1)
}

// MARK: - Extended Tests

@Test func deleteNonExistentSessionIsNoOp() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    repo.save(Session(name: "existing"))
    #expect(repo.all().count == 1)

    // Deleting a random UUID should not affect existing sessions
    repo.delete(id: UUID())
    #expect(repo.all().count == 1)
}

@Test func savePreservesAllOptionalFields() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    let session = Session(
        name: "full", status: .inReview,
        ticketURL: "https://github.com/org/repo/issues/42",
        ticketTitle: "Fix the bug",
        ticketNumber: 42,
        provider: .github,
        codeProvider: .gitlab
    )
    repo.save(session)

    let found = repo.find(id: session.id)
    #expect(found?.ticketURL == "https://github.com/org/repo/issues/42")
    #expect(found?.ticketTitle == "Fix the bug")
    #expect(found?.ticketNumber == 42)
    #expect(found?.provider == .github)
    #expect(found?.codeProvider == .gitlab)
    #expect(found?.status == .inReview)
}

@Test func statusUpdateRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    var session = Session(name: "lifecycle")
    repo.save(session)
    #expect(repo.find(id: session.id)?.status == .active)

    session.status = .inReview
    repo.save(session)
    #expect(repo.find(id: session.id)?.status == .inReview)

    session.status = .completed
    repo.save(session)
    #expect(repo.find(id: session.id)?.status == .completed)
}

@Test func multipleWorktreesForSameSession() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    let sessionID = UUID()
    store.mutate { data in
        data.worktrees.append(SessionWorktree(
            sessionID: sessionID, repoName: "crow", repoPath: "/repo",
            worktreePath: "/wt-1", branch: "feature/a"
        ))
        data.worktrees.append(SessionWorktree(
            sessionID: sessionID, repoName: "crow", repoPath: "/repo",
            worktreePath: "/wt-2", branch: "feature/b", isPrimary: true
        ))
    }

    let wts = repo.worktrees(for: sessionID)
    #expect(wts.count == 2)
    #expect(wts.filter(\.isPrimary).count == 1)
}

@Test func deleteCascadesMultipleRelatedData() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    let sessionID = UUID()
    let otherSessionID = UUID()
    let session = Session(id: sessionID, name: "cascade-multi")
    repo.save(session)
    repo.save(Session(id: otherSessionID, name: "other"))

    store.mutate { data in
        // Multiple worktrees, links, terminals for the target session
        data.worktrees.append(SessionWorktree(sessionID: sessionID, repoName: "a", repoPath: "/a", worktreePath: "/wt-a", branch: "f/a"))
        data.worktrees.append(SessionWorktree(sessionID: sessionID, repoName: "b", repoPath: "/b", worktreePath: "/wt-b", branch: "f/b"))
        data.links.append(SessionLink(sessionID: sessionID, label: "Issue", url: "https://example.com/1", linkType: .ticket))
        data.links.append(SessionLink(sessionID: sessionID, label: "PR", url: "https://example.com/2", linkType: .pr))
        data.terminals.append(SessionTerminal(sessionID: sessionID, name: "Claude Code", cwd: "/wt-a", isManaged: true))
        data.terminals.append(SessionTerminal(sessionID: sessionID, name: "Shell", cwd: "/wt-a"))

        // Data for other session (should survive)
        data.worktrees.append(SessionWorktree(sessionID: otherSessionID, repoName: "c", repoPath: "/c", worktreePath: "/wt-c", branch: "f/c"))
        data.links.append(SessionLink(sessionID: otherSessionID, label: "Repo", url: "https://example.com/3", linkType: .repo))
    }

    repo.delete(id: sessionID)

    #expect(repo.find(id: sessionID) == nil)
    #expect(repo.worktrees(for: sessionID).isEmpty)
    #expect(repo.links(for: sessionID).isEmpty)
    #expect(store.data.terminals.filter { $0.sessionID == sessionID }.isEmpty)

    // Other session's data is preserved
    #expect(repo.find(id: otherSessionID) != nil)
    #expect(repo.worktrees(for: otherSessionID).count == 1)
    #expect(repo.links(for: otherSessionID).count == 1)
}

@Test func deleteIdempotent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let repo = SessionRepository(store: store)

    let session = Session(name: "will-delete")
    repo.save(session)

    repo.delete(id: session.id)
    #expect(repo.find(id: session.id) == nil)

    // Second delete should be a no-op, not crash
    repo.delete(id: session.id)
    #expect(repo.find(id: session.id) == nil)
}
