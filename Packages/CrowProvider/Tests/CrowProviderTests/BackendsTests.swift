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
        // `.projectBoardStatus` declares the UI surface (GitHub Projects v2).
        // The `setTaskStatus` GraphQL migration is still pending — execution
        // currently routes through IssueTracker.markInReview via the
        // onMarkInReview closure, so direct `setTaskStatus` calls on this
        // backend still throw .unimplemented (asserted by
        // testGitHubTaskBackendSetTaskStatusThrowsUnimplemented). See ADR 0005
        // and issue crow#413 for the UI guard migration.
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

    func testGitHubTaskBackendSetTaskStatusThrowsUnimplemented() async {
        let backend = GitHubTaskBackend(shellRunner: FakeShellRunner())
        do {
            try await backend.setTaskStatus(url: "https://github.com/a/b/issues/1", status: .inReview)
            XCTFail("expected throw")
        } catch ProviderError.unimplemented {
            // expected — see ADR 0005, migration deferred
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - GitHubCodeBackend

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

    // MARK: - Stub Corveil

    func testStubCorveilTaskBackendThrowsUnimplementedForEveryMethod() async {
        let backend = StubCorveilTaskBackend()
        XCTAssertEqual(backend.provider, .corveil)
        XCTAssertTrue(backend.capabilities.isEmpty)
        await XCTAssertThrowsErrorAsync(try await backend.fetchTask(url: "https://corveil.io/t/1"))
        await XCTAssertThrowsErrorAsync(try await backend.setLabels(url: "x", add: ["a"], remove: []))
        await XCTAssertThrowsErrorAsync(try await backend.setTaskStatus(url: "x", status: .inReview))
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
