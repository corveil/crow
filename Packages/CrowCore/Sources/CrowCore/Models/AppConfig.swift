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
    /// unattended by definition.
    public var jobsAutoPermissionMode: Bool
    /// When true, code-review sessions start with `--permission-mode auto` so
    /// the review prompt can run `crow`, `gh`, and `git` without per-call
    /// approval. Defaults to true — reviews kick off unattended, like jobs.
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
    /// Manager terminal for assigned open issues labeled `crow:auto`.
    /// Opt-in: defaults to false (CROW-312). The label is still stripped
    /// after a successful dispatch so the trigger remains one-shot per
    /// issue. While disabled, the label is left alone so a later opt-in
    /// can still pick up previously-labeled issues.
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

    /// Session-log collector settings (CROW-1056). Opt-in, local-only, default
    /// OFF. When enabled, the daemon uploads opted-in workspaces' harness session
    /// transcripts to Corveil as session-artifacts. `nil`/absent means never
    /// configured — the collector is inert. Like `managerGateway`/`webAuth`, its
    /// API-key value is stripped before the config reaches a browser and it is
    /// writable only through the local-only `logsync-set` RPC (`SettingsSecrets`).
    public var logSync: LogSyncConfig?

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
        logSync: LogSyncConfig? = nil
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
        case workspaces, defaults, notifications, sidebar, switcher, remoteControlEnabled, managerAutoPermissionMode, jobsAutoPermissionMode, reviewAutoPermissionMode, coderViewAutoPermissionMode, telemetry, terminal, autoRespond, attributionTrailers, autoMergeWatcherEnabled, autoCreateWatcherEnabled, cleanup, versionUpdate, jobs, defaultAgentKind, agentsByKind, managerGateway, jiraCredential, webAuth, mcpTokens, logSync
    }

    /// Resolve the agent that should drive a newly-created session of the
    /// given kind. Prefers an explicit `agentsByKind` override, falling
    /// back to `defaultAgentKind` (CROW-421, CROW-433).
    public func agentKind(for sessionKind: SessionKind) -> AgentKind {
        return agentsByKind[sessionKind.rawValue] ?? defaultAgentKind
    }
}

/// Web-access password material (CROW-593): a PBKDF2-HMAC-SHA256 hash of the
/// password plus its salt and iteration count — never the plaintext. Presence of
/// this block means "a web password is set". `SettingsSecrets` blanks `hashB64`
/// and `saltB64` before the config is sent to a browser, so a client only learns
/// that a password exists, not its hash. Decodes tolerantly (missing fields → "")
/// so a partially-written config never traps.
public struct WebAuthConfig: Codable, Sendable, Equatable {
    public var hashB64: String
    public var saltB64: String
    public var iterations: Int

    public init(hashB64: String, saltB64: String, iterations: Int) {
        self.hashB64 = hashB64
        self.saltB64 = saltB64
        self.iterations = iterations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hashB64 = try c.decodeIfPresent(String.self, forKey: .hashB64) ?? ""
        saltB64 = try c.decodeIfPresent(String.self, forKey: .saltB64) ?? ""
        iterations = try c.decodeIfPresent(Int.self, forKey: .iterations) ?? 0
    }

    enum CodingKeys: String, CodingKey { case hashB64, saltB64, iterations }
}

/// Per-workspace (or per-Manager) AI gateway configuration. When present, the
/// `claude` launches it applies to inherit `ANTHROPIC_BASE_URL` (from `baseURL`)
/// and `ANTHROPIC_CUSTOM_HEADERS` (from `customHeaders`, serialized to
/// newline-separated `Name: Value` lines). When absent, those env vars are
/// explicitly unset before launch so a global `~/.zshrc` export — or a sibling
/// workspace's gateway — doesn't bleed in (CROW-402).
///
/// A header value may be a plaintext string or a secret reference. `op://…`
/// references are resolved at launch via the 1Password CLI (`op read`) so the
/// secret never lands at rest in `config.json`; any other value is treated
/// literally (plaintext — stored in `config.json`, so warn in the UI).
public struct WorkspaceGateway: Codable, Sendable, Equatable {
    public var baseURL: String
    public var customHeaders: [String: String]

    public init(baseURL: String, customHeaders: [String: String]) {
        self.baseURL = baseURL
        self.customHeaders = customHeaders
    }

    /// Whether this gateway has anything to apply. A gateway whose `baseURL` is
    /// blank and whose `customHeaders` is empty is treated as "no gateway".
    public var isEmpty: Bool {
        baseURL.trimmingCharacters(in: .whitespaces).isEmpty && customHeaders.isEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedBaseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        let decodedHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]

        // Reject a half-filled block at parse time (CROW-402): a baseURL with no
        // headers can't authenticate against the gateway, and headers with no
        // baseURL have nothing to attach to. Both-empty is allowed (it just means
        // "no gateway"); both-present is the valid case.
        let hasBaseURL = !decodedBaseURL.trimmingCharacters(in: .whitespaces).isEmpty
        let hasHeaders = !decodedHeaders.isEmpty
        if hasBaseURL != hasHeaders {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "gateway must set both baseURL and customHeaders, or neither (got baseURL: \(hasBaseURL ? "present" : "empty"), customHeaders: \(hasHeaders ? "present" : "empty"))"
                )
            )
        }

        baseURL = decodedBaseURL
        customHeaders = decodedHeaders
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL, customHeaders
    }
}

