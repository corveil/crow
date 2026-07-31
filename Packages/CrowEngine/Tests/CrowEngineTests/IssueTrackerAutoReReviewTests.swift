import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// CROW-921 — the auto-re-request-review watcher.
///
/// The bug: a PR whose CHANGES_REQUESTED findings were genuinely fixed could
/// park in `changesRequested` forever. `needsRefine` goes false the instant the
/// fix lands, so the only thing that re-requested review — a sentence inside
/// the `addressChanges` prompt — became unreachable; and with the host's review
/// request already consumed, the PR was invisible to `review-requested:@me`
/// too. Both halves of the loop went idle, each correct by its own rule.
///
/// These tests pin the decision surface. Following the convention in
/// `IssueTrackerAutoRebaseTests` / `IssueTrackerAutoMergeTests`, the pure
/// predicates carry the coverage; the tracker-level tests drive
/// `applyPRStatuses` and assert on the dispatch bookkeeping rather than on a
/// real `gh` call.
@Suite("IssueTracker auto re-request review (CROW-921)")
@MainActor
struct IssueTrackerAutoReReviewTests {
    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-auto-re-review-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private let prURL = "https://github.com/foo/bar/pull/1898"
    private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let reviewAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let beforeReview = Date(timeIntervalSince1970: 1_699_999_000)
    private let afterReview = Date(timeIntervalSince1970: 1_700_001_000)

    // MARK: - Fixtures

    private func makePR(
        reviewDecision: String = "CHANGES_REQUESTED",
        state: String = "OPEN",
        isDraft: Bool = false,
        sha: String? = nil,
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil,
        reviewers: [String] = ["dgershman"],
        hasPendingReviewRequest: Bool = false
    ) -> PRRecord {
        PRRecord(
            number: 1898,
            url: prURL,
            state: state,
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: "feature/x",
            headRefOid: sha ?? shaA,
            baseRefName: "main",
            repoNameWithOwner: "foo/bar",
            labels: [],
            linkedIssueReferences: [],
            checksState: "SUCCESS",
            failedCheckNames: [],
            latestReviewStates: ["CHANGES_REQUESTED"],
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt,
            changesRequestedReviewerLogins: reviewers,
            hasPendingReviewRequest: hasPendingReviewRequest
        )
    }

    /// The #921 snapshot: fix landed after the review, request cleared.
    private func fixedButUnrequestedPR(sha: String? = nil) -> PRRecord {
        makePR(
            sha: sha,
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview
        )
    }

    private func skipReason(
        pr: PRRecord,
        isReviewSession: Bool = false,
        agentSettled: Bool = true
    ) -> IssueTracker.AutoReReviewSkipReason? {
        IssueTracker.autoReReviewSkipReason(
            pr: pr,
            status: IssueTracker.buildPRStatus(from: pr),
            isReviewSession: isReviewSession,
            agentSettled: agentSettled
        )
    }

    // MARK: - Accepts

    @Test
    func acceptsAFixedButUnrequestedPR() {
        #expect(skipReason(pr: fixedButUnrequestedPR()) == nil)
    }

