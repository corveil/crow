import Foundation
import CrowCore

/// Discovers git repos across workspaces and manages worktrees.
public actor GitManager {
    /// Workspace config is only needed by `discoverRepos`. Operations that
    /// act on an explicit path (worktree create/remove, `rebaseOntoBase`)
    /// don't use it, so it's optional and the no-arg `init()` lets callers
    /// that only rebase (e.g. IssueTracker) construct one without plumbing
    /// `WorkspaceConfig` through.
    private let config: WorkspaceConfig?

    public init(config: WorkspaceConfig? = nil) {
        self.config = config
    }

    /// Discover all git repositories under devRoot.
    public func discoverRepos() async throws -> [RepoInfo] {
        guard let config else { return [] }
        let devRoot = config.devRoot
        let fm = FileManager.default
        guard let workspaceDirs = try? fm.contentsOfDirectory(atPath: devRoot) else {
            return []
        }

        var repos: [RepoInfo] = []
        for wsDir in workspaceDirs {
            let wsPath = (devRoot as NSString).appendingPathComponent(wsDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: wsPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !config.defaults.excludeDirs.contains(wsDir) else { continue }
            // crow-reviews holds transient PR-review clones (full clones that
            // resolve to the same org/repo slug as the canonical checkout); never
            // discover them or they'd duplicate the real repo in the summary scan.
            guard wsDir != "crow-reviews" else { continue }

            let wsConfig = config.workspaces[wsDir]
            let provider = wsConfig?.provider ?? config.defaults.provider
            let cli = wsConfig?.cli ?? config.defaults.cli
            let host = wsConfig?.host

            guard let repoDirs = try? fm.contentsOfDirectory(atPath: wsPath) else { continue }
            for repoDir in repoDirs {
                let repoPath = (wsPath as NSString).appendingPathComponent(repoDir)
                let gitPath = (repoPath as NSString).appendingPathComponent(".git")
                var gitIsDir: ObjCBool = false

                // Only include actual repos (not worktrees — .git is a directory, not a file)
                guard fm.fileExists(atPath: gitPath, isDirectory: &gitIsDir), gitIsDir.boolValue else { continue }

                repos.append(RepoInfo(
                    name: repoDir,
                    path: repoPath,
                    workspace: wsDir,
                    provider: provider,
                    cli: cli,
                    host: host
                ))
            }
        }
        return repos
    }

    /// Create a worktree for a repo.
    ///
    /// If the branch already exists on the remote, the worktree tracks it.
    /// Otherwise, a new branch is created from the repo's default branch with `--no-track`
    /// to prevent accidental pushes to the default branch.
    ///
    /// If creation fails because a local branch with the same name already exists,
    /// the conflicting branch is deleted and the operation is retried once.
    public func createWorktree(repoPath: String, worktreePath: String, branch: String) async throws {
        // Check if branch exists on remote
        let lsRemote = try await run(["git", "-C", repoPath, "ls-remote", "--heads", "origin", branch])
        let branchExistsOnRemote = !lsRemote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        _ = try await run(["git", "-C", repoPath, "fetch", "origin"])

        if branchExistsOnRemote {
            try await createWorktreeWithRetry(repoPath: repoPath, worktreePath: worktreePath, args: [
                "git", "-C", repoPath, "worktree", "add", worktreePath,
                "-b", branch, "--track", "origin/\(branch)",
            ], branch: branch)
        } else {
            let defaultBranch = try await resolveDefaultBranch(repoPath: repoPath)
            try await createWorktreeWithRetry(repoPath: repoPath, worktreePath: worktreePath, args: [
                "git", "-C", repoPath, "worktree", "add", worktreePath,
                "-b", branch, "--no-track", "origin/\(defaultBranch)",
            ], branch: branch)
        }
    }

    /// Remove a worktree.
    public func removeWorktree(repoPath: String, worktreePath: String) async throws {
        _ = try await run(["git", "-C", repoPath, "worktree", "remove", worktreePath])
    }

    // MARK: - Rebase

    /// Rebase the worktree's current branch onto `origin/<baseBranch>` and
    /// force-push it with `--force-with-lease`.
    ///
    /// Designed to run unattended from the IssueTracker poll loop, so it is
    /// deliberately conservative:
    /// - **Never touches a dirty tree.** A `git status --porcelain` check
    ///   short-circuits to `.dirtyWorktree` so we never clobber a Claude
    ///   session's in-progress edits.
    /// - **Verifies HEAD is on `branch`** before rebasing, so a worktree that
    ///   was switched to another branch is left alone (`.failed`).
    /// - **Requires the local branch to match the remote PR head** before
    ///   rewriting — committed-but-unpushed local commits (or a stale local
    ///   branch) yield `.outOfSyncWithRemote` so a force-push can't publish
    ///   unpushed work or revert remote commits.
    /// - **Aborts on conflict** to restore a clean checkout, then reports
    ///   `.conflicts` so the caller can hand resolution to a Claude session.
    /// - **`--force-with-lease`** (against the remote head of `branch` fetched
    ///   at the start) so a concurrent push to the PR branch fails the lease
    ///   rather than being overwritten.
    ///
    /// Returns a `RebaseOutcome` instead of throwing: the caller branches on
    /// the result (push / delegate / defer / log) rather than catching.
    public func rebaseOntoBase(
        worktreePath: String,
        branch: String,
        baseBranch: String
    ) async -> RebaseOutcome {
        do {
            // Refuse to touch a worktree with uncommitted changes.
            let status = try await run(["git", "-C", worktreePath, "status", "--porcelain"])
            guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .dirtyWorktree
            }

            // Confirm we're on the branch we intend to rebase.
            let head = try await run(["git", "-C", worktreePath, "rev-parse", "--abbrev-ref", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard head == branch else {
                return .failed("worktree HEAD is '\(head)', expected '\(branch)'")
            }

            // Fetch both the base (rebase target) and the branch itself so the
            // remote-tracking ref used for the in-sync check and the
            // `--force-with-lease` baseline reflect the current remote state.
            _ = try await run(["git", "-C", worktreePath, "fetch", "origin", baseBranch, branch])

            // Refuse to rewrite a branch that isn't in sync with its remote:
            // local commits not yet pushed (ahead) would be published
            // unexpectedly, and a stale local branch (behind/diverged) would
            // revert remote commits on force-push. Only proceed when the local
            // head exactly matches the remote PR head.
            let localSha = try await run(["git", "-C", worktreePath, "rev-parse", "HEAD"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let remoteSha = try await run(["git", "-C", worktreePath, "rev-parse", "origin/\(branch)"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard localSha == remoteSha else {
                return .outOfSyncWithRemote
            }

            // Attempt the rebase. A failure here is almost always conflicts.
            // `-c commit.gpgsign=false`: rewriting commits would otherwise try
            // to (re)sign each one, which can block on a pinentry/SSH-agent
            // prompt — fatal for an unattended background rebase.
            do {
                _ = try await run([
                    "git", "-C", worktreePath, "-c", "commit.gpgsign=false",
                    "rebase", "origin/\(baseBranch)",
                ])
            } catch let error as GitError {
                // Distinguish a genuine conflict from other failures (e.g. a
                // bad base ref) by looking for unmerged paths — robust across
                // git versions, unlike matching stderr text. Always abort
                // afterward to restore a clean tree.
                let unmerged = (try? await run([
                    "git", "-C", worktreePath, "diff", "--name-only", "--diff-filter=U",
                ])) ?? ""
                _ = try? await run(["git", "-C", worktreePath, "rebase", "--abort"])
                guard unmerged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .conflicts
                }
                // Not a conflict — surface the failure rather than misleadingly
                // asking Claude to "resolve conflicts".
                if case .commandFailed(_, _, let stderr) = error {
                    return .failed("rebase failed: \(stderr.prefix(300))")
                }
                return .failed("rebase failed")
            }

            // Rebase succeeded cleanly — publish it.
            do {
                _ = try await run([
                    "git", "-C", worktreePath, "push",
                    "--force-with-lease", "origin", branch,
                ])
            } catch let error as GitError {
                if case .commandFailed(_, _, let stderr) = error {
                    return .failed("push --force-with-lease rejected: \(stderr.prefix(300))")
                }
                return .failed("push failed")
            }
            return .rebasedAndPushed
        } catch let error as GitError {
            return .failed(error.errorDescription ?? "git error")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    /// Resolve the default branch for the remote (e.g. main, master).
    private func resolveDefaultBranch(repoPath: String) async throws -> String {
        let ref = try await run(["git", "-C", repoPath, "symbolic-ref", "refs/remotes/origin/HEAD"])
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        // refs/remotes/origin/main → main
        if let lastSlash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: lastSlash)...])
        }
        throw GitError.noDefaultBranch(remote: "origin")
    }

    /// Attempt to create a worktree; retry once if the branch already exists locally.
    private func createWorktreeWithRetry(
        repoPath: String, worktreePath: String, args: [String], branch: String
    ) async throws {
        do {
            _ = try await run(args)
        } catch let error as GitError {
            guard case .commandFailed(_, _, let stderr) = error,
                  stderr.contains("already exists") else {
                throw error
            }
            // Delete the conflicting local branch and retry once
            _ = try await run(["git", "-C", repoPath, "branch", "-D", branch])
            _ = try await run(args)
        }
    }

    /// Run a git command, returning stdout on success.
    private func run(_ args: [String]) async throws -> String {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw GitError.commandFailed(
                command: args.joined(separator: " "),
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }
        return stdout
    }
}

/// Result of `GitManager.rebaseOntoBase`. Distinguishes the outcomes the
/// caller must handle differently: a clean rebase that was pushed, conflicts
/// that need delegation to a Claude session, a dirty worktree to retry later,
/// and any other failure to log.
public enum RebaseOutcome: Sendable, Equatable {
    /// Rebase applied cleanly and the branch was force-pushed.
    case rebasedAndPushed
    /// Rebase hit conflicts; the rebase was aborted (tree is clean again) and
    /// resolution should be delegated to a Claude session.
    case conflicts
    /// The worktree had uncommitted changes; nothing was touched. Transient —
    /// retry once the tree is clean.
    case dirtyWorktree
    /// The local branch head doesn't match the remote PR head — there are
    /// committed-but-unpushed local commits (ahead) or the worktree is stale
    /// relative to the remote (behind/diverged). Nothing was touched, since a
    /// rebase + force-push would either publish unpushed work or revert remote
    /// commits. Transient — retry once the branch is back in sync.
    case outOfSyncWithRemote
    /// Any other failure (branch mismatch, fetch error, rejected push, …).
    case failed(String)
}

public struct RepoInfo: Sendable {
    public let name: String
    public let path: String
    public let workspace: String
    public let provider: String
    public let cli: String
    public let host: String?
}

public enum GitError: Error, LocalizedError {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
    case branchAlreadyExists(String)
    case noDefaultBranch(remote: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let exitCode, let stderr):
            return "Git command failed (\(exitCode)): \(command)\n\(stderr)"
        case .branchAlreadyExists(let branch):
            return "Branch '\(branch)' already exists"
        case .noDefaultBranch(let remote):
            return "Could not determine default branch for remote '\(remote)'"
        }
    }
}
