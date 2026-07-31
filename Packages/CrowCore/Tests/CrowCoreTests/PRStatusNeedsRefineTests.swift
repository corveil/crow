import Foundation
import Testing
@testable import CrowCore

/// CROW-508 — stateless "needs refine" rule. The PR snapshot alone (plus the
/// terminal-idle flag) decides whether the agent owes a response to the
/// latest CHANGES_REQUESTED review. These tests pin every edge case of the
/// pure predicate so the regression surface is independent of the IssueTracker
/// wiring (cooldown, first-observation skip, opt-in toggle).
@Suite("PRStatus.needsRefine (CROW-508)")
struct PRStatusNeedsRefineTests {
    private let reviewAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let beforeReview = Date(timeIntervalSince1970: 1_699_999_000)
    private let afterReview = Date(timeIntervalSince1970: 1_700_001_000)

    private func status(
        review: PRStatus.ReviewStatus = .changesRequested,
        isOpen: Bool = true,
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil,
        changesRequestedReviewerIsPending: Bool = false
    ) -> PRStatus {
        PRStatus(
            checksPass: .pending,
            reviewStatus: review,
            mergeable: .unknown,
            failedCheckNames: [],
            headSha: "abc",
            isOpen: isOpen,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt,
            changesRequestedReviewerIsPending: changesRequestedReviewerIsPending
        )
    }

    // MARK: - Acceptance Test 1 — round-N stall

    @Test
    func firesWhenReviewIsNewerThanLastCommit() {
        // Reviewer left CHANGES_REQUESTED, agent committed BEFORE that review,
        // and the terminal is idle — the bug repro the ticket centers on.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: beforeReview
        )
        #expect(PRStatus.needsRefine(status: s, terminalIdle: true))
    }

    @Test
    func firesWhenChangesRequestedAndNoCommitsYet() {
        // First CHANGES_REQUESTED on a brand-new PR that has no qualifying
        // commits yet (or commit data not fetched). Treat "no commits" as
        // "no response since review" — the rule fires.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: nil
        )
        #expect(PRStatus.needsRefine(status: s, terminalIdle: true))
    }

    // MARK: - Acceptance Test 2 — merge-from-main doesn't reset

    @Test
    func mergeFromMainDoesNotResetTheRule() {
        // The "Update branch" button produces a merge commit that is filtered
        // out upstream (in parsePRNode) when computing lastSubstantiveCommitAt.
        // From the rule's perspective: lastSubstantiveCommitAt stays at the
        // pre-review commit (before the review), so needsRefine still fires.
        // This test pins the post-filter behavior: an OLD lastSubstantiveCommitAt
        // does not advance just because a merge commit was pushed.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: beforeReview  // upstream filter kept the old value
        )
        #expect(PRStatus.needsRefine(status: s, terminalIdle: true))
    }

    // MARK: - Acceptance Test 3 — real fix flips it

    @Test
    func doesNotFireWhenCommitIsNewerThanReview() {
        // Agent pushed a real (non-merge, non-rebase) commit after the
        // CHANGES_REQUESTED review. lastSubstantiveCommitAt advances past
        // lastChangesRequestedAt → rule stops firing. The anti-loop property
        // the head-SHA gate used to enforce, now derived from PR data alone.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview
        )
        #expect(!PRStatus.needsRefine(status: s, terminalIdle: true))
    }

    @Test
    func doesNotFireWhenCommitEqualsReviewTime() {
        // Edge: review and commit timestamps coincide (network jitter, GitHub
        // rounding). `<` not `<=` — commit at exactly review time counts as
        // "already responded", so the rule does NOT fire.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: reviewAt
        )
        #expect(!PRStatus.needsRefine(status: s, terminalIdle: true))
    }

    // MARK: - Gates: terminal, review state, isOpen, missing timestamp

    @Test
    func doesNotFireWhenTerminalNotIdle() {
        // Agent is mid-work — don't interrupt.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: beforeReview
        )
        #expect(!PRStatus.needsRefine(status: s, terminalIdle: false))
    }

    @Test
    func doesNotFireWhenReviewStatusIsNotChangesRequested() {
        // Reviewer already approved or hasn't reviewed yet — out of bucket.
        #expect(!PRStatus.needsRefine(
            status: status(review: .approved, lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview),
            terminalIdle: true
        ))
        #expect(!PRStatus.needsRefine(
            status: status(review: .reviewRequired, lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview),
            terminalIdle: true
        ))
    }

    @Test
    func doesNotFireWhenPRIsClosed() {
        // GitHub keeps `reviewDecision == CHANGES_REQUESTED` after a PR
        // merges or closes. The isOpen gate prevents re-prompting the agent
        // to "address review feedback" on a dead PR.
        let merged = status(
            isOpen: false,
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: beforeReview
        )
        #expect(!PRStatus.needsRefine(status: merged, terminalIdle: true))
    }

    @Test
    func doesNotFireWhenChangesRequestedTimestampMissing() {
        // GitHub says CHANGES_REQUESTED but didn't surface a timestamped CR
        // review (rare paging quirk). Without an anchor we can't decide
        // "since when", and a false fire is worse than a missed one.
        let s = status(
            lastChangesRequestedAt: nil,
            lastSubstantiveCommitAt: beforeReview
        )
        #expect(!PRStatus.needsRefine(status: s, terminalIdle: true))
    }

    // MARK: - CROW-921 — the re-requested-reviewer gate

    @Test
    func doesNotFireWhenTheBlockingReviewerHasBeenReRequested() {
        // The ball is back with the reviewer, so there is nothing for the
        // agent to do — even though no commit has landed since the review.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: beforeReview,
            changesRequestedReviewerIsPending: true
        )
        #expect(!PRStatus.needsRefine(status: s, terminalIdle: true))
        #expect(PRStatus.changesRequestedState(status: s) == .awaitingReviewer)
    }

    @Test
    func theReRequestedStateIsNamedEvenWithoutAChangesRequestedAnchor() {
        // The real GitHub shape for state 3: the re-request emptied
        // `latestReviews`, so there is no CR timestamp. The classifier must
        // still say `awaitingReviewer` rather than `notApplicable` — the
        // gated-evaluation log is only useful if it names the actual state.
        let s = status(
            lastChangesRequestedAt: nil,
            lastSubstantiveCommitAt: afterReview,
            changesRequestedReviewerIsPending: true
        )
        #expect(PRStatus.changesRequestedState(status: s) == .awaitingReviewer)
    }
}

