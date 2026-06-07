import Foundation
import CrowCore

/// `TaskBackend` implementation for GitLab. Wraps the `glab` CLI.
///
/// Capabilities: none in v1 — GitLab issue boards aren't surfaced through Crow yet,
/// and `glab` doesn't batch issue queries the same way `gh` does.
///
/// See ADR 0005.
public struct GitLabTaskBackend: TaskBackend {
    public let provider: Provider = .gitlab
    public let capabilities: Set<TaskCapability> = []

    private let shellRunner: ShellRunner
    private let host: String?

    public init(shellRunner: ShellRunner, host: String?) {
        self.shellRunner = shellRunner
        self.host = host
    }

    public func fetchTask(url: String) async throws -> TicketInfo {
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        if parsed.isMR {
            throw ProviderError.invalidURL("fetchTask received a merge request URL: \(url)")
        }
        let env = self.env()
        let repoSlug = "\(parsed.org)/\(parsed.repo)"
        let output = try await shellRunner.run(
            args: ["glab", "issue", "view", "\(parsed.number)", "--repo", repoSlug],
            env: env,
            cwd: NSHomeDirectory()
        )
        let title = output.components(separatedBy: .newlines).first ?? "Ticket #\(parsed.number)"
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.repo,
            org: parsed.org,
            url: url,
            provider: .gitlab,
            isMR: false
        )
    }

    public func listAssigned(includeClosed: Bool) async throws -> AssignedListing {
        // GitLab has no consolidated batched endpoint. One REST call for open;
        // a second only when `includeClosed` is true (the GitHub-driven
        // closed-issue diff in IssueTracker doesn't consume the GitLab half,
        // so the default GitLab caller passes false to skip the wasted
        // round-trip every poll).
        // Use `glab api` rather than `glab issue list` — the latter shells out
        // to `git` even when no repo is involved and aborts with "fatal: not
        // a git repository" when cwd isn't a git working tree.
        let openOut: String
        do {
            openOut = try await shellRunner.run(
                args: ["glab", "api", "issues?scope=assigned_to_me&state=opened&per_page=100"],
                env: env(),
                cwd: NSHomeDirectory()
            )
        } catch {
            // Match the prior best-effort semantics: return empty rather than throwing.
            return AssignedListing(open: [], closed: [])
        }
        let open = Self.parseIssues(openOut, host: host ?? "", projectStatusOverride: nil)

        guard includeClosed else {
            return AssignedListing(open: open, closed: [])
        }

        let updatedAfter = Self.updatedAfterString()
        let closedOut: String
        do {
            closedOut = try await shellRunner.run(
                args: ["glab", "api", "issues?scope=assigned_to_me&state=closed&per_page=50&updated_after=\(updatedAfter)"],
                env: env(),
                cwd: NSHomeDirectory()
            )
        } catch {
            // If the closed query fails, fall back to whatever open we got.
            return AssignedListing(open: open, closed: [])
        }
        let closed = Self.parseIssues(closedOut, host: host ?? "", projectStatusOverride: .done)
        return AssignedListing(open: open, closed: closed)
    }

    public func setLabels(url: String, add: [String], remove: [String]) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        let repoSlug = "\(parsed.org)/\(parsed.repo)"
        let env = self.env()
        var args: [String] = ["glab", "issue", "update", "\(parsed.number)", "--repo", repoSlug]
        if !add.isEmpty {
            args.append("--label")
            args.append(add.joined(separator: ","))
        }
        if !remove.isEmpty {
            args.append("--unlabel")
            args.append(remove.joined(separator: ","))
        }
        _ = try await shellRunner.run(args: args, env: env, cwd: NSHomeDirectory())
    }

    public func setTaskStatus(url: String, status: TicketStatus) async throws {
        // No project board support declared. Capability-gated callers won't hit this;
        // anything that does is a programming error.
        throw ProviderError.unimplemented("GitLabTaskBackend.setTaskStatus: no projectBoardStatus capability")
    }

    public func assign(url: String, to login: String) async throws {
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        let repoSlug = "\(parsed.org)/\(parsed.repo)"
        _ = try await shellRunner.run(
            args: ["glab", "issue", "update", "\(parsed.number)", "--repo", repoSlug, "--assignee", login],
            env: env(),
            cwd: NSHomeDirectory()
        )
    }

    public func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo {
        var args: [String] = [
            "glab", "issue", "create",
            "--repo", repo,
            "--title", title,
            "--description", body
        ]
        if !labels.isEmpty {
            args.append("--label")
            args.append(labels.joined(separator: ","))
        }
        let output = try await shellRunner.run(args: args, env: env(), cwd: NSHomeDirectory())
        // `glab issue create` prints the new issue URL on stdout.
        let url = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://") } ?? ""
        guard !url.isEmpty,
              let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.commandFailed("glab issue create did not return a parseable URL; got: \(output)")
        }
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.repo,
            org: parsed.org,
            url: url,
            provider: .gitlab,
            isMR: false
        )
    }

    // MARK: - Helpers

    private func env() -> [String: String] {
        guard let host else { return [:] }
        return ["GITLAB_HOST": host]
    }

    /// GitLab's `updated_after` accepts ISO8601. Use 24h ago to match
    /// GitHub's `closed:>=YYYY-MM-DD` window for closed-issue diffing.
    static func updatedAfterString() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date().addingTimeInterval(-86400))
    }

    static func parseIssues(_ output: String, host: String, projectStatusOverride: TicketStatus?) -> [AssignedIssue] {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item -> AssignedIssue? in
            guard let number = item["iid"] as? Int,
                  let title = item["title"] as? String,
                  let url = item["web_url"] as? String else { return nil }
            let state = item["state"] as? String ?? "opened"
            let labels = (item["labels"] as? [String] ?? []).map { LabelInfo(name: $0) }
            let refs = item["references"] as? [String: Any]
            let fullRef = refs?["full"] as? String ?? ""
            return AssignedIssue(
                id: "gitlab:\(host):\(fullRef)",
                number: number,
                title: title,
                state: state == "opened" ? "open" : state,
                url: url,
                repo: fullRef,
                labels: labels,
                provider: .gitlab,
                projectStatus: projectStatusOverride ?? .unknown
            )
        }
    }
}
