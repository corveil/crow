import Foundation
import Testing
@testable import CrowCore

@Test func appConfigRoundTrip() throws {
    let config = AppConfig(
        workspaces: [
            WorkspaceInfo(name: "TestOrg", provider: "github", cli: "gh", alwaysInclude: ["repo1"]),
            WorkspaceInfo(name: "GitLabOrg", provider: "gitlab", cli: "glab", host: "gitlab.example.com"),
        ],
        defaults: ConfigDefaults(provider: "gitlab", cli: "glab", branchPrefix: "fix/", excludeDirs: ["vendor"], excludeReviewRepos: ["zarf-dev/zarf", "bmlt-enabled/yap"], excludeTicketRepos: ["org/hidden-repo"], binaries: ["codex": "/tmp/codex"]),
        notifications: NotificationSettings(globalMute: true),
        sidebar: SidebarSettings(hideSessionDetails: true)
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    #expect(decoded.workspaces.count == 2)
    #expect(decoded.workspaces[0].name == "TestOrg")
    #expect(decoded.workspaces[0].alwaysInclude == ["repo1"])
    #expect(decoded.workspaces[1].host == "gitlab.example.com")
    #expect(decoded.defaults.provider == "gitlab")
    #expect(decoded.defaults.branchPrefix == "fix/")
    #expect(decoded.defaults.excludeDirs == ["vendor"])
    #expect(decoded.defaults.excludeReviewRepos == ["zarf-dev/zarf", "bmlt-enabled/yap"])
    #expect(decoded.defaults.excludeTicketRepos == ["org/hidden-repo"])
    #expect(decoded.defaults.binaries == ["codex": "/tmp/codex"])
    #expect(decoded.notifications.globalMute == true)
    #expect(decoded.sidebar.hideSessionDetails == true)
}

/// `defaults.binaries` decodes from explicit JSON and is keyed by
/// `AgentKind.rawValue` (CROW-484).
@Test func configDefaultsBinariesDecodesFromJSON() throws {
    let json = #"""
        {
            "defaults": {
                "binaries": {
                    "codex":       "/Users/me/.nvm/versions/node/v22/bin/codex",
                    "cursor":      "/Users/me/.bun/bin/agent",
                    "claude-code": "/Users/me/.local/bin/claude"
                }
            }
        }
        """#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.defaults.binaries["codex"] == "/Users/me/.nvm/versions/node/v22/bin/codex")
    #expect(config.defaults.binaries["cursor"] == "/Users/me/.bun/bin/agent")
    #expect(config.defaults.binaries["claude-code"] == "/Users/me/.local/bin/claude")
}

/// Missing `binaries` key decodes to an empty map (forward-compat with
/// existing config files written before CROW-484).
@Test func configDefaultsBinariesDefaultsEmpty() throws {
    let json = #"{ "defaults": { "branchPrefix": "fix/" } }"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.defaults.binaries.isEmpty)
}

@Test func appConfigDecodeFromEmptyJSON() throws {
    let json = "{}".data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.workspaces.isEmpty)
    #expect(config.defaults.provider == "github")
    #expect(config.defaults.branchPrefix == "feature/")
    #expect(config.defaults.excludeReviewRepos.isEmpty)
    #expect(config.defaults.excludeTicketRepos.isEmpty)
    #expect(config.notifications.globalMute == false)
    #expect(config.sidebar.hideSessionDetails == false)
    #expect(config.remoteControlEnabled == false)
    #expect(config.managerAutoPermissionMode == true)
    #expect(config.attributionTrailers == true)
    #expect(config.autoMergeWatcherEnabled == false)
    #expect(config.autoCreateWatcherEnabled == false)
    #expect(config.cleanup.enabled == false)
    #expect(config.cleanup.retentionHours == 24)
}

@Test func appConfigAutoMergeWatcherEnabledRoundTrip() throws {
    var config = AppConfig()
    config.autoMergeWatcherEnabled = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.autoMergeWatcherEnabled == true)

    config.autoMergeWatcherEnabled = false
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.autoMergeWatcherEnabled == false)
}

@Test func appConfigAutoMergeWatcherDefaultsOffWhenKeyMissing() throws {
    // Legacy configs without the key must default to off — the watcher is
    // opt-in so users explicitly enable Crow to act on the crow:merge label.
    let json = #"{"workspaces":[]}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.autoMergeWatcherEnabled == false)
}

@Test func appConfigMigratesLegacyAutoRebaseWatcherEnabled() throws {
    // CROW-551: the top-level `autoRebaseWatcherEnabled` moved into
    // `autoRespond.autoRebaseAndResolveConflicts`. An existing opt-in carries
    // forward across the upgrade.
    let json = #"{"autoRebaseWatcherEnabled": true}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.autoRespond.autoRebaseAndResolveConflicts == true)

    // Re-encoding drops the legacy key, so a later opt-out sticks.
    let reencoded = try JSONEncoder().encode(config)
    let reencodedJSON = String(data: reencoded, encoding: .utf8)!
    #expect(!reencodedJSON.contains("autoRebaseWatcherEnabled"))
}

@Test func appConfigLegacyAutoRebaseWatcherTrueWinsOverExplicitNestedFalse() throws {
    // Edge case documenting the one-time upgrade semantics: when both keys
    // coexist, the legacy top-level opt-in ORs into the nested field even if
    // the nested key is explicitly false. No real pre-CROW-551 config can
    // have written the nested key, and the legacy key is dropped on the next
    // encode — so after one save an explicit nested false can no longer be
    // overridden.
    let json = #"{"autoRebaseWatcherEnabled": true, "autoRespond": {"autoRebaseAndResolveConflicts": false}}"#
        .data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.autoRespond.autoRebaseAndResolveConflicts == true)
}

@Test func appConfigLegacyAutoRebaseWatcherFalseOrMissingStaysOff() throws {
    let missing = try JSONDecoder().decode(AppConfig.self, from: #"{"workspaces":[]}"#.data(using: .utf8)!)
    #expect(missing.autoRespond.autoRebaseAndResolveConflicts == false)

    let explicitOff = try JSONDecoder().decode(AppConfig.self, from: #"{"autoRebaseWatcherEnabled": false}"#.data(using: .utf8)!)
    #expect(explicitOff.autoRespond.autoRebaseAndResolveConflicts == false)
}

@Test func appConfigAutoCreateWatcherEnabledRoundTrip() throws {
    var config = AppConfig()
    config.autoCreateWatcherEnabled = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.autoCreateWatcherEnabled == true)

    config.autoCreateWatcherEnabled = false
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.autoCreateWatcherEnabled == false)
}

@Test func appConfigAutoCreateWatcherDefaultsOffWhenKeyMissing() throws {
    // Legacy configs without the key must default to off — the crow:auto
    // label automation is opt-in (CROW-312).
    let json = #"{"workspaces":[]}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.autoCreateWatcherEnabled == false)
}

@Test func appConfigCleanupRoundTrip() throws {
    var config = AppConfig()
    config.cleanup.enabled = true
    config.cleanup.retentionHours = 72

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.cleanup.enabled == true)
    #expect(decoded.cleanup.retentionHours == 72)
}

@Test func appConfigCleanupDefaultsWhenKeyMissing() throws {
    let json = #"{"workspaces":[]}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.cleanup.enabled == false)
    #expect(config.cleanup.retentionHours == 24)
}

@Test func appConfigTerminalRoundTrip() throws {
    // CROW-835: the two per-surface wheel-scroll knobs survive encode→decode.
    var config = AppConfig()
    config.terminal.wheelScrollLines = 5
    config.terminal.agentWheelNotches = 2

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.terminal.wheelScrollLines == 5)
    #expect(decoded.terminal.agentWheelNotches == 2)
}

@Test func appConfigTerminalDefaultsWhenKeyMissing() throws {
    // Forward-compat: a pre-CROW-835 config (no `terminal` block) decodes to the
    // historical 3 lines/notch on shells and 1 forwarded notch/notch on agents.
    let json = #"{"workspaces":[]}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.terminal.wheelScrollLines == 3)
    #expect(config.terminal.agentWheelNotches == 1)
}

@Test func appConfigTerminalPartialKeyKeepsOtherDefault() throws {
    // Only one knob present → the other stays at its default.
    let json = #"{"terminal": {"agentWheelNotches": 4}}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.terminal.wheelScrollLines == 3)
    #expect(config.terminal.agentWheelNotches == 4)
}

@Test func appConfigRemoteControlRoundTrip() throws {
    var config = AppConfig()
    config.remoteControlEnabled = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.remoteControlEnabled == true)
}

@Test func appConfigManagerAutoPermissionModeRoundTrip() throws {
    var config = AppConfig()
    config.managerAutoPermissionMode = false

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.managerAutoPermissionMode == false)

    config.managerAutoPermissionMode = true
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.managerAutoPermissionMode == true)
}

@Test func appConfigManagerAutoPermissionModeDefaultsTrueWhenKeyMissing() throws {
    // Legacy configs without the key should opt in by default so the Manager
    // benefits from auto mode without requiring users to re-save settings.
    let json = #"{"workspaces": [], "remoteControlEnabled": false}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.managerAutoPermissionMode == true)
}

@Test func appConfigJobsAutoPermissionModeRoundTrip() throws {
    var config = AppConfig()
    config.jobsAutoPermissionMode = false

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.jobsAutoPermissionMode == false)

    config.jobsAutoPermissionMode = true
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.jobsAutoPermissionMode == true)
}

@Test func appConfigJobsAutoPermissionModeDefaultsTrueWhenKeyMissing() throws {
    // Jobs are unattended by definition — legacy configs without the key opt
    // in by default so scheduled runs can execute crow/gh/git without
    // per-call approval, matching the Manager toggle's default.
    let json = #"{"workspaces": [], "remoteControlEnabled": false}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.jobsAutoPermissionMode == true)
}

@Test func appConfigReviewAutoPermissionModeRoundTrip() throws {
    var config = AppConfig()
    config.reviewAutoPermissionMode = false

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.reviewAutoPermissionMode == false)

    config.reviewAutoPermissionMode = true
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.reviewAutoPermissionMode == true)
}

@Test func appConfigReviewAutoPermissionModeDefaultsTrueWhenKeyMissing() throws {
    // Reviews kick off unattended, like jobs — legacy configs without the key
    // opt in by default so the review flow can run crow/gh/git without
    // per-call approval, matching the Manager and Jobs toggles' defaults.
    let json = #"{"workspaces": [], "remoteControlEnabled": false}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.reviewAutoPermissionMode == true)
}

@Test func appConfigCoderViewAutoPermissionModeRoundTrip() throws {
    var config = AppConfig()
    config.coderViewAutoPermissionMode = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.coderViewAutoPermissionMode == true)

    config.coderViewAutoPermissionMode = false
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.coderViewAutoPermissionMode == false)
}

@Test func appConfigCoderViewAutoPermissionModeDefaultsFalseWhenKeyMissing() throws {
    // Unlike the Manager/jobs toggles, coder views default to plan mode —
    // legacy configs without the key must NOT opt in, so existing work
    // sessions keep launching in plan mode unless the user flips the
    // Settings → Automation toggle (#586).
    let json = #"{"workspaces": [], "remoteControlEnabled": false}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.coderViewAutoPermissionMode == false)
}

@Test func appConfigDecodeWithPartialKeys() throws {
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh", "alwaysInclude": []}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.workspaces.count == 1)
    // Other fields should be defaults
    #expect(config.defaults.provider == "github")
    #expect(config.notifications.soundEnabled == true)
    #expect(config.sidebar.hideSessionDetails == false)
}

// MARK: - Partial settings blocks (CROW-814)
//
// `AppConfig.init(from:)`'s `decodeIfPresent` only tolerates a *wholly absent*
// block. Before these structs got per-key defaults, a present-but-partial one
// threw `keyNotFound`, which failed the whole AppConfig decode, which made
// `ConfigStore.loadConfig` return nil — and every config writer's `?? AppConfig()`
// fallback would then overwrite config.json with defaults, losing every
// workspace, job and credential.

@Test func telemetryConfigDecodesPartialObject() throws {
    let json = #"{"telemetry": {"enabled": true}}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.telemetry.enabled == true)
    #expect(config.telemetry.port == 4318)
    #expect(config.telemetry.retentionDays == 180)
}

@Test func cleanupConfigDecodesPartialObject() throws {
    let json = #"{"cleanup": {"enabled": true}}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.cleanup.enabled == true)
    #expect(config.cleanup.retentionHours == 24)
}

@Test func sidebarSettingsDecodesEmptyObject() throws {
    let json = #"{"sidebar": {}}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.sidebar.hideSessionDetails == false)
}

@Test func switcherSettingsDecodeDefaultsWhenAbsent() throws {
    let json = "{}".data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.switcher.enabled == true)
    #expect(config.switcher.binding == "cmd+/")
    #expect(config.switcher.captureInTerminal == true)
    #expect(config.switcher.order == .mru)
    #expect(config.switcher.preview == true)
    #expect(config.switcher.include.reviews == true)
    #expect(config.switcher.include.managers == false)
    #expect(config.switcher.include.completed == false)
}

@Test func switcherSettingsDecodesEmptyObject() throws {
    let json = #"{"switcher": {}}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.switcher.enabled == true)
    #expect(config.switcher.binding == "cmd+/")
    #expect(config.switcher.include.archived == false)
}

/// CROW-1002: a stored binding is normally the user's and survives a default
/// change — which is exactly why CROW-980's new default never reached the
/// installs that were eating Shift+Tab. The reserved chord is the one exception.
@Test func switcherSettingsKeepsStoredBindingOverDefault() throws {
    let json = #"{"switcher": {"binding": "ctrl+space"}}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.switcher.binding == "ctrl+space")
}

/// The CROW-980 default stopped being the default but stays a legal choice —
/// it takes nothing from the terminal, so there is no cause to reset it.
@Test func switcherSettingsKeepsStoredEscTabBinding() throws {
    let json = #"{"switcher": {"binding": "esc+tab"}}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.switcher.binding == "esc+tab")
}

/// CROW-1002: the pre-CROW-980 default swallows the agents' permission-mode
/// cycle in every focused terminal, so it is rewritten rather than honored.
@Test func switcherSettingsMigratesReservedShiftTabBinding() throws {
    let json = #"{"switcher": {"binding": "shift+tab", "captureInTerminal": true}}"#
        .data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)

    #expect(config.switcher.binding == "cmd+/")
    // Only the binding is rewritten — the rest of the user's switcher settings
    // are untouched.
    #expect(config.switcher.captureInTerminal == true)
}

/// The setter stores the string verbatim and the client parses it
/// case-insensitively, so casing and stray whitespace must not smuggle the
/// reserved chord past the migration.
@Test func switcherSettingsMigratesReservedBindingRegardlessOfCasing() throws {
    for stored in ["Shift+Tab", "SHIFT+TAB", " shift+tab "] {
        #expect(SwitcherSettings.isReservedBinding(stored))
        #expect(SwitcherSettings.migratedBinding(stored) == "cmd+/")
    }
    #expect(!SwitcherSettings.isReservedBinding("cmd+/"))
    #expect(!SwitcherSettings.isReservedBinding("esc+tab"))
}

/// A blank binding is "never chose one", not a chord that matches nothing.
@Test func switcherSettingsTreatsBlankBindingAsUnset() throws {
    #expect(SwitcherSettings.migratedBinding(nil) == "cmd+/")
    #expect(SwitcherSettings.migratedBinding("") == "cmd+/")
    #expect(SwitcherSettings.migratedBinding("   ") == "cmd+/")
}

@Test func telemetryCleanupSidebarSurviveFullRoundTrip() throws {
    let config = AppConfig(
        sidebar: SidebarSettings(hideSessionDetails: true),
        telemetry: TelemetryConfig(enabled: true, port: 4319, retentionDays: 30),
        cleanup: CleanupConfig(enabled: true, retentionHours: 72)
    )

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    #expect(decoded.telemetry.enabled == true)
    #expect(decoded.telemetry.port == 4319)
    #expect(decoded.telemetry.retentionDays == 30)
    #expect(decoded.cleanup.enabled == true)
    #expect(decoded.cleanup.retentionHours == 72)
    #expect(decoded.sidebar.hideSessionDetails == true)
}

@Test func appConfigIgnoresUnknownKeys() throws {
    let json = """
    {"futureFeature": true, "workspaces": []}
    """.data(using: .utf8)!
    // Should not throw
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces.isEmpty)
}

@Test func appConfigEquality() {
    let a = AppConfig()
    let b = AppConfig()
    #expect(a == b)

    var c = AppConfig()
    c.defaults.branchPrefix = "fix/"
    #expect(a != c)
}

@Test func configDefaultsDecodeWithoutExcludeReviewRepos() throws {
    let json = """
    {"defaults": {"provider": "github", "cli": "gh", "branchPrefix": "feature/", "excludeDirs": ["node_modules"]}}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.defaults.excludeReviewRepos.isEmpty)
    #expect(config.defaults.excludeTicketRepos.isEmpty)
    #expect(config.defaults.excludeDirs == ["node_modules"])
}

