import CrowCore
import CrowEngine
import CrowIPC
import CrowPersistence
import Foundation

/// Granular settings patches (`telemetry-*`, `cleanup-*`, `logsync-*`,
/// `terminal-*`, `ui-*`, `version-update-*`, `automation-*`, `notifications-*`,
/// `defaults-*`, `agents-*`).
///
/// Extracted from `makeCommandRouter`'s dictionary literal (CROW-1134).
func makeSettingsHandlers(
    versionUpdateService: VersionUpdateService?,
    devRoot: String,
    soundLibrary: CustomSoundLibrary = .live
) -> [String: CommandRouter.Handler] {
    // The explicit annotation is load-bearing, not decoration: a large
    // dictionary of closures without a contextual type blows Swift's
    // type-checker solver budget (CROW-1134).
    let handlers: [String: CommandRouter.Handler] = [
        // General-tab settings for `crow telemetry` / `crow cleanup` / `crow ui`
        // (CROW-814). Granular PATCH methods rather than a CLI-side read-modify-
        // write of the whole blob: `set-config` replaces the entire `AppConfig`,
        // and CrowCLI can't decode one (it doesn't depend on CrowCore), so a blob
        // round-trip would make the CLI a second writer racing the web Settings
        // modal. Each write is a locked read-modify-write of one subtree via
        // `mutateConfig`, the same lock `set-config` and the scheduler take.
        //
        // Deliberately NOT gated in `RPCWebSocketHandler.localOnlyDenial` — see
        // the rationale ledger there.
        "telemetry-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return ["telemetry": SettingsRPC.telemetryJSON(config.telemetry)]
        },
        "telemetry-set": { params in
            try await mapRPCError {
                let enabled = try SettingsRPC.patchBool(params, "enabled")
                let port = try SettingsRPC.patchPort(params)
                let retentionDays = try SettingsRPC.patchRetentionDays(params)
                guard enabled != nil || port != nil || retentionDays != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of enabled, port, retention_days.")
                }
                let (old, new) = try mutateConfig(devRoot: devRoot) {
                    config -> (TelemetryConfig, TelemetryConfig) in
                    let before = config.telemetry
                    if let enabled { config.telemetry.enabled = enabled }
                    if let port { config.telemetry.port = port }
                    if let retentionDays { config.telemetry.retentionDays = retentionDays }
                    return (before, config.telemetry)
                }
                return [
                    "telemetry": SettingsRPC.telemetryJSON(new),
                    "restart_required": .bool(
                        SettingsRPC.telemetryRestartRequired(old: old, new: new)),
                ]
            }
        },
        "cleanup-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return ["cleanup": SettingsRPC.cleanupJSON(config.cleanup)]
        },
        "cleanup-set": { params in
            try await mapRPCError {
                let enabled = try SettingsRPC.patchBool(params, "enabled")
                let retentionHours = try SettingsRPC.patchRetentionHours(params)
                guard enabled != nil || retentionHours != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of enabled, retention_hours.")
                }
                let cleanup = try mutateConfig(devRoot: devRoot) { config -> CleanupConfig in
                    if let enabled { config.cleanup.enabled = enabled }
                    if let retentionHours { config.cleanup.retentionHours = retentionHours }
                    return config.cleanup
                }
                // The board poll re-reads config from disk every cycle, so this
                // takes effect within ~60s — no restart.
                return [
                    "cleanup": SettingsRPC.cleanupJSON(cleanup),
                    "restart_required": .bool(false),
                ]
            }
        },
        "logsync-get": { params in logsyncGetHandler(params: params, devRoot: devRoot) },
        "logsync-set": { params in try await logsyncSetHandler(params: params, devRoot: devRoot) },
        "terminal-get": { params in terminalGetHandler(params: params, devRoot: devRoot) },
        "terminal-set": { params in try await terminalSetHandler(params: params, devRoot: devRoot) },
        "ui-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            return ["ui": SettingsRPC.uiJSON(sidebar: config.sidebar, switcher: config.switcher)]
        },
        "ui-set": { params in
            try await mapRPCError {
                let hideSessionDetails = try SettingsRPC.patchBool(params, "hide_session_details")
                let switcherEnabled = try SettingsRPC.patchBool(params, "switcher_enabled")
                let switcherBinding = try SettingsRPC.patchNonEmptyString(params, "switcher_binding")
                let switcherCapture = try SettingsRPC.patchBool(params, "switcher_capture_in_terminal")
                let switcherOrder = try SettingsRPC.patchSwitcherOrder(params)
                let switcherPreview = try SettingsRPC.patchBool(params, "switcher_preview")
                let includePatches = try SettingsRPC.patchSwitcherIncludeKey(params)
                // Reject the chord agents reserve rather than storing it and
                // rewriting it on the next decode — a silent revert leaves the
                // user with no idea why their setting didn't stick (CROW-1002).
                if let switcherBinding, SwitcherSettings.isReservedBinding(switcherBinding) {
                    throw RPCError.invalidParams(
                        "Switcher binding '\(switcherBinding)' is reserved: coding agents cycle "
                        + "permission modes with Shift+Tab, and the switcher would swallow it in "
                        + "every focused terminal. Pick another chord (default: "
                        + "\(SwitcherSettings.defaultBinding)).")
                }
                guard hideSessionDetails != nil || switcherEnabled != nil || switcherBinding != nil
                    || switcherCapture != nil || switcherOrder != nil || switcherPreview != nil
                    || !includePatches.isEmpty else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one UI preference flag.")
                }
                let (sidebar, switcher) = try mutateConfig(devRoot: devRoot) {
                    config -> (SidebarSettings, SwitcherSettings) in
                    if let hideSessionDetails {
                        config.sidebar.hideSessionDetails = hideSessionDetails
                    }
                    if let switcherEnabled { config.switcher.enabled = switcherEnabled }
                    if let switcherBinding { config.switcher.binding = switcherBinding }
                    if let switcherCapture {
                        config.switcher.captureInTerminal = switcherCapture
                    }
                    if let switcherOrder { config.switcher.order = switcherOrder }
                    if let switcherPreview { config.switcher.preview = switcherPreview }
                    for (path, value) in includePatches {
                        config.switcher.include[keyPath: path] = value
                    }
                    return (config.sidebar, config.switcher)
                }
                // Connected browsers re-read the view-affecting config slice off
                // the `configReloaded` push that `startStoreReloadPoll` fires when
                // config.json's mtime moves — no restart, no reload.
                return [
                    "ui": SettingsRPC.uiJSON(sidebar: sidebar, switcher: switcher),
                    "restart_required": .bool(false),
                ]
            }
        },

        // Version update check (CROW-938) — `crow version get|set|--check`.
        "version-update-get": { _ in
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let status = await versionUpdateService?.cachedStatus
            return [
                "version_update": VersionUpdateRPC.configJSON(config.versionUpdate),
                "status": VersionUpdateRPC.statusJSON(status),
            ]
        },
        "version-update-set": { params in
            try await mapRPCError {
                let enabled = try SettingsRPC.patchBool(params, "enabled")
                let intervalHours = try VersionUpdateRPC.patchIntervalHours(params)
                guard enabled != nil || intervalHours != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of enabled, interval_hours.")
                }
                let versionUpdate = try mutateConfig(devRoot: devRoot) { config -> VersionUpdateConfig in
                    if let enabled { config.versionUpdate.enabled = enabled }
                    if let intervalHours {
                        config.versionUpdate.intervalHours = max(
                            VersionUpdateConfig.minimumIntervalHours, intervalHours)
                    }
                    return config.versionUpdate
                }
                return [
                    "version_update": VersionUpdateRPC.configJSON(versionUpdate),
                    "saved": .bool(true),
                ]
            }
        },
        "version-update-check": { params in
            let force = params["force"]?.boolValue ?? false
            guard let versionUpdateService else {
                return ["status": VersionUpdateRPC.statusJSON(nil)]
            }
            let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
            let status: VersionUpdateStatus?
            if force {
                status = await versionUpdateService.runCheck()
            } else {
                status = await versionUpdateService.checkIfDue(
                    enabled: config.versionUpdate.enabled,
                    intervalHours: config.versionUpdate.intervalHours,
                    force: false)
            }
            return ["status": VersionUpdateRPC.statusJSON(status)]
        },

        // Settings → Automation for `crow automation` (CROW-812). Same shape and
        // the same `mutateConfig` lock as the CROW-814 settings verbs above, and
        // likewise un-gated on remote `/rpc` — see the ledger in
        // `RPCWebSocketHandler.localOnlyDenial`.
        //
        // Writes the twelve booleans only. The Automation tab also renders three
        // board-filter lists, but those are `AppConfig.defaults` fields owned by
        // `defaults-set` (CROW-810) — two writers for one field with two sets of
        // list semantics is exactly the drift the parity work exists to prevent.
        // `automation-get` echoes them read-only so the tab still reads as a
        // whole from one call.
        //
        // Writing config is the *whole* job here: flipping one of these in the
        // web Settings modal has no side effect either (`toggleField`'s onchange
        // only marks the form dirty), because every consumer pulls from disk —
        // `applyConfigToAppState` re-runs each board tick, the `IssueTracker`
        // watcher gates are closures that reload config on every call, and
        // `AutoRespondCoordinator` takes a `settingsProvider` closure.
        "automation-get": { _ in
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return ["automation": SettingsRPC.automationJSON(config, configReadable: readable)]
        },
        "automation-set": { params in
            try await mapRPCError {
                let remoteControl = try SettingsRPC.patchBool(params, "remote_control_enabled")
                let managerMode = try SettingsRPC.patchBool(
                    params, "manager_auto_permission_mode")
                let reviewMode = try SettingsRPC.patchBool(params, "review_auto_permission_mode")
                let coderViewMode = try SettingsRPC.patchBool(
                    params, "coder_view_auto_permission_mode")
                let jobsMode = try SettingsRPC.patchBool(params, "jobs_auto_permission_mode")
                let trailers = try SettingsRPC.patchBool(params, "attribution_trailers")
                let autoCreate = try SettingsRPC.patchBool(params, "auto_create_watcher_enabled")
                let autoMerge = try SettingsRPC.patchBool(params, "auto_merge_watcher_enabled")
                let changesRequested = try SettingsRPC.patchBool(
                    params, "respond_to_changes_requested")
                let failedChecks = try SettingsRPC.patchBool(params, "respond_to_failed_checks")
                let autoRebase = try SettingsRPC.patchBool(
                    params, "auto_rebase_and_resolve_conflicts")
                let autoReRequest = try SettingsRPC.patchBool(params, "auto_re_request_review")

                let booleans = [
                    remoteControl, managerMode, reviewMode, coderViewMode, jobsMode, trailers,
                    autoCreate, autoMerge, changesRequested, failedChecks, autoRebase,
                    autoReRequest,
                ]
                guard booleans.contains(where: { $0 != nil }) else {
                    throw RPCError.invalidParams("Nothing to set — provide at least one field")
                }

                let (config, managerModeChanged) = try mutateConfig(devRoot: devRoot) {
                    config -> (AppConfig, Bool) in
                    let managerModeBefore = config.managerAutoPermissionMode
                    if let remoteControl { config.remoteControlEnabled = remoteControl }
                    if let managerMode { config.managerAutoPermissionMode = managerMode }
                    if let reviewMode { config.reviewAutoPermissionMode = reviewMode }
                    if let coderViewMode { config.coderViewAutoPermissionMode = coderViewMode }
                    if let jobsMode { config.jobsAutoPermissionMode = jobsMode }
                    if let trailers { config.attributionTrailers = trailers }
                    if let autoCreate { config.autoCreateWatcherEnabled = autoCreate }
                    if let autoMerge { config.autoMergeWatcherEnabled = autoMerge }
                    if let changesRequested {
                        config.autoRespond.respondToChangesRequested = changesRequested
                    }
                    if let failedChecks {
                        config.autoRespond.respondToFailedChecks = failedChecks
                    }
                    if let autoRebase {
                        config.autoRespond.autoRebaseAndResolveConflicts = autoRebase
                    }
                    if let autoReRequest {
                        config.autoRespond.autoReRequestReview = autoReRequest
                    }
                    return (config, managerModeBefore != config.managerAutoPermissionMode)
                }
                return [
                    "automation": SettingsRPC.automationJSON(config),
                    // `crowd` never needs a restart for any of these — reported
                    // for symmetry with the other settings verbs.
                    "restart_required": .bool(false),
                    // `managerAutoPermissionMode` is the one exception to the
                    // "everything re-reads from disk" rule: it is baked into the
                    // Manager terminal's stored shell command by
                    // `SessionService.managerCommand(for:)` and only re-read on a
                    // Manager rebuild. Reported only when the value actually
                    // moved, so re-setting it to what it already was doesn't nag.
                    "manager_restart_required": .bool(managerModeChanged),
                ]
            }
        },

        // Notification settings for `crow notifications` (CROW-813). Same
        // `AppConfig.notifications` subtree the web Settings → Notifications tab
        // edits; the write goes through the shared config lock, and the daemon's
        // mtime poll broadcasts `configReloaded` so an open tab refreshes.
        // Un-gated on remote `/rpc` for the same reason as `job-*`: this is a
        // core web-Settings surface carrying no secrets
        // (see `RPCWebSocketHandler.localOnlyDenial`).
        "notifications-get": { params in
            try await mapRPCError {
                let event = try params["event"].map { try NotificationRPC.decodeEvent($0) }
                let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
                return ["notifications": NotificationRPC.settingsJSON(
                    config.notifications, only: event, configReadable: readable,
                    customSounds: soundLibrary.list())]
            }
        },
        "notifications-set": { params in
            try await mapRPCError {
                let globalMute = params["global_mute"]?.boolValue
                let soundEnabled = params["sound_enabled"]?.boolValue
                let systemNotificationsEnabled = params["system_notifications_enabled"]?.boolValue
                let event = try params["event"].map { try NotificationRPC.decodeEvent($0) }
                let eventEnabled = params["event_enabled"]?.boolValue
                let eventSoundEnabled = params["event_sound_enabled"]?.boolValue
                let eventSystemEnabled = params["event_system_notification_enabled"]?.boolValue
                let customNames = soundLibrary.names
                let eventSoundName = try params["event_sound_name"].map {
                    try NotificationRPC.decodeSoundName($0, customNames: customNames)
                }

                let hasEventField = eventEnabled != nil || eventSoundEnabled != nil
                    || eventSystemEnabled != nil || eventSoundName != nil
                let hasGlobalField = globalMute != nil || soundEnabled != nil
                    || systemNotificationsEnabled != nil
                if event == nil, hasEventField {
                    throw RPCError.invalidParams("event is required when setting any event_* field")
                }
                if event != nil, !hasEventField {
                    throw RPCError.invalidParams(
                        "event given with nothing to change — provide at least one event_* field")
                }
                guard hasGlobalField || hasEventField else {
                    throw RPCError.invalidParams("Nothing to set — provide at least one field")
                }

                let settings = try mutateConfig(devRoot: devRoot) { config -> NotificationSettings in
                    if let globalMute { config.notifications.globalMute = globalMute }
                    if let soundEnabled { config.notifications.soundEnabled = soundEnabled }
                    if let systemNotificationsEnabled {
                        config.notifications.systemNotificationsEnabled = systemNotificationsEnabled
                    }
                    if let event {
                        // Read through `config(for:)`, which supplies the event's
                        // defaults when it's absent from disk — the common case,
                        // since most configs predate the automation events. A
                        // `eventSettings[event]?.enabled = x` subscript write
                        // would be a silent no-op there. Only the event being
                        // written is materialized: freezing all ten in on a
                        // one-field edit would opt the user out of future
                        // `defaultSound` changes.
                        var eventConfig = config.notifications.config(for: event)
                        if let eventEnabled { eventConfig.enabled = eventEnabled }
                        if let eventSoundEnabled { eventConfig.soundEnabled = eventSoundEnabled }
                        if let eventSystemEnabled {
                            eventConfig.systemNotificationEnabled = eventSystemEnabled
                        }
                        if let eventSoundName { eventConfig.soundName = eventSoundName }
                        config.notifications.eventSettings[event] = eventConfig
                    }
                    return config.notifications
                }
                return [
                    "notifications": NotificationRPC.settingsJSON(
                        settings, only: event, customSounds: soundLibrary.list()),
                    "saved": .bool(true),
                ]
            }
        },

        // Custom notification sounds (CROW-1147). Files live under Application
        // Support, not in config.json — add copies a host path (CLI, local-only);
        // remove deletes by name (web Settings + CLI). The web upload itself is
        // HTTP POST /sounds, because a sound can exceed the 1 MB /rpc frame.
        "notifications-add-sound": { params in
            try await mapRPCError {
                guard let raw = params["path"]?.stringValue,
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RPCError.invalidParams("path required")
                }
                let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/") else {
                    throw RPCError.invalidParams(
                        "path must be absolute (it is resolved by the daemon, not your shell)")
                }
                let name = params["name"]?.stringValue
                do {
                    let sound = try soundLibrary.add(
                        from: URL(fileURLWithPath: path), requestedName: name)
                    let (config, _) = loadConfigReportingReadability(devRoot: devRoot)
                    return [
                        "sound": NotificationRPC.customSoundJSON(sound),
                        "notifications": NotificationRPC.settingsJSON(
                            config.notifications, customSounds: soundLibrary.list()),
                        "saved": .bool(true),
                    ]
                } catch let error as CustomSoundError {
                    throw RPCError.invalidParams(error.localizedDescription)
                }
            }
        },
        "notifications-remove-sound": { params in
            try await mapRPCError {
                guard let raw = params["name"]?.stringValue,
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RPCError.invalidParams("name required")
                }
                do {
                    try soundLibrary.remove(name: raw)
                } catch let error as CustomSoundError {
                    throw RPCError.invalidParams(error.localizedDescription)
                }
                let (config, _) = loadConfigReportingReadability(devRoot: devRoot)
                return [
                    "removed": .bool(true),
                    "name": .string(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "notifications": NotificationRPC.settingsJSON(
                        config.notifications, customSounds: soundLibrary.list()),
                ]
            }
        },

        // Workspace/automation defaults for `crow defaults` (CROW-810) — the
        // `AppConfig.defaults` subtree behind Settings → Workspaces (provider,
        // branch prefix), → Automation (the review/ticket exclude lists) and
        // → General (the corveil binary path).
        //
        // This is the one granular settings verb that can reach
        // `defaults.binaries`, so `defaults-set` IS gated in
        // `RPCWebSocketHandler.localOnlyDenial` — but only when the request
        // carries a `binaries` param. `defaults-get` is un-gated; see the
        // rationale ledger there.
        "defaults-get": { _ in
            // `loadConfigReportingReadability`, not the bare
            // `loadConfig ?? AppConfig()` the telemetry/cleanup/ui gets use:
            // `ConfigStore.loadConfig` returns nil both for "no config yet"
            // (the defaults really do apply) and "present but undecodable" (they
            // are a fiction). Someone debugging why an exclude list isn't
            // working must not be shown an invented empty list as fact.
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return [
                "defaults": DefaultsRPC.defaultsJSON(config.defaults),
                "config_readable": .bool(readable),
            ]
        },
        "defaults-set": { params in
            try await mapRPCError {
                let provider = try DefaultsRPC.patchProvider(params)
                let cli = try DefaultsRPC.patchCLI(params)
                let branchPrefix = try DefaultsRPC.patchBranchPrefix(params)
                let binaries = try DefaultsRPC.patchBinaries(params)
                let excludeReviewRepos =
                    try DefaultsRPC.patchStringList(params, "exclude_review_repos")
                let excludeTicketRepos =
                    try DefaultsRPC.patchStringList(params, "exclude_ticket_repos")
                let ignoreReviewLabels =
                    try DefaultsRPC.patchStringList(params, "ignore_review_labels")

                guard provider != nil || cli != nil || branchPrefix != nil || binaries != nil
                        || excludeReviewRepos != nil || excludeTicketRepos != nil
                        || ignoreReviewLabels != nil else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of provider, cli, branch_prefix, "
                      + "binaries, or an add_/remove_/clear_ param for a list.")
                }

                let (old, new) = try mutateConfig(devRoot: devRoot) {
                    config -> (ConfigDefaults, ConfigDefaults) in
                    let before = config.defaults
                    if let provider { config.defaults.provider = provider }
                    if let cli { config.defaults.cli = cli }
                    if let branchPrefix { config.defaults.branchPrefix = branchPrefix }
                    if let binaries {
                        config.defaults.binaries =
                            DefaultsRPC.mergeBinaries(binaries, into: config.defaults.binaries)
                    }
                    if let patch = excludeReviewRepos {
                        config.defaults.excludeReviewRepos =
                            patch.apply(to: config.defaults.excludeReviewRepos)
                    }
                    if let patch = excludeTicketRepos {
                        config.defaults.excludeTicketRepos =
                            patch.apply(to: config.defaults.excludeTicketRepos)
                    }
                    if let patch = ignoreReviewLabels {
                        config.defaults.ignoreReviewLabels =
                            patch.apply(to: config.defaults.ignoreReviewLabels)
                    }
                    return (before, config.defaults)
                }

                return [
                    "defaults": DefaultsRPC.defaultsJSON(new),
                    "saved": .bool(true),
                    "restart_required": .bool(DefaultsRPC.restartRequired(old: old, new: new)),
                    // Both advisories are always present — like `promotionJSON`'s
                    // `added`/`already_global` — so a scripted caller can test
                    // them without a key-presence dance.
                    "binaries_not_executable": .array(
                        nonExecutableBinaryPaths(binaries ?? [:]).map { .string($0) }),
                    "provider_cli_mismatch": .bool(
                        DefaultsRPC.providerCLIMismatch(provider: new.provider, cli: new.cli)),
                ]
            }
        },

        // Agent selection for `crow agents` (CROW-811) — `AppConfig.defaultAgentKind`
        // and `AppConfig.agentsByKind`, the Settings → General "Agent" group. Same
        // locked read-modify-write as the settings verbs above. No
        // `restart_required`: the board tick calls `applyConfigToAppState` ->
        // `AppState.applyAgentConfig`, so a change is live within one poll.
        //
        // Distinct from `list-agents` further up, which answers "what harnesses are
        // registered in this process" and returns `agents` as an *array*. Its
        // per-agent `default` flag is the *registry* default (first-registered);
        // `default_agent_kind` here is the *configured* default. `available`
        // deliberately carries no such field so the two can't be read as one thing.
        //
        // Un-gated in `RPCWebSocketHandler.localOnlyDenial` for the same reason as
        // `notifications-*`: agent kinds carry no secrets, and a remote peer can
        // already change both fields through the un-gated `set-config` blob.
        "agents-get": { _ in
            let (config, readable) = loadConfigReportingReadability(devRoot: devRoot)
            return ["agents": AgentsRPC.agentsJSON(
                config, available: knownAgents(), configReadable: readable)]
        },
        "agents-set": { params in
            try await mapRPCError {
                // One snapshot for the whole call, so the gate that rejects a kind
                // and the `available` list echoed back can't disagree mid-flight.
                let available = knownAgents()
                let defaultKind = try AgentsRPC.decodeDefaultAgentKind(params, available: available)
                let setting = try AgentsRPC.decodeByKind(params, available: available)
                let clearing = try AgentsRPC.decodeClear(params)
                // Conflict before emptiness: a call carrying both a value and a
                // clear for the same role passes the emptiness check, so the
                // generic message would bury the actual mistake.
                try AgentsRPC.validateNoClearConflict(setting: setting, clearing: clearing)
                guard defaultKind != nil || !setting.isEmpty || !clearing.isEmpty else {
                    throw RPCError.invalidParams(
                        "Nothing to set — provide at least one of default_agent_kind, by_kind, clear.")
                }
                // Every decode above throws before `mutateConfig` is entered, so a
                // rejected kind or role leaves config.json untouched — no lock
                // taken, no partial write, no mtime bump.
                let config = try mutateConfig(devRoot: devRoot) { config -> AppConfig in
                    if let defaultKind { config.defaultAgentKind = defaultKind }
                    AgentsRPC.applyByKind(
                        &config.agentsByKind, setting: setting, clearing: clearing)
                    return config
                }
                return [
                    "agents": AgentsRPC.agentsJSON(config, available: available),
                    "saved": .bool(true),
                ]
            }
        },
    ]
    return handlers
}

