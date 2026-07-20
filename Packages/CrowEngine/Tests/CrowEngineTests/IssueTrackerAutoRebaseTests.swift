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

    // MARK: - Rejects

    @Test func rejectsCleanMergeablePR() {
        let pr = makePR(mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func rejectsUnknownState() {
        let pr = makePR(mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
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
}
