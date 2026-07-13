import Foundation

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

    public init(
        prURL: String,
        repoNameWithOwner: String,
        prNumber: Int,
        sessionIDs: [UUID],
        state: String,
        mergedAt: Date? = nil,
        firstSeenAt: Date,
        updatedAt: Date
    ) {
        self.prURL = prURL
        self.repoNameWithOwner = repoNameWithOwner
        self.prNumber = prNumber
        self.sessionIDs = sessionIDs
        self.state = state
        self.mergedAt = mergedAt
        self.firstSeenAt = firstSeenAt
        self.updatedAt = updatedAt
    }
}
