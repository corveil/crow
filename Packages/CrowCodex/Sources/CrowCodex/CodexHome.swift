import Foundation

/// The Codex home directory, resolved the way every Crow ↔ Codex path resolves
/// it: `$CODEX_HOME` when set and non-empty, otherwise `~/.codex`. An empty
/// `CODEX_HOME=` is treated as unset — matching `LaunchScaffold` and
/// `CodexTrustSeeder` — so it never yields a CWD-relative path.
///
/// A single source of truth so the launch, trust-seed, hook, and log-collection
/// paths all look at the same tree. A user (or a launchd plist) that sets
/// `CODEX_HOME` has Codex write its rollouts under that tree, so the session-log
/// collector and backfill must read it too (CROW-1089).
public enum CodexHome {
    /// The resolved Codex home directory. `environment` is injectable for tests.
    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let env = environment["CODEX_HOME"], !env.isEmpty { return env }
        return NSString(string: "~/.codex").expandingTildeInPath
    }

    /// `<codexHome>/sessions` — where Codex writes its date-partitioned
    /// `rollout-<ts>-<uuid>.jsonl` transcripts.
    public static func sessionsDir(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (path(environment: environment) as NSString).appendingPathComponent("sessions")
    }
}
