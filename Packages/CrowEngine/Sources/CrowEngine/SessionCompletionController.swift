import Foundation
import CrowCore
import CrowPersistence
import CrowProvider

/// Auto-complete + auto-cleanup, extracted from `IssueTracker` (CROW-1094).
/// Syncs In-Review status, completes finished work/review sessions on positive
/// evidence of closure, and reaps expired completed/archived sessions. All
/// completion decisions are pure `nonisolated static` functions for unit
/// testing; the instance methods only read `appState` and fire its completion
/// callbacks. `public` because `reviewKickoffAction` / `ReviewKickoffAction`
/// are the cross-module review-kickoff decision consumed by `ReviewsPayload`
/// and `SessionService` (re-exposed under the old `IssueTracker.` spelling).
@MainActor
public final class SessionCompletionController {
    private unowned let owner: IssueTracker
    private var appState: AppState { owner.appState }

    /// Local alias mirroring `IssueTracker.ViewerPR` (both are `PRRecord`).
    typealias ViewerPR = PRRecord

    init(owner: IssueTracker) { self.owner = owner }

    // MARK: - Auto-Complete (piggyback)

    /// Sync active sessions whose linked ticket has "In Review" project status to .inReview session status.
    func syncInReviewSessions(issues: [AssignedIssue]) {
        let inReviewURLs = Set(issues.filter { $0.projectStatus == .inReview }.map(\.url))

        for session in appState.activeSessions {
            guard let ticketURL = session.ticketURL else { continue }
            if inReviewURLs.contains(ticketURL) {
                print("[IssueTracker] Session '\(session.name)' — ticket is In Review on project board, updating session status")
                appState.onSetSessionInReview?(session.id)
            }
        }
    }

    /// Decision returned by `decideSessionCompletions` — carries both the
    /// session to complete and a short reason used in the log line emitted
    /// by the adapter.
    struct CompletionDecision: Equatable {
        let sessionID: UUID
        let reason: String
    }

    /// Result of a completion-decision pass. `floorGuardTriggered` is `true`
    /// when the decider refused to complete anything because the fetched
    /// open-issue set was empty while candidate sessions had ticket URLs —
    /// a strong indicator that the underlying GraphQL response was partial
    /// or errored. Surfaced so the adapter can log a warning and tests can
    /// assert the guard fired.
    struct CompletionResult: Equatable {
        let completions: [CompletionDecision]
        let floorGuardTriggered: Bool
    }

    /// Decide which candidate sessions should be auto-completed based on
    /// the current refresh payload. Requires positive evidence of closure:
    /// a PR-linked session needs its PR in `prsByURL` with state `MERGED`
    /// or `CLOSED`; an issue-only session needs its ticket URL in
    /// `closedIssueURLs`. Missing-from-open is no longer sufficient.
    ///
    /// `prDataComplete` is `false` when the stale-PR follow-up errored
    /// (rate-limited, non-zero exit, parse failure). In that case, PR-linked
    /// completions are skipped entirely to avoid completing on stale data.
    nonisolated static func decideSessionCompletions(
        candidateSessions: [Session],
        linksBySessionID: [UUID: [SessionLink]],
        openIssueURLs: Set<String>,
        closedIssueURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        prDataComplete: Bool
    ) -> CompletionResult {
        let withTickets = candidateSessions.filter { $0.ticketURL != nil }

        // Floor guard: if we have candidates but openIssueURLs is empty, the
        // consolidated query likely returned partial data. Skip this cycle.
        // This is belt-and-suspenders — the positive-evidence rules below
        // already refuse to complete without a MERGED/CLOSED PR or a
        // closedIssueURLs hit — but the guard catches future regressions
        // that reintroduce an absence-based path.
        if !withTickets.isEmpty && openIssueURLs.isEmpty {
            return CompletionResult(completions: [], floorGuardTriggered: true)
        }

        var decisions: [CompletionDecision] = []
        for session in withTickets {
            guard let ticketURL = session.ticketURL else { continue }
            if openIssueURLs.contains(ticketURL) { continue }

            let sessionLinks = linksBySessionID[session.id] ?? []
            if let prLink = sessionLinks.first(where: { $0.linkType == .pr }) {
                guard prDataComplete else { continue }
                guard let pr = prsByURL[prLink.url] else { continue }
                switch pr.state {
                case "MERGED":
                    decisions.append(CompletionDecision(sessionID: session.id, reason: "PR merged"))
                case "CLOSED":
                    decisions.append(CompletionDecision(sessionID: session.id, reason: "PR closed"))
                default:
                    break
                }
                continue
            }

            if session.provider == .github || session.provider == nil {
                if closedIssueURLs.contains(ticketURL) {
                    decisions.append(CompletionDecision(sessionID: session.id, reason: "issue closed"))
                }
            }
        }
        return CompletionResult(completions: decisions, floorGuardTriggered: false)
    }

