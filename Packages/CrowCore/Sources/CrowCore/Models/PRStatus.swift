import Foundation

/// Status of a pull request associated with a session.
public struct PRStatus: Codable, Sendable, Equatable {
    public var checksPass: CheckStatus
    public var reviewStatus: ReviewStatus
    public var mergeable: MergeStatus
    public var failedCheckNames: [String]
    /// Head commit SHA. Used to dedupe per-commit `.checksFailing` events
    /// (don't re-fire when the same commit is re-run).
    public var headSha: String?
    /// Whether the underlying PR is currently OPEN (as opposed to MERGED or
    /// closed-unmerged). Distinct from `mergeable == .merged`: a CLOSED PR
    /// has `mergeable == .unknown` but is still not actionable. Gates
    /// `needsRefine` so a dead PR can never re-prompt.
    public var isOpen: Bool
    /// Max `submittedAt` across CHANGES_REQUESTED reviews currently visible
    /// on the PR. `nil` when no CHANGES_REQUESTED review is present (or the
    /// provider doesn't surface review timestamps, e.g. GitLab today).
    /// The stateless "needs refine" rule compares this against
    /// `lastSubstantiveCommitAt` to decide whether the agent owes a response.
    public var lastChangesRequestedAt: Date?
    /// Max `authoredDate` across the PR's commits that are NOT rebases or
    /// merges (parent count < 2 AND message does not start with a merge
    /// prefix). `nil` when no commit timestamp data is available. Used by
    /// the stateless rule to know whether the author has substantively
    /// responded since the latest CHANGES_REQUESTED review.
    ///
    /// Author date, not committer date (CROW-921) — a rebase rewrites the
    /// latter on every replayed commit, which used to read as "the agent
    /// pushed a fix". See `GitHubCodeBackend.parsePRNode` for the full note
    /// including the amend/cherry-pick gap this deliberately accepts.
    public var lastSubstantiveCommitAt: Date?
    /// Whether the PR currently has at least one *pending* review request.
    /// The host clears the request when a reviewer submits, so on a
    /// CHANGES_REQUESTED PR this is the difference between "the ball is in
    /// the author's court" (`false`) and "somebody has already been asked to
    /// look again" (`true`) — the third state the CROW-921 loop was missing.
    /// `false` when the provider doesn't surface it (GitLab today).
    public var hasPendingReviewRequest: Bool
    /// Whether the PR currently carries the `crow:merge` auto-merge label
    /// (`IssueTracker.autoMergeLabel`). Distinct from
    /// `Session.autoMergeEnabledAt`, which records that Crow has already
    /// *enabled* GitHub auto-merge: the label is the request, the timestamp is
    /// the action. The UI shows them as separate indicators (CROW-773).
    public var hasMergeLabel: Bool

