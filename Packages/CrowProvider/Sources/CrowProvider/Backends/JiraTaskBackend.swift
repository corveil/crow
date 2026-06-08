import Foundation
import CrowCore

/// Per-workspace Jira configuration threaded into ``JiraTaskBackend``.
///
/// `acli` is already authenticated against a single Atlassian site, so none of
/// these are required to *call* Jira — they only refine behavior:
/// - `site`: the Atlassian site host (e.g. `acme.atlassian.net`) used to build
///   user-facing `…/browse/KEY` URLs. acli's JSON omits the browse URL (it only
///   returns an internal REST `self` host), so without a site we fall back to
///   the bare key for the URL.
/// - `projectKey`: default project for `createTask` when the caller doesn't pass one.
/// - `jql`: overrides the "my open tickets" query used by `listAssigned`.
public struct JiraConfig: Sendable, Equatable {
    public let site: String?
    public let projectKey: String?
    public let jql: String?

    public init(site: String? = nil, projectKey: String? = nil, jql: String? = nil) {
        self.site = site
        self.projectKey = projectKey
        self.jql = jql
    }
}

/// `TaskBackend` implementation for Atlassian Jira. Wraps the `acli` CLI.
///
/// Jira is a **task-only** provider (no embedded git) — exactly the "task tracker
/// with no code surface" shape ADR 0005 carved out, today represented only by the
/// `StubCorveilTaskBackend`. A Jira-tasked session pairs with a GitHub/GitLab
/// `CodeBackend` (resolved via `Session.codeProvider`); `ProviderManager.codeBackend(.jira)`
/// returns `nil`.
///
/// Capabilities: `.projectBoardStatus` — Jira workflow transitions are a real
/// status concept, wired through `setTaskStatus` via `acli jira workitem transition`.
/// Not `.batchedQuery` — `acli` has no consolidated multi-item endpoint.
///
/// See ADR 0005.
public struct JiraTaskBackend: TaskBackend {
    public let provider: Provider = .jira
    public let capabilities: Set<TaskCapability> = [.projectBoardStatus]

    private let shellRunner: ShellRunner
    private let config: JiraConfig

    /// Default "my open tickets" query. Overridable per-workspace via `JiraConfig.jql`.
    static let defaultOpenJQL = "assignee = currentUser() AND statusCategory != Done"
    /// Recently-closed half, mirroring the 24h window GitHub/GitLab use for
    /// closed-issue removal detection in IssueTracker.
    static let closedJQL = "assignee = currentUser() AND statusCategory = Done AND updated >= -1d"

    public init(shellRunner: ShellRunner, config: JiraConfig = JiraConfig()) {
        self.shellRunner = shellRunner
        self.config = config
    }

    // MARK: - TaskBackend