    /// The reviewer-side auto-kickoff decision for a single review request,
    /// mirroring the legacy `AppDelegate.onReviewRequestsRefreshed` guard
    /// (retired in the headless-engine migration, ADR 0008). Pure so the
    /// daemon's imperative shell (repo-pattern filter, SHA fingerprint dedup,
    /// clone serializer) stays thin and this branch is unit-testable.
    ///
    /// - `.create`: no session exists for this PR yet — spawn a review session.
    /// - `.reReview`: a linked session exists but the PR head advanced past the
    ///   SHA it last reviewed (author pushed / force-pushed after a first pass).
    ///   The stale session is completed and a fresh one spun up against the new
    ///   head (CROW-290 keys each head as its own round; CROW-406's
    ///   `existingByPR` guards the clone window). Carries the stale session ID
    ///   so the caller tears it down before enqueuing.
    /// - `.skip`: a session already covers this PR at the current head.
    public enum ReviewKickoffAction: Equatable {
        case skip
        case create
        case reReview(staleSessionID: UUID)
    }

    /// - Parameters:
    ///   - reviewSessionID: the `ReviewRequest`'s cross-referenced session, or
    ///     nil until `IssueTracker` repopulates it (lags the actual session by
    ///     up to one refresh).
    ///   - headRefOid: the PR's current head SHA (nil when unfetched — never
    ///     re-reviews on a missing head).
    ///   - linkedSession: the session resolved from `reviewSessionID`.
    ///   - existingByPRSessionID: `AppState.existingReviewSession(forPRURL:)` —
    ///     the authoritative link-based lookup that catches an in-flight kickoff
    ///     before `reviewSessionID` is written back.
    nonisolated public static func reviewKickoffAction(
        reviewSessionID: UUID?,
        headRefOid: String?,
        linkedSession: Session?,
        existingByPRSessionID: UUID?
    ) -> ReviewKickoffAction {
        // B-fallback: linked session exists but its last-reviewed head is
        // stale relative to the PR's current head → re-review the new head.
        let shaAdvanced = linkedSession != nil
            && headRefOid != nil
            && linkedSession?.lastReviewedHeadSha != headRefOid
        if shaAdvanced, let staleID = reviewSessionID {
            return .reReview(staleSessionID: staleID)
        }
        // Create only when nothing already covers this PR (belt-and-suspenders:
        // the lagging `reviewSessionID` cross-ref plus the authoritative
        // link-based lookup, so the ~10s clone window can't double-kick).
        if reviewSessionID == nil && existingByPRSessionID == nil {
            return .create
        }
        return .skip
    }

    /// Decide which review sessions should be auto-completed. Three rules:
    ///   1. Viewer has submitted a formal review (APPROVED / CHANGES_REQUESTED
    ///      / DISMISSED) at a time strictly after `session.createdAt`. This
    ///      closes the round so that an author's subsequent `/refine` +
    ///      re-request lands as a fresh review request with no linked
    ///      session, letting the kickoff guard re-fire (CROW-290).
    ///   2. PR is MERGED — terminal state, always complete.
    ///   3. PR is CLOSED — terminal state, always complete.
    /// Rules 2 + 3 require the PR to be present in `prsByURL` with the
    /// matching state and `prDataComplete == true` so the old "missing
    /// from open review queue == done" rule isn't reintroduced under
    /// partial fetches.
    ///
    /// Rule 1 reads **two** sources and fires on the later of them (CROW-945).
    /// `reviewRequestsByPRURL` alone could not work: it is built from the
    /// `review-requested:@me` search, and GitHub clears the pending request the
    /// instant the viewer submits a review, so the PR leaves that search at
    /// exactly the moment the round should close. A rule sourced only from it
    /// could fire only by winning a race against GitHub's search index — which
    /// is why, in practice, review rounds never closed at all. `prsByURL`
    /// carries the same verdict read off the PR itself, which survives the
    /// request being consumed.
    ///
    /// Rule 1 is deliberately **not** gated on `prDataComplete`, including its
    /// new `prsByURL` branch. That flag exists to stop *absence* being read as
    /// evidence; rule 1 is *presence*-based — a degraded fetch yields no entry,
    /// hence a nil timestamp, hence no decision. Gating it would make the fix
    /// silently miss on any cycle where an unrelated provider errored, which is
    /// the same over-conservatism that leaves rounds open.
    nonisolated static func decideReviewCompletions(
        reviewSessions: [Session],
        linksBySessionID: [UUID: [SessionLink]],
        openReviewPRURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        reviewRequestsByPRURL: [String: ReviewRequest],
        prDataComplete: Bool
    ) -> [CompletionDecision] {
        var decisions: [CompletionDecision] = []
        for session in reviewSessions {
            let sessionLinks = linksBySessionID[session.id] ?? []
            guard let prLink = sessionLinks.first(where: { $0.linkType == .pr }) else { continue }

            // Rule 1: viewer-submitted review after the session was created.
            let reviewedAt = [
                reviewRequestsByPRURL[prLink.url]?.viewerLastReviewedAt,
                prsByURL[prLink.url]?.viewerLastReviewedAt,
            ].compactMap { $0 }.max()
            if let reviewedAt, reviewedAt > session.createdAt {
                decisions.append(CompletionDecision(sessionID: session.id, reason: "viewer submitted review"))
                continue
            }

            // Rules 2 + 3 — terminal PR states. Require complete data.
            guard prDataComplete else { continue }
            if openReviewPRURLs.contains(prLink.url) { continue }
            guard let pr = prsByURL[prLink.url] else { continue }
            switch pr.state {
            case "MERGED":
                decisions.append(CompletionDecision(sessionID: session.id, reason: "PR merged"))
            case "CLOSED":
                decisions.append(CompletionDecision(sessionID: session.id, reason: "PR closed"))
            default:
                break
            }
        }
        return decisions
    }

