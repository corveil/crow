import Foundation
import Testing
@testable import CrowCore

@Suite struct BackfillReconstructionTests {

    // MARK: - RepoRemote.parse

    @Test func parsesHTTPSRemote() {
        let r = RepoRemote.parse("https://github.com/corveil/crow.git")
        #expect(r == RepoRemote(host: "github.com", owner: "corveil", repo: "crow"))
        #expect(r?.slug == "corveil/crow")
        #expect(r?.isGitHub == true)
    }

    @Test func parsesScpLikeRemote() {
        let r = RepoRemote.parse("git@github.com:RadiusMethod/corveil.git")
        #expect(r == RepoRemote(host: "github.com", owner: "RadiusMethod", repo: "corveil"))
    }

    @Test func parsesGitLabSubgroupsIntoOwnerPath() {
        let r = RepoRemote.parse("https://repo1.dso.mil/big-bang/product/packages/grafana.git")
        #expect(r?.host == "repo1.dso.mil")
        #expect(r?.owner == "big-bang/product/packages")
        #expect(r?.repo == "grafana")
        #expect(r?.isGitHub == false)
    }

    @Test func rejectsNonRemoteStrings() {
        #expect(RepoRemote.parse("") == nil)
        #expect(RepoRemote.parse("/some/local/path") == nil)
        #expect(RepoRemote.parse("git@github.com") == nil) // no path
    }

    // MARK: - workspace / worktree from cwd

    @Test func derivesWorkspaceAndWorktreeFromCwd() {
        let dev = "/Users/j/Dev2"
        let cwd = "/Users/j/Dev2/RadiusMethod/crow-1075-session-backfill"
        #expect(BackfillReconstructor.workspace(cwd: cwd, devRoot: dev) == "RadiusMethod")
        #expect(BackfillReconstructor.worktreeName(cwd: cwd, devRoot: dev) == "crow-1075-session-backfill")
    }

    @Test func cwdOutsideDevRootHasNoWorkspace() {
        let dev = "/Users/j/Dev2"
        let cwd = "/Users/j/Downloads/scratch"
        #expect(BackfillReconstructor.workspace(cwd: cwd, devRoot: dev) == nil)
        #expect(BackfillReconstructor.worktreeName(cwd: cwd, devRoot: dev) == nil)
    }

    @Test func cwdAtWorkspaceRootHasNoWorktree() {
        let dev = "/Users/j/Dev2"
        #expect(BackfillReconstructor.workspace(cwd: "/Users/j/Dev2/RadiusMethod", devRoot: dev) == "RadiusMethod")
        #expect(BackfillReconstructor.worktreeName(cwd: "/Users/j/Dev2/RadiusMethod", devRoot: dev) == nil)
    }

    // MARK: - parseWorktree

    @Test func parsesSimpleWorktreeWithKnownRepo() {
        let (repo, ticket) = BackfillReconstructor.parseWorktree(
            "crow-1075-session-backfill", knownRepoNames: ["crow", "corveil"])
        #expect(repo == "crow")
        #expect(ticket == 1075)
    }

    @Test func knownRepoDisambiguatesMultiDashRepoName() {
        // The hard case: `corveil-cloud-terraform` is a repo, so 331 is the
        // ticket — not `corveil` with ticket "cloud".
        let (repo, ticket) = BackfillReconstructor.parseWorktree(
            "corveil-cloud-terraform-331-right-size-api-task",
            knownRepoNames: ["corveil", "crow", "corveil-cloud-terraform"])
        #expect(repo == "corveil-cloud-terraform")
        #expect(ticket == 331)
    }

    @Test func fallsBackToGenericSplitWithoutKnownRepo() {
        let (repo, ticket) = BackfillReconstructor.parseWorktree(
            "alloy-2520-receiver-traces", knownRepoNames: [])
        #expect(repo == "alloy")
        #expect(ticket == 2520)
    }

    @Test func parsesReviewClone() {
        let (repo, ticket) = BackfillReconstructor.parseWorktree(
            "corveil-cloud-terraform-pr-319", knownRepoNames: [])
        #expect(repo == "corveil-cloud-terraform")
        #expect(ticket == 319)
    }

    @Test func worktreeWithNoNumberYieldsRepoOnly() {
        let (repo, ticket) = BackfillReconstructor.parseWorktree(
            "codename-spotlight", knownRepoNames: ["codename-spotlight"])
        #expect(repo == "codename-spotlight")
        #expect(ticket == nil)
    }

    // MARK: - ticketNumber(fromBranch:)

    @Test func extractsTicketNumberFromBranch() {
        #expect(BackfillReconstructor.ticketNumber(fromBranch: "feature/crow-1075-session-backfill") == 1075)
        #expect(BackfillReconstructor.ticketNumber(fromBranch: "feature/corveil-2100-sonnet-5-billing-rate") == 2100)
    }

    @Test func branchWithNoDashDelimitedNumberIsNil() {
        #expect(BackfillReconstructor.ticketNumber(fromBranch: "main") == nil)
        #expect(BackfillReconstructor.ticketNumber(fromBranch: "feature/cleanup-v2") == nil) // trailing, no closing dash
    }

    // MARK: - confidence

    @Test func confidenceTiers() {
        #expect(BackfillReconstructor.confidence(workspace: "R", repoName: "crow", ticket: 1) == .high)
        #expect(BackfillReconstructor.confidence(workspace: "R", repoName: "crow", ticket: nil) == .medium)
        #expect(BackfillReconstructor.confidence(workspace: "R", repoName: nil, ticket: nil) == .medium)
        #expect(BackfillReconstructor.confidence(workspace: nil, repoName: nil, ticket: nil) == .low)
    }

    // MARK: - ticketURL

    @Test func buildsValidatedTicketURLs() {
        let gh = RepoRemote(host: "github.com", owner: "corveil", repo: "crow")
        #expect(BackfillReconstructor.ticketURL(remote: gh, number: 12, kind: .issue)
            == "https://github.com/corveil/crow/issues/12")
        #expect(BackfillReconstructor.ticketURL(remote: gh, number: 12, kind: .pullRequest)
            == "https://github.com/corveil/crow/pull/12")
    }

    @Test func unvalidatedTicketHasNoURL() {
        let gh = RepoRemote(host: "github.com", owner: "corveil", repo: "crow")
        #expect(BackfillReconstructor.ticketURL(remote: gh, number: 12, kind: .unvalidated) == nil)
        #expect(BackfillReconstructor.ticketURL(remote: gh, number: nil, kind: .issue) == nil)
    }
}
