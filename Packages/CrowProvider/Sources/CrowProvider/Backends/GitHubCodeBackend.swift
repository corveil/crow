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

    // MARK: - enableAutoMerge / updateBranch

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
            "--json", "title,headRefName,headRefOid,baseRefName,number"
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
            baseRefName: (json["baseRefName"] as? String) ?? ""
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
            latestReviews(first: 5) { nodes { id state submittedAt } }
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
        // Pick the round-2 dedup discriminator deterministically: the
        // CHANGES_REQUESTED review with the latest `submittedAt`. GitHub's
        // `latestReviews` connection doesn't document a node order, so we
        // don't rely on it; ISO-8601 with `Z` is lexicographically sortable
        // when the timezone is consistent (which GitHub guarantees), so a
        // string `max(by:)` is correct here without parsing dates.
        // `max(by:)` over an empty filtered array returns `nil`, which threads
        // through to PRStatus.latestReviewID = nil exactly as required.
        let latestReviewID = latestReviewNodes
            .filter { ($0["state"] as? String) == "CHANGES_REQUESTED" }
            .max(by: { ($0["submittedAt"] as? String ?? "") < ($1["submittedAt"] as? String ?? "") })?["id"] as? String
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
            latestReviewID: latestReviewID
        )
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