/// Paths this call just set that aren't executable right now.
///
/// Advisory only: pointing at a tool you haven't installed yet is a legitimate
/// flow, and `Scaffolder` already skips a non-executable target rather than
/// failing the scaffold. But its only signal today is an `NSLog` in the daemon's
/// stderr, which a CLI user never sees — so a typo'd path would otherwise land
/// as an unqualified `{"saved": true}`.
///
/// Only the paths this call SET are checked: a pre-existing broken entry
/// shouldn't generate noise on an unrelated `--provider` write. Lives here
/// rather than in `DefaultsRPC` because it touches disk, and that enum's
/// contract — like `SettingsRPC`'s — is "no socket, no disk".
private func nonExecutableBinaryPaths(_ patch: [String: String]) -> [String] {
    let fm = FileManager.default
    return patch.values.filter { !$0.isEmpty && !fm.isExecutableFile(atPath: $0) }.sorted()
}

/// Snapshot this process's known agents for the `agents-*` handlers.
///
/// Reuses `AgentRegistry.agentListings()` — the shared projection #879/#880 added
/// so every surface serializes one contract — rather than re-deriving the roster.
/// That means `crow agents list` shows the same five rows the web pickers do,
/// each carrying `available`, instead of silently omitting an off-PATH agent
/// (the exact complaint #879 filed against the web).
///
/// Availability rides along per row rather than filtering the list: the launch
/// gate stays `available == true` (an unavailable kind never enters the
/// registry's launchable map, so `registeredKind`/`agent(for:)` still refuse
/// it), but a caller can now see that Antigravity exists and needs installing.
///
/// No `MainActor.run` hop, unlike `list-agents` in `SessionRPCHandlers`: `AgentRegistry`
/// is `@unchecked Sendable` behind its own `NSLock` and `CodingAgent` is
/// `Sendable`, so nothing here is main-actor bound. Kept a named function rather
/// than inlined twice so a future `@MainActor` on `CodingAgent` has exactly one
/// place to break.
private func knownAgents() -> [AgentsRPC.KnownAgent] {
    AgentRegistry.shared.agentListings().map {
        AgentsRPC.KnownAgent(
            kind: $0.kind, name: $0.displayName, binary: $0.binary, available: $0.available)
    }
}

