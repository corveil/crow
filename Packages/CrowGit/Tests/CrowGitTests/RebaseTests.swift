import Foundation
import Testing
@testable import CrowGit

/// Integration tests for `GitManager.rebaseOntoBase`. These shell out to a
/// real `git` against throwaway repos under a temp directory (a bare repo as
/// `origin`, a clone as the worktree). Skipped automatically if `git` isn't
/// on PATH.
@Suite("GitManager.rebaseOntoBase")
struct RebaseTests {

    // MARK: - Harness

    /// Run a git command in `dir` (or anywhere for `init`), returning
    /// (exitCode, stdout). Throws nothing — callers assert via the result.
    @discardableResult
    private func git(_ args: [String], in dir: String? = nil) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var full = ["git"]
        if let dir { full += ["-C", dir] }
        full += args
        p.arguments = full
        var env = ProcessInfo.processInfo.environment
        // Deterministic identity + no signing / hooks / pager.
        env["GIT_AUTHOR_NAME"] = "Test"; env["GIT_AUTHOR_EMAIL"] = "test@example.com"
        env["GIT_COMMITTER_NAME"] = "Test"; env["GIT_COMMITTER_EMAIL"] = "test@example.com"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"
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

    /// Create `origin` (bare) + a `work` clone with `main` and a `feature`
    /// branch (one commit each), both pushed. Returns the work-tree path.
    private func makeRepo() -> (root: String, work: String)? {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("rebase-test-\(UUID().uuidString)")
        let remote = (root as NSString).appendingPathComponent("origin.git")
        let work = (root as NSString).appendingPathComponent("work")
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        guard git(["init", "--bare", "-b", "main", remote]).code == 0 else { return nil }
        guard git(["clone", remote, work]).code == 0 else { return nil }

        write((work as NSString).appendingPathComponent("base.txt"), "base\n")
        git(["add", "."], in: work)
        git(["commit", "-m", "base"], in: work)
        guard git(["push", "-u", "origin", "main"], in: work).code == 0 else { return nil }

        git(["switch", "-c", "feature"], in: work)
        write((work as NSString).appendingPathComponent("feature.txt"), "feature\n")
        git(["add", "."], in: work)
        git(["commit", "-m", "feature change"], in: work)
        guard git(["push", "-u", "origin", "feature"], in: work).code == 0 else { return nil }

        return (root, work)
    }

    private func cleanup(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - Tests

    @Test func cleanRebaseIsPushed() async throws {
        try #require(gitAvailable())
        guard let (root, work) = makeRepo() else { Issue.record("setup failed"); return }
        defer { cleanup(root) }

        // Advance main with a non-conflicting file, leaving feature behind.
        git(["switch", "main"], in: work)
        write((work as NSString).appendingPathComponent("other.txt"), "other\n")
        git(["add", "."], in: work)
        git(["commit", "-m", "main moves on"], in: work)
        #expect(git(["push", "origin", "main"], in: work).code == 0)
        git(["switch", "feature"], in: work)

        let outcome = await GitManager().rebaseOntoBase(
            worktreePath: work, branch: "feature", baseBranch: "main"
        )
        #expect(outcome == .rebasedAndPushed)

        // feature now contains main's new file (rebased on top).
        #expect(FileManager.default.fileExists(
            atPath: (work as NSString).appendingPathComponent("other.txt")))
        // Tree is clean and not mid-rebase.
        #expect(git(["status", "--porcelain"], in: work).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func conflictAbortsAndReportsConflicts() async throws {
        try #require(gitAvailable())
        guard let (root, work) = makeRepo() else { Issue.record("setup failed"); return }
        defer { cleanup(root) }

        // Both feature and main edit base.txt differently → conflict.
        write((work as NSString).appendingPathComponent("base.txt"), "feature-edit\n")
        git(["commit", "-am", "feature edits base"], in: work)
        git(["push", "origin", "feature"], in: work)

        git(["switch", "main"], in: work)
        write((work as NSString).appendingPathComponent("base.txt"), "main-edit\n")
        git(["commit", "-am", "main edits base"], in: work)
        #expect(git(["push", "origin", "main"], in: work).code == 0)
        git(["switch", "feature"], in: work)

        let outcome = await GitManager().rebaseOntoBase(
            worktreePath: work, branch: "feature", baseBranch: "main"
        )
        #expect(outcome == .conflicts)

        // Rebase was aborted: clean tree, no rebase-merge state dir.
        #expect(git(["status", "--porcelain"], in: work).out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let gitDir = git(["rev-parse", "--git-dir"], in: work).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let rebaseDir = (work as NSString).appendingPathComponent("\(gitDir)/rebase-merge")
        #expect(!FileManager.default.fileExists(atPath: rebaseDir))
    }

    @Test func unpushedLocalCommitsAreSkipped() async throws {
        try #require(gitAvailable())
        guard let (root, work) = makeRepo() else { Issue.record("setup failed"); return }
        defer { cleanup(root) }

        // Advance main so the PR is genuinely behind (would otherwise rebase).
        git(["switch", "main"], in: work)
        write((work as NSString).appendingPathComponent("other.txt"), "other\n")
        git(["add", "."], in: work)
        git(["commit", "-m", "main moves on"], in: work)
        #expect(git(["push", "origin", "main"], in: work).code == 0)
        git(["switch", "feature"], in: work)

        // A committed-but-unpushed local commit (clean tree, ahead of remote).
        write((work as NSString).appendingPathComponent("local.txt"), "local\n")
        git(["add", "."], in: work)
        git(["commit", "-m", "local unpushed work"], in: work)

        let outcome = await GitManager().rebaseOntoBase(
            worktreePath: work, branch: "feature", baseBranch: "main"
        )
        #expect(outcome == .outOfSyncWithRemote)
        // The unpushed commit is still HEAD — nothing was rewritten or pushed.
        #expect(git(["log", "-1", "--format=%s"], in: work).out.contains("local unpushed work"))
    }

    @Test func dirtyWorktreeIsSkipped() async throws {
        try #require(gitAvailable())
        guard let (root, work) = makeRepo() else { Issue.record("setup failed"); return }
        defer { cleanup(root) }

        // Uncommitted change present.
        write((work as NSString).appendingPathComponent("feature.txt"), "uncommitted\n")

        let outcome = await GitManager().rebaseOntoBase(
            worktreePath: work, branch: "feature", baseBranch: "main"
        )
        #expect(outcome == .dirtyWorktree)
        // The uncommitted change is untouched.
        let contents = try String(contentsOfFile: (work as NSString).appendingPathComponent("feature.txt"), encoding: .utf8)
        #expect(contents == "uncommitted\n")
    }

    @Test func branchMismatchFails() async throws {
        try #require(gitAvailable())
        guard let (root, work) = makeRepo() else { Issue.record("setup failed"); return }
        defer { cleanup(root) }

        // HEAD is on `feature`, but we ask to rebase `not-the-branch`.
        let outcome = await GitManager().rebaseOntoBase(
            worktreePath: work, branch: "not-the-branch", baseBranch: "main"
        )
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }
}
