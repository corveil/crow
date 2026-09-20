import Foundation

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
    /// (CROW-1066; sole opt-in since CROW-1070). A per-workspace checkbox in
    /// Settings → Workspaces that **reuses this workspace's own `gateway`** for
    /// both the upload destination (`{gateway.baseURL}/api/crow-sessions/…`) and
    /// the credential (its `x-citadel-api-key`), so the operator never re-enters a
    /// Corveil key or host. `LogSyncCollector` uploads a session iff this flag is
    /// set **and** the workspace has a gateway to reuse — there is no separate
    /// master switch.
    ///
    /// The reuse is what makes browser-flippability safe: the destination +
    /// credential come only from the **local-only** `gateway` (never readable or
    /// authorable from the web, and never from any browser-writable field),
    /// so a remote peer ticking this box can at most turn one workspace's upload
    /// on/off, to the operator's own Corveil, with a credential it can neither see
    /// nor change. Default `false`.
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
        // CROW-1068: the `corveil` task provider was removed with `CorveilTaskBackend`
        // (the Corveil Tasks API it wrapped was retired, corveil/corveil#2440). A
        // legacy config still carrying it decodes to nil ("follow the code provider")
        // rather than a now-unmatched value that would silently blank the workspace's
        // board — the poll only recognizes github/gitlab/jira. The write path
        // (`WorkspaceRPC.decodeTaskProvider`) already rejects it, so this is the only
        // way an old value survives, and it's normalized on the next save.
        if taskProvider == "corveil" { taskProvider = nil }
        jiraProjectKey = try container.decodeIfPresent(String.self, forKey: .jiraProjectKey)
        jiraJQL = try container.decodeIfPresent(String.self, forKey: .jiraJQL)
        jiraSite = try container.decodeIfPresent(String.self, forKey: .jiraSite)
        jiraStatusMap = try container.decodeIfPresent([String: String].self, forKey: .jiraStatusMap)
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
        case taskProvider, jiraProjectKey, jiraJQL, jiraSite, jiraStatusMap, sessionEnv, uploadSessionLogs, gateway
    }

    /// Legal `provider` values — the code/PR hosts.
    ///
    /// Derived from ``Provider`` rather than spelled out, so a new provider case
    /// lands in the CLI's `--provider` rejection message and the `workspace-*`
    /// RPC validation without a second edit. Task-only providers (Jira) have no
    /// git surface, so they're never a code provider.
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
