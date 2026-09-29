import XCTest
import CrowCore
@testable import CrowProvider

final class ReviewingLabelBackendTests: XCTestCase {
    func testAddAndRemoveUseTmpdirAndTheReviewingLabel() async throws {
        let fake = FakeShellRunner()
        let backend = GitHubCodeBackend(shellRunner: fake)
        let url = "https://github.com/acme/app/pull/9"

        try await backend.addReviewingLabel(prURL: url)
        try await backend.removeReviewingLabel(prURL: url)

        XCTAssertEqual(fake.calls[0].args, ["gh", "pr", "edit", url, "--add-label", "crow:reviewing"])
        XCTAssertEqual(fake.calls[0].cwd, NSTemporaryDirectory())
        XCTAssertEqual(fake.calls[1].args, ["gh", "pr", "edit", url, "--remove-label", "crow:reviewing"])
        XCTAssertEqual(fake.calls[1].cwd, NSTemporaryDirectory())
    }

    func testEnsureReviewingLabelSwallowsAlreadyExists() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.failure(ShellRunnerError.nonZeroExit(
            exitCode: 1, output: "label crow:reviewing already exists"))]
        let backend = GitHubCodeBackend(shellRunner: fake)
        try await backend.ensureReviewingLabel(repo: "acme/app")
        XCTAssertEqual(fake.calls[0].args.prefix(4), ["gh", "label", "create", "crow:reviewing"])
    }

    func testParseReviewingLabelActorTakesTheLatestAdd() throws {
        let json = """
        {"data":{
          "viewer":{"login":"ada"},
          "repository":{"pullRequest":{
            "labels":{"nodes":[{"name":"crow:reviewing"}]},
            "timelineItems":{"nodes":[
              {"createdAt":"2026-09-01T00:00:00Z","actor":{"login":"ada"},"label":{"name":"crow:reviewing"}},
              {"createdAt":"2026-09-02T00:00:00Z","actor":{"login":"bob"},"label":{"name":"bug"}},
              {"createdAt":"2026-09-03T00:00:00Z","actor":{"login":"bob"},"label":{"name":"crow:reviewing"}}
            ]}
          }}
        }}
        """
        let actor = try GitHubCodeBackend.parseReviewingLabelActor(json)
        XCTAssertTrue(actor.labelPresent)
        XCTAssertEqual(actor.latestActor, "bob")
        XCTAssertEqual(actor.viewerLogin, "ada")
    }

    func testParseReviewingLabelActorIsAbsentWhenTheLabelIsGone() throws {
        let json = """
        {"data":{
          "viewer":{"login":"ada"},
          "repository":{"pullRequest":{
            "labels":{"nodes":[{"name":"bug"}]},
            "timelineItems":{"nodes":[
              {"createdAt":"2026-09-01T00:00:00Z","actor":{"login":"ada"},"label":{"name":"crow:reviewing"}}
            ]}
          }}
        }}
        """
        let actor = try GitHubCodeBackend.parseReviewingLabelActor(json)
        XCTAssertFalse(actor.labelPresent)
        XCTAssertEqual(actor.latestActor, "ada")
    }

    func testReviewingByOnAMonitoredPRRequiresTheLabel() {
        let withLabel: [String: Any] = [
            "number": 1,
            "url": "https://github.com/acme/app/pull/1",
            "state": "OPEN",
            "labels": ["nodes": [["name": "crow:reviewing", "color": "FBCA04"]]],
            "timelineItems": ["nodes": [[
                "createdAt": "2026-09-01T00:00:00Z",
                "actor": ["login": "ada"],
                "label": ["name": "crow:reviewing"],
            ]]],
        ]
        XCTAssertEqual(GitHubCodeBackend.parsePRNode(withLabel)?.reviewingBy, "ada")

        var without = withLabel
        without["labels"] = ["nodes": [["name": "bug"]]]
        XCTAssertNil(GitHubCodeBackend.parsePRNode(without)?.reviewingBy)
    }

    func testParseOpenReviewingLabelsKeepsEachPRsLatestActor() throws {
        let json = """
        {"data":{
          "viewer":{"login":"ada"},
          "search":{"nodes":[
            {"url":"https://github.com/acme/app/pull/2","timelineItems":{"nodes":[
              {"createdAt":"2026-09-01T00:00:00Z","actor":{"login":"ada"},"label":{"name":"crow:reviewing"}}
            ]}},
            {"url":"https://github.com/acme/app/pull/3","timelineItems":{"nodes":[
              {"createdAt":"2026-09-04T00:00:00Z","actor":{"login":"bob"},"label":{"name":"crow:reviewing"}}
            ]}}
          ]}
        }}
        """
        let listing = try GitHubCodeBackend.parseOpenReviewingLabels(json)
        XCTAssertEqual(listing.viewerLogin, "ada")
        XCTAssertEqual(listing.candidates.map(\.url), [
            "https://github.com/acme/app/pull/2",
            "https://github.com/acme/app/pull/3",
        ])
        XCTAssertEqual(listing.candidates.map(\.latestActor), ["ada", "bob"])
    }
}
