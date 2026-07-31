import XCTest
import CrowCore
@testable import CrowProvider

/// Records every shell invocation and returns canned outputs. Backends accept any
/// `ShellRunner`, so tests can assert command vectors without hitting the network
/// or spawning real `gh`/`glab` processes.
final class FakeShellRunner: ShellRunner, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let args: [String]
        let env: [String: String]
        let cwd: String?
    }
    var calls: [Call] = []
    /// Responses pulled in order. If empty, returns `""`.
    var responses: [Result<String, Error>] = []

    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        calls.append(Call(args: args, env: env, cwd: cwd))
        guard !responses.isEmpty else { return "" }
        let next = responses.removeFirst()
        switch next {
        case .success(let s): return s
        case .failure(let e): throw e
        }
    }
}

final class BackendsTests: XCTestCase {
    // MARK: - GitHubTaskBackend

    func testGitHubTaskBackendDeclaresCapabilities() {
        let backend = GitHubTaskBackend(shellRunner: FakeShellRunner())
        XCTAssertEqual(backend.provider, .github)
        XCTAssertTrue(backend.capabilities.contains(.projectBoardStatus))
        XCTAssertTrue(backend.capabilities.contains(.batchedQuery))
    }

    func testGitHubTaskBackendFetchTaskInvokesGhIssueView() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"{"title":"Hello"}"#)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let info = try await backend.fetchTask(url: "https://github.com/acme/api/issues/42")
        XCTAssertEqual(info.title, "Hello")
        XCTAssertEqual(info.number, 42)
        XCTAssertEqual(info.repo, "api")
        XCTAssertEqual(info.org, "acme")
        XCTAssertEqual(info.provider, .github)
        XCTAssertFalse(info.isMR)
        XCTAssertEqual(fake.calls.first?.args.first, "gh")
        XCTAssertTrue(fake.calls.first?.args.contains("issue") ?? false)
        // #696: GitHub carries no ticket priority/epic — the fields default to
        // nil without any backend change (neutral alignment weight downstream).
        XCTAssertNil(info.priority)
        XCTAssertNil(info.parentKey)
    }

    func testGitHubTaskBackendRejectsPullRequestURL() async {
        let backend = GitHubTaskBackend(shellRunner: FakeShellRunner())
        do {
            _ = try await backend.fetchTask(url: "https://github.com/acme/api/pull/7")
            XCTFail("expected throw for PR URL")
        } catch ProviderError.invalidURL {
            // expected
        } catch {
            XCTFail("expected invalidURL, got \(error)")
        }
    }

    func testGitHubTaskBackendSetLabelsAddsAndRemovesLabels() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setLabels(
            url: "https://github.com/acme/api/issues/42",
            add: ["crow:auto"],
            remove: ["wip"]
        )
        XCTAssertEqual(fake.calls.count, 1)
        let args = fake.calls[0].args
        XCTAssertEqual(args[0], "gh")
        XCTAssertTrue(args.contains("--add-label"))
        XCTAssertTrue(args.contains("crow:auto"))
        XCTAssertTrue(args.contains("--remove-label"))
        XCTAssertTrue(args.contains("wip"))
    }

    func testGitHubTaskBackendSetLabelsSkipsEmpty() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setLabels(url: "https://github.com/acme/api/issues/1", add: [], remove: [])
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testGitHubTaskBackendListAssignedIssuesParses() async throws {
        let fake = FakeShellRunner()
        let json = """
        {"data":{
          "openIssues":{"nodes":[
            {"number":1,"title":"Open one","url":"https://github.com/a/b/issues/1","state":"open",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"bug","color":"red"}]},
             "projectItems":{"nodes":[{"fieldValueByName":{"name":"In Progress"}}]}}
          ]},
          "closedIssues":{"issueCount":137,"nodes":[
            {"number":2,"title":"Closed one","url":"https://github.com/a/b/issues/2","state":"closed",
             "repository":{"nameWithOwner":"a/b"},"labels":{"nodes":[]}}
          ]},
          "rateLimit":{"remaining":4999,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":1}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 1)
        XCTAssertEqual(listing.open[0].title, "Open one")
        XCTAssertEqual(listing.open[0].projectStatus, .inProgress)
        XCTAssertEqual(listing.closed.count, 1)
        XCTAssertEqual(listing.closed[0].projectStatus, .done)  // override for closed
        // The total comes from the search connection's issueCount, not the
        // node page — the done badge must be able to exceed the first: 50 cap.
        XCTAssertEqual(listing.closedTotalCount, 137)
        XCTAssertEqual(listing.rateLimit?.remaining, 4999)
        XCTAssertEqual(fake.calls.first?.args[0], "gh")
        XCTAssertTrue(fake.calls.first?.args.contains("graphql") ?? false)
    }

    func testGitHubTaskBackendParsesInReviewLabelFallback() async throws {
        let fake = FakeShellRunner()
        // Open issues: #1 has no project item but carries the fallback label →
        // .inReview; #2 is on a board AND carries the label → the board wins;
        // #3 has neither → .unknown. Closed #4 carries the label → .done (the
        // closed override wins).
        let json = """
        {"data":{
          "openIssues":{"nodes":[
            {"number":1,"title":"Labelled","url":"https://github.com/a/b/issues/1","state":"open",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"crow:in-review","color":"FBCA04"}]},
             "projectItems":{"nodes":[]}},
            {"number":2,"title":"On board","url":"https://github.com/a/b/issues/2","state":"open",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"crow:in-review","color":"FBCA04"}]},
             "projectItems":{"nodes":[{"fieldValueByName":{"name":"In Progress"}}]}},
            {"number":3,"title":"Plain","url":"https://github.com/a/b/issues/3","state":"open",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"bug","color":"red"}]},
             "projectItems":{"nodes":[]}}
          ]},
          "closedIssues":{"issueCount":1,"nodes":[
            {"number":4,"title":"Closed","url":"https://github.com/a/b/issues/4","state":"closed",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"crow:in-review","color":"FBCA04"}]}}
          ]},
          "rateLimit":{"remaining":4999,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":1}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 3)
        XCTAssertEqual(listing.open[0].projectStatus, .inReview)
        XCTAssertEqual(listing.open[1].projectStatus, .inProgress)
        XCTAssertEqual(listing.open[2].projectStatus, .unknown)
        XCTAssertEqual(listing.closed[0].projectStatus, .done)
    }

    func testGitHubTaskBackendParsesInProgressLabelFallback() async throws {
        let fake = FakeShellRunner()
        // #1 no project item + `crow:in-progress` → .inProgress; #2 is on a
        // board, which wins over the label; #3 carries both fallback labels →
        // In Review wins (pipeline order).
        let json = """
        {"data":{
          "openIssues":{"nodes":[
            {"number":1,"title":"Working","url":"https://github.com/a/b/issues/1","state":"open",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"crow:in-progress","color":"1D76DB"}]},
             "projectItems":{"nodes":[]}},
            {"number":2,"title":"On board","url":"https://github.com/a/b/issues/2","state":"open",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"crow:in-progress","color":"1D76DB"}]},
             "projectItems":{"nodes":[{"fieldValueByName":{"name":"Backlog"}}]}},
            {"number":3,"title":"Both","url":"https://github.com/a/b/issues/3","state":"open",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[{"name":"crow:in-progress","color":"1D76DB"},
                                {"name":"crow:in-review","color":"FBCA04"}]},
             "projectItems":{"nodes":[]}}
          ]},
          "closedIssues":{"nodes":[]}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 3)
        XCTAssertEqual(listing.open[0].projectStatus, .inProgress)
        XCTAssertEqual(listing.open[1].projectStatus, .backlog)
        XCTAssertEqual(listing.open[2].projectStatus, .inReview)
    }

    func testGitHubTaskBackendClosedTotalFallsBackToNodeCount() async throws {
        let fake = FakeShellRunner()
        // No issueCount in the response — closedTotalCount falls back to the
        // fetched node count.
        let json = """
        {"data":{
          "openIssues":{"nodes":[]},
          "closedIssues":{"nodes":[
            {"number":2,"title":"Closed one","url":"https://github.com/a/b/issues/2","state":"closed",
             "repository":{"nameWithOwner":"a/b"},"labels":{"nodes":[]}}
          ]}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.closed.count, 1)
        XCTAssertEqual(listing.closedTotalCount, 1)
    }

    func testGitHubTaskBackendListAssignedRetriesWithoutProjectsOnScopeError() async throws {
        let fake = FakeShellRunner()
        fake.responses = [
            .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "GraphQL error: INSUFFICIENT_SCOPES (need read:project)")),
            .success(#"{"data":{"openIssues":{"nodes":[]},"closedIssues":{"nodes":[]}}}"#)
        ]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 0)
        // The retry call used the no-projects query — query body differs.
        XCTAssertEqual(fake.calls.count, 2)
        // Missing-scope is surfaced so callers can keep their warning UI lit.
        XCTAssertEqual(listing.missingScope, "read:project")
    }

    // MARK: - SAML enforcement (graceful degradation)

    func testClassifyGraphQLErrorDetectsSAML() {
        let blob = #"{"data":{"openIssues":{"nodes":[]}},"errors":[{"type":"FORBIDDEN","message":"Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise."}]}"#
        guard case .samlRestricted(let carried) = GitHubTaskBackend.classifyGraphQLError(blob) else {
            return XCTFail("expected .samlRestricted")
        }
        // The full blob is carried so call sites can recover partial data.
        XCTAssertEqual(carried, blob)
    }

    func testClassifyGraphQLErrorSAMLTakesPrecedenceOverScope() {
        // A SAML blob shouldn't be misrouted to the scope branch even if it
        // happened to mention a scope-ish token.
        let blob = "Resource protected by organization SAML enforcement"
        guard case .samlRestricted = GitHubTaskBackend.classifyGraphQLError(blob) else {
            return XCTFail("expected .samlRestricted")
        }
    }

    func testDecodeGraphQLDataExtractsLeadingObjectWithTrailingGhError() {
        // Merged stdout+stderr: response body followed by gh's error line, plus
        // a brace inside a string value to exercise the string-aware scanner.
        let blob = """
        {"data":{"openIssues":{"nodes":[{"title":"weird }{ title"}]}}}
        gh: Resource protected by organization SAML enforcement.
        """
        let dataObj = GitHubTaskBackend.decodeGraphQLData(blob)
        XCTAssertNotNil(dataObj)
        let nodes = ((dataObj?["openIssues"] as? [String: Any])?["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes?.first?["title"] as? String, "weird }{ title")
    }

    func testListAssignedRecoversAccessibleIssuesOnSAML() async throws {
        // GitHub returns the accessible-org issue in `data` alongside the SAML
        // `errors` entry; gh exits non-zero and the merged blob carries both,
        // with gh's error line appended after the body.
        let blob = """
        {"data":{
          "openIssues":{"nodes":[
            {"number":7,"title":"Accessible","url":"https://github.com/ok/repo/issues/7","state":"open",
             "repository":{"nameWithOwner":"ok/repo"},"labels":{"nodes":[]}}
          ]},
          "closedIssues":{"nodes":[]},
          "rateLimit":{"remaining":4990,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":1}
        },"errors":[{"type":"FORBIDDEN","path":["openIssues","nodes",3],"message":"Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise."}]}
        gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise.
        """
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: blob))]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let listing = try await backend.listAssigned()
        XCTAssertTrue(listing.samlRestricted)
        XCTAssertEqual(listing.open.count, 1)
        XCTAssertEqual(listing.open.first?.title, "Accessible")
        XCTAssertEqual(listing.rateLimit?.remaining, 4990)
    }

    func testRecoverPartialIssuesEmptyWhenNoJSON() {
        // gh emitted only an error line, no body — degrade to empty + flagged,
        // never throw.
        let listing = GitHubTaskBackend.recoverPartialIssues(
            fromSAMLBlob: "gh: Resource protected by organization SAML enforcement."
        )
        XCTAssertTrue(listing.samlRestricted)
        XCTAssertTrue(listing.open.isEmpty)
        XCTAssertTrue(listing.closed.isEmpty)
    }

    /// #894: GitHub nullifies individual `viewer.pullRequests.nodes` entries for
    /// org PRs behind SAML enforcement and returns the rest. This test used a
    /// clean nodes array, so the all-or-nothing `as? [[String: Any]]` cast that
    /// dropped every accessible PR never showed up. The fixture now interleaves
    /// nulls at the head, middle, and tail, and asserts that check state — the
    /// payload the Fix Checks button keys off — survives with the PRs.
    func testListMonitoredPRsRecoversAccessiblePRsOnSAML() async throws {
        let blob = """
        {"data":{
          "viewerPRs":{"pullRequests":{"nodes":[
            null,
            {"number":885,"url":"https://github.com/ok/repo/pull/885","state":"OPEN",
             "headRefName":"feat","baseRefName":"main","repository":{"nameWithOwner":"ok/repo"},
             "labels":{"nodes":[{"name":"crow:merge","color":"1D76DB"}]},
             "statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
               {"__typename":"CheckRun","name":"Build & Test","conclusion":"FAILURE","status":"COMPLETED"},
               {"__typename":"CheckRun","name":"Lint","conclusion":"SUCCESS","status":"COMPLETED"}
             ]}}},
            null,
            null,
            {"number":837,"url":"https://github.com/ok/repo/pull/837","state":"OPEN",
             "headRefName":"other","baseRefName":"main","repository":{"nameWithOwner":"ok/repo"},
             "statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[]}}},
            null
          ]}},
          "reviewPRs":{"nodes":[]},
          "viewer":{"login":"me"},
          "rateLimit":{"remaining":4980,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":1}
        },"errors":[{"type":"FORBIDDEN","path":["viewerPRs","pullRequests","nodes",0],"message":"Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise."}]}
        gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise.
        """
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: blob))]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let listing = try await backend.listMonitoredPRs()
        XCTAssertTrue(listing.samlRestricted)
        // Pre-#894 this was 0: one NSNull nilled the whole array cast.
        XCTAssertEqual(listing.viewerPRs.count, 2)
        XCTAssertEqual(listing.viewerPRs.map(\.number), [885, 837])
        XCTAssertEqual(listing.viewerLogin, "me")
        XCTAssertEqual(listing.rateLimit?.remaining, 4980)

        // The regression that made this user-visible: CI state must survive.
        let failing = try XCTUnwrap(listing.viewerPRs.first { $0.number == 885 })
        XCTAssertEqual(failing.checksState, "FAILURE")
        XCTAssertEqual(failing.failedCheckNames, ["Build & Test"])
        XCTAssertEqual(failing.labels.map(\.name), ["crow:merge"])

        let green = try XCTUnwrap(listing.viewerPRs.first { $0.number == 837 })
        XCTAssertEqual(green.checksState, "SUCCESS")
        XCTAssertTrue(green.failedCheckNames.isEmpty)
    }

    /// #894, one level down: nulls can appear inside *any* nullable-element
    /// connection, not just the top-level `nodes`. A null in `labels.nodes`,
    /// `statusCheckRollup.contexts.nodes`, `latestReviews.nodes`,
    /// `commits.nodes`, or `closingIssuesReferences.nodes` must drop only that
    /// element — not the surrounding array and not the PR itself.
    func testParsePRNodeSurvivesNullsInsideNestedConnections() throws {
        let json = """
        {"data":{
          "viewerPRs":{"pullRequests":{"nodes":[
            {"number":7,"url":"https://github.com/a/b/pull/7","state":"OPEN",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[null,{"name":"bug","color":"red"},null]},
             "closingIssuesReferences":{"nodes":[
               null,{"number":42,"repository":{"nameWithOwner":"a/b"}}
             ]},
             "statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
               null,
               {"__typename":"CheckRun","name":"Build","conclusion":"FAILURE","status":"COMPLETED"},
               null,
               {"__typename":"StatusContext","context":"ci/legacy","state":"ERROR"}
             ]}},
             "latestReviews":{"nodes":[
               null,
               {"state":"CHANGES_REQUESTED","submittedAt":"2026-06-07T10:00:00Z"},
               null
             ]},
             "commits":{"nodes":[
               null,
               {"commit":{"oid":"1","messageHeadline":"real fix",
                          "committedDate":"2026-06-01T00:00:00Z",
                          "authoredDate":"2026-06-01T00:00:00Z","parents":{"totalCount":1}}},
               null
             ]}}
          ]}},
          "reviewPRs":{"nodes":[]},
          "viewer":{"login":"me"}
        }}
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        let pr = try XCTUnwrap(listing.viewerPRs.first)
        XCTAssertEqual(pr.labels.map(\.name), ["bug"])
        XCTAssertEqual(pr.linkedIssueReferences.map(\.number), [42])
        XCTAssertEqual(pr.checksState, "FAILURE")
        // Both context shapes survive: CheckRun keys off conclusion/name,
        // StatusContext off state/context.
        XCTAssertEqual(pr.failedCheckNames, ["Build", "ci/legacy"])
        XCTAssertEqual(pr.latestReviewStates, ["CHANGES_REQUESTED"])
        // Epoch-constructed so a nil-vs-nil co-failure can't pass this.
        XCTAssertEqual(pr.lastChangesRequestedAt, Date(timeIntervalSince1970: 1780826400))
        XCTAssertEqual(pr.lastSubstantiveCommitAt, Date(timeIntervalSince1970: 1780272000))
    }

    /// A connection whose `nodes` is itself `null` (GraphQL nullifies to the
    /// nearest nullable parent when the whole connection errors) must degrade
    /// to empty, not take the PR down with it.
    func testParsePRNodeToleratesWhollyNullConnections() throws {
        let json = """
        {"data":{
          "viewerPRs":{"pullRequests":{"nodes":[
            {"number":8,"url":"https://github.com/a/b/pull/8","state":"OPEN",
             "repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":null},
             "statusCheckRollup":null,
             "latestReviews":null,
             "commits":{"nodes":[]}}
          ]}},
          "reviewPRs":{"nodes":[]},
          "viewer":{"login":"me"}
        }}
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        let pr = try XCTUnwrap(listing.viewerPRs.first)
        XCTAssertEqual(pr.number, 8)
        XCTAssertTrue(pr.labels.isEmpty)
        XCTAssertEqual(pr.checksState, "")
        XCTAssertTrue(pr.failedCheckNames.isEmpty)
        XCTAssertTrue(pr.latestReviewStates.isEmpty)
        XCTAssertNil(pr.lastSubstantiveCommitAt)
    }

    /// The `reviewPRs: search(…)` connection nullifies elements the same way
    /// (#894). Covers the top-level `nodes` array and a null inside a PR's own
    /// `reviews.nodes`, which feeds `viewerLastReviewedAt`.
    func testParseReviewRequestsSkipsNullNodes() throws {
        let json = """
        {"data":{
          "viewerPRs":{"pullRequests":{"nodes":[]}},
          "reviewPRs":{"nodes":[
            null,
            {"number":21,"title":"Review me","url":"https://github.com/a/b/pull/21",
             "state":"OPEN","isDraft":false,"updatedAt":"2026-06-07T10:00:00.000Z",
             "headRefName":"feat","baseRefName":"main",
             "author":{"login":"someone"},"repository":{"nameWithOwner":"a/b"},
             "labels":{"nodes":[null,{"name":"needs-review","color":"blue"}]},
             "reviews":{"nodes":[
               null,
               {"author":{"login":"me"},"state":"APPROVED","submittedAt":"2026-06-06T10:00:00.000Z"},
               null
             ]}},
            null
          ]},
          "viewer":{"login":"me"}
        }}
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        XCTAssertEqual(listing.reviewRequests.count, 1)
        let req = try XCTUnwrap(listing.reviewRequests.first)
        XCTAssertEqual(req.prNumber, 21)
        XCTAssertEqual(req.labels.map(\.name), ["needs-review"])
        // The viewer's own review survived the null siblings.
        XCTAssertNotNil(req.viewerLastReviewedAt)
    }

    /// #894 issue-side counterpart: one SAML-nulled assigned issue dropped the
    /// entire ticket list. Note the *existing* SAML fixture above already
    /// carried `"path":["openIssues","nodes",3]` in its errors array while its
    /// `nodes` array was clean — it described the null without reproducing it.
    func testListAssignedRecoversIssuesWhenNodesContainNulls() async throws {
        let blob = """
        {"data":{
          "openIssues":{"nodes":[
            null,
            {"number":7,"title":"Accessible","url":"https://github.com/ok/repo/issues/7","state":"open",
             "repository":{"nameWithOwner":"ok/repo"},
             "labels":{"nodes":[null,{"name":"bug","color":"red"}]},
             "projectItems":{"nodes":[null,{"fieldValueByName":{"name":"In Progress"}}]}},
            null,
            {"number":9,"title":"Also accessible","url":"https://github.com/ok/repo/issues/9","state":"open",
             "repository":{"nameWithOwner":"ok/repo"},"labels":{"nodes":[]},
             "projectItems":{"nodes":[]}}
          ]},
          "closedIssues":{"issueCount":2,"nodes":[
            null,
            {"number":3,"title":"Done","url":"https://github.com/ok/repo/issues/3","state":"closed",
             "repository":{"nameWithOwner":"ok/repo"},"labels":{"nodes":[]}}
          ]},
          "rateLimit":{"remaining":4990,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":1}
        },"errors":[{"type":"FORBIDDEN","path":["openIssues","nodes",0],"message":"Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise."}]}
        gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise.
        """
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: blob))]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let listing = try await backend.listAssigned(includeClosed: true)
        XCTAssertTrue(listing.samlRestricted)
        // Pre-#894: 0.
        XCTAssertEqual(listing.open.count, 2)
        XCTAssertEqual(listing.open.map(\.number), [7, 9])
        XCTAssertEqual(listing.closed.count, 1)
        // A null sibling in labels.nodes / projectItems.nodes must not erase
        // the surviving entries.
        let first = try XCTUnwrap(listing.open.first)
        XCTAssertEqual(first.labels.map(\.name), ["bug"])
        XCTAssertEqual(first.projectStatus, .inProgress)
        XCTAssertEqual(listing.rateLimit?.remaining, 4990)
    }

    /// #894: a nulled project item must not hide the surviving one. Before the
    /// fix, `[null, {…}]` failed the array cast in BOTH
    /// `resolveProjectFieldOption` and `hasProjectItems`, so the backend
    /// concluded "no board" and quietly wrote a `crow:` fallback label onto an
    /// issue that IS on a board. Also covers a null inside `field.options`.
    func testSetTaskStatusResolvesOptionDespiteNullProjectItemsAndOptions() async throws {
        let fake = FakeShellRunner()
        let lookup = """
        {"data":{"repository":{"issue":{"projectItems":{"nodes":[
          null,
          {"id":"ITEM_1","project":{"id":"PROJ_1"},
           "fieldValueByName":{"name":"Backlog",
             "field":{"id":"FIELD_1","options":[
               null,
               {"id":"OPT_INREVIEW","name":"In Review"},
               null,
               {"id":"OPT_DONE","name":"Done"}
             ]}}},
          null
        ]}}}}}
        """
        fake.responses = [.success(lookup), .success(#"{"data":{}}"#)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
        // Two calls == lookup + mutation. Pre-fix this took the label-fallback
        // path instead.
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertTrue(fake.calls.last?.args.contains { $0.contains("OPT_INREVIEW") } ?? false)
    }

    /// `hasProjectItems` must see through nulls: `[null, {…}]` means the issue
    /// IS on a board, so a missing Status option is `unimplemented`, not a
    /// silent `crow:` label write. This is the one intentional behavior change
    /// in #894 — it restores the semantics the function's doc comment claimed.
    func testHasProjectItemsSeesThroughNullEntries() {
        let allNull = #"{"data":{"repository":{"issue":{"projectItems":{"nodes":[null,null]}}}}}"#
        XCTAssertFalse(GitHubTaskBackend.hasProjectItems(allNull))

        let mixed = """
        {"data":{"repository":{"issue":{"projectItems":{"nodes":[
          null,{"id":"ITEM_1","project":{"id":"PROJ_1"}}
        ]}}}}}
        """
        XCTAssertTrue(GitHubTaskBackend.hasProjectItems(mixed))

        XCTAssertFalse(GitHubTaskBackend.hasProjectItems(
            #"{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}"#
        ))
        XCTAssertFalse(GitHubTaskBackend.hasProjectItems("not json"))
    }

    func testFindRecentPRsForBranchesSkipsNullNodes() async throws {
        let fake = FakeShellRunner()
        let json = """
        {"data":{
          "pr0":{"pullRequests":{"nodes":[
            null,
            {"number":5,"url":"https://github.com/a/b/pull/5","state":"OPEN",
             "updatedAt":"2026-06-07T10:00:00.000Z","headRefName":"feat/x"},
            null
          ]}},
          "pr1":null
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let matches = try await backend.findRecentPRsForBranches([
            BranchCandidate(repoSlug: "a/b", branch: "feat/x"),
            BranchCandidate(repoSlug: "blocked/repo", branch: "feat/y")
        ])
        // The null-only alias contributes nothing; the surviving node survives.
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.number, 5)
    }

    /// #894: `prStates` feeds session-linked PRs absent from
    /// `viewer.pullRequests(first: 50)` — including SAML-restricted PRs, which
    /// are *permanently* absent from that connection. Without the rollup those
    /// PRs could never show CI status. `parsePRNode` is shared, so only the
    /// query needed the field.
    func testPRStatesRequestsAndParsesStatusCheckRollup() async throws {
        let fake = FakeShellRunner()
        let json = """
        {"data":{
          "pr0":{"pullRequest":{"number":885,"url":"https://github.com/a/b/pull/885","state":"OPEN",
                 "repository":{"nameWithOwner":"a/b"},
                 "labels":{"nodes":[{"name":"crow:merge","color":"1D76DB"}]},
                 "statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[
                   null,
                   {"__typename":"CheckRun","name":"Build & Test","conclusion":"FAILURE","status":"COMPLETED"},
                   {"__typename":"CheckRun","name":"Lint","conclusion":"SUCCESS","status":"COMPLETED"}
                 ]}}}}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let ref = PRRef(owner: "a", repo: "b", number: 885)
        let states = try await backend.prStates(refs: [ref])
        XCTAssertEqual(states[ref]?.checksState, "FAILURE")
        XCTAssertEqual(states[ref]?.failedCheckNames, ["Build & Test"])
        XCTAssertEqual(states[ref]?.labels.map(\.name), ["crow:merge"])
        // The batched query actually asks for it.
        XCTAssertTrue(fake.calls.first?.args.contains { $0.contains("statusCheckRollup") } ?? false)
        XCTAssertTrue(fake.calls.first?.args.contains { $0.contains("contexts(first: 25)") } ?? false)
    }

    /// #894: `prStates` batches every stale ref into one aliased query, so a
    /// single SAML-restricted repo made `gh` exit non-zero and threw away state
    /// for EVERY stale PR in the cycle. Symmetric with `listMonitoredPRs`:
    /// recover the aliases that resolved.
    func testPRStatesRecoversAccessibleRefsOnSAML() async throws {
        let blob = """
        {"data":{
          "pr0":{"pullRequest":{"number":1,"url":"https://github.com/ok/repo/pull/1","state":"MERGED",
                 "mergeCommit":{"oid":"0123456789abcdef"},
                 "repository":{"nameWithOwner":"ok/repo"},
                 "labels":{"nodes":[]},
                 "statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[]}}}},
          "pr1":null,
          "pr2":{"pullRequest":{"number":3,"url":"https://github.com/ok/repo/pull/3","state":"CLOSED",
                 "repository":{"nameWithOwner":"ok/repo"},"labels":{"nodes":[]}}}
        },"errors":[{"type":"FORBIDDEN","path":["pr1"],"message":"Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise."}]}
        gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise.
        """
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: blob))]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let ok = PRRef(owner: "ok", repo: "repo", number: 1)
        let blocked = PRRef(owner: "blocked", repo: "repo", number: 2)
        let alsoOK = PRRef(owner: "ok", repo: "repo", number: 3)
        // Pre-#894 this threw and the caller lost all three.
        let states = try await backend.prStates(refs: [ok, blocked, alsoOK])
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[ok]?.state, "MERGED")
        XCTAssertEqual(states[ok]?.mergeCommitOid, "0123456789abcdef")
        XCTAssertEqual(states[alsoOK]?.state, "CLOSED")
        // The restricted ref is simply absent — auto-completion requires
        // positive evidence (`guard let pr = prsByURL[...]`), so an absent
        // record can never be mistaken for "closed".
        XCTAssertNil(states[blocked])
    }

    /// Non-SAML failures must still throw — the recovery path is narrow.
    func testPRStatesStillThrowsOnNonSAMLFailure() async {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(
            exitCode: 1, output: "API rate limit exceeded"
        ))]
        let backend = GitHubCodeBackend(shellRunner: fake)
        do {
            _ = try await backend.prStates(refs: [PRRef(owner: "a", repo: "b", number: 1)])
            XCTFail("expected throw")
        } catch let error as ProviderError {
            if case .samlRestricted = error {
                XCTFail("non-SAML failure must not take the recovery path")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// gh emitted only an error line, no body — degrade to empty, never throw.
    func testRecoverPartialStalePRStatesEmptyWhenNoJSON() {
        let states = GitHubCodeBackend.recoverPartialStalePRStates(
            fromSAMLBlob: "gh: Resource protected by organization SAML enforcement.",
            refs: [PRRef(owner: "a", repo: "b", number: 1)]
        )
        XCTAssertTrue(states.isEmpty)
    }

    /// Companion to `testHasProjectItemsSeesThroughNullEntries`: a board whose
    /// ONLY project item is nulled still counts as "no board", so the label
    /// fallback keeps working. Guards against over-correcting that change.
    func testSetTaskStatusStillFallsBackToLabelWhenAllProjectItemsAreNull() async throws {
        let fake = FakeShellRunner()
        let lookup = #"{"data":{"repository":{"issue":{"projectItems":{"nodes":[null,null]}}}}}"#
        fake.responses = [.success(lookup), .success(""), .success(""), .success("")]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
        XCTAssertEqual(fake.calls.count, 4)
        XCTAssertEqual(Array(fake.calls.dropFirst().first?.args.prefix(4) ?? []), ["gh", "label", "create", "crow:in-review"])
    }

    // MARK: - LenientJSON (#894)

    /// The primitive the whole fix rests on. Pinned directly so a refactor that
    /// "simplifies" it back to `as? [[String: Any]]` fails here first, with a
    /// message pointing at the cause rather than at a parse result three layers
    /// up.
    func testLenientJSONDropsNullsInsteadOfFailingTheArray() throws {
        let raw = try JSONSerialization.jsonObject(
            with: Data(#"{"c":{"nodes":[null,{"n":1},null,{"n":2}]},"plain":[null,{"id":"x"}],"nullNodes":{"nodes":null},"notArray":{"nodes":{"n":1}}}"#.utf8)
        ) as? [String: Any]
        let obj = try XCTUnwrap(raw)

        // The exact failure #894 is about.
        XCTAssertNil((obj["c"] as? [String: Any])?["nodes"] as? [[String: Any]])
        XCTAssertEqual(LenientJSON.nodes(obj, "c").count, 2)
        XCTAssertEqual(LenientJSON.nodes(obj, "c").compactMap { $0["n"] as? Int }, [1, 2])

        XCTAssertEqual(LenientJSON.objects(obj["plain"]).count, 1)
        XCTAssertTrue(LenientJSON.nodes(obj, "nullNodes").isEmpty)
        XCTAssertTrue(LenientJSON.nodes(obj, "notArray").isEmpty)
        XCTAssertTrue(LenientJSON.nodes(obj, "absent").isEmpty)
        XCTAssertTrue(LenientJSON.nodes(nil, "anything").isEmpty)
        XCTAssertTrue(LenientJSON.nodes(nil).isEmpty)
        XCTAssertTrue(LenientJSON.objects(nil).isEmpty)
        XCTAssertTrue(LenientJSON.objects(NSNull()).isEmpty)
    }

    func testGitHubTaskBackendSetTaskStatusRunsMutation() async throws {
        let fake = FakeShellRunner()
        // First call: lookup. Second call: mutation.
        let lookup = """
        {"data":{"repository":{"issue":{"projectItems":{"nodes":[
          {"id":"ITEM_1","project":{"id":"PROJ_1"},
           "fieldValueByName":{"name":"Backlog",
             "field":{"id":"FIELD_1","options":[
               {"id":"OPT_INREVIEW","name":"In Review"},
               {"id":"OPT_DONE","name":"Done"}
             ]}}}
        ]}}}}}
        """
        fake.responses = [.success(lookup), .success(#"{"data":{}}"#)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
        XCTAssertEqual(fake.calls.count, 2)
        // Mutation call should reference OPT_INREVIEW.
        let mutationArgs = fake.calls[1].args
        XCTAssertTrue(mutationArgs.contains("optionId=OPT_INREVIEW"))
    }

    func testGitHubTaskBackendSetTaskStatusThrowsWhenOptionMissing() async {
        let fake = FakeShellRunner()
        // On a project board, but no option matching the target status — this
        // stays an unimplemented throw (the label fallback is only for issues
        // on no board at all).
        let lookup = """
        {"data":{"repository":{"issue":{"projectItems":{"nodes":[
          {"id":"ITEM_1","project":{"id":"PROJ_1"},
           "fieldValueByName":{"name":"Backlog",
             "field":{"id":"FIELD_1","options":[
               {"id":"OPT_BACKLOG","name":"Backlog"},
               {"id":"OPT_DONE","name":"Done"}
             ]}}}
        ]}}}}}
        """
        fake.responses = [.success(lookup)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        do {
            try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
            XCTFail("expected throw")
        } catch ProviderError.unimplemented {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        // No label churn on the on-project path.
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testGitHubTaskBackendSetTaskStatusMatchesBareReviewAlias() async throws {
        // Regression guard: a project board whose Status column is named just
        // "Review" (no "In ") must still resolve to .inReview, since
        // TicketStatus(projectBoardName:) treats them as synonyms.
        let fake = FakeShellRunner()
        let lookup = """
        {"data":{"repository":{"issue":{"projectItems":{"nodes":[
          {"id":"ITEM_1","project":{"id":"PROJ_1"},
           "fieldValueByName":{"name":"Backlog",
             "field":{"id":"FIELD_1","options":[
               {"id":"OPT_REVIEW","name":"Review"},
               {"id":"OPT_DONE","name":"Done"}
             ]}}}
        ]}}}}}
        """
        fake.responses = [.success(lookup), .success(#"{"data":{}}"#)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertTrue(fake.calls[1].args.contains("optionId=OPT_REVIEW"))
    }

    // No project board at all → the `crow:in-review` / `crow:in-progress`
    // labels carry the status instead of a Projects-v2 field (#706, #790).
    private static let noProjectLookup = #"{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}"#

    func testGitHubTaskBackendSetTaskStatusFallsBackToLabelWhenNoProject() async throws {
        let fake = FakeShellRunner()
        // Lookup (no project items) → label create → add edit → clear the
        // sibling in-progress label.
        fake.responses = [.success(Self.noProjectLookup), .success(""), .success(""), .success("")]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
        XCTAssertEqual(fake.calls.count, 4)
        let createArgs = fake.calls[1].args
        XCTAssertEqual(Array(createArgs.prefix(4)), ["gh", "label", "create", "crow:in-review"])
        XCTAssertTrue(createArgs.contains("a/b"))
        let editArgs = fake.calls[2].args
        XCTAssertTrue(editArgs.contains("--add-label"))
        XCTAssertTrue(editArgs.contains("crow:in-review"))
        XCTAssertFalse(editArgs.contains("--remove-label"))
        // The two fallback labels are mutually exclusive.
        let clearArgs = fake.calls[3].args
        XCTAssertTrue(clearArgs.contains("--remove-label"))
        XCTAssertTrue(clearArgs.contains("crow:in-progress"))
    }

    func testGitHubTaskBackendSetTaskStatusFallsBackToInProgressLabelWhenNoProject() async throws {
        let fake = FakeShellRunner()
        // Lookup → label create → add edit → clear the sibling in-review label.
        fake.responses = [.success(Self.noProjectLookup), .success(""), .success(""), .success("")]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inProgress)
        XCTAssertEqual(fake.calls.count, 4)
        let createArgs = fake.calls[1].args
        XCTAssertEqual(Array(createArgs.prefix(4)), ["gh", "label", "create", "crow:in-progress"])
        XCTAssertTrue(createArgs.contains("a/b"))
        let editArgs = fake.calls[2].args
        XCTAssertTrue(editArgs.contains("--add-label"))
        XCTAssertTrue(editArgs.contains("crow:in-progress"))
        XCTAssertFalse(editArgs.contains("--remove-label"))
        let clearArgs = fake.calls[3].args
        XCTAssertTrue(clearArgs.contains("--remove-label"))
        XCTAssertTrue(clearArgs.contains("crow:in-review"))
    }

    func testGitHubTaskBackendSetTaskStatusFallbackToleratesExistingLabel() async throws {
        let fake = FakeShellRunner()
        fake.responses = [
            .success(Self.noProjectLookup),
            .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "label 'crow:in-review' already exists")),
            .success(""),
            .success("")
        ]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
        XCTAssertEqual(fake.calls.count, 4)
        XCTAssertTrue(fake.calls[2].args.contains("--add-label"))
        XCTAssertTrue(fake.calls[2].args.contains("crow:in-review"))
    }

    func testGitHubTaskBackendSetTaskStatusFallbackClearsBothLabelsWhenNoTarget() async throws {
        let fake = FakeShellRunner()
        // Done carries no fallback label (the issue gets closed): no create, no
        // add — just a removal edit per label.
        fake.responses = [.success(Self.noProjectLookup), .success(""), .success("")]
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .done)
        XCTAssertEqual(fake.calls.count, 3)
        let removed = fake.calls.dropFirst().flatMap(\.args)
        XCTAssertFalse(removed.contains("--add-label"))
        XCTAssertTrue(removed.contains("crow:in-progress"))
        XCTAssertTrue(removed.contains("crow:in-review"))
    }

    func testGitHubTaskBackendSetTaskStatusFallbackSwallowsMissingLabelOnRemove() async throws {
        let fake = FakeShellRunner()
        fake.responses = [
            .success(Self.noProjectLookup),
            .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "'crow:in-progress' not found")),
            .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "'crow:in-review' not found"))
        ]
        let backend = GitHubTaskBackend(shellRunner: fake)
        // Removal is best-effort: a repo that never entered review has no label.
        try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .done)
        XCTAssertEqual(fake.calls.count, 3)
    }

    func testGitHubTaskBackendAssignInvokesGhIssueEdit() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.assign(url: "https://github.com/a/b/issues/1", to: "@me")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(fake.calls[0].args.contains("--add-assignee"))
        XCTAssertTrue(fake.calls[0].args.contains("@me"))
    }

    func testGitHubTaskBackendCloseTaskRunsGhIssueClose() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.closeTask(url: "https://github.com/acme/api/issues/42")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].args, ["gh", "issue", "close", "https://github.com/acme/api/issues/42"])
    }

    func testGitHubTaskBackendCloseTaskRejectsInvalidURL() async {
        let backend = GitHubTaskBackend(shellRunner: FakeShellRunner())
        do {
            try await backend.closeTask(url: "not-a-url")
            XCTFail("expected throw")
        } catch ProviderError.invalidURL {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGitHubTaskBackendCloseTaskSurfacesCommandFailure() async {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "gh: not authenticated"))]
        let backend = GitHubTaskBackend(shellRunner: fake)
        do {
            try await backend.closeTask(url: "https://github.com/acme/api/issues/42")
            XCTFail("expected throw")
        } catch ProviderError.commandFailed(let msg) {
            XCTAssertTrue(msg.contains("not authenticated"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGitHubTaskBackendCreateTaskReturnsParsedURL() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("Creating issue in acme/api\n\nhttps://github.com/acme/api/issues/99\n")]
        let backend = GitHubTaskBackend(shellRunner: fake)
        let info = try await backend.createTask(repo: "acme/api", title: "Hi", body: "There", labels: ["bug"])
        XCTAssertEqual(info.number, 99)
        XCTAssertEqual(info.org, "acme")
        XCTAssertEqual(info.repo, "api")
        XCTAssertEqual(info.url, "https://github.com/acme/api/issues/99")
        XCTAssertTrue(fake.calls[0].args.contains("--label"))
        XCTAssertTrue(fake.calls[0].args.contains("bug"))
    }

    // MARK: - GitHubCodeBackend

    func testGitHubCodeBackendDeclaresCapabilities() {
        let backend = GitHubCodeBackend(shellRunner: FakeShellRunner())
        XCTAssertTrue(backend.capabilities.contains(.autoMergeLabel))
        XCTAssertTrue(backend.capabilities.contains(.batchedPRStates))
        XCTAssertTrue(backend.capabilities.contains(.autoMerge))
        XCTAssertTrue(backend.capabilities.contains(.updateBranch))
    }

    func testGitHubCodeBackendLinkedPRParsesJSON() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"[{"number":7,"url":"https://github.com/a/b/pull/7","state":"OPEN"}]"#)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let pr = try await backend.linkedPR(repo: "a/b", branch: "feature/x")
        XCTAssertEqual(pr?.number, 7)
        XCTAssertEqual(pr?.state, "OPEN")
        XCTAssertEqual(pr?.url, "https://github.com/a/b/pull/7")
        let args = fake.calls[0].args
        XCTAssertEqual(args[0], "gh")
        XCTAssertTrue(args.contains("--head"))
        XCTAssertTrue(args.contains("feature/x"))
    }

    func testGitHubCodeBackendLinkedPRReturnsNilForEmptyArray() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("[]")]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let pr = try await backend.linkedPR(repo: "a/b", branch: "main")
        XCTAssertNil(pr)
    }

    func testGitHubCodeBackendEnsureMergeLabelSwallowsAlreadyExists() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "label crow:merge already exists"))]
        let backend = GitHubCodeBackend(shellRunner: fake)
        try await backend.ensureMergeLabel(repo: "a/b")
    }

    func testGitHubCodeBackendPRStatesBatchesQuery() async throws {
        let fake = FakeShellRunner()
        let json = """
        {"data":{
          "pr0":{"pullRequest":{"number":1,"url":"https://github.com/a/b/pull/1","state":"MERGED",
                 "mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","isDraft":false,
                 "headRefName":"f","headRefOid":"abc","baseRefName":"main",
                 "repository":{"nameWithOwner":"a/b"}}}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let ref = PRRef(owner: "a", repo: "b", number: 1)
        let states = try await backend.prStates(refs: [ref])
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[ref]?.state, "MERGED")
        // One batched call, not per-ref.
        XCTAssertEqual(fake.calls.count, 1)
        let args = fake.calls[0].args
        XCTAssertTrue(args.contains("graphql"))
    }

    func testGitHubCodeBackendFetchCrowAuthoredCommitsReturnsCommitsWithTrailer() async throws {
        let fake = FakeShellRunner()
        let json = """
        [
          {"sha":"abc","commit":{"message":"Fix bug\\n\\nCrow-Session: 123"}},
          {"sha":"def","commit":{"message":"Unrelated change"}}
        ]
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let commits = try await backend.fetchCrowAuthoredCommits(
            prURL: "https://github.com/a/b/pull/1",
            repoSlug: "a/b",
            prNumber: 1
        )
        // Returns ALL commits — caller filters for Crow-Session trailer.
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].sha, "abc")
        XCTAssertTrue(commits[0].message.contains("Crow-Session"))
    }

    // MARK: - Rework / merge-rate backend surface (#694)

    func testGitHubCodeBackendPRStatesParsesMergeCommitOidAndToleratesAbsence() async throws {
        let fake = FakeShellRunner()
        let json = """
        {"data":{
          "pr0":{"pullRequest":{"number":1,"url":"https://github.com/a/b/pull/1","state":"MERGED",
                 "mergeCommit":{"oid":"0123456789abcdef"},
                 "repository":{"nameWithOwner":"a/b"}}},
          "pr1":{"pullRequest":{"number":2,"url":"https://github.com/a/b/pull/2","state":"OPEN",
                 "mergeCommit":null,
                 "repository":{"nameWithOwner":"a/b"}}}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let merged = PRRef(owner: "a", repo: "b", number: 1)
        let open = PRRef(owner: "a", repo: "b", number: 2)
        let states = try await backend.prStates(refs: [merged, open])
        XCTAssertEqual(states[merged]?.mergeCommitOid, "0123456789abcdef")
        XCTAssertNil(states[open]?.mergeCommitOid)
        // The query now requests the merge commit.
        XCTAssertTrue(fake.calls[0].args.contains { $0.contains("mergeCommit { oid }") })
    }

    func testGitHubCodeBackendFetchRecentDefaultBranchCommitsBuildsSinceEndpointAndParses() async throws {
        let fake = FakeShellRunner()
        let json = """
        [
          {"sha":"beef123","commit":{"message":"Revert \\"x\\"\\n\\nThis reverts commit abc1234."}},
          {"sha":"feed456","commit":{"message":"feat: y"}}
        ]
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let commits = try await backend.fetchRecentDefaultBranchCommits(
            repoSlug: "a/b",
            since: Date(timeIntervalSince1970: 1_752_000_000)
        )
        XCTAssertEqual(commits.count, 2)
        XCTAssertEqual(commits[0].sha, "beef123")
        XCTAssertTrue(commits[0].message.contains("This reverts commit"))
        XCTAssertEqual(fake.calls.count, 1)
        let endpoint = fake.calls[0].args.last ?? ""
        XCTAssertTrue(endpoint.hasPrefix("/repos/a/b/commits?since=2025-07-08T"))
        XCTAssertTrue(endpoint.contains("per_page=100"))
    }

    func testGitHubCodeBackendFetchPRChangedFilesParsesFilenames() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"[{"filename":"Sources/App/Foo.swift"},{"filename":"README.md"},{"status":"no filename key"}]"#)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let files = try await backend.fetchPRChangedFiles(repoSlug: "a/b", prNumber: 7)
        XCTAssertEqual(files, ["Sources/App/Foo.swift", "README.md"])
        XCTAssertEqual(fake.calls[0].args.last, "/repos/a/b/pulls/7/files?per_page=100")
    }

    func testNonGitHubBackendsInheritReworkFetchNoOps() async throws {
        // GitLab inherits the protocol defaults — revert scan and file
        // overlap degrade to no data, no calls.
        let fake = FakeShellRunner()
        let backend = GitLabCodeBackend(shellRunner: fake, host: nil)
        let commits = try await backend.fetchRecentDefaultBranchCommits(repoSlug: "a/b", since: Date())
        let files = try await backend.fetchPRChangedFiles(repoSlug: "a/b", prNumber: 1)
        XCTAssertTrue(commits.isEmpty)
        XCTAssertTrue(files.isEmpty)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testGitHubCodeBackendEnableAutoMergeRunsGhPrMerge() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubCodeBackend(shellRunner: fake)
        try await backend.enableAutoMerge(prURL: "https://github.com/a/b/pull/1")
        XCTAssertEqual(fake.calls.count, 1)
        // Direct argv (not sh -c) into NSTemporaryDirectory — no shell
        // interpolation surface around prURL.
        XCTAssertEqual(fake.calls[0].args.prefix(3), ArraySlice(["gh", "pr", "merge"]))
        XCTAssertTrue(fake.calls[0].args.contains("--auto"))
        XCTAssertTrue(fake.calls[0].args.contains("https://github.com/a/b/pull/1"))
        XCTAssertEqual(fake.calls[0].cwd, NSTemporaryDirectory())
    }

    func testGitHubCodeBackendUpdateBranchRunsGhPrUpdateBranch() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubCodeBackend(shellRunner: fake)
        try await backend.updateBranch(prURL: "https://github.com/a/b/pull/1")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].args, ["gh", "pr", "update-branch", "https://github.com/a/b/pull/1"])
        XCTAssertEqual(fake.calls[0].cwd, NSTemporaryDirectory())
    }

    func testGitHubCodeBackendFetchPRMetadataParses() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"{"title":"PR Title","number":7,"headRefName":"f","headRefOid":"abc","baseRefName":"main"}"#)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let meta = try await backend.fetchPRMetadata(prURL: "https://github.com/a/b/pull/7")
        XCTAssertEqual(meta.title, "PR Title")
        XCTAssertEqual(meta.number, 7)
        XCTAssertEqual(meta.headRefName, "f")
        XCTAssertEqual(meta.baseRefName, "main")
    }

    func testGitHubCodeBackendFindRecentPRsForBranchesParses() async throws {
        let fake = FakeShellRunner()
        let json = """
        {"data":{
          "pr0":{"pullRequests":{"nodes":[
            {"number":7,"url":"https://github.com/a/b/pull/7","state":"OPEN","updatedAt":"2026-01-01T00:00:00Z","headRefName":"feature/x"}
          ]}}
        }}
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let matches = try await backend.findRecentPRsForBranches([
            BranchCandidate(repoSlug: "a/b", branch: "feature/x")
        ])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].number, 7)
        XCTAssertEqual(matches[0].state, "OPEN")
        XCTAssertEqual(matches[0].candidate.branch, "feature/x")
    }

    func testGitHubCodeBackendFindPRsMatchingKeysParsesAndFilters() async throws {
        let fake = FakeShellRunner()
        // Four PRs returned by gh search:
        //  #52 — key in title AND head → kept
        //  #53 — key in head only (title/body unrelated) → kept
        //  #41 — key in body ONLY → rejected (#520: a body mention belongs to a
        //        different ticket; matching it attached phantom PRs)
        //  #40 — key nowhere → rejected
        let json = """
        [
          {"number":52,"url":"https://github.com/a/b/pull/52","state":"OPEN","updatedAt":"2026-01-02T00:00:00Z","title":"feat: thing. MAXX-6859","headRefName":"feature/maxx-6859-thing","body":"closes MAXX-6859"},
          {"number":53,"url":"https://github.com/a/b/pull/53","state":"OPEN","updatedAt":"2026-01-03T00:00:00Z","title":"feat: unrelated title","headRefName":"feature/maxx-6859-other","body":"no mention"},
          {"number":41,"url":"https://github.com/a/b/pull/41","state":"MERGED","updatedAt":"2026-01-01T00:00:00Z","title":"different ticket","headRefName":"feature/other-work","body":"related to MAXX-6859"},
          {"number":40,"url":"https://github.com/a/b/pull/40","state":"MERGED","updatedAt":"2026-01-01T00:00:00Z","title":"unrelated","headRefName":"feature/other","body":"no key here"}
        ]
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let matches = try await backend.findPRsMatchingKeys([
            KeyCandidate(repoSlug: "a/b", key: "MAXX-6859")
        ])
        XCTAssertEqual(Set(matches.map(\.number)), [52, 53])
        XCTAssertTrue(matches.allSatisfy { $0.candidate.key == "MAXX-6859" })
        // Command shape: gh pr list --search "<key> in:title,body" (broad recall;
        // results are post-filtered to title/head only).
        let args = fake.calls[0].args
        XCTAssertEqual(Array(args.prefix(3)), ["gh", "pr", "list"])
        XCTAssertTrue(args.contains("--search"))
        XCTAssertTrue(args.contains("MAXX-6859 in:title,body"))
        XCTAssertTrue(args.contains("a/b"))
    }

    func testGitHubCodeBackendFindPRsMatchingKeysSkipsFailedRepo() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "no auth"))]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let matches = try await backend.findPRsMatchingKeys([
            KeyCandidate(repoSlug: "a/b", key: "MAXX-6859")
        ])
        XCTAssertTrue(matches.isEmpty)
    }

    // MARK: - GitLab backends

    func testGitLabTaskBackendDeclaresNoCapabilities() {
        let backend = GitLabTaskBackend(shellRunner: FakeShellRunner(), host: nil)
        XCTAssertEqual(backend.provider, .gitlab)
        XCTAssertTrue(backend.capabilities.isEmpty)
    }

    func testGitLabTaskBackendFetchTaskInvokesGlab() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("Issue title")]
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.internal.io")
        let info = try await backend.fetchTask(url: "https://gitlab.internal.io/group/proj/-/issues/3")
        XCTAssertEqual(info.title, "Issue title")
        XCTAssertEqual(info.number, 3)
        XCTAssertEqual(info.provider, .gitlab)
        XCTAssertEqual(fake.calls.first?.args.first, "glab")
        XCTAssertEqual(fake.calls.first?.env["GITLAB_HOST"], "gitlab.internal.io")
        // #696: GitLab carries no ticket priority/epic — nil, not an error.
        XCTAssertNil(info.priority)
        XCTAssertNil(info.parentKey)
    }

    func testGitLabTaskBackendListAssignedIssuesParses() async throws {
        let fake = FakeShellRunner()
        let openJSON = """
        [{"iid":7,"title":"Open MR","web_url":"https://gitlab.example.com/g/p/-/issues/7","state":"opened",
          "labels":["bug"],"references":{"full":"g/p#7"}}]
        """
        let closedJSON = """
        [{"iid":3,"title":"Closed","web_url":"https://gitlab.example.com/g/p/-/issues/3","state":"closed",
          "labels":[],"references":{"full":"g/p#3"}}]
        """
        let closedResponse = "HTTP/2.0 200 OK\nContent-Type: application/json\nX-Total: 137\n\n" + closedJSON
        fake.responses = [.success(openJSON), .success(closedResponse)]
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.example.com")
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 1)
        XCTAssertEqual(listing.open[0].title, "Open MR")
        XCTAssertEqual(listing.open[0].state, "open")
        XCTAssertEqual(listing.closed.count, 1)
        XCTAssertEqual(listing.closed[0].projectStatus, .done)
        // #697: the done badge uses the X-Total window total, not the capped page.
        XCTAssertEqual(listing.closedTotalCount, 137)
        XCTAssertNil(listing.rateLimit)  // GitLab doesn't have rate-limit JSON in this shape
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertTrue(fake.calls[1].args.contains("-i"))
    }

    func testGitLabTaskBackendClosedTotalFallsBackToPageCountWithoutHeader() async throws {
        let fake = FakeShellRunner()
        let openJSON = "[]"
        let closedJSON = #"[{"iid":3,"title":"Closed","web_url":"https://gl/g/p/-/issues/3","state":"closed","labels":[],"references":{"full":"g/p#3"}}]"#
        // Headers present but no X-Total (GitLab omits it for expensive counts).
        let closedResponse = "HTTP/2.0 200 OK\nContent-Type: application/json\n\n" + closedJSON
        fake.responses = [.success(openJSON), .success(closedResponse)]
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.example.com")
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.closed.count, 1)
        XCTAssertEqual(listing.closedTotalCount, 1)
    }

    func testGitLabTaskBackendClosedCallFailureKeepsOpen() async throws {
        let fake = FakeShellRunner()
        let openJSON = #"[{"iid":7,"title":"Open","web_url":"https://gl/g/p/-/issues/7","state":"opened","labels":[],"references":{"full":"g/p#7"}}]"#
        fake.responses = [.success(openJSON), .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "boom"))]
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.example.com")
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 1)
        XCTAssertEqual(listing.closed.count, 0)
        XCTAssertEqual(listing.closedTotalCount, 0)
    }

    func testGitLabSplitTotalHeader() {
        // CRLF endings + case-insensitive header name.
        let crlf = "HTTP/2.0 200 OK\r\nx-total: 42\r\n\r\n[{\"iid\":1}]"
        let parsedCRLF = GitLabTaskBackend.splitTotalHeader(crlf)
        XCTAssertEqual(parsedCRLF.total, 42)
        XCTAssertEqual(parsedCRLF.body, "[{\"iid\":1}]")

        // No blank line → treated as bare body, no total.
        let bare = #"[{"iid":1}]"#
        let parsedBare = GitLabTaskBackend.splitTotalHeader(bare)
        XCTAssertNil(parsedBare.total)
        XCTAssertEqual(parsedBare.body, bare)

        // Non-numeric X-Total is ignored.
        let junk = "HTTP/2.0 200 OK\nX-Total: lots\n\n[]"
        XCTAssertNil(GitLabTaskBackend.splitTotalHeader(junk).total)
    }

    func testGitLabTaskBackendListAssignedSkipsClosedCallWhenNotRequested() async throws {
        // Regression guard: passing includeClosed: false must skip the second
        // REST round-trip for callers that only need the open list.
        let fake = FakeShellRunner()
        let openJSON = #"[{"iid":7,"title":"Open","web_url":"https://gl/g/p/-/issues/7","state":"opened","labels":[],"references":{"full":"g/p#7"}}]"#
        fake.responses = [.success(openJSON)]
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.example.com")
        let listing = try await backend.listAssigned(includeClosed: false)
        XCTAssertEqual(listing.open.count, 1)
        XCTAssertEqual(listing.closed.count, 0)
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testGitLabTaskBackendAssignInvokesGlabIssueUpdate() async throws {
        let fake = FakeShellRunner()
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.example.com")
        try await backend.assign(url: "https://gitlab.example.com/g/p/-/issues/7", to: "alice")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(fake.calls[0].args.contains("--assignee"))
        XCTAssertTrue(fake.calls[0].args.contains("alice"))
    }

    func testGitLabTaskBackendCloseTaskRunsGlabIssueClose() async throws {
        let fake = FakeShellRunner()
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.example.com")
        try await backend.closeTask(url: "https://gitlab.example.com/g/p/-/issues/7")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertEqual(fake.calls[0].args, ["glab", "issue", "close", "7", "--repo", "g/p"])
        XCTAssertEqual(fake.calls[0].env["GITLAB_HOST"], "gitlab.example.com")
    }

    func testGitLabTaskBackendSetTaskStatusThrowsUnimplemented() async {
        let backend = GitLabTaskBackend(shellRunner: FakeShellRunner(), host: nil)
        do {
            try await backend.setTaskStatus(url: "https://gitlab.example.com/g/p/-/issues/1", status: .inReview)
            XCTFail("expected throw")
        } catch ProviderError.unimplemented {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGitLabCodeBackendEnsureMergeLabelThrowsUnimplemented() async {
        let backend = GitLabCodeBackend(shellRunner: FakeShellRunner(), host: nil)
        do {
            try await backend.ensureMergeLabel(repo: "a/b")
            XCTFail("expected throw")
        } catch ProviderError.unimplemented {
            // expected — GitLab has no autoMergeLabel capability today
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGitLabCodeBackendEnableAutoMergeThrowsUnimplemented() async {
        let backend = GitLabCodeBackend(shellRunner: FakeShellRunner(), host: nil)
        do {
            try await backend.enableAutoMerge(prURL: "https://gitlab.example.com/g/p/-/merge_requests/1")
            XCTFail("expected throw")
        } catch ProviderError.unimplemented {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGitLabCodeBackendUpdateBranchThrowsUnimplemented() async {
        let backend = GitLabCodeBackend(shellRunner: FakeShellRunner(), host: nil)
        do {
            try await backend.updateBranch(prURL: "https://gitlab.example.com/g/p/-/merge_requests/1")
            XCTFail("expected throw")
        } catch ProviderError.unimplemented {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testGitLabCodeBackendPRStatesPerMR() async throws {
        let fake = FakeShellRunner()
        let json = #"{"iid":3,"web_url":"https://gitlab.example.com/g/p/-/merge_requests/3","state":"merged","source_branch":"f","target_branch":"main","sha":"abc"}"#
        fake.responses = [.success(json)]
        let backend = GitLabCodeBackend(shellRunner: fake, host: "gitlab.example.com")
        let ref = PRRef(owner: "g", repo: "p", number: 3)
        let states = try await backend.prStates(refs: [ref])
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[ref]?.state, "MERGED")
        XCTAssertEqual(fake.calls.count, 1)
    }

    func testGitLabCodeBackendFetchPRMetadataParses() async throws {
        let fake = FakeShellRunner()
        let json = #"{"iid":3,"title":"MR","source_branch":"f","sha":"abc","target_branch":"main"}"#
        fake.responses = [.success(json)]
        let backend = GitLabCodeBackend(shellRunner: fake, host: "gitlab.example.com")
        let meta = try await backend.fetchPRMetadata(prURL: "https://gitlab.example.com/g/p/-/merge_requests/3")
        XCTAssertEqual(meta.title, "MR")
        XCTAssertEqual(meta.number, 3)
        XCTAssertEqual(meta.headRefName, "f")
    }

    // MARK: - Factory

    func testProviderManagerHandsOutMatchingBackends() async {
        let mgr = ProviderManager()
        XCTAssertEqual(mgr.taskBackend(for: .github).provider, .github)
        XCTAssertEqual(mgr.taskBackend(for: .gitlab, host: "gitlab.com").provider, .gitlab)
        XCTAssertEqual(mgr.taskBackend(for: .corveil).provider, .corveil)
        XCTAssertNotNil(mgr.codeBackend(for: .github))
        XCTAssertNotNil(mgr.codeBackend(for: .gitlab))
        XCTAssertNil(mgr.codeBackend(for: .corveil))
    }

    func testProviderManagerTaskBackendForCorveilURL() async {
        let mgr = ProviderManager()
        let backend = mgr.taskBackend(forURL: "https://corveil.io/tasks/42")
        XCTAssertEqual(backend.provider, .corveil)
    }

    // MARK: - parseMonitoredPRsResponse timestamps (CROW-508)

    /// Pre-CROW-508 we picked the latest CR review's *id* for round-2 dedup.
    /// The stateless "needs refine" rule needs the *timestamp* of that same
    /// review — anchor for "since when does the agent owe a response?".
    /// The parser must pick the max `submittedAt` across CHANGES_REQUESTED
    /// reviews, not the first one in array order.
    func testParseMonitoredPRsPicksLatestChangesRequestedTimestamp() throws {
        let json = """
        {
          "data": {
            "viewerPRs": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 7,
                    "url": "https://github.com/a/b/pull/7",
                    "state": "OPEN",
                    "reviewDecision": "CHANGES_REQUESTED",
                    "headRefOid": "deadbeef",
                    "latestReviews": {
                      "nodes": [
                        {"id": "R_old",   "state": "CHANGES_REQUESTED", "submittedAt": "2026-06-01T10:00:00Z"},
                        {"id": "R_newer", "state": "APPROVED",          "submittedAt": "2026-06-05T10:00:00Z"},
                        {"id": "R_newest","state": "CHANGES_REQUESTED", "submittedAt": "2026-06-07T10:00:00Z"},
                        {"id": "R_mid",   "state": "CHANGES_REQUESTED", "submittedAt": "2026-06-03T10:00:00Z"}
                      ]
                    }
                  }
                ]
              }
            },
            "reviewPRs": {"nodes": []},
            "viewer": {"login": "me"},
            "rateLimit": {"remaining": 5000, "limit": 5000, "resetAt": "2026-06-08T17:00:00Z", "cost": 1}
          }
        }
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        XCTAssertEqual(listing.viewerPRs.count, 1)
        // Construct the expected instant from epoch seconds — NOT from the
        // same ISO8601DateFormatter the parser uses. A bug where the
        // production formatter returns nil (CROW-508 PR #509 review) would
        // pass the previous version of this assertion because both sides
        // were nil. Epoch construction eliminates that co-failure mode.
        // 2026-06-07T10:00:00Z = 1780826400 seconds since 1970.
        let expected = Date(timeIntervalSince1970: 1780826400)
        XCTAssertEqual(listing.viewerPRs[0].lastChangesRequestedAt, expected)
    }

    func testParseMonitoredPRsLastChangesRequestedAtIsNilWhenNoChangesRequested() throws {
        let json = """
        {
          "data": {
            "viewerPRs": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 9,
                    "url": "https://github.com/a/b/pull/9",
                    "state": "OPEN",
                    "reviewDecision": "APPROVED",
                    "headRefOid": "abc",
                    "latestReviews": {
                      "nodes": [
                        {"id": "R_ok", "state": "APPROVED", "submittedAt": "2026-06-07T10:00:00Z"}
                      ]
                    }
                  }
                ]
              }
            },
            "reviewPRs": {"nodes": []},
            "viewer": {"login": "me"},
            "rateLimit": {"remaining": 5000, "limit": 5000, "resetAt": "2026-06-08T17:00:00Z", "cost": 1}
          }
        }
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        XCTAssertEqual(listing.viewerPRs.count, 1)
        XCTAssertNil(listing.viewerPRs[0].lastChangesRequestedAt)
    }

    /// Locks down GitHub's actual `DateTime` shape (no fractional seconds)
    /// parsing to a non-nil value. The original CROW-508 patch used
    /// `[.withInternetDateTime, .withFractionalSeconds]` which is strict
    /// and rejects this format — feature was silently inert in production.
    /// PR #509 review caught it. This test will fail loudly if a future
    /// regression re-introduces the strict formatter.
    func testParseGitHubDateTimeHandlesNonFractionalISO8601() {
        // GitHub's actual format — no fraction.
        let nonFractional = GitHubCodeBackend.parseGitHubDateTime("2026-06-15T01:28:17Z")
        XCTAssertNotNil(nonFractional)
        XCTAssertEqual(nonFractional, Date(timeIntervalSince1970: 1781486897))
    }

    /// Resilience against potential future API drift: a timestamp WITH a
    /// fractional component must also parse. Both shapes flow through the
    /// same helper.
    func testParseGitHubDateTimeAlsoHandlesFractionalISO8601() {
        let withFraction = GitHubCodeBackend.parseGitHubDateTime("2026-06-15T01:28:17.123Z")
        XCTAssertNotNil(withFraction)
    }

    /// Garbage input returns nil, doesn't crash.
    func testParseGitHubDateTimeReturnsNilForGarbage() {
        XCTAssertNil(GitHubCodeBackend.parseGitHubDateTime("not a date"))
        XCTAssertNil(GitHubCodeBackend.parseGitHubDateTime(""))
    }

    /// Merge commits (parents.totalCount >= 2) and rebase-style commits
    /// matching the merge-message prefix list must NOT advance the
    /// "agent substantively responded" timestamp. Otherwise pressing
    /// GitHub's "Update branch" button (default merge mode) or rebasing
    /// onto main with a merge commit would fool the rule into thinking the
    /// agent pushed a fix.
    ///
    /// The rebase gap this used to disclaim is closed — see
    /// `testParseMonitoredPRsRebaseRestampDoesNotAdvanceSubstantiveCommit`.
    func testParseMonitoredPRsLastSubstantiveCommitExcludesMergeCommits() throws {
        let json = """
        {
          "data": {
            "viewerPRs": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 10,
                    "url": "https://github.com/a/b/pull/10",
                    "state": "OPEN",
                    "reviewDecision": "CHANGES_REQUESTED",
                    "headRefOid": "abc",
                    "latestReviews": {"nodes": []},
                    "commits": {
                      "nodes": [
                        {"commit": {"oid": "1", "messageHeadline": "real fix",
                                    "committedDate": "2026-06-01T00:00:00Z",
                                    "authoredDate": "2026-06-01T00:00:00Z",
                                    "parents": {"totalCount": 1}}},
                        {"commit": {"oid": "2", "messageHeadline": "Merge branch 'main' into feature",
                                    "committedDate": "2026-06-05T00:00:00Z",
                                    "authoredDate": "2026-06-05T00:00:00Z",
                                    "parents": {"totalCount": 2}}},
                        {"commit": {"oid": "3", "messageHeadline": "Merge remote-tracking branch 'upstream/main'",
                                    "committedDate": "2026-06-06T00:00:00Z",
                                    "authoredDate": "2026-06-06T00:00:00Z",
                                    "parents": {"totalCount": 2}}},
                        {"commit": {"oid": "4", "messageHeadline": "Merge pull request #99",
                                    "committedDate": "2026-06-07T00:00:00Z",
                                    "authoredDate": "2026-06-07T00:00:00Z",
                                    "parents": {"totalCount": 2}}}
                      ]
                    }
                  }
                ]
              }
            },
            "reviewPRs": {"nodes": []},
            "viewer": {"login": "me"},
            "rateLimit": {"remaining": 5000, "limit": 5000, "resetAt": "2026-06-08T17:00:00Z", "cost": 1}
          }
        }
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        XCTAssertEqual(listing.viewerPRs.count, 1)
        // Only the real fix commit counts; merges are excluded. Constructed
        // from epoch seconds for the same anti-co-failure reason as the
        // CHANGES_REQUESTED timestamp test above.
        // 2026-06-01T00:00:00Z = 1780272000.
        XCTAssertEqual(listing.viewerPRs[0].lastSubstantiveCommitAt, Date(timeIntervalSince1970: 1780272000))
    }

    /// CROW-921: the rebase restamp. A `git rebase` replays the feature
    /// commits with their *committer* date rewritten to ~now while preserving
    /// the author date. Those commits aren't merge commits, so under the old
    /// committer-date rule they advanced `lastSubstantiveCommitAt` and
    /// needs-refine read a rebase as "the agent pushed a fix" — the false
    /// negative that let a fixed-but-unrequested PR park in CHANGES_REQUESTED
    /// forever.
    ///
    /// The fixture is the shape observed live on `corveil/corveil#1898`:
    /// every feature commit sharing one committer timestamp from a single
    /// rebase, author dates spread across the original working session.
    func testParseMonitoredPRsRebaseRestampDoesNotAdvanceSubstantiveCommit() throws {
        let json = """
        {
          "data": {
            "viewerPRs": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 1898,
                    "url": "https://github.com/a/b/pull/1898",
                    "state": "OPEN",
                    "reviewDecision": "CHANGES_REQUESTED",
                    "headRefOid": "abc",
                    "latestReviews": {"nodes": []},
                    "commits": {
                      "nodes": [
                        {"commit": {"oid": "1", "messageHeadline": "fix one",
                                    "committedDate": "2026-06-10T00:00:00Z",
                                    "authoredDate": "2026-06-01T00:00:00Z",
                                    "parents": {"totalCount": 1}}},
                        {"commit": {"oid": "2", "messageHeadline": "fix two",
                                    "committedDate": "2026-06-10T00:00:00Z",
                                    "authoredDate": "2026-06-02T00:00:00Z",
                                    "parents": {"totalCount": 1}}}
                      ]
                    }
                  }
                ]
              }
            },
            "reviewPRs": {"nodes": []},
            "viewer": {"login": "me"}
          }
        }
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        let pr = try XCTUnwrap(listing.viewerPRs.first)
        // 2026-06-02T00:00:00Z = 1780358400 — the later *author* date, not the
        // 2026-06-10 rebase stamp both commits now carry.
        XCTAssertEqual(pr.lastSubstantiveCommitAt, Date(timeIntervalSince1970: 1780358400))
    }

    /// CROW-921: who is blocking the PR, and has anyone been asked to look
    /// again. `latestReviews` is one review per author, so filtering to
    /// CHANGES_REQUESTED names exactly the reviewers whose verdict stands.
    func testParseMonitoredPRsReviewerLoginsAndPendingRequest() throws {
        let json = """
        {
          "data": {
            "viewerPRs": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 11,
                    "url": "https://github.com/a/b/pull/11",
                    "state": "OPEN",
                    "reviewDecision": "CHANGES_REQUESTED",
                    "headRefOid": "abc",
                    "latestReviews": {"nodes": [
                      {"author": {"login": "dgershman"}, "state": "CHANGES_REQUESTED",
                       "submittedAt": "2026-06-07T10:00:00Z"},
                      {"author": {"login": "approver"}, "state": "APPROVED",
                       "submittedAt": "2026-06-07T11:00:00Z"},
                      null,
                      {"author": null, "state": "CHANGES_REQUESTED",
                       "submittedAt": "2026-06-07T12:00:00Z"}
                    ]},
                    "reviewRequests": {"totalCount": 0, "nodes": []},
                    "commits": {"nodes": []}
                  },
                  {
                    "number": 12,
                    "url": "https://github.com/a/b/pull/12",
                    "state": "OPEN",
                    "reviewDecision": "CHANGES_REQUESTED",
                    "headRefOid": "def",
                    "latestReviews": {"nodes": []},
                    "reviewRequests": {"totalCount": 1, "nodes": [
                      {"requestedReviewer": {"__typename": "User", "login": "dgershman"}}
                    ]},
                    "commits": {"nodes": []}
                  },
                  {
                    "number": 13,
                    "url": "https://github.com/a/b/pull/13",
                    "state": "OPEN",
                    "headRefOid": "ghi",
                    "commits": {"nodes": []}
                  },
                  {
                    "number": 14,
                    "url": "https://github.com/a/b/pull/14",
                    "state": "OPEN",
                    "reviewDecision": "CHANGES_REQUESTED",
                    "headRefOid": "jkl",
                    "latestReviews": {"nodes": [
                      {"author": {"login": "a"}, "state": "CHANGES_REQUESTED",
                       "submittedAt": "2026-06-07T10:00:00Z"}
                    ]},
                    "reviewRequests": {"totalCount": 2, "nodes": [
                      null,
                      {"requestedReviewer": {"__typename": "User", "login": "b"}},
                      {"requestedReviewer": {"__typename": "Team", "slug": "reviewers"}}
                    ]},
                    "commits": {"nodes": []}
                  }
                ]
              }
            },
            "reviewPRs": {"nodes": []},
            "viewer": {"login": "me"}
          }
        }
        """
        let listing = try GitHubCodeBackend.parseMonitoredPRsResponse(json)
        XCTAssertEqual(listing.viewerPRs.count, 4)
        // Only the CHANGES_REQUESTED author; the approver and the null-author
        // node are dropped rather than producing an empty-string reviewer.
        XCTAssertEqual(listing.viewerPRs[0].changesRequestedReviewerLogins, ["dgershman"])
        XCTAssertFalse(listing.viewerPRs[0].hasPendingReviewRequest)
        XCTAssertEqual(listing.viewerPRs[0].pendingReviewerLogins, [])
        // The live GitHub shape for "awaiting reviewer": the re-request
        // emptied `latestReviews` while reviewDecision still says
        // CHANGES_REQUESTED.
        XCTAssertTrue(listing.viewerPRs[1].hasPendingReviewRequest)
        XCTAssertEqual(listing.viewerPRs[1].pendingReviewerLogins, ["dgershman"])
        XCTAssertEqual(listing.viewerPRs[1].changesRequestedReviewerLogins, [])
        // Field absent entirely (stale-PR follow-up query shape) reads as
        // "no pending request", never as a crash or a nil-vs-false confusion.
        XCTAssertFalse(listing.viewerPRs[2].hasPendingReviewRequest)
        XCTAssertEqual(listing.viewerPRs[2].pendingReviewerLogins, [])
        // The multi-reviewer shape (review of #930): A blocks and is visible,
        // B is still pending from the original request, and a Team request is
        // visible only through `totalCount` — a Team carries no login, and
        // folding a slug into the login list would risk colliding with a real
        // user. Nulls survive via LenientJSON, as everywhere else.
        XCTAssertEqual(listing.viewerPRs[3].changesRequestedReviewerLogins, ["a"])
        XCTAssertEqual(listing.viewerPRs[3].pendingReviewerLogins, ["b"])
        XCTAssertTrue(listing.viewerPRs[3].hasPendingReviewRequest)
    }

    /// A login that could be read as a `gh` flag must never reach argv.
    /// Direct argv already rules out shell metacharacters; this closes flag
    /// injection, the one thing it doesn't cover.
    func testIsSafeReviewerLogin() {
        XCTAssertTrue(GitHubCodeBackend.isSafeReviewerLogin("dgershman"))
        XCTAssertTrue(GitHubCodeBackend.isSafeReviewerLogin("a-b-c9"))
        XCTAssertFalse(GitHubCodeBackend.isSafeReviewerLogin(""))
        XCTAssertFalse(GitHubCodeBackend.isSafeReviewerLogin("--add-label"))
        XCTAssertFalse(GitHubCodeBackend.isSafeReviewerLogin("-x"))
        XCTAssertFalse(GitHubCodeBackend.isSafeReviewerLogin("foo bar"))
        XCTAssertFalse(GitHubCodeBackend.isSafeReviewerLogin("foo/bar"))
        XCTAssertFalse(GitHubCodeBackend.isSafeReviewerLogin(String(repeating: "a", count: 40)))
    }

    /// Pure helper used by `parsePRNode`. Both Swift and tests share the
    /// same prefix list so a future addition stays in sync.
    func testIsMergeCommitMessage() {
        XCTAssertTrue(GitHubCodeBackend.isMergeCommitMessage("Merge branch 'main' into feature/x"))
        XCTAssertTrue(GitHubCodeBackend.isMergeCommitMessage("Merge remote-tracking branch 'upstream/main'"))
        XCTAssertTrue(GitHubCodeBackend.isMergeCommitMessage("Merge pull request #42 from foo/bar"))
        XCTAssertFalse(GitHubCodeBackend.isMergeCommitMessage("merge branch"))                 // case-sensitive prefix
        XCTAssertFalse(GitHubCodeBackend.isMergeCommitMessage("Merge two records into one"))   // not a merge prefix
        XCTAssertFalse(GitHubCodeBackend.isMergeCommitMessage("Fix authentication bug"))
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected throw", file: file, line: line)
    } catch {
        // expected
    }
}
