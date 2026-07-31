import Foundation
import CrowCore

/// Identifies a single PR by its repo coordinates and number.
///
/// Used as the key for batched PR-state lookups (see `CodeBackend.prStates`).
/// `owner` and `repo` together form the GitHub `org/repo` slug; on GitLab they
/// form the path before the `-/merge_requests/{iid}` segment.
public struct PRRef: Sendable, Hashable {
    public let owner: String
    public let repo: String
    public let number: Int

    public init(owner: String, repo: String, number: Int) {
        self.owner = owner
        self.repo = repo
        self.number = number
    }

    public var slug: String { "\(owner)/\(repo)" }
}

/// Rich PR/MR record. Mirrors the union of fields needed across:
///
/// - the viewer's own open PRs (`CodeBackend.listMonitoredPRs`)
/// - stale-PR follow-up (`CodeBackend.prStates`)
/// - reconcile branch matches (`CodeBackend.findRecentPRsForBranches`)
///
/// Not every field is populated by every call — for example, `prStates` skips
/// reviews and commits, so the CROW-508 needs-refine rule only ever fires off
/// the open-viewer query. (GitHub's `prStates` does fetch `labels`, since a
/// session-linked PR reached only via the stale path must still carry its
/// `crow:merge` label — #838; it also fetches `statusCheckRollup` — #894, see
/// below; GitLab's stale-MR path still omits both, which is fine while
/// auto-merge is GitHub-only.) Callers merge records by URL using the `merge`
/// helper to fill in gaps as more data arrives.
///
/// `prStates` fetches checks despite once being documented as "moot for closed
/// PRs" (#894): the stale set is not exclusively closed PRs. A PR past
/// `viewer.pullRequests(first: 50)`, or one in a SAML-restricted org — which is
/// a permanent hole in that connection, not a transient one — reaches this
/// record only via `prStates`, so without the rollup it could never show CI
/// state at all. Don't drop the field as dead weight.
public struct PRRecord: Sendable {
    public let number: Int
    public let url: String
    public let state: String              // OPEN / MERGED / CLOSED (GitHub); normalized same for GitLab
    public let mergeable: String          // MERGEABLE / CONFLICTING / UNKNOWN
    public let mergeStateStatus: String   // BEHIND / BLOCKED / CLEAN / DIRTY / DRAFT / HAS_HOOKS / UNKNOWN / UNSTABLE
    public let reviewDecision: String     // APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / ""
    public let isDraft: Bool
    public let headRefName: String
    public let headRefOid: String         // commit SHA, "" if unavailable
    public let baseRefName: String
    public let repoNameWithOwner: String
    public let labels: [LabelInfo]
    public let linkedIssueReferences: [LinkedIssueRef]
    public let checksState: String        // SUCCESS / FAILURE / PENDING / EXPECTED / ERROR / ""
    public let failedCheckNames: [String]
    public let latestReviewStates: [String]
    /// Max `submittedAt` across CHANGES_REQUESTED reviews currently visible
    /// on the PR. Drives the stateless "needs refine" rule in `IssueTracker`
    /// (CROW-508): compared against `lastSubstantiveCommitAt` to decide
    /// whether the agent owes a response. `nil` when no CHANGES_REQUESTED
    /// review is visible or the provider doesn't surface timestamps.
    public let lastChangesRequestedAt: Date?
    /// Max `authoredDate` across the PR's commits that are NOT rebases or
    /// merges (parent count < 2 AND message does not start with a merge
    /// prefix). `nil` when commit data wasn't fetched (e.g. stale-PR
    /// follow-up query, GitLab today, or empty commit list).
    ///
    /// `authoredDate`, not `committedDate` (CROW-921): a rebase rewrites the
    /// *committer* date of every replayed commit to ~now while preserving the
    /// author date, so a committer-date rule reads a rebase as "the agent
    /// pushed a fix". See `GitHubCodeBackend.parsePRNode` for the full note.
    public let lastSubstantiveCommitAt: Date?
    /// Logins of the reviewers whose *latest* review on this PR is
    /// CHANGES_REQUESTED — i.e. exactly who is blocking the PR right now, and
    /// therefore who to re-request when the findings have been addressed
    /// (CROW-921). Empty when no CHANGES_REQUESTED review is visible, when the
    /// query didn't select reviewer identity (the stale-PR follow-up), or on
    /// providers that don't surface it (GitLab today).
    ///
    /// Sourced from GraphQL `latestReviews`, which drops a review as soon as
    /// its author is re-requested — so this is naturally empty in exactly the
    /// state where re-requesting would be wrong.
    public let changesRequestedReviewerLogins: [String]
    /// Logins of the reviewers with a *pending* review request (GraphQL
    /// `reviewRequests`). Users only — a Team request carries no login and is
    /// visible instead through `hasPendingReviewRequest`.
    ///
    /// Requests are per-reviewer: the host clears only the *submitting*
    /// reviewer's request, so this list and `changesRequestedReviewerLogins`
    /// routinely hold different people (A reviewed and blocked; B was asked at
    /// the same time and hasn't looked). Deciding anything from "is something
    /// pending" alone therefore silences the loop for a PR whose findings
    /// nobody has addressed. Consult
    /// `PRStatus.changesRequestedReviewerIsPending`, never this field or
    /// `hasPendingReviewRequest` directly.
    public let pendingReviewerLogins: [String]
    /// Whether the PR has *any* pending review request, Users and Teams alike
    /// (`reviewRequests.totalCount > 0`). Strictly weaker than
    /// `pendingReviewerLogins`: use it only for the "is anyone at all waiting"
    /// question, which is the one thing a Team request can answer.
    ///
    /// `false` also means "not fetched" — the field is absent from the
    /// stale-PR follow-up query and from GitLab. That direction is deliberate:
    /// the CROW-921 watcher additionally requires post-review commits and a
    /// non-empty `changesRequestedReviewerLogins`, neither of which those paths
    /// populate either, so an unknown here can't provoke a spurious re-request.
    public let hasPendingReviewRequest: Bool
    /// Used by reconcile tie-breaking when multiple non-OPEN PRs exist on the same branch.
    public let updatedAt: Date?
    /// SHA of the merge/squash commit on the base branch. Populated only by
    /// queries that fetch `mergeCommit { oid }` (the stale-PR state query) and
    /// only once the PR is MERGED; `nil` otherwise. Revert-detection anchor
    /// (#694): a revert of a squash-merged PR names this SHA, not a branch SHA.
    public let mergeCommitOid: String?
    /// Whether the PR's repository has GitHub's "Allow auto-merge" setting on
    /// (GraphQL `Repository.autoMergeAllowed`). `nil` means *unknown*, not
    /// *false*: GitLab never sets it, and a SAML-restricted or otherwise
    /// partial fetch can omit it. Callers must treat `nil` as "proceed as
    /// before" — only an explicit `false` is a licence to change behaviour
    /// (#888), because guessing wrong here either freezes a healthy PR or
    /// merges one Crow shouldn't touch.
    public let repoAutoMergeAllowed: Bool?

