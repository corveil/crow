import Foundation
import XCTest
import CrowCore
@testable import CrowProvider

/// Answers `listMonitoredPRs`'s requests by which document they carry, not by
/// arrival order: the two halves go out concurrently, so `FakeShellRunner`'s
/// in-order queue can't tell them apart.
final class MonitoredPRsShellRunner: ShellRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let viewer: Result<String, Error>
    private let searches: Result<String, Error>
    private let labelEvents: Result<String, Error>
    private var _calls: [[String]] = []

    init(
        viewer: Result<String, Error>,
        searches: Result<String, Error>,
        labelEvents: Result<String, Error> = .success(#"{"data":{"nodes":[]}}"#)
    ) {
        self.viewer = viewer
        self.searches = searches
        self.labelEvents = labelEvents
    }

    var calls: [[String]] { lock.withLock { _calls } }

    func labelEventCalls() -> [[String]] {
        calls.filter { $0.contains { $0.contains("nodes(ids: $ids)") } }
    }

    func run(args: [String], env: [String: String], cwd: String?) async throws -> String {
        lock.withLock { _calls.append(args) }
        let query = args.first { $0.hasPrefix("query=") } ?? ""
        let result: Result<String, Error>
        if query.contains("viewerPRs: viewer") {
            result = viewer
        } else if query.contains("reviewPRs: search") {
            result = searches
        } else if query.contains("nodes(ids: $ids)") {
            result = labelEvents
        } else {
            return ""
        }
        return try result.get()
    }
}

/// CROW-1351: the monitored-PR fetch is two concurrent requests plus a label
/// follow-up that runs only when a row carries `crow:reviewing`.
final class GitHubMonitoredPRsSplitTests: XCTestCase {
    private let viewerJSON = """
    {"data":{
      "viewerPRs":{"pullRequests":{"nodes":[
        {"id":"PR_v1","number":1,"url":"https://github.com/acme/app/pull/1","state":"OPEN",
         "repository":{"nameWithOwner":"acme/app"},
         "labels":{"nodes":[{"name":"crow:merge","color":"000000"}]}}
      ]}},
      "viewer":{"login":"me"},
      "rateLimit":{"remaining":4900,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":18}
    }}
    """

    private func searchesJSON(reviewLabels: String = #"[{"name":"bug","color":"ff0000"}]"#) -> String {
        """
        {"data":{
          "reviewPRs":{"nodes":[
            {"id":"PR_r2","number":2,"title":"Two","url":"https://github.com/acme/app/pull/2",
             "repository":{"nameWithOwner":"acme/app"},"author":{"login":"bob"},
             "labels":{"nodes":\(reviewLabels)}}
          ]},
          "reviewedPRs":{"nodes":[]},
          "completedPRs":{"nodes":[]},
          "viewer":{"login":"me"},
          "rateLimit":{"remaining":4897,"limit":5000,"resetAt":"2026-01-01T00:00:00Z","cost":3}
        }}
        """
    }

    func testMergesBothHalvesAndSkipsTheLabelFollowUpWhenNothingIsReviewing() async throws {
        let fake = MonitoredPRsShellRunner(viewer: .success(viewerJSON), searches: .success(searchesJSON()))
        let listing = try await GitHubCodeBackend(shellRunner: fake).listMonitoredPRs()

        XCTAssertEqual(listing.viewerPRs.map(\.number), [1])
        XCTAssertEqual(listing.reviewRequests.map(\.prNumber), [2])
        XCTAssertEqual(listing.viewerLogin, "me")
        XCTAssertFalse(listing.samlRestricted)
        // The later reading of the shared budget, and what the whole poll spent.
        XCTAssertEqual(listing.rateLimit?.remaining, 4897)
        XCTAssertEqual(listing.rateLimit?.cost, 21)
        XCTAssertEqual(fake.calls.count, 2)
        XCTAssertTrue(fake.labelEventCalls().isEmpty)
    }

