import Foundation
import CrowCore

/// REST JSON parsers for GitLab merge requests.
///
/// Extracted from `GitLabCodeBackend` (CROW-1273). Symbols stay on
/// `GitLabCodeBackend` via this extension so `@testable` tests keep
/// `GitLabCodeBackend.mapPipelineStatus` / `parseStaleMRResponse` /
/// `normalizeState` and so `BoardPoller` / `IssueTracker` aliases keep
/// forwarding to the same public statics. REST endpoints, `glab` argv,
/// `PRRecord` / `ReviewRequest` field meaning, state/pipeline vocabularies,
/// and the empty `reviewedPRs` / `viewerPRs` contract are unchanged.

extension GitLabCodeBackend {
    // MARK: - JSON helpers

    private static func jsonObject(_ output: String) -> Any? {
        guard let data = output.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func jsonDict(_ output: String) -> [String: Any]? {
        jsonObject(output) as? [String: Any]
    }

    private static func jsonArray(_ output: String) -> [[String: Any]]? {
        jsonObject(output) as? [[String: Any]]
    }

    /// Draft vs legacy `work_in_progress`. Older GitLab versions only emit
    /// `work_in_progress`; dropping the fallback marks every legacy WIP MR
    /// as not-draft.
    private static func isDraft(_ item: [String: Any]) -> Bool {
        (item["draft"] as? Bool) ?? (item["work_in_progress"] as? Bool) ?? false
    }

    // MARK: - Linked PR

    /// Parse `glab mr list -F json` into a `LinkedPR`. Returns nil if the
    /// JSON shape doesn't match.
    static func parseLinkedPR(_ output: String) -> LinkedPR? {
        guard let arr = jsonArray(output),
              let first = arr.first,
              let iid = first["iid"] as? Int else {
            return nil
        }
        let webURL = (first["web_url"] as? String) ?? ""
        let state = (first["state"] as? String) ?? ""
        return LinkedPR(number: iid, url: webURL, state: state)
    }

    // MARK: - Stale MR / PRRecord

    /// Parse a single `projects/{slug}/merge_requests/{iid}` REST response
    /// into a `PRRecord`. State is normalized to GitHub's
    /// `OPEN|MERGED|CLOSED` vocabulary so downstream code stays
    /// provider-agnostic. Returns nil if the JSON shape doesn't match.
    public static func parseStaleMRResponse(
        _ output: String,
        fallbackURL: String,
        fallbackSlug: String
    ) -> PRRecord? {
        guard let item = jsonDict(output),
              let number = item["iid"] as? Int else { return nil }
        let url = (item["web_url"] as? String) ?? fallbackURL
        let rawState = (item["state"] as? String) ?? ""
        let state = normalizeState(rawState)
        let headRefName = (item["source_branch"] as? String) ?? ""
        let baseRefName = (item["target_branch"] as? String) ?? ""
        let headRefOid = (item["sha"] as? String) ?? ""
        return PRRecord(
            number: number,
            url: url,
            state: state,
            isDraft: isDraft(item),
            headRefName: headRefName,
            headRefOid: headRefOid,
            baseRefName: baseRefName,
            repoNameWithOwner: fallbackSlug
        )
    }

    // MARK: - Review MRs

    static func parseReviewMRs(_ output: String, host: String) -> [ReviewRequest] {
        guard let items = jsonArray(output) else {
            return []
        }
        return items.compactMap { item -> ReviewRequest? in
            guard let number = item["iid"] as? Int,
                  let title = item["title"] as? String,
                  let url = item["web_url"] as? String else { return nil }
            let refs = item["references"] as? [String: Any]
            let fullRef = (refs?["full"] as? String) ?? ""
            let author = ((item["author"] as? [String: Any])?["username"] as? String) ?? ""
            let headBranch = (item["source_branch"] as? String) ?? ""
            let baseBranch = (item["target_branch"] as? String) ?? ""
            let labels = (item["labels"] as? [String] ?? []).map { LabelInfo(name: $0) }
            let updatedAt = IssueDate.parse(item["updated_at"] as? String)
            let headRefOid = item["sha"] as? String
            return ReviewRequest(
                id: "gitlab:\(host):\(fullRef)",
                prNumber: number,
                title: title,
                url: url,
                repo: fullRef,
                author: author,
                headBranch: headBranch,
                baseBranch: baseBranch,
                isDraft: isDraft(item),
                requestedAt: updatedAt,
                labels: labels,
                provider: .gitlab,
                headRefOid: headRefOid
            )
        }
    }

    // MARK: - Linked-MR status (board enrichment)

    /// Preferred related MR from `issues/{iid}/related_merge_requests`.
    /// Prefers an `opened` MR, else the first listed. `checksState` is
    /// empty — the pipeline is a second REST call. Returns nil when the
    /// JSON isn't an array or no item has both `iid` and `web_url`.
    static func parseRelatedMRStatus(_ output: String) -> PRRecord? {
        guard let arr = jsonArray(output) else { return nil }
        let opened = arr.first { ($0["state"] as? String) == "opened" }
        guard let mr = opened ?? arr.first,
              let iid = mr["iid"] as? Int,
              let webURL = mr["web_url"] as? String else {
            return nil
        }
        return PRRecord(
            number: iid,
            url: webURL,
            state: normalizeState((mr["state"] as? String) ?? ""),
            isDraft: isDraft(mr)
        )
    }

    /// Overlay a single-MR REST response's `head_pipeline` / `pipeline`
    /// onto a related-MR `PRRecord`. A missing/empty pipeline leaves
    /// `checksState` blank.
    static func applyingPipeline(to record: PRRecord, output: String) -> PRRecord {
        PRRecord(
            number: record.number,
            url: record.url,
            state: record.state,
            isDraft: record.isDraft,
            checksState: parsePipelineChecksState(output)
        )
    }

    /// Parse a single-MR REST response's `head_pipeline` (fallback
    /// `pipeline`) into the checks vocabulary. Empty when the JSON has
    /// no pipeline status.
    static func parsePipelineChecksState(_ output: String) -> String {
        guard let mrObj = jsonDict(output) else { return "" }
        let pipeline = (mrObj["head_pipeline"] as? [String: Any]) ?? (mrObj["pipeline"] as? [String: Any])
        guard let status = pipeline?["status"] as? String else { return "" }
        return mapPipelineStatus(status)
    }

    /// Normalize a GitLab pipeline status to the provider-agnostic checks
    /// vocabulary shared with GitHub (`SUCCESS`/`FAILURE`/`PENDING`/`ERROR`).
    /// `skipped`/unknown map to `""` (no checks shown).
    static func mapPipelineStatus(_ raw: String) -> String {
        switch raw {
        case "success": return "SUCCESS"
        case "failed": return "FAILURE"
        case "running", "pending", "created", "preparing", "waiting_for_resource",
             "scheduled", "manual": return "PENDING"
        case "canceled": return "ERROR"
        default: return ""
        }
    }

    // MARK: - Commits / recent MRs / metadata

    static func parseCommits(_ output: String) -> [CommitInfo] {
        guard let arr = jsonArray(output) else { return [] }
        return arr.compactMap { item -> CommitInfo? in
            guard let message = item["message"] as? String else { return nil }
            let sha = (item["id"] as? String) ?? ""
            return CommitInfo(sha: sha, message: message)
        }
    }

    static func parseRecentPRs(_ output: String, candidate: BranchCandidate) -> [BranchPRMatch] {
        guard let items = jsonArray(output) else { return [] }
        var matches: [BranchPRMatch] = []
        for item in items {
            guard let number = item["iid"] as? Int,
                  let url = item["web_url"] as? String else { continue }
            let rawState = (item["state"] as? String) ?? ""
            let normalized = normalizeState(rawState)
            let updatedAt = IssueDate.parse(item["updated_at"] as? String)
            matches.append(BranchPRMatch(
                candidate: candidate,
                number: number,
                url: url,
                state: normalized,
                updatedAt: updatedAt
            ))
        }
        return matches
    }

    /// Parse a single-MR REST response into `PRMetadata`. Returns nil if
    /// the JSON isn't an object — the adapter throws, matching the
    /// previous inline path.
    static func parsePRMetadata(_ output: String, fallbackNumber: Int) -> PRMetadata? {
        guard let item = jsonDict(output) else { return nil }
        return PRMetadata(
            title: (item["title"] as? String) ?? "",
            number: (item["iid"] as? Int) ?? fallbackNumber,
            headRefName: (item["source_branch"] as? String) ?? "",
            headRefOid: (item["sha"] as? String) ?? "",
            baseRefName: (item["target_branch"] as? String) ?? "",
            author: ((item["author"] as? [String: Any])?["username"] as? String) ?? ""
        )
    }

    // MARK: - State vocabulary

    public static func normalizeState(_ raw: String) -> String {
        switch raw {
        case "opened": return "OPEN"
        case "merged": return "MERGED"
        case "closed": return "CLOSED"
        default: return raw.uppercased()
        }
    }
}