/// `logsync-get` (CROW-1056; slimmed in CROW-1070): echo the session-log
/// collector's behavior knobs. No secret to reveal any more — the credential and
/// destination are per-workspace on the gateway.
private func logsyncGetHandler(params: [String: JSONValue], devRoot: String) -> [String: JSONValue] {
    let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
    return ["logsync": SettingsRPC.logsyncJSON(config.logSync)]
}

/// `logsync-set` (CROW-1056; slimmed in CROW-1070): PATCH the session-log
/// collector's behavior knobs. Extracted from the handler dictionary so the big
/// literal stays inside the type-checker's budget. No longer local-only — the
/// block carries no credential and no opt-in (both are per-workspace via the
/// gateway), so it is an ordinary config write, like `telemetry-set`.
private func logsyncSetHandler(params: [String: JSONValue], devRoot: String) async throws -> [String: JSONValue] {
    try await mapRPCError {
        let retentionDays = try SettingsRPC.patchBoundedInt(params, "retention_days", min: 0)
        let quietPeriod = try SettingsRPC.patchBoundedInt(params, "quiet_period_minutes", min: 0)
        let maxUploadBytes = try SettingsRPC.patchBoundedInt(params, "max_upload_bytes", min: 1)

        let anySet = retentionDays != nil || quietPeriod != nil || maxUploadBytes != nil
        guard anySet else {
            throw RPCError.invalidParams(
                "Nothing to set — provide at least one of retention_days, "
                + "quiet_period_minutes, max_upload_bytes.")
        }

        let logSync: LogSyncConfig = try mutateConfig(devRoot: devRoot) { config in
            var block = config.logSync ?? LogSyncConfig()
            if let retentionDays { block.retentionDays = retentionDays }
            if let quietPeriod { block.quietPeriodMinutes = quietPeriod }
            if let maxUploadBytes { block.maxUploadBytes = maxUploadBytes }
            config.logSync = block
            return block
        }
        // The collector re-reads config from disk every tick, so this takes
        // effect within ~5 min — no restart.
        return [
            "logsync": SettingsRPC.logsyncJSON(logSync),
            "saved": .bool(true),
        ]
    }
}

