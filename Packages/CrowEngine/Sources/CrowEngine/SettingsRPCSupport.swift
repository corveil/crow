import CrowCore
import CrowIPC
import Foundation

/// Pure decode/encode helpers for the `telemetry-*` / `cleanup-*` / `ui-*` RPC
/// handlers behind `crow telemetry` / `crow cleanup` / `crow ui` (CROW-814), and
/// for `automation-*` behind `crow automation` (CROW-812).
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

    // MARK: - Automation (CROW-812)

    /// The Settings → Automation tab as one payload: the eight top-level
    /// `AppConfig` booleans, the three `autoRespond` booleans, and the three
    /// board-filter lists.
    ///
    /// `auto_respond` and `defaults` nest by *config-block* name, the same
    /// reasoning as `uiJSON`'s `sidebar`: the board-filter lists genuinely live
    /// under `AppConfig.defaults`, not at top level, and nesting keeps the wire
    /// shape honest about where a hand edit would go.
    ///
    /// `effective_exclude_review_repos` is read-only and derived — the global
    /// list unioned with every workspace's per-workspace `excludeReviewRepos`,
    /// which is what the review board actually filters on. Without it the CLI is
    /// blind to the per-workspace half and a caller can't explain why a repo is
    /// still hidden. `automation-set` ignores it.
    ///
    /// `config_readable` follows `notifications-get`: `ConfigStore.loadConfig`
    /// returns nil both for "no config yet" (defaults really apply) and for
    /// "present but undecodable" (the defaults are a fiction). That matters more
    /// here than for telemetry — six of these twelve booleans default to `true`,
    /// so a caller shown invented settings as fact would conclude automation is
    /// armed when the daemon can't read the file at all.
    public static func automationJSON(
        _ config: AppConfig, configReadable: Bool = true
    ) -> JSONValue {
        .object([
            "remote_control_enabled": .bool(config.remoteControlEnabled),
            "manager_auto_permission_mode": .bool(config.managerAutoPermissionMode),
            "review_auto_permission_mode": .bool(config.reviewAutoPermissionMode),
            "coder_view_auto_permission_mode": .bool(config.coderViewAutoPermissionMode),
            "jobs_auto_permission_mode": .bool(config.jobsAutoPermissionMode),
            "attribution_trailers": .bool(config.attributionTrailers),
            "auto_create_watcher_enabled": .bool(config.autoCreateWatcherEnabled),
            "auto_merge_watcher_enabled": .bool(config.autoMergeWatcherEnabled),
            "auto_respond": .object([
                "respond_to_changes_requested":
                    .bool(config.autoRespond.respondToChangesRequested),
                "respond_to_failed_checks": .bool(config.autoRespond.respondToFailedChecks),
                "auto_rebase_and_resolve_conflicts":
                    .bool(config.autoRespond.autoRebaseAndResolveConflicts),
                "auto_re_request_review": .bool(config.autoRespond.autoReRequestReview),
            ]),
            "defaults": .object([
                "exclude_review_repos": stringArray(config.defaults.excludeReviewRepos),
                "ignore_review_labels": stringArray(config.defaults.ignoreReviewLabels),
                "exclude_ticket_repos": stringArray(config.defaults.excludeTicketRepos),
                "effective_exclude_review_repos":
                    stringArray(config.effectiveExcludeReviewRepos),
            ]),
            "config_readable": .bool(configReadable),
        ])
    }

    private static func stringArray(_ values: [String]) -> JSONValue {
        .array(values.map { .string($0) })
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

    /// The session-log collector block (CROW-1056). The Corveil API-key reference
    /// is shown only when `reveal` is set OR it is an `op://…` pointer (which is a
    /// reference, not the secret); a plaintext key is masked. `api_key_set`
    /// reports presence either way, and `configured` distinguishes an absent block
    /// (`logSync == nil`, the collector inert) from an all-defaults one.
    public static func logsyncJSON(_ logSync: LogSyncConfig?, reveal: Bool) -> JSONValue {
        let cfg = logSync ?? LogSyncConfig()
        let apiKeyDisplay: String
        if cfg.apiKeyRef.isEmpty {
            apiKeyDisplay = ""
        } else if reveal || cfg.apiKeyRef.hasPrefix("op://") {
            apiKeyDisplay = cfg.apiKeyRef
        } else {
            apiKeyDisplay = "<hidden>"
        }
        return .object([
            "enabled": .bool(cfg.enabled),
            "base_url": .string(cfg.baseURL),
            "api_key_ref": .string(apiKeyDisplay),
            "api_key_set": .bool(!cfg.apiKeyRef.isEmpty),
            "enabled_workspaces": stringArray(cfg.enabledWorkspaces),
            "retention_days": .int(cfg.retentionDays),
            "quiet_period_minutes": .int(cfg.quietPeriodMinutes),
            "max_upload_bytes": .int(cfg.maxUploadBytes),
            "configured": .bool(logSync != nil),
        ])
    }

    /// PATCH helper for a string-array param: `nil` when absent/null ("leave
    /// unchanged"), throws when present but not an array of strings.
    public static func patchStringList(
        _ params: [String: JSONValue], _ key: String
    ) throws -> [String]? {
        guard let value = params[key], value != .null else { return nil }
        guard let array = value.arrayValue else {
            throw RPCError.invalidParams("\(key) must be an array of strings")
        }
        return array.compactMap { $0.stringValue }
    }

    /// The `ui` group is a *view* namespace, not a single `AppConfig` block:
    /// today `sidebar` and `switcher`, later `terminal` and anything else purely
    /// presentational. Nesting by config-block name mirrors `config.json` and
    /// keeps a future `sidebar.width` from colliding with `terminal.width`;
    /// growing the group stays purely additive.
    public static func uiJSON(sidebar: SidebarSettings, switcher: SwitcherSettings) -> JSONValue {
        .object([
            "sidebar": .object([
                "hide_session_details": .bool(sidebar.hideSessionDetails),
            ]),
            "switcher": switcherJSON(switcher),
        ])
    }

    public static func switcherJSON(_ switcher: SwitcherSettings) -> JSONValue {
        .object([
            "enabled": .bool(switcher.enabled),
            "binding": .string(switcher.binding),
            "capture_in_terminal": .bool(switcher.captureInTerminal),
            "order": .string(switcher.order.rawValue),
            "preview": .bool(switcher.preview),
            "include": .object([
                "managers": .bool(switcher.include.managers),
                "jobs": .bool(switcher.include.jobs),
                "reviews": .bool(switcher.include.reviews),
                "active": .bool(switcher.include.active),
                "paused": .bool(switcher.include.paused),
                "in_review": .bool(switcher.include.inReview),
                "completed": .bool(switcher.include.completed),
                "archived": .bool(switcher.include.archived),
            ]),
        ])
    }

    /// Patch one `switcher.include` key. `key` is snake_case on the wire
    /// (`in_review` → `inReview`).
    public static func patchSwitcherIncludeKey(
        _ params: [String: JSONValue], prefix: String = "switcher_include_"
    ) throws -> [(WritableKeyPath<SwitcherIncludeSettings, Bool>, Bool)] {
        let keys: [(String, WritableKeyPath<SwitcherIncludeSettings, Bool>)] = [
            ("managers", \.managers),
            ("jobs", \.jobs),
            ("reviews", \.reviews),
            ("active", \.active),
            ("paused", \.paused),
            ("in_review", \.inReview),
            ("completed", \.completed),
            ("archived", \.archived),
        ]
        var patches: [(WritableKeyPath<SwitcherIncludeSettings, Bool>, Bool)] = []
        for (wire, path) in keys {
            guard let value = params[prefix + wire], value != .null else { continue }
            guard let flag = value.boolValue else {
                throw RPCError.invalidParams("\(prefix)\(wire) must be a boolean (true or false)")
            }
            patches.append((path, flag))
        }
        return patches
    }

    public static func patchSwitcherOrder(
        _ params: [String: JSONValue], _ key: String = "switcher_order"
    ) throws -> SwitcherOrder? {
        guard let value = params[key], value != .null else { return nil }
        guard let raw = value.stringValue else {
            throw RPCError.invalidParams("\(key) must be \"mru\" or \"sidebar\"")
        }
        guard let order = SwitcherOrder(rawValue: raw) else {
            throw RPCError.invalidParams("\(key) must be \"mru\" or \"sidebar\"")
        }
        return order
    }

    public static func patchNonEmptyString(
        _ params: [String: JSONValue], _ key: String
    ) throws -> String? {
        guard let value = params[key], value != .null else { return nil }
        guard let text = value.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RPCError.invalidParams("\(key) must be a non-empty string")
        }
        return text
    }

    /// PATCH helper for a string that MAY be set to empty: `nil` when absent/null
    /// ("leave unchanged"), and an explicit `""` clears the stored value. Used for
    /// `logsync-set`'s `base_url` / `api_key_ref`, where clearing is meaningful.
    public static func patchStringAllowingEmpty(
        _ params: [String: JSONValue], _ key: String
    ) throws -> String? {
        guard let value = params[key], value != .null else { return nil }
        guard let text = value.stringValue else {
            throw RPCError.invalidParams("\(key) must be a string")
        }
        return text
    }

    /// PATCH helper for an integer with a lower bound: `nil` when absent/null,
    /// throws when present-but-not-an-integer or below `min`.
    public static func patchBoundedInt(
        _ params: [String: JSONValue], _ key: String, min: Int
    ) throws -> Int? {
        guard let value = params[key], value != .null else { return nil }
        guard let n = value.intValue else {
            throw RPCError.invalidParams("\(key) must be an integer")
        }
        guard n >= min else {
            throw RPCError.invalidParams("\(key) must be at least \(min)")
        }
        return n
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