    public init(
        number: Int,
        url: String,
        state: String,
        mergeable: String = "UNKNOWN",
        mergeStateStatus: String = "UNKNOWN",
        reviewDecision: String = "",
        isDraft: Bool = false,
        headRefName: String = "",
        headRefOid: String = "",
        baseRefName: String = "",
        repoNameWithOwner: String = "",
        labels: [LabelInfo] = [],
        linkedIssueReferences: [LinkedIssueRef] = [],
        checksState: String = "",
        failedCheckNames: [String] = [],
        latestReviewStates: [String] = [],
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil,
        changesRequestedReviewerLogins: [String] = [],
        pendingReviewerLogins: [String] = [],
        hasPendingReviewRequest: Bool = false,
        updatedAt: Date? = nil,
        mergeCommitOid: String? = nil,
        repoAutoMergeAllowed: Bool? = nil
    ) {
        self.number = number
        self.url = url
        self.state = state
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.baseRefName = baseRefName
        self.repoNameWithOwner = repoNameWithOwner
        self.labels = labels
        self.linkedIssueReferences = linkedIssueReferences
        self.checksState = checksState
        self.failedCheckNames = failedCheckNames
        self.latestReviewStates = latestReviewStates
        self.lastChangesRequestedAt = lastChangesRequestedAt
        self.lastSubstantiveCommitAt = lastSubstantiveCommitAt
        self.changesRequestedReviewerLogins = changesRequestedReviewerLogins
        self.pendingReviewerLogins = pendingReviewerLogins
        self.hasPendingReviewRequest = hasPendingReviewRequest
        self.updatedAt = updatedAt
        self.mergeCommitOid = mergeCommitOid
        self.repoAutoMergeAllowed = repoAutoMergeAllowed
    }
}