extension WorkspaceGateway {
    /// Parse a multiline `Name: Value` editor string into a header map. Blank
    /// lines are ignored; each line's first `:` splits name from value. Used by
    /// the Settings UI so a free-text editor maps to the `customHeaders` dict.
    public static func parseHeaderLines(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            result[name] = value
        }
        return result
    }

    /// Render a header map as a multiline `Name: Value` editor string (sorted by
    /// name for stable display).
    public static func headerLines(from headers: [String: String]) -> String {
        headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    /// Whether a header *value* was stored with literal surrounding quote
    /// characters — a shell-quoting slip (`--header 'X-Api-Key: "Bearer sk-…"'`)
    /// that nothing downstream notices (CROW-969). ``GatewayResolver/serializeHeaders(_:)``
    /// interpolates the value verbatim and `ClaudeLaunchArgs.gatewayEnvPrefix`
    /// shell-quotes the whole header line, so the stray quotes reach the gateway
    /// inside `ANTHROPIC_CUSTOM_HEADERS` and it rejects the request — surfacing to
    /// the user as a bare "API error" that names nothing actionable.
    ///
    /// Trimmed first, because the web path stores whatever the browser sent
    /// (`SecretRoutes.buildGateway` filters on trimmed *keys* only, never values).
    ///
    /// A blank or whitespace-only value is **not** wrapped. Blank is the "keep the
    /// secret already stored" signal that `SecretRoutes.mergingPreservedHeaders`
    /// resolves, so treating it as malformed would break every base-URL-only edit.
    ///
    /// Two characters are required so a lone `"` is not read as matching itself,
    /// and both ends must carry the *same* delimiter so `"abc'` — no recognizable
    /// shell slip — passes rather than inventing a rule we can't defend.
    ///
    /// Deliberately **not** enforced in ``init(from:)``: a config already on disk
    /// carrying this mistake must still decode. A decode failure makes
    /// `ConfigStore.loadConfig` return nil, and the next write then replaces every
    /// workspace, job and credential with defaults (the review-Red on #623, noted
    /// at `SecretRoutes.mergingPreservedHeaders`). Writes are guarded instead, and
    /// values already stored are warned about at launch by `GatewayResolver`.
    public static func isQuoteWrapped(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last
        else { return false }
        return (first == "\"" || first == "'") && first == last
    }

    /// Whether a header *name* carries a quote character a shell left behind.
    ///
    /// Catches the slip ``isQuoteWrapped(_:)`` structurally cannot see: quoting the
    /// whole pair (`--header '"X-Api-Key: sk-…"'`) puts one quote on the name and
    /// the other on the value, so neither half is individually wrapped.
    ///
    /// `"` is rejected anywhere in the name — RFC 9110's `field-name` is a `token`
    /// and `tchar` excludes `"` entirely, so a name containing one can never be a
    /// valid HTTP header whatever the author intended. `'` **is** a legal `tchar`,
    /// so it is rejected only in leading position, where no real header name has
    /// ever put one.
    ///
    /// Deliberately not caught: a *trailing* `'` (legal, and not a recognizable
    /// quoting artifact), and full RFC 9110 token validation — spaces, control
    /// characters and the like. Validation guards new writes only and a stored
    /// config is never re-validated, so broadening the grammar would reject
    /// someone re-saving an untouched, working header for a reason unrelated to
    /// the quoting slip this rule exists for.
    public static func headerNameHasStrayQuote(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("\"") { return true }
        return trimmed.first == "'"
    }
}

/// Jira REST credential used only by the in-app status fetch (CROW-528). The
/// Crow app process calls Jira's REST API directly (e.g. the #523 workspace
/// status-map dropdown via ``JiraStatusFetcher``); it cannot use the `jira` MCP,
/// which only serves Claude Code sessions. Those sessions instead inherit the
/// global `jira` MCP server from `~/.claude.json`, so Crow no longer injects or
/// provisions any Jira MCP itself.
///
/// Auth is a **personal API token** sent as HTTP Basic: the resolver builds
/// `Authorization: Basic base64("\(username):\(token)")`. `tokenRef` is an
/// `op://…` 1Password reference (resolved via `op read`) so the token never
/// lands at rest in `config.json`; a non-`op://` value is treated as a plaintext
/// token (stored in `config.json`, so warn in the UI). The Jira site comes from
/// the workspace's `jiraSite`, so no endpoint is stored here.
public struct JiraCredential: Codable, Sendable, Equatable {
    /// The Jira account email/username used for HTTP Basic auth (`JIRA_USERNAME`).
    public var username: String
    /// The API token, as an `op://…` reference (preferred) or plaintext.
    public var tokenRef: String

    public init(username: String, tokenRef: String) {
        self.username = username
        self.tokenRef = tokenRef
    }

    /// Whether this credential has enough to authenticate. Both a username and a
    /// token are required for Basic auth.
    public var isEmpty: Bool {
        username.trimmingCharacters(in: .whitespaces).isEmpty
            && tokenRef.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        tokenRef = try container.decodeIfPresent(String.self, forKey: .tokenRef) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case username, tokenRef
    }
}

