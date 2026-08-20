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
        changesRequestedReviewerIsPending: Bool = false
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
            // "The blocking reviewer has been re-requested" as the host would
            // actually present it: the same people appear in the pending list.
            // Fixtures that need the *unrelated* pending reviewer shape build
            // a `PRRecord` directly — see the multi-reviewer tests below.
            pendingReviewerLogins: changesRequestedReviewerIsPending ? reviewers : [],
            hasPendingReviewRequest: changesRequestedReviewerIsPending
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
            changesRequestedReviewerIsPending: true
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
    /// is `.jira` on purpose: it has no `CodeBackend`, so even if the
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
        session.provider = .jira
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

    @Test
    func failureCountsArePrunedWithTheRoundKeys() {
        // Same boundedness requirement as the round-key set they shadow.
        let (tracker, _, _) = makeTracker()
        let staleKey = IssueTracker.autoReReviewRoundKey(
            url: "https://github.com/foo/bar/pull/1", headRefOid: shaA, lastChangesRequestedAt: reviewAt)
        tracker.autoReReviewFailureCounts[staleKey] = 2
        tracker.applyPRStatuses(viewerPRs: [fixedButUnrequestedPR()])
        #expect(tracker.autoReReviewFailureCounts[staleKey] == nil)
    }

    // MARK: - Failure path

    @Test
    func aPermanentlyUnservableSessionIsNotRetriedEveryPoll() async {
        // The session's provider (`.jira`) has no `CodeBackend`, which is a
        // property of the session and cannot change under a live round. The
        // first cut cleared the round key here, so the watcher re-dispatched
        // every 60s poll for the life of the PR and emitted two un-deduped log
        // lines each time (review of #930). It must latch instead.
        let (tracker, _, _) = makeTracker()
        let pr = fixedButUnrequestedPR()
        tracker.applyPRStatuses(viewerPRs: [pr])
        let roundKey = IssueTracker.autoReReviewRoundKey(
            url: prURL, headRefOid: pr.headRefOid, lastChangesRequestedAt: pr.lastChangesRequestedAt)
        #expect(tracker.autoReRequestAttempted.contains(roundKey))

        // Let the dispatched attempt run to completion.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        // In-flight released so a real retry could happen, but the round key
        // stays latched so no further poll re-dispatches.
        #expect(!tracker.autoReRequestInFlight.contains(prURL))
        #expect(tracker.autoReRequestAttempted.contains(roundKey))

        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(!tracker.autoReRequestInFlight.contains(prURL))
    }

    @Test
    func theRetryBudgetIsBounded() {
        // The inputs to a re-request are fixed for the life of a round — same
        // PR, same logins — so a failure that isn't transient never stops
        // being one. Three attempts, then the round is latched until a new
        // push or a new reviewer submission re-arms it.
        #expect(IssueTracker.maxAutoReReviewFailureRetries == 3)
    }

    // MARK: - The invariant the design rests on

    @Test
    func theTwoActionsNeverBothFireForTheSamePR() {
        // Prompting the agent and pinging the reviewer are mutually exclusive
        // responses to the same PR, and nothing in the type system enforces
        // it — the guarantee comes from both gates deriving from one
        // classifier. Sweep the cross-product of every input either gate
        // reads and assert they never both return "go".
        //
        // (Asserting this in CrowCore is impossible: only the classifier's
        // single enum value is in scope there, so any such check is a
        // tautology. Both gate functions are visible here.)
        let dates: [Date?] = [nil, beforeReview, reviewAt, afterReview]
        var bothQuiet = 0, refineFired = 0, reRequestFired = 0
        for reviewDecision in ["CHANGES_REQUESTED", "APPROVED", "REVIEW_REQUIRED", ""] {
            for prState in ["OPEN", "MERGED"] {
                for isDraft in [true, false] {
                    for cr in dates {
                        for commit in dates {
                            for reviewerPending in [true, false] {
                                for reviewers in [["dgershman"], []] {
                                    for settled in [true, false] {
                                        let pr = makePR(
                                            reviewDecision: reviewDecision,
                                            state: prState,
                                            isDraft: isDraft,
                                            lastChangesRequestedAt: cr,
                                            lastSubstantiveCommitAt: commit,
                                            reviewers: reviewers,
                                            changesRequestedReviewerIsPending: reviewerPending)
                                        let status = IssueTracker.buildPRStatus(from: pr)
                                        let refineGoes = IssueTracker.needsRefineGate(
                                            status: status,
                                            toggleOn: true,
                                            isReviewSession: false,
                                            firstObservation: false,
                                            terminalIdle: settled,
                                            cooldownElapsed: true) == nil
                                        let reRequestGoes = IssueTracker.autoReReviewSkipReason(
                                            pr: pr,
                                            status: status,
                                            isReviewSession: false,
                                            agentSettled: settled) == nil
                                        #expect(!(refineGoes && reRequestGoes))
                                        if refineGoes { refineFired += 1 }
                                        else if reRequestGoes { reRequestFired += 1 }
                                        else { bothQuiet += 1 }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        // A sweep where neither gate ever opens would satisfy the invariant
        // vacuously; assert both arms are genuinely exercised.
        #expect(refineFired > 0)
        #expect(reRequestFired > 0)
        #expect(bothQuiet > 0)
    }

    // MARK: - CROW-921 review of #930 — the multi-reviewer regression

    @Test
    func anUnrelatedPendingReviewerDoesNotSilenceTheLoop() {
        // A requested changes and is still blocking; B was asked at the same
        // time and never looked, so B's request is still pending. Keying the
        // state on "does the PR have any pending request" read that as "the
        // ball is with the reviewer" and went quiet on both halves — the same
        // permanent dead-end CROW-921 exists to close, and a regression
        // against shipped CROW-508 behaviour.
        //
        // Driven from the raw provider fields through `buildPRStatus` so the
        // derivation is exercised end to end, not just the classifier.
        let pr = PRRecord(
            number: 1898,
            url: prURL,
            state: "OPEN",
            reviewDecision: "CHANGES_REQUESTED",
            headRefOid: shaA,
            latestReviewStates: ["CHANGES_REQUESTED"],
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: beforeReview,   // A's findings unaddressed
            changesRequestedReviewerLogins: ["a"],   // A blocks and is visible
            pendingReviewerLogins: ["b"],            // B was never cleared
            hasPendingReviewRequest: true
        )
        let status = IssueTracker.buildPRStatus(from: pr)

        #expect(!status.changesRequestedReviewerIsPending)
        #expect(PRStatus.changesRequestedState(status: status) == .needsRefine)
        #expect(PRStatus.needsRefine(status: status, terminalIdle: true))
    }

    @Test
    func aReRequestedBlockerStillReadsAsAwaitingReviewer() {
        // The other side of the same fix: once A is re-requested the host
        // hides A's review, so the blocker list empties while the request
        // appears. That must still be `.awaitingReviewer` — otherwise the
        // watcher would re-request a reviewer who is already looking.
        let pr = PRRecord(
            number: 1898,
            url: prURL,
            state: "OPEN",
            reviewDecision: "CHANGES_REQUESTED",
            headRefOid: shaA,
            lastChangesRequestedAt: nil,             // anchor gone with the review
            lastSubstantiveCommitAt: afterReview,
            changesRequestedReviewerLogins: [],
            pendingReviewerLogins: ["a"],
            hasPendingReviewRequest: true
        )
        let status = IssueTracker.buildPRStatus(from: pr)

        #expect(status.changesRequestedReviewerIsPending)
        #expect(PRStatus.changesRequestedState(status: status) == .awaitingReviewer)
        #expect(!PRStatus.needsRefine(status: status, terminalIdle: true))
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
        changesRequestedReviewerIsPending: Bool = false
    ) -> PRStatus {
        PRStatus(
            reviewStatus: review,
            isOpen: true,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt,
            changesRequestedReviewerIsPending: changesRequestedReviewerIsPending
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
            changesRequestedReviewerIsPending: true)) == .awaitingReviewer)
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
