import Foundation

/// Writes (and later removes) the per-session hook configuration that an
/// agent reads to emit lifecycle events back to Crow. For Claude Code this
/// is `.claude/settings.local.json`; other agents will grow their own
/// conformers.
public protocol HookConfigWriter: Sendable {
    /// Install hook entries for `sessionID` in the worktree. Must preserve any
    /// user-authored entries that aren't managed by Crow.
    func writeHookConfig(worktreePath: String, sessionID: UUID, crowPath: String) throws

    /// Remove Crow-managed hook entries from the worktree, preserving user
    /// settings. Used when a session is deleted.
    func removeHookConfig(worktreePath: String)
}
