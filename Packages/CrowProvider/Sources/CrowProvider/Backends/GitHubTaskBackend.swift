import Foundation
import CrowCore

/// `TaskBackend` implementation for GitHub. Wraps the `gh` CLI.
///
/// Capabilities declared:
/// - `.batchedQuery` — `listAssigned` fetches open + closed issues in one
///   GraphQL call.
/// - `.projectBoardStatus` — GitHub Projects v2. After the #454 migration this
///   is a real implementation: `setTaskStatus` performs the project-item
///   lookup + `updateProjectV2ItemFieldValue` mutation. The legacy
///   `IssueTracker.markInReview` escape-hatch is gone.
///
/// See ADR 0005.
public struct GitHubTaskBackend: TaskBackend {
    public let provider: Provider = .github
    public let capabilities: Set<TaskCapability> = [.batchedQuery, .projectBoardStatus]

    private let shellRunner: ShellRunner

    public init(shellRunner: ShellRunner) {
        self.shellRunner = shellRunner
    }

    // MARK: - TaskBackend

    public func fetchTask(url: String) async throws -> TicketInfo {
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        if parsed.isMR {
            throw ProviderError.invalidURL("fetchTask received a pull request URL: \(url)")
        }
        let output = try await shellRunner.run("gh", "issue", "view", url, "--json", "title,body,labels")
        let title = Self.extractTitle(from: output) ?? "Ticket #\(parsed.number)"
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.repo,
            org: parsed.org,
            url: url,
            provider: .github,
            isMR: false
        )
    }

    public func listAssigned(includeClosed: Bool) async throws -> AssignedListing {
        let openQuery = "assignee:@me state:open type:issue"
        let closedQuery = "assignee:@me state:closed closed:>=\(Self.closedSinceString()) type:issue"

        // GitHub batches open + closed into one GraphQL call regardless of
        // `includeClosed` — there's no per-half network cost to save. When
        // `includeClosed` is false we drop the closedIssues from the parsed
        // result. The retry-without-projectItems path mirrors the same
        // shape so the missing-scope semantics stay consistent.
        do {
            let output = try await runIssuesQuery(
                query: Self.consolidatedIssuesQuery,
                openQuery: openQuery,
                closedQuery: closedQuery
            )
            let listing = try Self.parseIssuesResponse(output, missingScope: nil)
            return includeClosed ? listing : Self.stripClosed(listing)
        } catch ProviderError.insufficientScope(let scope) {
            do {
                let output = try await runIssuesQuery(
                    query: Self.consolidatedIssuesQueryNoProjects,
                    openQuery: openQuery,
                    closedQuery: closedQuery
                )
                let listing = try Self.parseIssuesResponse(output, missingScope: scope)
                return includeClosed ? listing : Self.stripClosed(listing)
            } catch ProviderError.samlRestricted(let blob) {
                // Rare: the no-projects retry also hit SAML. Recover what
                // resolved; the scope warning is sacrificed for this cycle.
                let listing = Self.recoverPartialIssues(fromSAMLBlob: blob)
                return includeClosed ? listing : Self.stripClosed(listing)
            }
        } catch ProviderError.samlRestricted(let blob) {
            // An org's SAML enforcement blocked the token. GitHub still
            // returned the accessible-org issues in `data`; recover them and
            // flag the listing degraded instead of failing the whole cycle.
            let listing = Self.recoverPartialIssues(fromSAMLBlob: blob)
            return includeClosed ? listing : Self.stripClosed(listing)
        }
    }

    private static func stripClosed(_ listing: AssignedListing) -> AssignedListing {
        AssignedListing(
            open: listing.open,
            closed: [],
            rateLimit: listing.rateLimit,
            missingScope: listing.missingScope,
            samlRestricted: listing.samlRestricted
        )
    }

    public func setLabels(url: String, add: [String], remove: [String]) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        var args: [String] = ["gh", "issue", "edit", url]
        for label in add {
            args.append("--add-label")
            args.append(label)
        }
        for label in remove {
            args.append("--remove-label")
            args.append(label)
        }
        _ = try await shellRunner.run(args: args, env: [:], cwd: nil)
    }

    public func setTaskStatus(url: String, status: TicketStatus) async throws {
        guard let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.invalidURL(url)
        }
        // Step 1: look up the issue's project item, project, Status field, and
        // available options. Two-step because the option ID we need to set
        // lives on the field, not on the item.
        let query = """
        query($owner: String!, $repo: String!, $number: Int!) {
          repository(owner: $owner, name: $repo) {
            issue(number: $number) {
              projectItems(first: 10) {
                nodes {
                  id
                  project { id }
                  fieldValueByName(name: "Status") {
                    ... on ProjectV2ItemFieldSingleSelectValue {
                      name
                      field {
                        ... on ProjectV2SingleSelectField {
                          id
                          options { id name }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

        let queryOut: String
        do {
            queryOut = try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(query)",
                "-F", "owner=\(parsed.org)",
                "-F", "repo=\(parsed.repo)",
                "-F", "number=\(parsed.number)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw Self.classifyGraphQLError(output)
        }

        guard let resolved = Self.resolveProjectFieldOption(queryOut, target: status) else {
            if !Self.hasProjectItems(queryOut) {
                // No project board attached to the issue: represent pipeline
                // status with the `crow:in-review` fallback label instead
                // (#706). The label only encodes In Review — any other target
                // status just clears it (Done is signaled by closing the
                // issue; In Progress by the active session).
                try await setInReviewFallbackLabel(
                    url: url, repo: "\(parsed.org)/\(parsed.repo)", applied: status == .inReview
                )
                return
            }
            // On a project, but no matching option for the requested status.
            // Treat as unimplemented so callers can distinguish "feature
            // genuinely not available here" from "shell failed".
            throw ProviderError.unimplemented(
                "GitHubTaskBackend.setTaskStatus: issue has no '\(status.rawValue)' status option"
            )
        }

        let mutation = """
        mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $projectId
            itemId: $itemId
            fieldId: $fieldId
            value: { singleSelectOptionId: $optionId }
          }) {
            projectV2Item { id }
          }
        }
        """

        do {
            _ = try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(mutation)",
                "-F", "projectId=\(resolved.projectID)",
                "-F", "itemId=\(resolved.itemID)",
                "-F", "fieldId=\(resolved.fieldID)",
                "-F", "optionId=\(resolved.optionID)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw Self.classifyGraphQLError(output)
        }
    }

    public func closeTask(url: String) async throws {
        guard ProviderManager.parseTicketURLComponents(url) != nil else {
            throw ProviderError.invalidURL(url)
        }
        // `gh issue close` is idempotent — closing an already-closed issue exits 0.
        do {
            _ = try await shellRunner.run("gh", "issue", "close", url)
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw ProviderError.commandFailed(output)
        }
    }

    public func assign(url: String, to login: String) async throws {
        _ = try await shellRunner.run(
            "gh", "issue", "edit", url, "--add-assignee", login
        )
    }

    public func createTask(repo: String, title: String, body: String, labels: [String]) async throws -> TicketInfo {
        var args: [String] = [
            "gh", "issue", "create",
            "--repo", repo,
            "--title", title,
            "--body", body
        ]
        for label in labels {
            args.append("--label")
            args.append(label)
        }
        let output = try await shellRunner.run(args: args, env: [:], cwd: nil)
        // `gh issue create` prints the new issue URL on stdout. Pluck it.
        let url = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("https://") } ?? ""
        guard !url.isEmpty,
              let parsed = ProviderManager.parseTicketURLComponents(url) else {
            throw ProviderError.commandFailed("gh issue create did not return a parseable URL; got: \(output)")
        }
        return TicketInfo(
            number: parsed.number,
            title: title,
            repo: parsed.repo,
            org: parsed.org,
            url: url,
            provider: .github,
            isMR: false
        )
    }

    // MARK: - Helpers

    private func runIssuesQuery(query: String, openQuery: String, closedQuery: String) async throws -> String {
        do {
            return try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(query)",
                "-F", "openQuery=\(openQuery)",
                "-F", "closedQuery=\(closedQuery)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) {
            throw Self.classifyGraphQLError(output)
        }
    }

    /// Classify a `gh api graphql` stderr blob into a typed error. Rate-limit
    /// and scope failures get their own cases so callers can route them to
    /// dedicated UI; everything else collapses to `.commandFailed`.
    static func classifyGraphQLError(_ stderr: String) -> ProviderError {
        // Check SAML first: GitHub returns partial `data` alongside the SAML
        // `errors` entry, so we carry the whole blob to recover accessible-org
        // results. A SAML blob won't also contain the rate-limit/scope tokens.
        if stderr.contains("Resource protected by organization SAML enforcement")
            || stderr.contains("protected by SAML") {
            return .samlRestricted(stderr)
        }
        if stderr.contains("RATE_LIMITED") || stderr.contains("API rate limit exceeded") {
            return .rateLimited(stderr)
        }
        if stderr.contains("INSUFFICIENT_SCOPES") || stderr.contains("read:project") {
            return .insufficientScope("read:project")
        }
        return .commandFailed(stderr)
    }

    /// Apply or clear the `crow:in-review` fallback label on an issue that has
    /// no project board (#706).
    private func setInReviewFallbackLabel(url: String, repo: String, applied: Bool) async throws {
        let label = TicketStatus.inReviewFallbackLabel
        if applied {
            try await ensureInReviewLabel(repo: repo)
            try await setLabels(url: url, add: [label], remove: [])
        } else {
            do {
                try await setLabels(url: url, add: [], remove: [label])
            } catch ShellRunnerError.nonZeroExit(_, let output)
                where output.localizedCaseInsensitiveContains("not found") {
                // Label doesn't exist in the repo (never entered review here);
                // removal is best-effort.
            }
        }
    }

    /// Ensure the `crow:in-review` fallback label exists in `repo`, mirroring
    /// `GitHubCodeBackend.ensureMergeLabel`.
    private func ensureInReviewLabel(repo: String) async throws {
        do {
            _ = try await shellRunner.run(
                "gh", "label", "create", TicketStatus.inReviewFallbackLabel,
                "--repo", repo,
                "--color", "FBCA04",
                "--description", "Crow: in review (no-project status fallback)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) where output.localizedCaseInsensitiveContains("already exists") {
            return
        }
    }

    /// Whether the project-item lookup response shows the issue on at least
    /// one Project board. Distinguishes "no board at all" (→ label fallback)
    /// from "on a board but no matching Status option" (→ unimplemented).
    static func hasProjectItems(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let repo = dataObj["repository"] as? [String: Any],
              let issue = repo["issue"] as? [String: Any],
              let projectItems = issue["projectItems"] as? [String: Any],
              let nodes = projectItems["nodes"] as? [[String: Any]] else {
            return false
        }
        return !nodes.isEmpty
    }

    /// Walk the project-item lookup response and find the (itemID, projectID,
    /// fieldID, optionID) tuple matching `target`. Matching goes through
    /// `TicketStatus(projectBoardName:)` so column aliases like bare "Review"
    /// (rather than literal "In Review") map correctly — the column-name
    /// vocabulary the rest of the app accepts. Returns `nil` if the issue has
    /// no project board or no aliased match.
    static func resolveProjectFieldOption(_ output: String, target: TicketStatus) -> (itemID: String, projectID: String, fieldID: String, optionID: String)? {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let repo = dataObj["repository"] as? [String: Any],
              let issue = repo["issue"] as? [String: Any],
              let projectItems = issue["projectItems"] as? [String: Any],
              let nodes = projectItems["nodes"] as? [[String: Any]] else {
            return nil
        }
        for node in nodes {
            guard let itemID = node["id"] as? String,
                  let project = node["project"] as? [String: Any],
                  let projectID = project["id"] as? String,
                  let fv = node["fieldValueByName"] as? [String: Any],
                  let field = fv["field"] as? [String: Any],
                  let fieldID = field["id"] as? String,
                  let options = field["options"] as? [[String: Any]] else { continue }
            for option in options {
                guard let name = option["name"] as? String,
                      let optionID = option["id"] as? String else { continue }
                // Route through the aliasing constructor so e.g. "Review",
                // "in review", or any future synonym in TicketStatus.init
                // still resolves to .inReview.
                if TicketStatus(projectBoardName: name) == target {
                    return (itemID, projectID, fieldID, optionID)
                }
            }
        }
        return nil
    }

    private static func extractTitle(from output: String) -> String? {
        if let data = output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = json["title"] as? String {
            return title
        }
        return output.components(separatedBy: .newlines).first
    }

    /// GraphQL `search` only accepts date-only for `closed:>=`. Use yesterday
    /// (UTC) so closed-issue diffing has a 24h trailing window.
    private static func closedSinceString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: Date().addingTimeInterval(-86400))
    }

    // MARK: - Query bodies + parsing

    static let consolidatedIssuesQuery = """
    query($openQuery: String!, $closedQuery: String!) {
      openIssues: search(type: ISSUE, query: $openQuery, first: 100) {
        nodes {
          ... on Issue {
            number title url state updatedAt createdAt bodyText
            author { login }
            comments { totalCount }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            projectItems(first: 10) {
              nodes {
                fieldValueByName(name: "Status") {
                  ... on ProjectV2ItemFieldSingleSelectValue { name }
                }
              }
            }
          }
        }
      }
      closedIssues: search(type: ISSUE, query: $closedQuery, first: 50) {
        issueCount
        nodes {
          ... on Issue {
            number title url state updatedAt createdAt bodyText
            author { login }
            comments { totalCount }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
          }
        }
      }
      rateLimit { remaining limit resetAt cost }
    }
    """

    static let consolidatedIssuesQueryNoProjects = """
    query($openQuery: String!, $closedQuery: String!) {
      openIssues: search(type: ISSUE, query: $openQuery, first: 100) {
        nodes {
          ... on Issue {
            number title url state updatedAt createdAt bodyText
            author { login }
            comments { totalCount }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
          }
        }
      }
      closedIssues: search(type: ISSUE, query: $closedQuery, first: 50) {
        issueCount
        nodes {
          ... on Issue {
            number title url state updatedAt createdAt bodyText
            author { login }
            comments { totalCount }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
          }
        }
      }
      rateLimit { remaining limit resetAt cost }
    }
    """

    static func parseIssuesResponse(_ output: String, missingScope: String?) throws -> AssignedListing {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            throw ProviderError.commandFailed("listAssigned: failed to parse GraphQL response")
        }
        let open = parseIssueNodes(
            dataObj["openIssues"] as? [String: Any],
            defaultState: "open"
        )
        let closed = parseIssueNodes(
            dataObj["closedIssues"] as? [String: Any],
            defaultState: "closed",
            projectStatusOverride: .done
        )
        // Total matches in the 24h window — `nodes` is capped at `first: 50`,
        // so the badge count must come from the search connection's
        // `issueCount` or it saturates at 50 (#562).
        let closedTotal = (dataObj["closedIssues"] as? [String: Any])?["issueCount"] as? Int
        let rate = parseRateLimit(dataObj["rateLimit"] as? [String: Any])
        return AssignedListing(open: open, closed: closed, closedTotalCount: closedTotal, rateLimit: rate, missingScope: missingScope)
    }

    /// Recover the accessible-org issues GitHub returned alongside a SAML
    /// `errors` entry. `blob` is the merged `gh` stdout+stderr — partial JSON
    /// body followed by the `gh:` error line — so we extract the leading JSON
    /// object before parsing. When nothing is recoverable (gh emitted no body),
    /// returns an empty listing rather than throwing, so the cycle degrades to
    /// "no tickets, warning shown" instead of failing. Always marks
    /// `samlRestricted` so callers light the warning UI.
    static func recoverPartialIssues(fromSAMLBlob blob: String) -> AssignedListing {
        guard let dataObj = decodeGraphQLData(blob) else {
            return AssignedListing(open: [], closed: [], rateLimit: nil, samlRestricted: true)
        }
        let open = parseIssueNodes(
            dataObj["openIssues"] as? [String: Any],
            defaultState: "open"
        )
        let closed = parseIssueNodes(
            dataObj["closedIssues"] as? [String: Any],
            defaultState: "closed",
            projectStatusOverride: .done
        )
        let rate = parseRateLimit(dataObj["rateLimit"] as? [String: Any])
        return AssignedListing(open: open, closed: closed, rateLimit: rate, samlRestricted: true)
    }

    /// Pull the `data` object out of a `gh api graphql` output blob that may
    /// have trailing non-JSON text appended — e.g. the `gh: …` error line that
    /// lands in the same merged stdout+stderr stream after the response body on
    /// a partial (SAML/FORBIDDEN) failure. Fast path parses the whole string
    /// (the success case stays zero-overhead); the fallback extracts the first
    /// balanced top-level `{…}` object and parses that. Returns `json["data"]`,
    /// or nil if no JSON object is present.
    static func decodeGraphQLData(_ blob: String) -> [String: Any]? {
        func dataObject(from string: String) -> [String: Any]? {
            guard let data = string.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["data"] as? [String: Any]
        }
        if let dataObj = dataObject(from: blob) {
            return dataObj
        }
        guard let sliced = firstBalancedJSONObject(in: blob) else { return nil }
        return dataObject(from: sliced)
    }

    /// Return the substring spanning the first complete, brace-balanced `{…}`
    /// object in `blob`, ignoring braces inside JSON strings (and escapes).
    /// Used to peel the response body off a blob with trailing `gh:` error text.
    static func firstBalancedJSONObject(in blob: String) -> String? {
        let chars = Array(blob)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                switch c {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(chars[start...i])
                    }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    static func parseIssueNodes(
        _ searchObj: [String: Any]?,
        defaultState: String,
        projectStatusOverride: TicketStatus? = nil
    ) -> [AssignedIssue] {
        guard let nodes = searchObj?["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { node -> AssignedIssue? in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let url = node["url"] as? String else { return nil }
            let state = (node["state"] as? String ?? defaultState).lowercased()
            let repoName = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { labelNode -> LabelInfo? in
                    guard let name = labelNode["name"] as? String else { return nil }
                    return LabelInfo(name: name, color: labelNode["color"] as? String)
                } ?? []
            // Tolerant parse (#751): GitHub GraphQL emits non-fractional
            // DateTime, which a `.withFractionalSeconds` formatter rejects —
            // that silently disabled updated/created sort + "opened … ago".
            let updatedAt = GitHubCodeBackend.parseGitHubDateTime((node["updatedAt"] as? String) ?? "")
            let createdAt = GitHubCodeBackend.parseGitHubDateTime((node["createdAt"] as? String) ?? "")
            let author = (node["author"] as? [String: Any])?["login"] as? String
            let commentsCount = (node["comments"] as? [String: Any])?["totalCount"] as? Int
            let body = (node["bodyText"] as? String).flatMap(IssueBody.cap)
            var projectStatus: TicketStatus = projectStatusOverride ?? .unknown
            if projectStatusOverride == nil,
               let projectItems = node["projectItems"] as? [String: Any],
               let itemNodes = projectItems["nodes"] as? [[String: Any]] {
                for item in itemNodes {
                    if let fv = item["fieldValueByName"] as? [String: Any],
                       let statusName = fv["name"] as? String {
                        projectStatus = TicketStatus(projectBoardName: statusName)
                        break
                    }
                }
            }
            // Label fallback (#706): when the board yields no status (issue
            // not on any project), the `crow:in-review` label carries the
            // In Review state. A board status, when present, wins above.
            if projectStatusOverride == nil, projectStatus == .unknown,
               labels.contains(where: { $0.name == TicketStatus.inReviewFallbackLabel }) {
                projectStatus = .inReview
            }
            return AssignedIssue(
                id: "github:\(repoName)#\(number)",
                number: number,
                title: title,
                state: state,
                url: url,
                repo: repoName,
                labels: labels,
                provider: .github,
                updatedAt: updatedAt,
                projectStatus: projectStatus,
                body: body,
                author: author,
                createdAt: createdAt,
                commentsCount: commentsCount
            )
        }
    }

    static func parseRateLimit(_ obj: [String: Any]?) -> GitHubRateLimit? {
        guard let obj,
              let remaining = obj["remaining"] as? Int,
              let limit = obj["limit"] as? Int,
              let cost = obj["cost"] as? Int,
              let resetAtStr = obj["resetAt"] as? String else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resetAt = fmt.date(from: resetAtStr)
            ?? ISO8601DateFormatter().date(from: resetAtStr)
            ?? Date().addingTimeInterval(60 * 60)
        return GitHubRateLimit(
            remaining: remaining,
            limit: limit,
            resetAt: resetAt,
            cost: cost,
            observedAt: Date()
        )
    }
}