/// Opt-in settings that let Crow type instructions into a session's managed
/// Claude Code terminal when a watched PR transitions into a state that
/// usually requires action.
///
/// `respondToChangesRequested` defaults **on** as of CROW-505 — auto-refine
/// is the answer to the user's complaint that a PR sitting in
/// CHANGES_REQUESTED with an idle agent never re-prompts. Existing users'
/// explicit choices stay sticky: `decodeIfPresent` returns whatever was
/// previously written, so a user who turned this off keeps it off across
/// the upgrade. `respondToFailedChecks` still defaults off — typing into a
/// terminal unprompted is intrusive, and CI flakes shouldn't auto-trigger
/// a fix-attempt.
public struct AutoRespondSettings: Codable, Sendable, Equatable {
    /// Inject a "fix the review feedback" prompt when a PR transitions into
    /// `reviewStatus == .changesRequested`.
    public var respondToChangesRequested: Bool
    /// Inject a "fix the failing checks" prompt when a PR transitions into
    /// `checksPass == .failing` (keyed on the head SHA, so re-runs of the
    /// same commit don't re-fire).
    public var respondToFailedChecks: Bool
    /// Auto-rebase Crow-authored PR branches that fall BEHIND base or become
    /// CONFLICTING: rebase onto base and force-push (`--force-with-lease`);
    /// when the rebase hits conflicts, inject the fixConflicts prompt into the
    /// session's managed terminal so Claude resolves them. Force-push-bearing,
    /// so opt-in: defaults to false (CROW-551; formerly the top-level
    /// `autoRebaseWatcherEnabled`, CROW-318).
    public var autoRebaseAndResolveConflicts: Bool
    /// Re-request review automatically when a CHANGES_REQUESTED PR's findings
    /// have been addressed and nobody has been asked to look again (CROW-921).
    /// Runs `gh pr edit --add-reviewer` from the daemon rather than asking the
    /// agent to do it, so it works no matter which path fixed the PR.
    ///
    /// Defaults to **true**, alongside `respondToChangesRequested`: the
    /// `addressChanges` prompt has always instructed the agent to re-request,
    /// so this completes behaviour users already expect rather than adding a
    /// new one. (Contrast `autoRebaseAndResolveConflicts`, which defaults off
    /// because it force-pushes.) Re-requesting is idempotent and reversible.
    public var autoReRequestReview: Bool

