import Foundation
import Testing
@testable import CrowGit
import CrowCore

@Suite("WorktreeInference")
struct WorktreeInferenceTests {

    @Test("infers repo, main clone, path, and branch from a linked worktree")
    func infersFromLinkedWorktree() throws {
        let fixture = try makeRepoWithWorktree(
            repoFolder: "my-folder",
            origin: "git@github.com:corveil/shell-crm.git",
            branch: "feature/shell-crm-473-open-geo-enrichment"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try #require(WorktreeInference.infer(
            cwd: fixture.worktree.path, devRoot: fixture.root.path))

        #expect(result.repoName == "shell-crm")
        #expect(std(result.repoPath) == std(fixture.mainClone.path))
        #expect(std(result.worktreePath) == std(fixture.worktree.path))
        #expect(result.branch == "feature/shell-crm-473-open-geo-enrichment")
    }

    @Test("falls back to the clone folder name when origin is missing")
    func fallsBackToFolderNameWithoutOrigin() throws {
        let fixture = try makeRepoWithWorktree(
            repoFolder: "shell-crm", origin: nil, branch: "feature/x")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try #require(WorktreeInference.infer(
            cwd: fixture.worktree.path, devRoot: fixture.root.path))
        #expect(result.repoName == "shell-crm")
        #expect(result.branch == "feature/x")
    }

    @Test("a main clone uses itself as repoPath")
    func mainCloneUsesItself() throws {
        let fixture = try makeRepoWithWorktree(
            repoFolder: "crow", origin: "https://github.com/corveil/crow.git", branch: "feature/x")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try #require(WorktreeInference.infer(
            cwd: fixture.mainClone.path, devRoot: fixture.root.path))
        #expect(result.repoName == "crow")
        #expect(std(result.repoPath) == std(fixture.mainClone.path))
        #expect(std(result.worktreePath) == std(fixture.mainClone.path))
        #expect(result.branch == "main")
    }

    @Test("cwd outside devRoot is rejected")
    func rejectsPathOutsideDevRoot() throws {
        let fixture = try makeRepoWithWorktree(
            repoFolder: "crow", origin: nil, branch: "feature/x")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-infer-outside-\(UUID().uuidString)")
        #expect(WorktreeInference.infer(cwd: fixture.worktree.path, devRoot: elsewhere.path) == nil)
    }

    @Test("a plain directory is not a worktree")
    func rejectsPlainDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-infer-plain-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("ws/not-a-repo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(WorktreeInference.infer(cwd: dir.path, devRoot: root.path) == nil)
    }

    @Test("cwd equal to devRoot is rejected even if it is a git repo")
    func rejectsDevRootItself() throws {
        let fixture = try makeRepoWithWorktree(
            repoFolder: "crow", origin: nil, branch: "feature/x")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(WorktreeInference.infer(
            cwd: fixture.mainClone.path, devRoot: fixture.mainClone.path) == nil)
    }

    @Test("resolveMainClone agrees with git on a linked worktree")
    func resolveMainCloneAgreesWithGit() throws {
        let fixture = try makeRepoWithWorktree(
            repoFolder: "crow", origin: nil, branch: "feature/x")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(WorktreeInference.resolveMainClone(worktreePath: fixture.worktree.path)
                == std(fixture.mainClone.path))
        #expect(WorktreeInference.resolveMainClone(worktreePath: fixture.mainClone.path) == nil)
    }

    @Test("https origin URLs yield the repo segment")
    func parsesHTTPSOrigin() throws {
        let fixture = try makeRepoWithWorktree(
            repoFolder: "ignored",
            origin: "https://github.com/corveil/crow.git",
            branch: "feature/x"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try #require(WorktreeInference.infer(
            cwd: fixture.worktree.path, devRoot: fixture.root.path))
        #expect(result.repoName == "crow")
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let mainClone: URL
        let worktree: URL
    }

    private func makeRepoWithWorktree(
        repoFolder: String,
        origin: String?,
        branch: String
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("crow-infer-\(UUID().uuidString)")
        let mainClone = root.appendingPathComponent("ws").appendingPathComponent(repoFolder)
        try FileManager.default.createDirectory(at: mainClone, withIntermediateDirectories: true)
        _ = try git(["init", "--initial-branch=main", mainClone.path])
        _ = try git(["-C", mainClone.path, "config", "user.email", "t@example.com"])
        _ = try git(["-C", mainClone.path, "config", "user.name", "T"])
        _ = try git(["-C", mainClone.path, "config", "commit.gpgsign", "false"])
        try Data("x".utf8).write(to: mainClone.appendingPathComponent("README"))
        _ = try git(["-C", mainClone.path, "add", "README"])
        _ = try git(["-C", mainClone.path, "commit", "-m", "init"])
        if let origin {
            _ = try git(["-C", mainClone.path, "remote", "add", "origin", origin])
        }

        let worktree = root.appendingPathComponent("ws").appendingPathComponent("\(repoFolder)-1-slug")
        _ = try git(["-C", mainClone.path, "worktree", "add", worktree.path, "-b", branch])
        return Fixture(root: root, mainClone: mainClone, worktree: worktree)
    }

    private func git(_ args: [String]) throws -> String {
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
