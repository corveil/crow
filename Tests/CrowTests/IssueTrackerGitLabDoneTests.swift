import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import Crow

/// CROW-697: GitLab closed issues must count toward `doneIssuesLast24h` for
/// throughput parity with GitHub/Jira. The backend's closed fetch + `X-Total`
/// window total are covered by `BackendsTests` in CrowProvider; these cover
/// IssueTracker's merge of a GitLab `AssignedListing` into the flat issue
/// list + the recently-done count.
@Suite("IssueTracker GitLab Done merge")
struct IssueTrackerGitLabDoneTests {

    private func issue(_ ref: String, number: Int, status: TicketStatus, state: String) -> AssignedIssue {
        AssignedIssue(
            id: "gitlab:gitlab.example.com:\(ref)",
            number: number,
            title: ref,
            state: state,
            url: "https://gitlab.example.com/g/p/-/issues/\(number)",
            repo: "g/p",
            provider: .gitlab,
            projectStatus: status
        )
    }

    @Test func closedIssuesContributeToDoneCount() {
        let listing = AssignedListing(
            open: [issue("g/p#7", number: 7, status: .unknown, state: "open")],
            closed: [
                issue("g/p#3", number: 3, status: .done, state: "closed"),
                issue("g/p#4", number: 4, status: .done, state: "closed"),
            ]
        )

        let merged = IssueTracker.mergeListing(listing)

        // Both closed issues land in the flat list so the board can group them.
        #expect(merged.issues.count == 3)
        #expect(merged.issues.filter { $0.projectStatus == .done }.map(\.id).sorted()
            == ["gitlab:gitlab.example.com:g/p#3", "gitlab:gitlab.example.com:g/p#4"])
        // N issues closed in the last 24h contribute N (mirrors GitHub semantics).
        #expect(merged.doneCount == 2)
    }

    @Test func dedupesClosedAgainstOpenButStillCountsTheWindow() {
        // An issue present in both halves (defensive: the open/closed queries
        // are disjoint by state, but mirror GitHub's id dedup).
        let listing = AssignedListing(
            open: [issue("g/p#7", number: 7, status: .unknown, state: "open")],
            closed: [issue("g/p#7", number: 7, status: .done, state: "closed")]
        )

        let merged = IssueTracker.mergeListing(listing)

        // Not double-counted in the issue list...
        #expect(merged.issues.count == 1)
        #expect(merged.issues[0].id == "gitlab:gitlab.example.com:g/p#7")
        // ...but the done window count still reflects the closed result.
        #expect(merged.doneCount == 1)
    }

    @Test func emptyListingContributesZero() {
        // A workspace whose GitLab fetch degraded to empty contributes 0,
        // no error — the no-backend / broken-glab path.
        let merged = IssueTracker.mergeListing(AssignedListing(open: [], closed: []))
        #expect(merged.issues.isEmpty)
        #expect(merged.doneCount == 0)
    }

    /// The badge must reflect the `X-Total` window total, not the length of
    /// the capped `per_page=50` page — 96 closed issues must badge as 96,
    /// mirroring GitHub's #562 / Jira's #572 cap fixes.
    @Test func doneCountUsesBackendTotalOverPageCount() {
        let listing = AssignedListing(
            open: [issue("g/p#7", number: 7, status: .unknown, state: "open")],
            closed: [
                issue("g/p#3", number: 3, status: .done, state: "closed"),
                issue("g/p#4", number: 4, status: .done, state: "closed"),
            ],
            closedTotalCount: 96
        )

        let merged = IssueTracker.mergeListing(listing)

        // The flat list still only carries the fetched page…
        #expect(merged.issues.count == 3)
        // …but the done window count is the header total, uncapped.
        #expect(merged.doneCount == 96)
    }
}
