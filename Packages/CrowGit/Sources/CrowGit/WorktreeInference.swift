import Foundation
import CrowCore

/// Reconstruct a `SessionWorktree`'s fields from an on-disk checkout (CROW-1219).
///
/// `add-worktree` records metadata only when `{path}/.git` already exists; this
/// helper is the other half of that failure mode — a session whose managed
/// terminal cwd *is* a git worktree, but whose store has no row. It never
/// creates a checkout.
public enum WorktreeInference {
    public struct Result: Sendable, Equatable {
        public let repoName: String
        public let repoPath: String
        public let worktreePath: String
        public let branch: String

        public init(repoName: String, repoPath: String, worktreePath: String, branch: String) {
            self.repoName = repoName
            self.repoPath = repoPath
            self.worktreePath = worktreePath
            self.branch = branch
        }
    }

    /// Infer repo name, main-clone path, worktree path, and branch from `cwd`.
    ///
    /// Returns `nil` when `cwd` is outside `devRoot`, is not a git checkout,
    /// HEAD is detached / option-shaped, or the main clone would sit outside
    /// `devRoot`. Does not invent a row for a path that is not already a
    /// checkout — the git tree must exist.
    public static func infer(cwd: String, devRoot: String) -> Result? {
        let worktreePath = (cwd as NSString).standardizingPath
        guard !worktreePath.isEmpty else { return nil }
        guard Validation.isPathWithinRoot(worktreePath, root: devRoot) else { return nil }
        // The Manager's cwd is `devRoot` itself. A work session whose
        // managed terminal landed there is not a recoverable checkout.
        let stdRoot = (devRoot as NSString).standardizingPath
        guard worktreePath != stdRoot else { return nil }

        let gitMarker = (worktreePath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitMarker) else { return nil }

        guard let branch = git(["-C", worktreePath, "rev-parse", "--abbrev-ref", "HEAD"]) else {
            return nil
        }
        // Detached HEAD prints `HEAD`. A leading dash would be parsed as an
        // option by later `git` invocations (same guard as `add-worktree`).
        guard !branch.isEmpty, branch != "HEAD", !branch.hasPrefix("-") else { return nil }

        let repoPath: String
        if let main = resolveMainClone(worktreePath: worktreePath) {
            repoPath = main
        } else {
            // `.git` is a directory — this *is* the main clone (or a
            // worktree whose gitdir chain we could not read). Either way the
            // checkout itself is the repo path, matching review-session rows.
            repoPath = worktreePath
        }
        guard Validation.isPathWithinRoot(repoPath, root: devRoot) else { return nil }

        // Prefer the origin slug's last segment (`shell-crm`); fall back to
        // the main clone's folder name, which is the `{workspace}/{repo}`
        // convention `setup.sh` and `discoverRepos` already use.
        let origin = git(["-C", worktreePath, "remote", "get-url", "origin"])
        let repoName = RepoRemote.parse(origin ?? "")?.repo
            ?? (repoPath as NSString).lastPathComponent
        guard !repoName.isEmpty else { return nil }

        return Result(
            repoName: repoName,
            repoPath: repoPath,
            worktreePath: worktreePath,
            branch: branch
        )
    }

    /// The main clone backing a linked worktree, or `nil` when `worktreePath`
    /// is itself the main clone (or not a shape we understand).
    ///
    /// Asks git for `--git-common-dir` rather than parsing `gitdir:` by hand:
    /// the poll path can afford a subprocess, and git's own answer is the
    /// source of truth for "where is the shared dir".
    public static func resolveMainClone(worktreePath: String) -> String? {
        let raw = git([
            "-C", worktreePath, "rev-parse", "--path-format=absolute", "--git-common-dir",
        ]) ?? git(["-C", worktreePath, "rev-parse", "--git-common-dir"])
        guard let raw else { return nil }

        let commonDir: String
        if raw.hasPrefix("/") {
            commonDir = (raw as NSString).standardizingPath
        } else {
            commonDir = ((worktreePath as NSString).appendingPathComponent(raw) as NSString)
                .standardizingPath
        }
        guard (commonDir as NSString).lastPathComponent == ".git" else { return nil }
        let main = ((commonDir as NSString).deletingLastPathComponent as NSString).standardizingPath
        guard !main.isEmpty, main != "/" else { return nil }
        let stdWorktree = (worktreePath as NSString).standardizingPath
        if main == stdWorktree { return nil }
        return main
    }

    private static func git(_ args: [String]) -> String? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.environment = ShellEnvironment.shared.env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            ?? ""
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