/// CROW-921 (review of #930) — deriving "has a blocking reviewer been
/// re-requested?" from the two lists the host gives us.
///
/// The first cut of #930 keyed on `reviewRequests.totalCount > 0`, which counts
/// *every* pending request on the PR. Review requests are per-reviewer and the
/// host clears only the submitting reviewer's, so a PR routinely carries A's
/// CHANGES_REQUESTED verdict alongside B's still-pending original request —
/// and a PR-wide reading silenced both halves of the loop for exactly the
/// multi-reviewer PRs CROW-921 was meant to rescue.
@Suite("PRStatus.changesRequestedReviewerIsPending (CROW-921)")
struct ChangesRequestedReviewerIsPendingTests {
    private func derive(
        changesRequested: [String], pending: [String], anyPending: Bool? = nil
    ) -> Bool {
        PRStatus.changesRequestedReviewerIsPending(
            changesRequestedReviewers: changesRequested,
            pendingReviewers: pending,
            anyPendingRequest: anyPending ?? !pending.isEmpty
        )
    }

    @Test
    func anUnrelatedPendingReviewerDoesNotCountAsReRequested() {
        // THE REGRESSION. A requested changes and is still blocking; B was
        // asked at the same time and never looked. Under the old PR-wide
        // reading this returned true, which made `changesRequestedState` say
        // `.awaitingReviewer` — so the agent was never prompted to address A's
        // findings and nothing ever re-requested. The same permanent dead-end
        // CROW-921 exists to eliminate, and a regression against CROW-508.
        #expect(!derive(changesRequested: ["a"], pending: ["b"]))
    }

    @Test
    func aReRequestedBlockingReviewerCounts() {
        #expect(derive(changesRequested: ["a"], pending: ["a"]))
        // One of several is enough — that reviewer is looking again.
        #expect(derive(changesRequested: ["a", "c"], pending: ["b", "c"]))
    }

    @Test
    func aPendingRequestWithNoVisibleBlockerCounts() {
        // The live GitHub shape for state 3: the host hides a review as soon
        // as it re-requests the author, so the blocker disappears from
        // `latestReviews` at the same moment the request appears. Verified
        // against a real PR reading `CHANGES_REQUESTED` with `latestReviews:
        // []` and one pending request.
        #expect(derive(changesRequested: [], pending: ["a"]))
    }

    @Test
    func aPendingTeamRequestIsVisibleOnlyThroughTheCount() {
        // A Team request carries no login, so `pendingReviewers` is empty and
        // `anyPendingRequest` is the only evidence it exists. It must not be
        // folded into the login list: a team slug could collide with a user
        // login, and the intersection is against review *authors*, who are
        // always Users.
        #expect(derive(changesRequested: [], pending: [], anyPending: true))
        // But a team request still must not mask a visible blocker.
        #expect(!derive(changesRequested: ["a"], pending: [], anyPending: true))
    }

    @Test
    func nothingPendingIsNeverReRequested() {
        #expect(!derive(changesRequested: ["a"], pending: []))
        #expect(!derive(changesRequested: [], pending: []))
    }
}

