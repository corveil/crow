import Foundation
import Testing
@testable import Crow

@Suite("IssueTracker stale-PR follow-up")
struct IssueTrackerStalePRTests {

    // MARK: - GitLab MR URL parsing

    @Test func parsesTopLevelGitLabMRURL() {
        let parsed = IssueTracker.parseGitLabMRURL(
            "https://repo1.dso.mil/big-bang/product/-/merge_requests/123"
        )
        #expect(parsed?.host == "repo1.dso.mil")
        #expect(parsed?.slug == "big-bang/product")
        #expect(parsed?.number == 123)
    }

    @Test func parsesNestedGroupGitLabMRURL() {
        // Regression guard for nested groups. The two-segment heuristic in
        // ProviderManager.parseTicketURLComponents would truncate this to
        // "big-bang/product" — the dedicated parser must keep the full path.
        let parsed = IssueTracker.parseGitLabMRURL(
            "https://repo1.dso.mil/big-bang/product/packages/elasticsearch-kibana/-/merge_requests/7"
        )
        #expect(parsed?.host == "repo1.dso.mil")
        #expect(parsed?.slug == "big-bang/product/packages/elasticsearch-kibana")
        #expect(parsed?.number == 7)
    }

    @Test func parsesGitLabComMRURL() {
        let parsed = IssueTracker.parseGitLabMRURL(
            "https://gitlab.com/foo/bar/-/merge_requests/42"
        )
        #expect(parsed?.host == "gitlab.com")
        #expect(parsed?.slug == "foo/bar")
        #expect(parsed?.number == 42)
    }

    @Test func rejectsGitHubPRURL() {
        // GitHub PR URLs lack `/-/merge_requests/`, so the GitLab parser
        // must return nil and let the caller fall through to the GitHub path.
        let parsed = IssueTracker.parseGitLabMRURL(
            "https://github.com/foo/bar/pull/9"
        )
        #expect(parsed == nil)
    }

    @Test func rejectsGitLabIssueURL() {
        // `/-/issues/` ≠ `/-/merge_requests/`. Issue URLs aren't in scope
        // for the stale-PR fetch.
        let parsed = IssueTracker.parseGitLabMRURL(
            "https://gitlab.com/foo/bar/-/issues/3"
        )
        #expect(parsed == nil)
    }