// MARK: - WorkspaceInfo

@Test func workspaceInfoDerivedCLI() {
    let github = WorkspaceInfo(name: "Test", provider: "github", cli: "gh")
    #expect(github.derivedCLI == "gh")

    let gitlab = WorkspaceInfo(name: "Test", provider: "gitlab", cli: "glab")
    #expect(gitlab.derivedCLI == "glab")

    // Even if cli is stale, derivedCLI is correct
    let stale = WorkspaceInfo(name: "Test", provider: "gitlab", cli: "gh")
    #expect(stale.derivedCLI == "glab")
}

@Test func workspaceAutoReviewReposRoundTrip() throws {
    let config = AppConfig(workspaces: [
        WorkspaceInfo(name: "Org", autoReviewRepos: ["org/repo1", "org/repo2"])
    ])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0].autoReviewRepos == ["org/repo1", "org/repo2"])
}

@Test func workspaceAutoReviewReposDefaultsEmptyWhenKeyMissing() throws {
    // Legacy configs without the key should default to empty (feature off).
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh"}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces[0].autoReviewRepos.isEmpty)
    #expect(config.workspaces[0].alwaysInclude.isEmpty)
}

@Test func workspaceExcludeReviewReposRoundTrip() throws {
    let config = AppConfig(workspaces: [
        WorkspaceInfo(name: "Org", excludeReviewRepos: ["org/repo1", "org/*"])
    ])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0].excludeReviewRepos == ["org/repo1", "org/*"])
}

