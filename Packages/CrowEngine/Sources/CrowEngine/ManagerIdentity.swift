import Foundation
import CrowCore

/// Isolated project identity for extra Manager sessions (CROW-1281).
///
/// Extra Managers used to share `{devRoot}` as cwd. Claude/Codex/Cursor
/// `--continue` / `resume --last` are cwd-scoped, so launch order decided who
/// inherited whose transcript; hydrate also rewrote `{devRoot}/.claude/settings.local.json`
/// with `--session <thisManagerUuid>` for each Manager, last writer owning hook
/// routing for every Claude in that directory.
///
/// The primary Manager stays at `{devRoot}` (skills, CLAUDE.md, repo tree).
/// Every other Manager whose requested cwd is the shared root gets
/// `{devRoot}/.crow/managers/<session-uuid>/` instead — unique Claude project
/// slug, unique hook file, unique `--continue` namespace. `--add-dir {devRoot}`
/// on Claude extra Managers keeps orchestration pointed at the real tree.
enum ManagerIdentity {
    static func relativePath(sessionID: UUID) -> String {
        ".crow/managers/\(sessionID.uuidString)"
    }

    static func directory(devRoot: String, sessionID: UUID) -> String {
        (devRoot as NSString).appendingPathComponent(relativePath(sessionID: sessionID))
    }

    /// Extra Managers requested at `{devRoot}` are relocated into an identity
    /// directory. The primary Manager, and any cwd that is already unique
    /// (or outside the root), stay put.
    static func resolvedCwd(
        requested: String, sessionID: UUID, isPrimary: Bool, devRoot: String?
    ) -> String {
        if isPrimary { return requested }
        guard let root = devRoot else { return requested }
        let stdReq = (requested as NSString).standardizingPath
        let stdRoot = (root as NSString).standardizingPath
        guard stdReq == stdRoot else { return requested }
        return directory(devRoot: root, sessionID: sessionID)
    }

    /// Create the identity directory, a pointer README, and symlinks to the
    /// development root's `CLAUDE.md` / `AGENTS.md` so extra Managers still
    /// see Crow's Manager context.
    @discardableResult
    static func prepareDirectory(at path: String, orchestrationRoot: String) -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        writePointerReadme(at: path, orchestrationRoot: orchestrationRoot)
        linkIfPresent(name: "CLAUDE.md", from: orchestrationRoot, into: path)
        linkIfPresent(name: "AGENTS.md", from: orchestrationRoot, into: path)
        return path
    }

    /// Claude extra Managers need `--add-dir {devRoot}` so tools still see the
    /// real tree after cwd isolation. Nil for the primary Manager (already in
    /// the root), non-Claude agents, and extra Managers that already had a
    /// unique cwd of their own (not the identity directory).
    static func additionalDirectory(
        for session: Session, cwd: String, devRoot: String?
    ) -> String? {
        guard session.agentKind == .claudeCode else { return nil }
        guard session.id != AppState.managerSessionID else { return nil }
        guard let root = devRoot else { return nil }
        let identity = (directory(devRoot: root, sessionID: session.id) as NSString)
            .standardizingPath
        let stdCwd = (cwd as NSString).standardizingPath
        return stdCwd == identity ? root : nil
    }

    private static func writePointerReadme(at path: String, orchestrationRoot: String) {
        let readme = (path as NSString).appendingPathComponent("CLAUDE.crow.md")
        guard !FileManager.default.fileExists(atPath: readme) else { return }
        let body = """
        # Crow extra Manager identity

        This directory isolates this Manager's conversation and hook config
        from sibling Managers that would otherwise share the development root.

        The development root is:

        \(orchestrationRoot)

        Prefer that tree for `crow`, `gh`, `git worktree`, and repo work.
        Claude extra Managers also receive `--add-dir` of that path.
        """
        try? body.write(toFile: readme, atomically: true, encoding: .utf8)
    }

    private static func linkIfPresent(name: String, from root: String, into dest: String) {
        let source = (root as NSString).appendingPathComponent(name)
        let target = (dest as NSString).appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source) else { return }
        if fm.fileExists(atPath: target) { return }
        try? fm.createSymbolicLink(atPath: target, withDestinationPath: source)
    }
}
