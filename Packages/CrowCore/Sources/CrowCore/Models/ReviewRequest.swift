import Foundation

/// The viewer's most recent submitted review state on a PR.
///
/// PENDING is deliberately absent — an unsubmitted draft carries no
/// `submittedAt` at all. The raw values are GitHub's own so the provider can
/// decode them without a mapping table (CROW-982).
///
/// **`commented` is not a round-closing verdict.** `crow-review-pr` mandates
/// `--approve`/`--request-changes` and forbids `--comment`, so a comment is
/// notes without a decision and a review round stays open on it — see
/// `GitHubCodeBackend.roundClosingReviewStates`, which is the set that drives
/// `decideReviewCompletions` and still excludes it. It is modelled here because
/// the *board* has a second question to answer (CROW-990): a PR you left
/// comments on is a PR whose ball is with its author, and before this case
/// existed such a PR was in no group at all — invisible, which is the #953
/// complaint. Read this enum as "what did I last say", not "is the round over".
///
/// `nil` on a `ReviewRequest` means **not fetched** — never "no review". GitLab
/// exposes no per-reviewer verdict, and the SAML/partial paths can drop the
/// selection, so absence is genuinely ambiguous and must not be read as a
/// negative verdict.
public enum ReviewVerdict: String, Codable, Sendable, CaseIterable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case dismissed = "DISMISSED"
    case commented = "COMMENTED"

    /// Verdicts that mean "I have said my piece and the author owes the next
    /// move". Drives the board's **Waiting on author** group (CROW-990).
    ///
    /// `dismissed` is excluded on purpose: a dismissed review is one whose
    /// verdict was *thrown away*, so it leaves nothing owed in either
    /// direction — GitHub re-requests the reviewer when it wants another look,
    /// and that lands the PR back in the requested queue where it belongs.
    public var isWaitingOnAuthor: Bool {
        self == .changesRequested || self == .commented
    }
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
    /// Timestamp of the viewer's most recent submitted review. Which state it
    /// was lives in `viewerLastReviewState` — the two are parsed from the same
    /// review node and are set or nil together.
    public var viewerLastReviewedAt: Date?
    /// The state at `viewerLastReviewedAt`. Needed to tell "I approved this"
    /// from "I requested changes", which the timestamp alone collapses — the
    /// board's whole grouping turns on exactly this distinction (CROW-982,
    /// CROW-990). `nil` means not fetched; see `ReviewVerdict`.
    public var viewerLastReviewState: ReviewVerdict?
    /// The PR head the viewer's last review was submitted against — GitHub's
    /// `PullRequestReview.commit.oid`, parsed from the same review node as the
    /// timestamp and the verdict (CROW-997).
    ///
    /// Compared against `headRefOid` this answers "has the author pushed since I
    /// last looked?" for a PR with **no live session** — which is every row under
    /// **Waiting on author**, because `decideReviewCompletions` rule 1 retires the
    /// round the moment the verdict lands. `Session.lastReviewedHeadSha` records
    /// the same fact but needs a session to hang off, so it goes blind on exactly
    /// these rows; this field lives on the request instead and survives the round.
    public var viewerLastReviewedHeadSha: String?
    /// GitHub's `PullRequestState` — `"OPEN"`, `"MERGED"`, or `"CLOSED"`.
    ///
    /// `nil` means **not fetched**, and `isCompleted` reads that as open. Every
    /// row on this board used to come from a `state:open` search, so open was
    /// the only possibility and the field went unparsed; since CROW-990 the
    /// board also carries PRs that merged or closed in the last 24 h, and it
    /// needs to tell those from the ones still waiting on someone.
    public var state: String?
    /// When the PR left everyone's queue for good — `mergedAt ?? closedAt`.
    ///
    /// Separate from `requestedAt` (the PR's `updatedAt`, which any later
    /// comment bumps) because the **Recently completed** window has to measure
    /// from the merge, not from the last thing that touched the thread.
    public var completedAt: Date?

    /// Whether the PR is no longer open. A nil `state` reads as open — see
    /// `state`, where nil is "not fetched", and treating an unknown PR as
    /// merged would silently file live work under a heading that means done.
    public var isCompleted: Bool {
        state == "MERGED" || state == "CLOSED"
    }

    /// Whether the viewer's last review **provably** covered the PR's current
    /// head — i.e. the author has pushed nothing since it was submitted.
    ///
    /// Deliberately `false` when either SHA is missing, and the asymmetry is the
    /// whole point. This gates the board's suppression of Start Review under
    /// **Waiting on author** (CROW-997), so a `true` claims "there is nothing new
    /// to look at" and takes the row's only way forward off the card. A partial
    /// fetch must not make that claim: unknown means the row keeps its button,
    /// which is at worst a redundant round and at best the author-pushed-without-
    /// re-requesting PR the group would otherwise strand. Same "absence is not
    /// evidence" rule as `state` and `viewerLastReviewState` above.
    public var viewerReviewCoversCurrentHead: Bool {
        guard let reviewed = viewerLastReviewedHeadSha, let head = headRefOid else { return false }
        return reviewed == head
    }

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
        viewerLastReviewState: ReviewVerdict? = nil,
        viewerLastReviewedHeadSha: String? = nil,
        state: String? = nil,
        completedAt: Date? = nil
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
        self.viewerLastReviewedHeadSha = viewerLastReviewedHeadSha
        self.state = state
        self.completedAt = completedAt
    }
}
