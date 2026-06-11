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
          "closedIssues":{"nodes":[
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
        XCTAssertEqual(listing.rateLimit?.remaining, 4999)
        XCTAssertEqual(fake.calls.first?.args[0], "gh")
        XCTAssertTrue(fake.calls.first?.args.contains("graphql") ?? false)
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
        // No matching option.
        fake.responses = [.success(#"{"data":{"repository":{"issue":{"projectItems":{"nodes":[]}}}}}"#)]
        let backend = GitHubTaskBackend(shellRunner: fake)
        do {
            try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
            XCTFail("expected throw")
        } catch ProviderError.unimplemented {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
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

    func testGitHubTaskBackendAssignInvokesGhIssueEdit() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubTaskBackend(shellRunner: fake)
        try await backend.assign(url: "https://github.com/a/b/issues/1", to: "@me")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(fake.calls[0].args.contains("--add-assignee"))
        XCTAssertTrue(fake.calls[0].args.contains("@me"))
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
        // Two PRs returned by gh search: one references MAXX-6859 in its title,
        // one is a fuzzy match that mentions it nowhere — only the first counts.
        let json = """
        [
          {"number":52,"url":"https://github.com/a/b/pull/52","state":"OPEN","updatedAt":"2026-01-02T00:00:00Z","title":"feat: thing. MAXX-6859","headRefName":"feature/maxx-6859-thing","body":"closes MAXX-6859"},
          {"number":40,"url":"https://github.com/a/b/pull/40","state":"MERGED","updatedAt":"2026-01-01T00:00:00Z","title":"unrelated","headRefName":"feature/other","body":"no key here"}
        ]
        """
        fake.responses = [.success(json)]
        let backend = GitHubCodeBackend(shellRunner: fake)
        let matches = try await backend.findPRsMatchingKeys([
            KeyCandidate(repoSlug: "a/b", key: "MAXX-6859")
        ])
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].number, 52)
        XCTAssertEqual(matches[0].state, "OPEN")
        XCTAssertEqual(matches[0].candidate.key, "MAXX-6859")
        // Command shape: gh pr list --search "<key> in:title,body".
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
        fake.responses = [.success(openJSON), .success(closedJSON)]
        let backend = GitLabTaskBackend(shellRunner: fake, host: "gitlab.example.com")
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 1)
        XCTAssertEqual(listing.open[0].title, "Open MR")
        XCTAssertEqual(listing.open[0].state, "open")
        XCTAssertEqual(listing.closed.count, 1)
        XCTAssertEqual(listing.closed[0].projectStatus, .done)
        XCTAssertNil(listing.rateLimit)  // GitLab doesn't have rate-limit JSON in this shape
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testGitLabTaskBackendListAssignedSkipsClosedCallWhenNotRequested() async throws {
        // Regression guard: passing includeClosed: false must skip the second
        // REST round-trip. The IssueTracker GitLab path uses this to avoid a
        // wasted call every 60s — the closed-diff logic is GitHub-only.
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

    // MARK: - parseMonitoredPRsResponse latestReviewID (CROW-456)

    /// `latestReviews` connection has no documented order. The parser must
    /// pick the CHANGES_REQUESTED review with the latest `submittedAt`, not
    /// the first one in the array — otherwise round-2 dedup could miss a
    /// genuine new review (or worse, flip ids across polls and re-fire
    /// auto-respond for no reviewer action).
    func testParseMonitoredPRsPicksLatestSubmittedChangesRequestedReview() throws {
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
        XCTAssertEqual(listing.viewerPRs[0].latestReviewID, "R_newest")
    }

    /// When no review has a `submittedAt` (degraded payload), `max(by:)` over
    /// equal keys still returns an element rather than throwing — verify we
    /// at least don't crash and we do return one of the CHANGES_REQUESTED ids.
    func testParseMonitoredPRsLatestReviewIDDegradesGracefullyWithoutSubmittedAt() throws {
        let json = """
        {
          "data": {
            "viewerPRs": {
              "pullRequests": {
                "nodes": [
                  {
                    "number": 8,
                    "url": "https://github.com/a/b/pull/8",
                    "state": "OPEN",
                    "reviewDecision": "CHANGES_REQUESTED",
                    "headRefOid": "abc",
                    "latestReviews": {
                      "nodes": [
                        {"id": "R_a", "state": "CHANGES_REQUESTED"},
                        {"id": "R_b", "state": "CHANGES_REQUESTED"}
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
        XCTAssertNotNil(listing.viewerPRs[0].latestReviewID)
        XCTAssertTrue(["R_a", "R_b"].contains(listing.viewerPRs[0].latestReviewID))
    }

    func testParseMonitoredPRsLatestReviewIDIsNilWhenNoChangesRequested() throws {
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
        XCTAssertNil(listing.viewerPRs[0].latestReviewID)
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