    public init(
        respondToChangesRequested: Bool = true,
        respondToFailedChecks: Bool = false,
        autoRebaseAndResolveConflicts: Bool = false,
        autoReRequestReview: Bool = true
    ) {
        self.respondToChangesRequested = respondToChangesRequested
        self.respondToFailedChecks = respondToFailedChecks
        self.autoRebaseAndResolveConflicts = autoRebaseAndResolveConflicts
        self.autoReRequestReview = autoReRequestReview
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        respondToChangesRequested = try c.decodeIfPresent(Bool.self, forKey: .respondToChangesRequested) ?? true
        respondToFailedChecks = try c.decodeIfPresent(Bool.self, forKey: .respondToFailedChecks) ?? false
        autoRebaseAndResolveConflicts = try c.decodeIfPresent(Bool.self, forKey: .autoRebaseAndResolveConflicts) ?? false
        autoReRequestReview = try c.decodeIfPresent(Bool.self, forKey: .autoReRequestReview) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case respondToChangesRequested, respondToFailedChecks, autoRebaseAndResolveConflicts
        case autoReRequestReview
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
    public var excludeReviewRepos: [String] // repos whose review requests are hidden from the review board
    public var customInstructions: String? // free-text instructions appended to session prompts
    /// Which `crow-review-pr` finding severities force `gh pr review
    /// --request-changes` for this workspace (CROW-963).
    ///
    /// `nil` — the unset state — means Crow's default, ``ReviewSeverity/defaultBlocking``
    /// (`red` + `yellow`), **not** "nothing blocks". An install that never touches
    /// this setting must see exactly today's behaviour, so `--clear-…` removes the
    /// key rather than storing an empty list. An explicitly empty list is rejected
    /// at every write boundary (CLI, RPC, web): a workspace where nothing gates the
    /// verdict approves every review, and with `autoMergeWatcherEnabled` on, merges
    /// it too. Decoding stays lenient — see `init(from:)`.
    ///
    /// **Advisory only.** The review agent runs `gh pr review` itself; Crow never
    /// sees the call and cannot validate the posted verdict against this policy.
    /// The field configures a prompt, not a gate.
    public var reviewBlockingSeverities: [ReviewSeverity]?
    /// Optional AI gateway. When set, `claude` launches into this workspace
    /// inherit `ANTHROPIC_BASE_URL`/`ANTHROPIC_CUSTOM_HEADERS` derived from it;
    /// when nil, those env vars are explicitly unset so a global `~/.zshrc`
    /// export doesn't leak in (CROW-402). Does not apply to the Manager session,
    /// which has its own `AppConfig.managerGateway`.
    public var gateway: WorkspaceGateway?

    /// Where this workspace's **tasks/tickets** live, independent of `provider`
    /// (which is the **code/PR** host). `nil` means "follow the code provider"
    /// — so existing GitHub-code workspaces keep using GitHub issues, unchanged.
    /// Set to `"jira"` to pull tickets from Jira while code/PRs stay on GitHub
    /// (ADR 0005 cross-backend pairing). See `derivedTaskProvider`.
    public var taskProvider: String?  // "github" | "gitlab" | "jira" | nil
    /// Jira project key (e.g. "PROPS") — default project for created tickets and
    /// scoping. Only meaningful when `taskProvider == "jira"`.
    public var jiraProjectKey: String?
    /// JQL for this workspace's "my open tickets" board query. Only meaningful
    /// when `taskProvider == "jira"`; falls back to a sensible default when nil.
    public var jiraJQL: String?
    /// Atlassian site host (e.g. "acme.atlassian.net") used to build user-facing
    /// `…/browse/KEY` URLs. Only meaningful when `taskProvider == "jira"`.
    public var jiraSite: String?
    /// Per-workspace override of the Crow→Jira status-name map. Keys are
    /// ``TicketStatus`` raw values for the pipeline statuses ("Backlog", "Ready",
    /// "In Progress", "In Review", "Done"); values are the concrete Jira workflow
    /// status names for this project. A missing/blank entry falls back to
    /// ``JiraTaskBackend.defaultJiraStatusName(for:)``. Only meaningful when
    /// `taskProvider == "jira"`. See #523.
    public var jiraStatusMap: [String: String]?
    /// Self-hosted Corveil host (e.g. "corveil.acme.io") used **only** for URL
    /// routing in `ProviderManager.detect` — Corveil's own auth/state lives in
    /// the CLI (`corveil login`, `CORVEIL_URL`), so Crow doesn't pipe it through.
    /// `nil` is fine: the public `corveil.io` is auto-detected.
    public var corveilHost: String?
    /// Extra environment variables exported into every agent launched in this
    /// workspace, as a plain `KEY: VALUE` map.
    ///
    /// This field was consumed before it was modeled: `skills/crow-workspace/setup.sh`
    /// reads `.workspaces[].sessionEnv` out of `config.json` with `jq`, and the
    /// skill documents it as a peer of `gateway` / `customInstructions`. But
    /// `encode(to:)` is synthesized from ``CodingKeys``, so while the key was
    /// absent from that list *every* config save silently deleted a hand-authored
    /// block — and the `jq` read then returned empty with no error (CROW-809).
    /// Modeling it is what makes the round-trip lossless.
    ///
    /// Unlike ``gateway`` this is not treated as a credential: it is not stripped
    /// by `SettingsSecrets`, so don't put tokens here — use a gateway header.
    public var sessionEnv: [String: String]?

    /// Opt this workspace's coding-session transcripts in to Corveil upload
    /// (CROW-1066). The follow-up to the CLI-only `logSync.enabledWorkspaces`
    /// list: a per-workspace checkbox in Settings → Workspaces that **reuses the
    /// workspace's own `gateway` credential** so the operator never re-enters a
    /// Corveil API key. `LogSyncCollector` uploads a session only when the
    /// local-only master switch `logSync.enabled` is on **and** the session's
    /// workspace either sets this flag or appears in `logSync.enabledWorkspaces`.
    ///
    /// Unlike the rest of the `logSync` block — which is local-only, so a remote
    /// peer cannot flip it — this rides on the workspace record and is therefore
    /// **browser-flippable** through `set-config` / `workspace edit`. That is a
    /// deliberate, bounded relaxation (CROW-1066): it only reuses a credential the
    /// workspace already holds (the gateway key, itself local-only and never
    /// readable/authorable from the web), the upload destination stays the
    /// local-only `logSync.baseURL`, and `logSync.enabled` remains the local kill
    /// switch. Default `false`.
    public var uploadSessionLogs: Bool

    /// The CLI tool name derived from the current `provider` value.
    /// Unlike `cli` (which may be stale from an old config file), this is always correct.
    public var derivedCLI: String {
        provider == "github" ? "gh" : "glab"
    }

    /// The effective task-provider string: the explicit `taskProvider` when set,
    /// otherwise the code `provider` (so existing workspaces are unchanged).
    public var derivedTaskProvider: String {
        taskProvider ?? provider
    }

    /// The severities that gate this workspace's review verdicts, resolving the
    /// unset state to Crow's default rather than to "nothing blocks" (CROW-963).
    public var effectiveReviewBlockingSeverities: [ReviewSeverity] {
        reviewBlockingSeverities ?? ReviewSeverity.defaultBlocking
    }

    public init(
        id: UUID = UUID(),
        name: String,
        provider: String = "github",
        cli: String = "gh",
        host: String? = nil,
        alwaysInclude: [String] = [],
        autoReviewRepos: [String] = [],
        excludeReviewRepos: [String] = [],
        customInstructions: String? = nil,
        reviewBlockingSeverities: [ReviewSeverity]? = nil,
        taskProvider: String? = nil,
        jiraProjectKey: String? = nil,
        jiraJQL: String? = nil,
        jiraSite: String? = nil,
        jiraStatusMap: [String: String]? = nil,
        corveilHost: String? = nil,
        sessionEnv: [String: String]? = nil,
        uploadSessionLogs: Bool = false,
        gateway: WorkspaceGateway? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.cli = cli
        self.host = host
        self.alwaysInclude = alwaysInclude
        self.autoReviewRepos = autoReviewRepos
        self.excludeReviewRepos = excludeReviewRepos
        self.customInstructions = customInstructions
        self.reviewBlockingSeverities = reviewBlockingSeverities.map(ReviewSeverity.canonicalize)
        self.taskProvider = taskProvider
        self.jiraProjectKey = jiraProjectKey
        self.jiraJQL = jiraJQL
        self.jiraSite = jiraSite
        self.jiraStatusMap = jiraStatusMap
        self.corveilHost = corveilHost
        self.sessionEnv = sessionEnv
        self.uploadSessionLogs = uploadSessionLogs
        self.gateway = gateway
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
        excludeReviewRepos = try container.decodeIfPresent([String].self, forKey: .excludeReviewRepos) ?? []
        customInstructions = try container.decodeIfPresent(String.self, forKey: .customInstructions)
        // Decoded as `[String]`, never as `[ReviewSeverity]` (CROW-963). A direct
        // enum decode throws on an unrecognized value, and a throwing
        // `WorkspaceInfo` decode makes `ConfigStore.loadConfig` return nil — at
        // which point every writer's `?? AppConfig()` fallback rewrites
        // config.json with defaults, taking every workspace, job and gateway with
        // it. So: drop unknown values, canonicalize, and treat an empty result as
        // unset (the default set). Rejecting an empty list is the *write* path's
        // job — a hand-edited config must still load.
        reviewBlockingSeverities = try container
            .decodeIfPresent([String].self, forKey: .reviewBlockingSeverities)
            .map { raw in
                ReviewSeverity.canonicalize(raw.compactMap {
                    ReviewSeverity(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased())
                })
            }
            .flatMap { $0.isEmpty ? nil : $0 }
        taskProvider = try container.decodeIfPresent(String.self, forKey: .taskProvider)
        jiraProjectKey = try container.decodeIfPresent(String.self, forKey: .jiraProjectKey)
        jiraJQL = try container.decodeIfPresent(String.self, forKey: .jiraJQL)
        jiraSite = try container.decodeIfPresent(String.self, forKey: .jiraSite)
        jiraStatusMap = try container.decodeIfPresent([String: String].self, forKey: .jiraStatusMap)
        corveilHost = try container.decodeIfPresent(String.self, forKey: .corveilHost)
        sessionEnv = try container.decodeIfPresent([String: String].self, forKey: .sessionEnv)
        // Decode-tolerant (CROW-1066): an older config lacking the key opts out.
        uploadSessionLogs = try container.decodeIfPresent(Bool.self, forKey: .uploadSessionLogs) ?? false
        gateway = try container.decodeIfPresent(WorkspaceGateway.self, forKey: .gateway)
    }

    // `encode(to:)` is synthesized from this list, so a key missing here is a
    // key *deleted* from config.json on the next save — not merely one the app
    // ignores. That is how `sessionEnv` was being dropped (CROW-809).
    private enum CodingKeys: String, CodingKey {
        case id, name, provider, cli, host, alwaysInclude, autoReviewRepos, excludeReviewRepos, customInstructions
        case reviewBlockingSeverities
        case taskProvider, jiraProjectKey, jiraJQL, jiraSite, jiraStatusMap, corveilHost, sessionEnv, uploadSessionLogs, gateway
    }

    /// Legal `provider` values — the code/PR hosts.
    ///
    /// Derived from ``Provider`` rather than spelled out, so a new provider case
    /// lands in the CLI's `--provider` rejection message and the `workspace-*`
    /// RPC validation without a second edit. Task-only providers (Jira, Corveil)
    /// have no git surface, so they're never a code provider.
    public static var validProviders: [String] {
        Provider.allCases.filter { !$0.isTaskOnly }.map(\.rawValue)
    }

    /// Legal `taskProvider` values — every ``Provider``. `nil` (the Settings
    /// dropdown's blank option) additionally means "follow the code provider".
    public static var validTaskProviders: [String] { Provider.allCases.map(\.rawValue) }

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
        // The name becomes a path component under devRoot; "." / ".." would
        // resolve outside the intended directory.
        if name == "." || name == ".." {
            return "Name cannot be “.” or “..”"
        }
        // Crow owns some dev-root directories that aren't workspaces. A workspace
        // folder of that name would collide with them on disk, and anything
        // deriving a workspace from a path would bind those sessions to it —
        // review sessions in particular (CROW-891).
        if DevRootLayout.isReservedWorkspaceName(name) {
            return "“\(name)” is reserved by Crow and cannot be a workspace name"
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
    /// Absolute-path overrides for executable binaries, keyed by tool name.
    ///
    /// Serves two callers that share the same map shape:
    /// - **Agent binary discovery** (CROW-484): keyed by `AgentKind.rawValue`
    ///   (`"codex"`, `"cursor"`, `"claude-code"`). `CodingAgent.findBinary()`
    ///   consults this map before walking PATH — set this when discovery
    ///   doesn't find your install (exotic Node manager, sandboxed PATH, etc.).
    /// - **External tool installers** (CROW-482): keyed by tool name (e.g.
    ///   `"corveil"`) and used by `Scaffolder` to run each tool's own skill
    ///   installer on launch. The Settings UI currently exposes only the
    ///   `corveil` slot; the map shape is intentionally generic so future
    ///   tools (soulstone, tanzanite, …) extend the same field without a
    ///   schema change.
    ///
    /// Agent keys (`claude-code`, `codex`, `cursor`) and tool keys (`corveil`,
    /// …) don't overlap, so the two callers coexist in one map.
    public var binaries: [String: String]

    /// Whether Crow mirrors the user's `~/.claude.json` `mcpServers` into Codex's
    /// `~/.codex/config.toml` on daemon boot (#830). Default `true` for MCP
    /// parity with Claude sessions. Set `false` to opt out: mirroring copies MCP
    /// `env` values (often API tokens) into a second on-disk file, so a user who
    /// deliberately keeps credentials in one place can suppress the duplication.
    public var mirrorClaudeMCPToCodex: Bool

    /// Forge providers the Settings → Workspaces picker offers.
    ///
    /// Lives on the model, not in the CLI or the RPC layer, so `crow defaults
    /// set --provider` and the `defaults-set` handler validate against one list
    /// (CROW-810). `GitManager` compares `provider` with `==`, so a casing
    /// variant is a real mismatch, not a cosmetic one — hence no lowercasing
    /// anywhere; callers are told the exact accepted spellings.
    public static let validProviders = ["github", "gitlab"]

    /// Forge CLIs `GitManager` shells out to. Paired with `validProviders`, but
    /// stored independently — see `provider`/`cli` in `GitManager`.
    public static let validCLIs = ["gh", "glab"]

    /// Binary-override name `Scaffolder` owns outright.
    ///
    /// Mirrors its `managedBinarySymlinks`: the reap loop skips this key and
    /// `ClaudeHookConfigWriter.ensureCrowCLISymlink` re-points it at the running
    /// app's own CLI on every launch, while `BinaryOverrides` never consults it
    /// (it is not an `AgentKind`). An override here can therefore never take effect.
    public static let reservedBinaryName = "crow"

    /// Whether a `binaries` key is safe to write.
    ///
    /// The name becomes `{devRoot}/.claude/bin/<name>` in
    /// `Scaffolder.installBinarySymlinks`, which builds that path with
    /// `appendingPathComponent` and then `removeItem`s it before symlinking. A
    /// **blank** name resolves to the bin *directory*, which that code would
    /// delete and replace with a symlink; a name containing a path separator
    /// escapes the directory entirely, and the reap loop (which walks
    /// `contentsOfDirectory`) could never clean the orphan up.
    public static func isValidBinaryName(_ name: String) -> Bool {
        guard !name.isEmpty, name != reservedBinaryName else { return false }
        return !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

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
        ignoreReviewLabels: [String] = [],
        binaries: [String: String] = [:],
        mirrorClaudeMCPToCodex: Bool = true
    ) {
        self.provider = provider
        self.cli = cli
        self.branchPrefix = branchPrefix
        self.excludeDirs = excludeDirs
        self.excludeReviewRepos = excludeReviewRepos
        self.excludeTicketRepos = excludeTicketRepos
        self.ignoreReviewLabels = ignoreReviewLabels
        self.binaries = binaries
        self.mirrorClaudeMCPToCodex = mirrorClaudeMCPToCodex
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
        binaries = try container.decodeIfPresent([String: String].self, forKey: .binaries) ?? [:]
        mirrorClaudeMCPToCodex = try container.decodeIfPresent(Bool.self, forKey: .mirrorClaudeMCPToCodex) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case provider, cli, branchPrefix, excludeDirs, excludeReviewRepos, excludeTicketRepos, ignoreReviewLabels, binaries, mirrorClaudeMCPToCodex
    }
}

/// Sidebar display preferences.
public struct SidebarSettings: Codable, Sendable, Equatable {
    public var hideSessionDetails: Bool

    public init(hideSessionDetails: Bool = false) {
        self.hideSessionDetails = hideSessionDetails
    }

    /// Per-key defaults, matching `ConfigDefaults` and `TerminalSettings`.
    /// `AppConfig`'s `decodeIfPresent` only tolerates a wholly *absent* block —
    /// a present-but-partial one (`{"sidebar": {}}`) would throw `keyNotFound`
    /// and fail the entire config decode (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hideSessionDetails = try c.decodeIfPresent(Bool.self, forKey: .hideSessionDetails) ?? false
    }

    enum CodingKeys: String, CodingKey { case hideSessionDetails }
}

/// Session-switcher ordering mode (CROW-976).
public enum SwitcherOrder: String, Codable, Sendable, Equatable {
    case mru
    case sidebar
}

/// Per-category / per-status filters for the session switcher overlay.
public struct SwitcherIncludeSettings: Codable, Sendable, Equatable {
    public var managers: Bool
    public var jobs: Bool
    public var reviews: Bool
    public var active: Bool
    public var paused: Bool
    public var inReview: Bool
    public var completed: Bool
    public var archived: Bool

