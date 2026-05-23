import Foundation
import Testing
@testable import CrowPersistence
@testable import CrowCore

@Test func emptyStoreCreation() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let data = store.data
    #expect(data.sessions.isEmpty)
    #expect(data.worktrees.isEmpty)
    #expect(data.links.isEmpty)
    #expect(data.terminals.isEmpty)
}

@Test func mutatePersistsToFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let session = Session(name: "persist-test")
    store.mutate { data in
        data.sessions.append(session)
    }

    // Create a new store from the same directory — data should survive
    let reloaded = JSONStore(directory: dir)
    #expect(reloaded.data.sessions.count == 1)
    #expect(reloaded.data.sessions.first?.name == "persist-test")
    #expect(reloaded.data.sessions.first?.id == session.id)
}

@Test func concurrentMutatesAreConsistent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let iterations = 50

    // Dispatch concurrent mutates that each append a session
    let group = DispatchGroup()
    for i in 0..<iterations {
        group.enter()
        DispatchQueue.global().async {
            store.mutate { data in
                data.sessions.append(Session(name: "session-\(i)"))
            }
            group.leave()
        }
    }
    group.wait()

    #expect(store.data.sessions.count == iterations)

    // Verify file on disk is also consistent
    let reloaded = JSONStore(directory: dir)
    #expect(reloaded.data.sessions.count == iterations)
}

// Guards the lock-scope + write-coalescing change (#304): the in-memory data
// lock is released before the disk write, but writes must still land in
// mutation order and the newest snapshot must win. A stale snapshot winning
// would leave the on-disk state internally inconsistent across fields.
@Test func concurrentMutatesAcrossFieldsAreConsistent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    let iterations = 100

    let group = DispatchGroup()
    for i in 0..<iterations {
        group.enter()
        DispatchQueue.global().async {
            // Each mutate appends to two different arrays. The newest snapshot
            // always reflects every prior mutation, so the final on-disk state
            // must carry equal counts for both — never a torn write where one
            // array advanced but the other did not.
            store.mutate { data in
                data.sessions.append(Session(name: "s-\(i)"))
                data.links.append(SessionLink(
                    sessionID: UUID(), label: "l-\(i)",
                    url: "https://example.com/\(i)", linkType: .pr
                ))
            }
            group.leave()
        }
    }
    group.wait()

    #expect(store.data.sessions.count == iterations)
    #expect(store.data.links.count == iterations)

    let reloaded = JSONStore(directory: dir)
    #expect(reloaded.data.sessions.count == iterations)
    #expect(reloaded.data.links.count == iterations)
}

// The final mutation in a rapid burst must always be the one persisted —
// write coalescing may drop intermediate snapshots but never the latest (#304).
@Test func lastMutationInBurstIsPersisted() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    for i in 0..<200 {
        store.mutate { data in
            data.sessions.append(Session(name: "burst-\(i)"))
        }
    }

    let reloaded = JSONStore(directory: dir)
    #expect(reloaded.data.sessions.count == 200)
    #expect(reloaded.data.sessions.last?.name == "burst-199")
}

@Test func corruptFileCreatesBackup() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let storeFile = dir.appendingPathComponent("store.json")
    try "not valid json{{{".write(to: storeFile, atomically: true, encoding: .utf8)

    // Init should detect corruption, create backup, and start fresh
    let store = JSONStore(directory: dir)
    #expect(store.data.sessions.isEmpty)

    // Backup file should exist
    let backupFile = dir.appendingPathComponent("store.json.bak")
    #expect(FileManager.default.fileExists(atPath: backupFile.path))

    // Backup should contain the original corrupt content
    let backupContent = try String(contentsOf: backupFile, encoding: .utf8)
    #expect(backupContent == "not valid json{{{")
}

@Test func filePermissionsAreOwnerOnly() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONStore(directory: dir)
    store.mutate { data in
        data.sessions.append(Session(name: "perm-test"))
    }

    let storeFile = dir.appendingPathComponent("store.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: storeFile.path)
    let permissions = attributes[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func roundTripAllModelTypes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let sessionID = UUID()
    let session = Session(id: sessionID, name: "round-trip")
    let worktree = SessionWorktree(
        sessionID: sessionID, repoName: "crow", repoPath: "/path/to/crow",
        worktreePath: "/path/to/worktree", branch: "feature/test"
    )
    let link = SessionLink(
        sessionID: sessionID, label: "Issue", url: "https://github.com/org/repo/issues/1",
        linkType: .ticket
    )
    let terminal = SessionTerminal(
        sessionID: sessionID, name: "Claude Code", cwd: "/path/to/worktree",
        command: nil, isManaged: true
    )

    let store = JSONStore(directory: dir)
    store.mutate { data in
        data.sessions.append(session)
        data.worktrees.append(worktree)
        data.links.append(link)
        data.terminals.append(terminal)
    }

    let reloaded = JSONStore(directory: dir)
    #expect(reloaded.data.sessions.count == 1)
    #expect(reloaded.data.worktrees.count == 1)
    #expect(reloaded.data.links.count == 1)
    #expect(reloaded.data.terminals.count == 1)

    let rt = reloaded.data.terminals.first!
    #expect(rt.name == "Claude Code")
    #expect(rt.isManaged == true)
    #expect(rt.sessionID == sessionID)

    let rw = reloaded.data.worktrees.first!
    #expect(rw.branch == "feature/test")

    let rl = reloaded.data.links.first!
    #expect(rl.linkType == .ticket)
    #expect(rl.label == "Issue")
}
