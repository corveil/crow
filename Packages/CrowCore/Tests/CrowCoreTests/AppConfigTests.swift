import Foundation
import Testing
@testable import CrowCore

@Test func appConfigRoundTrip() throws {
    let config = AppConfig(
        workspaces: [
            WorkspaceInfo(name: "TestOrg", provider: "github", cli: "gh", alwaysInclude: ["repo1"]),
            WorkspaceInfo(name: "GitLabOrg", provider: "gitlab", cli: "glab", host: "gitlab.example.com"),
        ],
        defaults: ConfigDefaults(provider: "gitlab", cli: "glab", branchPrefix: "fix/", excludeDirs: ["vendor"], excludeReviewRepos: ["zarf-dev/zarf", "bmlt-enabled/yap"], excludeTicketRepos: ["org/hidden-repo"]),
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
    #expect(decoded.notifications.globalMute == true)
    #expect(decoded.sidebar.hideSessionDetails == true)
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
    #expect(config.experimentalTmuxBackend == false)
    #expect(config.attributionTrailers == true)
    #expect(config.cleanup.enabled == false)
    #expect(config.cleanup.retentionHours == 24)
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
    #expect(repoMatchesExcludePatterns("org/repo", patterns: ["org/repo"]) == true)
    #expect(repoMatchesExcludePatterns("org/repo", patterns: ["org/other"]) == false)
}

@Test func repoExcludeCaseInsensitive() {
    #expect(repoMatchesExcludePatterns("Org/Repo", patterns: ["org/repo"]) == true)
    #expect(repoMatchesExcludePatterns("org/repo", patterns: ["ORG/REPO"]) == true)
}

@Test func repoExcludeWildcardSuffix() {
    #expect(repoMatchesExcludePatterns("org/repo", patterns: ["org/*"]) == true)
    #expect(repoMatchesExcludePatterns("org/other", patterns: ["org/*"]) == true)
    #expect(repoMatchesExcludePatterns("different/repo", patterns: ["org/*"]) == false)
}

@Test func repoExcludeWildcardPrefix() {
    #expect(repoMatchesExcludePatterns("org/repo", patterns: ["*/repo"]) == true)
    #expect(repoMatchesExcludePatterns("other/repo", patterns: ["*/repo"]) == true)
    #expect(repoMatchesExcludePatterns("org/other", patterns: ["*/repo"]) == false)
}

@Test func repoExcludeWildcardOnly() {
    #expect(repoMatchesExcludePatterns("org/repo", patterns: ["*"]) == true)
}

@Test func repoExcludeMultiplePatterns() {
    let patterns = ["org/specific", "other-org/*"]
    #expect(repoMatchesExcludePatterns("org/specific", patterns: patterns) == true)
    #expect(repoMatchesExcludePatterns("other-org/anything", patterns: patterns) == true)
    #expect(repoMatchesExcludePatterns("org/different", patterns: patterns) == false)
}

@Test func repoExcludeEmptyPatterns() {
    #expect(repoMatchesExcludePatterns("org/repo", patterns: []) == false)
}

@Test func appConfigExperimentalTmuxBackendRoundTrip() throws {
    var config = AppConfig()
    config.experimentalTmuxBackend = true

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
    #expect(decoded.experimentalTmuxBackend == true)

    config.experimentalTmuxBackend = false
    let data2 = try JSONEncoder().encode(config)
    let decoded2 = try JSONDecoder().decode(AppConfig.self, from: data2)
    #expect(decoded2.experimentalTmuxBackend == false)
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
