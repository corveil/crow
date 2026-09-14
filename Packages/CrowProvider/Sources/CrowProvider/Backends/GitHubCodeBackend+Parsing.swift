import Foundation
import CrowCore

/// GraphQL documents and `PRRecord` parsers for GitHub PRs.
///
/// Extracted from `GitHubCodeBackend` (CROW-1253). Symbols stay on
/// `GitHubCodeBackend` via this extension so `@testable` tests keep
/// `GitHubCodeBackend.parseMonitoredPRsResponse` / `monitoredPRsQuery`
/// / `parsePRNode` and so `listMonitoredPRs` / `prStates` keep calling
/// the same statics. Query shape, `PRRecord` field meaning, SAML
/// degrade-not-fail, and Reviews-board grouping are unchanged.

extension GitHubCodeBackend {
    // MARK: - Recently completed search

    /// The **Recently completed** search (CROW-990) — PRs the viewer reviewed
    /// that merged or closed inside the window.
    ///
    /// `is:closed` covers merged PRs too (GitHub models a merge as a close), so
    /// one qualifier reaches both halves of the group — including the case the
    /// ticket calls out, where you requested changes, the author fixed it, and
    /// *someone else* approved and merged.
    ///
    /// The `closed:` bound is a full ISO-8601 instant, not a `YYYY-MM-DD` date:
    /// a date bound would return up to 48 h of history depending on the hour,
    /// which the serialization-time cutoff would then have to throw away. It is
    /// intentionally still only a *coarse* bound — the authoritative 24 h edge
    /// is `ReviewGroup.classify`, evaluated on each render, so the tail expires
    /// on the clock rather than on the next poll.
    static func completedReviewsQuery(now: Date) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        let since = fmt.string(from: now.addingTimeInterval(-ReviewGroup.recentlyCompletedWindow))
        return "reviewed-by:@me is:closed type:pr closed:>=\(since) sort:updated-desc"
    }

    // MARK: - Reconcile parsers

    /// A GitHub issue-number key is `#` plus digits (`#473`). Distinct from a
    /// Jira key (`MAXX-6859`) so the two post-filters cannot be confused.
    static func isGitHubIssueKey(_ key: String) -> Bool {
        guard key.first == "#" else { return false }
        let digits = key.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber), let n = Int(digits) else { return false }
        return n > 0
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
        let needle = candidate.key.lowercased()
        var matches: [KeyPRMatch] = []
        for node in arr {
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String else { continue }
            let title = (node["title"] as? String ?? "").lowercased()
            let head = (node["headRefName"] as? String ?? "").lowercased()
            guard title.contains(needle) || head.contains(needle) else { continue }
            let updatedAt = IssueDate.parse(node["updatedAt"] as? String)
            matches.append(KeyPRMatch(
                candidate: candidate, number: number, url: url, state: state, updatedAt: updatedAt
            ))
        }
        return matches
    }

    /// Parse `gh pr list --json …` for a GitHub issue-number candidate (`#473`).
    /// Unlike the Jira-key filter, a match in the **body** is the whole point:
    /// Crow's workspace skill writes `Closes #N` there. Require a GitHub closing
    /// keyword (`close[sd]?` / `fix(e[sd])?` / `resolve[sd]?`) so a passing
    /// "related to #473" does not attach a phantom PR (#520 analog, CROW-1221).
    static func parseGitHubIssuePRMatches(_ output: String, candidate: KeyCandidate) -> [KeyPRMatch] {
        guard let issueNumber = Int(candidate.key.dropFirst()), issueNumber > 0,
              let data = output.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var matches: [KeyPRMatch] = []
        for node in arr {
            guard let number = node["number"] as? Int,
                  let url = node["url"] as? String,
                  let state = node["state"] as? String else { continue }
            let title = node["title"] as? String ?? ""
            let body = node["body"] as? String ?? ""
            guard prReferencesGitHubIssue(
                title: title, body: body, repoSlug: candidate.repoSlug, number: issueNumber
            ) else { continue }
            let updatedAt = IssueDate.parse(node["updatedAt"] as? String)
            matches.append(KeyPRMatch(
                candidate: candidate, number: number, url: url, state: state, updatedAt: updatedAt
            ))
        }
        return matches
    }

    /// Whether `title`/`body` reference GitHub issue `number` with a closing
    /// keyword GitHub itself honors: close/closes/closed, fix/fixes/fixed,
    /// resolve/resolves/resolved, optional colon, then `#N`, `owner/repo#N`,
    /// or `https://github.com/owner/repo/issues/N`. Bare `#N` without a keyword
    /// is not enough — that is how "related to #473" attached the wrong PR.
    static func prReferencesGitHubIssue(
        title: String, body: String, repoSlug: String, number: Int
    ) -> Bool {
        let n = String(number)
        let escapedSlug = NSRegularExpression.escapedPattern(for: repoSlug)
        let keyword = #"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s*"#
        let haystack = title + "\n" + body
        let patterns = [
            keyword + "#\(n)\\b",
            keyword + "https?://github\\.com/\(escapedSlug)/issues/\(n)\\b",
            keyword + "\(escapedSlug)#\(n)\\b",
        ]
        return patterns.contains { haystack.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: - Queries + parsers

    static let monitoredPRsQuery = """
    query($reviewQuery: String!, $reviewedQuery: String!, $completedQuery: String!) {
      viewerPRs: viewer {
        pullRequests(first: 50, states: [OPEN], orderBy: {field: UPDATED_AT, direction: DESC}) {
          nodes {
            number url state mergeable mergeStateStatus reviewDecision isDraft headRefName headRefOid baseRefName
            repository { nameWithOwner autoMergeAllowed }
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
            latestReviews(first: 20) { nodes { author { login } state submittedAt } }
            reviewRequests(first: 20) {
              totalCount
              nodes { requestedReviewer { __typename ... on User { login } } }
            }
            commits(last: 30) {
              nodes {
                commit {
                  oid
                  messageHeadline
                  committedDate
                  authoredDate
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
            mergedAt closedAt
            author { login }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            reviews(last: 20) { nodes { author { login } submittedAt state commit { oid } } }
          }
        }
      }
      reviewedPRs: search(type: ISSUE, query: $reviewedQuery, first: 50) {
        nodes {
          ... on PullRequest {
            number title url isDraft updatedAt headRefName headRefOid baseRefName state
            mergedAt closedAt
            author { login }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            reviews(last: 20) { nodes { author { login } submittedAt state commit { oid } } }
          }
        }
      }
      completedPRs: search(type: ISSUE, query: $completedQuery, first: 50) {
        nodes {
          ... on PullRequest {
            number title url isDraft updatedAt headRefName headRefOid baseRefName state
            mergedAt closedAt
            author { login }
            repository { nameWithOwner }
            labels(first: 20) { nodes { name color } }
            reviews(last: 20) { nodes { author { login } submittedAt state commit { oid } } }
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
        let viewerLogin = (dataObj["viewer"] as? [String: Any])?["login"] as? String ?? ""
        let viewerPRs = parseViewerPRs(dataObj["viewerPRs"] as? [String: Any])
        let reviewRequests = parseReviewRequests(
            dataObj["reviewPRs"] as? [String: Any],
            viewerLogin: viewerLogin.isEmpty ? nil : viewerLogin
        )
        let reviewed = parseReviewedPRs(
            open: dataObj["reviewedPRs"] as? [String: Any],
            completed: dataObj["completedPRs"] as? [String: Any],
            viewerLogin: viewerLogin.isEmpty ? nil : viewerLogin
        )
        let rate = GitHubTaskBackend.parseRateLimit(dataObj["rateLimit"] as? [String: Any])
        return MonitoredPRListing(
            viewerPRs: viewerPRs,
            reviewRequests: reviewRequests,
            reviewedPRs: reviewed,
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
        let viewerLogin = (dataObj["viewer"] as? [String: Any])?["login"] as? String ?? ""
        let viewerPRs = parseViewerPRs(dataObj["viewerPRs"] as? [String: Any])
        let reviewRequests = parseReviewRequests(
            dataObj["reviewPRs"] as? [String: Any],
            viewerLogin: viewerLogin.isEmpty ? nil : viewerLogin
        )
        let reviewed = parseReviewedPRs(
            open: dataObj["reviewedPRs"] as? [String: Any],
            completed: dataObj["completedPRs"] as? [String: Any],
            viewerLogin: viewerLogin.isEmpty ? nil : viewerLogin
        )
        let rate = GitHubTaskBackend.parseRateLimit(dataObj["rateLimit"] as? [String: Any])
        return MonitoredPRListing(
            viewerPRs: viewerPRs,
            reviewRequests: reviewRequests,
            reviewedPRs: reviewed,
            viewerLogin: viewerLogin,
            rateLimit: rate,
            samlRestricted: true
        )
    }

    static func parseViewerPRs(_ viewerObj: [String: Any]?) -> [PRRecord] {
        // `LenientJSON`, not `as? [[String: Any]]` (#894): GitHub nullifies the
        // individual nodes it won't resolve under SAML enforcement, and the
        // all-or-nothing array cast dropped every accessible PR alongside them.
        LenientJSON.nodes(viewerObj, "pullRequests").compactMap { parsePRNode($0) }
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
        // `Repository.autoMergeAllowed` — the repo's "Allow auto-merge" setting.
        // Deliberately NOT defaulted to a Bool: a query that didn't select the
        // field (or a partial SAML recovery) must read as unknown, not as
        // "auto-merge is forbidden", which would strand every PR in the repo
        // (#888). Same manual cast as `repoName` above — `repository` is a plain
        // object, not a connection, so `LenientJSON.nodes` (#896) doesn't apply.
        let repoAutoMergeAllowed = (node["repository"] as? [String: Any])?["autoMergeAllowed"] as? Bool
        let labels = LenientJSON.nodes(node, "labels")
            .compactMap { labelNode -> LabelInfo? in
                guard let name = labelNode["name"] as? String else { return nil }
                return LabelInfo(name: name, color: labelNode["color"] as? String)
            }
        let linkedNodes = LenientJSON.nodes(node, "closingIssuesReferences")
        let linkedRefs: [LinkedIssueRef] = linkedNodes.compactMap { ref in
            guard let n = ref["number"] as? Int else { return nil }
            let r = (ref["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            return LinkedIssueRef(number: n, repo: r)
        }
        let rollup = node["statusCheckRollup"] as? [String: Any]
        let checksState = (rollup?["state"] as? String) ?? ""
        let contextNodes = LenientJSON.nodes(rollup, "contexts")
        let failedCheckNames: [String] = contextNodes.compactMap { ctx in
            if let conclusion = ctx["conclusion"] as? String, conclusion == "FAILURE" {
                return ctx["name"] as? String
            }
            if let st = ctx["state"] as? String, st == "FAILURE" || st == "ERROR" {
                return ctx["context"] as? String
            }
            return nil
        }
        let latestReviewNodes = LenientJSON.nodes(node, "latestReviews")
        let reviewStates = latestReviewNodes.compactMap { $0["state"] as? String }
        // Stateless "needs refine" rule (CROW-508): the latest CHANGES_REQUESTED
        // submission timestamp anchors "since when does the agent owe a
        // response?". `latestReviews(first: 20)` is intentionally broad
        // enough to cover several reviewers' latest reviews without paginating
        // — GitHub orders that connection by reviewer, not by recency, so a
        // narrow window could omit the CR we need.
        //
        // Parse with `IssueDate.parse` (tolerant of both fractional and
        // non-fractional). GitHub's GraphQL `DateTime` scalar emits
        // non-fractional ISO-8601 (`2026-06-15T01:28:17Z`), and an
        // `ISO8601DateFormatter` configured with `.withFractionalSeconds`
        // returns nil for that shape — silently disabling the rule.
        let lastChangesRequestedAt = latestReviewNodes
            .filter { ($0["state"] as? String) == "CHANGES_REQUESTED" }
            .compactMap { IssueDate.parse($0["submittedAt"] as? String) }
            .max()
        // Stateless "needs refine" rule (CROW-508): the latest non-merge,
        // non-rebase commit timestamp anchors "has the agent substantively
        // responded since the review?". A merge commit (parent count >= 2)
        // or a commit whose subject starts with `Merge branch|remote-tracking|
        // pull request` is excluded so the GitHub "Update branch" button
        // (default merge mode) and routine merges from main can't trick the
        // rule into thinking the agent pushed a fix.
        //
        // `authoredDate`, NOT `committedDate` (CROW-921). A real `git rebase`
        // (or "Update with rebase" on the Update-branch dropdown) replays the
        // existing feature commits with their *committer* date rewritten to
        // ~now. Those commits aren't merge commits, so under the old
        // committer-date rule they advanced `lastSubstantiveCommitAt` and the
        // needs-refine rule read a rebase as "the agent pushed a fix" — the
        // false negative that let CROW-921's PR park in CHANGES_REQUESTED
        // forever. `authoredDate` survives a rebase untouched, costs nothing
        // extra (same GraphQL node), and is cheaper than the tree-equality
        // check CROW-508 deferred.
        //
        // Accepted gap: `git commit --amend` and `git cherry-pick` ALSO
        // preserve `authoredDate` while rewriting `committedDate`, so a fix
        // delivered by amending is indistinguishable from a rebase using
        // dates alone (telling them apart needs the deferred tree check).
        // Both failure directions are the safe ones — needs-refine keeps
        // nudging the agent (bounded by its cooldown) and the CROW-921
        // re-request watcher stays quiet, so nobody pings a human reviewer
        // with a no-op review round.
        let commitNodes = LenientJSON.nodes(node, "commits")
        let lastSubstantiveCommitAt = commitNodes
            .compactMap { node -> Date? in
                guard let commit = node["commit"] as? [String: Any] else { return nil }
                let parents = (commit["parents"] as? [String: Any])?["totalCount"] as? Int ?? 1
                if parents >= 2 { return nil }
                let message = (commit["messageHeadline"] as? String) ?? ""
                if Self.isMergeCommitMessage(message) { return nil }
                return IssueDate.parse(commit["authoredDate"] as? String)
            }
            .max()
        // Who is blocking the PR right now, for the CROW-921 re-request
        // watcher. `latestReviews` is one review per author, so filtering to
        // CHANGES_REQUESTED yields exactly the reviewers whose verdict still
        // stands. Deduped but order-stable so the log and the `gh` argv read
        // the same way twice.
        var seenLogins: Set<String> = []
        let changesRequestedReviewerLogins = latestReviewNodes
            .filter { ($0["state"] as? String) == "CHANGES_REQUESTED" }
            .compactMap { ($0["author"] as? [String: Any])?["login"] as? String }
            .filter { !$0.isEmpty && seenLogins.insert($0).inserted }
        // Whether anyone has already been asked to look again, and who.
        //
        // Review requests are **per reviewer**: when A submits a review the
        // host clears only A's request, so a PR can carry a CHANGES_REQUESTED
        // verdict from A while B's original request is still pending. A
        // PR-wide "is anything pending" boolean therefore cannot decide
        // anything — an unrelated pending reviewer would read as "the ball is
        // with the reviewer" and silence both halves of the loop for a PR
        // whose findings nobody has addressed (review of #930).
        //
        // So carry both: the User logins (Teams have no login and are
        // deliberately not folded in — a team slug could collide with a user
        // login, and the intersection below is against review *authors*, who
        // are always Users), plus `totalCount` for the "anything at all"
        // question, which is the only thing a Team request can answer.
        // `PRStatus.changesRequestedReviewerIsPending` combines them.
        let reviewRequestsObj = node["reviewRequests"] as? [String: Any]
        let pendingReviewerLogins = LenientJSON.nodes(node, "reviewRequests")
            .compactMap { ($0["requestedReviewer"] as? [String: Any])?["login"] as? String }
            .filter { !$0.isEmpty }
        let hasPendingReviewRequest = ((reviewRequestsObj?["totalCount"] as? Int) ?? 0) > 0
        // The viewer's own latest verdict, from the `reviews(author:, states:)`
        // selection the stale-PR query adds (CROW-945). Absent on every other
        // path, which leaves this nil — "not fetched", never "no review".
        //
        // The state filter is redundant against today's query (which already
        // filters server-side) and kept anyway: it is the assertion that only a
        // verdict closes a round, so a future selection-set edit that widened
        // or dropped `states:` would degrade to "no timestamp" rather than
        // silently start closing rounds on a COMMENTED review.
        let viewerLastReviewedAt = LenientJSON.nodes(node, "reviews")
            .filter { Self.roundClosingReviewStates.contains(($0["state"] as? String) ?? "") }
            .compactMap { IssueDate.parse($0["submittedAt"] as? String) }
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
            changesRequestedReviewerLogins: changesRequestedReviewerLogins,
            pendingReviewerLogins: pendingReviewerLogins,
            hasPendingReviewRequest: hasPendingReviewRequest,
            viewerLastReviewedAt: viewerLastReviewedAt,
            mergeCommitOid: mergeCommitOid,
            repoAutoMergeAllowed: repoAutoMergeAllowed
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

    /// Review states that constitute a *verdict* and therefore close a review
    /// round. COMMENTED and PENDING are excluded on purpose: `crow-review-pr`
    /// mandates `--request-changes`/`--approve` and forbids `--comment`, so a
    /// comment is notes without a decision and the round stays open. PENDING is
    /// an unsubmitted draft and carries no `submittedAt` at all.
    ///
    /// Shared by the two paths that answer "has the viewer closed this round?" —
    /// `parseReviewRequests` (the `review-requested:@me` search) and
    /// `parsePRNode` (the stale-PR query, which also passes these to GraphQL as
    /// `states:`). One definition so the two can't drift into disagreeing about
    /// what closes a round. Both feed `decideReviewCompletions`, which
    /// auto-completes a review session — hence the narrowness.
    static let roundClosingReviewStates: Set<String> = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]

    /// Every review state the **board** routes on — a strict superset that adds
    /// COMMENTED (CROW-990).
    ///
    /// The two sets answer different questions and must stay separate. "Is my
    /// review round over?" excludes a comment; "who owes the next move?" does
    /// not — a PR you left comments on is parked with its author, and narrowing
    /// this to `roundClosingReviewStates` is precisely what left three such PRs
    /// in no group at all. Widening `roundClosingReviewStates` instead would
    /// make a `--comment` review auto-complete a live review session, which
    /// CROW-945 deliberately forbids.
    static let boardVerdictReviewStates: Set<String> = roundClosingReviewStates.union(["COMMENTED"])

    /// - Parameter acceptedStates: which review states count as the viewer's
    ///   last word. Defaults to the round-closing set because the requested
    ///   queue's `viewerLastReviewedAt` feeds `decideReviewCompletions`; the
    ///   board-only `reviewed-by:@me` paths widen it.
    static func parseReviewRequests(
        _ searchObj: [String: Any]?,
        viewerLogin: String?,
        acceptedStates: Set<String> = roundClosingReviewStates
    ) -> [ReviewRequest] {
        let nodes = LenientJSON.nodes(searchObj)
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
            let updatedAt = IssueDate.parse(node["updatedAt"] as? String)
            let prState = node["state"] as? String
            // `mergedAt` first: a merged PR carries both, and the merge is the
            // event the Recently completed window measures from.
            let completedAt = IssueDate.parse(node["mergedAt"] as? String)
                ?? IssueDate.parse(node["closedAt"] as? String)
            let labels = LenientJSON.nodes(node, "labels")
                .compactMap { labelNode -> LabelInfo? in
                    guard let name = labelNode["name"] as? String else { return nil }
                    return LabelInfo(name: name, color: labelNode["color"] as? String)
                }
            var viewerLastReviewedAt: Date?
            var viewerLastReviewState: ReviewVerdict?
            var viewerLastReviewedHeadSha: String?
            if let viewerLogin {
                for review in LenientJSON.nodes(node, "reviews") {
                    guard let author = (review["author"] as? [String: Any])?["login"] as? String,
                          author == viewerLogin,
                          let state = review["state"] as? String,
                          acceptedStates.contains(state),
                          let submittedAt = IssueDate.parse(review["submittedAt"] as? String) else { continue }
                    if viewerLastReviewedAt == nil || submittedAt > viewerLastReviewedAt! {
                        viewerLastReviewedAt = submittedAt
                        // Decoded from the same node as the timestamp, so the
                        // pair can never disagree about which review won. Both
                        // accepted-state sets are subsets of `ReviewVerdict`'s
                        // raw values, so this never fails — but a `nil` here
                        // would leave a timestamp with no verdict, so drop the
                        // timestamp too rather than emit a half record the
                        // board would misclassify.
                        viewerLastReviewState = ReviewVerdict(rawValue: state)
                        if viewerLastReviewState == nil { viewerLastReviewedAt = nil }
                        // The head this review was submitted against (CROW-997).
                        // Assigned unconditionally inside the winner branch — an
                        // absent `commit` must *clear* a previous round's SHA,
                        // not leave it behind, or the board would compare the
                        // current head against a review two rounds old and read
                        // "author pushed" as "nothing new".
                        viewerLastReviewedHeadSha = (review["commit"] as? [String: Any])?["oid"] as? String
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
                viewerLastReviewedAt: viewerLastReviewedAt,
                viewerLastReviewState: viewerLastReviewState,
                viewerLastReviewedHeadSha: viewerLastReviewedHeadSha,
                state: prState,
                completedAt: completedAt
            ))
        }
        return requests.sorted { ($0.requestedAt ?? .distantPast) > ($1.requestedAt ?? .distantPast) }
    }

    /// The `reviewed-by:@me` half of the board — PRs that have already **left**
    /// the requested queue (CROW-982, widened by CROW-990).
    ///
    /// Two searches in, one list out. `open` is `state:open` (PRs parked with
    /// their author, or approved and not yet merged); `completed` is the
    /// closed-since window (merged or closed). They are merged here rather than
    /// carried separately because every consumer downstream wants the same
    /// thing — "PRs I reviewed that nothing is asking me about" — and
    /// `ReviewGroup.classify` already reads the lifecycle state off each row to
    /// decide which heading it belongs under.
    ///
    /// **No verdict filter.** CROW-982 kept only approvals here, on the
    /// reasoning that a changes-requested PR would already be in the requested
    /// queue. It isn't: GitHub clears the pending request on submit, so that
    /// filter didn't dedupe those rows, it deleted them — eight live PRs
    /// visible nowhere in Crow. Routing is `classify`'s job now, and it is the
    /// only place that decides.
    ///
    /// The 24 h cutoff is deliberately *not* applied here: it belongs at
    /// serialization time so the window tracks the clock rather than the poll.
    static func parseReviewedPRs(
        open: [String: Any]?,
        completed: [String: Any]?,
        viewerLogin: String?
    ) -> [ReviewRequest] {
        // No login means the `viewer { login }` selection failed (a degraded or
        // SAML-partial response). Every verdict would parse as nil, so every row
        // would classify into no group anyway — return early and make the "not
        // fetched" case explicit rather than incidental.
        guard let viewerLogin, !viewerLogin.isEmpty else { return [] }
        let openRows = parseReviewRequests(open, viewerLogin: viewerLogin, acceptedStates: boardVerdictReviewStates)
        let completedRows = parseReviewRequests(completed, viewerLogin: viewerLogin, acceptedStates: boardVerdictReviewStates)
        // `state:open` and `is:closed` are mutually exclusive within one index
        // snapshot, so an overlap should be impossible — but a PR rendering
        // twice is a visible bug and this costs one dictionary, so the completed
        // row wins by construction rather than by trusting GitHub's indexer.
        var byURL: [String: ReviewRequest] = [:]
        for row in openRows { byURL[row.url] = row }
        for row in completedRows { byURL[row.url] = row }
        return byURL.values.sorted { ($0.requestedAt ?? .distantPast) > ($1.requestedAt ?? .distantPast) }
    }

    static func parseStalePRResponse(_ output: String, refs: [PRRef]) -> [PRRef: PRRecord] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return [:] }
        return parseStalePRData(dataObj, refs: refs)
    }

    /// Parse an already-decoded GraphQL `data` object into per-ref records.
    ///
    /// Split out of `parseStalePRResponse` so the SAML partial-recovery path can
    /// feed it `GitHubTaskBackend.decodeGraphQLData`'s output — that helper peels
    /// the trailing `gh:` error line off the merged stdout+stderr blob, which a
    /// plain `JSONSerialization` pass on the raw blob cannot do.
    ///
    /// Per-ref nulls are already tolerated: GitHub nullifies the whole `prN`
    /// alias for a repo the token can't reach, and `dataObj["pr\(i)"] as?
    /// [String: Any]` yields nil for `NSNull`, so that ref is simply absent.
    static func parseStalePRData(_ dataObj: [String: Any], refs: [PRRef]) -> [PRRef: PRRecord] {
        var out: [PRRef: PRRecord] = [:]
        for (i, ref) in refs.enumerated() {
            guard let repoObj = dataObj["pr\(i)"] as? [String: Any],
                  let prObj = repoObj["pullRequest"] as? [String: Any],
                  let rec = parsePRNode(prObj) else { continue }
            out[ref] = rec
        }
        return out
    }

    /// Recover the accessible-repo PR states GitHub returned alongside a SAML
    /// `errors` entry. Symmetric with `recoverPartialMonitoredPRs`: `prStates`
    /// batches every stale ref into one aliased query, so one SAML-restricted
    /// repo made `gh` exit non-zero and took every *other* ref's state down
    /// with it (#894). GitHub nullifies only the offending `prN` alias and
    /// resolves the rest; recover those.
    ///
    /// Returns `[:]` when no body is recoverable — the caller treats that
    /// identically to "no stale states", and this never throws.
    static func recoverPartialStalePRStates(fromSAMLBlob blob: String, refs: [PRRef]) -> [PRRef: PRRecord] {
        guard let dataObj = GitHubTaskBackend.decodeGraphQLData(blob) else { return [:] }
        return parseStalePRData(dataObj, refs: refs)
    }

    static func parseRecentPRsResponse(
        _ output: String,
        parsed: [(idx: Int, cand: BranchCandidate, owner: String, repo: String)]
    ) -> [BranchPRMatch] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else { return [] }
        var matches: [BranchPRMatch] = []
        for p in parsed {
            let repoObj = dataObj["pr\(p.idx)"] as? [String: Any]
            for node in LenientJSON.nodes(repoObj, "pullRequests") {
                guard let number = node["number"] as? Int,
                      let url = node["url"] as? String,
                      let state = node["state"] as? String else { continue }
                let updatedAt = IssueDate.parse(node["updatedAt"] as? String)
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
