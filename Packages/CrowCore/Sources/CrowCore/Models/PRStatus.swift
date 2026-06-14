import Foundation

/// Status of a pull request associated with a session.
public struct PRStatus: Codable, Sendable, Equatable {
    public var checksPass: CheckStatus
    public var reviewStatus: ReviewStatus
    public var mergeable: MergeStatus
    public var failedCheckNames: [String]
    /// Head commit SHA. Used to dedupe per-commit transition events
    /// (e.g. don't re-fire "checks failing" when the same commit is re-run).
    public var headSha: String?
    /// Node ID of the most recent CHANGES_REQUESTED review on this PR, when
    /// the provider surfaces stable review identifiers. Round-2 dedup uses
    /// this so a fresh "Request changes" submission re-arms auto-respond
    /// even when the bucket stays in `.changesRequested`. `nil` when no
    /// CHANGES_REQUESTED review is currently visible, or on providers that
    /// don't expose review IDs in the monitored-PR query (e.g. GitLab).
    public var latestReviewID: String?
    /// Whether the underlying PR is currently OPEN (as opposed to MERGED or
    /// closed-unmerged). Distinct from `mergeable == .merged`: a CLOSED PR
    /// has `mergeable == .unknown` but is still not actionable.
    ///
    /// Required by the stalled-`.changesRequested` re-fire pass (CROW-505):
    /// the standing-state predicate reads `previousPRStatus[sid]` directly
    /// rather than firing on transition edges, so without this flag a PR
    /// that merged or closed while in `CHANGES_REQUESTED` (its
    /// `reviewDecision` doesn't reset on close) would keep re-prompting the
    /// agent every quiet window to "address review feedback" on a dead PR.
    /// Defaults to `true` for backward decode — pre-CROW-505 stores have no
    /// `isOpen` field, and the very next poll rewrites the persisted status
    /// from the live viewer payload before re-fire is consulted, so the
    /// transient default never affects an actual re-fire decision.
    public var isOpen: Bool

    public init(
        checksPass: CheckStatus = .unknown,
        reviewStatus: ReviewStatus = .unknown,
        mergeable: MergeStatus = .unknown,
        failedCheckNames: [String] = [],
        headSha: String? = nil,
        latestReviewID: String? = nil,
        isOpen: Bool = true
    ) {
        self.checksPass = checksPass
        self.reviewStatus = reviewStatus
        self.mergeable = mergeable
        self.failedCheckNames = failedCheckNames
        self.headSha = headSha
        self.latestReviewID = latestReviewID
        self.isOpen = isOpen
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checksPass = try c.decodeIfPresent(CheckStatus.self, forKey: .checksPass) ?? .unknown
        reviewStatus = try c.decodeIfPresent(ReviewStatus.self, forKey: .reviewStatus) ?? .unknown
        mergeable = try c.decodeIfPresent(MergeStatus.self, forKey: .mergeable) ?? .unknown
        failedCheckNames = try c.decodeIfPresent([String].self, forKey: .failedCheckNames) ?? []
        headSha = try c.decodeIfPresent(String.self, forKey: .headSha)
        latestReviewID = try c.decodeIfPresent(String.self, forKey: .latestReviewID)
        isOpen = try c.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case checksPass, reviewStatus, mergeable, failedCheckNames, headSha, latestReviewID, isOpen
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
}