/// `terminal-get` (CROW-1085): echo the terminal wheel-scroll knobs. A pure
/// read, mirroring `cleanup-get` / `ui-get`.
private func terminalGetHandler(params: [String: JSONValue], devRoot: String) -> [String: JSONValue] {
    let config = ConfigStore.loadConfig(devRoot: devRoot) ?? AppConfig()
    return ["terminal": SettingsRPC.terminalJSON(config.terminal)]
}

/// `terminal-set` (CROW-1085): PATCH the terminal wheel-scroll knobs — the CLI
/// half of the CROW-835 web Settings sliders (ADR 0016 parity). Extracted from
/// the handler dictionary so the big literal stays inside the type-checker's
/// budget. Both knobs floor at 1, matching the web UI's `Math.max(1, …)` clamp:
/// zero lines-per-notch or zero notches-forwarded would disable wheel scrolling
/// on that surface entirely.
private func terminalSetHandler(params: [String: JSONValue], devRoot: String) async throws -> [String: JSONValue] {
    try await mapRPCError {
        let wheelScrollLines = try SettingsRPC.patchBoundedInt(params, "wheel_scroll_lines", min: 1)
        let agentWheelNotches = try SettingsRPC.patchBoundedInt(params, "agent_wheel_notches", min: 1)

        guard wheelScrollLines != nil || agentWheelNotches != nil else {
            throw RPCError.invalidParams(
                "Nothing to set — provide at least one of wheel_scroll_lines, agent_wheel_notches.")
        }

        let terminal: TerminalSettings = try mutateConfig(devRoot: devRoot) { config in
            if let wheelScrollLines { config.terminal.wheelScrollLines = wheelScrollLines }
            if let agentWheelNotches { config.terminal.agentWheelNotches = agentWheelNotches }
            return config.terminal
        }
        // Connected browsers re-read the terminal config slice off the
        // `configReloaded` push that fires when config.json's mtime moves, so a
        // new wheel speed applies on the next scroll — no restart, no reload.
        return [
            "terminal": SettingsRPC.terminalJSON(terminal),
            "restart_required": .bool(false),
        ]
    }
}
