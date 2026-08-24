import Foundation

/// The Grok Build home directory, resolved the way every Crow ↔ Grok path
/// resolves it: `$GROK_HOME` when set and non-empty, otherwise `~/.grok`. An
/// empty `GROK_HOME=` is treated as unset — matching `CodexHome` and
/// `GrokTrustSeeder` — so it never yields a CWD-relative path.
///
/// A single source of truth so the trust-seed and log-collection paths look at
/// the same tree. A user (or a launchd plist) that sets `GROK_HOME` has Grok
/// write its sessions under that tree, so the session-log collector and backfill
/// must read it too (CROW-1098).
public enum GrokHome {
    /// The resolved Grok home directory. `environment` is injectable for tests.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let env = environment["GROK_HOME"], !env.isEmpty { return env }
        return NSString(string: "~/.grok").expandingTildeInPath
    }

    /// `<grokHome>/sessions` — where Grok writes its per-worktree
    /// `<url-encoded-cwd>/<session-uuid>/chat_history.jsonl` transcripts.
    public static func sessionsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (path(environment: environment) as NSString).appendingPathComponent("sessions")
    }
}
