import Foundation

/// The Cursor CLI's config/data home, resolved the way every Crow ↔ Cursor path
/// resolves it: `$CURSOR_CONFIG_DIR` when set and non-empty, otherwise
/// `~/.cursor`. An empty `CURSOR_CONFIG_DIR=` is treated as unset — matching
/// `CursorMCPConfigWriter` — so it never yields a CWD-relative path.
///
/// A single source of truth so the MCP-bridge and session-log-collection paths
/// look at the same tree. A user (or a launchd plist) that sets
/// `CURSOR_CONFIG_DIR` has Cursor keep its per-chat stores under that tree, so
/// the session-log collector and backfill must read it too (CROW-1095).
public enum CursorHome {
    /// The resolved Cursor home directory. `environment` is injectable for tests.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let env = environment["CURSOR_CONFIG_DIR"], !env.isEmpty { return env }
        return NSString(string: "~/.cursor").expandingTildeInPath
    }

    /// `<cursorHome>/chats` — where the `cursor-agent` CLI writes each chat's
    /// `<chatId>/<subId>/store.db` (SQLite) + sibling `meta.json`. This is the
    /// CLI's per-chat store, **not** the Cursor IDE's `workspaceStorage`.
    public static func chatsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (path(environment: environment) as NSString).appendingPathComponent("chats")
    }
}
