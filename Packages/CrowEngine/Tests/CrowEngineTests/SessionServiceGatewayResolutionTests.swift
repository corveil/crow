import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Coverage for the two pure helpers behind `workspaceGatewayResolved` — the
/// path lookup that names a session's workspace, and the PR-link lookup that
/// names its repo (CROW-891).
///
/// `workspaceGatewayResolved` itself isn't directly testable: it reads
/// `ConfigStore.loadDevRoot()`, which is all-static with no injection seam, and
/// `SessionService.init` takes no devRoot/config — so exercising it would mean
/// touching the live devroot pointer, which ADR 0012 forbids. Every *decision*
/// it makes lives in these two helpers plus `AppConfig.workspace(forRepoSlug:)`
/// (covered in CrowCore), so testing them covers the resolution logic without
/// standing up the terminal machinery.
@Suite("Gateway workspace resolution")
struct SessionServiceGatewayResolutionTests {

    private static let devRoot = "/Users/dev/Dev"

    // MARK: - workspaceName(forWorktreePath:devRoot:) — the path fast path

    /// The worker/job layout: `{devRoot}/{workspace}/{repo}-{n}-{slug}`.
    @Test func workspaceNameFromStandardWorktreePath() {
        let path = "\(Self.devRoot)/Spotlight/props-197-fix-tab-url-hash"
        #expect(
            SessionService.workspaceName(forWorktreePath: path, devRoot: Self.devRoot)
                == "Spotlight")
    }

    /// The CROW-891 root cause, pinned as an executable assertion: a review clone
    /// lives in a flat sibling directory, so path math yields the literal
    /// `"crow-reviews"` — never a workspace name. This is why the repo-slug
    /// fallback has to exist.
    @Test func workspaceNameOfReviewCloneIsCrowReviews() {
        let path = "\(Self.devRoot)/crow-reviews/props-pr-42"
        #expect(
            SessionService.workspaceName(forWorktreePath: path, devRoot: Self.devRoot)
                == "crow-reviews")
    }

    @Test func workspaceNameNilOutsideDevRoot() {
        #expect(
            SessionService.workspaceName(
                forWorktreePath: "/somewhere/else/props", devRoot: Self.devRoot) == nil)
    }

    /// devRoot itself has no component under it — the `hasPrefix(root + "/")`
    /// guard rejects it rather than returning the dev-root folder's own name.
    @Test func workspaceNameNilForDevRootItself() {
        #expect(
            SessionService.workspaceName(forWorktreePath: Self.devRoot, devRoot: Self.devRoot)
                == nil)
    }

    @Test func workspaceNameStandardizesPaths() {
        let path = "\(Self.devRoot)/Spotlight/../Spotlight/props-197"
        #expect(
            SessionService.workspaceName(forWorktreePath: path, devRoot: Self.devRoot)
                == "Spotlight")
    }

    // MARK: - repoSlug(fromPRLinks:) — the review fallback's input

    private static func prLink(_ url: String) -> SessionLink {
        SessionLink(sessionID: UUID(), label: "PR", url: url, linkType: .pr)
    }

    @Test func repoSlugFromGitHubPRLink() {
        let links = [Self.prLink("https://github.com/acme/widget/pull/42")]
        #expect(SessionService.repoSlug(fromPRLinks: links) == "acme/widget")
    }

    /// A ticket URL is the same shape as a PR URL in the segments the parser
    /// reads, so selection has to key on `linkType`, not on parseability.
    @Test func repoSlugIgnoresNonPRLinks() {
        let sessionID = UUID()
        let links = [
            SessionLink(
                sessionID: sessionID, label: "Issue",
                url: "https://github.com/other/repo/issues/7", linkType: .ticket),
            SessionLink(
                sessionID: sessionID, label: "Repo",
                url: "https://github.com/other/repo", linkType: .repo),
        ]
        #expect(SessionService.repoSlug(fromPRLinks: links) == nil)
    }

    /// First *parseable* PR link, not first PR link — a malformed one is skipped
    /// rather than poisoning resolution for the whole session.
    @Test func repoSlugReturnsFirstParseableLink() {
        let links = [
            Self.prLink("not a url"),
            Self.prLink("https://github.com/acme/widget/pull/42"),
        ]
        #expect(SessionService.repoSlug(fromPRLinks: links) == "acme/widget")
    }

    @Test func repoSlugReturnsNilWithNoLinks() {
        #expect(SessionService.repoSlug(fromPRLinks: []) == nil)
    }

    /// GitLab MR URLs don't fit `parseReviewPR`'s trailing-5-segment shape, so
    /// they yield a slug that claims no workspace → gateway unset, which is
    /// exactly the pre-CROW-891 behavior (no regression). The mis-parse is
    /// upstream — `createReviewSession` names the clone with the same parser.
    /// Pinned so a future GitLab fix updates this consciously rather than drifts.
    @Test func repoSlugForGitLabMRIsMalformedButStable() {
        let links = [Self.prLink("https://gitlab.com/group/proj/-/merge_requests/12")]
        #expect(SessionService.repoSlug(fromPRLinks: links) == "proj/-")
    }
}
