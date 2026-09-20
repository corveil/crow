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
    /// Esc+Tab (or configured binding) session switcher overlay (CROW-976).
    public var switcher: SwitcherSettings
    public var remoteControlEnabled: Bool
    public var managerAutoPermissionMode: Bool
    /// When true, sessions launched by the Jobs scheduler start with
    /// `--permission-mode auto` so their prompts can run `crow`, `gh`, and
    /// `git` without per-call approval. Defaults to true — jobs are
    /// unattended by definition. Claude Code ≥ 2.1.257 can still stall once
    /// on the first extra-workdir Read (CROW-1176); Crow does not bypass that.
    /// `--permission-prompts none` is print-mode only and is not emitted (CROW-1215).
    public var jobsAutoPermissionMode: Bool
    /// When true, code-review sessions start with `--permission-mode auto` so
    /// the review prompt can run `crow`, `gh`, and `git` without per-call
    /// approval. Defaults to true — reviews kick off unattended, like jobs.
    /// Same extra-workdir Read residual as jobs (CROW-1176); review clones
    /// under `{devRoot}/crow-reviews/` are the likely first hit.
    /// `--permission-prompts none` is print-mode only and is not emitted (CROW-1215).
    public var reviewAutoPermissionMode: Bool
    /// When true, newly launched work coder views start with
    /// `--permission-mode auto` (auto-accept) instead of the default plan
    /// mode. Applies to `.work` sessions only — Manager and jobs have their
    /// own toggles. Defaults to false so existing behavior is preserved
    /// unless the user opts in (#586).
    public var coderViewAutoPermissionMode: Bool
    public var telemetry: TelemetryConfig
    /// Terminal wheel-scroll tuning (CROW-835). Separate knobs for the two
    /// per-surface scroll paths (ADR-0013): local scrollback lines-per-notch on
    /// plain shells, and forwarded notches-per-notch on agent surfaces.
    public var terminal: TerminalSettings
    public var autoRespond: AutoRespondSettings
    /// When true, `setup.sh` writes a per-worktree `.claude/settings.local.json`
    /// that overrides Claude Code's `attribution.commit` to include the crow
    /// session UUID alongside the standard `Co-Authored-By: Claude` trailer.
    public var attributionTrailers: Bool
    /// When true, the IssueTracker watches for PRs labeled `crow:merge`
    /// and enables GitHub native auto-merge (squash) — but only on PRs
    /// authored by Crow (Crow-Session trailer matching a known session).
    /// Opt-in: defaults to false (CROW-299).
    public var autoMergeWatcherEnabled: Bool
    /// When true, the IssueTracker dispatches `/crow-workspace` to the
    /// Manager terminal for assigned open issues labeled `crow:auto`, or
    /// `/crow-workspace --explore` for `crow:explore` (CROW-1149). Opt-in:
    /// defaults to false (CROW-312). Trigger labels are stripped after a
    /// successful dispatch so the claim remains one-shot per issue. While
    /// disabled, labels are left alone so a later opt-in can still pick
    /// up previously-labeled issues. `crow:auto` wins when both are present.
    public var autoCreateWatcherEnabled: Bool
    public var cleanup: CleanupConfig
    /// Periodic check against `corveil/crow` `main` to surface when this build
    /// is behind upstream (CROW-938). Off-able; interval floored at 1h.
    public var versionUpdate: VersionUpdateConfig
    /// Scheduled jobs: named sets of prompts that fire automatically on a
    /// schedule, scoped to a repo. Driven by `JobScheduler` (CROW-317).
    public var jobs: [JobConfig]
    /// The agent used for newly created sessions when none is specified.
    /// Existing persisted configs without this key decode to `.claudeCode`.
    public var defaultAgentKind: AgentKind
    /// Per-action-type overrides. When a key is present, sessions of that
    /// kind are created with the mapped agent; when absent, they fall back
    /// to `defaultAgentKind`. Honored for every `SessionKind`, including
    /// `.manager` (CROW-433 — Manager was previously pinned to Claude Code).
    ///
    /// Keyed by `SessionKind.rawValue` (string) rather than `SessionKind`
    /// directly so JSON serializes as an object literal like
    /// `{"review": "codex"}` — Swift's default `JSONEncoder` only treats
    /// dictionaries with `String`/`Int` keys as JSON objects.
    public var agentsByKind: [String: AgentKind]
    /// Optional AI gateway for the Manager session's `claude` launch. The
    /// Manager sits at `devRoot` and isn't bound to a single workspace, so it
    /// has its own gateway rather than inheriting any one workspace's. When nil,
    /// the Manager uses the vanilla Anthropic API (env vars explicitly unset so a
    /// global `~/.zshrc` export doesn't bleed in). Per-workspace `gateway` blocks
    /// apply to non-Manager sessions only (CROW-402).
    public var managerGateway: WorkspaceGateway?
    /// Optional Jira REST credential, shared org-wide (one Jira account), used
    /// only by the in-app status fetch (the #523 workspace status-map dropdown).
    /// Claude Code sessions get Jira via the global `jira` MCP in `~/.claude.json`,
    /// so Crow no longer injects any MCP (CROW-528). The API token is stored as an
    /// `op://` reference (resolved on demand) so it never lands at rest in
    /// `config.json`. When nil, the "Fetch from Jira" status button is disabled.
    public var jiraCredential: JiraCredential?

    /// Optional web-access password (CROW-593). When set, non-local access to the
    /// daemon's HTTP/WS surface requires logging in with this password; loopback
    /// (localhost) access stays unauthenticated. Stored as a PBKDF2 hash + salt so
    /// the plaintext never lands in `config.json`, and stripped from the config
    /// sent to clients (they only learn that a password is set). Set/cleared via
    /// the `set-web-password` RPC, never through `set-config`.
    public var webAuth: WebAuthConfig?

    /// Scoped bearer tokens for the read-only MCP server at `POST /mcp` (CROW-1004).
    /// Each record stores a SHA-256 hash of the token, never the token itself — the
    /// plaintext is returned exactly once, by `mcp-token-mint`. Stripped of its hash
    /// before the config reaches a browser and restored verbatim on the way back
    /// (`SettingsSecrets`), so a `set-config` round-trip can neither mint nor revoke
    /// one. Minted/revoked via the local-only `mcp-token-*` RPCs.
    public var mcpTokens: [MCPTokenRecord]

    /// Session-log collector behavior tuning (CROW-1056; slimmed in CROW-1070).
    /// Holds only the three global knobs — ledger retention, quiet period, upload
    /// cap. The opt-in and the upload destination + credential are per-workspace
    /// (the `uploadSessionLogs` checkbox reusing that workspace's local-only
    /// `gateway`), so this block carries no secret and is an ordinary
    /// browser-editable config block. `nil`/absent means all-default knobs.
    public var logSync: LogSyncConfig?

    /// First-class Corveil integration connection state (CROW-1118; epic
    /// CROW-1117). The source of truth for Crow's Corveil "Connect" (OAuth)
    /// integration — base URL, self-registered client id, connected user, per-org
    /// key metadata, and the OAuth tokens. The existing `WorkspaceGateway` +
    /// logsync configs are *generated* from it. Absent (`nil`) means "not
    /// connected". Its three OAuth token strings are secrets: `SettingsSecrets`
    /// blanks them for the browser and restores the whole block on the way back,
    /// so they never leave via `get-config`/`set-config` and a round-trip can't
    /// clear the connection. See ``CorveilConnection``.
    public var corveilConnection: CorveilConnection?

    /// Effective review-exclude patterns: the global `defaults.excludeReviewRepos`
    /// unioned with every workspace's per-workspace `excludeReviewRepos`. A repo
    /// excluded by any workspace (or the global default) is hidden from the review
    /// board. Order is irrelevant — `repoMatchesPatterns` matches on any pattern.
    public var effectiveExcludeReviewRepos: [String] {
        defaults.excludeReviewRepos + workspaces.flatMap(\.excludeReviewRepos)
    }

    /// The workspace that owns a repo, addressed by its `owner/repo` slug.
    ///
    /// Membership is `alwaysInclude` ∪ `autoReviewRepos` — the two lists that name
    /// repos a workspace *works on*. `excludeReviewRepos` is deliberately **not**
    /// subtracted: it's a review-board *visibility* filter, not a membership
    /// statement, so a repo hidden from the board still belongs to the workspace
    /// and still gets its gateway (CROW-891).
    ///
    /// Patterns use ``repoMatchesPatterns`` glob semantics — case-insensitive, one
    /// `*`. Ambiguity resolves deterministically so two workspaces claiming the
    /// same repo can't flip the answer between launches: a workspace naming the
    /// slug **exactly** beats one matching only through a glob, and among equals
    /// the earlier entry in `workspaces` (config file order) wins.
    ///
    /// Returns nil when no workspace claims the slug. Callers must treat that as
    /// "unset", not "inherit" — see `SessionService.workspaceGatewayResolved`.
    public func workspace(forRepoSlug slug: String) -> WorkspaceInfo? {
        let lowerSlug = slug.lowercased()
        var globMatch: WorkspaceInfo?
        for workspace in workspaces {
            let patterns = workspace.alwaysInclude + workspace.autoReviewRepos
            guard repoMatchesPatterns(slug, patterns: patterns) else { continue }
            if patterns.contains(where: { $0.lowercased() == lowerSlug }) {
                return workspace  // exact beats glob; first exact in config order wins
            }
            if globMatch == nil { globMatch = workspace }
        }
        return globMatch
    }

    public init(
        workspaces: [WorkspaceInfo] = [],
        defaults: ConfigDefaults = ConfigDefaults(),
        notifications: NotificationSettings = NotificationSettings(),
        sidebar: SidebarSettings = SidebarSettings(),
        switcher: SwitcherSettings = SwitcherSettings(),
        remoteControlEnabled: Bool = false,
        managerAutoPermissionMode: Bool = true,
        jobsAutoPermissionMode: Bool = true,
        reviewAutoPermissionMode: Bool = true,
        coderViewAutoPermissionMode: Bool = false,
        telemetry: TelemetryConfig = TelemetryConfig(),
        terminal: TerminalSettings = TerminalSettings(),
        autoRespond: AutoRespondSettings = AutoRespondSettings(),
        attributionTrailers: Bool = true,
        autoMergeWatcherEnabled: Bool = false,
        autoCreateWatcherEnabled: Bool = false,
        cleanup: CleanupConfig = CleanupConfig(),
        versionUpdate: VersionUpdateConfig = VersionUpdateConfig(),
        jobs: [JobConfig] = [],
        defaultAgentKind: AgentKind = .claudeCode,
        agentsByKind: [String: AgentKind] = [:],
        managerGateway: WorkspaceGateway? = nil,
        jiraCredential: JiraCredential? = nil,
        webAuth: WebAuthConfig? = nil,
        mcpTokens: [MCPTokenRecord] = [],
        logSync: LogSyncConfig? = nil,
        corveilConnection: CorveilConnection? = nil
    ) {
        self.workspaces = workspaces
        self.defaults = defaults
        self.notifications = notifications
        self.sidebar = sidebar
        self.switcher = switcher
        self.remoteControlEnabled = remoteControlEnabled
        self.managerAutoPermissionMode = managerAutoPermissionMode
        self.jobsAutoPermissionMode = jobsAutoPermissionMode
        self.reviewAutoPermissionMode = reviewAutoPermissionMode
        self.coderViewAutoPermissionMode = coderViewAutoPermissionMode
        self.telemetry = telemetry
        self.terminal = terminal
        self.autoRespond = autoRespond
        self.attributionTrailers = attributionTrailers
        self.autoMergeWatcherEnabled = autoMergeWatcherEnabled
        self.autoCreateWatcherEnabled = autoCreateWatcherEnabled
        self.cleanup = cleanup
        self.versionUpdate = versionUpdate
        self.jobs = jobs
        self.defaultAgentKind = defaultAgentKind
        self.agentsByKind = agentsByKind
        self.managerGateway = managerGateway
        self.jiraCredential = jiraCredential
        self.webAuth = webAuth
        self.mcpTokens = mcpTokens
        self.logSync = logSync
        self.corveilConnection = corveilConnection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decodeIfPresent([WorkspaceInfo].self, forKey: .workspaces) ?? []
        defaults = try container.decodeIfPresent(ConfigDefaults.self, forKey: .defaults) ?? ConfigDefaults()
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        sidebar = try container.decodeIfPresent(SidebarSettings.self, forKey: .sidebar) ?? SidebarSettings()
        switcher = try container.decodeIfPresent(SwitcherSettings.self, forKey: .switcher) ?? SwitcherSettings()
        remoteControlEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteControlEnabled) ?? false
        managerAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .managerAutoPermissionMode) ?? true
        jobsAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .jobsAutoPermissionMode) ?? true
        reviewAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .reviewAutoPermissionMode) ?? true
        coderViewAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .coderViewAutoPermissionMode) ?? false
        telemetry = try container.decodeIfPresent(TelemetryConfig.self, forKey: .telemetry) ?? TelemetryConfig()
        terminal = try container.decodeIfPresent(TerminalSettings.self, forKey: .terminal) ?? TerminalSettings()
        autoRespond = try container.decodeIfPresent(AutoRespondSettings.self, forKey: .autoRespond) ?? AutoRespondSettings()
        attributionTrailers = try container.decodeIfPresent(Bool.self, forKey: .attributionTrailers) ?? true
        autoMergeWatcherEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoMergeWatcherEnabled) ?? false
        autoCreateWatcherEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCreateWatcherEnabled) ?? false
        // Backward-compat (CROW-551): the pre-CROW-551 top-level
        // `autoRebaseWatcherEnabled` moved into
        // `autoRespond.autoRebaseAndResolveConflicts`. Carry an existing opt-in
        // forward; the legacy key stays out of `CodingKeys`, so the next encode
        // drops it and a later opt-out sticks.
        let rebaseLegacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if try rebaseLegacyContainer.decodeIfPresent(Bool.self, forKey: .autoRebaseWatcherEnabled) == true {
            autoRespond.autoRebaseAndResolveConflicts = true
        }
        cleanup = try container.decodeIfPresent(CleanupConfig.self, forKey: .cleanup) ?? CleanupConfig()
        versionUpdate = try container.decodeIfPresent(VersionUpdateConfig.self, forKey: .versionUpdate)
            ?? VersionUpdateConfig()
        jobs = try container.decodeIfPresent([JobConfig].self, forKey: .jobs) ?? []
        defaultAgentKind = try container.decodeIfPresent(AgentKind.self, forKey: .defaultAgentKind) ?? .claudeCode
        agentsByKind = try container.decodeIfPresent([String: AgentKind].self, forKey: .agentsByKind) ?? [:]
        managerGateway = try container.decodeIfPresent(WorkspaceGateway.self, forKey: .managerGateway)
        if let cred = try container.decodeIfPresent(JiraCredential.self, forKey: .jiraCredential) {
            jiraCredential = cred
        } else {
            // Backward-compat: migrate the pre-CROW-528 `atlassianMCP` block
            // (email/tokenRef) into the new Jira REST credential. Decoded from a
            // separate container so the legacy key stays out of `CodingKeys`
            // (which also drives the synthesized `encode(to:)`).
            let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let legacy = try legacyContainer.decodeIfPresent(LegacyAtlassianMCP.self, forKey: .atlassianMCP),
               !legacy.email.isEmpty || !legacy.tokenRef.isEmpty {
                jiraCredential = JiraCredential(username: legacy.email, tokenRef: legacy.tokenRef)
            } else {
                jiraCredential = nil
            }
        }
        webAuth = try container.decodeIfPresent(WebAuthConfig.self, forKey: .webAuth)
        mcpTokens = try container.decodeIfPresent([MCPTokenRecord].self, forKey: .mcpTokens) ?? []
        logSync = try container.decodeIfPresent(LogSyncConfig.self, forKey: .logSync)
        corveilConnection = try container.decodeIfPresent(CorveilConnection.self, forKey: .corveilConnection)
    }

    /// Pre-CROW-528 shape of the now-removed `atlassianMCP` config, decoded only
    /// to migrate an existing `config.json` forward to `jiraCredential`.
    private struct LegacyAtlassianMCP: Decodable {
        var email: String = ""
        var tokenRef: String = ""
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
            tokenRef = try c.decodeIfPresent(String.self, forKey: .tokenRef) ?? ""
        }
        enum CodingKeys: String, CodingKey { case email, tokenRef }
    }

    /// Decode-only keys for legacy/migrated fields that no longer have a stored
    /// property (so they must stay out of `CodingKeys`, which drives encoding).
    private enum LegacyCodingKeys: String, CodingKey {
        case atlassianMCP
        case autoRebaseWatcherEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces, defaults, notifications, sidebar, switcher, remoteControlEnabled, managerAutoPermissionMode, jobsAutoPermissionMode, reviewAutoPermissionMode, coderViewAutoPermissionMode, telemetry, terminal, autoRespond, attributionTrailers, autoMergeWatcherEnabled, autoCreateWatcherEnabled, cleanup, versionUpdate, jobs, defaultAgentKind, agentsByKind, managerGateway, jiraCredential, webAuth, mcpTokens, logSync, corveilConnection
    }

    /// Resolve the agent that should drive a newly-created session of the
    /// given kind. Prefers an explicit `agentsByKind` override, falling
    /// back to `defaultAgentKind` (CROW-421, CROW-433).
    public func agentKind(for sessionKind: SessionKind) -> AgentKind {
        return agentsByKind[sessionKind.rawValue] ?? defaultAgentKind
    }
}

extension AppConfig {
    /// Propagate a Corveil org key rotation across every stored gateway that embeds
    /// the old key value — the Manager gateway and each workspace gateway
    /// (corveil/crow#1124). The rotation itself lives in the connection's
    /// `orgKeySecrets`; this carries the new value into the gateways derived from it
    /// so neither the AI-gateway launch nor the reused log-upload credential is left
    /// authenticating with the revoked key.
    ///
    /// A no-op when `oldSecret` is blank or unchanged (see
    /// ``WorkspaceGateway/rewritingGatewayKey(from:to:)``), so it is safe to call on
    /// a first mint (no prior secret) as well as a rotate.
    public mutating func propagateCorveilKeyRotation(from oldSecret: String, to newSecret: String) {
        guard !oldSecret.isEmpty, oldSecret != newSecret else { return }
        managerGateway = managerGateway?.rewritingGatewayKey(from: oldSecret, to: newSecret)
        for index in workspaces.indices {
            workspaces[index].gateway =
                workspaces[index].gateway?.rewritingGatewayKey(from: oldSecret, to: newSecret)
        }
    }
}