@Test func workspaceExcludeReviewReposDefaultsEmptyWhenKeyMissing() throws {
    // Legacy configs without the key should default to empty (feature off).
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh"}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces[0].excludeReviewRepos.isEmpty)
}

@Test func effectiveExcludeReviewReposUnionsGlobalAndWorkspaces() {
    // Effective set is the global default unioned with every workspace's list.
    var config = AppConfig(workspaces: [
        WorkspaceInfo(name: "Org1", excludeReviewRepos: ["ws1/repo"]),
        WorkspaceInfo(name: "Org2"), // empty — contributes nothing
        WorkspaceInfo(name: "Org3", excludeReviewRepos: ["ws3/*"])
    ])
    config.defaults.excludeReviewRepos = ["global/*"]

    let effective = config.effectiveExcludeReviewRepos
    #expect(effective.contains("global/*"))
    #expect(effective.contains("ws1/repo"))
    #expect(effective.contains("ws3/*"))

    // A repo excluded by any workspace (or the global default) is matched.
    #expect(repoMatchesPatterns("ws1/repo", patterns: effective) == true)
    #expect(repoMatchesPatterns("global/anything", patterns: effective) == true)
    #expect(repoMatchesPatterns("ws3/something", patterns: effective) == true)
    // A repo excluded by no one is not matched.
    #expect(repoMatchesPatterns("other/repo", patterns: effective) == false)
}

