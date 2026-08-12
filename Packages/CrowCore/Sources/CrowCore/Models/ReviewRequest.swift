import Foundation

/// The viewer's most recent *verdict* on a PR.
///
/// Only the three round-closing states are modelled. COMMENTED and PENDING are
/// deliberately absent: `crow-review-pr` mandates `--approve`/`--request-changes`
/// and forbids `--comment`, so a comment is notes without a decision, and
/// PENDING is an unsubmitted draft carrying no `submittedAt` at all. The raw
/// values are GitHub's own so the provider can decode them without a mapping
/// table (CROW-982).
///
/// `nil` on a `ReviewRequest` means **not fetched** — never "no review". GitLab
/// exposes no per-reviewer verdict, and the SAML/partial paths can drop the
/// selection, so absence is genuinely ambiguous and must not be read as a
/// negative verdict.
public enum ReviewVerdict: String, Codable, Sendable, CaseIterable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case dismissed = "DISMISSED"
}

/// A pull request where the current user has been requested as a reviewer.
public struct ReviewRequest: Identifiable, Codable, Sendable {
    public let id: String             // "github:org/repo#123"
    public var prNumber: Int
    public var title: String
    public var url: String             // full PR URL
    public var repo: String            // "org/repo"
    public var author: String          // PR author login
    public var headBranch: String
    public var baseBranch: String
    public var isDraft: Bool
    public var requestedAt: Date?
    public var labels: [LabelInfo]
    public var provider: Provider
    public var reviewSessionID: UUID?  // set if a review session already exists
    public var headRefOid: String?     // PR head commit SHA — used to detect new pushes
    /// Timestamp of the viewer's most recent round-closing review. Which of the
    /// three verdicts it was lives in `viewerLastReviewState` — the two are
    /// parsed from the same review node and are set or nil together.
    public var viewerLastReviewedAt: Date?
    /// The verdict at `viewerLastReviewedAt`. Needed to tell "I approved this"
    /// from "I requested changes", which the timestamp alone collapses — the
    /// board's Not-approved-yet / Approved-recently split turns on exactly this
    /// distinction (CROW-982). `nil` means not fetched; see `ReviewVerdict`.
    public var viewerLastReviewState: ReviewVerdict?

    public init(
        id: String,
        prNumber: Int,
        title: String,
        url: String,
        repo: String,
        author: String,
        headBranch: String,
        baseBranch: String,
        isDraft: Bool = false,
        requestedAt: Date? = nil,
        labels: [LabelInfo] = [],
        provider: Provider = .github,
        reviewSessionID: UUID? = nil,
        headRefOid: String? = nil,
        viewerLastReviewedAt: Date? = nil,
        viewerLastReviewState: ReviewVerdict? = nil
    ) {
        self.id = id
        self.prNumber = prNumber
        self.title = title
        self.url = url
        self.repo = repo
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.isDraft = isDraft
        self.requestedAt = requestedAt
        self.labels = labels
        self.provider = provider
        self.reviewSessionID = reviewSessionID
        self.headRefOid = headRefOid
        self.viewerLastReviewedAt = viewerLastReviewedAt
        self.viewerLastReviewState = viewerLastReviewState
    }
}