    public init(
        managers: Bool = false,
        jobs: Bool = false,
        reviews: Bool = true,
        active: Bool = true,
        paused: Bool = true,
        inReview: Bool = true,
        completed: Bool = false,
        archived: Bool = false
    ) {
        self.managers = managers
        self.jobs = jobs
        self.reviews = reviews
        self.active = active
        self.paused = paused
        self.inReview = inReview
        self.completed = completed
        self.archived = archived
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        managers = try c.decodeIfPresent(Bool.self, forKey: .managers) ?? false
        jobs = try c.decodeIfPresent(Bool.self, forKey: .jobs) ?? false
        reviews = try c.decodeIfPresent(Bool.self, forKey: .reviews) ?? true
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? true
        inReview = try c.decodeIfPresent(Bool.self, forKey: .inReview) ?? true
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    }

    enum CodingKeys: String, CodingKey {
        case managers, jobs, reviews, active, paused, inReview, completed, archived
    }
}

/// Session switcher overlay preferences (CROW-976).
public struct SwitcherSettings: Codable, Sendable, Equatable {
    /// The binding new installs get, and the target every legacy default is
    /// migrated onto (CROW-1002). `cmd+/` is a plain modifier chord — no prefix
    /// sequence to learn, no key an agent TUI wants — so it commits on release
    /// of Cmd the way a macOS app switcher does.
    ///
    /// Non-Apple keyboards have no Cmd: set `ctrl+/` with
    /// `crow ui set --switcher-binding 'ctrl+/'`.
    public static let defaultBinding = "cmd+/"

