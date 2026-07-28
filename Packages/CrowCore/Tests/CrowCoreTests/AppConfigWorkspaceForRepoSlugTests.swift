import Foundation
import Testing

@testable import CrowCore

/// Coverage for `AppConfig.workspace(forRepoSlug:)` — the repo→workspace lookup
/// that lets a review clone under `{devRoot}/crow-reviews/` find its workspace's
/// AI gateway, which path-based resolution alone can never do (CROW-891).
///
/// Pure function over in-memory config, so no temp dirs and no `ConfigStore`.

// MARK: - Fixtures

private func ws(
    _ name: String,
    alwaysInclude: [String] = [],
    autoReviewRepos: [String] = [],
    excludeReviewRepos: [String] = [],
    gateway: WorkspaceGateway? = nil
) -> WorkspaceInfo {
    WorkspaceInfo(
        name: name,
        alwaysInclude: alwaysInclude,
        autoReviewRepos: autoReviewRepos,
        excludeReviewRepos: excludeReviewRepos,
        gateway: gateway
    )
}

private let probeGateway = WorkspaceGateway(
    baseURL: "https://gateway.invalid",
    customHeaders: ["x-probe": "value"]
)

// MARK: - Membership

@Test func workspaceForRepoSlugMatchesAlwaysInclude() {
    let config = AppConfig(workspaces: [ws("Acme", alwaysInclude: ["acme/widget"])])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.name == "Acme")
}

@Test func workspaceForRepoSlugMatchesAutoReviewRepos() {
    // Membership is the *union* — a repo named only in autoReviewRepos still
    // belongs to the workspace.
    let config = AppConfig(workspaces: [ws("Acme", autoReviewRepos: ["acme/widget"])])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.name == "Acme")
}

@Test func workspaceForRepoSlugIsCaseInsensitive() {
    let config = AppConfig(workspaces: [ws("Acme", alwaysInclude: ["Acme/Widget"])])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.name == "Acme")

    let lowerConfig = AppConfig(workspaces: [ws("Acme", alwaysInclude: ["acme/widget"])])
    #expect(lowerConfig.workspace(forRepoSlug: "ACME/WIDGET")?.name == "Acme")
}

@Test func workspaceForRepoSlugHonorsGlobs() {
    let config = AppConfig(workspaces: [
        ws("Acme", alwaysInclude: ["acme/*"]),
        ws("Widgets", alwaysInclude: ["*/gadget"]),
    ])
    #expect(config.workspace(forRepoSlug: "acme/anything")?.name == "Acme")
    #expect(config.workspace(forRepoSlug: "other/gadget")?.name == "Widgets")
    #expect(config.workspace(forRepoSlug: "other/unclaimed") == nil)
}

@Test func workspaceForRepoSlugIgnoresExcludeReviewRepos() {
    // excludeReviewRepos hides a repo from the review *board*; it is not a
    // membership statement. A manually started review on an excluded repo still
    // gets the workspace's gateway (CROW-891 decision).
    let config = AppConfig(workspaces: [
        ws(
            "Acme",
            alwaysInclude: ["acme/widget"],
            excludeReviewRepos: ["acme/widget"],
            gateway: probeGateway
        )
    ])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.gateway == probeGateway)
}

// MARK: - No match

@Test func workspaceForRepoSlugReturnsNilWhenUnclaimed() {
    let config = AppConfig(workspaces: [ws("Acme", alwaysInclude: ["acme/*"])])
    #expect(config.workspace(forRepoSlug: "stranger/repo") == nil)
}

@Test func workspaceForRepoSlugReturnsNilForEmptyWorkspaces() {
    #expect(AppConfig().workspace(forRepoSlug: "acme/widget") == nil)
}

@Test func workspaceForRepoSlugReturnsNilForWorkspaceWithNoPatterns() {
    // Both lists empty → claims nothing. Such a workspace is still reachable via
    // the worktree-path fast path.
    let config = AppConfig(workspaces: [ws("Acme", gateway: probeGateway)])
    #expect(config.workspace(forRepoSlug: "acme/widget") == nil)
}

// MARK: - Ambiguity

@Test func workspaceForRepoSlugPrefersExactOverGlob() {
    // The glob is FIRST in config order and still loses — exactness outranks
    // position, so the answer can't flip when workspaces are reordered.
    let config = AppConfig(workspaces: [
        ws("Catchall", alwaysInclude: ["acme/*"]),
        ws("Widget", alwaysInclude: ["acme/widget"]),
    ])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.name == "Widget")
}

@Test func workspaceForRepoSlugBreaksGlobTiesByConfigOrder() {
    let config = AppConfig(workspaces: [
        ws("First", alwaysInclude: ["acme/*"]),
        ws("Second", alwaysInclude: ["acme/*"]),
    ])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.name == "First")
}

@Test func workspaceForRepoSlugBreaksExactTiesByConfigOrder() {
    let config = AppConfig(workspaces: [
        ws("First", alwaysInclude: ["acme/widget"]),
        ws("Second", autoReviewRepos: ["acme/widget"]),
    ])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.name == "First")
}

@Test func workspaceForRepoSlugExactMatchAcrossListsBeatsGlob() {
    // The exact hit lives in autoReviewRepos while the glob is in alwaysInclude —
    // the union is searched as one pattern set.
    let config = AppConfig(workspaces: [
        ws("Catchall", alwaysInclude: ["*"]),
        ws("Widget", autoReviewRepos: ["acme/widget"]),
    ])
    #expect(config.workspace(forRepoSlug: "acme/widget")?.name == "Widget")
    // …and the catch-all still owns everything else it claims.
    #expect(config.workspace(forRepoSlug: "stranger/repo")?.name == "Catchall")
}

// MARK: - Membership ≠ gateway

@Test func workspaceForRepoSlugReturnsWorkspaceWithoutGateway() {
    // The lookup answers "who owns this repo", not "who has a gateway" — the
    // caller guards on `.gateway`.
    let config = AppConfig(workspaces: [ws("Acme", alwaysInclude: ["acme/widget"])])
    let matched = config.workspace(forRepoSlug: "acme/widget")
    #expect(matched?.name == "Acme")
    #expect(matched?.gateway == nil)
}
