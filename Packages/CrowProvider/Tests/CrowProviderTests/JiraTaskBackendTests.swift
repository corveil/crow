import XCTest
import CrowCore
@testable import CrowProvider

/// Thread-safe mutable cell so a `@Sendable` transport closure can record what it
/// observed without tripping the concurrency checker.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    func set(_ value: T) { lock.lock(); _value = value; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return _value }
}

/// Exercises `JiraTaskBackend` against `FakeShellRunner` — the ADR 0005
/// testability bar. Asserts the exact `acli` argv for each method plus the JSON
/// parsing, key parsing, and status mapping, without spawning real `acli`.
final class JiraTaskBackendTests: XCTestCase {

    private func backend(_ fake: FakeShellRunner, config: JiraConfig = JiraConfig()) -> JiraTaskBackend {
        JiraTaskBackend(shellRunner: fake, config: config)
    }

    // MARK: - Capabilities

    func testDeclaresProjectBoardStatusOnly() {
        let b = backend(FakeShellRunner())
        XCTAssertEqual(b.provider, .jira)
        XCTAssertTrue(b.capabilities.contains(.projectBoardStatus))
        XCTAssertFalse(b.capabilities.contains(.batchedQuery))
    }

    // MARK: - JiraKey parsing

    func testJiraKeyParsesBrowseURL() {
        let parsed = JiraKey.parse("https://acme.atlassian.net/browse/PROJ-123")
        XCTAssertEqual(parsed?.project, "PROJ")
        XCTAssertEqual(parsed?.number, 123)
        XCTAssertEqual(parsed?.key, "PROJ-123")
    }

    func testJiraKeyParsesBareKeyAndStripsQuery() {
        XCTAssertEqual(JiraKey.parse("AB2-7")?.key, "AB2-7")
        XCTAssertEqual(JiraKey.parse("https://x.atlassian.net/browse/TEAM-9?focusedId=1")?.key, "TEAM-9")
        XCTAssertNil(JiraKey.parse("not-a-key"))
        XCTAssertNil(JiraKey.parse("PROJ-"))
    }

    // MARK: - fetchTask

    func testFetchTaskInvokesAcliViewAndParsesSummary() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"[{"key":"PROJ-42","fields":{"summary":"Fix the thing"}}]"#)]
        let b = backend(fake, config: JiraConfig(site: "acme.atlassian.net"))
        let info = try await b.fetchTask(url: "https://acme.atlassian.net/browse/PROJ-42")

