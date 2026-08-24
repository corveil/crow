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
}
