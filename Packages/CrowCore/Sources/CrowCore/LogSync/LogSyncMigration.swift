import Foundation

/// One-shot migration of the legacy global `logSync` opt-in to the per-workspace
/// `uploadSessionLogs` checkbox (CROW-1070).
///
/// CROW-1070 removed `logSync.enabled` / `baseURL` / `apiKeyRef` /
/// `enabledWorkspaces` — the upload destination + credential now come from the
/// opting-in workspace's own local-only `gateway`, and the opt-in is the
/// per-workspace `WorkspaceInfo.uploadSessionLogs` flag. A user who had opted a
/// workspace in through the old CLI list (`crow logsync set --add-workspace …`)
/// should keep uploading without re-ticking anything, so on first boot we carry
/// that opt-in over.
///
/// The pure ``migrate(config:rawJSON:)`` reads the removed keys from the raw JSON
/// (they no longer exist on ``LogSyncConfig``) and folds any `enabledWorkspaces`
/// name into the matching workspace's `uploadSessionLogs`. Re-encoding the config
/// drops the removed keys, so the migration is idempotent — a second pass sees no
/// removed key and returns `nil`.
public enum LogSyncMigration {
    /// The legacy `logSync` keys removed in CROW-1070, decoded from the raw config
    /// JSON. All optional: a non-nil value means the key was present, which is what
    /// arms the one-shot migration.
    private struct LegacyLogSync: Decodable {
        var enabled: Bool?
        var enabledWorkspaces: [String]?
        var baseURL: String?
        var apiKeyRef: String?

        /// Whether the raw config carried any key CROW-1070 removed — the trigger
        /// for a migrate-and-rewrite (which then drops them, so it won't re-fire).
        var hasAnyRemovedKey: Bool {
            enabled != nil || enabledWorkspaces != nil || baseURL != nil || apiKeyRef != nil
        }
    }

    private struct RawConfigProbe: Decodable {
        var logSync: LegacyLogSync?
    }

    /// Given the loaded `config` and the raw JSON it was decoded from, return a
    /// migrated config, or `nil` when there is nothing to migrate.
    ///
    /// Fires only when the raw JSON still carries a removed `logSync` key. It folds
    /// a legacy `enabledWorkspaces` opt-in into the matching workspace's
    /// `uploadSessionLogs` — **only** when the legacy master switch `enabled` was
    /// true, so a workspace that uploaded nothing before (switch off, or listed but
    /// inert) keeps uploading nothing rather than being silently turned on. Callers
    /// persist the result; the slim encode drops the removed keys, making a repeat
    /// pass a no-op.
    public static func migrate(config: AppConfig, rawJSON: Data) -> AppConfig? {
        guard let probe = try? JSONDecoder().decode(RawConfigProbe.self, from: rawJSON),
              let legacy = probe.logSync, legacy.hasAnyRemovedKey
        else { return nil }

        var migrated = config
        if legacy.enabled == true, let names = legacy.enabledWorkspaces, !names.isEmpty {
            let wanted = Set(names.map { $0.lowercased() })
            for i in migrated.workspaces.indices
            where wanted.contains(migrated.workspaces[i].name.lowercased()) {
                migrated.workspaces[i].uploadSessionLogs = true
            }
        }
        return migrated
    }
}