    @Test
    func acceptsWhenTheFixLandedAtExactlyTheReviewTimestamp() {
        // `<` not `<=` in the classifier, so the boundary is "responded".
        let pr = makePR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: reviewAt)
        #expect(skipReason(pr: pr) == nil)
    }

    // MARK: - Rejects

    @Test
    func rejectsWhenTheAgentStillOwesAFix() {
        // State 1. Re-requesting here would send the reviewer back to a PR
        // that hasn't changed — needs-refine owns this case.
        let pr = makePR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        #expect(skipReason(pr: pr) == .notAwaitingReRequest)
    }

    @Test
    func rejectsWhenARequestIsAlreadyPending() {
        // State 3. The ball is with the reviewer; a second request is noise.
        let pr = makePR(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview,
            hasPendingReviewRequest: true
        )
        #expect(skipReason(pr: pr) == .notAwaitingReRequest)
    }

    @Test
    func rejectsAPRThatIsNotChangesRequestedOrNotOpen() {
        #expect(skipReason(pr: makePR(
            reviewDecision: "APPROVED",
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview)) == .notAwaitingReRequest)
        #expect(skipReason(pr: makePR(
            state: "MERGED",
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview)) == .notAwaitingReRequest)
    }

    @Test
    func rejectsWhenThereIsNobodyToRequest() {
        // GitHub said CHANGES_REQUESTED but surfaced no reviewer login. Better
        // a logged skip than a `gh pr edit` with an empty reviewer list.
        let pr = makePR(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview,
            reviewers: []
        )
        #expect(skipReason(pr: pr) == .noReviewers)
    }

    @Test
    func rejectsADraftPR() {
        let pr = makePR(
            isDraft: true,
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview
        )
        #expect(skipReason(pr: pr) == .draft)
    }

    @Test
    func rejectsAReviewSessionsPR() {
        // A review session's linked PR belongs to somebody else — same
        // exclusion auto-rebase and needs-refine make.
        #expect(skipReason(pr: fixedButUnrequestedPR(), isReviewSession: true) == .reviewSession)
    }

    @Test
    func rejectsWhileTheAgentIsStillWorking() {
        // The agent may have fixed finding 1 of 3. Waiting only delays —
        // `.awaitingReRequest` holds until somebody adds the request — and it
        // keeps Crow from pinging a reviewer mid-fix.
        #expect(skipReason(pr: fixedButUnrequestedPR(), agentSettled: false) == .agentBusy)
    }

    @Test
    func sessionEligibilityExcludesManagerAndReviewSessions() {
        #expect(IssueTracker.sessionEligibleForAutoReReview(Session(name: "work", kind: .work)))
        #expect(!IssueTracker.sessionEligibleForAutoReReview(Session(name: "review", kind: .review)))
    }

    // MARK: - Round key

    @Test
    func aNewPushOrANewReviewIsANewRound() {
        let base = IssueTracker.autoReReviewRoundKey(
            url: prURL, headRefOid: shaA, lastChangesRequestedAt: reviewAt)
        // Same inputs → same key, so a repeated poll can't fire twice.
        #expect(base == IssueTracker.autoReReviewRoundKey(
            url: prURL, headRefOid: shaA, lastChangesRequestedAt: reviewAt))
        // A new push re-arms.
        #expect(base != IssueTracker.autoReReviewRoundKey(
            url: prURL, headRefOid: shaB, lastChangesRequestedAt: reviewAt))
        // So does a new reviewer submission.
        #expect(base != IssueTracker.autoReReviewRoundKey(
            url: prURL, headRefOid: shaA, lastChangesRequestedAt: afterReview))
        // A nil anchor is representable and distinct.
        #expect(base != IssueTracker.autoReReviewRoundKey(
            url: prURL, headRefOid: shaA, lastChangesRequestedAt: nil))
    }

    // MARK: - Tracker-level dispatch

    /// Tracker with one work session linked to `prURL`. The session's provider
    /// is `.corveil` on purpose: it has no `CodeBackend`, so even if the
    /// dispatched `Task` runs after the test body it can only log, never shell
    /// out to `gh`. The assertions below are all synchronous and read the
    /// dispatch bookkeeping, which `applyPRStatuses` writes before the `Task`
    /// is created.
    private func makeTracker(
        enabled: Bool = true,
        kind: SessionKind = .work,
        activityState: AgentActivityState = .idle,
        readiness: TerminalReadiness = .agentLaunched,
        withTerminal: Bool = true
    ) -> (tracker: IssueTracker, sessionID: UUID, state: AppState) {
        let state = AppState()
        var session = Session(name: "feature/x", kind: kind)
        session.provider = .corveil
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #1898", url: prURL, linkType: .pr)
        ]
        if withTerminal {
            let terminal = SessionTerminal(
                sessionID: session.id, name: "Claude", cwd: "/tmp", command: "claude", isManaged: true)
            state.terminals[session.id] = [terminal]
            state.terminalReadiness[terminal.id] = readiness
            state.hookState(for: session.id).activityState = activityState
        }
        let tracker = IssueTracker(
            appState: state, providerManager: ProviderManager(), store: Self.tempStore())
        tracker.autoReRequestReviewProvider = { enabled }
        return (tracker, session.id, state)
    }

    @Test
    func dispatchesOnceForAFixedButUnrequestedPR() {
        let (tracker, _, _) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(tracker.autoReRequestInFlight.contains(prURL))
        #expect(tracker.autoReRequestAttempted.count == 1)
    }

    @Test
    func doesNotDispatchWhenTheToggleIsOff() {
        let (tracker, _, _) = makeTracker(enabled: false)
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(tracker.autoReRequestInFlight.isEmpty)
        #expect(tracker.autoReRequestAttempted.isEmpty)
    }

    @Test
    func doesNotDispatchWhileTheAgentIsBusy() {
        let (tracker, _, _) = makeTracker(activityState: .working)
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(tracker.autoReRequestInFlight.isEmpty)
    }

    @Test
    func dispatchesWhenThereIsNoLaunchedAgentToWaitFor() {
        // The escape hatch. `isManagedTerminalIdle` returns false here, which
        // is right for typing a prompt and wrong for an API call — gating on
        // it would recreate the permanent dead-end for any session whose
        // terminal was closed or never launched.
        let (noTerminal, _, _) = makeTracker(withTerminal: false)
        noTerminal.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(noTerminal.autoReRequestInFlight.contains(prURL))

        let (preLaunch, _, _) = makeTracker(readiness: .shellReady)
        preLaunch.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(preLaunch.autoReRequestInFlight.contains(prURL))
    }

    @Test
    func doesNotRedispatchForTheSameRound() {
        let (tracker, _, _) = makeTracker()
        let pr = fixedButUnrequestedPR()
        tracker.applyPRStatuses(viewerPRs: [pr])
        // Clear the in-flight marker as the attempt's `defer` would, leaving
        // only the per-round guard to stop a second fire.
        tracker.autoReRequestInFlight.remove(prURL)

        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(tracker.autoReRequestInFlight.isEmpty)
        #expect(tracker.autoReRequestAttempted.count == 1)
    }

    @Test
    func aNewPushReArmsTheWatcher() {
        let (tracker, _, _) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR(sha: shaA)])
        tracker.autoReRequestInFlight.remove(prURL)

        // A second fix pushed before the reviewer looked: new head, new round.
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR(sha: shaB)])
        #expect(tracker.autoReRequestInFlight.contains(prURL))
    }

    @Test
    func anEmptyPollDoesNotWipeTheRoundGuard() {
        // The auto-rebase lesson: pruning per-round state against a failed
        // fetch would let the next successful poll fire a duplicate request.
        let (tracker, _, _) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        let attemptedAfterDispatch = tracker.autoReRequestAttempted

        tracker.applyPRStatuses(viewerPRs: [])
        #expect(tracker.autoReRequestAttempted == attemptedAfterDispatch)
    }

    @Test
    func doesNotDispatchForAReviewSession() {
        let (tracker, _, _) = makeTracker(kind: .review)
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(tracker.autoReRequestInFlight.isEmpty)
    }

    // MARK: - Log volume

    @Test
    func steadyStateLinesAreEmittedOnceNotEveryPoll() {
        // A PR parked on a skip reason would otherwise emit a line every 60s
        // poll for as long as it stayed there — ~1440/day/PR, which buries the
        // signal the gated log exists to surface.
        let (tracker, _, _) = makeTracker(activityState: .working)
        let pr = fixedButUnrequestedPR()
        for _ in 0..<5 {
            tracker.applyPRStatuses(viewerPRs: [pr])
        }
        let reReviewKeys = tracker.steadyStateLogDedupe.keys.filter {
            $0.hasPrefix(IssueTracker.autoReReviewLogChannel)
        }
        // One retained entry for this PR — the dedupe key — not five lines.
        #expect(reReviewKeys.count == 1)
    }

    @Test
    func theTwoLogChannelsDoNotEvictEachOther() {
        // Both channels can describe the same PR in one poll. Keying on the
        // URL alone would let each overwrite the other's dedupe entry and
        // restore the every-poll flood for both.
        #expect(IssueTracker.steadyStateLogKey(
            channel: IssueTracker.needsRefineLogChannel, prURL: prURL)
            != IssueTracker.steadyStateLogKey(
                channel: IssueTracker.autoReReviewLogChannel, prURL: prURL))
    }

    @Test
    func steadyStateEntriesArePrunedWhenThePRGoesAway() {
        // Ephemeral state must stay bounded by current PR count rather than
        // by lifetime process activity.
        let (tracker, sessionID, state) = makeTracker(activityState: .working)
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(!tracker.steadyStateLogDedupe.isEmpty)

        state.links[sessionID] = []
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(tracker.steadyStateLogDedupe.isEmpty)
    }
}

