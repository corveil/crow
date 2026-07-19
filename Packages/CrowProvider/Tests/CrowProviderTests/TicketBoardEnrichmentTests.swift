import XCTest
import CrowCore
@testable import CrowProvider

/// Coverage for the #751 Ticket Board enrichment: the body cap, the GitLab
/// pipeline→checks mapping, tolerant GitHub date parsing, GitLab issue parsing
/// (clean project slug + new fields), and the linked-MR lookup building a valid
/// `projects/{slug}` path (the review's slug-with-`#iid` bug).
final class TicketBoardEnrichmentTests: XCTestCase {

    // MARK: - IssueBody.cap

    func testIssueBodyCapNilForEmptyOrWhitespace() {
        XCTAssertNil(IssueBody.cap(""))
        XCTAssertNil(IssueBody.cap("   \n\t "))
    }

    func testIssueBodyCapTrimsButKeepsShortBody() {
        XCTAssertEqual(IssueBody.cap("  hello world  "), "hello world")
    }

    func testIssueBodyCapTruncatesLongBodyWithEllipsis() {
        let long = String(repeating: "x", count: IssueBody.maxLength + 500)
        let capped = IssueBody.cap(long)
        XCTAssertNotNil(capped)
        // maxLength chars + the ellipsis.
        XCTAssertEqual(capped?.count, IssueBody.maxLength + 1)
        XCTAssertTrue(capped?.hasSuffix("…") ?? false)
    }

    // MARK: - GitLab pipeline status → checks vocabulary

    func testMapPipelineStatus() {
        XCTAssertEqual(GitLabCodeBackend.mapPipelineStatus("success"), "SUCCESS")
        XCTAssertEqual(GitLabCodeBackend.mapPipelineStatus("failed"), "FAILURE")
        for pending in ["running", "pending", "created", "preparing", "waiting_for_resource", "scheduled", "manual"] {
            XCTAssertEqual(GitLabCodeBackend.mapPipelineStatus(pending), "PENDING", pending)
        }
        XCTAssertEqual(GitLabCodeBackend.mapPipelineStatus("canceled"), "ERROR")
        XCTAssertEqual(GitLabCodeBackend.mapPipelineStatus("skipped"), "")
        XCTAssertEqual(GitLabCodeBackend.mapPipelineStatus("something-new"), "")
    }

    // MARK: - IssueDate tolerant parse

    func testIssueDateParsesBothFractionalAndPlain() {
        XCTAssertNotNil(IssueDate.parse("2026-06-15T01:28:17Z"))          // non-fractional (GitHub)
        XCTAssertNotNil(IssueDate.parse("2026-06-15T01:28:17.123Z"))      // fractional (GitLab)
        XCTAssertNil(IssueDate.parse(nil))
        XCTAssertNil(IssueDate.parse("not a date"))
    }

    // MARK: - GitHub parseIssueNodes enriched fields (+ non-fractional dates)

    func testParseIssueNodesEnrichedFields() {
        let searchObj: [String: Any] = [
            "nodes": [[
                "number": 751,
                "title": "Redesign the Ticket Board",
                "url": "https://github.com/corveil/crow/issues/751",
                "state": "OPEN",
                // GitHub GraphQL emits NON-fractional DateTime — the regression
                // this test guards (a fractional-only formatter returned nil).
                "updatedAt": "2026-07-18T10:00:00Z",
                "createdAt": "2026-07-15T09:30:00Z",
                "author": ["login": "dhilgaertner"],
                "comments": ["totalCount": 4],
                "bodyText": "  A useful description.  ",
                "repository": ["nameWithOwner": "corveil/crow"],
                "labels": ["nodes": [["name": "enhancement", "color": "a2eeef"]]],
            ]]
        ]
        let issues = GitHubTaskBackend.parseIssueNodes(searchObj, defaultState: "open")
        XCTAssertEqual(issues.count, 1)
        let i = issues[0]
        XCTAssertEqual(i.author, "dhilgaertner")
        XCTAssertEqual(i.commentsCount, 4)
        XCTAssertEqual(i.body, "A useful description.")
        XCTAssertNotNil(i.updatedAt, "non-fractional updatedAt must parse")
        XCTAssertNotNil(i.createdAt, "non-fractional createdAt must parse")
        XCTAssertEqual(i.repo, "corveil/crow")
    }

    // MARK: - GitLab parseIssues: clean slug + new fields

    func testGitLabParseIssuesStripsIidFromRepoAndMapsFields() {
        let json = """
        [{
          "iid": 6,
          "title": "Fix flaky auth test",
          "web_url": "https://gitlab.example.com/group/project/-/issues/6",
          "state": "opened",
          "labels": ["bug"],
          "references": { "full": "group/project#6" },
          "author": { "username": "jordan" },
          "created_at": "2026-07-10T08:00:00Z",
          "updated_at": "2026-07-17T12:00:00.500Z",
          "user_notes_count": 3,
          "merge_requests_count": 1,
          "description": "Some description body."
        }]
        """
        let issues = GitLabTaskBackend.parseIssues(json, host: "gitlab.example.com", projectStatusOverride: nil)
        XCTAssertEqual(issues.count, 1)
        let i = issues[0]
        // repo must be the bare project path (no "#6") so the repo filter groups
        // correctly and the MR-status call targets a valid project path.
        XCTAssertEqual(i.repo, "group/project")
        // identity still carries the iid.
        XCTAssertEqual(i.id, "gitlab:gitlab.example.com:group/project#6")
        XCTAssertEqual(i.author, "jordan")
        XCTAssertEqual(i.commentsCount, 3)
        XCTAssertEqual(i.mergeRequestsCount, 1)
        XCTAssertEqual(i.body, "Some description body.")
        XCTAssertNotNil(i.createdAt)
        XCTAssertNotNil(i.updatedAt)
    }

    // MARK: - linkedMRStatus builds a valid project path (slug bug fix)

    func testLinkedMRStatusUsesCleanProjectSlugAndMapsPipeline() async throws {
        let fake = FakeShellRunner()
        fake.responses = [
            .success("""
            [{"iid":17,"web_url":"https://gitlab.example.com/group/project/-/merge_requests/17","state":"opened","draft":true}]
            """),
            .success("""
            {"iid":17,"head_pipeline":{"status":"failed"}}
            """),
        ]
        let backend = GitLabCodeBackend(shellRunner: fake, host: "gitlab.example.com")
        let rec = try await backend.linkedMRStatus(repoSlug: "group/project", issueNumber: 6)

        XCTAssertNotNil(rec)
        XCTAssertEqual(rec?.number, 17)
        XCTAssertEqual(rec?.state, "OPEN")
        XCTAssertEqual(rec?.isDraft, true)
        XCTAssertEqual(rec?.checksState, "FAILURE")

        // The first call must hit the encoded project path with NO "#iid".
        XCTAssertEqual(fake.calls.first?.args,
                       ["glab", "api", "projects/group%2Fproject/issues/6/related_merge_requests"])
        XCTAssertFalse(fake.calls.first?.args.joined(separator: " ").contains("#") ?? true)
    }

    func testLinkedMRStatusReturnsNilWhenNoRelatedMRs() async throws {
        let fake = FakeShellRunner()
        fake.responses = [.success("[]")]
        let backend = GitLabCodeBackend(shellRunner: fake, host: "gitlab.example.com")
        let rec = try await backend.linkedMRStatus(repoSlug: "group/project", issueNumber: 6)
        XCTAssertNil(rec)
    }
}
