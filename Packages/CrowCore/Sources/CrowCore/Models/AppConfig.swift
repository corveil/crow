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

    /// Effective review-exclude patterns: the global `defaults.excludeReviewRepos`
    /// unioned with every workspace's per-workspace `excludeReviewRepos`. A repo
    /// excluded by any workspace (or the global default) is hidden from the review
    /// board. Order is irrelevant — `repoMatchesPatterns` matches on any pattern.
    public var effectiveExcludeReviewRepos: [String] {
        defaults.excludeReviewRepos + workspaces.flatMap(\.excludeReviewRepos)
    }

    public init(
        workspaces: [WorkspaceInfo] = [],
        defaults: ConfigDefaults = ConfigDefaults(),
        notifications: NotificationSettings = NotificationSettings(),
        sidebar: SidebarSettings = SidebarSettings(),
        remoteControlEnabled: Bool = false,
        managerAutoPermissionMode: Bool = true,
        jobsAutoPermissionMode: Bool = true,
        reviewAutoPermissionMode: Bool = true,
        coderViewAutoPermissionMode: Bool = false,
        telemetry: TelemetryConfig = TelemetryConfig(),
        autoRespond: AutoRespondSettings = AutoRespondSettings(),
        attributionTrailers: Bool = true,
        autoMergeWatcherEnabled: Bool = false,
        autoCreateWatcherEnabled: Bool = false,
        cleanup: CleanupConfig = CleanupConfig(),
        jobs: [JobConfig] = [],
        defaultAgentKind: AgentKind = .claudeCode,
        agentsByKind: [String: AgentKind] = [:],
        managerGateway: WorkspaceGateway? = nil,
        jiraCredential: JiraCredential? = nil,
        webAuth: WebAuthConfig? = nil
    ) {
        self.workspaces = workspaces
        self.defaults = defaults
        self.notifications = notifications
        self.sidebar = sidebar
        self.remoteControlEnabled = remoteControlEnabled
        self.managerAutoPermissionMode = managerAutoPermissionMode
        self.jobsAutoPermissionMode = jobsAutoPermissionMode
        self.reviewAutoPermissionMode = reviewAutoPermissionMode
        self.coderViewAutoPermissionMode = coderViewAutoPermissionMode
        self.telemetry = telemetry
        self.autoRespond = autoRespond
        self.attributionTrailers = attributionTrailers
        self.autoMergeWatcherEnabled = autoMergeWatcherEnabled
        self.autoCreateWatcherEnabled = autoCreateWatcherEnabled
        self.cleanup = cleanup
        self.jobs = jobs
        self.defaultAgentKind = defaultAgentKind
        self.agentsByKind = agentsByKind
        self.managerGateway = managerGateway
        self.jiraCredential = jiraCredential
        self.webAuth = webAuth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decodeIfPresent([WorkspaceInfo].self, forKey: .workspaces) ?? []
        defaults = try container.decodeIfPresent(ConfigDefaults.self, forKey: .defaults) ?? ConfigDefaults()
        notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications) ?? NotificationSettings()
        sidebar = try container.decodeIfPresent(SidebarSettings.self, forKey: .sidebar) ?? SidebarSettings()
        remoteControlEnabled = try container.decodeIfPresent(Bool.self, forKey: .remoteControlEnabled) ?? false
        managerAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .managerAutoPermissionMode) ?? true
        jobsAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .jobsAutoPermissionMode) ?? true
        reviewAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .reviewAutoPermissionMode) ?? true
        coderViewAutoPermissionMode = try container.decodeIfPresent(Bool.self, forKey: .coderViewAutoPermissionMode) ?? false
        telemetry = try container.decodeIfPresent(TelemetryConfig.self, forKey: .telemetry) ?? TelemetryConfig()
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
        case workspaces, defaults, notifications, sidebar, remoteControlEnabled, managerAutoPermissionMode, jobsAutoPermissionMode, reviewAutoPermissionMode, coderViewAutoPermissionMode, telemetry, autoRespond, attributionTrailers, autoMergeWatcherEnabled, autoCreateWatcherEnabled, cleanup, jobs, defaultAgentKind, agentsByKind, managerGateway, jiraCredential, webAuth
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

    public init(
        respondToChangesRequested: Bool = true,
        respondToFailedChecks: Bool = false,
        autoRebaseAndResolveConflicts: Bool = false
    ) {
        self.respondToChangesRequested = respondToChangesRequested
        self.respondToFailedChecks = respondToFailedChecks
        self.autoRebaseAndResolveConflicts = autoRebaseAndResolveConflicts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        respondToChangesRequested = try c.decodeIfPresent(Bool.self, forKey: .respondToChangesRequested) ?? true
        respondToFailedChecks = try c.decodeIfPresent(Bool.self, forKey: .respondToFailedChecks) ?? false
        autoRebaseAndResolveConflicts = try c.decodeIfPresent(Bool.self, forKey: .autoRebaseAndResolveConflicts) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case respondToChangesRequested, respondToFailedChecks, autoRebaseAndResolveConflicts
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
        taskProvider: String? = nil,
        jiraProjectKey: String? = nil,
        jiraJQL: String? = nil,
        jiraSite: String? = nil,
        jiraStatusMap: [String: String]? = nil,
        corveilHost: String? = nil,
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
        self.taskProvider = taskProvider
        self.jiraProjectKey = jiraProjectKey
        self.jiraJQL = jiraJQL
        self.jiraSite = jiraSite
        self.jiraStatusMap = jiraStatusMap
        self.corveilHost = corveilHost
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
        taskProvider = try container.decodeIfPresent(String.self, forKey: .taskProvider)
        jiraProjectKey = try container.decodeIfPresent(String.self, forKey: .jiraProjectKey)
        jiraJQL = try container.decodeIfPresent(String.self, forKey: .jiraJQL)
        jiraSite = try container.decodeIfPresent(String.self, forKey: .jiraSite)
        jiraStatusMap = try container.decodeIfPresent([String: String].self, forKey: .jiraStatusMap)
        corveilHost = try container.decodeIfPresent(String.self, forKey: .corveilHost)
        gateway = try container.decodeIfPresent(WorkspaceGateway.self, forKey: .gateway)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, cli, host, alwaysInclude, autoReviewRepos, excludeReviewRepos, customInstructions
        case taskProvider, jiraProjectKey, jiraJQL, jiraSite, jiraStatusMap, corveilHost, gateway
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
        // The name becomes a path component under devRoot; "." / ".." would
        // resolve outside the intended directory.
        if name == "." || name == ".." {
            return "Name cannot be “.” or “..”"
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
        binaries: [String: String] = [:]
    ) {
        self.provider = provider
        self.cli = cli
        self.branchPrefix = branchPrefix
        self.excludeDirs = excludeDirs
        self.excludeReviewRepos = excludeReviewRepos
        self.excludeTicketRepos = excludeTicketRepos
        self.ignoreReviewLabels = ignoreReviewLabels
        self.binaries = binaries
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
    }

    private enum CodingKeys: String, CodingKey {
        case provider, cli, branchPrefix, excludeDirs, excludeReviewRepos, excludeTicketRepos, ignoreReviewLabels, binaries
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
}
