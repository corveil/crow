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
/// Since CROW-982 it also carries the board's grouping — `group` per review plus
/// `group_counts`/`group_order` — so `crow list-reviews` and the web board are
/// grouped identically by construction rather than by two clients agreeing on a
/// rule. CROW-990 took that split from three groups to four.
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
    ///
    /// Read it as *what this row offers*, which is the session decision plus the
    /// group-level suppressions in `kickoffAction(for:group:linked:existing:)` —
    /// not as a prediction of what `start-review` would do if called anyway. The
    /// two differ on purpose: `createReviewSession` guards only against
    /// double-covering a PR, so it will happily open a round on a merged PR or a
    /// quiet Waiting-on-author one. That is the escape hatch — `crow start-review
    /// --url` still works on anything — while the board declines to *suggest* it.
    @MainActor
    public static func build(appState: AppState, now: Date = Date()) -> [String: JSONValue] {
        let fmt = ISO8601DateFormatter()

        // The requested queue feeds the groups GitHub is asking about; the
        // `reviewed-by:@me` list feeds the two that describe work already done
        // (CROW-982, CROW-990). Both go through the same `classify`, which also
        // decides visibility — a reviewed PR outside the 24 h tail comes back
        // nil and is dropped. That trimming happens *here* rather than at poll
        // time so the window expires on the clock instead of on the next poll.
        // `reviewedPRs` is already deduped against the requested queue by
        // `IssueTracker`.
        let requested = appState.filteredReviewRequests
        let reviewed = appState.filteredReviewedPRs

        var counts: [ReviewGroup: Int] = [:]
        func serialize(_ r: ReviewRequest, isRequestedOfViewer: Bool) -> JSONValue? {
            let existing = appState.existingReviewSession(forPRURL: r.url)
            let linked = r.reviewSessionID.flatMap { id in
                appState.sessions.first(where: { $0.id == id })
            } ?? existing
            // "A review is open/in progress on it" — an *active* session, since
            // both `reviewSessionID` (cross-referenced from `reviewSessions`)
            // and `existingReviewSession` exclude completed/archived rounds.
            // Consulting `existing` too covers the ~10s clone window before the
            // cross-reference lands, so a just-started round doesn't flicker
            // through "Not approved yet".
            let hasActiveSession = r.reviewSessionID != nil || existing != nil
            guard let group = ReviewGroup.classify(
                r,
                hasActiveReviewSession: hasActiveSession,
                isRequestedOfViewer: isRequestedOfViewer,
                now: now
            ) else { return nil }
            // Takes the group, not just the session state: two of the four mean
            // "there is nothing here to review" for reasons the session logic
            // cannot see. See `kickoffAction`.
            let action = kickoffAction(for: r, group: group, linked: linked, existing: existing)
            counts[group, default: 0] += 1
            // Built by assignment after a small literal rather than as one
            // ~20-key dictionary literal: the single literal blew Swift's
            // type-checker budget outright ("unable to type-check this
            // expression in reasonable time") once the last two keys landed.
            var fields: [String: JSONValue] = [
                "id": .string(r.id),
                "pr_number": .int(r.prNumber),
                "title": .string(r.title),
                "url": .string(r.url),
                "repo": .string(r.repo),
                "author": .string(r.author),
                "head_branch": .string(r.headBranch),
                "base_branch": .string(r.baseBranch),
                "is_draft": .bool(r.isDraft),
                "provider": .string(r.provider.rawValue),
            ]
            fields["requested_at"] = r.requestedAt.map { .string(fmt.string(from: $0)) } ?? .null
            fields["labels"] = .array(r.labels.map {
                .object(["name": .string($0.name), "color": $0.color.map { .string($0) } ?? .null])
            })
            fields["review_session_id"] = r.reviewSessionID.map { .string($0.uuidString) } ?? .null
            fields["head_ref_oid"] = r.headRefOid.map { .string($0) } ?? .null
            fields["viewer_last_reviewed_head_sha"] = r.viewerLastReviewedHeadSha.map { .string($0) } ?? .null
            fields["kickoff_action"] = .string(actionName(action))
            fields["viewer_last_reviewed_at"] = r.viewerLastReviewedAt.map { .string(fmt.string(from: $0)) } ?? .null
            fields["viewer_last_review_state"] = r.viewerLastReviewState.map { .string($0.rawValue) } ?? .null
            fields["state"] = r.state.map { .string($0) } ?? .null
            fields["completed_at"] = r.completedAt.map { .string(fmt.string(from: $0)) } ?? .null
            fields["group"] = .string(group.rawValue)
            return .object(fields)
        }

        // Which list a review came from is itself a signal, so it is passed to
        // `classify` rather than re-derived: `requested` is exactly the set
        // GitHub is still asking the viewer about. A PR that appears in both
        // searches (reviewed, then re-requested) is deduped into `requested` by
        // `IssueTracker`, so it is classified as the queue member it is.
        //
        // Precedence still holds within each list: a PR you approved a minute
        // ago that has a live session stays under In review.
        let reviews: [JSONValue] = requested.compactMap { serialize($0, isRequestedOfViewer: true) }
            + reviewed.compactMap { serialize($0, isRequestedOfViewer: false) }

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
            // Which groups a *new* row in may chime `reviewRequested` for. The
            // web board used to name the excluded group inline, which meant
            // adding a fourth group silently opted it into the chime — a
            // `waiting_on_author` row is populated by your own verdict landing,
            // so announcing it as work arriving is backwards. Publishing the
            // rule keeps it beside the grouping it belongs to.
            "group_announces_new_request": .object(Dictionary(
                uniqueKeysWithValues: ReviewGroup.displayOrder.map {
                    ($0.rawValue, JSONValue.bool($0.announcesAsNewRequest))
                }
            )),
            "hidden_by_filters": .int(appState.hiddenReviewCount),
        ]
    }

    /// Which kickoff a row offers — the **one** rule `crow list-reviews` and the
    /// web board both read (the browser only re-labels `kickoff_action`, it never
    /// re-derives it).
    ///
    /// Two groups get the decision short-circuited rather than run, because
    /// `IssueTracker.reviewKickoffAction` reasons purely about sessions and head
    /// SHAs and cannot see *why* a row is on the board:
    ///
    ///  - **Completed.** A merged or closed PR cannot be reviewed again, and the
    ///    session logic would happily offer "Start Review" on something that
    ///    shipped yesterday.
    ///  - **Waiting on author** (CROW-997). The ball is with the author, so there
    ///    is nothing new to look at until they push. The session logic can't tell:
    ///    the round auto-completed the instant the verdict landed
    ///    (`decideReviewCompletions` rule 1), so there is no `linkedSession` to
    ///    compare heads against, `shaAdvanced` is false for want of a left-hand
    ///    side, and every such row fell through to `.create`. That rendered Start
    ///    Review as the card's primary action and made it tickable in the board's
    ///    batch mode — eight redundant rounds one click away.
    ///
    /// The waiting-on-author suppression is conditional, not blanket, because the
    /// author *can* push without re-requesting: the PR stays out of
    /// `review-requested:@me`, stays under this heading, and genuinely does have
    /// something new in it. `viewerReviewCoversCurrentHead` is what tells the two
    /// apart, and it answers `false` unless it can prove the heads match — so an
    /// unfetched SHA keeps the button rather than stranding the row. (With
    /// `--auto-re-request-review` on, CROW-921 re-adds the reviewer and the PR
    /// leaves this group on its own; the board must not *depend* on that watcher,
    /// which is optional.)
    ///
    /// `.skip` is what makes a row unselectable in batch mode too, so suppressing
    /// the button and suppressing the checkbox are one decision, not two.
    static func kickoffAction(
        for r: ReviewRequest,
        group: ReviewGroup,
        linked: Session?,
        existing: Session?
    ) -> IssueTracker.ReviewKickoffAction {
        if r.isCompleted { return .skip }
        if group == .waitingOnAuthor && r.viewerReviewCoversCurrentHead { return .skip }
        return IssueTracker.reviewKickoffAction(
            reviewSessionID: r.reviewSessionID ?? existing?.id,
            headRefOid: r.headRefOid,
            linkedSession: linked,
            existingByPRSessionID: existing?.id
        )
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