/// Issue-body helpers shared across provider backends (#751). The board only
/// needs an excerpt plus an "expand" affordance, so the body is capped here to
/// bound the RPC payload rather than shipping arbitrarily long issue bodies.
public enum IssueBody {
    /// Max stored body length. Comfortably covers a card excerpt plus an
    /// inline expand without unbounded payload growth.
    public static let maxLength = 2000

    /// Trim whitespace and cap to `maxLength`, appending an ellipsis when
    /// truncated. Returns nil for an empty/whitespace-only body so the card
    /// renders no description block.
    public static func cap(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }
}

/// Tolerant ISO-8601 parsing shared across backends (#751). Providers are
/// inconsistent about fractional seconds — GitHub GraphQL emits the plain form
/// (`2026-06-15T01:28:17Z`) while GitLab/others may include `.SSS`. A formatter
/// pinned to one shape silently returns nil for the other (the CROW-508 trap;
/// see `GitHubCodeBackend.parseGitHubDateTime`), which quietly disables any
/// feature that depends on the parsed date. Try plain first, then fractional.
public enum IssueDate {
    public static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: raw) { return d }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw)
    }
}

/// An issue reference linked from a PR/MR via "closes #N" or equivalent.
public struct LinkedIssueRef: Sendable {
    public let number: Int
    public let repo: String

    public init(number: Int, repo: String) {
        self.number = number
        self.repo = repo
    }
}

/// A single commit on a PR/MR, used for Crow-author detection.
public struct CommitInfo: Sendable {
    public let sha: String
    public let message: String

    public init(sha: String, message: String) {
        self.sha = sha
        self.message = message
    }
}

/// Input to `CodeBackend.findRecentPRsForBranches` — one (repo, branch) tuple.
public struct BranchCandidate: Sendable, Hashable {
    public let repoSlug: String
    public let branch: String

    public init(repoSlug: String, branch: String) {
        self.repoSlug = repoSlug
        self.branch = branch
    }
}

/// One PR match returned from `findRecentPRsForBranches`, tagged with which
/// candidate it came from so callers can route the result back to the right
/// session.
public struct BranchPRMatch: Sendable {
    public let candidate: BranchCandidate
    public let number: Int
    public let url: String
    public let state: String       // "OPEN" / "MERGED" / "CLOSED"
    public let updatedAt: Date?

