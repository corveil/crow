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
///
/// Since CROW-982 it also carries the board's three-way grouping — `group` per
/// review plus `group_counts`/`group_order` — so `crow list-reviews` and the web
/// board are grouped identically by construction rather than by two clients
/// agreeing on a rule.
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
    public static func build(appState: AppState, now: Date = Date()) -> [String: JSONValue] {
        let fmt = ISO8601DateFormatter()

        // Groups 1+2 come from the requested queue; group 3 from the separate
        // `reviewed-by:@me` search, trimmed to the 24 h window *here* rather
        // than at poll time so the tail expires on the clock instead of on the
        // next poll (CROW-982). `recentlyApprovedReviews` is already deduped
        // against the requested queue by `IssueTracker`.
        let requested = appState.filteredReviewRequests
        let approvedTail = appState.filteredRecentlyApprovedReviews.filter {
            ReviewGroup.isRecentApproval(state: $0.viewerLastReviewState, at: $0.viewerLastReviewedAt, now: now)
        }

        var counts: [ReviewGroup: Int] = [:]
        func serialize(_ r: ReviewRequest) -> JSONValue {
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
            // "A review is open/in progress on it" — an *active* session, since
            // both `reviewSessionID` (cross-referenced from `reviewSessions`)
            // and `existingReviewSession` exclude completed/archived rounds.
            // Consulting `existing` too covers the ~10s clone window before the
            // cross-reference lands, so a just-started round doesn't flicker
            // through "Not approved yet".
            let hasActiveSession = r.reviewSessionID != nil || existing != nil
            let group = ReviewGroup.classify(
                viewerLastReviewState: r.viewerLastReviewState,
                viewerLastReviewedAt: r.viewerLastReviewedAt,
                hasActiveReviewSession: hasActiveSession,
                now: now
            )
            counts[group, default: 0] += 1
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
                "viewer_last_reviewed_at": r.viewerLastReviewedAt.map { .string(fmt.string(from: $0)) } ?? .null,
                "viewer_last_review_state": r.viewerLastReviewState.map { .string($0.rawValue) } ?? .null,
                "group": .string(group.rawValue),
            ])
        }

        // The approved tail is classified with `hasActiveReviewSession` still
        // honored, so precedence holds: a PR you approved a minute ago but that
        // has a live session stays under In review.
        let reviews: [JSONValue] = requested.map { serialize($0) } + approvedTail.map { serialize($0) }

        // Emitted for every group, including empty ones — the board renders a
        // zero count rather than dropping the section, so an empty board still
        // says *what* is empty. That silence was half the shock in #953.
        let groupCounts: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: ReviewGroup.displayOrder.map { ($0.rawValue, JSONValue.int(counts[$0] ?? 0)) }
        )
        return [
            "reviews": .array(reviews),
            "loading": .bool(appState.isLoadingReviews),
            "unseen": .int(appState.unseenReviewCount),
            "group_counts": .object(groupCounts),
            "group_order": .array(ReviewGroup.displayOrder.map { .string($0.rawValue) }),
            "hidden_by_filters": .int(appState.hiddenReviewCount),
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
