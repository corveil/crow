import Foundation

/// The one place the per-session artifacts-scratch path convention lives, so the
/// daemon that *serves* images and the terminal env that tells agents where to
/// *write* them can never drift (CROW-593). Ephemeral, under `$TMPDIR`, outside
/// any git worktree.
public enum ArtifactPaths {
    /// Root scratch dir — a sibling of the tmux socket under `$TMPDIR/crow`.
    public static func root() -> URL {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return URL(fileURLWithPath: tmp).appendingPathComponent("crow/artifacts", isDirectory: true)
    }

    /// A session's scratch dir.
    public static func dir(sessionID: UUID) -> URL {
        root().appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }
}
