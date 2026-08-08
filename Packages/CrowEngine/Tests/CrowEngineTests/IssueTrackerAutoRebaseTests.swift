import Foundation
import Testing
import CrowCore
@testable import CrowEngine

@Suite("IssueTracker auto-rebase watcher (no label required)")
struct IssueTrackerAutoRebaseTests {

    // MARK: - Fixtures

    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "0E8A16")
    private static let otherLabel = LabelInfo(name: "documentation", color: "ffffff")

    private func makePR(
        state: String = "OPEN",
        mergeable: String = "MERGEABLE",
        mergeStateStatus: String = "BEHIND",
        reviewDecision: String = "REVIEW_REQUIRED",
        isDraft: Bool = false,
        labels: [LabelInfo] = []
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: 42,
            url: "https://github.com/corveil/crow/pull/42",
            state: state,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: "feature/x",
            headRefOid: "abc1234",
            baseRefName: "main",
            repoNameWithOwner: "corveil/crow",
            labels: labels,
            linkedIssueReferences: [],
            checksState: "SUCCESS",
            failedCheckNames: [],
            latestReviewStates: []
        )
    }

    // MARK: - Accepts

    @Test func acceptsBehindBase() {
        let pr = makePR(mergeable: "MERGEABLE", mergeStateStatus: "BEHIND")
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func acceptsConflicting() {
        let pr = makePR(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY")
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    /// The defining difference from auto-merge: no `crow:merge` label needed.
    @Test func acceptsBehindWithoutCrowMergeLabel() {
        let pr = makePR(mergeStateStatus: "BEHIND", labels: [Self.otherLabel])
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func acceptsBehindWithNoLabelsAtAll() {
        let pr = makePR(mergeStateStatus: "BEHIND", labels: [])
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    /// A rebase doesn't require approval, so review state is irrelevant.
    @Test func acceptsRegardlessOfReviewDecision() {
        let pr = makePR(mergeStateStatus: "BEHIND", reviewDecision: "CHANGES_REQUESTED")
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    /// Draft-ness is irrelevant to a rebase (CROW-577): the operation only
    /// rewrites the session's own branch, it never merges. A draft that has
    /// fallen behind base is exactly the case the watcher should handle.
    @Test func acceptsDraftBehindBase() {
        let pr = makePR(mergeStateStatus: "BEHIND", isDraft: true)
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func acceptsDraftConflicting() {
        let pr = makePR(mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", isDraft: true)
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    // MARK: - The masked-behind shapes (#944)
    //
    // `mergeStateStatus` is GitHub's SINGLE-VALUED summary of why the merge
    // button isn't green — the highest-priority reason, not a set of flags. A
    // PR that is behind base *and* anything else reports the other value, so
    // keying on `== "BEHIND"` was blind to every row below. These are now
    // candidates, and git decides whether they actually need a rebase.

    /// The expensive one, and the reason #944 exists: BLOCKED is the *normal*
    /// state of a PR waiting on its reviewer, which is exactly the window in
    /// which a busy base drifts ahead.
    @Test func acceptsBlockedWhichMasksBehind() {
        let pr = makePR(mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED")
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    /// A draft's `mergeStateStatus` is *always* DRAFT, so behind-ness was
    /// masked permanently — drafts are where long-lived Crow branches rot.
    /// They stay eligible: see `draftEligibleForRebaseIsStillExcludedFromMergePath`
    /// for the guarantee that this can never merge one.
    @Test func acceptsDraftStateWhichMasksBehind() {
        let pr = makePR(mergeable: "MERGEABLE", mergeStateStatus: "DRAFT", isDraft: true)
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func acceptsDirtyEvenWithoutTheConflictingFlag() {
        // DIRTY without `mergeable == "CONFLICTING"` used to fall through the
        // old predicate entirely — it matched neither disjunct.
        let pr = makePR(mergeable: "UNKNOWN", mergeStateStatus: "DIRTY")
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func acceptsUnstableAndHasHooks() {
        // Not usually behind, but cheap to check and correct to consider —
        // the git probe makes each one a single fetch per head state.
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: makePR(mergeStateStatus: "UNSTABLE")))
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: makePR(mergeStateStatus: "HAS_HOOKS")))
    }

    // MARK: - Rejects

    @Test func rejectsCleanMergeablePR() {
        let pr = makePR(mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    /// CLEAN is now the *only* thing that disqualifies an open PR. Pinned
    /// separately so a future narrowing of the filter has to argue with a test.
    @Test func cleanIsTheOnlyDisqualifyingStateForAnOpenPR() {
        let states = ["BEHIND", "BLOCKED", "DIRTY", "DRAFT", "UNKNOWN", "UNSTABLE", "HAS_HOOKS"]
        for state in states {
            #expect(IssueTracker.shouldAttemptAutoRebase(pr: makePR(mergeStateStatus: state)),
                    "\(state) should be a candidate")
        }
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: makePR(mergeStateStatus: "CLEAN")))
    }

    /// INVERTED by #944. This used to assert that UNKNOWN was rejected, which
    /// was the bug: GitHub reports UNKNOWN for a few seconds after every push
    /// while it recomputes mergeability, and a base that moved during that
    /// window left the PR permanently skipped for that head. Kept rather than
    /// deleted because it encodes a decision someone will otherwise
    /// re-litigate — the cost is one `git fetch` per push per PR.
    @Test func acceptsUnknownStateSoAMidRecomputePRIsNotSkipped() {
        let pr = makePR(mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN")
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    /// Regression (CROW-577): a draft that qualifies for auto-rebase must
    /// still be excluded from the auto-merge path — `shouldAttemptAutoMerge`
    /// keeps its own draft guard, so `shouldUpdateBranchBeforeMerge` stays
    /// false and `applyAutoRebase`'s precedence branch can't hand a draft to
    /// auto-merge. The `crow:merge` label is present so draft-ness is the
    /// only thing blocking the merge path.
    @Test func draftEligibleForRebaseIsStillExcludedFromMergePath() {
        let pr = makePR(mergeStateStatus: "BEHIND", isDraft: true, labels: [Self.crowMergeLabel])
        let session = Session(name: "feature-crow-42", kind: .work)
        #expect(IssueTracker.shouldAttemptAutoRebase(pr: pr))
        #expect(!IssueTracker.shouldAttemptAutoMerge(pr: pr, session: session))
        #expect(!IssueTracker.shouldUpdateBranchBeforeMerge(pr: pr, session: session))
    }

    @Test func rejectsClosedPR() {
        let pr = makePR(state: "CLOSED", mergeStateStatus: "BEHIND")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func rejectsMergedPR() {
        let pr = makePR(state: "MERGED", mergeStateStatus: "BEHIND")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    // MARK: - Session eligibility (CROW-551)

    /// Review sessions must never be auto-rebased: Crow would be force-pushing
    /// over someone else's PR under review. Policy gate independent of the
    /// `autoRebaseAndResolveConflicts` toggle, mirroring
    /// `AutoRespondCoordinator.shouldSkipReviewSession`.
    @Test func excludesReviewSessions() {
        let review = Session(name: "review-crow-42", kind: .review)
        #expect(!IssueTracker.sessionEligibleForAutoRebase(review))
    }

    @Test func allowsWorkSessions() {
        let work = Session(name: "feature-crow-42", kind: .work)
        #expect(IssueTracker.sessionEligibleForAutoRebase(work))
    }

    @Test func excludesManagerSession() {
        let manager = Session(id: AppState.managerSessionID, name: "Manager", kind: .manager)
        #expect(!IssueTracker.sessionEligibleForAutoRebase(manager))
    }

    // MARK: - Failed-rebase retry policy

    @Test func retriesFailuresUnderTheCap() {
        #expect(IssueTracker.shouldRetryFailedRebase(failureCount: 1))
        #expect(IssueTracker.shouldRetryFailedRebase(failureCount: 2))
    }

    @Test func stopsRetryingAtTheCap() {
        #expect(IssueTracker.maxAutoRebaseFailureRetries == 3)
        #expect(!IssueTracker.shouldRetryFailedRebase(failureCount: 3))
        #expect(!IssueTracker.shouldRetryFailedRebase(failureCount: 4))
    }

    // MARK: - Deferral backoff (#889)

    @Test func firstDeferralRetriesOnTheNextPoll() {
        // The common transient case (agent mid-edit) must still recover
        // promptly — one poll interval, not a long backoff.
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: 1)
            == IssueTracker.autoRebaseDeferralBaseDelay)
    }

    @Test func backoffDoublesPerConsecutiveDeferral() {
        let base = IssueTracker.autoRebaseDeferralBaseDelay
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: 2) == base * 2)
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: 3) == base * 4)
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: 4) == base * 8)
    }

    @Test func backoffIsMonotonicAndSaturatesAtTheCap() {
        let cap = IssueTracker.autoRebaseDeferralMaxDelay
        var previous: TimeInterval = 0
        for count in 1...64 {
            let delay = IssueTracker.autoRebaseDeferralBackoff(deferralCount: count)
            #expect(delay >= previous)
            #expect(delay <= cap)
            previous = delay
        }
        // Saturated, and stable well past the cap — no overflow to 0 or inf
        // from the repeated doubling.
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: 64) == cap)
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: 100_000) == cap)
    }

    @Test func backoffHandlesNonPositiveCountsDefensively() {
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: 0)
            == IssueTracker.autoRebaseDeferralBaseDelay)
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: -1)
            == IssueTracker.autoRebaseDeferralBaseDelay)
    }

    // MARK: - Deferral reasons

    /// These land verbatim in `crowd-automation.log` as `deferred:<raw>`;
    /// changing one breaks anyone grepping the log for a stuck branch.
    @Test func deferReasonRawValuesAreStableForGrepping() {
        #expect(IssueTracker.AutoRebaseDeferReason.dirtyWorktree.rawValue == "dirty-worktree")
        #expect(IssueTracker.AutoRebaseDeferReason.outOfSyncAhead.rawValue == "out-of-sync-ahead")
        #expect(IssueTracker.AutoRebaseDeferReason.outOfSyncDiverged.rawValue == "out-of-sync-diverged")
        // The one new token (#944) — a give-up isn't a deferral, so it lives on
        // the verdict rather than in `AutoRebaseDeferReason`.
        #expect(IssueTracker.AutoRebaseVerdict.gaveUp(attempts: 3, error: "x").reason
                == "rebase-failed")
    }

    // MARK: - Deferral escalation (#944)

    /// The threshold is not a free parameter: it is the first count whose
    /// backoff has SATURATED. Below it Crow is genuinely "waiting a bit
    /// longer"; from here on it asks the same question every 15 minutes and
    /// gets the same answer, which is the state that used to be invisible.
    /// This pins the two together so moving one without the other fails.
    @Test func escalationThresholdIsWhereTheBackoffSaturates() {
        let threshold = IssueTracker.autoRebaseStuckDeferralThreshold
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: threshold)
                == IssueTracker.autoRebaseDeferralMaxDelay)
        // ...and it is the FIRST such count, not merely one of them.
        #expect(IssueTracker.autoRebaseDeferralBackoff(deferralCount: threshold - 1)
                < IssueTracker.autoRebaseDeferralMaxDelay)
    }

    @Test func escalatesOnlyAtOrPastTheThreshold() {
        let threshold = IssueTracker.autoRebaseStuckDeferralThreshold
        for count in 1..<threshold {
            #expect(!IssueTracker.shouldEscalateDeferral(deferralCount: count))
        }
        #expect(IssueTracker.shouldEscalateDeferral(deferralCount: threshold))
        // Escalation is a notification, not a give-up — it stays true forever
        // so the `.blocked` chip persists while Crow keeps retrying.
        #expect(IssueTracker.shouldEscalateDeferral(deferralCount: threshold + 100))
    }

    // MARK: - Published verdicts (#944)

    /// The invariant the whole publish path leans on: `blocked` ⟺ `permanent`
    /// ⟺ "fires `onAutoRebaseStuck`". `publishAutoRebaseVerdict` notifies on
    /// `phase == .blocked`, so a verdict that disagreed with itself would
    /// either chime for a transient wait or stay silent on a real wedge.
    @Test func permanentAgreesWithBlockedForEveryVerdict() {
        var verdicts: [IssueTracker.AutoRebaseVerdict] = [.gaveUp(attempts: 3, error: "boom")]
        for reason in [IssueTracker.AutoRebaseDeferReason.dirtyWorktree,
                       .outOfSyncAhead, .outOfSyncDiverged] {
            verdicts.append(.deferred(reason, count: 1))
            verdicts.append(.deferred(reason, count: IssueTracker.autoRebaseStuckDeferralThreshold))
        }
        for verdict in verdicts {
            let state = verdict.state
            #expect(state.permanent == (state.phase == .blocked))
            // Every verdict carries a renderable sentence and the log's token.
            #expect(!state.message.isEmpty)
            #expect(state.reason == verdict.reason)
        }
    }

    @Test func deferredVerdictEscalatesFromStalledToBlocked() {
        let reason = IssueTracker.AutoRebaseDeferReason.outOfSyncDiverged
        #expect(IssueTracker.AutoRebaseVerdict.deferred(reason, count: 1).state.phase == .stalled)
        let stuck = IssueTracker.AutoRebaseVerdict.deferred(
            reason, count: IssueTracker.autoRebaseStuckDeferralThreshold).state
        #expect(stuck.phase == .blocked)
        // The blocked sentence must tell a human what to do, not just that
        // Crow is unhappy — this is the only surface the state has.
        #expect(stuck.message.contains("Reconcile"))
    }

    /// Git's stderr goes into the chip tooltip and the notification body, so an
    /// unbounded one blows out both.
    @Test func gaveUpVerdictTruncatesGitError() {
        let long = String(repeating: "x", count: 5_000)
        let state = IssueTracker.AutoRebaseVerdict.gaveUp(attempts: 3, error: long).state
        #expect(state.message.count < 400)
        #expect(state.phase == .blocked)
    }

    // MARK: - update-branch retry policy (#944)

    /// A failed `gh pr update-branch` leaves `headRefOid` unchanged, so the
    /// per-head guard's "retry once the branch moves" was a deadlock: the
    /// branch is precisely what didn't move.
    @Test func failedUpdateBranchRetriesUpToTheCap() {
        #expect(IssueTracker.maxAutoUpdateBranchFailureRetries == 3)
        #expect(IssueTracker.shouldRetryFailedUpdateBranch(failureCount: 1))
        #expect(IssueTracker.shouldRetryFailedUpdateBranch(failureCount: 2))
        #expect(!IssueTracker.shouldRetryFailedUpdateBranch(failureCount: 3))
        #expect(!IssueTracker.shouldRetryFailedUpdateBranch(failureCount: 99))
    }
}
