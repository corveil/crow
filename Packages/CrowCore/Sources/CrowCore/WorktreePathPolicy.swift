import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where a new worktree may be created (CROW-1396).
///
/// A session's workspace is derived from its worktree path alone —
/// `workspaceName(forWorktreePath:)` takes the first folder under the dev root —
/// so a worktree created anywhere else is silently attributed to the wrong (or a
/// nonexistent) workspace: no gateway, no custom instructions, no session-log
/// upload. This is the one rule both creation paths enforce: the daemon's
/// `add-worktree` handler and `skills/crow-workspace/setup.sh` (which mirrors it
/// in bash, before `git worktree add`).
///
/// Accepted, after resolving symlinks and `..`:
/// - `{devRoot}/{workspace}/{dir}` where `{workspace}` names a configured
///   workspace (case-insensitive, as everywhere else — APFS is);
/// - `{devRoot}/crow-reviews/{dir}` (`DevRootLayout.reviewsDirName`).
///
/// Existing worktrees are never re-checked; this gates creation only.
public enum WorktreePathPolicy {
    /// What an accepted path resolved to.
    public enum Placement: Equatable, Sendable {
        /// Under a configured workspace; carries the workspace's configured name.
        case workspace(String)
        /// Under the PR review-clone root.
        case reviews
    }

    /// Why a path was refused. `message` is the operator-facing error.
    public struct Rejection: Error, Equatable, Sendable {
        public let path: String
        public let reason: String
        public let message: String
    }

    /// Validate `path` against the dev-root layout.
    ///
    /// - Parameters:
    ///   - path: the worktree path as given (must be absolute).
    ///   - devRoot: the configured dev root.
    ///   - workspaceNames: the configured workspace names.
    public static func validate(
        _ path: String, devRoot: String, workspaceNames: [String]
    ) -> Result<Placement, Rejection> {
        func reject(_ reason: String) -> Result<Placement, Rejection> {
            .failure(Rejection(
                path: path, reason: reason,
                message: rejectionMessage(
                    path: path, reason: reason, devRoot: devRoot, workspaceNames: workspaceNames)))
        }

        guard path.hasPrefix("/") else { return reject("it is not an absolute path") }

        let root = resolve(devRoot)
        let full = resolve(path)
        guard full != root else { return reject("it is the dev root itself") }
        guard full.hasPrefix(root + "/") else { return reject("it is outside the dev root") }

        let components = full.dropFirst(root.count + 1)
            .split(separator: "/").map(String.init)
        guard let folder = components.first else { return reject("it is the dev root itself") }

        let placement: Placement
        if folder.lowercased() == DevRootLayout.reviewsDirName {
            placement = .reviews
        } else if let name = workspaceNames.first(where: { $0.lowercased() == folder.lowercased() }) {
            placement = .workspace(name)
        } else if components.count == 1 {
            return reject("it sits directly in the dev root, not inside a workspace folder")
        } else {
            return reject("'\(folder)' is not a configured workspace")
        }

        switch components.count {
        case 2: break
        case 1: return reject("it is the '\(folder)' folder itself, not a folder inside it")
        default: return reject("it is nested \(components.count - 2) level\(components.count == 3 ? "" : "s") too deep inside '\(folder)'")
        }

        // The resolved path says where the files land; the *spelled* path is
        // what Crow stores and later reads the workspace from
        // (`workspaceName(forWorktreePath:)` never resolves a symlink). Both
        // must name the same folder, or `{devRoot}/alias/x` with `alias` →
        // `Corveil` would be accepted yet attributed to `alias` (PR #1398 review).
        let spelledRoot = collapse(devRoot)
        let spelled = collapse(path)
        guard spelled.hasPrefix(spelledRoot + "/") else {
            return reject("it does not spell out the dev root \(spelledRoot) (it reaches it only through a symlink)")
        }
        let spelledFolder = spelled.dropFirst(spelledRoot.count + 1)
            .split(separator: "/").first.map(String.init) ?? ""
        guard spelledFolder.lowercased() == folder.lowercased() else {
            return reject("'\(spelledFolder)' is a symlink to '\(folder)'; use '\(folder)' itself so Crow attributes the worktree to that workspace")
        }
        return .success(placement)
    }

    /// Collapse `.`, `..` and empty components without touching the filesystem.
    static func collapse(_ path: String) -> String {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The full error: what was given, the expected form, the configured
    /// workspaces, and how to fix it.
    static func rejectionMessage(
        path: String, reason: String, devRoot: String, workspaceNames: [String]
    ) -> String {
        let root = (devRoot as NSString).standardizingPath
        let configured = workspaceNames.isEmpty
            ? "(none configured)"
            : workspaceNames.joined(separator: ", ")
        return "Worktree path '\(path)' is not allowed: \(reason). "
            + "Expected \(root)/{workspace}/{dir} (one folder directly inside a configured workspace) "
            + "or \(root)/\(DevRootLayout.reviewsDirName)/{dir}. "
            + "Configured workspaces: \(configured). "
            + "Fix: create the worktree under one of those workspaces, "
            + "or add its folder as a workspace with `crow workspace add --name <folder>`."
    }

    /// Standardize `path` and resolve symlinks in its longest existing prefix.
    ///
    /// The leaf usually doesn't exist yet (the worktree is about to be created),
    /// so `realpath` runs on the deepest existing ancestor and the rest is
    /// appended, collapsing `.` and `..` in that not-yet-existing tail by hand.
    /// `realpath` rather than Foundation's `resolvingSymlinksInPath` /
    /// `standardizingPath`: on Darwin those strip a leading `/private` only when
    /// the result exists, so the dev root and a not-yet-created child under it
    /// would resolve to different prefixes.
    static func resolve(_ path: String) -> String {
        var existing = path
        var tail: [String] = []
        while !existing.isEmpty, existing != "/", !FileManager.default.fileExists(atPath: existing) {
            tail.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var base = existing.isEmpty ? "/" : existing
        if let resolved = realpath(base, nil) {
            base = String(cString: resolved)
            free(resolved)
        }
        var parts = base.split(separator: "/").map(String.init)
        for component in tail {
            switch component {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
