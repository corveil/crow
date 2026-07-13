import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLResponse/URLSession live here on Linux
#endif
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
    /// Per-workspace Crow→Jira status-name overrides, keyed by ``TicketStatus``
    /// raw value (e.g. "In Progress" → "In Development"). A missing/blank entry
    /// falls back to ``JiraTaskBackend/defaultJiraStatusName(for:)``. See #523.
    public let statusMap: [String: String]?
    /// HTTP Basic `Authorization` header (e.g. `Basic …` from
    /// ``JiraCredentialResolver``) for the Jira Cloud REST transition path (#529).
    /// When set (together with `site`), `setTaskStatus`/`closeTask` transition via
    /// ``JiraTransitionClient`` — fetching available transitions and degrading
    /// gracefully — instead of `acli`. Nil falls back to the legacy `acli` path.
    public let authorization: String?

    public init(site: String? = nil, projectKey: String? = nil, jql: String? = nil, statusMap: [String: String]? = nil, authorization: String? = nil) {
        self.site = site
        self.projectKey = projectKey
        self.jql = jql
        self.statusMap = statusMap
        self.authorization = authorization
    }
}

/// `TaskBackend` implementation for Atlassian Jira. Wraps the `acli` CLI.
///
/// Jira is a **task-only** provider (no embedded git) — exactly the "task tracker
/// with no code surface" shape ADR 0005 carved out, today shared with
/// `CorveilTaskBackend`. A Jira-tasked session pairs with a GitHub/GitLab
/// `CodeBackend` (resolved via `Session.codeProvider`); `ProviderManager.codeBackend(.jira)`
/// returns `nil`.
///
/// Capabilities: `.projectBoardStatus` — Jira workflow transitions are a real
/// status concept, wired through `setTaskStatus`. When a REST credential is
/// configured (``JiraConfig/authorization`` + `site`) transitions go via the
/// Jira Cloud REST API (``JiraTransitionClient``, #529); otherwise they fall
/// back to `acli jira workitem transition`. Not `.batchedQuery` — `acli` has no
/// consolidated multi-item endpoint.
///
/// See ADR 0005.
public struct JiraTaskBackend: TaskBackend {
    public let provider: Provider = .jira
    public let capabilities: Set<TaskCapability> = [.projectBoardStatus]

    private let shellRunner: ShellRunner
    private let config: JiraConfig
    /// HTTP transport for the REST transition path (#529); injectable for tests.
    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// Default "my open tickets" query. Overridable per-workspace via `JiraConfig.jql`.
    static let defaultOpenJQL = "assignee = currentUser() AND statusCategory != Done"
    /// Recently-closed half, mirroring the 24h window GitHub/GitLab use for
    /// closed-issue removal detection in IssueTracker.
    static let closedJQL = "assignee = currentUser() AND statusCategory = Done AND updated >= -1d"
    /// Page cap for the recently-closed half. The listing's `closedTotalCount`
    /// comes from a separate count query so the done-in-24h badge doesn't
    /// saturate at this cap (#572, mirroring GitHub's #562 fix).
    static let closedPageLimit = 50

    public init(
        shellRunner: ShellRunner,
        config: JiraConfig = JiraConfig(),
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
    ) {
        self.shellRunner = shellRunner
        self.config = config
        self.transport = transport
    }

    // MARK: - TaskBackend