/// CROW-921 — the gated-evaluation log. `applyPRStatuses` used to log only
/// when needs-refine *fired*, so a PR that sat in CHANGES_REQUESTED without
/// dispatching left no trace at all; diagnosing #921 meant reading raw
/// `crow get-state` output and hand-converting Apple reference dates.
@Suite("IssueTracker needs-refine gate reasons (CROW-921)")
struct NeedsRefineGateTests {
    private let reviewAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let beforeReview = Date(timeIntervalSince1970: 1_699_999_000)
    private let afterReview = Date(timeIntervalSince1970: 1_700_001_000)

    private func status(
        review: PRStatus.ReviewStatus = .changesRequested,
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil,
        hasPendingReviewRequest: Bool = false
    ) -> PRStatus {
        PRStatus(
            reviewStatus: review,
            isOpen: true,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt,
            hasPendingReviewRequest: hasPendingReviewRequest
        )
    }

    private func gate(
        _ status: PRStatus,
        toggleOn: Bool = true,
        isReviewSession: Bool = false,
        firstObservation: Bool = false,
        terminalIdle: Bool = true,
        cooldownElapsed: Bool = true
    ) -> IssueTracker.NeedsRefineGate? {
        IssueTracker.needsRefineGate(
            status: status,
            toggleOn: toggleOn,
            isReviewSession: isReviewSession,
            firstObservation: firstObservation,
            terminalIdle: terminalIdle,
            cooldownElapsed: cooldownElapsed
        )
    }

