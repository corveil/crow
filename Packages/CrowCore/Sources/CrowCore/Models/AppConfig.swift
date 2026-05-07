import Foundation

/// Application configuration stored at `{devRoot}/.claude/config.json`.
///
/// All top-level fields are optional on decode — missing keys fall back to defaults.
/// This means existing config files continue to work when new settings are added
/// (forward compatibility).
public struct AppConfig: Codable, Sendable, Equatable {
    public var workspaces: [WorkspaceInfo]
    public var defaults: ConfigDefaults
    public var notifications: NotificationSettings
    public var sidebar: SidebarSettings
    public var remoteControlEnabled: Bool
    public var managerAutoPermissionMode: Bool
    public var telemetry: TelemetryConfig
    public var autoRespond: AutoRespondSettings
    /// Opt into the tmux backend (#198). Surfaced in Settings → Experimental.
    /// Read once at app launch; takes effect on next relaunch.
    public var experimentalTmuxBackend: Bool
    /// When true, `setup.sh` writes a per-worktree `.claude/settings.local.json`
    /// that overrides Claude Code's `attribution.commit` to include the crow
    /// session UUID alongside the standard `Co-Authored-By: Claude` trailer.
    public var attributionTrailers: Bool

    public init(
        workspaces: [WorkspaceInfo] = [],
        defaults: ConfigDefaults = ConfigDefaults(),
        notifications: NotificationSettings = NotificationSettings(),
        sidebar: SidebarSettings = SidebarSettings(),
        remoteControlEnabled: Bool = false,
        managerAutoPermissionMode: Bool = true,
        telemetry: TelemetryConfig = TelemetryConfig(),
        autoRespond: AutoRespondSettings = AutoRespondSettings(),
        experimentalTmuxBackend: Bool = false,
        attributionTrailers: Bool = true
    ) {
        self.workspaces = workspaces
        self.defaults = defaults
        self.notifications = notifications
        self.sidebar = sidebar
        self.remoteControlEnabled = remoteControlEnabled
        self.managerAutoPermissionMode = managerAutoPermissionMode
        self.telemetry = telemetry
        self.autoRespond = autoRespond
        self.experimentalTmuxBackend = experimentalTmuxBackend
        self.attributionTrailers = attributionTrailers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decodeIfPresent([WorkspaceInfo].self, forKey: .workspaces) ?? []
        defaults = try container.decodeIfPresent(ConfigDefaults.self, forKey: .defaults) ?? ConfigDefaults()
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        sidebar = try container.decodeIfPresent(SidebarSettings.self, forKey: .sidebar) ?? SidebarSettings()
        remoteControlEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteControlEnabled) ?? false
        managerAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .managerAutoPermissionMode) ?? true
        telemetry = try container.decodeIfPresent(TelemetryConfig.self, forKey: .telemetry) ?? TelemetryConfig()
        autoRespond = try container.decodeIfPresent(AutoRespondSettings.self, forKey: .autoRespond) ?? AutoRespondSettings()
        experimentalTmuxBackend = try container.decodeIfPresent(Bool.self, forKey: .experimentalTmuxBackend) ?? false
        attributionTrailers = try container.decodeIfPresent(Bool.self, forKey: .attributionTrailers) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces, defaults, notifications, sidebar, remoteControlEnabled, managerAutoPermissionMode, telemetry, autoRespond, experimentalTmuxBackend, attributionTrailers
    }
}

/// Opt-in settings that let Crow type instructions into a session's managed
/// Claude Code terminal when a watched PR transitions into a state that
/// usually requires action. Both flags default off — typing into a terminal
/// unprompted is intrusive, so the user must explicitly enable each.
public struct AutoRespondSettings: Codable, Sendable, Equatable {
    /// Inject a "fix the review feedback" prompt when a PR transitions into
    /// `reviewStatus == .changesRequested`.
    public var respondToChangesRequested: Bool
    /// Inject a "fix the failing checks" prompt when a PR transitions into
    /// `checksPass == .failing` (keyed on the head SHA, so re-runs of the
    /// same commit don't re-fire).
    public var respondToFailedChecks: Bool

    public init(
        respondToChangesRequested: Bool = false,
        respondToFailedChecks: Bool = false
    ) {
        self.respondToChangesRequested = respondToChangesRequested
        self.respondToFailedChecks = respondToFailedChecks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        respondToChangesRequested = try c.decodeIfPresent(Bool.self, forKey: .respondToChangesRequested) ?? false
        respondToFailedChecks = try c.decodeIfPresent(Bool.self, forKey: .respondToFailedChecks) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case respondToChangesRequested, respondToFailedChecks
    }
}