    /// Check active sessions whose linked ticket is no longer in the open
    /// issues list. Delegates to `decideSessionCompletions` so the decision
    /// logic is covered by unit tests without a shell/Process abstraction.
    func autoCompleteFinishedSessions(
        openIssues: [AssignedIssue],
        closedIssueURLs: Set<String>,
        viewerPRs: [ViewerPR],
        prDataComplete: Bool
    ) {
        let openIssueURLs = Set(openIssues.map(\.url))
        let prsByURL = Dictionary(viewerPRs.map { ($0.url, $0) }, uniquingKeysWith: IssueTracker.mergePRRecords)

        let candidateSessions = appState.sessions.filter {
            !$0.isManager &&
            ($0.status == .active || $0.status == .paused || $0.status == .inReview)
        }
        var linksBySessionID: [UUID: [SessionLink]] = [:]
        for session in candidateSessions {
            linksBySessionID[session.id] = appState.links(for: session.id)
        }

        let result = Self.decideSessionCompletions(
            candidateSessions: candidateSessions,
            linksBySessionID: linksBySessionID,
            openIssueURLs: openIssueURLs,
            closedIssueURLs: closedIssueURLs,
            prsByURL: prsByURL,
            prDataComplete: prDataComplete
        )

        if result.floorGuardTriggered {
            let count = candidateSessions.filter { $0.ticketURL != nil }.count
            print("[IssueTracker] skipping auto-complete — openIssues empty with \(count) candidate sessions (likely partial fetch)")
            return
        }

        let sessionsByID = Dictionary(uniqueKeysWithValues: candidateSessions.map { ($0.id, $0) })
        for decision in result.completions {
            let name = sessionsByID[decision.sessionID]?.name ?? decision.sessionID.uuidString
            print("[IssueTracker] Session '\(name)' — \(decision.reason), marking completed")
            appState.onCompleteSession?(decision.sessionID)
        }
    }

    /// Auto-complete review sessions whose PR has been merged or closed.
    /// Delegates to `decideReviewCompletions` for testability.
    ///
    /// The candidate filter matches `AppState.reviewSessions` (which excludes
    /// only `.completed`/`.archived`), `collectStalePRURLs`, and
    /// `autoCompleteFinishedSessions` — deliberately, because those are the
    /// statuses that keep a session shadowing its PR. Filtering to `.active`
    /// alone (as this did before CROW-945) left a `.paused` or `.inReview`
    /// review session visible to `existingReviewSession(forPRURL:)` forever
    /// with no rule anywhere able to complete it, so the PR could never start
    /// another round.
    func autoCompleteFinishedReviews(
        openReviewPRURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        reviewRequestsByPRURL: [String: ReviewRequest],
        prDataComplete: Bool
    ) {
        let activeReviews = appState.sessions.filter {
            $0.kind == .review
                && ($0.status == .active || $0.status == .paused || $0.status == .inReview)
        }
        var linksBySessionID: [UUID: [SessionLink]] = [:]
        for session in activeReviews {
            linksBySessionID[session.id] = appState.links(for: session.id)
        }

        let decisions = Self.decideReviewCompletions(
            reviewSessions: activeReviews,
            linksBySessionID: linksBySessionID,
            openReviewPRURLs: openReviewPRURLs,
            prsByURL: prsByURL,
            reviewRequestsByPRURL: reviewRequestsByPRURL,
            prDataComplete: prDataComplete
        )

        let sessionsByID = Dictionary(uniqueKeysWithValues: activeReviews.map { ($0.id, $0) })
        for decision in decisions {
            let name = sessionsByID[decision.sessionID]?.name ?? decision.sessionID.uuidString
            print("[IssueTracker] Review session '\(name)' — \(decision.reason), marking completed")
            appState.onCompleteSession?(decision.sessionID)
        }
    }

