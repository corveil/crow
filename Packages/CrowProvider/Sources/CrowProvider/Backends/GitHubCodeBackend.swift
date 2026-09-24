import Foundation
import CrowCore

/// `CodeBackend` implementation for GitHub. Wraps the `gh` CLI for PR/label operations.
///
/// Facade (CROW-1253): protocol methods, `capabilities`, `shellRunner`, and
/// the `gh` argv wrappers. GraphQL documents and `PRRecord` parsers live in
/// `GitHubCodeBackend+Parsing.swift` as `extension GitHubCodeBackend` so
/// `@testable` tests keep `GitHubCodeBackend.parseMonitoredPRsResponse` etc.
///
/// Capabilities:
/// - `.autoMergeLabel` — supports `gh label create crow:merge`.
/// - `.batchedPRStates` — batches multiple PR states in one GraphQL call.
/// - `.autoMerge` — supports `gh pr merge --auto --squash --delete-branch`.
/// - `.updateBranch` — supports `gh pr update-branch`.
/// - `.directMerge` — supports `gh pr merge --squash --delete-branch` (no `--auto`).
/// - `.requestReviewers` — supports `gh pr edit --add-reviewer`.
///
/// See ADR 0005 for the protocol contract.
public struct GitHubCodeBackend: CodeBackend {
    public let provider: Provider = .github
    public let cliName: String = "gh"
    public let capabilities: Set<CodeCapability> = [
        .autoMergeLabel,
        .batchedPRStates,
        .autoMerge,
        .updateBranch,
        .directMerge,
        .requestReviewers
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

    // MARK: - resolveCanonicalRepoSlug

    /// Resolve `slug` ("owner/repo") to GitHub's canonical `full_name` via the
    /// REST `/repos/{owner}/{repo}` endpoint, which 301-follows org/repo renames
    /// (unlike the GraphQL `repository(owner:name:)` this backend uses elsewhere,
    /// which returns null for a renamed owner — the root of CROW-1268). Returns
    /// the canonical "owner/repo", or `nil` when the repo doesn't exist under
    /// that slug (a definitive 404 the caller can cache rather than retry). Any
    /// other `gh` failure is rethrown so the caller treats it as transient.
    public func resolveCanonicalRepoSlug(_ slug: String) async throws -> String? {
        let trimmed = slug.trimmingCharacters(in: .whitespaces)
        guard trimmed.split(separator: "/").count == 2 else { return nil }
        do {
            let output = try await shellRunner.run(
                "gh", "api", "repos/\(trimmed)", "--jq", ".full_name"
            )
            let full = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return full.isEmpty ? nil : full
        } catch ShellRunnerError.nonZeroExit(_, let stderr)
            where stderr.localizedCaseInsensitiveContains("not found")
                || stderr.localizedCaseInsensitiveContains("404") {
            // Definitive: no repo at that slug. `nil` (not a throw) so the caller
            // caches the miss and stops re-querying it every poll.
            return nil
        }
    }

    // MARK: - listMonitoredPRs

    public func listMonitoredPRs() async throws -> MonitoredPRListing {
        let reviewQuery = "review-requested:@me state:open type:pr"
        // The board's post-request half (CROW-982, widened by CROW-990). This
        // has to be its own search: submitting a review clears the pending
        // request, so a reviewed PR leaves `review-requested:@me` outright and
        // no filtering of that result set could ever recover it.
        //
        // Two searches, because "still open" and "already finished" are disjoint
        // GitHub states that no single query expresses: `state:open` for PRs
        // parked with their author, and a closed-since window for PRs that
        // merged or closed. Both ride in the *same* GraphQL document as the
        // query above, so they are two more search nodes on an existing request
        // rather than extra HTTP round trips. `sort:updated-desc` matters at
        // `first: 50`: a review bumps the PR's `updatedAt`, so the rows these
        // groups want sort to the front instead of relying on relevance order.
        let reviewedQuery = "reviewed-by:@me state:open type:pr sort:updated-desc"
        let completedQuery = Self.completedReviewsQuery(now: Date())
        let output: String
        do {
            output = try await shellRunner.run(
                "gh", "api", "graphql",
                "-f", "query=\(Self.monitoredPRsQuery)",
                "-F", "reviewQuery=\(reviewQuery)",
                "-F", "reviewedQuery=\(reviewedQuery)",
                "-F", "completedQuery=\(completedQuery)"
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

    public func prStates(refs: [PRRef], viewerLogin: String?) async throws -> [PRRef: PRRecord] {
        guard !refs.isEmpty else { return [:] }
        // The viewer's own latest *verdict* on each PR (CROW-945). This is the
        // signal that closes a review round, and it has to come from the PR
        // itself: the `review-requested:@me` search that used to be its only
        // source drops the PR the instant the viewer submits a review, i.e.
        // exactly when the round should close. A review session's PR is
        // authored by someone else, so it is never in `viewerPRs` and always
        // lands here — this query already runs every poll, so the signal costs
        // no extra API call.
        //
        // `states:` is load-bearing, not decoration. GraphQL's
        // `viewerLatestReview` takes no arguments and returns the latest review
        // of ANY state, so a follow-up `--comment` review (COMMENTED) or an
        // unsubmitted draft (PENDING, null `submittedAt`) would mask a real
        // CHANGES_REQUESTED verdict and reproduce CROW-945 through a new field.
        // Filtering server-side also beats scanning `reviews(last: 20)`: one
        // node per alias instead of twenty, and immune to the >20-review
        // truncation that the search path's unfiltered scan still has.
        //
        // Omitted entirely when the login is unknown (a failed
        // `listMonitoredPRs` earlier in the cycle), leaving the field nil —
        // "not fetched", never "no review". See `PRRecord`.
        let viewer = viewerLogin?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Sorted so the query text is stable across runs (a Set's iteration
        // order is not) — an unstable query string would defeat any response
        // caching and make diffing two `gh` invocations pointless.
        let states = Self.roundClosingReviewStates.sorted().joined(separator: ", ")
        let reviewsSelection = viewer.isEmpty ? "" : """

                  reviews(last: 1, author: $viewer, states: [\(states)]) {
                    nodes { state submittedAt }
                  }
            """
        var queryParts: [String] = []
        var args: [String] = ["gh", "api", "graphql"]
        for (i, ref) in refs.enumerated() {
            queryParts.append("""
              pr\(i): repository(owner: $owner\(i), name: $repo\(i)) {
                pullRequest(number: $num\(i)) {
                  number url state mergeable mergeStateStatus reviewDecision isDraft
                  headRefName headRefOid baseRefName
                  mergeCommit { oid }
                  repository { nameWithOwner autoMergeAllowed }
                  labels(first: 20) { nodes { name color } }
                  statusCheckRollup {
                    state
                    contexts(first: 25) {
                      nodes {
                        __typename
                        ... on CheckRun { name conclusion status }
                        ... on StatusContext { context state }
                      }
                    }
                  }\(reviewsSelection)
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
        if !viewer.isEmpty {
            varDecls.append("$viewer: String!")
            // `-f`, not `-F`: `-F` type-infers, so an all-digit login would be
            // sent as an Int and fail the `String!` variable.
            args.append(contentsOf: ["-f", "viewer=\(viewer)"])
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
            let err = GitHubTaskBackend.classifyGraphQLError(stderr)
            if case .samlRestricted(let blob) = err {
                // One SAML-restricted repo in the batch nullifies only its own
                // `prN` alias; every other alias resolved. Recover those rather
                // than losing state for every stale PR in the cycle (#894).
                return Self.recoverPartialStalePRStates(fromSAMLBlob: blob, refs: refs)
            }
            throw err
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

    /// Search each repo for PRs whose title/body references `key`. `key` is
    /// either a Jira ticket key (`MAXX-6859`) or a GitHub issue number (`#473`).
    /// One `gh pr list --search` call per candidate (the set is small — sessions
    /// missing a PR link). Best-effort per repo: a failing repo is skipped, not
    /// fatal.
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
            if Self.isGitHubIssueKey(c.key) {
                out.append(contentsOf: Self.parseGitHubIssuePRMatches(output, candidate: c))
            } else {
                out.append(contentsOf: Self.parseKeyPRMatches(output, candidate: c))
            }
        }
        return out
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

    /// Same invocation as `enableAutoMerge` minus `--auto`, which is the whole
    /// difference: `--auto` queues the merge behind GitHub's required checks
    /// and reviews, while this merges immediately. GitHub still refuses if the
    /// PR is genuinely unmergeable, but it will NOT wait for pending checks —
    /// so callers must have verified greenness themselves (#888).
    public func mergeNow(prURL: String) async throws {
        _ = try await shellRunner.run(
            args: ["gh", "pr", "merge", prURL, "--squash", "--delete-branch"],
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

    /// Re-request review (CROW-921). Same direct-argv + `$TMPDIR` cwd
    /// convention as `addMergeLabel`: no `sh -c`, so nothing in `prURL` or a
    /// login reaches a shell.
    ///
    /// Logins are additionally filtered through `isSafeReviewerLogin` before
    /// they become argv. Direct argv already rules out shell metacharacters,
    /// but not *flag* injection — a login of `--add-label` would be read by
    /// `gh` as an option, not a value. Throws rather than silently sending a
    /// short list, so the caller can log a real reason instead of recording a
    /// success that re-requested nobody.
    public func requestReviewers(prURL: String, logins: [String]) async throws {
        let safe = logins.filter(Self.isSafeReviewerLogin)
        guard !safe.isEmpty else {
            throw ProviderError.commandFailed(
                "requestReviewers: no usable reviewer logins in \(logins)")
        }
        guard safe.count == logins.count else {
            throw ProviderError.commandFailed(
                "requestReviewers: refusing malformed reviewer login in \(logins)")
        }
        _ = try await shellRunner.run(
            args: ["gh", "pr", "edit", prURL] + safe.flatMap { ["--add-reviewer", $0] },
            env: [:],
            cwd: NSTemporaryDirectory()
        )
    }

    /// A GitHub login: alphanumeric with interior hyphens, 1–39 characters.
    /// Deliberately stricter than GitHub's own rule — anything that can't be a
    /// login is rejected rather than normalized, because the only ways to get
    /// here are a parse bug or a hostile API response, and both deserve an
    /// error. `nonisolated static` so tests share the exact definition.
    nonisolated static func isSafeReviewerLogin(_ login: String) -> Bool {
        guard !login.isEmpty, login.count <= 39 else { return false }
        guard let first = login.first, first.isASCII, first.isLetter || first.isNumber else {
            return false
        }
        return login.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
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
}
