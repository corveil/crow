import XCTest
import CrowCore
@testable import CrowProvider

/// Exercises `CorveilTaskBackend` against `FakeShellRunner` — the ADR 0005
/// testability bar. Asserts the exact `corveil` argv for each method plus the
/// JSON parsing, id parsing, and status mapping, without spawning real `corveil`.
final class CorveilTaskBackendTests: XCTestCase {

    private func backend(_ fake: FakeShellRunner, config: CorveilConfig = CorveilConfig()) -> CorveilTaskBackend {
        CorveilTaskBackend(shellRunner: fake, config: config)
    }

    // MARK: - Capabilities

    func testDeclaresBatchedQueryAndProjectBoardStatus() {
        let b = backend(FakeShellRunner())
        XCTAssertEqual(b.provider, .corveil)
        XCTAssertTrue(b.capabilities.contains(.batchedQuery))
        XCTAssertTrue(b.capabilities.contains(.projectBoardStatus))
    }

    // MARK: - CorveilTaskID parsing

    func testCorveilTaskIDParsesDashboardURL() {
        let parsed = CorveilTaskID.parse("https://corveil.io/dashboard/tasks/42")
        XCTAssertEqual(parsed?.id, "42")
        XCTAssertEqual(parsed?.number, 42)
    }

    func testCorveilTaskIDParsesSelfHostedURL() {
        let parsed = CorveilTaskID.parse("https://corveil.acme.io/dashboard/tasks/137")
        XCTAssertEqual(parsed?.id, "137")
        XCTAssertEqual(parsed?.number, 137)
    }

    func testCorveilTaskIDParsesBareNumericId() {
        XCTAssertEqual(CorveilTaskID.parse("42")?.id, "42")
        XCTAssertEqual(CorveilTaskID.parse("42")?.number, 42)
    }

    func testCorveilTaskIDStripsQueryAndFragment() {
        let parsed = CorveilTaskID.parse("https://corveil.io/dashboard/tasks/42?foo=bar")
        XCTAssertEqual(parsed?.id, "42")
        XCTAssertEqual(parsed?.number, 42)
    }

    func testCorveilTaskIDParsesSlugWithNumericSuffix() {
        let parsed = CorveilTaskID.parse("task-99")
        XCTAssertEqual(parsed?.id, "task-99")
        XCTAssertEqual(parsed?.number, 99)
    }

    func testCorveilTaskIDRejectsUnparseable() {
        XCTAssertNil(CorveilTaskID.parse(""))
        XCTAssertNil(CorveilTaskID.parse("https://corveil.io/dashboard"))
        XCTAssertNil(CorveilTaskID.parse("not-numeric"))
    }

    // MARK: - fetchTask

    func testFetchTaskInvokesCorveilGetAndReadsURLField() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"{"id":"42","title":"Fix the thing","url":"https://corveil.io/dashboard/tasks/42"}"#)]
        let b = backend(fake)
        let info = try await b.fetchTask(url: "https://corveil.io/dashboard/tasks/42")