    /// Bindings Crow refuses to use for the switcher, rewritten to
    /// `defaultBinding` on decode and rejected on write (CROW-1002).
    ///
    /// `shift+tab` is Claude Code's (and Cursor's, and Codex's) permission-mode
    /// cycle, and `captureInTerminal` defaults to true, so a config carrying it
    /// swallows that keystroke in every focused terminal. CROW-980 changed only
    /// the *default* — which reaches a config with no `binding` key at all — so
    /// every install that had already written one kept eating Shift+Tab. That is
    /// the bug CROW-1002 opens with, and a default change alone would not have
    /// fixed it a second time.
    ///
    /// Migration and validation share this set on purpose: a binding the decoder
    /// silently rewrites but the setter still accepts would revert on the next
    /// daemon start with nothing to explain why. Anything not listed here is a
    /// real choice and is left alone — `esc+tab` included, which merely stopped
    /// being the default.
    public static let reservedBindings: Set<String> = ["shift+tab"]

    /// True when `binding` names a chord Crow must not take from the terminal.
    ///
    /// Trimmed and case-folded because `--switcher-binding` stores the string
    /// verbatim and the client parses it case-insensitively, so `Shift+Tab `
    /// reaches the terminal as the same swallowed keystroke `shift+tab` does.
    public static func isReservedBinding(_ binding: String) -> Bool {
        reservedBindings.contains(binding.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public var enabled: Bool
    /// Chord string, e.g. `cmd+/` or `ctrl+space`. Parsed client-side.
    ///
    /// A leading `esc` is still accepted and parsed as a *prefix* rather than a
    /// modifier (tap Esc, then the key) — CROW-980's sequence support outlived
    /// its stint as the default.
    public var binding: String
    /// When true, the binding is captured even inside a focused terminal.
    public var captureInTerminal: Bool
    public var order: SwitcherOrder
    /// Fetch a cheap tmux pane preview for the highlighted card.
    public var preview: Bool
    public var include: SwitcherIncludeSettings

    public init(
        enabled: Bool = true,
        binding: String = SwitcherSettings.defaultBinding,
        captureInTerminal: Bool = true,
        order: SwitcherOrder = .mru,
        preview: Bool = true,
        include: SwitcherIncludeSettings = SwitcherIncludeSettings()
    ) {
        self.enabled = enabled
        self.binding = binding
        self.captureInTerminal = captureInTerminal
        self.order = order
        self.preview = preview
        self.include = include
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        binding = SwitcherSettings.migratedBinding(
            try c.decodeIfPresent(String.self, forKey: .binding))
        captureInTerminal = try c.decodeIfPresent(Bool.self, forKey: .captureInTerminal) ?? true
        order = try c.decodeIfPresent(SwitcherOrder.self, forKey: .order) ?? .mru
        preview = try c.decodeIfPresent(Bool.self, forKey: .preview) ?? true
        include = try c.decodeIfPresent(SwitcherIncludeSettings.self, forKey: .include)
            ?? SwitcherIncludeSettings()
    }

    /// Resolve a stored binding, rewriting a reserved one onto the current
    /// default (CROW-1002). Absent and blank both mean "never chose one".
    public static func migratedBinding(_ stored: String?) -> String {
        guard let stored, !stored.trimmingCharacters(in: .whitespaces).isEmpty else {
            return defaultBinding
        }
        return isReservedBinding(stored) ? defaultBinding : stored
    }

    enum CodingKeys: String, CodingKey {
        case enabled, binding, captureInTerminal, order, preview, include
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

    /// Per-key defaults — see `SidebarSettings.init(from:)` (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 4318
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 180
    }

    enum CodingKeys: String, CodingKey { case enabled, port, retentionDays }
}

/// Terminal wheel-scroll tuning (CROW-835). The web terminal routes the wheel by
/// surface under ADR-0013's per-surface hybrid model, and the two paths have
/// different natural units, so each gets its own knob. Device normalization
/// (`deltaMode` + sub-notch accumulation) is a fixed client-side concern and is
/// deliberately not configurable — these only scale the resulting notch count.
public struct TerminalSettings: Codable, Sendable, Equatable {
    /// Plain-shell surfaces: local xterm scrollback **lines per physical wheel
    /// notch** (default 3 — the historical hardcoded value).
    public var wheelScrollLines: Int
    /// Agent-TUI surfaces (Claude Code / Cursor / Manager): number of wheel
    /// reports **forwarded to the app per physical notch** (default 1 — one notch
    /// in, one notch out; the app owns its own lines-per-notch). Raise it if agent
    /// scrolling feels too slow.
    public var agentWheelNotches: Int

    public init(wheelScrollLines: Int = 3, agentWheelNotches: Int = 1) {
        self.wheelScrollLines = wheelScrollLines
        self.agentWheelNotches = agentWheelNotches
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wheelScrollLines = try c.decodeIfPresent(Int.self, forKey: .wheelScrollLines) ?? 3
        agentWheelNotches = try c.decodeIfPresent(Int.self, forKey: .agentWheelNotches) ?? 1
    }

    enum CodingKeys: String, CodingKey { case wheelScrollLines, agentWheelNotches }
}

/// Auto-cleanup settings for completed and archived sessions.
public struct CleanupConfig: Codable, Sendable, Equatable {
    /// Whether auto-cleanup is enabled. Disabled by default.
    public var enabled: Bool
    /// Hours to retain completed/archived sessions before deletion.
    public var retentionHours: Int

    public init(enabled: Bool = false, retentionHours: Int = 24) {
        self.enabled = enabled
        self.retentionHours = retentionHours
    }

    /// Per-key defaults — see `SidebarSettings.init(from:)` (CROW-814).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        retentionHours = try c.decodeIfPresent(Int.self, forKey: .retentionHours) ?? 24
    }

    enum CodingKeys: String, CodingKey { case enabled, retentionHours }
}

/// Session-log upload settings (CROW-1056) — the opt-in, local-only control
/// block for the multi-harness session-log collector.
///
/// **Local-only, default OFF.** This block configures uploads *from the daemon
/// host* and carries a Corveil API-key reference, so — like `managerGateway` /
/// `webAuth` / `mcpTokens` — it is stripped before the config reaches a browser
/// (`SettingsSecrets`) and is writable only through the local-only `logsync-set`
/// RPC, never `set-config`. Nothing uploads unless a local operator turns it on.
///
/// The collector uploads a session's transcript only when **both** `enabled` is
/// true **and** the session's workspace name is listed in `enabledWorkspaces`
/// (the per-workspace opt-in — matched case-insensitively). Uploads are
/// best-effort and never block or fail a session.
public struct LogSyncConfig: Codable, Sendable, Equatable {
    /// Master switch. `false` (the default) means the collector does nothing.
    public var enabled: Bool
    /// Corveil API base URL that hosts `POST /api/crow-sessions/{id}/artifacts`
    /// (e.g. `https://api.corveil.io`). Empty disables uploads even when
    /// `enabled` is true.
    public var baseURL: String
    /// The developer's own Corveil API key, as an `op://…` 1Password reference
    /// (resolved at upload via `GatewayResolver.opRead`, so the secret never
    /// lands at rest in `config.json`) or a plaintext key. Sent as
    /// `Authorization: Bearer <key>`. The upload is authenticated as — and
    /// attributed to — this principal, server-side; there are no AWS credentials
    /// on the laptop.
    public var apiKeyRef: String
    /// Names of the workspaces opted in to transcript upload. A session uploads
    /// only if its workspace name appears here (case-insensitive). Empty = no
    /// workspace uploads, which is the default even when `enabled` is true.
    public var enabledWorkspaces: [String]
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
    /// Per-artifact upload cap in bytes. A larger transcript is truncated and
    /// flagged. Kept at/under the server's own limit. Default 8,000,000.
    public var maxUploadBytes: Int

