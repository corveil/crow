import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import Crow

@Suite("IssueTracker PR dedup")
struct IssueTrackerDedupTests {

    private func makeViewerPR(
        url: String,
        state: String,
        number: Int = 1,
        mergeable: String = "UNKNOWN",
        mergeStateStatus: String = "UNKNOWN",
        reviewDecision: String = "",
        isDraft: Bool = false,
        headRefName: String = "",
        headRefOid: String = "",
        baseRefName: String = "",
        repoNameWithOwner: String = "",
        labels: [LabelInfo] = [],
        linkedIssueReferences: [LinkedIssueRef] = [],
        checksState: String = "",
        failedCheckNames: [String] = [],
        latestReviewStates: [String] = [],
        lastChangesRequestedAt: Date? = nil,
        lastSubstantiveCommitAt: Date? = nil
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: number,
            url: url,
            state: state,
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision,
            isDraft: isDraft,
            headRefName: headRefName,
            headRefOid: headRefOid,
            baseRefName: baseRefName,
            repoNameWithOwner: repoNameWithOwner,
            labels: labels,
            linkedIssueReferences: linkedIssueReferences,
            checksState: checksState,
            failedCheckNames: failedCheckNames,
            latestReviewStates: latestReviewStates,
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt
        )
    }

    @Test func collapsesExactDuplicates() {
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let prs = [
            makeViewerPR(url: url, state: "OPEN"),
            makeViewerPR(url: url, state: "OPEN"),
        ]
        let deduped = IssueTracker.dedupedByURL(prs)
        #expect(deduped.count == 1)
        #expect(deduped[0].url == url)
    }

    @Test func mergedBeatsOpenRegardlessOfOrder() {
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let open = makeViewerPR(url: url, state: "OPEN")
        let merged = makeViewerPR(url: url, state: "MERGED")

        let openFirst = IssueTracker.dedupedByURL([open, merged])
        let mergedFirst = IssueTracker.dedupedByURL([merged, open])

        #expect(openFirst.count == 1)
        #expect(openFirst[0].state == "MERGED")
        #expect(mergedFirst.count == 1)
        #expect(mergedFirst[0].state == "MERGED")
    }

    @Test func mergedWinnerBackfillsEmptyFieldsFromOpenLoser() {
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let open = makeViewerPR(
            url: url,
            state: "OPEN",
            reviewDecision: "APPROVED",
            headRefName: "feature/x",
            baseRefName: "main",
            repoNameWithOwner: "radiusmethod/corveil",
            checksState: "SUCCESS",
            failedCheckNames: ["noop"],
            latestReviewStates: ["APPROVED"]
        )
        let merged = makeViewerPR(url: url, state: "MERGED")

        let result = IssueTracker.dedupedByURL([open, merged])
        #expect(result.count == 1)
        let pr = result[0]
        #expect(pr.state == "MERGED")
        #expect(pr.reviewDecision == "APPROVED")
        #expect(pr.headRefName == "feature/x")
        #expect(pr.baseRefName == "main")
        #expect(pr.repoNameWithOwner == "radiusmethod/corveil")
        #expect(pr.checksState == "SUCCESS")
        #expect(pr.failedCheckNames == ["noop"])
        #expect(pr.latestReviewStates == ["APPROVED"])
    }

    @Test func mergedWinsThreeWay() {
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let prs = [
            makeViewerPR(url: url, state: "OPEN"),
            makeViewerPR(url: url, state: "CLOSED"),
            makeViewerPR(url: url, state: "MERGED"),
        ]
        let result = IssueTracker.dedupedByURL(prs)
        #expect(result.count == 1)
        #expect(result[0].state == "MERGED")
    }

    @Test func preservesFirstSeenOrderAcrossDistinctURLs() {
        let a = makeViewerPR(url: "https://example/a", state: "OPEN", number: 1)
        let b = makeViewerPR(url: "https://example/b", state: "OPEN", number: 2)
        let c = makeViewerPR(url: "https://example/c", state: "OPEN", number: 3)

        let result = IssueTracker.dedupedByURL([a, b, c])
        #expect(result.map(\.url) == ["https://example/a", "https://example/b", "https://example/c"])
    }

    @Test func dictionaryUniquingWithMergeRecordsDoesNotTrap() {
        // Guard for the belt-and-suspenders call sites at
        // applyPRStatuses / autoCompleteFinishedSessions. If a future
        // refactor regresses dedup at the assembly site, these call sites
        // must still tolerate duplicates instead of trapping.
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let prs = [
            makeViewerPR(url: url, state: "OPEN"),
            makeViewerPR(url: url, state: "MERGED"),
        ]
        let byURL = Dictionary(
            prs.map { ($0.url, $0) },
            uniquingKeysWith: IssueTracker.mergePRRecords
        )
        #expect(byURL.count == 1)
        #expect(byURL[url]?.state == "MERGED")
    }

    // MARK: - CROW-508 timestamp propagation

    @Test func mergePRRecordsPrefersWinnerLastChangesRequestedAt() {
        // Winner is whichever has the higher-rank state (MERGED beats OPEN).
        // Forward its lastChangesRequestedAt; fall back to loser's only when
        // winner's is nil so the stateless "needs refine" rule never loses
        // the anchor timestamp during merge.
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let openTs = Date(timeIntervalSince1970: 1_700_000_000)
        let mergedTs = Date(timeIntervalSince1970: 1_700_001_000)
        let open = makeViewerPR(url: url, state: "OPEN", lastChangesRequestedAt: openTs)
        let merged = makeViewerPR(url: url, state: "MERGED", lastChangesRequestedAt: mergedTs)
        #expect(IssueTracker.mergePRRecords(open, merged).lastChangesRequestedAt == mergedTs)
        #expect(IssueTracker.mergePRRecords(merged, open).lastChangesRequestedAt == mergedTs)
    }

    @Test func mergePRRecordsBackfillsLastChangesRequestedAtWhenWinnerLacks() {
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let openTs = Date(timeIntervalSince1970: 1_700_000_000)
        let open = makeViewerPR(url: url, state: "OPEN", lastChangesRequestedAt: openTs)
        let mergedNoTs = makeViewerPR(url: url, state: "MERGED")
        #expect(IssueTracker.mergePRRecords(open, mergedNoTs).lastChangesRequestedAt == openTs)
    }

    @Test func mergePRRecordsBackfillsLastSubstantiveCommitAtWhenWinnerLacks() {
        let url = "https://github.com/radiusmethod/corveil/pull/201"
        let openTs = Date(timeIntervalSince1970: 1_700_000_000)
        let open = makeViewerPR(url: url, state: "OPEN", lastSubstantiveCommitAt: openTs)
        let mergedNoTs = makeViewerPR(url: url, state: "MERGED")
        #expect(IssueTracker.mergePRRecords(open, mergedNoTs).lastSubstantiveCommitAt == openTs)
    }
}