@Test func effectiveExcludeReviewReposEmptyWhenNothingConfigured() {
    // No global and no per-workspace exclusions → empty effective set, no filtering.
    let config = AppConfig(workspaces: [WorkspaceInfo(name: "Org")])
    #expect(config.effectiveExcludeReviewRepos.isEmpty)
}

@Test func workspaceCustomInstructionsRoundTrip() throws {
    let config = AppConfig(workspaces: [
        WorkspaceInfo(name: "Org", customInstructions: "Always run npm test before committing")
    ])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0].customInstructions == "Always run npm test before committing")
}

@Test func workspaceCustomInstructionsDefaultsNilWhenKeyMissing() throws {
    // Legacy configs without the key should default to nil.
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh"}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces[0].customInstructions == nil)
}

@Test func workspaceJiraStatusMapRoundTrip() throws {
    let config = AppConfig(workspaces: [
        WorkspaceInfo(name: "Org", taskProvider: "jira",
                      jiraStatusMap: ["In Progress": "In Development", "Ready": "To Do"])
    ])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0].jiraStatusMap?["In Progress"] == "In Development")
    #expect(decoded.workspaces[0].jiraStatusMap?["Ready"] == "To Do")
}

@Test func workspaceJiraStatusMapDefaultsNilWhenKeyMissing() throws {
    // Legacy/non-Jira configs without the key default to nil (use built-in defaults).
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh"}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces[0].jiraStatusMap == nil)
}

// MARK: - sessionEnv (CROW-809)
//
// `WorkspaceInfo.encode(to:)` is synthesized from `CodingKeys`, so a key absent
// from that list is not merely ignored on read — it is *deleted* on the next
// write. `sessionEnv` was in exactly that state: `skills/crow-workspace/setup.sh`
// reads `.workspaces[].sessionEnv` with jq and the skill documents it, but the
// model had no such field, so every Settings save silently dropped it and the
// jq read then returned empty with no error. These pin the round-trip.

@Test func workspaceSessionEnvSurvivesEncodeDecode() throws {
    let config = AppConfig(workspaces: [
        WorkspaceInfo(name: "Org", sessionEnv: ["AWS_PROFILE": "dev", "NODE_ENV": "development"])
    ])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0].sessionEnv == ["AWS_PROFILE": "dev", "NODE_ENV": "development"])
}