    public init(
        enabled: Bool = false,
        baseURL: String = "",
        apiKeyRef: String = "",
        enabledWorkspaces: [String] = [],
        retentionDays: Int = 30,
        quietPeriodMinutes: Int = 30,
        maxUploadBytes: Int = 8_000_000
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
        self.enabledWorkspaces = enabledWorkspaces
        self.retentionDays = retentionDays
        self.quietPeriodMinutes = quietPeriodMinutes
        self.maxUploadBytes = maxUploadBytes
    }

    /// Per-key tolerant decode — an older `config.json` lacking any field (or the
    /// whole block) still decodes (CROW-814 idiom).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKeyRef = try c.decodeIfPresent(String.self, forKey: .apiKeyRef) ?? ""
        enabledWorkspaces = try c.decodeIfPresent([String].self, forKey: .enabledWorkspaces) ?? []
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        quietPeriodMinutes = try c.decodeIfPresent(Int.self, forKey: .quietPeriodMinutes) ?? 30
        maxUploadBytes = try c.decodeIfPresent(Int.self, forKey: .maxUploadBytes) ?? 8_000_000
    }

    /// Whether this workspace name is opted in (case-insensitive).
    public func uploadsWorkspace(_ name: String) -> Bool {
        let lower = name.lowercased()
        return enabledWorkspaces.contains { $0.lowercased() == lower }
    }

    enum CodingKeys: String, CodingKey {
        case enabled, baseURL, apiKeyRef, enabledWorkspaces, retentionDays, quietPeriodMinutes, maxUploadBytes
    }
}
