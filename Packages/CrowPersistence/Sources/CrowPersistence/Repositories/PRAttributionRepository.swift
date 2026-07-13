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
}