        XCTAssertEqual(info.title, "Fix the thing")
        XCTAssertEqual(info.number, 42)
        XCTAssertEqual(info.provider, .corveil)
        XCTAssertFalse(info.isMR)
        XCTAssertEqual(info.url, "https://corveil.io/dashboard/tasks/42")

        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(3)), ["corveil", "task", "get"])
        XCTAssertTrue(args.contains("42"))
        XCTAssertTrue(args.contains("--json"))
        // #696: Corveil carries no ticket priority/epic — nil, not an error.
        XCTAssertNil(info.priority)
        XCTAssertNil(info.parentKey)
    }

    func testFetchTaskFallsBackToHostBuiltURLWhenJSONOmitsURL() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"{"id":"42","title":"No URL field"}"#)]
        let b = backend(fake, config: CorveilConfig(host: "corveil.acme.io"))
        let info = try await b.fetchTask(url: "https://corveil.acme.io/dashboard/tasks/42")
        XCTAssertEqual(info.url, "https://corveil.acme.io/dashboard/tasks/42")
    }

    func testFetchTaskRejectsUnparseableURL() async {
        do {
            _ = try await backend(FakeShellRunner()).fetchTask(url: "https://corveil.io/dashboard")
            XCTFail("expected throw")
        } catch ProviderError.invalidURL {
            // expected
        } catch {
            XCTFail("expected invalidURL, got \(error)")
        }
    }

    // MARK: - listAssigned

    func testListAssignedFansOutAcrossOpenAndInProgressForTheOpenHalf() async throws {
        // Corveil's `--status` is exact-match, not "not closed" — so to match
        // GitHub/Jira semantics the backend must issue one call for `open` and
        // one for `in_progress`, merging the results. Without this, a task we
        // just moved to in_progress via setTaskStatus(.inProgress) would vanish
        // from the assigned board on the next IssueTracker poll.
        let fake = FakeShellRunner()
        fake.responses = [
            .success(#"[{"id":"1","title":"Just queued","status":"open"}]"#),
            .success(#"[{"id":"2","title":"Actively working","status":"in_progress","labels":["bug","crow:auto"],"url":"https://corveil.io/dashboard/tasks/2"}]"#),
        ]
        let b = backend(fake)
        let listing = try await b.listAssigned(includeClosed: false)

        XCTAssertEqual(listing.open.count, 2)
        XCTAssertTrue(listing.closed.isEmpty)

        XCTAssertEqual(fake.calls.count, 2)
        for call in fake.calls {
            let args = call.args
            XCTAssertEqual(Array(args.prefix(3)), ["corveil", "task", "list"])
            XCTAssertEqual(args[args.firstIndex(of: "--assignee")! + 1], "@me")
        }
        XCTAssertEqual(fake.calls[0].args[fake.calls[0].args.firstIndex(of: "--status")! + 1], "open")
        XCTAssertEqual(fake.calls[1].args[fake.calls[1].args.firstIndex(of: "--status")! + 1], "in_progress")

        let queued = listing.open.first(where: { $0.id == "corveil:1" })
        XCTAssertNotNil(queued)
        XCTAssertEqual(queued?.projectStatus, .ready)
        XCTAssertEqual(queued?.state, "open")

        let active = listing.open.first(where: { $0.id == "corveil:2" })
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.projectStatus, .inProgress)
        XCTAssertEqual(active?.state, "open")
        XCTAssertEqual(active?.url, "https://corveil.io/dashboard/tasks/2")
        XCTAssertEqual(active?.labels.map(\.name), ["bug", "crow:auto"])
    }

    func testListAssignedIssuesThirdCallWhenIncludeClosed() async throws {
        // Open half fans out (open + in_progress), then a third call for closed.
        let fake = FakeShellRunner()
        fake.responses = [
            .success("[]"),
            .success("[]"),
            .success(#"[{"id":"9","title":"Done one","status":"closed"}]"#),
        ]
        let b = backend(fake)
        let listing = try await b.listAssigned(includeClosed: true)

        XCTAssertEqual(fake.calls.count, 3)
        let closedArgs = fake.calls[2].args
        XCTAssertEqual(closedArgs[closedArgs.firstIndex(of: "--status")! + 1], "closed")
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

    func testSetLabelsAddsAndRemovesViaRepeatedFlags() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).setLabels(
            url: "42", add: ["crow-tracked", "bug"], remove: ["stale"]
        )
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["corveil", "task", "update", "42"])

        let addCount = args.enumerated().filter { $0.element == "--add-label" }.count
        XCTAssertEqual(addCount, 2)
        let removeCount = args.enumerated().filter { $0.element == "--remove-label" }.count
        XCTAssertEqual(removeCount, 1)

        // Verify each add-label flag is followed by the right value.
        let firstAddIdx = args.firstIndex(of: "--add-label")!
        XCTAssertEqual(args[firstAddIdx + 1], "crow-tracked")
        let removeIdx = args.firstIndex(of: "--remove-label")!
        XCTAssertEqual(args[removeIdx + 1], "stale")
    }

    func testSetLabelsNoOpWhenEmpty() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).setLabels(url: "42", add: [], remove: [])
        XCTAssertTrue(fake.calls.isEmpty)
    }

    // MARK: - setTaskStatus

    func testSetTaskStatusMapsInReviewToInProgress() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).setTaskStatus(url: "https://corveil.io/dashboard/tasks/42", status: .inReview)
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["corveil", "task", "update", "42"])
        XCTAssertEqual(args[args.firstIndex(of: "--status")! + 1], "in_progress")
    }

    func testCloseTaskSetsClosedStatus() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).closeTask(url: "https://corveil.io/dashboard/tasks/42")
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["corveil", "task", "update", "42"])
        XCTAssertEqual(args[args.firstIndex(of: "--status")! + 1], "closed")
    }

    func testStatusNameMappingCoversAllCases() {
        XCTAssertEqual(CorveilTaskBackend.corveilStatusName(for: .backlog), "open")
        XCTAssertEqual(CorveilTaskBackend.corveilStatusName(for: .ready), "open")
        XCTAssertEqual(CorveilTaskBackend.corveilStatusName(for: .inProgress), "in_progress")
        XCTAssertEqual(CorveilTaskBackend.corveilStatusName(for: .inReview), "in_progress")
        XCTAssertEqual(CorveilTaskBackend.corveilStatusName(for: .done), "closed")
        XCTAssertEqual(CorveilTaskBackend.corveilStatusName(for: .unknown), "open")
    }

    func testReverseStatusMapping() {
        XCTAssertEqual(CorveilTaskBackend.ticketStatus(fromCorveil: "open"), .ready)
        XCTAssertEqual(CorveilTaskBackend.ticketStatus(fromCorveil: "in_progress"), .inProgress)
        XCTAssertEqual(CorveilTaskBackend.ticketStatus(fromCorveil: "in-progress"), .inProgress)
        XCTAssertEqual(CorveilTaskBackend.ticketStatus(fromCorveil: "closed"), .done)
        XCTAssertEqual(CorveilTaskBackend.ticketStatus(fromCorveil: "done"), .done)
        XCTAssertEqual(CorveilTaskBackend.ticketStatus(fromCorveil: "weird"), .unknown)
    }

    // MARK: - assign

    func testAssignInvokesCorveilUpdate() async throws {
        let fake = FakeShellRunner()
        try await backend(fake).assign(url: "42", to: "@me")
        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(4)), ["corveil", "task", "update", "42"])
        XCTAssertEqual(args[args.firstIndex(of: "--assignee")! + 1], "@me")
    }

    // MARK: - createTask

    func testCreateTaskWithLabelsAndParsesIdAndURL() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success(#"{"id":"100","title":"Created","url":"https://corveil.io/dashboard/tasks/100"}"#)]
        let b = backend(fake)
        let info = try await b.createTask(repo: "", title: "Created", body: "desc", labels: ["a", "b"])

        XCTAssertEqual(info.number, 100)
        XCTAssertEqual(info.url, "https://corveil.io/dashboard/tasks/100")
        XCTAssertEqual(info.provider, .corveil)

        let args = fake.calls.first?.args ?? []
        XCTAssertEqual(Array(args.prefix(3)), ["corveil", "task", "create"])
        XCTAssertEqual(args[args.firstIndex(of: "--title")! + 1], "Created")
        XCTAssertEqual(args[args.firstIndex(of: "--description")! + 1], "desc")
        XCTAssertEqual(args[args.firstIndex(of: "--assignee")! + 1], "@me")

        let labelCount = args.enumerated().filter { $0.element == "--label" }.count
        XCTAssertEqual(labelCount, 2)
        XCTAssertTrue(args.contains("--json"))
    }

    func testCreateTaskAcceptsNumericIdInResponse() async throws {
        let fake = FakeShellRunner()
        // corveil JSON could plausibly emit ids as numbers; the parser handles both.
        fake.responses = [.success(#"{"id":7,"title":"x"}"#)]
        let info = try await backend(fake).createTask(repo: "", title: "x", body: "y", labels: [])
        XCTAssertEqual(info.number, 7)
    }

    func testCreateTaskThrowsWhenJSONLacksParseableID() async {
        let fake = FakeShellRunner()
        fake.responses = [.success("{}")]
        do {
            _ = try await backend(fake).createTask(repo: "", title: "x", body: "y", labels: [])
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
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "Error: please run corveil login"))]
        do {
            _ = try await backend(fake).fetchTask(url: "https://corveil.io/dashboard/tasks/1")
            XCTFail("expected throw")
        } catch let ProviderError.commandFailed(msg) {
            XCTAssertTrue(msg.lowercased().contains("corveil login"))
        } catch {
            XCTFail("expected commandFailed, got \(error)")
        }
    }
}
