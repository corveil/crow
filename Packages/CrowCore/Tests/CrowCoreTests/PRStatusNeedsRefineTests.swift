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
        lastSubstantiveCommitAt: Date? = nil
    ) -> PRStatus {
        PRStatus(
            checksPass: .pending,
            reviewStatus: review,
            mergeable: .unknown,
            failedCheckNames: [],
            headSha: "abc",
            isOpen: isOpen,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt
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
}