/// The regression proper: a hand-authored `sessionEnv` read off disk must still
/// be there after the re-encode that every config write performs.
@Test func workspaceSessionEnvSurvivesAConfigRewrite() throws {
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org",
      "provider": "github", "cli": "gh", "sessionEnv": {"AWS_PROFILE": "dev"}}]}
    """.data(using: .utf8)!
    let loaded = try JSONDecoder().decode(AppConfig.self, from: json)
    let rewritten = try JSONDecoder().decode(
        AppConfig.self, from: try JSONEncoder().encode(loaded))
    #expect(rewritten.workspaces[0].sessionEnv == ["AWS_PROFILE": "dev"])
}

@Test func workspaceSessionEnvDefaultsNilWhenKeyMissing() throws {
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh"}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces[0].sessionEnv == nil)
}

/// Every field `crow workspace` can write must survive a round-trip together —
/// a field added to the struct but forgotten in `CodingKeys` would pass its own
/// in-memory test and still be dropped on save.
@Test func workspaceFullRoundTripKeepsEveryField() throws {
    let workspace = WorkspaceInfo(
        name: "Org", provider: "gitlab", cli: "glab", host: "gitlab.acme.io",
        alwaysInclude: ["acme/api"], autoReviewRepos: ["acme/web"],
        excludeReviewRepos: ["acme/legacy"], customInstructions: "Run make test.",
        reviewBlockingSeverities: [.red],
        taskProvider: "jira", jiraProjectKey: "PROPS", jiraJQL: "assignee = currentUser()",
        jiraSite: "acme.atlassian.net", jiraStatusMap: ["In Progress": "In Dev"],
        corveilHost: "corveil.acme.io", sessionEnv: ["AWS_PROFILE": "dev"],
        gateway: WorkspaceGateway(baseURL: "https://gw.acme.io", customHeaders: ["X-Key": "sk-1"]))
    let data = try JSONEncoder().encode(AppConfig(workspaces: [workspace]))
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0] == workspace)
}

// MARK: - Review blocking severities (CROW-963)

@Test func workspaceReviewBlockingSeveritiesRoundTrip() throws {
    let config = AppConfig(workspaces: [
        WorkspaceInfo(name: "Org", reviewBlockingSeverities: [.red])
    ])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0].reviewBlockingSeverities == [.red])
    #expect(decoded.workspaces[0].effectiveReviewBlockingSeverities == [.red])
}

@Test func workspaceReviewBlockingSeveritiesDefaultsNilWhenKeyMissing() throws {
    // The whole safety property of CROW-963: a config written before the setting
    // existed must resolve to today's behaviour (red + yellow), NOT to an empty
    // blocking set, which would approve every review.
    let json = """
    {"workspaces": [{"id": "11111111-2222-3333-4444-555555555555", "name": "Org", "provider": "github", "cli": "gh"}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces[0].reviewBlockingSeverities == nil)
    #expect(config.workspaces[0].effectiveReviewBlockingSeverities == [.red, .yellow])
}

@Test func workspaceReviewBlockingSeveritiesUnsetKeyIsOmittedOnSave() throws {
    // `--clear-review-blocking-severities` stores nil, and nil must encode as an
    // ABSENT key rather than `null`: a null would have to decode back to
    // something, and "explicitly nothing" is exactly the state that means approve
    // every review. Same reason `crow agents set --clear` removes its key.
    let data = try JSONEncoder().encode(AppConfig(workspaces: [WorkspaceInfo(name: "Org")]))
    let text = String(data: data, encoding: .utf8) ?? ""
    #expect(!text.contains("reviewBlockingSeverities"))
}

