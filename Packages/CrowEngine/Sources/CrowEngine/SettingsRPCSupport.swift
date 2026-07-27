import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `telemetry-*` / `cleanup-*` / `ui-*` RPC
/// handlers behind `crow telemetry` / `crow cleanup` / `crow ui` (CROW-814).
///
/// Same contract as `JobRPC`: no socket, no disk, so the param validation and
/// response shapes are unit-testable in isolation.
///
/// Every `*-set` method is a PATCH — a param that is absent (or explicitly null)
/// leaves the stored value alone. The `patch*` helpers encode exactly that: `nil`
/// means "unchanged", and a *present but wrong-typed* value throws rather than
/// being silently dropped. (`job-edit`'s `params["workspace"]?.stringValue` idiom
/// conflates the two and reports success for a value it ignored.)
public enum SettingsRPC {

    // MARK: - Patch param decoding

    /// - Returns: `nil` when the key is absent or null ("leave unchanged").
    /// - Throws: `RPCError.invalidParams` when present but not a JSON boolean.
    public static func patchBool(_ params: [String: JSONValue], _ key: String) throws -> Bool? {
        guard let value = params[key], value != .null else { return nil }
        guard let flag = value.boolValue else {
            throw RPCError.invalidParams("\(key) must be a boolean (true or false)")
        }
        return flag
    }

    /// OTLP receiver port. Ports below 1024 need root, which `crowd` does not
    /// have; above 65535 is not a port at all.
    ///
    /// This is also the `UInt16` gate: `TelemetryConfig.port` is a `UInt16`, so
    /// persisting an out-of-range value would make the *whole* `config.json`
    /// undecodable on the next load.
    public static func patchPort(
        _ params: [String: JSONValue], _ key: String = "port"
    ) throws -> UInt16? {
        guard let raw = try patchInt(params, key) else { return nil }
        guard (1024...65535).contains(raw), let port = UInt16(exactly: raw) else {
            throw RPCError.invalidParams("\(key) must be between 1024 and 65535")
        }
        return port
    }

    /// Telemetry retention. 0 is meaningful — "keep forever", matching the
    /// Settings picker's `[0, 'Forever']` option and `TelemetryDatabase.pruneOldData`'s
    /// `guard retentionDays > 0` no-op.
    public static func patchRetentionDays(
        _ params: [String: JSONValue], _ key: String = "retention_days"
    ) throws -> Int? {
        guard let days = try patchInt(params, key) else { return nil }
        guard days >= 0 else {
            throw RPCError.invalidParams("\(key) must be 0 or greater (0 = keep forever)")
        }
        return days
    }

    /// Session-cleanup retention. Unlike telemetry there is no "forever" — the
    /// cutoff is `now - retentionHours`, so 0 would delete a session the moment
    /// it completes and a negative value would push the cutoff into the *future*
    /// and sweep every completed/archived session (worktree and branch included)
    /// on the next board poll. Floor is 1, the Settings picker's smallest option.
    public static func patchRetentionHours(
        _ params: [String: JSONValue], _ key: String = "retention_hours"
    ) throws -> Int? {
        guard let hours = try patchInt(params, key) else { return nil }
        guard hours >= 1 else {
            throw RPCError.invalidParams("\(key) must be at least 1 hour")
        }
        return hours
    }

    private static func patchInt(_ params: [String: JSONValue], _ key: String) throws -> Int? {
        guard let value = params[key], value != .null else { return nil }
        guard let number = value.intValue else {
            throw RPCError.invalidParams("\(key) must be an integer")
        }
        return number
    }

    // MARK: - Response encoding

    // Built as object literals rather than via `JSONEncoder(.convertToSnakeCase)`
    // + re-decode (the `JobRPC.jobJSON` trick). `JobConfig` earns that round-trip
    // — dates, a nested schedule enum, a computed `next_run_at`. These three
    // structs are five scalars total, so the literal form keeps the wire shape
    // reviewable at a glance and free of any Bool-vs-number coercion difference
    // between Darwin Foundation and swift-corelibs-foundation.
    //
    // They also carry no credentials, so unlike `get-config` these responses need
    // no `SettingsSecrets.strippedForTransport` pass — there is nothing to strip.

    public static func telemetryJSON(_ telemetry: TelemetryConfig) -> JSONValue {
        .object([
            "enabled": .bool(telemetry.enabled),
            "port": .int(Int(telemetry.port)),
            "retention_days": .int(telemetry.retentionDays),
        ])
    }

    public static func cleanupJSON(_ cleanup: CleanupConfig) -> JSONValue {
        .object([
            "enabled": .bool(cleanup.enabled),
            "retention_hours": .int(cleanup.retentionHours),
        ])
    }

    /// The `ui` group is a *view* namespace, not a single `AppConfig` block:
    /// today only `sidebar`, later `terminal` and anything else purely
    /// presentational. Nesting by config-block name mirrors `config.json` and
    /// keeps a future `sidebar.width` from colliding with `terminal.width`;
    /// growing the group stays purely additive.
    public static func uiJSON(_ sidebar: SidebarSettings) -> JSONValue {
        .object([
            "sidebar": .object([
                "hide_session_details": .bool(sidebar.hideSessionDetails),
            ]),
        ])
    }

    /// Whether a telemetry change needs a daemon restart to take effect.
    ///
    /// `enabled` and `port` are read once at boot and the port is baked into
    /// every agent launch's `OTEL_EXPORTER_OTLP_ENDPOINT`, so a live daemon
    /// cannot adopt them. `retentionDays` only drives the one-shot boot prune —
    /// also next-start, but it's a pruning window rather than a dead subsystem,
    /// so reporting a restart for it would train users to ignore the flag. The
    /// CLI help text says so instead.
    public static func telemetryRestartRequired(
        old: TelemetryConfig, new: TelemetryConfig
    ) -> Bool {
        old.enabled != new.enabled || old.port != new.port
    }
}
