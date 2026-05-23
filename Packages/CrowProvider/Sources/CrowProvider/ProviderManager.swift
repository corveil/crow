import Foundation
import CrowCore

/// Detects provider from URL and fetches ticket details.
public actor ProviderManager {
    /// Additional GitLab hosts beyond gitlab.com (user-configurable).
    private let additionalGitLabHosts: [String]

    public init(additionalGitLabHosts: [String] = []) {
        self.additionalGitLabHosts = additionalGitLabHosts
    }

    /// Detect provider from a URL string.
    ///
    /// Falls back to `.github` for unrecognized hosts — the `gh` CLI call will fail clearly
    /// if the URL is actually a self-hosted GitLab instance, which is an acceptable failure mode.
    public func detectProvider(from url: String) -> (provider: Provider, cli: String, host: String?) {
        if url.contains("github.com") {
            return (.github, "gh", nil)
        } else if url.contains("gitlab.com") {
            return (.gitlab, "glab", "gitlab.com")
        }
        // Check user-configured GitLab hosts
        for host in additionalGitLabHosts {
            if url.contains(host) {
                return (.gitlab, "glab", host)
            }
        }
        return (.github, "gh", nil)
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

    /// Fetch ticket details using gh/glab CLI.
    public func fetchTicket(url: String) async throws -> TicketInfo {
        let detected = detectProvider(from: url)
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

    /// Expand a workspace's repo specs into a sorted, de-duplicated list of
    /// `owner/repo` slugs.
    ///
    /// Each spec is either a glob (`owner/*` — list every repo owned by `owner`
    /// via the provider) or an explicit slug (`owner/repo` — passed through
    /// verbatim). Used to populate the Jobs form's repo picker from a
    /// workspace's `alwaysInclude` entries.
    public func reposForSpecs(_ specs: [String], provider: Provider, host: String?) async -> [String] {
        var slugs: Set<String> = []
        for spec in specs {
            switch Self.classifySpec(spec) {
            case .glob(let owner):
                for slug in await listRepos(owner: owner, provider: provider, host: host) {
                    slugs.insert(slug)
                }
            case .explicit(let slug):
                slugs.insert(slug)
            case .invalid:
                continue
            }
        }
        return slugs.sorted()
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
}

public enum ProviderError: Error {
    case invalidURL(String)
    case commandFailed(String)
}
