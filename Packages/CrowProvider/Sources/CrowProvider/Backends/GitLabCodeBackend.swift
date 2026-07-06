import Foundation
import CrowCore

/// `CodeBackend` implementation for GitLab. Wraps the `glab` CLI.
///
/// Capabilities: none in v1. The merge-label flow, auto-merge enable, and
/// update-branch are all GitHub-only today; once GitLab gets equivalent CI
/// gating, declare the matching capability and implement the method.
///
/// See ADR 0005.
public struct GitLabCodeBackend: CodeBackend {
    public let provider: Provider = .gitlab
    public let cliName: String = "glab"
    public let capabilities: Set<CodeCapability> = []

    private let shellRunner: ShellRunner
    private let host: String?

    public init(shellRunner: ShellRunner, host: String?) {
        self.shellRunner = shellRunner
        self.host = host
    }

    public func linkedPR(repo: String, branch: String) async throws -> LinkedPR? {
        let output = try await shellRunner.run(
            args: [
                "glab", "mr", "list",
                "--repo", repo,
                "--source-branch", branch,
                "--all",
                "-F", "json"
            ],
            env: env(),
            cwd: NSHomeDirectory()
        )
        guard let data = output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let iid = first["iid"] as? Int else {
            return nil
        }
        let webURL = (first["web_url"] as? String) ?? ""
        let state = (first["state"] as? String) ?? ""
        return LinkedPR(number: iid, url: webURL, state: state)
    }

    public func ensureMergeLabel(repo: String) async throws {
        throw ProviderError.unimplemented("GitLabCodeBackend.ensureMergeLabel: no autoMergeLabel capability")
    }

    public func listMonitoredPRs() async throws -> MonitoredPRListing {
        // Best-effort: GitLab assigns the viewer as either author OR reviewer
        // depending on the workflow. Use the REST API's
        // `merge_requests?scope=assigned_to_me` for review-requested-like MRs.
        // The CLI doesn't surface "viewer's own monitored PRs" the same way
        // GitHub does — we leave viewerPRs empty rather than fabricate it.
        let output: String
        do {
            output = try await shellRunner.run(
                args: ["glab", "api", "merge_requests?scope=assigned_to_me&state=opened&per_page=50"],
                env: env(),
                cwd: NSHomeDirectory()
            )
        } catch {
            return MonitoredPRListing(viewerPRs: [], reviewRequests: [], viewerLogin: "")
        }
        let reviewRequests = Self.parseReviewMRs(output, host: host ?? "")
        return MonitoredPRListing(viewerPRs: [], reviewRequests: reviewRequests, viewerLogin: "")
    }

    public func prStates(refs: [PRRef]) async throws -> [PRRef: PRRecord] {
        // GitLab REST has no batching; one call per MR.
        var out: [PRRef: PRRecord] = [:]
        for ref in refs {
            let slug = ref.slug
            let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? slug
            let endpoint = "projects/\(encodedSlug)/merge_requests/\(ref.number)"
            let output: String
            do {
                output = try await shellRunner.run(
                    args: ["glab", "api", endpoint],
                    env: env(),
                    cwd: NSHomeDirectory()
                )
            } catch {
                continue
            }
            guard let rec = Self.parseStaleMRResponse(
                output,
                fallbackURL: "",
                fallbackSlug: slug
            ) else { continue }
            out[ref] = rec
        }
        return out
    }

    /// Parse a single `projects/{slug}/merge_requests/{iid}` REST response
    /// into a `PRRecord`. State is normalized to GitHub's
    /// `OPEN|MERGED|CLOSED` vocabulary so downstream code stays
    /// provider-agnostic. Returns nil if the JSON shape doesn't match.
    public static func parseStaleMRResponse(
        _ output: String,
        fallbackURL: String,
        fallbackSlug: String
    ) -> PRRecord? {
        guard let data = output.data(using: .utf8),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = item["iid"] as? Int else { return nil }
        let url = (item["web_url"] as? String) ?? fallbackURL
        let rawState = (item["state"] as? String) ?? ""
        let state = normalizeState(rawState)
        let headRefName = (item["source_branch"] as? String) ?? ""
        let baseRefName = (item["target_branch"] as? String) ?? ""
        let headRefOid = (item["sha"] as? String) ?? ""
        let isDraft = (item["draft"] as? Bool) ?? (item["work_in_progress"] as? Bool) ?? false
        return PRRecord(
            number: number,
            url: url,
            state: state,
            isDraft: isDraft,
            headRefName: headRefName,
            headRefOid: headRefOid,
            baseRefName: baseRefName,
            repoNameWithOwner: fallbackSlug
        )
    }

