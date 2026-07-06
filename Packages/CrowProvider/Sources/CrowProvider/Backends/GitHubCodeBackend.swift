import Foundation
import CrowCore

/// `CodeBackend` implementation for GitHub. Wraps the `gh` CLI for PR/label operations.
///
/// Capabilities:
/// - `.autoMergeLabel` — supports `gh label create crow:merge`.
/// - `.batchedPRStates` — batches multiple PR states in one GraphQL call.
/// - `.autoMerge` — supports `gh pr merge --auto --squash --delete-branch`.
/// - `.updateBranch` — supports `gh pr update-branch`.
///
/// See ADR 0005 for the protocol contract.
public struct GitHubCodeBackend: CodeBackend {
    public let provider: Provider = .github
    public let cliName: String = "gh"
    public let capabilities: Set<CodeCapability> = [
        .autoMergeLabel,
        .batchedPRStates,
        .autoMerge,
        .updateBranch
    ]

    private let shellRunner: ShellRunner

    public init(shellRunner: ShellRunner) {
        self.shellRunner = shellRunner
    }

    // MARK: - linkedPR / ensureMergeLabel

    public func linkedPR(repo: String, branch: String) async throws -> LinkedPR? {
        let output = try await shellRunner.run(
            "gh", "pr", "list",
            "--repo", repo,
            "--head", branch,
            "--state", "all",
            "--json", "number,url,state",
            "--limit", "1"
        )
        guard let data = output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first,
              let number = first["number"] as? Int,
              let url = first["url"] as? String,
              let state = first["state"] as? String else {
            return nil
        }
        return LinkedPR(number: number, url: url, state: state)
    }

    public func ensureMergeLabel(repo: String) async throws {
        do {
            _ = try await shellRunner.run(
                "gh", "label", "create", "crow:merge",
                "--repo", repo,
                "--color", "1D76DB",
                "--description", "Auto-merge when checks pass"
            )
        } catch ShellRunnerError.nonZeroExit(_, let output) where output.localizedCaseInsensitiveContains("already exists") {
            return
        }
    }

    // MARK: - listMonitoredPRs

