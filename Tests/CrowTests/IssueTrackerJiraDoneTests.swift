import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import Crow

/// CROW-536: Jira tickets in their mapped Done status must reach the board's
/// Done section. The mapping itself (status name → `.done`) is covered by
/// `JiraTaskBackendTests`; these cover IssueTracker's merge of a Jira
/// `AssignedListing` into the flat issue list + the recently-Done count.
@Suite("IssueTracker Jira Done merge")
struct IssueTrackerJiraDoneTests {

    private func issue(_ key: String, status: TicketStatus, state: String) -> AssignedIssue {
        AssignedIssue(
            id: "jira:\(key)",
            number: 1,
            title: key,
            state: state,
            url: "https://acme.atlassian.net/browse/\(key)",
            repo: "PROJ",
            provider: .jira,
            projectStatus: status
        )
    }

    @Test func includesClosedDoneIssuesAndCountsTheWindow() {
        let listing = AssignedListing(
            open: [issue("PROJ-1", status: .inProgress, state: "open")],
            closed: [
                issue("PROJ-2", status: .done, state: "closed"),
                issue("PROJ-3", status: .done, state: "closed"),
            ]
        )

        let merged = IssueTracker.mergeJiraListing(listing)

        // Both Done issues land in the flat list so the board can group them.
        #expect(merged.issues.count == 3)
        #expect(merged.issues.filter { $0.projectStatus == .done }.map(\.id).sorted()
            == ["jira:PROJ-2", "jira:PROJ-3"])
        // Done count tracks the full 24h window (mirrors GitHub semantics).
        #expect(merged.doneCount == 2)
    }

    @Test func dedupesClosedAgainstOpenButStillCountsTheWindow() {
        // A ticket present in both halves (defensive: open JQL excludes Done
        // category, so this shouldn't happen, but mirror GitHub's id dedup).
        let shared = issue("PROJ-1", status: .inProgress, state: "open")
        let listing = AssignedListing(
            open: [shared],
            closed: [issue("PROJ-1", status: .done, state: "closed")]
        )

        let merged = IssueTracker.mergeJiraListing(listing)

        // Not double-counted in the issue list...
        #expect(merged.issues.count == 1)
        #expect(merged.issues[0].id == "jira:PROJ-1")
        // ...but the Done window count still reflects the closed result.
        #expect(merged.doneCount == 1)
    }

    @Test func emptyListingYieldsNothing() {
        let merged = IssueTracker.mergeJiraListing(AssignedListing(open: [], closed: []))
        #expect(merged.issues.isEmpty)
        #expect(merged.doneCount == 0)
    }
}
