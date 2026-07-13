import Foundation
import CrowCore

/// Detects provider from URL and fetches ticket details.
///
/// Also acts as a factory for ``TaskBackend`` / ``CodeBackend`` instances — call
/// ``taskBackend(for:host:)`` or ``codeBackend(for:host:)`` to get a provider-
/// specific backend rather than switching on `Provider` at the call site. See ADR 0005.
public actor ProviderManager {
    /// Additional GitLab hosts beyond gitlab.com (user-configurable).
    nonisolated private let additionalGitLabHosts: [String]
    /// Additional Corveil hosts beyond corveil.io (user-configurable per
    /// workspace via `WorkspaceInfo.corveilHost`). URL detection routes any
    /// match here to `.corveil`.
    nonisolated private let additionalCorveilHosts: [String]

    /// Subprocess runner shared by all backends this manager hands out.
    nonisolated private let shellRunner: ShellRunner

    public init(
        additionalGitLabHosts: [String] = [],
        additionalCorveilHosts: [String] = [],
        shellRunner: ShellRunner = ProcessShellRunner()
    ) {
        self.additionalGitLabHosts = additionalGitLabHosts
        self.additionalCorveilHosts = additionalCorveilHosts
        self.shellRunner = shellRunner
    }

    // MARK: - Backend factory

    /// Hand out a ``TaskBackend`` for the given provider. Use the URL-based
    /// variant when only a ticket URL is in hand.
    public nonisolated func taskBackend(
        for provider: Provider,
        host: String? = nil,
        jira: JiraConfig? = nil,
        corveil: CorveilConfig? = nil
    ) -> TaskBackend {
        switch provider {
        case .github:
            return GitHubTaskBackend(shellRunner: shellRunner)
        case .gitlab:
            return GitLabTaskBackend(shellRunner: shellRunner, host: host)
        case .corveil:
            return CorveilTaskBackend(shellRunner: shellRunner, config: corveil ?? CorveilConfig())
        case .jira:
            return JiraTaskBackend(shellRunner: shellRunner, config: jira ?? JiraConfig())
        }
    }

    /// Hand out a ``CodeBackend`` for the given provider, or `nil` for providers
    /// that have no VCS-side surface (Corveil). Callers must handle `nil` —
    /// a non-coding task may legitimately have no code backend at all.
    public nonisolated func codeBackend(for provider: Provider, host: String? = nil) -> CodeBackend? {
        switch provider {
        case .github:
            return GitHubCodeBackend(shellRunner: shellRunner)
        case .gitlab:
            return GitLabCodeBackend(shellRunner: shellRunner, host: host)
        case .corveil, .jira:
            // Task-only providers — no VCS surface. A Jira-tasked session pairs
            // with a GitHub/GitLab code backend via `Session.codeProvider`.
            return nil
        }
    }

    /// Probe `acli` availability for the Jira backend. Delegates to
    /// `AcliProbe` (CrowCore) so the same check backs the Settings UI picker.
    public nonisolated func jiraAvailability() async -> JiraAvailability {
        await AcliProbe.availability(shellRunner: shellRunner)
    }

    /// URL-driven `TaskBackend` lookup — detect the provider from `url` and
    /// hand back the matching backend.
    public nonisolated func taskBackend(forURL url: String) -> TaskBackend {
        let detected = Self.detect(url: url, additionalGitLabHosts: additionalGitLabHosts, additionalCorveilHosts: additionalCorveilHosts)
        return taskBackend(for: detected.provider, host: detected.host)
    }

    /// Single source of truth for URL → provider detection. The actor-isolated
    /// ``detectProvider(from:)`` and the nonisolated factory paths both delegate
    /// here so the matching logic can never drift.
    nonisolated static func detect(
        url: String,
        additionalGitLabHosts: [String],
        additionalCorveilHosts: [String] = []
    ) -> (provider: Provider, cli: String, host: String?) {
        if url.contains("github.com") {
            return (.github, "gh", nil)
        } else if Validation.isJiraSpec(url) {
            // Jira — task-only, driven by `acli`. An Atlassian host, a `/browse/`
            // URL with a valid key, or a bare `PROJ-123`. Checked before the
            // loose GitLab matching so a Jira spec isn't misrouted.
            return (.jira, "acli", nil)
        } else if url.contains("gitlab.com") {
            return (.gitlab, "glab", "gitlab.com")
        } else if url.contains("corveil.io") {
            // Public corveil.io — task-only, driven by `corveil`. See ADR 0005.
            return (.corveil, "corveil", nil)
        }
        for host in additionalCorveilHosts where !host.isEmpty && url.contains(host) {
            return (.corveil, "corveil", host)
        }
        for host in additionalGitLabHosts {
            if url.contains(host) {
                return (.gitlab, "glab", host)
            }
        }
        return (.github, "gh", nil)
    }

    /// Detect provider from a URL string.
    ///
    /// Falls back to `.github` for unrecognized hosts — the `gh` CLI call will fail clearly
    /// if the URL is actually a self-hosted GitLab instance, which is an acceptable failure mode.
    public func detectProvider(from url: String) -> (provider: Provider, cli: String, host: String?) {
        Self.detect(url: url, additionalGitLabHosts: additionalGitLabHosts, additionalCorveilHosts: additionalCorveilHosts)
    }

    /// Parse issue/PR number and repo from a ticket URL.
    ///
    /// Supported formats:
    /// - GitHub issue: `https://github.com/{org}/{repo}/issues/{number}`
    /// - GitHub PR:    `https://github.com/{org}/{repo}/pull/{number}`
    /// - GitLab issue: `https://{host}/{org}/{repo}/-/issues/{number}`
    /// - GitLab MR:    `https://{host}/{org}/{repo}/-/merge_requests/{number}`
    ///
    /// - Returns: A tuple of `(org, repo, number, isMR)` where `isMR` is true for pull requests
    ///   and merge requests, or `nil` if the URL doesn't match a supported format.
    public func parseTicketURL(_ url: String) -> (org: String, repo: String, number: Int, isMR: Bool)? {
        Self.parseTicketURLComponents(url)
    }

    /// Static variant of ``parseTicketURL(_:)`` usable without an actor instance.
    public static func parseTicketURLComponents(_ url: String) -> (org: String, repo: String, number: Int, isMR: Bool)? {
        // split(separator:) omits empty subsequences, so "https://host/..." becomes:
        // ["https:", "host", "org", "repo", ...]
        // Jira: https://<site>.atlassian.net/browse/PROJ-123 (or a bare PROJ-123).
        // The project key stands in for both org and repo; the numeric suffix is
        // the issue number. The full key is recoverable as "\(org)-\(number)".
        if Validation.isJiraSpec(url), let jira = Validation.parseJiraKey(url) {
            return (jira.project, jira.project, jira.number, false)
        }

        let parts = url.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }

        if url.contains("github.com") {
            // ["https:", "github.com", org, repo, "issues"|"pull", number]
            guard parts.count >= 6,
                  let number = Int(parts[parts.count - 1]) else { return nil }
            let org = parts[2]
            let repo = parts[3]
            let isMR = parts[parts.count - 2] == "pull"
            return (org, repo, number, isMR)
        } else {
            // GitLab: ["https:", host, org, repo, "-", "issues"|"merge_requests", number]
            guard parts.count >= 7,
                  let number = Int(parts[parts.count - 1]) else { return nil }
            let org = parts[2]
            let repo = parts[3]
            let isMR = parts[parts.count - 2] == "merge_requests"
            return (org, repo, number, isMR)
        }
    }

    /// Fetch ticket details using gh/glab/acli CLI.
    public func fetchTicket(url: String) async throws -> TicketInfo {
        let detected = detectProvider(from: url)

        // Jira parses keys, not org/repo/number paths, and its JSON nests the
        // title under `fields.summary` — delegate to the backend rather than the
        // shared gh/glab title extraction below.
        if detected.provider == .jira {
            return try await taskBackend(for: .jira).fetchTask(url: url)
        }
        // Corveil ids aren't org/repo/number tuples either; delegate to its
        // backend the same way Jira does.
        if detected.provider == .corveil {
            return try await taskBackend(for: .corveil).fetchTask(url: url)
        }

        guard let parsed = parseTicketURL(url) else {
            throw ProviderError.invalidURL(url)
        }

        let output: String
        switch detected.provider {
        case .github:
            if parsed.isMR {
                output = try await shell("gh", "pr", "view", url, "--json", "title,body,labels")
            } else {
                output = try await shell("gh", "issue", "view", url, "--json", "title,body,labels")
            }
        case .gitlab:
            var env: [String: String] = [:]
            if let host = detected.host {
                env["GITLAB_HOST"] = host
            }
            let repoSlug = "\(parsed.org)/\(parsed.repo)"
            if parsed.isMR {
                output = try await shell(env: env, cwd: NSHomeDirectory(), "glab", "mr", "view", "\(parsed.number)", "--repo", repoSlug)
            } else {
                output = try await shell(env: env, cwd: NSHomeDirectory(), "glab", "issue", "view", "\(parsed.number)", "--repo", repoSlug)
            }
        case .corveil:
            // Handled by the early return above (delegated to CorveilTaskBackend).
            throw ProviderError.unimplemented("unreachable: Corveil handled before the switch")
        case .jira:
            // Handled by the early return above (delegated to JiraTaskBackend).
            throw ProviderError.unimplemented("unreachable: Jira handled before the switch")
        }

        // Parse title from JSON output (GitHub returns JSON, GitLab returns text)
        let title = extractTitle(from: output) ?? "Ticket #\(parsed.number)"

        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.repo,
            org: parsed.org,
            url: url,
            provider: detected.provider,
            isMR: parsed.isMR
        )
    }

    // MARK: - Repo listing (Jobs repo picker)

    /// Expand a workspace's repo specs into resolved `owner/repo` slugs plus any
    /// specs that couldn't be resolved.
    ///
    /// Each spec is either a glob (`owner/*` — list every repo owned by `owner`
    /// via the provider), an explicit slug (`owner/repo` — passed through
    /// verbatim), or invalid. Invalid specs (e.g. a bare org name like
    /// `securityscorecard`) are *surfaced* in `invalidSpecs` — with a suggested
    /// fix when there is one — rather than silently dropped, so the Jobs form's
    /// repo picker can explain why it's empty.
    public func reposForSpecs(_ specs: [String], provider: Provider, host: String?) async -> WorkspaceRepoListing {
        var slugs: Set<String> = []
        var invalid: [WorkspaceRepoListing.InvalidSpec] = []
        for spec in specs {
            switch Self.classifySpec(spec) {
            case .glob(let owner):
                for slug in await listRepos(owner: owner, provider: provider, host: host) {
                    slugs.insert(slug)
                }
            case .explicit(let slug):
                slugs.insert(slug)
            case .invalid:
                // Skip whitespace-only entries so the UI never shows "'' is invalid".
                guard !spec.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                invalid.append(
                    .init(raw: spec, suggestion: Self.suggestion(forInvalidSpec: spec))
                )
            }
        }
        return WorkspaceRepoListing(repos: slugs.sorted(), invalidSpecs: invalid)
    }

    /// List every repo owned by `owner` as `owner/repo` slugs.
    ///
    /// Shells out to the provider CLI. Returns `[]` (logged) on any failure so
    /// the form degrades to an empty picker rather than throwing.
    public func listRepos(owner: String, provider: Provider, host: String?) async -> [String] {
        do {
            switch provider {
            case .github:
                let out = try await shell(
                    "gh", "repo", "list", owner,
                    "--limit", "1000", "--json", "nameWithOwner", "--jq", ".[].nameWithOwner"
                )
                return Self.nonEmptyLines(out)
            case .gitlab:
                var env: [String: String] = [:]
                if let host { env["GITLAB_HOST"] = host }
                // GitLab's group-by-path endpoint needs the full group path
                // URL-encoded (`group/sub` → `group%2Fsub`); the raw slash 404s.
                let encodedOwner = Self.encodeGitLabGroupPath(owner)
                let out = try await shell(
                    env: env, cwd: NSHomeDirectory(),
                    "glab", "api", "--paginate",
                    "groups/\(encodedOwner)/projects?per_page=100&include_subgroups=true",
                    "--jq", ".[].path_with_namespace"
                )
                return Self.nonEmptyLines(out)
            case .corveil, .jira:
                // Task-only providers; no repo listing is meaningful here.
                return []
            }
        } catch {
            NSLog("[ProviderManager] listRepos failed for owner '\(owner)': \(error.localizedDescription)")
            return []
        }
    }

    /// How a repo spec resolves: a glob over an owner, an explicit slug, or unusable.
    enum RepoSpec: Equatable {
        case glob(owner: String)
        case explicit(slug: String)
        case invalid
    }

    /// Classify a raw `alwaysInclude` entry. `owner/*` → glob; `owner/repo`
    /// (or deeper, e.g. GitLab nested groups) → explicit slug; anything else
    /// (empty, or a bare name with no owner) → invalid.
    nonisolated static func classifySpec(_ raw: String) -> RepoSpec {
        let spec = raw.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return .invalid }
        if spec.hasSuffix("/*") {
            let owner = String(spec.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return owner.isEmpty ? .invalid : .glob(owner: owner)
        }
        // A usable explicit entry needs an owner and a repo (at least one "/").
        guard spec.contains("/"), !spec.contains("*") else { return .invalid }
        return .explicit(slug: spec)
    }

    /// Suggest a clean fix for an invalid spec, or `nil` if there isn't an
    /// obvious one. A bare org name (no `/`, no `*`) is almost always meant as
    /// "every repo in this org", so we suggest `<name>/*`.
    nonisolated static func suggestion(forInvalidSpec raw: String) -> String? {
        let spec = raw.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty, !spec.contains("/"), !spec.contains("*") else { return nil }
        return "\(spec)/*"
    }

    private static func nonEmptyLines(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Percent-encode a GitLab group path for the `groups/:id` API, where the
    /// id may be a path like `group/sub` that must arrive as `group%2Fsub`.
    /// Group paths are otherwise `[A-Za-z0-9_.-]`, so encoding the separators is
    /// sufficient.
    nonisolated static func encodeGitLabGroupPath(_ owner: String) -> String {
        owner.replacingOccurrences(of: "/", with: "%2F")
    }

    private func extractTitle(from output: String) -> String? {
        // Try JSON first (GitHub gh output)
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = json["title"] as? String {
            return title
        }
        // Fallback: first line of output (GitLab glab output)
        return output.components(separatedBy: .newlines).first
    }

    private func shell(env: [String: String] = [:], cwd: String? = nil, _ args: String...) async throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.environment = env.isEmpty
            ? ShellEnvironment.shared.env
            : ShellEnvironment.shared.merging(env)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw ProviderError.commandFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Details about a ticket (issue or PR/MR) fetched from a provider.
public struct TicketInfo: Sendable {
    public let number: Int
    public let title: String
    public let repo: String
    public let org: String
    public let url: String
    public let provider: Provider
    public let isMR: Bool
    /// Normalized ticket priority (#696, ADR 0008 follow-up 8). Only Jira
    /// surfaces one today; nil for GitHub/GitLab/Corveil tickets.
    public let priority: TicketPriority?
    /// Epic/parent work-item key (Jira Cloud unified `parent` field). Fetched
    /// for future epic-based goal inference; unused by the v1 alignment weight.
    public let parentKey: String?

    public init(
        number: Int, title: String, repo: String, org: String, url: String,
        provider: Provider, isMR: Bool,
        priority: TicketPriority? = nil, parentKey: String? = nil
    ) {
        self.number = number
        self.title = title
        self.repo = repo
        self.org = org
        self.url = url
        self.provider = provider
        self.isMR = isMR
        self.priority = priority
        self.parentKey = parentKey
    }
}

public enum ProviderError: Error {
    case invalidURL(String)
    case commandFailed(String)
    /// A backend method is part of the protocol but not implemented for this provider yet
    /// (e.g. a capability-gated method on a backend without the capability). See ADR 0005.
    case unimplemented(String)
    /// GitHub `INSUFFICIENT_SCOPES` — the OAuth token is missing a required scope
    /// (typically `read:project`). Surfaced as a typed error so call sites can
    /// route to the existing scope-warning UI instead of treating it as a hard
    /// failure. The associated value is the missing scope name.
    case insufficientScope(String)
    /// GitHub GraphQL `RATE_LIMITED`. Callers should skip the cycle and retry
    /// after the documented reset time.
    case rateLimited(String)
    /// GitHub org SAML enforcement on an org the OAuth token isn't authorized
    /// for. GitHub returns the issues/PRs that *did* resolve from accessible
    /// orgs in `data`, alongside a `FORBIDDEN`/SAML entry in `errors`; `gh`
    /// then exits non-zero. The associated value is the FULL merged `gh`
    /// output blob (partial JSON body + the trailing `gh:` error line) so
    /// call sites can recover the accessible-org data instead of dropping the
    /// whole cycle. See `GitHubTaskBackend.recoverPartialIssues`.
    case samlRestricted(String)
}
