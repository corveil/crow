import Foundation
import CrowCore

/// GraphQL documents and `AssignedIssue` parsers for GitHub issues.
///
/// Extracted from `GitHubTaskBackend` (CROW-1265). Symbols stay on
/// `GitHubTaskBackend` via this extension so `@testable` tests keep
/// `GitHubTaskBackend.parseIssueNodes` / `recoverPartialIssues` /
/// `hasProjectItems` and so `listAssigned` / `setTaskStatus` keep calling
/// the same statics. Query shape, `AssignedIssue` field meaning, SAML
/// degrade-not-fail, `issueCount` vs node cap, `read:project` retry, and
/// fallback-label vs Projects v2 are unchanged.
///
/// Shared GraphQL JSON peelers (`decodeGraphQLData`, `firstBalancedJSONObject`,
/// `parseRateLimit`) live here so `GitHubCodeBackend+Parsing` keeps calling
/// `GitHubTaskBackend.*`. `classifyGraphQLError` stays on the adapter.

extension GitHubTaskBackend {
    // MARK: - Query documents

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

    /// Step 1 of `setTaskStatus`: look up the issue's project item, project,
    /// Status field, and available options. Two-step because the option ID
    /// we need to set lives on the field, not on the item.
    static let projectItemLookupQuery = """
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

    static let updateProjectV2ItemFieldValueMutation = """
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

    // MARK: - AssignedIssue parsers

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

    static func parseIssueNodes(
        _ searchObj: [String: Any]?,
        defaultState: String,
        projectStatusOverride: TicketStatus? = nil
    ) -> [AssignedIssue] {
        // `LenientJSON`, not `as? [[String: Any]]` (#894): GitHub nullifies the
        // individual nodes it won't resolve under SAML enforcement, and the
        // all-or-nothing array cast emptied the whole ticket board alongside them.
        return LenientJSON.nodes(searchObj).compactMap { node -> AssignedIssue? in
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let url = node["url"] as? String else { return nil }
            let state = (node["state"] as? String ?? defaultState).lowercased()
            let repoName = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            let labels = LenientJSON.nodes(node, "labels")
                .compactMap { labelNode -> LabelInfo? in
                    guard let name = labelNode["name"] as? String else { return nil }
                    return LabelInfo(name: name, color: labelNode["color"] as? String)
                }
            // Tolerant parse (#751): GitHub GraphQL emits non-fractional
            // DateTime, which a `.withFractionalSeconds` formatter rejects —
            // that silently disabled updated/created sort + "opened … ago".
            let updatedAt = IssueDate.parse(node["updatedAt"] as? String)
            let createdAt = IssueDate.parse(node["createdAt"] as? String)
            let author = (node["author"] as? [String: Any])?["login"] as? String
            let commentsCount = (node["comments"] as? [String: Any])?["totalCount"] as? Int
            let body = (node["bodyText"] as? String).flatMap(IssueBody.cap)
            var projectStatus: TicketStatus = projectStatusOverride ?? .unknown
            if projectStatusOverride == nil {
                for item in LenientJSON.nodes(node, "projectItems") {
                    if let fv = item["fieldValueByName"] as? [String: Any],
                       let statusName = fv["name"] as? String {
                        projectStatus = TicketStatus(projectBoardName: statusName)
                        break
                    }
                }
            }
            // Label fallback (#706, #790): when the board yields no status
            // (issue not on any project), the `crow:in-review` /
            // `crow:in-progress` labels carry the state. A board status, when
            // present, wins above. In Review wins if both labels are somehow
            // present, matching pipeline order.
            if projectStatusOverride == nil, projectStatus == .unknown {
                let names = Set(labels.map(\.name))
                if names.contains(TicketStatus.inReviewFallbackLabel) {
                    projectStatus = .inReview
                } else if names.contains(TicketStatus.inProgressFallbackLabel) {
                    projectStatus = .inProgress
                }
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

    /// Whether the project-item lookup response shows the issue on at least
    /// one Project board. Distinguishes "no board at all" (→ label fallback)
    /// from "on a board but no matching Status option" (→ unimplemented).
    ///
    /// Reads the nodes leniently (#894): a SAML-nulled project item used to
    /// fail the whole array cast, so an issue that IS on a board read as
    /// "no board" and got a `crow:` fallback label written onto it instead.
    static func hasProjectItems(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let repo = dataObj["repository"] as? [String: Any],
              let issue = repo["issue"] as? [String: Any] else {
            return false
        }
        return !LenientJSON.nodes(issue, "projectItems").isEmpty
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
              let issue = repo["issue"] as? [String: Any] else {
            return nil
        }
        for node in LenientJSON.nodes(issue, "projectItems") {
            guard let itemID = node["id"] as? String,
                  let project = node["project"] as? [String: Any],
                  let projectID = project["id"] as? String,
                  let fv = node["fieldValueByName"] as? [String: Any],
                  let field = fv["field"] as? [String: Any],
                  let fieldID = field["id"] as? String else { continue }
            for option in LenientJSON.objects(field["options"]) {
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

    // MARK: - Shared GraphQL JSON peelers (CROW-1253 contract)

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