        XCTAssertEqual(info.title, "Fix the thing")
        XCTAssertEqual(info.number, 42)
        XCTAssertEqual(info.org, "PROJ")
        XCTAssertEqual(info.repo, "PROJ")
        XCTAssertEqual(info.provider, .jira)
        XCTAssertFalse(info.isMR)
        XCTAssertEqual(info.url, "https://acme.atlassian.net/browse/PROJ-42")

        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["acli", "jira", "workitem", "view"])
        XCTAssertTrue(args.contains("PROJ-42"))
        XCTAssertTrue(args.contains("--json"))
        XCTAssertTrue(args.contains("--fields"))
    }

    func testFetchTaskRejectsUnparseableURL() async {
        do {
            _ = try await backend(FakeShellRunner()).fetchTask(url: "https://acme.atlassian.net/browse/")
            XCTFail("expected throw")
        } catch ProviderError.invalidURL {
            // expected
        } catch {
            XCTFail("expected invalidURL, got \(error)")
        }
    }

    // MARK: - listAssigned

    func testListAssignedParsesSearchResultsAndDefaultsJQL() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("""
        [
          {"key":"PROJ-1","fields":{"summary":"Open one","status":{"name":"In Progress","statusCategory":{"key":"indeterminate"}},"labels":["bug","crow:auto"]}},
          {"key":"PROJ-2","fields":{"summary":"Open two","status":{"name":"To Do","statusCategory":{"key":"new"}}}}
        ]
        """)]
        let b = backend(fake, config: JiraConfig(site: "acme.atlassian.net"))
        let listing = try await b.listAssigned(includeClosed: false)

        XCTAssertEqual(listing.open.count, 2)
        XCTAssertTrue(listing.closed.isEmpty)
        let first = listing.open[0]
        XCTAssertEqual(first.id, "jira:PROJ-1")
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.repo, "PROJ")
        XCTAssertEqual(first.provider, .jira)
        XCTAssertEqual(first.state, "open")
        XCTAssertEqual(first.projectStatus, .inProgress)
        XCTAssertEqual(first.url, "https://acme.atlassian.net/browse/PROJ-1")
        XCTAssertEqual(first.labels.map(\.name), ["bug", "crow:auto"])
        XCTAssertTrue(listing.open[1].labels.isEmpty)

        // Default JQL used; only one search call when includeClosed is false.
        XCTAssertEqual(fake.calls.count, 1)
        let args = fake.calls[0].args
        XCTAssertEqual(Array(args.prefix(4)), ["acli", "jira", "workitem", "search"])
        XCTAssertTrue(args.contains("--jql"))
        XCTAssertTrue(args.contains(JiraTaskBackend.defaultOpenJQL))
    }

    func testListAssignedHonorsConfiguredJQLAndClosedQuery() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("[]"), .success(#"[{"key":"PROJ-9","fields":{"summary":"Done one","status":{"name":"Done","statusCategory":{"key":"done"}}}}]"#)]
        let b = backend(fake, config: JiraConfig(site: "acme.atlassian.net", jql: "project = PROJ AND assignee = currentUser()"))
        let listing = try await b.listAssigned(includeClosed: true)

        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertTrue(fake.calls[0].args.contains("project = PROJ AND assignee = currentUser()"))
        XCTAssertTrue(fake.calls[1].args.contains(JiraTaskBackend.closedJQL))
        XCTAssertEqual(listing.closed.count, 1)
        XCTAssertEqual(listing.closed[0].state, "closed")
        XCTAssertEqual(listing.closed[0].projectStatus, .done)
    }

    func testListAssignedDegradesToEmptyOnFailure() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "boom"))]
        let listing = try await backend(fake).listAssigned(includeClosed: false)
        XCTAssertTrue(listing.open.isEmpty)
        XCTAssertTrue(listing.closed.isEmpty)
    }

    // MARK: - setLabels

    func testSetLabelsAddsAndRemoves() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).setLabels(
            url: "PROJ-5", add: ["crow-tracked"], remove: ["stale"]
        )
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["acli", "jira", "workitem", "edit"])
        XCTAssertEqual(args[args.firstIndex(of: "--key")! + 1], "PROJ-5")
        XCTAssertEqual(args[args.firstIndex(of: "--labels")! + 1], "crow-tracked")
        XCTAssertEqual(args[args.firstIndex(of: "--remove-labels")! + 1], "stale")
        XCTAssertTrue(args.contains("--yes"))
    }

    func testSetLabelsNoOpWhenEmpty() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).setLabels(url: "PROJ-5", add: [], remove: [])
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: - setTaskStatus

    func testSetTaskStatusTransitionsWithMappedName() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).setTaskStatus(url: "https://acme.atlassian.net/browse/PROJ-5", status: .inReview)
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["acli", "jira", "workitem", "transition"])
        XCTAssertEqual(args[args.firstIndex(of: "--key")! + 1], "PROJ-5")
        XCTAssertEqual(args[args.firstIndex(of: "--status")! + 1], "In Review")
        XCTAssertTrue(args.contains("--yes"))
    }

    func testDefaultStatusNameMapping() {
        XCTAssertEqual(JiraTaskBackend.defaultJiraStatusName(for: .ready), "To Do")
        XCTAssertEqual(JiraTaskBackend.defaultJiraStatusName(for: .inProgress), "In Progress")
        XCTAssertEqual(JiraTaskBackend.defaultJiraStatusName(for: .inReview), "In Review")
        XCTAssertEqual(JiraTaskBackend.defaultJiraStatusName(for: .done), "Done")
        XCTAssertEqual(JiraTaskBackend.defaultJiraStatusName(for: .backlog), "Backlog")
    }

    func testStatusMapOverridesDefault() {
        let cfg = JiraConfig(statusMap: ["In Progress": "In Development", "In Review": "Code Review"])
        let b = backend(FakeShellRunner(), config: cfg)
        // Overridden states use the configured name…
        XCTAssertEqual(b.jiraStatusName(for: .inProgress), "In Development")
        XCTAssertEqual(b.jiraStatusName(for: .inReview), "Code Review")
        // …unmapped states fall back to the built-in defaults.
        XCTAssertEqual(b.jiraStatusName(for: .ready), "To Do")
        XCTAssertEqual(b.jiraStatusName(for: .done), "Done")
    }

    func testStatusMapBlankEntryFallsBackToDefault() {
        let b = backend(FakeShellRunner(), config: JiraConfig(statusMap: ["In Progress": "   "]))
        XCTAssertEqual(b.jiraStatusName(for: .inProgress), "In Progress")
    }

    func testSetTaskStatusUsesMappedNameFromConfig() async throws {
        let fake = FakeShellRunner()
        let cfg = JiraConfig(statusMap: ["In Review": "Code Review"])
        try await backend(fake, config: cfg)
            .setTaskStatus(url: "https://acme.atlassian.net/browse/PROJ-5", status: .inReview)
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(args[args.firstIndex(of: "--status")! + 1], "Code Review")
    }

    // MARK: - setTaskStatus REST path (#529)

    private static let transitionsJSON = """
    {"transitions":[
      {"id":"11","name":"Start","to":{"name":"In Development"}},
      {"id":"21","name":"Review","to":{"name":"In Review"}},
      {"id":"31","name":"Resolve","to":{"name":"Done"}}
    ]}
    """.data(using: .utf8)!

    /// With an Authorization header + site, transitions go via REST — `acli` is
    /// never shelled out, and the POST carries the id of the transition whose
    /// target status matches the mapped name.
    func testSetTaskStatusUsesRESTWhenCredentialed() async throws {
        let fake = FakeShellRunner()
        let postedID = Box<String?>(nil)
        let cfg = JiraConfig(
            site: "acme.atlassian.net",
            statusMap: ["In Progress": "In Development"],
            authorization: "Basic creds"
        )
        let b = JiraTaskBackend(shellRunner: fake, config: cfg, transport: { request in
            if request.httpMethod == "POST" {
                let body = try! JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                postedID.set((body?["transition"] as? [String: Any])?["id"] as? String)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
            }
            return (Self.transitionsJSON, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        try await b.setTaskStatus(url: "https://acme.atlassian.net/browse/MAXX-7", status: .inProgress)
        XCTAssertEqual(postedID.get(), "11")
        XCTAssertTrue(fake.calls.isEmpty, "REST path must not shell out to acli")
    }

    /// An unreachable target status is a graceful no-op: no POST, no throw, no acli.
    func testSetTaskStatusRESTGracefulNoOpWhenUnavailable() async throws {
        let fake = FakeShellRunner()
        let didPOST = Box<Bool>(false)
        let cfg = JiraConfig(site: "acme.atlassian.net", authorization: "Basic creds")
        let b = JiraTaskBackend(shellRunner: fake, config: cfg, transport: { request in
            if request.httpMethod == "POST" { didPOST.set(true) }
            return (Self.transitionsJSON, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        // .backlog → "Backlog", which is not a reachable transition above.
        try await b.setTaskStatus(url: "https://acme.atlassian.net/browse/MAXX-7", status: .backlog)
        XCTAssertFalse(didPOST.get())
        XCTAssertTrue(fake.calls.isEmpty)
    }

    /// Without an Authorization header, the legacy `acli` path is used (no REST).
    func testSetTaskStatusFallsBackToAcliWithoutCredential() async throws {
        let fake = FakeShellRunner()
        let b = JiraTaskBackend(shellRunner: fake, config: JiraConfig(site: "acme.atlassian.net"), transport: { _ in
            XCTFail("transport must not be called without a credential")
            throw ProviderError.commandFailed("unreachable")
        })
        try await b.setTaskStatus(url: "https://acme.atlassian.net/browse/PROJ-5", status: .inReview)
        XCTAssertEqual(Array((fake.calls.first?.args ?? []).prefix(4)), ["acli", "jira", "workitem", "transition"])
    }

    // MARK: - closeTask

    func testCloseTaskTransitionsToDefaultDone() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).closeTask(url: "https://acme.atlassian.net/browse/PROJ-5")
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["acli", "jira", "workitem", "transition"])
        XCTAssertEqual(args[args.firstIndex(of: "--key")! + 1], "PROJ-5")
        XCTAssertEqual(args[args.firstIndex(of: "--status")! + 1], "Done")
    }

    func testCloseTaskUsesMappedDoneName() async throws {
        let fake = FakeShellRunner()
        let cfg = JiraConfig(statusMap: ["Done": "Resolved"])
        try await backend(fake, config: cfg).closeTask(url: "https://acme.atlassian.net/browse/PROJ-5")
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(args[args.firstIndex(of: "--status")! + 1], "Resolved")
    }

    // MARK: - assign

    func testAssignInvokesAcliAssign() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).assign(url: "PROJ-5", to: "@me")
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["acli", "jira", "workitem", "assign"])
        XCTAssertEqual(args[args.firstIndex(of: "--key")! + 1], "PROJ-5")
        XCTAssertEqual(args[args.firstIndex(of: "--assignee")! + 1], "@me")
    }

    // MARK: - createTask

    func testCreateTaskUsesRepoAsProjectAndParsesKey() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"[{"key":"NEW-100","fields":{"summary":"Created"}}]"#)]
        let b = backend(fake, config: JiraConfig(site: "acme.atlassian.net"))
        let info = try await b.createTask(repo: "NEW", title: "Created", body: "desc", labels: ["a", "b"])

        XCTAssertEqual(info.number, 100)
        XCTAssertEqual(info.org, "NEW")
        XCTAssertEqual(info.url, "https://acme.atlassian.net/browse/NEW-100")
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["acli", "jira", "workitem", "create"])
        XCTAssertEqual(args[args.firstIndex(of: "--project")! + 1], "NEW")
        XCTAssertEqual(args[args.firstIndex(of: "--type")! + 1], "Task")
        XCTAssertEqual(args[args.firstIndex(of: "--label")! + 1], "a,b")
    }

    func testCreateTaskFallsBackToConfiguredProject() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"[{"key":"DEF-1","fields":{"summary":"x"}}]"#)]
        let b = backend(fake, config: JiraConfig(projectKey: "DEF"))
        _ = try await b.createTask(repo: "", title: "x", body: "y", labels: [])
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(args[args.firstIndex(of: "--project")! + 1], "DEF")
    }

    func testCreateTaskThrowsWhenNoProject() async {
        do {
            _ = try await backend(FakeShellRunner()).createTask(repo: "", title: "x", body: "y", labels: [])
            XCTFail("expected throw")
        } catch ProviderError.commandFailed {
            // expected
        } catch {
            XCTFail("expected commandFailed, got \(error)")
        }
    }

    // MARK: - auth error surfacing

    func testUnauthenticatedOutputSurfacesClearError() async {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "Error: please run acli jira auth login"))]
        do {
            _ = try await backend(fake).fetchTask(url: "PROJ-1")
            XCTFail("expected throw")
        } catch let ProviderError.commandFailed(msg) {
            XCTAssertTrue(msg.lowercased().contains("auth login"))
        } catch {
            XCTFail("expected commandFailed, got \(error)")
        }
    }
}
