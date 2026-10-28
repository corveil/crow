import Foundation

/// Session-log collector **behavior tuning** (CROW-1056, slimmed in CROW-1070) —
/// the global knobs for the multi-harness session-log collector.
///
/// **Not a secret; not the opt-in.** Since CROW-1070 the upload *destination* and
/// *credential* are the opting-in workspace's own **local-only AI gateway**
/// (`WorkspaceInfo.gateway`) — never a field in this block — and the opt-in is the
/// per-workspace `WorkspaceInfo.uploadSessionLogs` checkbox. So this block carries
/// no credential, no destination and no opt-in list: only three behavior knobs.
/// It is therefore an ordinary, browser-editable config block (Settings → General
/// → "Session logs"), reachable over `set-config` and the (no-longer-local-only)
/// `crow logsync` CLI alike.
///
/// The removed `enabled` / `baseURL` / `apiKeyRef` / `enabledWorkspaces` fields are
/// migrated on first boot by ``LogSyncMigration`` — a legacy `enabledWorkspaces`
/// opt-in becomes the matching workspace's `uploadSessionLogs`.
public struct LogSyncConfig: Codable, Sendable, Equatable {
    /// Days to retain entries in the local upload ledger before pruning
    /// (housekeeping only — mirrors `TelemetryConfig.retentionDays`; the server
    /// enforces its own artifact retention). 0 keeps entries forever.
    public var retentionDays: Int
    /// A session whose newest log file changed within this window is treated as
    /// still active and is NOT uploaded yet — the server rejects a second upload
    /// of the same `(session, harness, kind)` with 409, so the collector waits
    /// for the transcript to go quiescent before capturing it once. Terminal
    /// sessions (completed/archived) bypass this. Default 30 minutes.
    public var quietPeriodMinutes: Int
    /// Per-artifact upload cap in bytes, measured on the **gzip-compressed**
    /// body as sent (CROW-1394). A transcript still over it after compression
    /// is truncated and flagged. Default 8,388,608 — Corveil's own limit
    /// (`CORVEIL_WORKER_ARTIFACT_MAX_BYTES`, 8 MiB).
    public var maxUploadBytes: Int

    /// Corveil's per-artifact body limit, and the default `maxUploadBytes`.
    public static let defaultMaxUploadBytes = 8 * 1024 * 1024

    public init(
        retentionDays: Int = 30,
        quietPeriodMinutes: Int = 30,
        maxUploadBytes: Int = LogSyncConfig.defaultMaxUploadBytes
    ) {
        self.retentionDays = retentionDays
        self.quietPeriodMinutes = quietPeriodMinutes
        self.maxUploadBytes = maxUploadBytes
    }

    /// Per-key tolerant decode — an older `config.json` lacking any field (or the
    /// whole block) still decodes (CROW-814 idiom). The removed CROW-1070 keys
    /// (`enabled`/`baseURL`/`apiKeyRef`/`enabledWorkspaces`) are simply ignored
    /// here and dropped on the next encode; ``LogSyncMigration`` reads them once,
    /// from the raw JSON, to carry a legacy opt-in over to `uploadSessionLogs`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        quietPeriodMinutes = try c.decodeIfPresent(Int.self, forKey: .quietPeriodMinutes) ?? 30
        maxUploadBytes = try c.decodeIfPresent(Int.self, forKey: .maxUploadBytes) ?? Self.defaultMaxUploadBytes
    }

    enum CodingKeys: String, CodingKey {
        case retentionDays, quietPeriodMinutes, maxUploadBytes
    }
}