    public func listMonitoredPRs() async throws -> MonitoredPRListing {
        let reviewQuery = "review-requested:@me state:open type:pr"
        let output: String
        do {
            output = try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(Self.monitoredPRsQuery)",
                "-F", "reviewQuery=\(reviewQuery)"
            )
        } catch ShellRunnerError.nonZeroExit(_, let stderr) {
            let err = GitHubTaskBackend.classifyGraphQLError(stderr)
            if case .samlRestricted(let blob) = err {
                // An org's SAML enforcement blocked the token. Recover the
                // accessible-org PRs/reviews GitHub still returned and flag the
                // listing degraded instead of failing the whole cycle.
                return Self.recoverPartialMonitoredPRs(fromSAMLBlob: blob)
            }
            throw err
        }
        return try Self.parseMonitoredPRsResponse(output)
    }

    // MARK: - prStates

    /// `prStates` and `findRecentPRsForBranches` deliberately omit the
    /// `rateLimit { remaining limit resetAt cost }` block their pre-migration
    /// IssueTracker counterparts used to carry. The cycle's main consolidated
    /// poll (`listAssigned` + `listMonitoredPRs`) already refreshes
    /// `appState.githubRateLimit` every ~60s, so threading rate-limit out
    /// of these secondary calls only sharpens the soft-threshold accounting
    /// by a few requests of granularity. Re-add the block and a return-shape
    /// tuple if that granularity ever starts mattering.

    public func prStates(refs: [PRRef]) async throws -> [PRRef: PRRecord] {
        guard !refs.isEmpty else { return [:] }
        var queryParts: [String] = []
        var args: [String] = ["gh", "api", "graphql"]
        for (i, ref) in refs.enumerated() {
            queryParts.append("""
              pr\(i): repository(owner: $owner\(i), name: $repo\(i)) {
                pullRequest(number: $num\(i)) {
                  number url state mergeable mergeStateStatus reviewDecision isDraft
                  headRefName headRefOid baseRefName
                  mergeCommit { oid }
                  repository { nameWithOwner }
                }
              }
            """)
            args.append(contentsOf: ["-F", "owner\(i)=\(ref.owner)"])
            args.append(contentsOf: ["-F", "repo\(i)=\(ref.repo)"])
            args.append(contentsOf: ["-F", "num\(i)=\(ref.number)"])
        }
        var varDecls: [String] = []
        for i in 0..<refs.count {
            varDecls.append("$owner\(i): String!, $repo\(i): String!, $num\(i): Int!")
        }
        let query = """
        query(\(varDecls.joined(separator: ", "))) {
        \(queryParts.joined(separator: "\n"))
        }
        """
        args.insert(contentsOf: ["-f", "query=\(query)"], at: 3)

        let output: String
        do {
            output = try await shellRunner.run(args: args, env: [:], cwd: nil)
        } catch ShellRunnerError.nonZeroExit(_, let stderr) {
            throw GitHubTaskBackend.classifyGraphQLError(stderr)
        }
        return Self.parseStalePRResponse(output, refs: refs)
    }

    // MARK: - fetchCrowAuthoredCommits

    public func fetchCrowAuthoredCommits(prURL: String, repoSlug: String, prNumber: Int) async throws -> [CommitInfo] {
        let endpoint = "/repos/\(repoSlug)/pulls/\(prNumber)/commits"
        let output = try await shellRunner.run(args: ["gh", "api", endpoint], env: [:], cwd: nil)
        guard let data = output.data(using: .utf8),
              let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return nodes.compactMap { node -> CommitInfo? in
            guard let commit = node["commit"] as? [String: Any],
                  let message = commit["message"] as? String else { return nil }
            let sha = (node["sha"] as? String) ?? ""
            return CommitInfo(sha: sha, message: message)
        }
    }

    // MARK: - fetchRecentDefaultBranchCommits

    /// Recent default-branch commits for revert detection (#694). Omitting
    /// the `sha` param makes the endpoint list the default branch. Single
    /// page of 100 — reverts are recent by definition, and the caller's
    /// periodic re-scan plus dedupe make coverage incremental on busy repos.
    public func fetchRecentDefaultBranchCommits(repoSlug: String, since: Date) async throws -> [CommitInfo] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let endpoint = "/repos/\(repoSlug)/commits?since=\(formatter.string(from: since))&per_page=100"
        let output = try await shellRunner.run(args: ["gh", "api", endpoint], env: [:], cwd: nil)
        guard let data = output.data(using: .utf8),
              let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return nodes.compactMap { node -> CommitInfo? in
            guard let commit = node["commit"] as? [String: Any],
                  let message = commit["message"] as? String else { return nil }
            let sha = (node["sha"] as? String) ?? ""
            return CommitInfo(sha: sha, message: message)
        }
    }

    // MARK: - fetchPRChangedFiles

    /// File paths changed by a PR, for post-merge-fix overlap (#694).
    /// Single page of 100 paths — the caller caps what it stores anyway,
    /// and overlap detection only needs a representative set.
    public func fetchPRChangedFiles(repoSlug: String, prNumber: Int) async throws -> [String] {
        let endpoint = "/repos/\(repoSlug)/pulls/\(prNumber)/files?per_page=100"
        let output = try await shellRunner.run(args: ["gh", "api", endpoint], env: [:], cwd: nil)
        guard let data = output.data(using: .utf8),
              let nodes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return nodes.compactMap { $0["filename"] as? String }
    }

    // MARK: - findRecentPRsForBranches

    public func findRecentPRsForBranches(_ candidates: [BranchCandidate]) async throws -> [BranchPRMatch] {
        var parsed: [(idx: Int, cand: BranchCandidate, owner: String, repo: String)] = []
        for (i, c) in candidates.enumerated() {
            let parts = c.repoSlug.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            parsed.append((i, c, String(parts[0]), String(parts[1])))
        }
        guard !parsed.isEmpty else { return [] }

        var queryParts: [String] = []
        var args: [String] = ["gh", "api", "graphql"]
        for p in parsed {
            queryParts.append("""
              pr\(p.idx): repository(owner: $owner\(p.idx), name: $repo\(p.idx)) {
                pullRequests(headRefName: $branch\(p.idx), first: 5, orderBy: {field: UPDATED_AT, direction: DESC}) {
                  nodes { number url state updatedAt headRefName }
                }
              }
            """)
            args.append(contentsOf: ["-F", "owner\(p.idx)=\(p.owner)"])
            args.append(contentsOf: ["-F", "repo\(p.idx)=\(p.repo)"])
            args.append(contentsOf: ["-F", "branch\(p.idx)=\(p.cand.branch)"])
        }
        var varDecls: [String] = []
        for p in parsed {
            varDecls.append("$owner\(p.idx): String!, $repo\(p.idx): String!, $branch\(p.idx): String!")
        }
        let query = """
        query(\(varDecls.joined(separator: ", "))) {
        \(queryParts.joined(separator: "\n"))
        }
        """
        args.insert(contentsOf: ["-f", "query=\(query)"], at: 3)

        let output: String
        do {
            output = try await shellRunner.run(args: args, env: [:], cwd: nil)
        } catch ShellRunnerError.nonZeroExit(_, let stderr) {
            throw GitHubTaskBackend.classifyGraphQLError(stderr)
        }
        return Self.parseRecentPRsResponse(output, parsed: parsed)
    }

    /// Search each repo for PRs whose title/body references `key` (e.g. a Jira
    /// key like `MAXX-6859`). One `gh pr list --search` call per candidate
    /// (the candidate set is small — only Jira-tasked sessions missing a PR
    /// link). Best-effort per repo: a failing repo is skipped, not fatal.
    public func findPRsMatchingKeys(_ candidates: [KeyCandidate]) async throws -> [KeyPRMatch] {
        var out: [KeyPRMatch] = []
        for c in candidates {
            guard c.repoSlug.split(separator: "/", maxSplits: 1).count == 2,
                  !c.key.isEmpty else { continue }
            let output: String
            do {
                output = try await shellRunner.run(
                    "gh", "pr", "list",
                    "--repo", c.repoSlug,
                    "--search", "\(c.key) in:title,body",
                    "--state", "all",
                    "--json", "number,url,state,updatedAt,title,headRefName,body",
                    "--limit", "10"
                )
            } catch {
                continue
            }
            out.append(contentsOf: Self.parseKeyPRMatches(output, candidate: c))
        }
        return out
    }

    /// Parse `gh pr list --json …` output into `KeyPRMatch`es. Post-filters to
    /// PRs where the key actually appears (case-insensitively) in the **title or
    /// head branch** — `gh`'s search can be fuzzy, and a key mentioned only in a
    /// PR's *body* (e.g. "related to MAXX-6854") belongs to a different ticket.
    /// Matching on body attached phantom PRs to sessions whose ticket had none
    /// (#520), so it is deliberately excluded.
    static func parseKeyPRMatches(_ output: String, candidate: KeyCandidate) -> [KeyPRMatch] {
        guard let data = output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime]
        let needle = candidate.key.lowercased()
        var matches: [KeyPRMatch] = []
        for node in arr {
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String else { continue }
            let title = (node["title"] as? String ?? "").lowercased()
            let head = (node["headRefName"] as? String ?? "").lowercased()
            guard title.contains(needle) || head.contains(needle) else { continue }
            let updatedAt = (node["updatedAt"] as? String).flatMap { dateFmt.date(from: $0) }
            matches.append(KeyPRMatch(
                candidate: candidate, number: number, url: url, state: state, updatedAt: updatedAt
            ))
        }
        return matches
    }

    // MARK: - enableAutoMerge / updateBranch

    public func addMergeLabel(prURL: String) async throws {
        // Direct argv (not `sh -c`) eliminates shell interpolation around
        // `prURL`; $TMPDIR cwd so gh doesn't infer the repo from the cwd.
        _ = try await shellRunner.run(
            args: ["gh", "pr", "edit", prURL, "--add-label", "crow:merge"],
            env: [:],
            cwd: NSTemporaryDirectory()
        )
    }

    public func enableAutoMerge(prURL: String) async throws {
        // Run inside $TMPDIR so gh doesn't pick up the cwd's git config when
        // detecting the repo. Direct argv (not `sh -c`) eliminates any shell
        // interpolation surface around `prURL`.
        _ = try await shellRunner.run(
            args: ["gh", "pr", "merge", prURL, "--auto", "--squash", "--delete-branch"],
            env: [:],
            cwd: NSTemporaryDirectory()
        )
    }

    public func updateBranch(prURL: String) async throws {
        _ = try await shellRunner.run(
            args: ["gh", "pr", "update-branch", prURL],
            env: [:],
            cwd: NSTemporaryDirectory()
        )
    }

    // MARK: - fetchPRMetadata

    public func fetchPRMetadata(prURL: String) async throws -> PRMetadata {
        let output = try await shellRunner.run(
            "gh", "pr", "view", prURL,
            "--json", "title,headRefName,headRefOid,baseRefName,number,author"
        )
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.commandFailed("fetchPRMetadata: failed to parse `gh pr view` output")
        }
        return PRMetadata(
            title: (json["title"] as? String) ?? "",
            number: (json["number"] as? Int) ?? 0,
            headRefName: (json["headRefName"] as? String) ?? "",
            headRefOid: (json["headRefOid"] as? String) ?? "",
            baseRefName: (json["baseRefName"] as? String) ?? "",
            author: ((json["author"] as? [String: Any])?["login"] as? String) ?? ""
        )
    }

    // MARK: - Queries + parsers

    static let monitoredPRsQuery = """
    query($reviewQuery: String!) {
      viewerPRs: viewer {
        pullRequests(first: 50, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number url state mergeable mergeStateStatus reviewDecision isDraft headRefName headRefOid baseRefName
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            closingIssuesReferences(first: 5) { nodes { number repository { nameWithOwner } } }
            statusCheckRollup {
              state
              contexts(first: 25) {
                nodes {
                  __typename
                  ... on CheckRun { name conclusion status }
                  ... on StatusContext { context state }
                }
              }
            }
            latestReviews(first: 20) { nodes { state submittedAt } }
            commits(last: 30) {
              nodes {
                commit {
                  oid
                  messageHeadline
                  committedDate
                  parents(first: 2) { totalCount }
                }
              }
            }
          }
        }
      }
      reviewPRs: search(type: ISSUE, query: $reviewQuery, first: 50) {
        nodes {
          ... on PullRequest {
            number title url isDraft updatedAt headRefName headRefOid baseRefName state
            author { login }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            reviews(last: 20) { nodes { author { login } submittedAt state } }
          }
        }
      }
      viewer { login }
      rateLimit { remaining limit resetAt cost }
    }
    """

    static func parseMonitoredPRsResponse(_ output: String) throws -> MonitoredPRListing {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            throw ProviderError.commandFailed("listMonitoredPRs: failed to parse GraphQL response")
        }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let viewerLogin = (dataObj["viewer"] as? [String: Any])?["login"] as? String ?? ""
        let viewerPRs = parseViewerPRs(dataObj["viewerPRs"] as? [String: Any])
        let reviewRequests = parseReviewRequests(
            dataObj["reviewPRs"] as? [String: Any],
            dateFormatter: dateFmt,
            viewerLogin: viewerLogin.isEmpty ? nil : viewerLogin
        )
        let rate = GitHubTaskBackend.parseRateLimit(dataObj["rateLimit"] as? [String: Any])
        return MonitoredPRListing(
            viewerPRs: viewerPRs,
            reviewRequests: reviewRequests,
            viewerLogin: viewerLogin,
            rateLimit: rate
        )
    }

    /// Recover the accessible-org PRs/reviews GitHub returned alongside a SAML
    /// `errors` entry. Mirrors `GitHubTaskBackend.recoverPartialIssues`: extract
    /// the leading JSON object from the merged `gh` blob, parse what resolved,
    /// and mark `samlRestricted`. Degrades to an empty listing (never throws)
    /// when no body is recoverable.
    static func recoverPartialMonitoredPRs(fromSAMLBlob blob: String) -> MonitoredPRListing {
        guard let dataObj = GitHubTaskBackend.decodeGraphQLData(blob) else {
            return MonitoredPRListing(viewerPRs: [], reviewRequests: [], viewerLogin: "", samlRestricted: true)
        }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let viewerLogin = (dataObj["viewer"] as? [String: Any])?["login"] as? String ?? ""
        let viewerPRs = parseViewerPRs(dataObj["viewerPRs"] as? [String: Any])
        let reviewRequests = parseReviewRequests(
            dataObj["reviewPRs"] as? [String: Any],
            dateFormatter: dateFmt,
            viewerLogin: viewerLogin.isEmpty ? nil : viewerLogin
        )
        let rate = GitHubTaskBackend.parseRateLimit(dataObj["rateLimit"] as? [String: Any])
        return MonitoredPRListing(
            viewerPRs: viewerPRs,
            reviewRequests: reviewRequests,
            viewerLogin: viewerLogin,
            rateLimit: rate,
            samlRestricted: true
        )
    }

    static func parseViewerPRs(_ viewerObj: [String: Any]?) -> [PRRecord] {
        guard let pullRequests = viewerObj?["pullRequests"] as? [String: Any],
              let nodes = pullRequests["nodes"] as? [[String: Any]] else { return [] }
        return nodes.compactMap { parsePRNode($0) }
    }

    static func parsePRNode(_ node: [String: Any]) -> PRRecord? {
        guard let number = node["number"] as? Int,
              let url = node["url"] as? String,
              let state = node["state"] as? String else { return nil }
        let mergeable = (node["mergeable"] as? String) ?? "UNKNOWN"
        let mergeStateStatus = (node["mergeStateStatus"] as? String) ?? "UNKNOWN"
        let reviewDecision = (node["reviewDecision"] as? String) ?? ""
        let isDraft = (node["isDraft"] as? Bool) ?? false
        let headRefName = (node["headRefName"] as? String) ?? ""
        let headRefOid = (node["headRefOid"] as? String) ?? ""
        let baseRefName = (node["baseRefName"] as? String) ?? ""
        let mergeCommitOid = (node["mergeCommit"] as? [String: Any])?["oid"] as? String
        let repoName = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
        let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
            .compactMap { labelNode -> LabelInfo? in
                guard let name = labelNode["name"] as? String else { return nil }
                return LabelInfo(name: name, color: labelNode["color"] as? String)
            } ?? []
        let linkedNodes = (node["closingIssuesReferences"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let linkedRefs: [LinkedIssueRef] = linkedNodes.compactMap { ref in
            guard let n = ref["number"] as? Int else { return nil }
            let r = (ref["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            return LinkedIssueRef(number: n, repo: r)
        }
        let rollup = node["statusCheckRollup"] as? [String: Any]
        let checksState = (rollup?["state"] as? String) ?? ""
        let contextNodes = ((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let failedCheckNames: [String] = contextNodes.compactMap { ctx in
            if let conclusion = ctx["conclusion"] as? String, conclusion == "FAILURE" {
                return ctx["name"] as? String
            }
            if let st = ctx["state"] as? String, st == "FAILURE" || st == "ERROR" {
                return ctx["context"] as? String
            }
            return nil
        }
        let latestReviewNodes = (node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let reviewStates = latestReviewNodes.compactMap { $0["state"] as? String }
        // Stateless "needs refine" rule (CROW-508): the latest CHANGES_REQUESTED
        // submission timestamp anchors "since when does the agent owe a
        // response?". `latestReviews(first: 20)` is intentionally broad
        // enough to cover several reviewers' latest reviews without paginating
        // — GitHub orders that connection by reviewer, not by recency, so a
        // narrow window could omit the CR we need.
        //
        // Parse with `parseGitHubDateTime` (tolerant of both fractional and
        // non-fractional). GitHub's GraphQL `DateTime` scalar emits
        // non-fractional ISO-8601 (`2026-06-15T01:28:17Z`), and an
        // `ISO8601DateFormatter` configured with `.withFractionalSeconds`
        // returns nil for that shape — silently disabling the rule.
        let lastChangesRequestedAt = latestReviewNodes
            .filter { ($0["state"] as? String) == "CHANGES_REQUESTED" }
            .compactMap { ($0["submittedAt"] as? String).flatMap(Self.parseGitHubDateTime) }
            .max()
        // Stateless "needs refine" rule (CROW-508): the latest non-merge,
        // non-rebase commit timestamp anchors "has the agent substantively
        // responded since the review?". A merge commit (parent count >= 2)
        // or a commit whose subject starts with `Merge branch|remote-tracking|
        // pull request` is excluded so the GitHub "Update branch" button
        // (default merge mode) and routine merges from main can't trick the
        // rule into thinking the agent pushed a fix.
        //
        // Known gap: a real `git rebase` (or "Update with rebase" on the
        // Update-branch dropdown) rewrites the *committer* date of the
        // existing feature commits to ~now. Those commits are not merge
        // commits, so they pass the filter and DO advance
        // `lastSubstantiveCommitAt` — a false negative the rule accepts as
        // the cost of avoiding a tree-equals-parents API call per PR per
        // poll. The ticket calls the tree check optional; we skip it in v1.
        let commitNodes = (node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        let lastSubstantiveCommitAt = commitNodes
            .compactMap { node -> Date? in
                guard let commit = node["commit"] as? [String: Any] else { return nil }
                let parents = (commit["parents"] as? [String: Any])?["totalCount"] as? Int ?? 1
                if parents >= 2 { return nil }
                let message = (commit["messageHeadline"] as? String) ?? ""
                if Self.isMergeCommitMessage(message) { return nil }
                return (commit["committedDate"] as? String).flatMap(Self.parseGitHubDateTime)
            }
            .max()
        return PRRecord(
            number: number,
            url: url,
            state: state,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: headRefName,
            headRefOid: headRefOid,
            baseRefName: baseRefName,
            repoNameWithOwner: repoName,
            labels: labels,
            linkedIssueReferences: linkedRefs,
            checksState: checksState,
            failedCheckNames: failedCheckNames,
            latestReviewStates: reviewStates,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt,
            mergeCommitOid: mergeCommitOid
        )
    }

    /// Decide whether a commit subject line indicates a rebase/merge that
    /// should NOT advance "agent substantively responded since review".
    /// Match anchored to the start of the line; the prefix list mirrors what
    /// `git merge` / GitHub's "Update branch" button produce. Public so
    /// `parsePRNode` and unit tests share the same definition.
    nonisolated static func isMergeCommitMessage(_ headline: String) -> Bool {
        let trimmed = headline.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("Merge branch ")
            || trimmed.hasPrefix("Merge remote-tracking ")
            || trimmed.hasPrefix("Merge pull request ")
    }

    /// Parse a GitHub `DateTime` scalar tolerantly. GitHub's GraphQL emits
    /// the non-fractional ISO-8601 form (`2026-06-15T01:28:17Z`), but
    /// `ISO8601DateFormatter` configured with `.withFractionalSeconds`
    /// returns nil for that shape, and the inverse configuration rejects
    /// any timestamp that DOES carry a fraction. Production code must
    /// tolerate both — a strict formatter silently disables features that
    /// depend on parsed timestamps (CROW-508 needsRefine was inert this
    /// way; see PR #509 review). We try the non-fractional form first
    /// (matches what GitHub actually emits today), then fall back to
    /// fractional for resilience against future API drift.
    ///
    /// Other call sites in this file still use the brittle pattern (see
    /// `parseReviewRequests`, `parseStaleMRResponse`, parseStaleStateResponse).
    /// They're out of scope for this PR but should migrate to this helper
    /// in a follow-up — same trap, different fields.
    nonisolated static func parseGitHubDateTime(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: raw) { return d }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw)
    }

    static func parseReviewRequests(
        _ searchObj: [String: Any]?,
        dateFormatter: ISO8601DateFormatter,
        viewerLogin: String?
    ) -> [ReviewRequest] {
        guard let nodes = searchObj?["nodes"] as? [[String: Any]] else { return [] }
        let satisfyingStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]
        var requests: [ReviewRequest] = []
        for node in nodes {
            guard let number = node["number"] as? Int,
                  let title = node["title"] as? String,
                  let url = node["url"] as? String else { continue }
            let repoName = (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            let authorLogin = (node["author"] as? [String: Any])?["login"] as? String ?? ""
            let isDraft = (node["isDraft"] as? Bool) ?? false
            let headBranch = (node["headRefName"] as? String) ?? ""
            let headRefOid = node["headRefOid"] as? String
            let baseBranch = (node["baseRefName"] as? String) ?? ""
            let updatedAt = (node["updatedAt"] as? String).flatMap { dateFormatter.date(from: $0) }
            let labels = ((node["labels"] as? [String: Any])?["nodes"] as? [[String: Any]])?
                .compactMap { labelNode -> LabelInfo? in
                    guard let name = labelNode["name"] as? String else { return nil }
                    return LabelInfo(name: name, color: labelNode["color"] as? String)
                } ?? []
            var viewerLastReviewedAt: Date?
            if let viewerLogin,
               let reviewNodes = ((node["reviews"] as? [String: Any])?["nodes"]) as? [[String: Any]] {
                for review in reviewNodes {
                    guard let author = (review["author"] as? [String: Any])?["login"] as? String,
                          author == viewerLogin,
                          let state = review["state"] as? String,
                          satisfyingStates.contains(state),
                          let submittedAtStr = review["submittedAt"] as? String,
                          let submittedAt = dateFormatter.date(from: submittedAtStr) else { continue }
                    if viewerLastReviewedAt == nil || submittedAt > viewerLastReviewedAt! {
                        viewerLastReviewedAt = submittedAt
                    }
                }
            }
            requests.append(ReviewRequest(
                id: "github:\(repoName)#\(number)",
                prNumber: number,
                title: title,
                url: url,
                repo: repoName,
                author: authorLogin,
                headBranch: headBranch,
                baseBranch: baseBranch,
                isDraft: isDraft,
                requestedAt: updatedAt,
                labels: labels,
                provider: .github,
                headRefOid: headRefOid,
                viewerLastReviewedAt: viewerLastReviewedAt
            ))
        }
        return requests.sorted { ($0.requestedAt ?? .distantPast) > ($1.requestedAt ?? .distantPast) }
    }

    static func parseStalePRResponse(_ output: String, refs: [PRRef]) -> [PRRef: PRRecord] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return [:] }
        var out: [PRRef: PRRecord] = [:]
        for (i, ref) in refs.enumerated() {
            guard let repoObj = dataObj["pr\(i)"] as? [String: Any],
                  let prObj = repoObj["pullRequest"] as? [String: Any],
                  let rec = parsePRNode(prObj) else { continue }
            out[ref] = rec
        }
        return out
    }

    static func parseRecentPRsResponse(
        _ output: String,
        parsed: [(idx: Int, cand: BranchCandidate, owner: String, repo: String)]
    ) -> [BranchPRMatch] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return [] }
        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var matches: [BranchPRMatch] = []
        for p in parsed {
            guard let repoObj = dataObj["pr\(p.idx)"] as? [String: Any],
                  let prs = repoObj["pullRequests"] as? [String: Any],
                  let nodes = prs["nodes"] as? [[String: Any]] else { continue }
            for node in nodes {
                guard let number = node["number"] as? Int,
                      let url = node["url"] as? String,
                      let state = node["state"] as? String else { continue }
                let updatedAt = (node["updatedAt"] as? String).flatMap { dateFmt.date(from: $0) }
                matches.append(BranchPRMatch(
                    candidate: p.cand,
                    number: number,
                    url: url,
                    state: state,
                    updatedAt: updatedAt
                ))
            }
        }
        return matches
    }
}
