import Foundation

/// The Muse Code data home — where Muse writes its durable session journals
/// (CROW-1106). Resolved the XDG way, since Muse's documented store lives under
/// the XDG data directory: `$XDG_DATA_HOME/muse` when `$XDG_DATA_HOME` is set and
/// non-empty, otherwise `~/.local/share/muse` (the XDG default). An empty
/// `XDG_DATA_HOME=` is treated as unset — matching `CodexHome` / `GrokHome` — so
/// it never yields a CWD-relative path.
///
/// A single source of truth so the session-log collector and the backfill read
/// the same tree. A user (or a launchd plist) that relocates `$XDG_DATA_HOME` has
/// Muse write its journals under that tree, so the collector must read it too.
///
/// ⚠️ Version-pinned re-check target: the `~/.local/share/muse` location and its
/// XDG-relative resolution are from Meta's dev cookbook + a third-party parser,
/// **not verified against a live install** (Muse is Meta-auth-gated, CROW-1099).
/// If Muse ignores `$XDG_DATA_HOME` on a machine that sets it, the collector
/// simply finds nothing there (fails safe — never misattributes).
public enum MuseHome {
    /// The resolved Muse data home directory. `environment` is injectable for tests.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("muse")
        }
        return NSString(string: "~/.local/share/muse").expandingTildeInPath
    }

    /// `<museHome>/sessions` — where Muse writes its date-partitioned
    /// `<YYYY>/<MM>/<DD>/<id>/session.jsonl` journals.
    public static func sessionsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (path(environment: environment) as NSString).appendingPathComponent("sessions")
    }

    /// User-scope config dir (`settings.json`, including `mcp_servers`). Official
    /// Muse docs name `~/.config/muse/settings.json` (Configuration and context
    /// + Extending and automating). Distinct from `path()` — journals live under
    /// the XDG *data* tree; MCP does not.
    ///
    /// Honors `$XDG_CONFIG_HOME` when set and non-empty (`$XDG_CONFIG_HOME/muse`),
    /// otherwise `~/.config/muse` — the XDG default that the docs pin. An empty
    /// `XDG_CONFIG_HOME=` is treated as unset so it never yields a CWD-relative
    /// path (same empty-is-unset rule as `path()` / `CodexHome` / `GrokHome`).
    ///
    /// ⚠️ Version-pinned re-check target: official docs spell the literal
    /// `~/.config/muse/settings.json` and do not mention `$XDG_CONFIG_HOME`. If
    /// Muse ignores a relocated config home, Crow would write a `jira` server
    /// Muse never loads (fails open — the prompt still has an `acli` fallback).
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return (xdg as NSString).appendingPathComponent("muse")
        }
        return NSString(string: "~/.config/muse").expandingTildeInPath
    }

    /// `<configHome>/settings.json` — the user-scope file Muse loads for
    /// `mcp_servers` (CROW-1209). Project `.muse/` is a different surface
    /// (stripped from review clones; Crow does not write a project MCP file).
    public static func settingsPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (configHome(environment: environment) as NSString).appendingPathComponent("settings.json")
    }
}
