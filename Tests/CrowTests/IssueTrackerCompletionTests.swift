import Foundation
import Testing
import CrowCore
@testable import Crow

@Suite("IssueTracker completion decisions")
struct IssueTrackerCompletionTests {

    // MARK: - Fixtures

    private func makeSession(
        id: UUID = UUID(),
        name: String = "session",
        status: SessionStatus = .active,
        kind: SessionKind = .work,
        ticketURL: String? = nil,
        provider: Provider? = .github,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        locked: Bool = false
    ) -> Session {
        Session(
            id: id,
            name: name,
            status: status,
            kind: kind,
            ticketURL: ticketURL,
            provider: provider,
            createdAt: createdAt,
            updatedAt: updatedAt,
            locked: locked
        )
    }

    private func makeReviewRequest(
        url: String,
        viewerLastReviewedAt: Date? = nil,
        headRefOid: String? = nil
    ) -> ReviewRequest {
        ReviewRequest(
            id: "github:foo/bar#9",
            prNumber: 9,
            title: "title",
            url: url,
            repo: "foo/bar",
            author: "alice",
            headBranch: "feature",
            baseBranch: "main",
            headRefOid: headRefOid,
            viewerLastReviewedAt: viewerLastReviewedAt
        )
    }

    private func prLink(sessionID: UUID, url: String) -> SessionLink {
        SessionLink(sessionID: sessionID, label: "PR", url: url, linkType: .pr)
    }

