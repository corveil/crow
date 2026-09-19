import Foundation
import CrowCore

/// REST JSON parsers for GitLab assigned issues.
///
/// Extracted from `GitLabTaskBackend` (CROW-1275). Symbols stay on
/// `GitLabTaskBackend` via this extension so `@testable` tests keep
/// `GitLabTaskBackend.parseIssues` / `splitTotalHeader` and so
/// `listAssigned` keeps calling the same statics. REST endpoints, `glab`
/// argv, `AssignedIssue` / `AssignedListing` field meaning, `opened`→`open`
/// vocabulary, `X-Total` badge math, and degrade-not-fail are unchanged.

extension GitLabTaskBackend {
    // MARK: - Header peel

    /// Split a `glab api -i` response into the `X-Total` header value and the
    /// body. Headers end at the first blank line; GitLab omits `X-Total` for
    /// very expensive counts, in which case (or with no header block at all)
    /// `total` is nil and `AssignedListing` falls back to the page length.
    nonisolated static func splitTotalHeader(_ output: String) -> (total: Int?, body: String) {
        let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
        guard let sep = normalized.range(of: "\n\n") else { return (nil, output) }
        var total: Int?
        for line in normalized[..<sep.lowerBound].split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "x-total" {
                total = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return (total, String(normalized[sep.upperBound...]))
    }

    // MARK: - Assigned issues

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
            // `references.full` is "group/project#iid" — the iid belongs in the
            // issue identity (`id`), but `repo` must be the bare project path so
            // the repo filter groups correctly (#751) and the MR-status API call
            // targets a valid `projects/{slug}` path (paths never contain '#').
            let repoSlug = fullRef.split(separator: "#", maxSplits: 1).first.map(String.init) ?? fullRef
            // Richer detail for the board (#751) — the REST issues payload
            // already carries these, so no extra call. Dates via the tolerant
            // parser (GitLab may or may not include fractional seconds).
            let author = (item["author"] as? [String: Any])?["username"] as? String
            let createdAt = IssueDate.parse(item["created_at"] as? String)
            let updatedAt = IssueDate.parse(item["updated_at"] as? String)
            let commentsCount = item["user_notes_count"] as? Int
            let mrCount = item["merge_requests_count"] as? Int
            let body = (item["description"] as? String).flatMap(IssueBody.cap)
            return AssignedIssue(
                id: "gitlab:\(host):\(fullRef)",
                number: number,
                title: title,
                state: state == "opened" ? "open" : state,
                url: url,
                repo: repoSlug,
                labels: labels,
                provider: .gitlab,
                updatedAt: updatedAt,
                projectStatus: projectStatusOverride ?? .unknown,
                body: body,
                author: author,
                createdAt: createdAt,
                commentsCount: commentsCount,
                mergeRequestsCount: mrCount
            )
        }
    }
}
