import Foundation
import Testing
import CrowCore
@testable import Crow

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
            url: "https://github.com/radiusmethod/crow/pull/42",
            state: state,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: "feature/x",
            headRefOid: "abc1234",
            baseRefName: "main",
            repoNameWithOwner: "radiusmethod/crow",
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

    // MARK: - Rejects

    @Test func rejectsCleanMergeablePR() {
        let pr = makePR(mergeable: "MERGEABLE", mergeStateStatus: "CLEAN")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func rejectsUnknownState() {
        let pr = makePR(mergeable: "UNKNOWN", mergeStateStatus: "UNKNOWN")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func rejectsDraft() {
        let pr = makePR(mergeStateStatus: "BEHIND", isDraft: true)
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func rejectsClosedPR() {
        let pr = makePR(state: "CLOSED", mergeStateStatus: "BEHIND")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
    }

    @Test func rejectsMergedPR() {
        let pr = makePR(state: "MERGED", mergeStateStatus: "BEHIND")
        #expect(!IssueTracker.shouldAttemptAutoRebase(pr: pr))
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
