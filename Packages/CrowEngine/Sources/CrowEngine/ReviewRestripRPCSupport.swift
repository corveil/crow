import CrowCore
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Body of `review-restrip` / `crow review restrip` (CROW-1492).
///
/// The review skill and the re-review prompt call this right after
/// `gh pr checkout`, which restores the PR head's harness config into a live
/// review session (CROW-960). The agent used to run `rm` itself, but Claude
/// Code's sandbox denies writes to `.claude/settings.json` and
/// `.claude/settings.local.json`, so on Claude (most reviews) those two files
/// stayed live for the whole review. `crowd` runs outside any agent sandbox,
/// so the removal happens here instead.
///
/// Guardrails, all enforced here rather than trusted to the caller:
///  - The caller names a session, never a path. The clone is the session's
///    own registered worktree, and the session must be a `.review` session.
///  - That clone must resolve, after symlinks and `..`, to exactly
///    `{devRoot}/crow-reviews/{dir}` (`WorktreePathPolicy`, CROW-1396), and the
///    clone directory itself must not be a symlink.
///  - Only ``ReviewCloneRestrip/paths`` are removed, from the working tree.
///    Never `git rm` (the index entry survives, same as
///    `strip*ConfigFromReviewClone`), and never `.claude/` wholesale.
///  - The clone is attacker-controlled, and `crowd` has no sandbox, so a
///    path is never followed through a symlinked parent: a committed
///    `.claude -> ~/.claude` would otherwise point the removal at the
///    operator's own settings. That case is refused and reported.
///  - After removing, every path is checked again with `lstat`. Anything left
///    makes the call fail, so the skill stops the review.
public enum ReviewRestripRPC {

    /// What one re-strip did.
    public struct Report: Equatable, Sendable {
        /// The clone the paths were removed from.
        public let clonePath: String
        /// Paths that were present and are now gone.
        public let removed: [String]
        /// Paths still present afterwards, each with the reason.
        public let remaining: [Failure]

        public var isComplete: Bool { remaining.isEmpty }
    }

    /// A path the re-strip could not remove.
    public struct Failure: Equatable, Sendable {
        public let path: String
        public let reason: String
    }

    /// Resolve the clone a `.review` session may re-strip, or throw.
    ///
    /// - Parameters:
    ///   - session: the session named by `session_id`, or `nil` if none.
    ///   - worktree: that session's primary worktree, or `nil` if none.
    ///   - devRoot: the configured dev root.
    public static func clonePath(
        session: Session?, worktree: SessionWorktree?, devRoot: String
    ) throws -> String {
        guard let session else {
            throw RPCError.invalidParams("Unknown session_id (no such session)")
        }
        guard session.kind == .review else {
            throw RPCError.invalidParams(
                "Session \(session.id.uuidString) is a \(session.kind.rawValue) session; "
                + "`crow review restrip` only acts on a review session's clone")
        }
        guard let path = worktree?.worktreePath, !path.isEmpty else {
            throw RPCError.applicationError(
                "Review session \(session.id.uuidString) has no clone registered; nothing was stripped")
        }
        switch WorktreePathPolicy.validate(path, devRoot: devRoot, workspaceNames: []) {
        case .success(.reviews):
            break
        case .success(.workspace), .failure:
            throw RPCError.applicationError(
                "Refusing to re-strip '\(path)': it is not a review clone at "
                + "\(devRoot)/\(DevRootLayout.reviewsDirName)/{dir} once symlinks and '..' are resolved")
        }
        switch fileKind(path) {
        case .directory:
            return path
        case .symlink:
            throw RPCError.applicationError(
                "Refusing to re-strip '\(path)': the clone directory is a symlink")
        case .absent:
            throw RPCError.applicationError(
                "Review clone '\(path)' does not exist; nothing was stripped")
        case .other:
            throw RPCError.applicationError(
                "Refusing to re-strip '\(path)': it is not a directory")
        }
    }

    /// Remove ``ReviewCloneRestrip/paths`` from `clonePath`'s working tree,
    /// then check each one again. Idempotent: an absent path is not an error.
    public static func restrip(clonePath: String) -> Report {
        var removed: [String] = []
        var remaining: [Failure] = []
        for relative in ReviewCloneRestrip.paths {
            switch strip(relative, in: clonePath) {
            case .absent: break
            case .removed: removed.append(relative)
            case .failed(let reason): remaining.append(Failure(path: relative, reason: reason))
            }
        }
        let report = Report(clonePath: clonePath, removed: removed, remaining: remaining)
        if report.isComplete {
            CrowLog.info("[ReviewRestrip] Re-stripped \(clonePath): removed \(removed.isEmpty ? "nothing" : removed.joined(separator: " "))")
        } else {
            CrowLog.error("[ReviewRestrip] Re-strip of \(clonePath) incomplete: \(failureSummary(remaining))")
        }
        return report
    }

    /// The error a failed re-strip returns. The skill tells the agent to stop
    /// the review and show this message.
    public static func incompleteMessage(_ report: Report) -> String {
        "Review re-strip incomplete in \(report.clonePath): \(failureSummary(report.remaining)). "
            + "PR-supplied harness config is still on disk; stop the review."
    }

    // MARK: - Internals

    private enum Outcome { case absent, removed, failed(String) }

    private static func strip(_ relative: String, in clonePath: String) -> Outcome {
        let components = relative.split(separator: "/").map(String.init)
        // Walk each parent folder without following a symlink out of the clone.
        var parent = clonePath
        for component in components.dropLast() {
            parent = (parent as NSString).appendingPathComponent(component)
            switch fileKind(parent) {
            case .absent:
                return .absent
            case .directory:
                continue
            case .symlink:
                return .failed("its parent '\(component)' is a symlink, which Crow will not follow out of the clone")
            case .other:
                return .failed("its parent '\(component)' is not a directory")
            }
        }
        let full = (clonePath as NSString).appendingPathComponent(relative)
        if fileKind(full) == .absent { return .absent }
        do {
            // Removes a symlink itself, never its target.
            try FileManager.default.removeItem(atPath: full)
        } catch {
            if fileKind(full) == .absent { return .removed }
            return .failed(error.localizedDescription)
        }
        return fileKind(full) == .absent ? .removed : .failed("it is still present after removal")
    }

    private enum FileKind { case absent, directory, symlink, other }

    /// `lstat`, so a symlink (dangling or not) is seen as itself.
    private static func fileKind(_ path: String) -> FileKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .absent }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    private static func failureSummary(_ failures: [Failure]) -> String {
        failures.map { "\($0.path) (\($0.reason))" }.joined(separator: "; ")
    }
}
