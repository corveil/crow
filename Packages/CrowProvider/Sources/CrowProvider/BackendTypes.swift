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
/// labels/checks because the stale-PR query doesn't fetch them. Callers merge
/// records by URL using the `merge` helper to fill in gaps as more data
/// arrives.
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
    /// Node ID of the most recent CHANGES_REQUESTED review on this PR, when
    /// available. Drives the round-2 dedup logic in `IssueTracker` so a second
    /// formal "Request changes" submission re-arms auto-respond. `nil` when no
    /// CHANGES_REQUESTED review is among the latest projected reviews, or on
    /// providers (e.g. GitLab) that don't surface stable review IDs in the
    /// monitored-MR query.
    public let latestReviewID: String?
    /// Used by reconcile tie-breaking when multiple non-OPEN PRs exist on the same branch.
    public let updatedAt: Date?

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
        latestReviewID: String? = nil,
        updatedAt: Date? = nil
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
        self.latestReviewID = latestReviewID
        self.updatedAt = updatedAt
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

/// PR metadata returned from `CodeBackend.fetchPRMetadata` — the subset
/// SessionService needs to prep a review clone.
public struct PRMetadata: Sendable {
    public let title: String
    public let number: Int
    public let headRefName: String
    public let headRefOid: String
    public let baseRefName: String

    public init(title: String, number: Int, headRefName: String, headRefOid: String, baseRefName: String) {
        self.title = title
        self.number = number
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.baseRefName = baseRefName
    }
}

/// Open + recently-closed issues assigned to the authenticated user.
///
/// Closed issues drive removal detection — IssueTracker diffs the new closed set
/// against the prior open set to flush issues that left the user's queue.
public struct AssignedListing: Sendable {
    public let open: [AssignedIssue]
    public let closed: [AssignedIssue]
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
        rateLimit: GitHubRateLimit? = nil,
        missingScope: String? = nil,
        samlRestricted: Bool = false
    ) {
        self.open = open
        self.closed = closed
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