    public init(
        checksPass: CheckStatus = .unknown,
        reviewStatus: ReviewStatus = .unknown,
        mergeable: MergeStatus = .unknown,
        failedCheckNames: [String] = [],
        headSha: String? = nil,
        isOpen: Bool = true,
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil,
        hasPendingReviewRequest: Bool = false,
        hasMergeLabel: Bool = false
    ) {
        self.checksPass = checksPass
        self.reviewStatus = reviewStatus
        self.mergeable = mergeable
        self.failedCheckNames = failedCheckNames
        self.headSha = headSha
        self.isOpen = isOpen
        self.lastChangesRequestedAt = lastChangesRequestedAt
        self.lastSubstantiveCommitAt = lastSubstantiveCommitAt
        self.hasPendingReviewRequest = hasPendingReviewRequest
        self.hasMergeLabel = hasMergeLabel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checksPass = try c.decodeIfPresent(CheckStatus.self, forKey: .checksPass) ?? .unknown
        reviewStatus = try c.decodeIfPresent(ReviewStatus.self, forKey: .reviewStatus) ?? .unknown
        mergeable = try c.decodeIfPresent(MergeStatus.self, forKey: .mergeable) ?? .unknown
        failedCheckNames = try c.decodeIfPresent([String].self, forKey: .failedCheckNames) ?? []
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha)
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
        lastChangesRequestedAt = try c.decodeIfPresent(Date.self, forKey: .lastChangesRequestedAt)
        lastSubstantiveCommitAt = try c.decodeIfPresent(Date.self, forKey: .lastSubstantiveCommitAt)
        hasPendingReviewRequest = try c.decodeIfPresent(Bool.self, forKey: .hasPendingReviewRequest) ?? false
        hasMergeLabel = try c.decodeIfPresent(Bool.self, forKey: .hasMergeLabel) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case checksPass, reviewStatus, mergeable, failedCheckNames, headSha, isOpen
        case lastChangesRequestedAt, lastSubstantiveCommitAt, hasPendingReviewRequest, hasMergeLabel
    }

    public enum CheckStatus: String, Codable, Sendable {
        /// All CI/CD checks have passed.
        case passing
        /// One or more CI/CD checks have failed.
        case failing
        /// Checks are still running.
        case pending
        /// Check status could not be determined (e.g. no checks configured).
        case unknown
    }

    public enum ReviewStatus: String, Codable, Sendable {
        /// PR has been approved by required reviewers.
        case approved
        /// A reviewer has requested changes.
        case changesRequested
        /// Review is required but not yet submitted.
        case reviewRequired
        /// Review status could not be determined.
        case unknown
    }

    public enum MergeStatus: String, Codable, Sendable {
        /// PR can be merged (no conflicts, requirements met).
        case mergeable
        /// PR has merge conflicts that must be resolved.
        case conflicting
        /// PR has already been merged.
        case merged
        /// Merge status could not be determined.
        case unknown
    }

    /// True if the PR has been merged.
    public var isMerged: Bool {
        mergeable == .merged
    }

    /// True if the PR is ready to merge (checks pass, approved, no conflicts).
    public var isReadyToMerge: Bool {
        checksPass == .passing && reviewStatus == .approved && mergeable == .mergeable
    }

    /// True if there are blockers preventing merge.
    public var hasBlockers: Bool {
        !isMerged && (checksPass == .failing || reviewStatus == .changesRequested || mergeable == .conflicting)
    }

    /// Where a CHANGES_REQUESTED PR sits in the review round-trip (CROW-921).
    ///
    /// The loop originally had two states and dead-ended between them: the
    /// only thing that re-requested review was a sentence inside the
    /// `addressChanges` prompt, and that prompt is reachable only while the
    /// agent still owes a fix. Once the fix landed, the prompt could never
    /// fire again and nothing re-requested review — so the PR was invisible to
    /// the reviewer's queue *and* to `review-requested:@me`, forever.
    ///
    /// Naming the third state is what closes the loop. Raw values are
    /// grep-stable: they land in `crowd-automation.log`.
    public enum ChangesRequestedState: String, Sendable, Equatable {
        /// Not a live CHANGES_REQUESTED PR, or no review timestamp to anchor
        /// "since when" against. Nothing to decide.
        case notApplicable
        /// Changes requested and the agent hasn't substantively responded yet
        /// → prompt the agent (the CROW-508 rule).
        case needsRefine
        /// The fix landed but nobody has been asked to look again → re-request
        /// review. This is the state CROW-921 added.
        case awaitingReRequest
        /// A review request is already pending → the ball is with the
        /// reviewer. Nothing for Crow to do.
        case awaitingReviewer
    }

    /// Classify a PR's position in the changes-requested round-trip.
    ///
    /// `needsRefine` and the auto-re-request watcher are both derived from
    /// this one function so they cannot drift into overlapping or
    /// contradictory conditions — every CHANGES_REQUESTED PR is in exactly one
    /// state, and the two actions are mutually exclusive by construction.
    ///
    /// Order matters. The pending-request check sits *above* the
    /// `lastChangesRequestedAt` guard on purpose: GitHub drops a review from
    /// `latestReviews` as soon as its author is re-requested, which nils the
    /// timestamp. Checked in the other order, a PR genuinely awaiting its
    /// reviewer would report `.notApplicable` and the gated-evaluation log
    /// would say "no CR timestamp" instead of naming the real state.
    ///
    /// Nil tolerance is inherited from CROW-508:
    /// - `lastChangesRequestedAt == nil`: the host said CHANGES_REQUESTED but
    ///   surfaced no timestamped CR review. Refuse to classify — a missing
    ///   timestamp can't anchor "since when", and guessing either way is worse
    ///   than doing nothing.
    /// - `lastSubstantiveCommitAt == nil`: no qualifying commits yet → the
    ///   agent still owes a response.
    public static func changesRequestedState(status: PRStatus) -> ChangesRequestedState {
        guard status.reviewStatus == .changesRequested, status.isOpen else { return .notApplicable }
        if status.hasPendingReviewRequest { return .awaitingReviewer }
        guard let lastReview = status.lastChangesRequestedAt else { return .notApplicable }
        guard let lastCommit = status.lastSubstantiveCommitAt else { return .needsRefine }
        return lastCommit < lastReview ? .needsRefine : .awaitingReRequest
    }

    /// The stateless "needs refine" rule (CROW-508). Returns `true` when the
    /// PR is sitting in CHANGES_REQUESTED, is still open, and the agent has
    /// not made a substantive commit since the latest CHANGES_REQUESTED
    /// review. `terminalIdle` gates the outer IssueTracker dispatch — keeping
    /// it as a parameter here makes the rule fully derivable from the PR plus
    /// terminal state, with no per-session bookkeeping.
    ///
    /// Anti-loop is automatic: as soon as the agent authors a non-merge,
    /// non-rebase commit, `lastSubstantiveCommitAt` advances past
    /// `lastChangesRequestedAt` and this returns false on the next poll.
    /// A `Merge branch 'main'` commit does NOT advance the timestamp (it's
    /// filtered out upstream), so the GitHub "Update branch" button can't
    /// trick the rule into a false negative — and since CROW-921 a rebase
    /// can't either, because the timestamp is the *author* date.
    public static func needsRefine(status: PRStatus, terminalIdle: Bool) -> Bool {
        guard terminalIdle else { return false }
        return changesRequestedState(status: status) == .needsRefine
    }
}
