import Foundation
import CrowCore

/// `CodeBackend` implementation for GitLab. Wraps the `glab` CLI.
///
/// Facade (CROW-1273): protocol methods, `capabilities`, `shellRunner`,
/// `host` / `GITLAB_HOST`, and the `glab` argv wrappers. REST JSON parsers
/// live in `GitLabCodeBackend+Parsing.swift` as `extension GitLabCodeBackend`
/// so `@testable` tests keep `GitLabCodeBackend.mapPipelineStatus` /
/// `parseStaleMRResponse` / `normalizeState` and so `BoardPoller` /
/// `IssueTracker` aliases keep forwarding to the same public statics.
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
        return Self.parseLinkedPR(output)
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
        // `reviewedPRs` is left empty (CROW-982, CROW-990): the MR list endpoint
        // carries no per-reviewer verdict, so there is nothing to distinguish an
        // MR the viewer approved from one they merely looked at. The board's
        // "Waiting on author" and "Recently completed" groups therefore stay
        // empty on GitLab rather than guessing — same reasoning as
        // `viewerLastReviewedAt` below.
        return MonitoredPRListing(viewerPRs: [], reviewRequests: reviewRequests, viewerLogin: "")
    }

    /// `viewerLogin` is accepted for protocol conformance and ignored: GitLab's
    /// MR endpoint carries no per-reviewer verdict timestamp, so
    /// `viewerLastReviewedAt` stays nil here — "not fetched", per `PRRecord`.
    public func prStates(refs: [PRRef], viewerLogin: String?) async throws -> [PRRef: PRRecord] {
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

    /// Best-effort linked-MR status for an issue, for the board's inline PR
    /// state + CI badges (#751). Finds the first open related MR (falling back
    /// to the most recent), then reads its head-pipeline CI rollup. Returns nil
    /// when the issue has no related MR or the call fails. Costs up to two REST
    /// calls per issue (related MRs, then the single MR for its pipeline), so
    /// callers should bound how many issues they enrich. The returned
    /// `PRRecord` populates only `number`/`url`/`state`/`isDraft`/`checksState`.
    public func linkedMRStatus(repoSlug: String, issueNumber: Int) async throws -> PRRecord? {
        let encodedSlug = repoSlug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? repoSlug
        let relatedEndpoint = "projects/\(encodedSlug)/issues/\(issueNumber)/related_merge_requests"
        let output = try await shellRunner.run(
            args: ["glab", "api", relatedEndpoint],
            env: env(),
            cwd: NSHomeDirectory()
        )
        guard let related = Self.parseRelatedMRStatus(output) else { return nil }

        // CI rollup: the list payload omits pipelines, so read the single-MR
        // endpoint's head_pipeline. Best-effort — a missing/empty pipeline just
        // leaves checksState blank.
        let mrEndpoint = "projects/\(encodedSlug)/merge_requests/\(related.number)"
        guard let mrOut = try? await shellRunner.run(
            args: ["glab", "api", mrEndpoint],
            env: env(),
            cwd: NSHomeDirectory()
        ) else {
            return related
        }
        return Self.applyingPipeline(to: related, output: mrOut)
    }

    public func fetchCrowAuthoredCommits(prURL: String, repoSlug: String, prNumber: Int) async throws -> [CommitInfo] {
        let encodedSlug = repoSlug.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? repoSlug
        let endpoint = "projects/\(encodedSlug)/merge_requests/\(prNumber)/commits"
        let output = try await shellRunner.run(
            args: ["glab", "api", endpoint],
            env: env(),
            cwd: NSHomeDirectory()
        )
        return Self.parseCommits(output)
    }

    public func findRecentPRsForBranches(_ candidates: [BranchCandidate]) async throws -> [BranchPRMatch] {
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
            matches.append(contentsOf: Self.parseRecentPRs(output, candidate: candidate))
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
        guard let meta = Self.parsePRMetadata(output, fallbackNumber: parsed.number) else {
            throw ProviderError.commandFailed("fetchPRMetadata: failed to parse glab MR response")
        }
        return meta
    }

    // MARK: - Helpers

    private func env() -> [String: String] {
        guard let host else { return [:] }
        return ["GITLAB_HOST": host]
    }
}
