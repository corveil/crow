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
            name: "RadiusMethod",
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