/// CROW-921 — the three-state classifier `needsRefine` and the auto-re-request
/// watcher both derive from. The states must partition: exactly one applies to
/// any given PR, so the two actions can never both fire.
@Suite("PRStatus.changesRequestedState (CROW-921)")
struct PRStatusChangesRequestedStateTests {
    private let reviewAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let beforeReview = Date(timeIntervalSince1970: 1_699_999_000)
    private let afterReview = Date(timeIntervalSince1970: 1_700_001_000)

    private func status(
        review: PRStatus.ReviewStatus = .changesRequested,
        isOpen: Bool = true,
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil,
        changesRequestedReviewerIsPending: Bool = false
    ) -> PRStatus {
        PRStatus(
            reviewStatus: review,
            headSha: "abc",
            isOpen: isOpen,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt,
            changesRequestedReviewerIsPending: changesRequestedReviewerIsPending
        )
    }

    @Test
    func theFixedButUnrequestedPRIsTheStateThatWasMissing() {
        // The #921 dead-end itself: the fix landed after the review, and the
        // host cleared the review request when the reviewer submitted. Before
        // this state existed, nothing in Crow could see this PR.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: afterReview,
            changesRequestedReviewerIsPending: false
        )
        #expect(PRStatus.changesRequestedState(status: s) == .awaitingReRequest)
        #expect(!PRStatus.needsRefine(status: s, terminalIdle: true))
    }

    @Test
    func noWorkSinceTheReviewIsNeedsRefine() {
        let s = status(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        #expect(PRStatus.changesRequestedState(status: s) == .needsRefine)
    }

    @Test
    func noCommitsAtAllIsNeedsRefine() {
        let s = status(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: nil)
        #expect(PRStatus.changesRequestedState(status: s) == .needsRefine)
    }

    @Test
    func aCommitAtExactlyReviewTimeCountsAsResponded() {
        // `<` not `<=`, mirroring needsRefine — so the boundary lands in
        // `.awaitingReRequest`, not `.needsRefine`.
        let s = status(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: reviewAt)
        #expect(PRStatus.changesRequestedState(status: s) == .awaitingReRequest)
    }

    @Test
    func nonChangesRequestedAndClosedPRsAreNotApplicable() {
        #expect(PRStatus.changesRequestedState(
            status: status(review: .approved, lastChangesRequestedAt: reviewAt)) == .notApplicable)
        #expect(PRStatus.changesRequestedState(
            status: status(review: .reviewRequired, lastChangesRequestedAt: reviewAt)) == .notApplicable)
        #expect(PRStatus.changesRequestedState(
            status: status(isOpen: false, lastChangesRequestedAt: reviewAt)) == .notApplicable)
    }

    @Test
    func missingAnchorIsNotApplicableRatherThanAGuess() {
        // No CR timestamp and no pending request: we can't tell whether the
        // fix predates the review, so neither action may fire.
        let s = status(lastChangesRequestedAt: nil, lastSubstantiveCommitAt: afterReview)
        #expect(PRStatus.changesRequestedState(status: s) == .notApplicable)
    }

    @Test
    func needsRefineAgreesWithTheClassifierOverEveryInput() {
        // `needsRefine` is defined in terms of the classifier, so the contract
        // worth pinning is that the two never disagree — sweep the
        // cross-product of every input that feeds it. (The stronger
        // "needs-refine and re-request never both fire" invariant lives in
        // `IssueTrackerAutoReReviewTests`, where both gate functions are
        // visible; asserting it here could only compare a single enum value
        // against two cases, which is true of any implementation.)
        let dates: [Date?] = [nil, beforeReview, reviewAt, afterReview]
        var seenStates: Set<PRStatus.ChangesRequestedState> = []
        for reviewStatus in [PRStatus.ReviewStatus.changesRequested, .approved, .reviewRequired, .unknown] {
            for isOpen in [true, false] {
                for cr in dates {
                    for commit in dates {
                        for pending in [true, false] {
                            let s = status(
                                review: reviewStatus,
                                isOpen: isOpen,
                                lastChangesRequestedAt: cr,
                                lastSubstantiveCommitAt: commit,
                                changesRequestedReviewerIsPending: pending
                            )
                            let state = PRStatus.changesRequestedState(status: s)
                            seenStates.insert(state)
                            #expect(
                                PRStatus.needsRefine(status: s, terminalIdle: true)
                                    == (state == .needsRefine))
                            // The terminal gate is the only other input, and
                            // it can only ever suppress.
                            #expect(!PRStatus.needsRefine(status: s, terminalIdle: false))
                        }
                    }
                }
            }
        }
        // The sweep is only meaningful if it actually reached every state.
        #expect(seenStates == Set(
            [.notApplicable, .needsRefine, .awaitingReRequest, .awaitingReviewer]))
    }
}