    public init(candidate: BranchCandidate, number: Int, url: String, state: String, updatedAt: Date?) {
        self.candidate = candidate
        self.number = number
        self.url = url
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// Input to `CodeBackend.findPRsMatchingKeys` — one (repo, key) tuple, where
/// `key` is a ticket key (e.g. a Jira key `MAXX-6859`) expected to appear in a
/// PR's title/body/branch. Lets reconcile recover PR links for task-only
/// trackers (Jira) whose PR branch doesn't match the session's worktree branch.
public struct KeyCandidate: Sendable, Hashable {
    public let repoSlug: String
    public let key: String

    public init(repoSlug: String, key: String) {
        self.repoSlug = repoSlug
        self.key = key
    }
}

/// One PR match returned from `findPRsMatchingKeys`, tagged with the candidate
/// it came from so callers can route the result back to the right session(s).
public struct KeyPRMatch: Sendable {
    public let candidate: KeyCandidate
    public let number: Int
    public let url: String
    public let state: String       // "OPEN" / "MERGED" / "CLOSED"
    public let updatedAt: Date?

    public init(candidate: KeyCandidate, number: Int, url: String, state: String, updatedAt: Date?) {
        self.candidate = candidate
        self.number = number
        self.url = url
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// PR metadata returned from `CodeBackend.fetchPRMetadata` — the subset
/// SessionService needs to prep a review clone.
public struct PRMetadata: Sendable {
    public let title: String
    public let number: Int
    public let headRefName: String
    public let headRefOid: String
    public let baseRefName: String
    /// PR author login (e.g. "octocat"). Empty when the provider didn't surface
    /// it. Used to show "PR by @author" on a review session (CROW-593).
    public let author: String

    public init(title: String, number: Int, headRefName: String, headRefOid: String, baseRefName: String, author: String = "") {
        self.title = title
        self.number = number
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.baseRefName = baseRefName
        self.author = author
    }
}

/// Open + recently-closed issues assigned to the authenticated user.
///
/// Closed issues drive removal detection — IssueTracker diffs the new closed set
/// against the prior open set to flush issues that left the user's queue.
public struct AssignedListing: Sendable {
    public let open: [AssignedIssue]
    public let closed: [AssignedIssue]
    /// Total recently-closed matches, independent of the page cap on `closed`
    /// (GitHub's `search` fetches at most 50 nodes but reports the full
    /// `issueCount`; Jira reports the REST approximate-count / `acli --count`
    /// total, #572). Falls back to `closed.count` when the backend doesn't
    /// report a total, so it's always safe to badge from.
    public let closedTotalCount: Int
    /// GitHub-only; nil for GitLab.
    public let rateLimit: GitHubRateLimit?
    /// When non-nil, the backend completed the call but had to degrade the
    /// response because the OAuth token was missing this scope (e.g.
    /// `read:project` on GitHub). Callers should surface a UI warning so the
    /// user knows to refresh their token. The successful path returns the
    /// best-effort data alongside the scope marker; no error is thrown.
    public let missingScope: String?
    /// True when the response was degraded because an org's SAML enforcement
    /// blocked the OAuth token. The accessible-org issues GitHub still
    /// returned are in `open`/`closed`; callers should surface a one-time UI
    /// warning. Like `missingScope`, no error is thrown for this case.
    public let samlRestricted: Bool

    public init(
        open: [AssignedIssue],
        closed: [AssignedIssue],
        closedTotalCount: Int? = nil,
        rateLimit: GitHubRateLimit? = nil,
        missingScope: String? = nil,
        samlRestricted: Bool = false
    ) {
        self.open = open
        self.closed = closed
        self.closedTotalCount = closedTotalCount ?? closed.count
        self.rateLimit = rateLimit
        self.missingScope = missingScope
        self.samlRestricted = samlRestricted
    }
}

/// Viewer's own monitored PRs + review-requested PRs. Returned together because
/// the GitHub GraphQL surface can fetch both in one batched call.
public struct MonitoredPRListing: Sendable {
    public let viewerPRs: [PRRecord]
    public let reviewRequests: [ReviewRequest]
    public let viewerLogin: String
    public let rateLimit: GitHubRateLimit?
    /// True when the response was degraded because an org's SAML enforcement
    /// blocked the OAuth token. The accessible-org PRs/reviews GitHub still
    /// returned are present; callers should surface a one-time UI warning.
    public let samlRestricted: Bool

    public init(viewerPRs: [PRRecord], reviewRequests: [ReviewRequest], viewerLogin: String, rateLimit: GitHubRateLimit? = nil, samlRestricted: Bool = false) {
        self.viewerPRs = viewerPRs
        self.reviewRequests = reviewRequests
        self.viewerLogin = viewerLogin
        self.rateLimit = rateLimit
        self.samlRestricted = samlRestricted
    }
}
