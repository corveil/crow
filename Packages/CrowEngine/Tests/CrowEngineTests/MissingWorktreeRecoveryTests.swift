import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowGit
@testable import CrowEngine

/// CROW-1219: a work session with a managed terminal whose cwd is a git
/// worktree, but no `SessionWorktree` row, should grow a primary row so PR
/// linking and `primaryWorktree(for:)` can match.
@Suite("Missing worktree recovery")
@MainActor
struct MissingWorktreeRecoveryTests {

    @Test("registers a primary worktree from the managed terminal cwd")
    func registersFromManagedCwd() async throws {
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (appState, store, session) = seed(
            kind: .work,
            terminals: [managed(cwd: fixture.worktree.path)]
        )
        let added = await MissingWorktreeRecovery.recoverAll(
            appState: appState, store: store, devRoot: fixture.root.path)

        #expect(added.count == 1)
        let wt = try #require(appState.primaryWorktree(for: session.id))
        #expect(wt.isPrimary)
        #expect(wt.repoName == "shell-crm")
        #expect(std(wt.repoPath) == std(fixture.mainClone.path))
        #expect(std(wt.worktreePath) == std(fixture.worktree.path))
        #expect(wt.branch == "feature/x")
        #expect(store.data.worktrees.contains { $0.id == wt.id })
    }

    @Test("does not invent a second worktree when one already exists")
    func skipsWhenWorktreeExists() async throws {
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let existing = SessionWorktree(
            sessionID: UUID(), repoName: "already", repoPath: fixture.mainClone.path,
            worktreePath: fixture.worktree.path, branch: "feature/existing", isPrimary: true
        )
        let (appState, store, session) = seed(
            kind: .work,
            worktrees: [existing],
            terminals: [managed(cwd: fixture.worktree.path)]
        )

        let added = await MissingWorktreeRecovery.recoverAll(
            appState: appState, store: store, devRoot: fixture.root.path)
        #expect(added.isEmpty)
        #expect(appState.worktrees(for: session.id).count == 1)
        #expect(appState.worktrees(for: session.id)[0].branch == "feature/existing")
    }

    @Test("skips job, review, and manager sessions")
    func skipsNonWorkKinds() async throws {
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        for kind: SessionKind in [.job, .review, .manager] {
            let (appState, store, session) = seed(
                kind: kind,
                terminals: [managed(cwd: fixture.worktree.path)]
            )
            let added = await MissingWorktreeRecovery.recoverAll(
                appState: appState, store: store, devRoot: fixture.root.path)
            #expect(added.isEmpty, "kind \(kind.rawValue) should stay worktree-less")
            #expect(appState.worktrees(for: session.id).isEmpty)
        }
    }

    @Test("ignores an unmanaged terminal")
    func skipsUnmanagedTerminal() async throws {
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (appState, store, session) = seed(
            kind: .work,
            terminals: [
                SessionTerminal(
                    sessionID: UUID(), name: "Shell", cwd: fixture.worktree.path, isManaged: false
                )
            ]
        )

        let added = await MissingWorktreeRecovery.recoverAll(
            appState: appState, store: store, devRoot: fixture.root.path)
        #expect(added.isEmpty)
        #expect(appState.worktrees(for: session.id).isEmpty)
    }

    @Test("recoverIfNeeded is a no-op when the session already has a worktree")
    func recoverIfNeededIsIdempotent() async throws {
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (appState, store, session) = seed(
            kind: .work,
            terminals: [managed(cwd: fixture.worktree.path)]
        )
        let first = await MissingWorktreeRecovery.recoverIfNeeded(
            sessionID: session.id, appState: appState, store: store, devRoot: fixture.root.path)
        #expect(first != nil)
        let second = await MissingWorktreeRecovery.recoverIfNeeded(
            sessionID: session.id, appState: appState, store: store, devRoot: fixture.root.path)
        #expect(second == nil)
        #expect(appState.worktrees(for: session.id).count == 1)
    }

    @Test("an explore work session is still recovered")
    func recoversExploreWorkSession() async throws {
        // Explore is a tag on `.work`, not a separate kind. A missing row is
        // the same bootstrap gap; inferring a checkout that already exists is
        // not inventing a second tree.
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let appState = AppState()
        let store = JSONStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1219-explore-\(UUID().uuidString)"))
        let session = Session(name: "explore", kind: .work, isExplore: true)
        appState.sessions = [session]
        appState.terminals[session.id] = [
            SessionTerminal(
                sessionID: session.id, name: "Claude Code",
                cwd: fixture.worktree.path, isManaged: true)
        ]

        let added = await MissingWorktreeRecovery.recoverAll(
            appState: appState, store: store, devRoot: fixture.root.path)
        #expect(added.count == 1)
        #expect(appState.primaryWorktree(for: session.id)?.isPrimary == true)
    }