    private func makeViewerPR(
        url: String,
        state: String,
        number: Int = 1
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: number,
            url: url,
            state: state,
            mergeable: "UNKNOWN",
            mergeStateStatus: "UNKNOWN",
            reviewDecision: "",
            isDraft: false,
            headRefName: "",
            headRefOid: "",
            baseRefName: "",
            repoNameWithOwner: "",
            labels: [],
            linkedIssueReferences: [],
            checksState: "",
            failedCheckNames: [],
            latestReviewStates: []
        )
    }

    // MARK: - Floor guard (the crow#181 regression)

    @Test
    func emptyOpenIssuesWithCandidatesTriggersFloorGuard() {
        // The bug: a degraded consolidated-GraphQL response produced an
        // empty openIssues list. Every candidate session with a ticket URL
        // fell through the "absence == done" branches and was marked
        // completed. With the guard, we must refuse to complete anything.
        let session = makeSession(
            name: "citadel-134-sensor-framework",
            ticketURL: "https://github.com/foo/citadel/issues/134"
        )
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [:],
            openIssueURLs: [],
            closedIssueURLs: [],
            prsByURL: [:],
            prDataComplete: true
        )
        #expect(result.floorGuardTriggered == true)
        #expect(result.completions.isEmpty)
    }

    @Test
    func floorGuardDoesNotFireWhenNoCandidatesHaveTickets() {
        // If no candidate sessions have ticket URLs, an empty openIssues
        // set is just a user with no assigned issues — not a partial fetch.
        let session = makeSession(ticketURL: nil)
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [:],
            openIssueURLs: [],
            closedIssueURLs: [],
            prsByURL: [:],
            prDataComplete: true
        )
        #expect(result.floorGuardTriggered == false)
        #expect(result.completions.isEmpty)
    }

    // MARK: - Positive-evidence rules

    @Test
    func mergedPRCompletes() {
        let session = makeSession(ticketURL: "https://github.com/foo/bar/issues/1")
        let prURL = "https://github.com/foo/bar/pull/2"
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [session.id: [prLink(sessionID: session.id, url: prURL)]],
            openIssueURLs: ["https://github.com/foo/bar/issues/other"],
            closedIssueURLs: [],
            prsByURL: [prURL: makeViewerPR(url: prURL, state: "MERGED")],
            prDataComplete: true
        )
        #expect(result.floorGuardTriggered == false)
        #expect(result.completions == [
            IssueTracker.CompletionDecision(sessionID: session.id, reason: "PR merged")
        ])
    }

    @Test
    func closedPRCompletes() {
        let session = makeSession(ticketURL: "https://github.com/foo/bar/issues/1")
        let prURL = "https://github.com/foo/bar/pull/2"
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [session.id: [prLink(sessionID: session.id, url: prURL)]],
            openIssueURLs: ["https://github.com/foo/bar/issues/other"],
            closedIssueURLs: [],
            prsByURL: [prURL: makeViewerPR(url: prURL, state: "CLOSED")],
            prDataComplete: true
        )
        #expect(result.completions == [
            IssueTracker.CompletionDecision(sessionID: session.id, reason: "PR closed")
        ])
    }

    @Test
    func openPRHoldsOff() {
        let session = makeSession(ticketURL: "https://github.com/foo/bar/issues/1")
        let prURL = "https://github.com/foo/bar/pull/2"
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [session.id: [prLink(sessionID: session.id, url: prURL)]],
            openIssueURLs: ["https://github.com/foo/bar/issues/other"],
            closedIssueURLs: [],
            prsByURL: [prURL: makeViewerPR(url: prURL, state: "OPEN")],
            prDataComplete: true
        )
        #expect(result.completions.isEmpty)
    }

    @Test
    func partialStalePRFetchDoesNotComplete() {
        // prDataComplete == false means the stale-PR follow-up errored.
        // A PR-linked session must not be completed — we don't have trust
        // in the PR state, even for MERGED/CLOSED records that happen to
        // appear (they may be stale from a prior cycle, but conservatively
        // we refuse to act on this cycle's incomplete data).
        let session = makeSession(ticketURL: "https://github.com/foo/bar/issues/1")
        let prURL = "https://github.com/foo/bar/pull/2"
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [session.id: [prLink(sessionID: session.id, url: prURL)]],
            openIssueURLs: ["https://github.com/foo/bar/issues/other"],
            closedIssueURLs: [],
            prsByURL: [:],
            prDataComplete: false
        )
        #expect(result.completions.isEmpty)
    }

    @Test
    func prMissingFromPayloadDoesNotComplete() {
        // Even with prDataComplete == true, a PR that's simply absent from
        // the payload (deleted, no access, or the viewer lost visibility)
        // is not positive evidence of closure. The old code treated this
        // as "PR no longer open, marking completed" — removed.
        let session = makeSession(ticketURL: "https://github.com/foo/bar/issues/1")
        let prURL = "https://github.com/foo/bar/pull/2"
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [session.id: [prLink(sessionID: session.id, url: prURL)]],
            openIssueURLs: ["https://github.com/foo/bar/issues/other"],
            closedIssueURLs: [],
            prsByURL: [:],
            prDataComplete: true
        )
        #expect(result.completions.isEmpty)
    }

    @Test
    func issueOnlyCompletesViaClosedIssueURL() {
        let ticketURL = "https://github.com/foo/bar/issues/1"
        let session = makeSession(ticketURL: ticketURL)
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [:],
            openIssueURLs: ["https://github.com/foo/bar/issues/other"],
            closedIssueURLs: [ticketURL],
            prsByURL: [:],
            prDataComplete: true
        )
        #expect(result.completions == [
            IssueTracker.CompletionDecision(sessionID: session.id, reason: "issue closed")
        ])
    }

    @Test
    func issueOnlyStaysActiveWhenMissingFromBothSets() {
        // This is the primary bug scenario: the issue isn't in openIssues
        // but also isn't in the recent closed set (either because the
        // fetch was partial, or the closure is older than 24h). Under the
        // old code, this session would be marked completed; now it must
        // stay active.
        let session = makeSession(
            name: "citadel-98-cost-tracking-pricing",
            ticketURL: "https://github.com/foo/citadel/issues/98"
        )
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [:],
            openIssueURLs: ["https://github.com/foo/citadel/issues/other"],
            closedIssueURLs: [],
            prsByURL: [:],
            prDataComplete: true
        )
        #expect(result.floorGuardTriggered == false)
        #expect(result.completions.isEmpty)
    }

    @Test
    func sessionStillInOpenIssuesIsSkipped() {
        let ticketURL = "https://github.com/foo/bar/issues/1"
        let session = makeSession(ticketURL: ticketURL)
        let result = IssueTracker.decideSessionCompletions(
            candidateSessions: [session],
            linksBySessionID: [:],
            openIssueURLs: [ticketURL],
            closedIssueURLs: [ticketURL],
            prsByURL: [:],
            prDataComplete: true
        )
        // Still open trumps closed — a session whose ticket is in the open
        // set must not be completed regardless of other payload contents.
        #expect(result.completions.isEmpty)
    }

    // MARK: - Review completion

    @Test
    func reviewPRMergedCompletes() {
        let reviewSession = makeSession(
            kind: .review,
            ticketURL: nil
        )
        let prURL = "https://github.com/foo/bar/pull/9"
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [],
            prsByURL: [prURL: makeViewerPR(url: prURL, state: "MERGED")],
            reviewRequestsByPRURL: [:],
            prDataComplete: true
        )
        #expect(decisions == [
            IssueTracker.CompletionDecision(sessionID: reviewSession.id, reason: "PR merged")
        ])
    }

    @Test
    func reviewStillInOpenReviewQueueIsSkipped() {
        let reviewSession = makeSession(kind: .review)
        let prURL = "https://github.com/foo/bar/pull/9"
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [prURL],
            prsByURL: [prURL: makeViewerPR(url: prURL, state: "MERGED")],
            reviewRequestsByPRURL: [:],
            prDataComplete: true
        )
        #expect(decisions.isEmpty)
    }

    @Test
    func reviewDoesNotCompleteWhenPRDataIncomplete() {
        let reviewSession = makeSession(kind: .review)
        let prURL = "https://github.com/foo/bar/pull/9"
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [],
            prsByURL: [prURL: makeViewerPR(url: prURL, state: "MERGED")],
            reviewRequestsByPRURL: [:],
            prDataComplete: false
        )
        #expect(decisions.isEmpty)
    }

    @Test
    func reviewMissingFromPayloadDoesNotComplete() {
        // Old code: "PR no longer open for review, marking completed".
        // New rule: without a MERGED/CLOSED record in prsByURL, don't act.
        let reviewSession = makeSession(kind: .review)
        let prURL = "https://github.com/foo/bar/pull/9"
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [],
            prsByURL: [:],
            reviewRequestsByPRURL: [:],
            prDataComplete: true
        )
        #expect(decisions.isEmpty)
    }

    // MARK: - Viewer-submitted review completes session (CROW-290)

    @Test
    func reviewSubmittedAfterSessionStartCompletes() {
        // Reviewer has submitted a verdict (APPROVED) after the session was
        // created — close the session so a re-request lands as a fresh one.
        let createdAt = Date().addingTimeInterval(-3600)
        let reviewSession = makeSession(kind: .review, createdAt: createdAt)
        let prURL = "https://github.com/foo/bar/pull/9"
        let request = makeReviewRequest(url: prURL, viewerLastReviewedAt: Date())
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [prURL],
            prsByURL: [:],
            reviewRequestsByPRURL: [prURL: request],
            prDataComplete: true
        )
        #expect(decisions == [
            IssueTracker.CompletionDecision(sessionID: reviewSession.id, reason: "viewer submitted review")
        ])
    }

    @Test
    func reviewSubmittedBeforeSessionStartIgnored() {
        // Reviewer's last verdict predates this session — that was round 1,
        // round 2's session is what's active now. Don't complete it.
        let reviewedAt = Date().addingTimeInterval(-3600)
        let reviewSession = makeSession(kind: .review, createdAt: Date())
        let prURL = "https://github.com/foo/bar/pull/9"
        let request = makeReviewRequest(url: prURL, viewerLastReviewedAt: reviewedAt)
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [prURL],
            prsByURL: [:],
            reviewRequestsByPRURL: [prURL: request],
            prDataComplete: true
        )
        #expect(decisions.isEmpty)
    }

    @Test
    func reviewWithNoViewerVerdictIgnored() {
        // PR has reviews from other users, or only viewer COMMENTED reviews.
        // `viewerLastReviewedAt` is nil because the parser already filters
        // these out. Decision function should treat that as "not yet reviewed".
        let reviewSession = makeSession(kind: .review, createdAt: Date().addingTimeInterval(-3600))
        let prURL = "https://github.com/foo/bar/pull/9"
        let request = makeReviewRequest(url: prURL, viewerLastReviewedAt: nil)
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [prURL],
            prsByURL: [:],
            reviewRequestsByPRURL: [prURL: request],
            prDataComplete: true
        )
        #expect(decisions.isEmpty)
    }

    @Test
    func viewerReviewCompletesEvenUnderPartialFetch() {
        // The viewer-submitted signal only needs the ReviewRequest payload,
        // which is always live data. It must not be gated on prDataComplete
        // (that gate exists for the MERGED/CLOSED rule, which has to guard
        // against missing-PR-as-closed under partial fetches).
        let reviewSession = makeSession(kind: .review, createdAt: Date().addingTimeInterval(-3600))
        let prURL = "https://github.com/foo/bar/pull/9"
        let request = makeReviewRequest(url: prURL, viewerLastReviewedAt: Date())
        let decisions = IssueTracker.decideReviewCompletions(
            reviewSessions: [reviewSession],
            linksBySessionID: [reviewSession.id: [prLink(sessionID: reviewSession.id, url: prURL)]],
            openReviewPRURLs: [prURL],
            prsByURL: [:],
            reviewRequestsByPRURL: [prURL: request],
            prDataComplete: false
        )
        #expect(decisions == [
            IssueTracker.CompletionDecision(sessionID: reviewSession.id, reason: "viewer submitted review")
        ])
    }

    // MARK: - Auto-Cleanup

    private func hoursAgo(_ hours: Double) -> Date {
        Date().addingTimeInterval(-hours * 3600)
    }

    @Test
    func completedSessionPastRetentionIsEligible() {
        let session = makeSession(status: .completed, updatedAt: hoursAgo(25))
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible == [session.id])
    }

    @Test
    func archivedSessionPastRetentionIsEligible() {
        let session = makeSession(status: .archived, updatedAt: hoursAgo(25))
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible == [session.id])
    }

    @Test
    func completedSessionWithinRetentionIsNotEligible() {
        let session = makeSession(status: .completed, updatedAt: hoursAgo(23))
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible.isEmpty)
    }

    @Test
    func activeSessionIsNeverEligible() {
        let session = makeSession(status: .active, updatedAt: hoursAgo(48))
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible.isEmpty)
    }

    @Test
    func pausedSessionIsNeverEligible() {
        let session = makeSession(status: .paused, updatedAt: hoursAgo(48))
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible.isEmpty)
    }

    @Test
    func inReviewSessionIsNeverEligible() {
        let session = makeSession(status: .inReview, updatedAt: hoursAgo(48))
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible.isEmpty)
    }

    @Test
    func lockedSessionPastRetentionIsNotEligible() {
        // A locked completed/job session must survive the reaper regardless of
        // age (CROW-569/CROW-573). Unlocking restores normal eligibility.
        let locked = makeSession(
            name: "locked-job",
            status: .completed,
            kind: .job,
            updatedAt: hoursAgo(48),
            locked: true
        )
        let unlocked = makeSession(
            name: "unlocked-job",
            status: .completed,
            kind: .job,
            updatedAt: hoursAgo(48)
        )
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [locked, unlocked],
            retentionHours: 24
        )
        #expect(eligible == [unlocked.id])
    }

    @Test
    func managerSessionIsProtected() {
        let session = makeSession(
            id: AppState.managerSessionID,
            status: .completed,
            updatedAt: hoursAgo(48)
        )
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible.isEmpty)
    }

    @Test
    func nonPrimaryManagerIsExcludedFromCleanup() {
        // A non-primary manager has a fresh UUID (not in protectedSessionIDs),
        // so it must be excluded via its kind rather than its ID.
        let session = makeSession(
            name: "Manager 2",
            status: .completed,
            kind: .manager,
            updatedAt: hoursAgo(48)
        )
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [session],
            retentionHours: 24
        )
        #expect(eligible.isEmpty)
    }

    @Test
    func virtualTabSessionsAreProtected() {
        let protectedIDs = [
            AppState.ticketBoardSessionID,
            AppState.allowListSessionID,
            AppState.reviewBoardSessionID,
        ]
        let sessions = protectedIDs.map {
            makeSession(id: $0, status: .completed, updatedAt: hoursAgo(48))
        }
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: sessions,
            retentionHours: 24
        )
        #expect(eligible.isEmpty)
    }

    @Test
    func mixedSessionsReturnsOnlyEligible() {
        let expired = makeSession(name: "expired", status: .completed, updatedAt: hoursAgo(25))
        let fresh = makeSession(name: "fresh", status: .completed, updatedAt: hoursAgo(1))
        let active = makeSession(name: "active", status: .active, updatedAt: hoursAgo(48))
        let manager = makeSession(
            id: AppState.managerSessionID,
            name: "manager",
            status: .completed,
            updatedAt: hoursAgo(48)
        )
        let eligible = IssueTracker.sessionsEligibleForCleanup(
            sessions: [expired, fresh, active, manager],
            retentionHours: 24
        )
        #expect(eligible == [expired.id])
    }
}