    func testFetchesLabelEventsOnlyForReviewingRowsAndFillsReviewingBy() async throws {
        let labelEvents = """
        {"data":{"nodes":[
          {"id":"PR_r2","timelineItems":{"nodes":[
            {"createdAt":"2026-09-01T00:00:00Z","actor":{"login":"ada"},"label":{"name":"crow:reviewing"}}
          ]}}
        ]}}
        """
        let fake = MonitoredPRsShellRunner(
            viewer: .success(viewerJSON),
            searches: .success(searchesJSON(reviewLabels: #"[{"name":"crow:reviewing","color":"000000"}]"#)),
            labelEvents: .success(labelEvents)
        )
        let listing = try await GitHubCodeBackend(shellRunner: fake).listMonitoredPRs()

        XCTAssertEqual(listing.reviewRequests.first?.reviewingBy, "ada")
        XCTAssertNil(listing.viewerPRs.first?.reviewingBy)
        let followUps = fake.labelEventCalls()
        XCTAssertEqual(followUps.count, 1)
        // Only the labelled row's id is asked for.
        XCTAssertEqual(followUps.first?.filter { $0.hasPrefix("ids[]=") }, ["ids[]=PR_r2"])
    }

    func testALabelFollowUpFailureLeavesReviewingByNilWithoutFailingThePoll() async throws {
        let fake = MonitoredPRsShellRunner(
            viewer: .success(viewerJSON),
            searches: .success(searchesJSON(reviewLabels: #"[{"name":"crow:reviewing","color":"000000"}]"#)),
            labelEvents: .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "HTTP 502"))
        )
        let listing = try await GitHubCodeBackend(shellRunner: fake).listMonitoredPRs()

        XCTAssertEqual(listing.reviewRequests.map(\.prNumber), [2])
        XCTAssertNil(listing.reviewRequests.first?.reviewingBy)
    }

    func testAFailedHalfFailsTheListing() async {
        let fake = MonitoredPRsShellRunner(
            viewer: .success(viewerJSON),
            searches: .failure(ShellRunnerError.nonZeroExit(exitCode: 1, output: "HTTP 502: Bad Gateway"))
        )
        do {
            _ = try await GitHubCodeBackend(shellRunner: fake).listMonitoredPRs()
            XCTFail("an empty review half must not read as 'no reviews'")
        } catch {}
    }

    func testAnUnparseableCleanHalfFailsTheListing() async {
        let fake = MonitoredPRsShellRunner(viewer: .success(viewerJSON), searches: .success(""))
        do {
            _ = try await GitHubCodeBackend(shellRunner: fake).listMonitoredPRs()
            XCTFail("an unparseable half must throw")
        } catch {}
    }

    func testReviewingLabelNodeIDsDedupesAcrossSearchesAndIgnoresOtherLabels() throws {
        let reviewing = #"{"nodes":[{"name":"Crow:Reviewing"}]}"#
        let json = """
        {"data":{
          "viewerPRs":{"pullRequests":{"nodes":[null,{"id":"A","labels":\(reviewing)}]}},
          "reviewPRs":{"nodes":[{"id":"B","labels":\(reviewing)},{"id":"C","labels":{"nodes":[{"name":"bug"}]}}]},
          "reviewedPRs":{"nodes":[{"id":"B","labels":\(reviewing)}]},
          "completedPRs":{"nodes":[{"labels":\(reviewing)}]}
        }}
        """
        let dataObj = try XCTUnwrap(GitHubTaskBackend.decodeGraphQLData(json))
        XCTAssertEqual(GitHubCodeBackend.reviewingLabelNodeIDs(in: dataObj), ["A", "B"])
    }

    func testInjectedTimelinesReachTheViewerPRParser() throws {
        let json = """
        {"data":{
          "viewerPRs":{"pullRequests":{"nodes":[
            null,
            {"id":"A","number":7,"url":"https://github.com/acme/app/pull/7","state":"OPEN",
             "repository":{"nameWithOwner":"acme/app"},
             "labels":{"nodes":[{"name":"crow:reviewing"}]}}
          ]}},
          "viewer":{"login":"me"}
        }}
        """
        let timelines = GitHubCodeBackend.parseReviewingLabelTimelines("""
        {"data":{"nodes":[null,{"id":"A","timelineItems":{"nodes":[
          {"createdAt":"2026-09-01T00:00:00Z","actor":{"login":"ada"},"label":{"name":"crow:reviewing"}}
        ]}}]}}
        """)
        let dataObj = try XCTUnwrap(GitHubTaskBackend.decodeGraphQLData(json))
        let listing = GitHubCodeBackend.parseMonitoredPRsData(
            GitHubCodeBackend.injectReviewingLabelTimelines(timelines, into: dataObj)
        )
        XCTAssertEqual(listing.viewerPRs.map(\.number), [7])
        XCTAssertEqual(listing.viewerPRs.first?.reviewingBy, "ada")
    }

    /// The point of the ticket: neither half pays for label events on every
    /// row, and every row carries the `id` the follow-up needs.
    func testNeitherHalfSelectsTimelineItemsAndEveryRowSelectsItsID() {
        let viewer = GitHubCodeBackend.monitoredViewerPRsQuery
        let searches = GitHubCodeBackend.monitoredReviewSearchesQuery
        XCTAssertFalse(viewer.contains("timelineItems"))
        XCTAssertFalse(searches.contains("timelineItems"))
        XCTAssertEqual(viewer.components(separatedBy: "id number url").count - 1, 1)
        XCTAssertEqual(searches.components(separatedBy: "id number title url").count - 1, 3)
        XCTAssertTrue(GitHubCodeBackend.reviewingLabelEventsQuery.contains("timelineItems(last: 30"))
    }
}
