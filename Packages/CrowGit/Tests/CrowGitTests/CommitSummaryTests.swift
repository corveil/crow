import Foundation
import Testing
@testable import CrowGit
import CrowCore

/// Integration tests for `GitManager.summarizeCommits`. Builds a real repo
/// under a temp dev-root (devRoot/<workspace>/<repo>/.git), makes commits with
/// controlled dates and known diffstats, then asserts the digest. Skipped
/// automatically if `git` isn't on PATH.
@Suite("GitManager.summarizeCommits")
struct CommitSummaryTests {

    // MARK: - Harness

    /// Run a git command in `dir`, optionally pinning the commit timestamp via
    /// `date` (sets both author and committer date — `git log --since/--until`
    /// filters on committer date). Returns (exitCode, stdout).
    @discardableResult
    private func git(_ args: [String], in dir: String? = nil, date: String? = nil) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var full = ["git"]
        if let dir { full += ["-C", dir] }
        full += args
        p.arguments = full
        var env = ProcessInfo.processInfo.environment
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        if let date { env["GIT_AUTHOR_DATE"] = date; env["GIT_COMMITTER_DATE"] = date }
        p.environment = env
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = outPipe
        try? p.run()
        p.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func gitAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--version"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func write(_ path: String, _ contents: String) {
        try? contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Build devRoot/ws/repo with:
    ///  - "base" commit dated 2020 (outside any 2026 window)
    ///  - "recent feature" on main dated 2026-05-20, +3 lines / 1 file
    ///  - "branch only commit" on a non-checked-out branch dated 2026-05-21,
    ///    +2 lines / 1 file (exercises `--all`)
    /// Returns the dev-root path.
    private func makeDevRoot() -> String? {
        let devRoot = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("summary-test-\(UUID().uuidString)")
        let wsPath = (devRoot as NSString).appendingPathComponent("ws")
        let repo = (wsPath as NSString).appendingPathComponent("repo")
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)

        guard git(["init", "-b", "main", repo]).code == 0 else { return nil }

        write((repo as NSString).appendingPathComponent("base.txt"), "base\n")
        git(["add", "."], in: repo)
        guard git(["commit", "-m", "base"], in: repo, date: "2020-01-01T00:00:00").code == 0 else { return nil }

        write((repo as NSString).appendingPathComponent("feature.txt"), "a\nb\nc\n")
        git(["add", "."], in: repo)
        guard git(["commit", "-m", "recent feature"], in: repo, date: "2026-05-20T12:00:00").code == 0 else { return nil }

        // Commit only reachable from a branch we don't leave checked out.
        guard git(["switch", "-c", "sidebranch"], in: repo).code == 0 else { return nil }
        write((repo as NSString).appendingPathComponent("branch.txt"), "x\ny\n")
        git(["add", "."], in: repo)
        guard git(["commit", "-m", "branch only commit"], in: repo, date: "2026-05-21T12:00:00").code == 0 else { return nil }
        git(["switch", "main"], in: repo)

        return devRoot
    }

    private func manager(devRoot: String) -> GitManager {
        GitManager(config: WorkspaceConfig(devRoot: devRoot, workspaces: [:], defaults: WorkspaceDefaults()))
    }

    // MARK: - Tests

    @Test func collectsCommitsWithSubjectsAndDiffstat() async throws {
        try #require(gitAvailable())
        let devRoot = try #require(makeDevRoot())
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let summaries = try await manager(devRoot: devRoot)
            .summarizeCommits(since: "2026-05-01", until: "2026-12-31")

        #expect(summaries.count == 1)
        let repo = try #require(summaries.first)
        #expect(repo.repo == "repo")
        #expect(repo.workspace == "ws")

        // 2026 commits only: the 2020 "base" commit is outside the window.
        #expect(repo.commits.count == 2)
        let subjects = Set(repo.commits.map(\.subject))
        #expect(subjects.contains("recent feature"))
        #expect(subjects.contains("branch only commit")) // --all picked up the side branch
        #expect(!subjects.contains("base"))

        // feature.txt (+3) + branch.txt (+2), no deletions, two files.
        #expect(repo.totalInsertions == 5)
        #expect(repo.totalDeletions == 0)
        #expect(repo.totalFilesChanged == 2)
    }

    @Test func excludesReposWithNoCommitsInWindow() async throws {
        try #require(gitAvailable())
        let devRoot = try #require(makeDevRoot())
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        // A window with no commits → the repo is omitted entirely.
        let summaries = try await manager(devRoot: devRoot)
            .summarizeCommits(since: "2019-01-01", until: "2019-12-31")
        #expect(summaries.isEmpty)
    }

    @Test func scopesByOrgRepoSlugAndDerivesCommitURLPrefix() async throws {
        try #require(gitAvailable())
        let devRoot = try #require(makeDevRoot())
        defer { try? FileManager.default.removeItem(atPath: devRoot) }

        let repoPath = ((devRoot as NSString).appendingPathComponent("ws") as NSString)
            .appendingPathComponent("repo")
        git(["remote", "add", "origin", "git@github.com:acme/repo.git"], in: repoPath)

        let gm = manager(devRoot: devRoot)
        let window = (since: "2026-05-01", until: "2026-12-31")

        // Matching slug → included, with a GitHub commit-URL prefix.
        let matched = try await gm.summarizeCommits(
            since: window.since, until: window.until, includeRepos: ["acme/repo"])
        #expect(matched.count == 1)
        #expect(matched.first?.commitURLPrefix == "https://github.com/acme/repo/commit/")

        // Case-insensitive match.
        let cased = try await gm.summarizeCommits(
            since: window.since, until: window.until, includeRepos: ["ACME/Repo"])
        #expect(cased.count == 1)

        // Same bare name under a different org → no match.
        let other = try await gm.summarizeCommits(
            since: window.since, until: window.until, includeRepos: ["other/repo"])
        #expect(other.isEmpty)

        // Empty scope set → nothing (distinct from nil = include all).
        let none = try await gm.summarizeCommits(
            since: window.since, until: window.until, includeRepos: [])
        #expect(none.isEmpty)
    }
}