@Test func workspaceReviewBlockingSeveritiesDecodeIsLenient() throws {
    // A hand-edited config must still LOAD. A throwing decode here would make
    // ConfigStore.loadConfig return nil, at which point every writer's
    // `?? AppConfig()` fallback rewrites config.json with defaults and takes
    // every workspace, job and gateway with it. Unknown values are dropped and an
    // empty result falls back to the default; rejecting bad input is the write
    // path's job, not the decoder's.
    func decodeSeverities(_ literal: String) throws -> WorkspaceInfo {
        let json = """
        {"workspaces": [{"id": "11111111-2222-3333-4444-555555555555", "name": "Org",
          "provider": "github", "cli": "gh", "reviewBlockingSeverities": \(literal)}]}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(AppConfig.self, from: json).workspaces[0]
    }

    // Unknown severity dropped, known one kept.
    #expect(try decodeSeverities(#"["red", "chartreuse"]"#).reviewBlockingSeverities == [.red])
    // Case and padding tolerated — the web and CLI both normalize, but a
    // hand-edited file might not.
    #expect(try decodeSeverities(#"[" RED ", "Yellow"]"#).reviewBlockingSeverities == [.red, .yellow])
    // Order canonicalized so `[yellow, red]` compares equal to the default.
    #expect(try decodeSeverities(#"["yellow", "red"]"#).reviewBlockingSeverities == [.red, .yellow])
    // An empty list, or one that becomes empty, means "unset" — never "nothing
    // blocks".
    #expect(try decodeSeverities("[]").reviewBlockingSeverities == nil)
    #expect(try decodeSeverities("[]").effectiveReviewBlockingSeverities == [.red, .yellow])
    #expect(try decodeSeverities(#"["mauve"]"#).reviewBlockingSeverities == nil)
    #expect(try decodeSeverities(#"["mauve"]"#).effectiveReviewBlockingSeverities == [.red, .yellow])
}

// MARK: - Provider domains (CROW-809)

/// The CLI's `--provider` / `--task-provider` rejection messages and the
/// `workspace-*` handler's validation both read these, so they are the one
/// source for what a workspace may be set to.
@Test func workspaceProviderDomainsComeFromTheProviderEnum() {
    // Task-only providers have no git surface, so they're never a code provider.
    #expect(WorkspaceInfo.validProviders == ["github", "gitlab"])
    #expect(Set(WorkspaceInfo.validTaskProviders) == Set(Provider.allCases.map(\.rawValue)))
    for provider in WorkspaceInfo.validProviders {
        #expect(Provider(rawValue: provider)?.isTaskOnly == false)
    }
}

@Test func workspaceNameValidation() {
    // Valid name
    #expect(WorkspaceInfo.validateName("MyOrg", existingNames: []) == nil)

    // Empty name
    #expect(WorkspaceInfo.validateName("", existingNames: []) != nil)

    // Duplicate name (case-insensitive)
    #expect(WorkspaceInfo.validateName("MyOrg", existingNames: ["myorg"]) != nil)
    #expect(WorkspaceInfo.validateName("MYORG", existingNames: ["MyOrg"]) != nil)

    // Filesystem-unsafe characters
    #expect(WorkspaceInfo.validateName("My/Org", existingNames: []) != nil)
    #expect(WorkspaceInfo.validateName("My:Org", existingNames: []) != nil)

    // Path-traversal names (would escape devRoot)
    #expect(WorkspaceInfo.validateName(".", existingNames: []) != nil)
    #expect(WorkspaceInfo.validateName("..", existingNames: []) != nil)
    // A name merely containing a dot is still fine.
    #expect(WorkspaceInfo.validateName("my.org", existingNames: []) == nil)

    // Valid with existing names that don't conflict
    #expect(WorkspaceInfo.validateName("NewOrg", existingNames: ["OtherOrg"]) == nil)
}

// MARK: - ConfigDefaults

@Test func branchPrefixValidation() {
    // Valid prefixes
    #expect(ConfigDefaults.isValidBranchPrefix("feature/") == true)
    #expect(ConfigDefaults.isValidBranchPrefix("fix/") == true)
    #expect(ConfigDefaults.isValidBranchPrefix("") == true) // empty allowed

    // Invalid prefixes
    #expect(ConfigDefaults.isValidBranchPrefix("feature branch/") == false)  // space
    #expect(ConfigDefaults.isValidBranchPrefix("feature~/") == false)        // tilde
    #expect(ConfigDefaults.isValidBranchPrefix("feature^/") == false)        // caret
    #expect(ConfigDefaults.isValidBranchPrefix("feature:/") == false)        // colon
    #expect(ConfigDefaults.isValidBranchPrefix("feature?/") == false)        // question mark
    #expect(ConfigDefaults.isValidBranchPrefix("feature*/") == false)        // asterisk
    #expect(ConfigDefaults.isValidBranchPrefix("feature[/") == false)        // bracket
    #expect(ConfigDefaults.isValidBranchPrefix("feat..ure/") == false)       // consecutive dots
    #expect(ConfigDefaults.isValidBranchPrefix("feature.") == false)         // trailing dot
    #expect(ConfigDefaults.isValidBranchPrefix("feature@{/") == false)       // @{
}

// MARK: - Repo Exclude Pattern Matching

@Test func repoExcludeExactMatch() {
    #expect(repoMatchesPatterns("org/repo", patterns: ["org/repo"]) == true)
    #expect(repoMatchesPatterns("org/repo", patterns: ["org/other"]) == false)
}

@Test func repoExcludeCaseInsensitive() {
    #expect(repoMatchesPatterns("Org/Repo", patterns: ["org/repo"]) == true)
    #expect(repoMatchesPatterns("org/repo", patterns: ["ORG/REPO"]) == true)
}

@Test func repoExcludeWildcardSuffix() {
    #expect(repoMatchesPatterns("org/repo", patterns: ["org/*"]) == true)
    #expect(repoMatchesPatterns("org/other", patterns: ["org/*"]) == true)
    #expect(repoMatchesPatterns("different/repo", patterns: ["org/*"]) == false)
}

@Test func repoExcludeWildcardPrefix() {
    #expect(repoMatchesPatterns("org/repo", patterns: ["*/repo"]) == true)
    #expect(repoMatchesPatterns("other/repo", patterns: ["*/repo"]) == true)
    #expect(repoMatchesPatterns("org/other", patterns: ["*/repo"]) == false)
}

@Test func repoExcludeWildcardOnly() {
    #expect(repoMatchesPatterns("org/repo", patterns: ["*"]) == true)
}

@Test func repoExcludeMultiplePatterns() {
    let patterns = ["org/specific", "other-org/*"]
    #expect(repoMatchesPatterns("org/specific", patterns: patterns) == true)
    #expect(repoMatchesPatterns("other-org/anything", patterns: patterns) == true)
    #expect(repoMatchesPatterns("org/different", patterns: patterns) == false)
}

@Test func repoExcludeEmptyPatterns() {
    #expect(repoMatchesPatterns("org/repo", patterns: []) == false)
}

@Test func repoMiddleWildcard() {
    #expect(repoMatchesPatterns("org/prefix-foo", patterns: ["org/prefix-*"]) == true)
    #expect(repoMatchesPatterns("org/prefix-bar-baz", patterns: ["org/prefix-*"]) == true)
    #expect(repoMatchesPatterns("org/other", patterns: ["org/prefix-*"]) == false)
}

@Test func repoSuffixWildcard() {
    #expect(repoMatchesPatterns("org/foo-suffix", patterns: ["*-suffix"]) == true)
    #expect(repoMatchesPatterns("org/bar-suffix", patterns: ["*-suffix"]) == true)
    #expect(repoMatchesPatterns("org/suffix-bar", patterns: ["*-suffix"]) == false)
}

@Test func appConfigDecodesLegacyExperimentalTmuxBackendKey() throws {
    // Old configs predating #301 carry `experimentalTmuxBackend`. The key
    // no longer exists on `AppConfig`, but decode must still succeed —
    // unknown keys are silently ignored, and the rest of the config loads.
    let json = #"{"workspaces":[],"experimentalTmuxBackend":true}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces.isEmpty)
    // Re-encoding drops the legacy key — that's the expected migration.
    let reencoded = try JSONEncoder().encode(config)
    let reencodedString = String(data: reencoded, encoding: .utf8) ?? ""
    #expect(!reencodedString.contains("experimentalTmuxBackend"))
}

@Test func appConfigAttributionTrailersRoundTrip() throws {
    var config = AppConfig()
    config.attributionTrailers = false

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.attributionTrailers == false)

    config.attributionTrailers = true
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.attributionTrailers == true)
}

@Test func appConfigAttributionTrailersDefaultsTrueWhenKeyMissing() throws {
    // Legacy configs without the key opt in by default — matches the behavior
    // users see when they install the feature without touching settings.
    let json = #"{"workspaces": [], "remoteControlEnabled": false}"#.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.attributionTrailers == true)
}

@Test func ignoreReviewLabelsRoundTrip() throws {
    let config = AppConfig(
        defaults: ConfigDefaults(ignoreReviewLabels: ["dependencies", "renovate", "automated"])
    )
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.defaults.ignoreReviewLabels == ["dependencies", "renovate", "automated"])
}

@Test func ignoreReviewLabelsDefaultsEmptyWhenKeyMissing() throws {
    let json = """
    {"defaults": {"provider": "github", "cli": "gh", "branchPrefix": "feature/", "excludeDirs": []}}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.defaults.ignoreReviewLabels.isEmpty)
}