    public func fetchTask(url: String) async throws -> TicketInfo {
        guard let parsed = JiraKey.parse(url) else {
            throw ProviderError.invalidURL(url)
        }
        let output = try await run([
            "acli", "jira", "workitem", "view", parsed.key,
            "--json", "--fields", "summary,status,description,comment,assignee,priority,parent",
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
            isMR: false,
            priority: Self.priorityName(fields).map { TicketPriority(jiraName: $0) },
            parentKey: Self.parentInfo(fields).key
        )
    }

    public func listAssigned(includeClosed: Bool) async throws -> AssignedListing {
        let openJQL = config.jql ?? Self.defaultOpenJQL

        // REST-preferred (#533): when a Jira Cloud credential is configured, read
        // assigned issues over the REST API — same auth the transition write path
        // (#529) uses — so the board read-back doesn't depend on a separately
        // installed/authenticated `acli`. Degrades to empty on failure, matching
        // GitLab's semantics. Falls back to `acli` when no REST credential is set.
        if let authorization = config.authorization, let site = config.site, !site.isEmpty {
            let open: [AssignedIssue]
            switch await JiraSearchClient.fetchAssigned(site: site, jql: openJQL, authorization: authorization, transport: transport) {
            case .success(let items):
                open = Self.parseAssigned(items: items, site: config.site, statusOverride: nil, statusMap: config.statusMap)
            case .failure(let error):
                NSLog("[JiraTaskBackend] REST listAssigned failed for %@: %@", site, String(describing: error))
                return AssignedListing(open: [], closed: [])
            }

            guard includeClosed else {
                return AssignedListing(open: open, closed: [])
            }

            let closed: [AssignedIssue]
            switch await JiraSearchClient.fetchAssigned(site: site, jql: Self.closedJQL, authorization: authorization, maxResults: Self.closedPageLimit, transport: transport) {
            case .success(let items):
                closed = Self.parseAssigned(items: items, site: config.site, statusOverride: .done, statusMap: config.statusMap)
            case .failure:
                return AssignedListing(open: open, closed: [])
            }

            // Total matches in the window — `closed` is a single capped page, so
            // the badge count must come from a count query or it saturates at
            // the page cap (#572). Best-effort: nil falls back to closed.count.
            var closedTotal: Int?
            if case .success(let count) = await JiraSearchClient.fetchApproximateCount(site: site, jql: Self.closedJQL, authorization: authorization, transport: transport) {
                // The count is eventually consistent; never report below the
                // page we literally fetched.
                closedTotal = max(count, closed.count)
            }
            return AssignedListing(open: open, closed: closed, closedTotalCount: closedTotal)
        }

        // Legacy fallback: `acli` (no REST credential configured).
        let open: [AssignedIssue]
        do {
            let openOut = try await search(jql: openJQL, limit: 100)
            open = Self.parseAssigned(openOut, site: config.site, statusOverride: nil, statusMap: config.statusMap)
        } catch {
            // Match GitLab's degrade-to-empty semantics rather than throwing.
            return AssignedListing(open: [], closed: [])
        }

        guard includeClosed else {
            return AssignedListing(open: open, closed: [])
        }

        let closed: [AssignedIssue]
        do {
            let closedOut = try await search(jql: Self.closedJQL, limit: Self.closedPageLimit)
            closed = Self.parseAssigned(closedOut, site: config.site, statusOverride: .done, statusMap: config.statusMap)
        } catch {
            return AssignedListing(open: open, closed: [])
        }

        // Same badge-total story as the REST path (#572): `--count` reports the
        // full match count independent of `--limit`. Best-effort.
        var closedTotal: Int?
        if let countOut = try? await run(["acli", "jira", "workitem", "search", "--jql", Self.closedJQL, "--count"]),
           let count = Self.firstInt(countOut) {
            closedTotal = max(count, closed.count)
        }
        return AssignedListing(open: open, closed: closed, closedTotalCount: closedTotal)
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
        let targetName = jiraStatusName(for: status)

        // Preferred path (#529): credentialed Jira Cloud REST. Fetches the
        // issue's available transitions first, so a target status that isn't a
        // reachable transition (or an unmapped name) is a logged no-op rather
        // than a hard error. Independent of `acli` (removed in #528).
        if let authorization = config.authorization, let site = config.site, !site.isEmpty {
            let outcome = await JiraTransitionClient.transition(
                site: site,
                issueKey: parsed.key,
                targetStatusName: targetName,
                authorization: authorization,
                transport: transport
            )
            switch outcome {
            case .success(.transitioned):
                return
            case .success(.noMatchingTransition(let available)):
                NSLog("[JiraTaskBackend] No transition to \"%@\" available for %@ (reachable: %@); skipping",
                      targetName, parsed.key, available.isEmpty ? "none" : available.joined(separator: ", "))
                return
            case .failure(let error):
                throw ProviderError.commandFailed("Jira REST transition failed for \(parsed.key): \(error)")
            }
        }

        // Legacy fallback: `acli` (pre-#528, or when no REST credential is set).
        _ = try await run([
            "acli", "jira", "workitem", "transition",
            "--key", parsed.key,
            "--status", targetName,
            "--yes",
        ])
    }

    public func closeTask(url: String) async throws {
        // Jira has no "close" verb — the terminal state is a workflow transition
        // to the mapped completed status. Reuse `setTaskStatus(.done)`, which
        // resolves `jiraStatusName(for: .done)` honoring `JiraConfig.statusMap`
        // (#523) with the "Done" default.
        try await setTaskStatus(url: url, status: .done)
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
            "--fields", "key,summary,status,assignee,labels,priority,parent",
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

    /// Resolve the Jira workflow status name for a Crow pipeline status, honoring
    /// the per-workspace ``JiraConfig/statusMap`` override (#523) and otherwise
    /// falling back to ``defaultJiraStatusName(for:)``. A blank override entry is
    /// ignored (treated as unset) so an empty Settings field uses the default.
    func jiraStatusName(for status: TicketStatus) -> String {
        config.statusMap?[status.rawValue]?.nonBlank ?? Self.defaultJiraStatusName(for: status)
    }

    /// The built-in Crow→Jira status-name defaults, used as the fallback when a
    /// workspace has no per-project override (#523). Delegates to
    /// ``TicketStatus/defaultJiraStatusName`` (CrowCore) so the Settings UI and
    /// this live-transition path share one source of truth.
    ///
    /// Best-effort: Jira workflow status names are configurable per project, so a
    /// transition can still legitimately fail if a project renames its statuses —
    /// hence the per-workspace override map.
    public static func defaultJiraStatusName(for status: TicketStatus) -> String {
        status.defaultJiraStatusName
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

    /// Priority name from a work item's `fields` dict (`fields.priority.name`).
    /// Nil-safe: absent for GitHub-style payloads, pre-#696 fixtures, and Jira
    /// projects without a priority field.
    static func priorityName(_ fields: [String: Any]?) -> String? {
        (fields?["priority"] as? [String: Any])?["name"] as? String
    }

    /// Epic/parent link from a work item's `fields` dict (#696). On Jira Cloud
    /// `parent` is the unified field for both team- and company-managed
    /// projects (classic "Epic Link" customfields were migrated into it);
    /// Server/DC classic epic links don't surface here and degrade to nil.
    static func parentInfo(_ fields: [String: Any]?) -> (key: String?, summary: String?) {
        guard let parent = fields?["parent"] as? [String: Any] else { return (nil, nil) }
        let summary = (parent["fields"] as? [String: Any])?["summary"] as? String
        return (parent["key"] as? String, summary)
    }

    /// Leniently pull the first integer out of `acli … --count` output, whose
    /// exact shape isn't contract ("96", "96 work items", `{"count":96}` all parse).
    static func firstInt(_ output: String) -> Int? {
        guard let range = output.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(output[range])
    }

    /// Fallback when `create --json` returns non-JSON: scrape the first KEY-123
    /// token out of the output.
    static func scrapeKey(_ output: String) -> String? {
        let pattern = #"[A-Z][A-Z0-9]+-\d+"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// Resolve a Jira workflow **status name** back to a Crow ``TicketStatus`` —
    /// the inverse of ``jiraStatusName(for:)`` (the #529 write path), honoring the
    /// per-workspace ``JiraConfig/statusMap`` (#523). For each pipeline status,
    /// resolve the Jira name it maps to (override or default) and match
    /// case-insensitively; otherwise fall back to the built-in alias table
    /// (`TicketStatus(projectBoardName:)`, which handles "Doing"/"Closed"/etc.).
    /// This is what makes a renamed status (e.g. "In Development" → In Progress)
    /// land in the right board column instead of collapsing to Backlog (#533).
    static func ticketStatus(forJiraName name: String, statusMap: [String: String]?) -> TicketStatus {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .unknown }
        for status in TicketStatus.pipelineStatuses {
            let jiraName = statusMap?[status.rawValue]?.nonBlank ?? Self.defaultJiraStatusName(for: status)
            if jiraName.caseInsensitiveCompare(trimmed) == .orderedSame {
                return status
            }
        }
        return TicketStatus(projectBoardName: trimmed)
    }

    /// Decode `acli`'s top-level-array JSON output, then map via the shared
    /// `parseAssigned(items:…)` core. The REST path passes its unwrapped `issues`
    /// array directly to that core instead.
    static func parseAssigned(_ output: String, site: String?, statusOverride: TicketStatus?, statusMap: [String: String]?) -> [AssignedIssue] {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return parseAssigned(items: items, site: site, statusOverride: statusOverride, statusMap: statusMap)
    }

    static func parseAssigned(items: [[String: Any]], site: String?, statusOverride: TicketStatus?, statusMap: [String: String]?) -> [AssignedIssue] {
        return items.compactMap { item -> AssignedIssue? in
            guard let key = item["key"] as? String,
                  let parsed = JiraKey.parse(key) else { return nil }
            let fields = item["fields"] as? [String: Any]
            let title = (fields?["summary"] as? String) ?? key
            let statusDict = fields?["status"] as? [String: Any]
            let statusName = statusDict?["name"] as? String ?? ""
            let categoryKey = (statusDict?["statusCategory"] as? [String: Any])?["key"] as? String ?? ""
            let status = statusOverride ?? Self.ticketStatus(forJiraName: statusName, statusMap: statusMap)
            let state = (statusOverride == .done || categoryKey == "done") ? "closed" : "open"
            // Jira labels are plain strings (no color); surface them so
            // label-driven flows (e.g. auto-create) work for Jira too.
            let labels = (fields?["labels"] as? [String] ?? []).map { LabelInfo(name: $0) }
            let priorityName = Self.priorityName(fields)
            let parent = Self.parentInfo(fields)
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
                labels: labels,
                provider: .jira,
                priority: priorityName.map { TicketPriority(jiraName: $0) },
                priorityName: priorityName,
                parentKey: parent.key,
                parentSummary: parent.summary,
                projectStatus: status
            )
        }
    }
}

/// Parses Jira work-item keys out of either a browse URL or a bare key.
///
/// Thin alias over the single validated parser in `CrowCore.Validation` so the
/// provider layer and launcher prompts share one implementation.
enum JiraKey {
    static func parse(_ spec: String) -> (project: String, number: Int, key: String)? {
        Validation.parseJiraKey(spec)
    }
}
