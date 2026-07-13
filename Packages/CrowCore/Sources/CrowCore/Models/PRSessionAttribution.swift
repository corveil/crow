import Foundation

/// A detected revert of one of this PR's commits (#694, ADR 0008
/// follow-up 6). A revert is a later commit — on the default branch or in
/// another attributed PR — whose message carries git's conventional
/// `This reverts commit <sha>` line naming one of this PR's stored SHAs
/// (`mergeCommitSHA` or `commitSHAs`). Counts as a rework signal for
/// every session attributed to the reverted PR.
///
/// Known limitation: a hand-written revert whose message drops the
/// conventional body line (keeping only a `Revert "…"` title) is not
/// detected — titles aren't stored, so there is nothing stable to match.
public struct PRRevertRecord: Codable, Equatable, Sendable {
    /// The SHA named by `This reverts commit …` — one of the reverted
    /// PR's stored SHAs. Dedupe key: the same logical revert observed
    /// through different paths (revert PR vs. default-branch scan) names
    /// the same target and is recorded once.
    public var revertedCommitSHA: String
    /// The commit carrying the revert message.
    public var revertCommitSHA: String
    /// URL of the attributed PR the revert was seen in, when it was
    /// detected via another PR's commit fetch; nil when detected on the
    /// default branch directly.
    public var sourcePRURL: String?
    /// When Crow detected the revert (Crow-observed, poll-bounded).
    public var detectedAt: Date

    public init(revertedCommitSHA: String, revertCommitSHA: String, sourcePRURL: String? = nil, detectedAt: Date) {
        self.revertedCommitSHA = revertedCommitSHA
        self.revertCommitSHA = revertCommitSHA
        self.sourcePRURL = sourcePRURL
        self.detectedAt = detectedAt
    }
}

/// A detected post-merge fix: another attributed PR that landed shortly
/// after this one merged and touched the same files (#694, ADR 0008
/// follow-up 6). A rework signal for this PR's sessions — the PR that
/// needed fixing, not the one that fixed it.
///
/// Heuristic (all conditions required; see
/// `IssueTracker.postMergeFixDetections`):
/// 1. the fix PR was first seen only after this PR merged;
/// 2. the fix PR itself merged, within `postMergeFixWindow` (48h) of
///    this PR's merge — only landed fixes count;
/// 3. the two PRs share at least one changed file path;
/// 4. the fix PR is not a revert of this PR (a revert counts exactly
///    once, as a revert);
/// 5. same-session follow-ups DO count — a fix to your own just-merged
///    PR is rework regardless of author.
/// PRs merged before file capture existed have `changedFiles == nil` and
/// never gain fix records (no retroactive detection).
public struct PostMergeFixRecord: Codable, Equatable, Sendable {
    /// URL of the attributed PR that fixed this one. Dedupe key.
    public var fixPRURL: String
    /// How many changed file paths the two PRs share.
    public var overlappingFileCount: Int
    /// When Crow detected the fix (Crow-observed, poll-bounded).
    public var detectedAt: Date

    public init(fixPRURL: String, overlappingFileCount: Int, detectedAt: Date) {
        self.fixPRURL = fixPRURL
        self.overlappingFileCount = overlappingFileCount
        self.detectedAt = detectedAt
    }
}

/// Durable PR → session attribution record, persisted whenever a PR's
/// commits are fetched and their `Crow-Session:` trailers parsed.
///
/// This is ADR 0008 follow-up 5: the trailer parse used to be a
/// discard-after-use auto-merge gate; this record retains the mapping so
/// the scorecard can count PRs merged per session per window (and, in
/// follow-up 6, merge rate). Records deliberately outlive session
/// deletion — window counts must survive the retention reaper — and
/// include unknown-session UUIDs: attribution is ground truth even when
/// the session isn't (or is no longer) known locally.
///
/// Extension point: add future fields — e.g. `authorLogin: String?` —
/// as OPTIONALS on this struct so previously persisted records keep
/// decoding.
public struct PRSessionAttribution: Codable, Equatable, Sendable {
    public var prURL: String
    public var repoNameWithOwner: String
    public var prNumber: Int
    /// Every UUID parsed from `Crow-Session:` trailers on the PR's commits,
    /// deduped, in first-seen order. Monotonic: once observed an ID is never
    /// removed, even if a later rebase drops the commit that carried it.
    public var sessionIDs: [UUID]
    /// Last observed PR state: "OPEN" / "MERGED" / "CLOSED".
    public var state: String
    /// When Crow first observed the PR in MERGED state; never overwritten.
    /// Crow-observed (no backend surfaces the real merge timestamp yet), so
    /// it can lag the actual merge by up to a poll interval or app downtime.
    /// A future API-sourced value can replace it without a schema change.
    public var mergedAt: Date?
    public var firstSeenAt: Date
    public var updatedAt: Date
    /// SHAs of the PR's branch commits, deduped, in first-seen order.
    /// Monotonic like `sessionIDs`, capped at
    /// `IssueTracker.maxStoredCommitSHAs`. Revert-detection match targets
    /// for merge strategies that land branch commits on the base branch
    /// (merge commit, rebase) and for providers with no merge-commit SHA.
    public var commitSHAs: [String]?
    /// SHA of the merge/squash commit on the base branch, stamped once at
    /// the first MERGED observation and never overwritten. The primary
    /// revert-detection target: Crow squash-merges, and GitHub's Revert
    /// button reverts this commit, not the branch commits.
    public var mergeCommitSHA: String?
    /// When Crow first observed the PR in CLOSED state; never overwritten
    /// (mirrors `mergedAt`, same Crow-observed lag caveat). Merge-rate
    /// counts a PR closed-without-merge only while its *current* state is
    /// CLOSED, so a reopened-then-merged PR counts as merged.
    public var closedAt: Date?
    /// File paths the PR changed, fetched once at the first MERGED
    /// observation, capped at `IssueTracker.maxStoredChangedFiles`.
    /// Post-merge-fix overlap input; nil when never fetched (pre-#694
    /// records, fetch failure, or provider without file listing).
    public var changedFiles: [String]?
    /// Detected reverts of this PR's commits, deduped by `revertedCommitSHA`.
    public var reverts: [PRRevertRecord]?
    /// Detected post-merge fixes to this PR, deduped by `fixPRURL`.
    public var postMergeFixes: [PostMergeFixRecord]?

    public init(
        prURL: String,
        repoNameWithOwner: String,
        prNumber: Int,
        sessionIDs: [UUID],
        state: String,
        mergedAt: Date? = nil,
        firstSeenAt: Date,
        updatedAt: Date,
        commitSHAs: [String]? = nil,
        mergeCommitSHA: String? = nil,
        closedAt: Date? = nil,
        changedFiles: [String]? = nil,
        reverts: [PRRevertRecord]? = nil,
        postMergeFixes: [PostMergeFixRecord]? = nil
    ) {
        self.prURL = prURL
        self.repoNameWithOwner = repoNameWithOwner
        self.prNumber = prNumber
        self.sessionIDs = sessionIDs
        self.state = state
        self.mergedAt = mergedAt
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
        self.commitSHAs = commitSHAs
        self.mergeCommitSHA = mergeCommitSHA
        self.closedAt = closedAt
        self.changedFiles = changedFiles
        self.reverts = reverts
        self.postMergeFixes = postMergeFixes
    }
}
