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
        hasPendingReviewRequest: Bool = false
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
            hasPendingReviewRequest: hasPendingReviewRequest
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

    // MARK: - CROW-921 — the pending-request gate

    @Test
    func doesNotFireWhileAReviewRequestIsPending() {
        // Somebody has already been asked to look again, so the ball is with
        // the reviewer and there is nothing for the agent to do — even though
        // no commit has landed since the review. Unreachable on GitHub today
        // (it empties `latestReviews` when it re-requests, which nils the
        // anchor), but the rule shouldn't depend on that quirk holding.
        let s = status(
            lastChangesRequestedAt: reviewAt,
            lastSubstantiveCommitAt: beforeReview,
            hasPendingReviewRequest: true
        )
        #expect(!PRStatus.needsRefine(status: s, terminalIdle: true))
        #expect(PRStatus.changesRequestedState(status: s) == .awaitingReviewer)
    }

    @Test
    func pendingRequestIsNamedEvenWithoutAChangesRequestedAnchor() {
        // The real GitHub shape for state 3: the re-request emptied
        // `latestReviews`, so there is no CR timestamp. The classifier must
        // still say `awaitingReviewer` rather than `notApplicable` — the
        // gated-evaluation log is only useful if it names the actual state.
        let s = status(
            lastChangesRequestedAt: nil,
            lastSubstantiveCommitAt: afterReview,
            hasPendingReviewRequest: true
        )
        #expect(PRStatus.changesRequestedState(status: s) == .awaitingReviewer)
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
        hasPendingReviewRequest: Bool = false
    ) -> PRStatus {
        PRStatus(
            reviewStatus: review,
            headSha: "abc",
            isOpen: isOpen,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt,
            hasPendingReviewRequest: hasPendingReviewRequest
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
            hasPendingReviewRequest: false
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
    func statesPartitionSoTheTwoActionsCanNeverBothFire() {
        // The invariant the whole design rests on. Sweep the cross-product of
        // every input that feeds the classifier and assert that needs-refine
        // and awaiting-re-request are never simultaneously true.
        let dates: [Date?] = [nil, beforeReview, reviewAt, afterReview]
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
                                hasPendingReviewRequest: pending
                            )
                            let state = PRStatus.changesRequestedState(status: s)
                            #expect(
                                PRStatus.needsRefine(status: s, terminalIdle: true)
                                    == (state == .needsRefine))
                            #expect(!(state == .needsRefine && state == .awaitingReRequest))
                        }
                    }
                }
            }
        }
    }
}
