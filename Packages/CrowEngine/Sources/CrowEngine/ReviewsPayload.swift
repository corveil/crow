import Foundation
import CrowCore
import CrowIPC

/// The `list-reviews` RPC payload, in one place.
///
/// Both routers — `CrowDaemon.RPCHandlers` (the Unix socket, i.e. `crow
/// list-reviews`) and `EngineRouter` (the web `/rpc`) — answer this verb, and
/// until CROW-945 each carried its own byte-identical copy of the mapping. The
/// CLI and the browser therefore agreed only by accident of copy-paste, which
/// is precisely the drift you don't want under a field that decides which
/// button a card renders.
public enum ReviewsPayload {

    /// Build the payload from live state.
    ///
    /// `kickoff_action` is computed **here, at serialization time**, not stamped
    /// onto `ReviewRequest` when the board is assembled: `appState.reviewRequests`
    /// refreshes at most once a poll while the board re-renders far more often,
    /// so an assembly-time verdict would be stale the moment a session was
    /// created or completed. Reading live `sessions`/`links` on each call keeps
    /// the label consistent with what the button will actually do.
    ///
    /// It is still only an **estimate**: it uses `request.headRefOid` (a board
    /// snapshot) whereas `SessionService.createReviewSession` decides against a
    /// head it fetches itself. The client must therefore treat this as a label
    /// and never suppress the RPC on it — the server is the decider.
    @MainActor
    public static func build(appState: AppState) -> [String: JSONValue] {
        let fmt = ISO8601DateFormatter()
        let reviews: [JSONValue] = appState.filteredReviewRequests.map { r in
            let existing = appState.existingReviewSession(forPRURL: r.url)
            let linked = r.reviewSessionID.flatMap { id in
                appState.sessions.first(where: { $0.id == id })
            } ?? existing
            let action = IssueTracker.reviewKickoffAction(
                reviewSessionID: r.reviewSessionID ?? existing?.id,
                headRefOid: r.headRefOid,
                linkedSession: linked,
                existingByPRSessionID: existing?.id
            )
            return .object([
                "id": .string(r.id),
                "pr_number": .int(r.prNumber),
                "title": .string(r.title),
                "url": .string(r.url),
                "repo": .string(r.repo),
                "author": .string(r.author),
                "head_branch": .string(r.headBranch),
                "base_branch": .string(r.baseBranch),
                "is_draft": .bool(r.isDraft),
                "requested_at": r.requestedAt.map { .string(fmt.string(from: $0)) } ?? .null,
                "labels": .array(r.labels.map {
                    .object(["name": .string($0.name), "color": $0.color.map { .string($0) } ?? .null])
                }),
                "provider": .string(r.provider.rawValue),
                "review_session_id": r.reviewSessionID.map { .string($0.uuidString) } ?? .null,
                "head_ref_oid": r.headRefOid.map { .string($0) } ?? .null,
                "kickoff_action": .string(actionName(action)),
            ])
        }
        return [
            "reviews": .array(reviews),
            "loading": .bool(appState.isLoadingReviews),
            "unseen": .int(appState.unseenReviewCount),
        ]
    }

    /// Wire names for `IssueTracker.ReviewKickoffAction`. Kept as a total switch
    /// (no `default`) so adding a case to the enum fails the build here rather
    /// than silently serializing as something the board doesn't handle.
    static func actionName(_ action: IssueTracker.ReviewKickoffAction) -> String {
        switch action {
        case .create: return "create"
        case .reReview: return "re_review"
        case .skip: return "skip"
        }
    }
}