    // MARK: - Auto-Cleanup

    /// Protected session IDs that must never be deleted by auto-cleanup.
    /// Includes the manager session and all fixed-UUID virtual tab sessions.
    nonisolated static let protectedSessionIDs: Set<UUID> = [
        AppState.managerSessionID,
        AppState.ticketBoardSessionID,
        AppState.reviewBoardSessionID,
        AppState.scorecardSessionID,
    ]

    /// Pure decision function: returns session IDs eligible for auto-cleanup.
    /// A session is eligible when its status is `.completed` or `.archived`,
    /// its `updatedAt` is older than the retention cutoff, and its ID is not
    /// in the protected set.
    nonisolated static func sessionsEligibleForCleanup(
        sessions: [Session],
        retentionHours: Int,
        now: Date = Date()
    ) -> [UUID] {
        let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3600)
        return sessions.compactMap { session in
            guard !protectedSessionIDs.contains(session.id) else { return nil }
            guard !session.isManager else { return nil }
            guard !session.locked else { return nil }
            guard session.status == .completed || session.status == .archived else { return nil }
            guard session.updatedAt < cutoff else { return nil }
            return session.id
        }
    }

    /// Delete completed/archived sessions that have exceeded their retention
    /// window. Errors are logged per-session by the `onDeleteSession` callback
    /// and do not abort subsequent deletions.
    func autoCleanupExpiredSessions(config: AppConfig) async {
        guard config.cleanup.enabled else { return }

        let eligible = Self.sessionsEligibleForCleanup(
            sessions: appState.sessions,
            retentionHours: config.cleanup.retentionHours
        )
        guard !eligible.isEmpty else { return }

        let sessionsByID = Dictionary(uniqueKeysWithValues: appState.sessions.map { ($0.id, $0) })
        for sessionID in eligible {
            let name = sessionsByID[sessionID]?.name ?? sessionID.uuidString
            print("[IssueTracker] Auto-cleanup: deleting session '\(name)' (retention: \(config.cleanup.retentionHours)h)")
            await owner.onDeleteSession?(sessionID)
        }
    }
}

// MARK: - IssueTracker compatibility surface (CROW-1094)
//
// Preserves the `IssueTracker.<symbol>` spelling that existing tests and
// cross-module callers (`ReviewsPayload`, `SessionService`) already use, so the
// extraction is API- and behavior-preserving. All logic lives on
// `SessionCompletionController`; these forward to it.
extension IssueTracker {
    typealias CompletionDecision = SessionCompletionController.CompletionDecision
    public typealias ReviewKickoffAction = SessionCompletionController.ReviewKickoffAction

    nonisolated public static func reviewKickoffAction(
        reviewSessionID: UUID?,
        headRefOid: String?,
        linkedSession: Session?,
        existingByPRSessionID: UUID?
    ) -> ReviewKickoffAction {
        SessionCompletionController.reviewKickoffAction(
            reviewSessionID: reviewSessionID,
            headRefOid: headRefOid,
            linkedSession: linkedSession,
            existingByPRSessionID: existingByPRSessionID)
    }

    nonisolated static func decideSessionCompletions(
        candidateSessions: [Session],
        linksBySessionID: [UUID: [SessionLink]],
        openIssueURLs: Set<String>,
        closedIssueURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        prDataComplete: Bool
    ) -> SessionCompletionController.CompletionResult {
        SessionCompletionController.decideSessionCompletions(
            candidateSessions: candidateSessions,
            linksBySessionID: linksBySessionID,
            openIssueURLs: openIssueURLs,
            closedIssueURLs: closedIssueURLs,
            prsByURL: prsByURL,
            prDataComplete: prDataComplete)
    }

    nonisolated static func decideReviewCompletions(
        reviewSessions: [Session],
        linksBySessionID: [UUID: [SessionLink]],
        openReviewPRURLs: Set<String>,
        prsByURL: [String: ViewerPR],
        reviewRequestsByPRURL: [String: ReviewRequest],
        prDataComplete: Bool
    ) -> [CompletionDecision] {
        SessionCompletionController.decideReviewCompletions(
            reviewSessions: reviewSessions,
            linksBySessionID: linksBySessionID,
            openReviewPRURLs: openReviewPRURLs,
            prsByURL: prsByURL,
            reviewRequestsByPRURL: reviewRequestsByPRURL,
            prDataComplete: prDataComplete)
    }

    nonisolated static func sessionsEligibleForCleanup(
        sessions: [Session],
        retentionHours: Int,
        now: Date = Date()
    ) -> [UUID] {
        SessionCompletionController.sessionsEligibleForCleanup(
            sessions: sessions, retentionHours: retentionHours, now: now)
    }
}