    @Test func rejectsMalformedURL() {
        #expect(IssueTracker.parseGitLabMRURL("not a url") == nil)
        #expect(IssueTracker.parseGitLabMRURL("https://gitlab.com/foo") == nil)
        #expect(IssueTracker.parseGitLabMRURL(
            "https://gitlab.com/foo/bar/-/merge_requests/notanumber"
        ) == nil)
    }

    // MARK: - GitLab state normalization

    @Test func normalizesOpenedToOPEN() {
        #expect(IssueTracker.normalizeGitLabPRState("opened") == "OPEN")
    }

    @Test func normalizesMergedToMERGED() {
        #expect(IssueTracker.normalizeGitLabPRState("merged") == "MERGED")
    }

    @Test func normalizesClosedToCLOSED() {
        #expect(IssueTracker.normalizeGitLabPRState("closed") == "CLOSED")
    }

    @Test func upcasesUnknownState() {
        #expect(IssueTracker.normalizeGitLabPRState("locked") == "LOCKED")
        #expect(IssueTracker.normalizeGitLabPRState("") == "")
    }

    // MARK: - GitLab MR JSON parsing

    @Test func parsesMergedMRResponse() {
        let json = """
        {
          "iid": 7,
          "web_url": "https://repo1.dso.mil/big-bang/product/-/merge_requests/7",
          "state": "merged",
          "source_branch": "feature/x",
          "target_branch": "master",
          "sha": "deadbeef",
          "draft": false
        }
        """
        let pr = IssueTracker.parseGitLabStaleMRResponse(
            json,
            fallbackURL: "https://repo1.dso.mil/big-bang/product/-/merge_requests/7",
            fallbackSlug: "big-bang/product"
        )
        #expect(pr?.number == 7)
        #expect(pr?.state == "MERGED")
        #expect(pr?.url == "https://repo1.dso.mil/big-bang/product/-/merge_requests/7")
        #expect(pr?.headRefName == "feature/x")
        #expect(pr?.baseRefName == "master")
        #expect(pr?.headRefOid == "deadbeef")
        #expect(pr?.repoNameWithOwner == "big-bang/product")
        #expect(pr?.isDraft == false)
    }

    @Test func parsesOpenedMRResponse() {
        let json = """
        {"iid": 12, "web_url": "https://gitlab.com/foo/bar/-/merge_requests/12", "state": "opened"}
        """
        let pr = IssueTracker.parseGitLabStaleMRResponse(
            json, fallbackURL: "fallback", fallbackSlug: "foo/bar"
        )
        #expect(pr?.state == "OPEN")
        #expect(pr?.number == 12)
    }

    @Test func parsesClosedMRResponse() {
        let json = """
        {"iid": 99, "web_url": "https://gitlab.com/foo/bar/-/merge_requests/99", "state": "closed"}
        """
        let pr = IssueTracker.parseGitLabStaleMRResponse(
            json, fallbackURL: "fallback", fallbackSlug: "foo/bar"
        )
        #expect(pr?.state == "CLOSED")
    }

    @Test func usesFallbackURLWhenWebUrlMissing() {
        // Defensive: if a future GitLab API change drops `web_url`, we still
        // produce a usable record using the URL we already had on hand.
        let json = """
        {"iid": 5, "state": "merged"}
        """
        let pr = IssueTracker.parseGitLabStaleMRResponse(
            json,
            fallbackURL: "https://gitlab.com/foo/bar/-/merge_requests/5",
            fallbackSlug: "foo/bar"
        )
        #expect(pr?.url == "https://gitlab.com/foo/bar/-/merge_requests/5")
        #expect(pr?.state == "MERGED")
    }

    @Test func returnsNilForMalformedJSON() {
        #expect(IssueTracker.parseGitLabStaleMRResponse(
            "not json",
            fallbackURL: "x",
            fallbackSlug: "y"
        ) == nil)
        // Missing the required `iid` field.
        #expect(IssueTracker.parseGitLabStaleMRResponse(
            #"{"state": "merged"}"#,
            fallbackURL: "x",
            fallbackSlug: "y"
        ) == nil)
    }

    @Test func acceptsLegacyWorkInProgressFlag() {
        // Older GitLab versions used `work_in_progress` instead of `draft`.
        let json = """
        {"iid": 1, "state": "opened", "work_in_progress": true}
        """
        let pr = IssueTracker.parseGitLabStaleMRResponse(
            json, fallbackURL: "x", fallbackSlug: "y"
        )
        #expect(pr?.isDraft == true)
    }

    // MARK: - Mixed-provider dedup integration

    @Test func dedupesGitHubAndGitLabPRsByURL() {
        // The orchestrator concats viewer (open) PRs with stale PRs from
        // both providers and runs the result through `dedupedByURL`. Verify
        // that a GitLab MR with the same URL appearing twice (once OPEN
        // from a prior reconcile, once MERGED from this cycle's stale fetch)
        // collapses with MERGED winning.
        let mrURL = "https://repo1.dso.mil/big-bang/product/-/merge_requests/7"
        let prURL = "https://github.com/radiusmethod/corveil/pull/201"
        let prs = [
            makeViewerPR(url: prURL, state: "OPEN"),
            makeViewerPR(url: mrURL, state: "OPEN"),
            makeViewerPR(url: prURL, state: "MERGED"),
            makeViewerPR(url: mrURL, state: "MERGED"),
        ]
        let result = IssueTracker.dedupedByURL(prs)
        #expect(result.count == 2)
        let byURL = Dictionary(uniqueKeysWithValues: result.map { ($0.url, $0) })
        #expect(byURL[prURL]?.state == "MERGED")
        #expect(byURL[mrURL]?.state == "MERGED")
    }

    // MARK: - helpers

    private func makeViewerPR(url: String, state: String, number: Int = 1) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: number,
            url: url,
            state: state,
            mergeable: "UNKNOWN",
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
}
