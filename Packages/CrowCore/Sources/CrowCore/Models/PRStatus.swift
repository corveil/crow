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
    /// Max `committedDate` across the PR's commits that are NOT rebases or
    /// merges (parent count < 2 AND message does not start with a merge
    /// prefix). `nil` when no commit timestamp data is available. Used by
    /// the stateless rule to know whether the author has substantively
    /// responded since the latest CHANGES_REQUESTED review.
    public var lastSubstantiveCommitAt: Date?

    public init(
        checksPass: CheckStatus = .unknown,
        reviewStatus: ReviewStatus = .unknown,
        mergeable: MergeStatus = .unknown,
        failedCheckNames: [String] = [],
        headSha: String? = nil,
        isOpen: Bool = true,
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil
    ) {
        self.checksPass = checksPass
        self.reviewStatus = reviewStatus
        self.mergeable = mergeable
        self.failedCheckNames = failedCheckNames
        self.headSha = headSha
        self.isOpen = isOpen
        self.lastChangesRequestedAt = lastChangesRequestedAt
        self.lastSubstantiveCommitAt = lastSubstantiveCommitAt
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
    }

    private enum CodingKeys: String, CodingKey {
        case checksPass, reviewStatus, mergeable, failedCheckNames, headSha, isOpen
        case lastChangesRequestedAt, lastSubstantiveCommitAt
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

    /// The stateless "needs refine" rule (CROW-508). Returns `true` when the
    /// PR is sitting in CHANGES_REQUESTED, is still open, and the agent has
    /// not made a substantive commit since the latest CHANGES_REQUESTED
    /// review. `terminalIdle` gates the outer IssueTracker dispatch — keeping
    /// it as a parameter here makes the rule fully derivable from the PR plus
    /// terminal state, with no per-session bookkeeping.
    ///
    /// The rule is intentionally tolerant of nil timestamps:
    /// - `lastChangesRequestedAt == nil`: GitHub said `reviewDecision ==
    ///   CHANGES_REQUESTED` but didn't surface a timestamped CR review (rare;
    ///   `latestReviews` paginates and can omit one). We refuse to fire — a
    ///   missing timestamp can't anchor "since when," and a false fire would
    ///   re-prompt the agent for no reviewer action.
    /// - `lastSubstantiveCommitAt == nil`: the PR has no qualifying commits
    ///   yet (or commit data wasn't fetched). Treat as "no response since
    ///   review" → still needs refine.
    ///
    /// Anti-loop is automatic: as soon as the agent makes a non-merge,
    /// non-rebase commit, `lastSubstantiveCommitAt` advances past
    /// `lastChangesRequestedAt` and this returns false on the next poll.
    /// A `Merge branch 'main'` commit does NOT advance the timestamp (it's
    /// filtered out upstream when computing `lastSubstantiveCommitAt`), so
    /// the GitHub "Update branch" button can't trick the rule into a false
    /// negative.
    public static func needsRefine(status: PRStatus, terminalIdle: Bool) -> Bool {
        guard terminalIdle else { return false }
        guard status.reviewStatus == .changesRequested, status.isOpen else { return false }
        guard let lastReview = status.lastChangesRequestedAt else { return false }
        if let lastCommit = status.lastSubstantiveCommitAt {
            return lastCommit < lastReview
        }
        return true
    }
}