    @Test("overlapping recoverAll calls append exactly one worktree")
    func overlappingRecoverAllDoesNotDoubleAppend() async throws {
        // Both calls snapshot the session as eligible before either persists
        // (each suspends for off-actor inference); the MainActor re-check is
        // what keeps the second from appending a duplicate (CROW-1346).
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (appState, store, session) = seed(
            kind: .work,
            terminals: [managed(cwd: fixture.worktree.path)]
        )
        async let first = MissingWorktreeRecovery.recoverAll(
            appState: appState, store: store, devRoot: fixture.root.path)
        async let second = MissingWorktreeRecovery.recoverAll(
            appState: appState, store: store, devRoot: fixture.root.path)
        async let single = MissingWorktreeRecovery.recoverIfNeeded(
            sessionID: session.id, appState: appState, store: store, devRoot: fixture.root.path)
        let total = await first.count + second.count + (single == nil ? 0 : 1)

        #expect(total == 1)
        #expect(appState.worktrees(for: session.id).count == 1)
        #expect(store.data.worktrees.filter { $0.sessionID == session.id }.count == 1)
    }

    @Test("a worktree registered during inference wins over the inferred one")
    func registrationDuringInferenceIsRespected() async throws {
        let fixture = try await makeRepoWithWorktree()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let (appState, store, session) = seed(
            kind: .work,
            terminals: [managed(cwd: fixture.worktree.path)]
        )
        async let added = MissingWorktreeRecovery.recoverAll(
            appState: appState, store: store, devRoot: fixture.root.path)
        // Typically lands while recoverAll is suspended on the off-actor `git`
        // calls — the window an `add-worktree` RPC would hit. Whichever side of
        // the snapshot it falls on, the manual row must be the only one.
        await Task.yield()
        appState.worktrees[session.id] = [
            SessionWorktree(
                sessionID: session.id, repoName: "manual", repoPath: fixture.mainClone.path,
                worktreePath: fixture.worktree.path, branch: "feature/manual", isPrimary: true)
        ]

        #expect(await added.isEmpty)
        #expect(appState.worktrees(for: session.id).map(\.branch) == ["feature/manual"])
    }

    // MARK: - Helpers

    private func seed(
        kind: SessionKind,
        worktrees: [SessionWorktree] = [],
        terminals: [SessionTerminal]
    ) -> (AppState, JSONStore, Session) {
        let appState = AppState()
        let store = JSONStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-1219-\(UUID().uuidString)"))
        let session = Session(name: "s", kind: kind)
        appState.sessions = [session]
        if !worktrees.isEmpty {
            appState.worktrees[session.id] = worktrees.map {
                SessionWorktree(
                    sessionID: session.id, repoName: $0.repoName, repoPath: $0.repoPath,
                    worktreePath: $0.worktreePath, branch: $0.branch, isPrimary: $0.isPrimary)
            }
        }
        appState.terminals[session.id] = terminals.map {
            SessionTerminal(
                sessionID: session.id, name: $0.name, cwd: $0.cwd, isManaged: $0.isManaged)
        }
        return (appState, store, session)
    }

    private func managed(cwd: String) -> SessionTerminal {
        SessionTerminal(sessionID: UUID(), name: "Claude Code", cwd: cwd, isManaged: true)
    }

    private struct Fixture: Sendable {
        let root: URL
        let mainClone: URL
        let worktree: URL
    }

    /// Builds the fixture on a detached task: this suite is `@MainActor`, and
    /// running `git` here would stall every other test's MainActor hop — the
    /// exact failure CROW-1346 fixed in production code.
    private func makeRepoWithWorktree() async throws -> Fixture {
        try await Task.detached { try Self.buildRepoWithWorktree() }.value
    }

    private nonisolated static func buildRepoWithWorktree() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-1219-\(UUID().uuidString)")
        let mainClone = root.appendingPathComponent("corveil/shell-crm")
        try FileManager.default.createDirectory(at: mainClone, withIntermediateDirectories: true)
        _ = try git(["init", "--initial-branch=main", mainClone.path])
        _ = try git(["-C", mainClone.path, "config", "user.email", "t@example.com"])
        _ = try git(["-C", mainClone.path, "config", "user.name", "T"])
        _ = try git(["-C", mainClone.path, "config", "commit.gpgsign", "false"])
        try Data("x".utf8).write(to: mainClone.appendingPathComponent("README"))
        _ = try git(["-C", mainClone.path, "add", "README"])
        _ = try git(["-C", mainClone.path, "commit", "-m", "init"])
        _ = try git(["-C", mainClone.path, "remote", "add", "origin",
                      "git@github.com:corveil/shell-crm.git"])

        let worktree = root.appendingPathComponent("corveil/shell-crm-473-open-geo-enrichment")
        _ = try git(["-C", mainClone.path, "worktree", "add", worktree.path, "-b", "feature/x"])
        return Fixture(root: root, mainClone: mainClone, worktree: worktree)
    }

    private nonisolated static func git(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: out, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "git", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text]
            )
        }
        return text
    }

    private func std(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
