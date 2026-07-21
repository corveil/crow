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

    func testListMonitoredPRsRecoversAccessiblePRsOnSAML() async throws {
        let blob = """
        {"data":{
          "viewerPRs":{"pullRequests":{"nodes":[
            {"number":12,"url":"https://github.com/ok/repo/pull/12","state":"OPEN",
             "headRefName":"feat","baseRefName":"main","repository":{"nameWithOwner":"ok/repo"}}
          ]}},
          "reviewPRs":{"nodes":[]},
          "viewer":{"login":"me"},
          "rateLimit":{"remaining":4980,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":1}
        },"errors":[{"type":"FORBIDDEN","message":"Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise."}]}
        gh: Resource protected by organization SAML enforcement. You must grant your OAuth token access to an organization within this enterprise.
        """
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: blob))]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let listing = try await backend.listMonitoredPRs()
        XCTAssertTrue(listing.samlRestricted)
        XCTAssertEqual(listing.viewerPRs.count, 1)
        XCTAssertEqual(listing.viewerPRs.first?.number, 12)
        XCTAssertEqual(listing.viewerLogin, "me")
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
    /// Known gap (documented in `parsePRNode`): a real `git rebase` rewrites
    /// the *committer* date of the feature commits themselves. Those commits
    /// are not merge commits, so they pass the filter and DO advance
    /// `lastSubstantiveCommitAt`. This test does not cover that path; the
    /// stateless rule accepts the false negative as the cost of not paying
    /// for a tree-equals-parents API call per PR per poll.
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
                                    "parents": {"totalCount": 1}}},
                        {"commit": {"oid": "2", "messageHeadline": "Merge branch 'main' into feature",
                                    "committedDate": "2026-06-05T00:00:00Z",
                                    "parents": {"totalCount": 2}}},
                        {"commit": {"oid": "3", "messageHeadline": "Merge remote-tracking branch 'upstream/main'",
                                    "committedDate": "2026-06-06T00:00:00Z",
                                    "parents": {"totalCount": 2}}},
                        {"commit": {"oid": "4", "messageHeadline": "Merge pull request #99",
                                    "committedDate": "2026-06-07T00:00:00Z",
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
