import Foundation
import CrowCore

/// Repository for PR→session attribution queries (#693, ADR 0008
/// follow-up 5). Read side of the attribution store; writes happen in
/// `IssueTracker`, which owns the trailer parse.
public struct PRAttributionRepository: Sendable {
    private let store: JSONStore

    public init(store: JSONStore) {
        self.store = store
    }

    public func attribution(prURL: String) -> PRSessionAttribution? {
        store.data.prAttributions?[prURL]
    }

    /// Every PR attributed to `sessionID`, in no guaranteed order.
    public func attributions(for sessionID: UUID) -> [PRSessionAttribution] {
        (store.data.prAttributions ?? [:]).values.filter { $0.sessionIDs.contains(sessionID) }
    }

    /// Count of PRs attributed to `sessionID` whose merge was observed
    /// inside `window`. A PR carrying multiple session trailers counts once
    /// for each of its sessions.
    public func mergedPRCount(for sessionID: UUID, in window: DateInterval) -> Int {
        attributions(for: sessionID).count { attribution in
            guard attribution.state == "MERGED", let mergedAt = attribution.mergedAt else { return false }
            return window.contains(mergedAt)
        }
    }

    /// Rework and merge-rate read values for `sessionID` over `window`
    /// (#694, ADR 0008 follow-up 6). Aggregates across every PR attributed
    /// to the session; a PR carrying multiple session trailers counts once
    /// for each of its sessions (matches `mergedPRCount`). A session with
    /// no attributed PRs gets the neutral value: zero counts, nil rate.
    public func reworkMetrics(for sessionID: UUID, in window: DateInterval) -> SessionReworkMetrics {
        let attributed = attributions(for: sessionID)
        var merged = 0
        var closed = 0
        var reverts = 0
        var fixes = 0
        for attribution in attributed {
            if attribution.state == "MERGED", let mergedAt = attribution.mergedAt,
               window.contains(mergedAt) {
                merged += 1
            }
            // Closed-without-merge requires the *current* state to be CLOSED:
            // a reopened-then-merged PR keeps its historical closedAt stamp
            // but counts as merged, not closed.
            if attribution.state == "CLOSED", let closedAt = attribution.closedAt,
               window.contains(closedAt) {
                closed += 1
            }
            reverts += (attribution.reverts ?? []).count { window.contains($0.detectedAt) }
            fixes += (attribution.postMergeFixes ?? []).count { window.contains($0.detectedAt) }
        }
        let resolved = merged + closed
        return SessionReworkMetrics(
            mergedCount: merged,
            closedWithoutMergeCount: closed,
            mergeRate: resolved > 0 ? Double(merged) / Double(resolved) : nil,
            revertCount: reverts,
            postMergeFixCount: fixes
        )
    }
}

/// Per-session rework/merge-rate read values over a window (#694, ADR 0008
/// follow-up 6). Category-A efficiency signal inputs for the scorecard and
/// the v2 combined score (follow-up 11) — this type only carries the
/// numbers; grading/weighting lives with the (future) consumer. The churn
/// hint (`SessionAnalytics.linesAdded/linesRemoved`) intentionally stays
/// separate and informational-only.
public struct SessionReworkMetrics: Equatable, Sendable {
    /// Attributed PRs whose merge was observed inside the window.
    public let mergedCount: Int
    /// Attributed PRs currently CLOSED whose close was observed inside the
    /// window (closed without merging).
    public let closedWithoutMergeCount: Int
    /// merged / (merged + closedWithoutMerge). `nil` — not 0, not 1 — when
    /// the session resolved no attributed PRs in the window: a session with
    /// nothing to rate is neutral, never graded.
    public let mergeRate: Double?
    /// Reverts of the session's attributed commits detected inside the window.
    public let revertCount: Int
    /// Post-merge fixes to the session's merged PRs detected inside the window.
    public let postMergeFixCount: Int

    public init(
        mergedCount: Int,
        closedWithoutMergeCount: Int,
        mergeRate: Double?,
        revertCount: Int,
        postMergeFixCount: Int
    ) {
        self.mergedCount = mergedCount
        self.closedWithoutMergeCount = closedWithoutMergeCount
        self.mergeRate = mergeRate
        self.revertCount = revertCount
        self.postMergeFixCount = postMergeFixCount
    }
}