    public func fetchCrowAuthoredCommits(prURL: String, repoSlug: String, prNumber: Int) async throws -> [CommitInfo] {
        let encodedSlug = repoSlug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? repoSlug
        let endpoint = "projects/\(encodedSlug)/merge_requests/\(prNumber)/commits"
        let output = try await shellRunner.run(
            args: ["glab", "api", endpoint],
            env: env(),
            cwd: NSHomeDirectory()
        )
        guard let data = output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { item -> CommitInfo? in
            guard let message = item["message"] as? String else { return nil }
            let sha = (item["id"] as? String) ?? ""
            return CommitInfo(sha: sha, message: message)
        }
    }

    public func findRecentPRsForBranches(_ candidates: [BranchCandidate]) async throws -> [BranchPRMatch] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var matches: [BranchPRMatch] = []
        for candidate in candidates {
            let encodedSlug = candidate.repoSlug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? candidate.repoSlug
            let encodedBranch = candidate.branch.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? candidate.branch
            let endpoint = "projects/\(encodedSlug)/merge_requests?source_branch=\(encodedBranch)&state=all&per_page=5&order_by=updated_at"
            let output: String
            do {
                output = try await shellRunner.run(
                    args: ["glab", "api", endpoint],
                    env: env(),
                    cwd: NSHomeDirectory()
                )
            } catch {
                continue
            }
            guard let data = output.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                continue
            }
            for item in items {
                guard let number = item["iid"] as? Int,
                      let url = item["web_url"] as? String else { continue }
                let rawState = (item["state"] as? String) ?? ""
                let normalized = Self.normalizeState(rawState)
                let updatedAt = (item["updated_at"] as? String).flatMap { dateFormatter.date(from: $0) }
                matches.append(BranchPRMatch(
                    candidate: candidate,
                    number: number,
                    url: url,
                    state: normalized,
                    updatedAt: updatedAt
                ))
            }
        }
        return matches
    }

    public func enableAutoMerge(prURL: String) async throws {
        throw ProviderError.unimplemented("GitLabCodeBackend.enableAutoMerge: no autoMerge capability")
    }

    public func updateBranch(prURL: String) async throws {
        throw ProviderError.unimplemented("GitLabCodeBackend.updateBranch: no updateBranch capability")
    }

    public func fetchPRMetadata(prURL: String) async throws -> PRMetadata {
        // Reuse the global URL parser to find slug + IID; then hit `glab api`.
        guard let parsed = ProviderManager.parseTicketURLComponents(prURL) else {
            throw ProviderError.invalidURL(prURL)
        }
        let slug = "\(parsed.org)/\(parsed.repo)"
        let encodedSlug = slug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? slug
        let endpoint = "projects/\(encodedSlug)/merge_requests/\(parsed.number)"
        let output = try await shellRunner.run(
            args: ["glab", "api", endpoint],
            env: env(),
            cwd: NSHomeDirectory()
        )
        guard let data = output.data(using: .utf8),
              let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.commandFailed("fetchPRMetadata: failed to parse glab MR response")
        }
        return PRMetadata(
            title: (item["title"] as? String) ?? "",
            number: (item["iid"] as? Int) ?? parsed.number,
            headRefName: (item["source_branch"] as? String) ?? "",
            headRefOid: (item["sha"] as? String) ?? "",
            baseRefName: (item["target_branch"] as? String) ?? "",
            author: ((item["author"] as? [String: Any])?["username"] as? String) ?? ""
        )
    }

    // MARK: - Helpers

    private func env() -> [String: String] {
        guard let host else { return [:] }
        return ["GITLAB_HOST": host]
    }

    public static func normalizeState(_ raw: String) -> String {
        switch raw {
        case "opened": return "OPEN"
        case "merged": return "MERGED"
        case "closed": return "CLOSED"
        default: return raw.uppercased()
        }
    }

    static func parseReviewMRs(_ output: String, host: String) -> [ReviewRequest] {
        guard let data = output.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return items.compactMap { item -> ReviewRequest? in
            guard let number = item["iid"] as? Int,
                  let title = item["title"] as? String,
                  let url = item["web_url"] as? String else { return nil }
            let refs = item["references"] as? [String: Any]
            let fullRef = (refs?["full"] as? String) ?? ""
            let author = ((item["author"] as? [String: Any])?["username"] as? String) ?? ""
            let headBranch = (item["source_branch"] as? String) ?? ""
            let baseBranch = (item["target_branch"] as? String) ?? ""
            let draft = (item["draft"] as? Bool) ?? (item["work_in_progress"] as? Bool) ?? false
            let labels = (item["labels"] as? [String] ?? []).map { LabelInfo(name: $0) }
            let updatedAt = (item["updated_at"] as? String).flatMap { dateFmt.date(from: $0) }
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
                isDraft: draft,
                requestedAt: updatedAt,
                labels: labels,
                provider: .gitlab,
                headRefOid: headRefOid
            )
        }
    }
}