// MARK: - defaults.binaries (CROW-482)

@Test func binariesRoundTrip() throws {
    let config = AppConfig(
        defaults: ConfigDefaults(binaries: [
            "corveil": "/Users/jane/dev/corveil/corveil",
            "soulstone": "/usr/local/bin/soulstone",
        ])
    )
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.defaults.binaries["corveil"] == "/Users/jane/dev/corveil/corveil")
    #expect(decoded.defaults.binaries["soulstone"] == "/usr/local/bin/soulstone")
}

@Test func binariesDefaultsEmptyWhenKeyMissing() throws {
    // Configs written before CROW-482 don't have `binaries` — they must still
    // decode cleanly with an empty map (forward compatibility).
    let json = """
    {"defaults": {"provider": "github", "cli": "gh", "branchPrefix": "feature/", "excludeDirs": []}}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.defaults.binaries.isEmpty)
}

// MARK: - AI gateway (CROW-402)

@Test func workspaceGatewayRoundTrip() throws {
    let config = AppConfig(workspaces: [
        WorkspaceInfo(
            name: "Corveil",
            gateway: WorkspaceGateway(
                baseURL: "https://corveil.io",
                customHeaders: ["x-citadel-api-key": "op://Spotlight Prod/Citadel/api_key"]
            )
        )
    ])
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.workspaces[0].gateway?.baseURL == "https://corveil.io")
    #expect(decoded.workspaces[0].gateway?.customHeaders["x-citadel-api-key"] == "op://Spotlight Prod/Citadel/api_key")
}

@Test func workspaceGatewayDefaultsNilWhenKeyMissing() throws {
    // Legacy configs without the key decode with a nil gateway.
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh"}]}
    """.data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.workspaces[0].gateway == nil)
}

@Test func managerGatewayRoundTrip() throws {
    var config = AppConfig()
    config.managerGateway = WorkspaceGateway(
        baseURL: "https://corveil.io",
        customHeaders: ["x-citadel-api-key": "Bearer sk-citadel-123"]
    )
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.managerGateway?.baseURL == "https://corveil.io")
    #expect(decoded.managerGateway?.customHeaders["x-citadel-api-key"] == "Bearer sk-citadel-123")
}

@Test func managerGatewayDefaultsNilWhenKeyMissing() throws {
    let json = "{}".data(using: .utf8)!
    let config = try JSONDecoder().decode(AppConfig.self, from: json)
    #expect(config.managerGateway == nil)
}

@Test func gatewayBothEmptyDecodesAsNoGateway() throws {
    // Both fields blank/empty is allowed — it just means "no gateway".
    let json = #"{"baseURL": "", "customHeaders": {}}"#.data(using: .utf8)!
    let gateway = try JSONDecoder().decode(WorkspaceGateway.self, from: json)
    #expect(gateway.isEmpty)
}

@Test func gatewayBaseURLWithoutHeadersThrows() throws {
    // A baseURL with no headers can't authenticate — reject at parse time.
    let json = #"{"baseURL": "https://corveil.io", "customHeaders": {}}"#.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WorkspaceGateway.self, from: json)
    }
}

@Test func gatewayHeadersWithoutBaseURLThrows() throws {
    // Headers with no baseURL have nothing to attach to — reject at parse time.
    let json = #"{"baseURL": "", "customHeaders": {"x-key": "secret"}}"#.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(WorkspaceGateway.self, from: json)
    }
}

@Test func malformedWorkspaceGatewayFailsConfigDecode() throws {
    // A malformed gateway inside a workspace propagates as a decode failure
    // (ConfigStore.loadConfig logs it and returns nil rather than silently
    // dropping just the bad field).
    let json = """
    {"workspaces": [{"id": "00000000-0000-0000-0000-000000000001", "name": "Org", "provider": "github", "cli": "gh", "gateway": {"baseURL": "https://corveil.io", "customHeaders": {}}}]}
    """.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(AppConfig.self, from: json)
    }
}

@Test func gatewayHeaderLinesRoundTrip() throws {
    let headers = ["x-b": "two", "x-a": "Bearer one"]
    let text = WorkspaceGateway.headerLines(from: headers)
    #expect(text == "x-a: Bearer one\nx-b: two")  // sorted
    #expect(WorkspaceGateway.parseHeaderLines(text) == headers)
}

@Test func gatewayParseHeaderLinesIgnoresBlankAndMalformedLines() throws {
    let text = """
    x-key: Bearer sk-1

      x-op : op://Vault/Item/field
    not-a-header-line
    : missing-name
    """
    let parsed = WorkspaceGateway.parseHeaderLines(text)
    #expect(parsed["x-key"] == "Bearer sk-1")
    #expect(parsed["x-op"] == "op://Vault/Item/field")
    #expect(parsed["not-a-header-line"] == nil)   // no colon → ignored
    #expect(parsed.count == 2)                    // ": missing-name" has empty name → ignored
}

// MARK: - Gateway header quoting rules (CROW-969)
//
// A value stored with literal surrounding quotes reaches the gateway with them
// intact and is rejected, surfacing as a bare "API error". These predicates are
// the single rule that `validateHeaderLine` (CLI) and `SecretRoutes.buildGateway`
// (RPC + web) both delegate to.

@Test func gatewayIsQuoteWrappedCatchesShellQuotingSlip() throws {
    #expect(WorkspaceGateway.isQuoteWrapped("\"Bearer sk-1\""))
    #expect(WorkspaceGateway.isQuoteWrapped("'Bearer sk-1'"))
    // Worst case: the quotes defeat `hasPrefix("op://")` in GatewayResolver, so
    // the reference is never resolved and is sent literally instead.
    #expect(WorkspaceGateway.isQuoteWrapped("\"op://Vault/Item/field\""))
}

