import XCTest
import CrowCore
@testable import CrowProvider

/// GitHub's intermittent gateway errors on slow GraphQL queries (#1350):
/// classified as `.transientGateway` and retried by the two poll paths before
/// the cycle gives up.
final class TransientGatewayRetryTests: XCTestCase {
    /// The shape `gh api graphql` produced on 2026-10-22: nginx's HTML body on
    /// stdout, gh's status line after it.
    private static let badGateway = """
    <html>
    <head><title>502 Bad Gateway</title></head>
    <body><center><h1>502 Bad Gateway</h1></center></body>
    </html>
    gh: HTTP 502
    """

    private static let emptyIssues = #"{"data":{"openIssues":{"nodes":[]},"closedIssues":{"nodes":[]}}}"#
    private static let emptyMonitored = #"{"data":{"viewerPRs":{"pullRequests":{"nodes":[]}},"reviewPRs":{"nodes":[]},"viewer":{"login":"me"}}}"#

    private static func gatewayFailure(_ output: String = badGateway) -> Result<String, Error> {
        .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: output))
    }

    // MARK: - Classification

    func testClassifiesGatewayErrorsAsTransient() {
        let blobs = [
            Self.badGateway,
            "gh: HTTP 504",
            "gh: We couldn't respond to your request in time. Sorry about that. Please try resubmitting your request and contact us if the problem persists.",
        ]
        for blob in blobs {
            guard case .transientGateway(let carried) = GitHubTaskBackend.classifyGraphQLError(blob) else {
                XCTFail("expected .transientGateway for: \(blob)")
                continue
            }
            XCTAssertEqual(carried, blob)
        }
    }

    func testOtherFailuresStayCommandFailed() {
        for blob in ["gh: HTTP 500", "gh: HTTP 401: Bad credentials", "GraphQL: Something unexpected"] {
            guard case .commandFailed = GitHubTaskBackend.classifyGraphQLError(blob) else {
                XCTFail("expected .commandFailed for: \(blob)")
                continue
            }
        }
    }

    func testTypedGraphQLErrorsWinOverGatewayMarker() {
        guard case .rateLimited = GitHubTaskBackend.classifyGraphQLError("API rate limit exceeded\ngh: HTTP 502") else {
            return XCTFail("expected .rateLimited")
        }
    }

    // MARK: - listAssigned

    func testListAssignedRecoversAfterOneGatewayError() async throws {
        let fake = FakeShellRunner()
        fake.responses = [Self.gatewayFailure(), .success(Self.emptyIssues)]
        let backend = GitHubTaskBackend(shellRunner: fake, transientRetryDelays: [.zero, .zero])
        let listing = try await backend.listAssigned()
        XCTAssertEqual(listing.open.count, 0)
        XCTAssertEqual(fake.calls.count, 2)
        // The retry re-sent the same query, not a degraded variant.
        XCTAssertEqual(fake.calls[0].args, fake.calls[1].args)
    }

    func testListAssignedFailsAfterRetriesAreExhausted() async {
        let fake = FakeShellRunner()
        fake.responses = [Self.gatewayFailure(), Self.gatewayFailure(), Self.gatewayFailure(), .success(Self.emptyIssues)]
        let backend = GitHubTaskBackend(shellRunner: fake, transientRetryDelays: [.zero, .zero])
        do {
            _ = try await backend.listAssigned()
            XCTFail("expected a throw")
        } catch ProviderError.transientGateway {
            // One attempt plus one per delay — the fourth response is never used.
            XCTAssertEqual(fake.calls.count, 3)
        } catch {
            XCTFail("expected .transientGateway, got \(error)")
        }
    }

    func testListAssignedDoesNotRetryNonTransientFailures() async {
        let fake = FakeShellRunner()
        fake.responses = [Self.gatewayFailure("gh: HTTP 401: Bad credentials"), .success(Self.emptyIssues)]
        let backend = GitHubTaskBackend(shellRunner: fake, transientRetryDelays: [.zero, .zero])
        do {
            _ = try await backend.listAssigned()
            XCTFail("expected a throw")
        } catch ProviderError.commandFailed {
            XCTAssertEqual(fake.calls.count, 1)
        } catch {
            XCTFail("expected .commandFailed, got \(error)")
        }
    }

    // MARK: - listMonitoredPRs

    /// Since CROW-1351 the fetch is two concurrent halves; each retries on its
    /// own, so the fake answers per document from its own queue.
    private final class HalfQueues: ShellRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var viewer: [Result<String, Error>]
        private var searches: [Result<String, Error>]
        private(set) var viewerCalls = 0
        private(set) var searchCalls = 0

        init(viewer: [Result<String, Error>], searches: [Result<String, Error>]) {
            self.viewer = viewer
            self.searches = searches
        }

        func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
            let query = args.first { $0.hasPrefix("query=") } ?? ""
            let next: Result<String, Error>? = lock.withLock {
                if query.contains("viewerPRs: viewer") {
                    viewerCalls += 1
                    return viewer.isEmpty ? nil : viewer.removeFirst()
                }
                if query.contains("reviewPRs: search") {
                    searchCalls += 1
                    return searches.isEmpty ? nil : searches.removeFirst()
                }
                return nil
            }
            return try next?.get() ?? ""
        }
    }

    private static let viewerHalf = #"{"data":{"viewerPRs":{"pullRequests":{"nodes":[]}},"viewer":{"login":"me"}}}"#
    private static let searchHalf = #"{"data":{"reviewPRs":{"nodes":[]},"reviewedPRs":{"nodes":[]},"completedPRs":{"nodes":[]}}}"#

    func testListMonitoredPRsRetriesOnlyTheHalfThatFailed() async throws {
        let fake = HalfQueues(
            viewer: [.success(Self.viewerHalf)],
            searches: [Self.gatewayFailure("gh: HTTP 504"), Self.gatewayFailure(), .success(Self.searchHalf)]
        )
        let backend = GitHubCodeBackend(shellRunner: fake, transientRetryDelays: [.zero, .zero])
        let listing = try await backend.listMonitoredPRs()
        XCTAssertEqual(listing.viewerLogin, "me")
        XCTAssertEqual(fake.viewerCalls, 1)
        XCTAssertEqual(fake.searchCalls, 3)
    }

    func testListMonitoredPRsFailsAfterRetriesAreExhausted() async {
        let fake = HalfQueues(
            viewer: [Self.gatewayFailure(), Self.gatewayFailure(), .success(Self.viewerHalf)],
            searches: [.success(Self.searchHalf)]
        )
        let backend = GitHubCodeBackend(shellRunner: fake, transientRetryDelays: [.zero])
        do {
            _ = try await backend.listMonitoredPRs()
            XCTFail("expected a throw")
        } catch ProviderError.transientGateway {
            XCTAssertEqual(fake.viewerCalls, 2)
        } catch {
            XCTFail("expected .transientGateway, got \(error)")
        }
    }

    func testDefaultRetryBudgetStaysUnderPollInterval() {
        // Three ~11s attempts (GitHub's limit plus nginx) plus the sleeps must
        // leave headroom under the 60s board poll.
        let sleep = GitHubTaskBackend.transientRetryDelays.reduce(Duration.zero, +)
        let attempts = GitHubTaskBackend.transientRetryDelays.count + 1
        XCTAssertLessThan(sleep + .seconds(11 * attempts), .seconds(45))
    }
}
