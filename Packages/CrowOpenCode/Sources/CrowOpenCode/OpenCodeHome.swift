import Foundation

/// The OpenCode data directory, resolved the way OpenCode itself resolves it:
/// `$XDG_DATA_HOME/opencode` when `XDG_DATA_HOME` is set and non-empty, otherwise
/// `~/.local/share/opencode`. An empty `XDG_DATA_HOME=` is treated as unset —
/// matching the XDG spec and the `XDG_CONFIG_HOME` handling in `LaunchScaffold` /
/// `OpenCodeHookConfigWriter` — so it never yields a CWD-relative path.
///
/// A single source of truth so the session-log collector and the historical
/// backfill both read the same store a user (or a launchd plist) that relocates
/// `XDG_DATA_HOME` has OpenCode write into (CROW-1096). This is the data-dir
/// analogue of `CodexHome`; it lives here (not `CodexHome`) because the
/// `sst/opencode` store is XDG-**data** rooted, whereas the hook/MCP config paths
/// are XDG-**config** rooted.
public enum OpenCodeHome {
    /// The resolved OpenCode data directory. `environment` is injectable for tests.
    public static func dataDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("opencode")
        }
        return NSString(string: "~/.local/share/opencode").expandingTildeInPath
    }

    /// `<dataDir>/opencode.db` — the SQLite session store current OpenCode
    /// (1.17.10+, Crow's documented window) writes. Sessions, messages, and parts
    /// live in relational `session` / `message` / `part` tables here; the pre-1.17
    /// JSON object store under `<dataDir>/storage/` is legacy that upstream migrates
    /// into this database on upgrade, so the collector and backfill read only the
    /// database (`OpenCodeStore`).
    public static func databasePath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (dataDir(environment: environment) as NSString).appendingPathComponent("opencode.db")
    }
}