@Test func gatewayIsQuoteWrappedRejectsEmptyQuotedString() throws {
    // Two quote characters, matching — a shell-quoted *empty* value. This would
    // store a literal 2-character credential, which is not the same thing as the
    // genuinely blank "keep the stored secret" signal below.
    #expect(WorkspaceGateway.isQuoteWrapped("\"\""))
    #expect(WorkspaceGateway.isQuoteWrapped("''"))
}

@Test func gatewayIsQuoteWrappedPassesEverythingElse() throws {
    let fine = [
        "",                          // blank = "keep the stored secret"
        "   ",                       // trims to blank, same signal
        "\"",                        // lone quote: must not match itself
        "'",
        "{\"a\":1}",                 // JSON — first `{`, last `}`
        "Bearer sk-\"abc\"-def",     // interior quotes only
        "\"abc'",                    // mismatched delimiters: not a recognizable slip
        "'abc\"",
        "abc\"",                     // one-sided
        "\"abc",
        "op://Vault/Item/field",
        "Bearer sk-plain",
    ]
    for value in fine {
        #expect(!WorkspaceGateway.isQuoteWrapped(value), "expected '\(value)' to be accepted")
    }
}

@Test func gatewayIsQuoteWrappedTrimsBeforeChecking() throws {
    // Reachable via a hand-crafted POST to /config/workspace-gateway, which
    // trims header *keys* but never values.
    #expect(WorkspaceGateway.isQuoteWrapped("  \"Bearer sk-1\"  "))
}

@Test func gatewayHeaderNameRejectsDoubleQuoteAnywhere() throws {
    // RFC 9110 field-name is a `token`, and `tchar` excludes `"` entirely — so a
    // name carrying one can never be a valid header, wherever the quote sits.
    // The leading case is the whole-line-quoted slip: `--header '"X-Api-Key: sk"'`
    // splits on the first colon, leaving neither half individually wrapped.
    #expect(WorkspaceGateway.headerNameHasStrayQuote("\"X-Api-Key"))
    #expect(WorkspaceGateway.headerNameHasStrayQuote("X-\"Api\"-Key"))
    #expect(WorkspaceGateway.headerNameHasStrayQuote("X-Api-Key\""))
}

@Test func gatewayHeaderNameRejectsOnlyLeadingSingleQuote() throws {
    #expect(WorkspaceGateway.headerNameHasStrayQuote("'X-Api-Key"))
    // Asymmetric on purpose: `'` IS a legal `tchar`, so it is rejected only where
    // no real header name has ever put one. A trailing apostrophe is legal and
    // not a recognizable quoting artifact, so it passes.
    #expect(!WorkspaceGateway.headerNameHasStrayQuote("X-Api-Key'"))
    #expect(!WorkspaceGateway.headerNameHasStrayQuote("X-Api-Key"))
    #expect(!WorkspaceGateway.headerNameHasStrayQuote(""))
}

// MARK: - Agent selection (CROW-811)
//
// `defaultAgentKind` + `agentsByKind` back `crow agents list|set` and the web
// Settings → General Agent pickers. The map is keyed by `SessionKind.rawValue`
// rather than `SessionKind` so JSON serializes it as an object literal — Swift's
// `JSONEncoder` only treats `String`/`Int`-keyed dictionaries as JSON objects.

@Test func agentSelectionSurvivesFullRoundTrip() throws {
    var config = AppConfig()
    config.defaultAgentKind = .cursor
    config.agentsByKind = ["review": .codex, "manager": .claudeCode]

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    #expect(decoded.defaultAgentKind == .cursor)
    #expect(decoded.agentsByKind == ["review": .codex, "manager": .claudeCode])

    // …and on the wire it really is an object, not the alternating
    // [key, value, key, value] array a non-String-keyed dictionary would produce.
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let byKind = try #require(object["agentsByKind"] as? [String: Any])
    #expect(byKind["review"] as? String == "codex")
}

/// Why `crow agents set --clear <role>` **removes** the key instead of writing a
/// null: `AgentKind` decodes from a single-value String container and
/// `AppConfig.init(from:)` decodes `agentsByKind` with `try`, not `try?`. So a
/// single null value fails the *whole* AppConfig decode — `ConfigStore.loadConfig`
/// then returns nil, every workspace, job and credential goes invisible, and each
/// writer's `?? AppConfig()` fallback stands ready to overwrite the file with
/// defaults. The web deletes the key for the same reason.
@Test func agentsByKindWithANullValueMakesTheWholeConfigUndecodable() throws {
    let json = #"{"workspaces": [], "agentsByKind": {"work": null}}"#.data(using: .utf8)!
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(AppConfig.self, from: json)
    }

    // The same document without the null decodes fine — it really is the null,
    // not the surrounding shape.
    let ok = #"{"workspaces": [], "agentsByKind": {"work": "codex"}}"#.data(using: .utf8)!
    #expect(try JSONDecoder().decode(AppConfig.self, from: ok).agentsByKind == ["work": .codex])
}

@Test func removingAnAgentOverrideFallsBackToTheDefault() {
    var config = AppConfig()
    config.defaultAgentKind = .claudeCode
    config.agentsByKind = ["work": .codex]
    #expect(config.agentKind(for: .work) == .codex)

    config.agentsByKind.removeValue(forKey: "work")
    #expect(config.agentKind(for: .work) == .claudeCode)
}

@Test func agentKindResolutionPrefersTheOverrideForEveryRole() {
    for role in SessionKind.allCases {
        var config = AppConfig()
        config.defaultAgentKind = .claudeCode
        config.agentsByKind = [role.rawValue: .codex]
        #expect(config.agentKind(for: role) == .codex)
        for other in SessionKind.allCases where other != role {
            #expect(config.agentKind(for: other) == .claudeCode)
        }
    }
}

/// A 5th session kind must not be addable without the agents surface noticing —
/// `allCases` drives the per-role map `crow agents list` reports and the roles
/// `crow agents set --clear` accepts.
@Test func sessionKindAllCasesCoversEveryRole() {
    #expect(SessionKind.allCases == [.work, .review, .job, .manager])
}
