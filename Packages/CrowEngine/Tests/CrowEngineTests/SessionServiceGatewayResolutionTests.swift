import Foundation
import Testing
import CrowCore
@testable import CrowEngine

/// Coverage for gateway workspace resolution: the pure `gatewayMatch` rule that
/// decides which workspace claims a session (CROW-891, CROW-969), plus the two
/// path/link helpers it is built from.
///
/// `gatewayMatch` takes its devRoot and config as parameters, so the whole
/// two-lookup rule is exercised here directly. Only the thin
/// `workspaceGatewayMatch(for:)` wrapper remains untestable — it reads
/// `ConfigStore.loadDevRoot()`, which is all-static with no injection seam, so
/// exercising it would mean touching the live devroot pointer, which ADR 0012
/// forbids. That wrapper contributes no decisions of its own.
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

    /// …and because that literal *is* a plausible workspace name, resolution must
    /// treat it as reserved rather than looking it up. A workspace that had taken
    /// the name would otherwise match the path fast path and capture every review
    /// session, shadowing the slug fallback entirely (PR #898 review).
    @Test func reviewCloneDirNameIsReservedForWorkspaces() {
        let path = "\(Self.devRoot)/crow-reviews/props-pr-42"
        let wsName = SessionService.workspaceName(
            forWorktreePath: path, devRoot: Self.devRoot)
        #expect(wsName.map(DevRootLayout.isReservedWorkspaceName) == true)
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

    // MARK: - gatewayMatch(worktreePath:prLinks:devRoot:config:) — the whole rule
    //
    // The two lookups above, composed. This is what decides which gateway a
    // session launches with, and — because the lookups can land on *different*
    // workspaces for the same repo — why a work session and a review of that
    // repo's PR can resolve differently (CROW-969).

    private static func gateway(_ url: String) -> WorkspaceGateway {
        WorkspaceGateway(baseURL: url, customHeaders: ["x-api-key": "sk-1"])
    }

    /// Spotlight owns a folder; Corveil claims the repo by slug. Their gateways
    /// differ, so every test below can tell which lookup won.
    private static func config() -> AppConfig {
        var config = AppConfig()
        config.workspaces = [
            WorkspaceInfo(
                name: "Spotlight",
                gateway: gateway("https://spotlight.gw")),
            WorkspaceInfo(
                name: "Corveil",
                alwaysInclude: ["acme/*"],
                gateway: gateway("https://corveil.gw")),
        ]
        return config
    }

    private static func match(
        path: String?, links: [SessionLink] = [], config: AppConfig? = nil
    ) -> SessionService.GatewayMatch? {
        SessionService.gatewayMatch(
            worktreePath: path, prLinks: links,
            devRoot: devRoot, config: config ?? Self.config())
    }

    @Test func matchByWorktreePath() throws {
        let match = try #require(
            Self.match(path: "\(Self.devRoot)/Spotlight/props-197-fix-tab"))
        #expect(match.workspaceName == "Spotlight")
        #expect(match.source == .worktreePath)
        #expect(match.gateway?.baseURL == "https://spotlight.gw")
    }

    /// The CROW-891 fallback: a review clone's path yields `crow-reviews`, which
    /// is reserved, so the PR link's `owner/repo` decides instead.
    @Test func matchByRepoSlugForReviewClone() throws {
        let match = try #require(Self.match(
            path: "\(Self.devRoot)/crow-reviews/widget-pr-42",
            links: [Self.prLink("https://github.com/acme/widget/pull/42")]))
        #expect(match.workspaceName == "Corveil")
        #expect(match.source == .repoSlug)
        #expect(match.gateway?.baseURL == "https://corveil.gw")
    }

    /// Pins lookup order. This is the CROW-969 divergence in one assertion: the
    /// same repo resolves to Spotlight from a worktree and to Corveil from a
    /// review clone, because only the path lookup can tell apart two workspaces
    /// sharing a repo.
    @Test func pathMatchWinsOverSlug() throws {
        let match = try #require(Self.match(
            path: "\(Self.devRoot)/Spotlight/widget-197",
            links: [Self.prLink("https://github.com/acme/widget/pull/42")]))
        #expect(match.workspaceName == "Spotlight")
        #expect(match.source == .worktreePath)
    }

    /// The fallback is gated on the path lookup failing, not on `kind == .review`
    /// — a work session whose worktree sits outside any workspace folder should
    /// still inherit its repo's gateway once its PR opens.
    @Test func slugFallbackRunsForWorkSessionWhosePathMissed() throws {
        let match = try #require(Self.match(
            path: "/somewhere/else/widget",
            links: [Self.prLink("https://github.com/acme/widget/pull/42")]))
        #expect(match.source == .repoSlug)
    }

    @Test func noMatchWhenNothingClaims() {
        #expect(Self.match(path: "/somewhere/else/widget") == nil)
        // A PR link whose repo no workspace claims.
        #expect(Self.match(
            path: nil,
            links: [Self.prLink("https://github.com/other/unclaimed/pull/1")]) == nil)
    }

    /// The state the old resolver collapsed by discarding its match: a workspace
    /// claimed the session and simply has no gateway. Behaviorally identical to
    /// "nothing claimed it" (`ANTHROPIC_*` unset) but a different fix, so the two
    /// must stay distinguishable.
    @Test func matchedWorkspaceWithNoGatewayStillMatches() throws {
        var config = AppConfig()
        config.workspaces = [WorkspaceInfo(name: "Spotlight", gateway: nil)]
        let match = try #require(
            Self.match(path: "\(Self.devRoot)/Spotlight/props-197", config: config))
        #expect(match.workspaceName == "Spotlight")
        #expect(match.gateway == nil)
    }

    /// APFS is case-preserving but case-insensitive, so an on-disk folder can
    /// differ in case from the configured name and still be the same directory.
    @Test func pathMatchIsCaseInsensitive() throws {
        let match = try #require(Self.match(path: "\(Self.devRoot)/spotlight/props-197"))
        #expect(match.workspaceName == "Spotlight")
    }

    /// A workspace that took the reserved name would otherwise match the path
    /// fast path for *every* review and shadow the slug fallback entirely.
    /// `validateName` rejects the name now, but configs written before it still
    /// have to resolve correctly (PR #898 review).
    @Test func reviewCloneIsNotCapturedByAWorkspaceNamedCrowReviews() throws {
        var config = Self.config()
        config.workspaces.insert(
            WorkspaceInfo(name: "crow-reviews", gateway: Self.gateway("https://wrong.gw")),
            at: 0)
        let match = try #require(Self.match(
            path: "\(Self.devRoot)/crow-reviews/widget-pr-42",
            links: [Self.prLink("https://github.com/acme/widget/pull/42")],
            config: config))
        #expect(match.workspaceName == "Corveil")
        #expect(match.source == .repoSlug)
    }
}