    public func fetchTask(url: String) async throws -> TicketInfo {
        guard let parsed = JiraKey.parse(url) else {
            throw ProviderError.invalidURL(url)
        }
        let output = try await run([
            "acli", "jira", "workitem", "view", parsed.key,
            "--json", "--fields", "summary,status,description,comment,assignee",
        ])
        let fields = Self.firstFields(output)
        let title = (fields?["summary"] as? String) ?? "Ticket \(parsed.key)"
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.project,
            org: parsed.project,
            url: browseURL(for: parsed.key) ?? url,
            provider: .jira,
            isMR: false
        )
    }

    public func listAssigned(includeClosed: Bool) async throws -> AssignedListing {
        let jql = config.jql ?? Self.defaultOpenJQL
        let open: [AssignedIssue]
        do {
            let openOut = try await search(jql: jql, limit: 100)
            open = Self.parseAssigned(openOut, site: config.site, statusOverride: nil)
        } catch {
            // Match GitLab's degrade-to-empty semantics rather than throwing.
            return AssignedListing(open: [], closed: [])
        }

        guard includeClosed else {
            return AssignedListing(open: open, closed: [])
        }

        let closed: [AssignedIssue]
        do {
            let closedOut = try await search(jql: Self.closedJQL, limit: 50)
            closed = Self.parseAssigned(closedOut, site: config.site, statusOverride: .done)
        } catch {
            return AssignedListing(open: open, closed: [])
        }
        return AssignedListing(open: open, closed: closed)
    }

    public func setLabels(url: String, add: [String], remove: [String]) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        guard let parsed = JiraKey.parse(url) else { throw ProviderError.invalidURL(url) }
        // Note: acli's `--labels` edits the label set by name; Crow uses this to
        // add a tracking label, which acli applies additively. `--remove-labels`
        // removes the named labels.
        var args = ["acli", "jira", "workitem", "edit", "--key", parsed.key]
        if !add.isEmpty {
            args.append("--labels")
            args.append(add.joined(separator: ","))
        }
        if !remove.isEmpty {
            args.append("--remove-labels")
            args.append(remove.joined(separator: ","))
        }
        args.append("--yes")
        _ = try await run(args)
    }

    public func setTaskStatus(url: String, status: TicketStatus) async throws {
        guard let parsed = JiraKey.parse(url) else { throw ProviderError.invalidURL(url) }
        _ = try await run([
            "acli", "jira", "workitem", "transition",
            "--key", parsed.key,
            "--status", Self.jiraStatusName(for: status),
            "--yes",
        ])
    }

    public func assign(url: String, to login: String) async throws {
        guard let parsed = JiraKey.parse(url) else { throw ProviderError.invalidURL(url) }
        _ = try await run([
            "acli", "jira", "workitem", "assign",
            "--key", parsed.key,
            "--assignee", login,
        ])
    }

    public func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo {
        // For Jira the `repo` slug carries the project key. Fall back to the
        // workspace-configured default project when the caller passes none.
        let project = repo.isEmpty ? (config.projectKey ?? "") : repo
        guard !project.isEmpty else {
            throw ProviderError.commandFailed("createTask: no Jira project key (pass `repo` or configure a default project)")
        }
        var args = [
            "acli", "jira", "workitem", "create",
            "--project", project,
            "--type", "Task",
            "--summary", title,
            "--description", body,
        ]
        if !labels.isEmpty {
            args.append("--label")
            args.append(labels.joined(separator: ","))
        }
        args.append("--json")
        let output = try await run(args)

        // `create --json` returns the new work item; pull its key out.
        guard let key = Self.firstKey(output) ?? Self.scrapeKey(output),
              let parsed = JiraKey.parse(key) else {
            throw ProviderError.commandFailed("acli jira workitem create did not return a parseable key; got: \(output)")
        }
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.project,
            org: parsed.project,
            url: browseURL(for: parsed.key) ?? parsed.key,
            provider: .jira,
            isMR: false
        )
    }

    // MARK: - Helpers

    private func search(jql: String, limit: Int) async throws -> String {
        try await run([
            "acli", "jira", "workitem", "search",
            "--jql", jql,
            "--json",
            "--fields", "key,summary,status,assignee",
            "--limit", "\(limit)",
        ])
    }

    /// Run an `acli` invocation, translating shell failures into typed
    /// `ProviderError`s and giving a clear hint when acli isn't authenticated.
    private func run(_ args: [String]) async throws -> String {
        do {
            return try await shellRunner.run(args: args, env: [:], cwd: NSHomeDirectory())
        } catch let ShellRunnerError.nonZeroExit(_, output) {
            if Self.looksUnauthenticated(output) {
                throw ProviderError.commandFailed("acli is not authenticated — run `acli jira auth login`. (\(output))")
            }
            throw ProviderError.commandFailed(output)
        }
    }

    private func browseURL(for key: String) -> String? {
        guard let site = config.site, !site.isEmpty else { return nil }
        let host = site.hasPrefix("http") ? site : "https://\(site)"
        return "\(host)/browse/\(key)"
    }

    static func looksUnauthenticated(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("auth login")
            || lower.contains("not authenticated")
            || lower.contains("unauthorized")
            || lower.contains("please login")
    }

    /// Map a Crow pipeline status to a Jira workflow status name. `TicketStatus`
    /// raw values already match common Jira names ("In Progress", "In Review",
    /// "Done", "Backlog"); only `.ready` needs a Jira-flavored alias.
    ///
    /// Best-effort: Jira workflow status names are configurable per project, so a
    /// transition can still legitimately fail if a project renames its statuses.
    static func jiraStatusName(for status: TicketStatus) -> String {
        switch status {
        case .ready: return "To Do"
        case .backlog, .inProgress, .inReview, .done, .unknown:
            return status.rawValue
        }
    }

    // MARK: - JSON parsing

    /// acli emits a JSON array of work items even for single-item `view`. Return
    /// the `fields` dict of the first element (or of a bare object, defensively).
    static func firstFields(_ output: String) -> [String: Any]? {
        guard let obj = firstObject(output) else { return nil }
        return obj["fields"] as? [String: Any]
    }

    static func firstKey(_ output: String) -> String? {
        firstObject(output)?["key"] as? String
    }

    private static func firstObject(_ output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let arr = json as? [[String: Any]] { return arr.first }
        if let obj = json as? [String: Any] { return obj }
        return nil
    }

    /// Fallback when `create --json` returns non-JSON: scrape the first KEY-123
    /// token out of the output.
    static func scrapeKey(_ output: String) -> String? {
        let pattern = #"[A-Z][A-Z0-9]+-\d+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    static func parseAssigned(_ output: String, site: String?, statusOverride: TicketStatus?) -> [AssignedIssue] {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item -> AssignedIssue? in
            guard let key = item["key"] as? String,
                  let parsed = JiraKey.parse(key) else { return nil }
            let fields = item["fields"] as? [String: Any]
            let title = (fields?["summary"] as? String) ?? key
            let statusDict = fields?["status"] as? [String: Any]
            let statusName = statusDict?["name"] as? String ?? ""
            let categoryKey = (statusDict?["statusCategory"] as? [String: Any])?["key"] as? String ?? ""
            let status = statusOverride ?? TicketStatus(projectBoardName: statusName)
            let state = (statusOverride == .done || categoryKey == "done") ? "closed" : "open"
            let url = site.flatMap { s -> String? in
                let host = s.hasPrefix("http") ? s : "https://\(s)"
                return "\(host)/browse/\(parsed.key)"
            } ?? parsed.key
            return AssignedIssue(
                id: "jira:\(parsed.key)",
                number: parsed.number,
                title: title,
                state: state,
                url: url,
                repo: parsed.project,
                labels: [],
                provider: .jira,
                projectStatus: status
            )
        }
    }
}

/// Parses Jira work-item keys out of either a browse URL or a bare key.
///
/// Accepts `https://<site>.atlassian.net/browse/PROJ-123` (with optional query/
/// fragment) or a bare `PROJ-123`. Splits on the **last** `-` so multi-segment
/// project keys survive, returning the project prefix, the numeric suffix, and
/// the normalized key.
enum JiraKey {
    static func parse(_ spec: String) -> (project: String, number: Int, key: String)? {
        var token = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = token.range(of: "/browse/") {
            token = String(token[r.upperBound...])
        }
        // Strip any trailing path / query / fragment.
        if let slash = token.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            token = String(token[..<slash])
        }
        guard let dash = token.lastIndex(of: "-") else { return nil }
        let project = String(token[..<dash])
        let numberStr = String(token[token.index(after: dash)...])
        guard !project.isEmpty, let number = Int(numberStr) else { return nil }
        return (project, number, "\(project)-\(number)")
    }
}
