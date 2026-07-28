import Foundation
import Testing
import CrowCore
@testable import CrowProvider

/// #888 — the auto-merge watcher used to discover a repo's "Allow auto-merge"
/// setting only by failing `gh pr merge --auto` and string-matching the error.
/// `Repository.autoMergeAllowed` rides the `repository { … }` object both
/// queries already select, so it costs no extra request. `nil` must mean
/// *unknown*, never *false*: a defaulted Bool here would strand or wrongly
/// direct-merge every PR in a repo whose fetch omitted the field.
@Suite("GitHub repoAutoMergeAllowed parsing (#888)")
struct GitHubAutoMergeAllowedTests {

    private func monitoredPRsJSON(repository: String) -> String {
        """
        {
          "data": {
            "viewerPRs": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 1866,
                    "url": "https://github.com/corveil/corveil/pull/1866",
                    "state": "OPEN",
                    "mergeable": "MERGEABLE",
                    "mergeStateStatus": "CLEAN",
                    "reviewDecision": "APPROVED",
                    "isDraft": false,
                    "headRefOid": "abc",
                    \(repository)
                    "labels": {"nodes": [{"name": "crow:merge", "color": "0E8A16"}]},
                    "latestReviews": {"nodes": []},
                    "commits": {"nodes": []}
                  }
                ]
              }
            },
            "reviewPRs": {"nodes": []},
            "viewer": {"login": "someone"}
          }
        }
        """
    }

    @Test func readsAutoMergeAllowedFalse() throws {
        // The ticket's smoking gun: corveil/corveil reports allow_auto_merge:false.
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(
            monitoredPRsJSON(repository: #""repository": {"nameWithOwner": "corveil/corveil", "autoMergeAllowed": false},"#))
        #expect(listing.viewerPRs.first?.repoAutoMergeAllowed == false)
        #expect(listing.viewerPRs.first?.repoNameWithOwner == "corveil/corveil")
    }

    @Test func readsAutoMergeAllowedTrue() throws {
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(
            monitoredPRsJSON(repository: #""repository": {"nameWithOwner": "corveil/crow", "autoMergeAllowed": true},"#))
        #expect(listing.viewerPRs.first?.repoAutoMergeAllowed == true)
    }

    @Test func anAbsentFieldIsUnknownNotForbidden() throws {
        // A query that didn't select the field, or a partial SAML recovery.
        // `false` here would send every PR in the repo down the direct-merge
        // path — the one blast radius this feature must not have.
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(
            monitoredPRsJSON(repository: #""repository": {"nameWithOwner": "corveil/crow"},"#))
        #expect(listing.viewerPRs.first?.repoAutoMergeAllowed == nil)
    }

    @Test func anAbsentRepositoryObjectIsAlsoUnknown() throws {
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(monitoredPRsJSON(repository: ""))
        #expect(listing.viewerPRs.first?.repoAutoMergeAllowed == nil)
    }

    @Test func bothQueriesSelectTheField() {
        // Adding the field to only one of the two GraphQL queries would make the
        // verdict depend on which fetch happened to see the PR last.
        #expect(GitHubCodeBackend.monitoredPRsQuery.contains("autoMergeAllowed"))
    }

    @Test func gitHubDeclaresTheDirectMergeCapability() {
        // The fallback is capability-gated; GitLab inherits the throwing default.
        let backend = GitHubCodeBackend(shellRunner: ProcessShellRunner())
        #expect(backend.capabilities.contains(.directMerge))
    }
}
