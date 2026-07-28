import Foundation

/// The one place the dev root's own reserved directory names live, so the code
/// that *creates* review clones, the repo scan that *skips* them, workspace-name
/// validation, and gateway resolution can never drift (CROW-891).
///
/// The dev root holds one directory per workspace plus a small number of
/// Crow-owned directories that are *not* workspaces. Those are indistinguishable
/// from a workspace folder by path shape alone, so anything deriving a workspace
/// from a path has to know which names are reserved.
public enum DevRootLayout {
    /// Holds transient PR-review clones at `{devRoot}/crow-reviews/{repo}-pr-{N}`.
    ///
    /// Deliberately *not* a workspace: review clones sit here rather than under
    /// the owning workspace's folder, which is why a review session resolves its
    /// workspace by repo slug instead of by path (CROW-891).
    public static let reviewsDirName = "crow-reviews"

    /// Directory names a workspace may not take, because a workspace folder of
    /// that name would collide with Crow's own dev-root layout.
    public static let reservedWorkspaceNames: Set<String> = [reviewsDirName]

    /// Whether `name` collides with a reserved dev-root directory.
    ///
    /// Case-insensitive: APFS is case-preserving but case-insensitive, so a
    /// workspace named `Crow-Reviews` would be the very same directory as the
    /// review-clone root.
    public static func isReservedWorkspaceName(_ name: String) -> Bool {
        reservedWorkspaceNames.contains(name.lowercased())
    }

    /// The review-clone root under a dev root.
    public static func reviewsDir(devRoot: String) -> String {
        (devRoot as NSString).appendingPathComponent(reviewsDirName)
    }
}