    @Test
    func firesWhenEveryGatePasses() {
        let s = status(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        #expect(gate(s) == nil)
    }

    @Test
    func namesEachSuppressionReason() {
        let stalled = status(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        #expect(gate(stalled, toggleOn: false) == .toggleOff)
        #expect(gate(stalled, isReviewSession: true) == .reviewSession)
        #expect(gate(stalled, firstObservation: true) == .firstObservation)
        #expect(gate(stalled, terminalIdle: false) == .agentBusy)
        #expect(gate(stalled, cooldownElapsed: false) == .cooldown)
        #expect(gate(status(review: .approved)) == .notChangesRequested)
        #expect(gate(status(lastChangesRequestedAt: nil)) == .notChangesRequested)
    }

    @Test
    func distinguishesTheTwoWaysAFixedPRIsQuiet() {
        // The distinction the ticket needed and the old log couldn't make:
        // "the fix landed and nobody has been asked to look" is a bug to act
        // on; "somebody is already looking" is healthy.
        #expect(gate(status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview)) == .awaitingReRequest)
        #expect(gate(status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview,
            hasPendingReviewRequest: true)) == .awaitingReviewer)
    }

    @Test
    func reasonsAreGrepStable() {
        // These land in crowd-automation.log and people search for them.
        #expect(IssueTracker.NeedsRefineGate.awaitingReRequest.rawValue == "awaiting-re-request")
        #expect(IssueTracker.NeedsRefineGate.awaitingReviewer.rawValue == "awaiting-reviewer")
        #expect(IssueTracker.NeedsRefineGate.agentBusy.rawValue == "agent-busy")
        #expect(IssueTracker.AutoReReviewSkipReason.noReviewers.rawValue
            == "no-changes-requested-reviewers")
        #expect(IssueTracker.AutoReReviewSkipReason.notAwaitingReRequest.rawValue
            == "not-awaiting-re-request")
    }
}