/// A workspace folder configuration.
///
/// Each workspace maps to a directory under the dev root (e.g., `~/Dev/MyOrg`).
/// The `provider` field determines which forge is used (GitHub or GitLab),
/// and `cli` stores the corresponding CLI tool name for backward compatibility.
/// Prefer `derivedCLI` in new code — it's always consistent with `provider`.
public struct WorkspaceInfo: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var provider: String       // "github" or "gitlab"
    public var cli: String            // "gh" or "glab" — kept for config file compat
    public var host: String?          // GitLab host (e.g., "gitlab.example.com")
    public var alwaysInclude: [String] // repos to always list in prompt table
    public var autoReviewRepos: [String] // repos where review requests auto-create a review session

    /// The CLI tool name derived from the current `provider` value.
    /// Unlike `cli` (which may be stale from an old config file), this is always correct.
    public var derivedCLI: String {
        provider == "github" ? "gh" : "glab"
    }

    public init(
        id: UUID = UUID(),
        name: String,
        provider: String = "github",
        cli: String = "gh",
        host: String? = nil,
        alwaysInclude: [String] = [],
        autoReviewRepos: [String] = []
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.cli = cli
        self.host = host
        self.alwaysInclude = alwaysInclude
        self.autoReviewRepos = autoReviewRepos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        provider = try container.decode(String.self, forKey: .provider)
        cli = try container.decode(String.self, forKey: .cli)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        alwaysInclude = try container.decodeIfPresent([String].self, forKey: .alwaysInclude) ?? []
        autoReviewRepos = try container.decodeIfPresent([String].self, forKey: .autoReviewRepos) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, cli, host, alwaysInclude, autoReviewRepos
    }

    /// Characters that are unsafe in directory names (workspace names become directory names).
    private static let unsafeCharacters = CharacterSet(charactersIn: "/:\0")

    /// Validate a workspace name, returning an error message or `nil` if valid.
    ///
    /// - Parameters:
    ///   - name: The trimmed workspace name to validate.
    ///   - existingNames: Names of other workspaces (for duplicate detection).
    /// - Returns: A human-readable error string, or `nil` if the name is valid.
    public static func validateName(_ name: String, existingNames: [String]) -> String? {
        if name.isEmpty {
            return "Name is required"
        }
        if name.unicodeScalars.contains(where: { unsafeCharacters.contains($0) }) {
            return "Name cannot contain /, :, or null characters"
        }
        let lowercased = name.lowercased()
        if existingNames.contains(where: { $0.lowercased() == lowercased }) {
            return "A workspace with this name already exists"
        }
        return nil
    }
}

/// Default settings applied when creating new workspaces or sessions.
public struct ConfigDefaults: Codable, Sendable, Equatable {
    public var provider: String
    public var cli: String
    public var branchPrefix: String
    public var excludeDirs: [String]
    public var excludeReviewRepos: [String]
    public var excludeTicketRepos: [String]
    public var ignoreReviewLabels: [String]

    /// Characters that are invalid in git ref names (see `git check-ref-format`).
    private static let invalidBranchChars = CharacterSet(charactersIn: " ~^:?*[\\")

    /// Check whether a branch prefix is valid for use in git ref names.
    ///
    /// Rejects prefixes containing characters forbidden by `git check-ref-format`,
    /// as well as patterns like consecutive dots or a trailing dot/slash.
    public static func isValidBranchPrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true } // empty is allowed (means no prefix)
        if prefix.unicodeScalars.contains(where: { invalidBranchChars.contains($0) }) {
            return false
        }
        if prefix.contains("..") { return false }
        if prefix.hasSuffix(".") { return false }
        if prefix.contains("@{") { return false }
        return true
    }

    public init(
        provider: String = "github",
        cli: String = "gh",
        branchPrefix: String = "feature/",
        excludeDirs: [String] = ["node_modules", ".git", "vendor", "dist", "build", "target"],
        excludeReviewRepos: [String] = [],
        excludeTicketRepos: [String] = [],
        ignoreReviewLabels: [String] = []
    ) {
        self.provider = provider
        self.cli = cli
        self.branchPrefix = branchPrefix
        self.excludeDirs = excludeDirs
        self.excludeReviewRepos = excludeReviewRepos
        self.excludeTicketRepos = excludeTicketRepos
        self.ignoreReviewLabels = ignoreReviewLabels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? "github"
        cli = try container.decodeIfPresent(String.self, forKey: .cli) ?? "gh"
        branchPrefix = try container.decodeIfPresent(String.self, forKey: .branchPrefix) ?? "feature/"
        excludeDirs = try container.decodeIfPresent([String].self, forKey: .excludeDirs) ?? ["node_modules", ".git", "vendor", "dist", "build", "target"]
        excludeReviewRepos = try container.decodeIfPresent([String].self, forKey: .excludeReviewRepos) ?? []
        excludeTicketRepos = try container.decodeIfPresent([String].self, forKey: .excludeTicketRepos) ?? []
        ignoreReviewLabels = try container.decodeIfPresent([String].self, forKey: .ignoreReviewLabels) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case provider, cli, branchPrefix, excludeDirs, excludeReviewRepos, excludeTicketRepos, ignoreReviewLabels
    }
}

/// Sidebar display preferences.
public struct SidebarSettings: Codable, Sendable, Equatable {
    public var hideSessionDetails: Bool

    public init(hideSessionDetails: Bool = false) {
        self.hideSessionDetails = hideSessionDetails
    }
}

/// Telemetry collection settings for Claude Code OTLP metrics.
public struct TelemetryConfig: Codable, Sendable, Equatable {
    /// Whether the OTLP receiver is enabled.
    public var enabled: Bool
    /// Port for the OTLP HTTP receiver (default: 4318).
    public var port: UInt16
    /// Number of days to retain telemetry data. 0 disables pruning (keep forever).
    public var retentionDays: Int

    public init(enabled: Bool = false, port: UInt16 = 4318, retentionDays: Int = 180) {
        self.enabled = enabled
        self.port = port
        self.retentionDays = retentionDays
    }
}
