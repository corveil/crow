import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import CrowEngine

/// Records label calls. The rest of `CodeBackend` is unused.
private struct RecordingReviewBackend: CodeBackend, @unchecked Sendable {
    let provider: Provider = .github
    let cliName: String = "gh"
    let capabilities: Set<CodeCapability> = [.reviewInProgressLabel]
    let actor: ReviewingLabelActor
    let listing: ReviewingLabelListing
    let ensureError: Error?
    let addError: Error?
    let removeError: Error?

    final class Log: @unchecked Sendable {
        var ensured: [String] = []
        var added: [String] = []
        var removed: [String] = []
    }
    let log = Log()

    func linkedPR(repo: String, branch: String) async throws -> LinkedPR? { nil }
    func ensureMergeLabel(repo: String) async throws {}
    func listMonitoredPRs() async throws -> MonitoredPRListing {
        MonitoredPRListing(viewerPRs: [], reviewRequests: [], viewerLogin: "")
    }
    func prStates(refs: [PRRef], viewerLogin: String?) async throws -> [PRRef: PRRecord] { [:] }
    func fetchCrowAuthoredCommits(prURL: String, repoSlug: String, prNumber: Int) async throws -> [CommitInfo] { [] }
    func findRecentPRsForBranches(_ candidates: [BranchCandidate]) async throws -> [BranchPRMatch] { [] }
    func enableAutoMerge(prURL: String) async throws {}
    func updateBranch(prURL: String) async throws {}
    func fetchPRMetadata(prURL: String) async throws -> PRMetadata {
        PRMetadata(title: "", number: 0, headRefName: "", headRefOid: "", baseRefName: "")
    }

    func ensureReviewingLabel(repo: String) async throws {
        log.ensured.append(repo)
        if let ensureError { throw ensureError }
    }
    func addReviewingLabel(prURL: String) async throws {
        log.added.append(prURL)
        if let addError { throw addError }
    }
    func removeReviewingLabel(prURL: String) async throws {
        log.removed.append(prURL)
        if let removeError { throw removeError }
    }
    func reviewingLabelActor(prURL: String) async throws -> ReviewingLabelActor { actor }
    func listOpenReviewingLabels() async throws -> ReviewingLabelListing { listing }
}

@Suite("ReviewingLabelService", .serialized)
struct ReviewingLabelServiceTests {
    private let url = "https://github.com/acme/app/pull/9"

    private func backend(
        actor: String? = "ada",
        viewer: String = "ada",
        present: Bool = true,
        candidates: [ReviewingLabel.Candidate] = [],
        ensureError: Error? = nil,
        addError: Error? = nil,
        removeError: Error? = nil
    ) -> RecordingReviewBackend {
        RecordingReviewBackend(
            actor: ReviewingLabelActor(labelPresent: present, latestActor: actor, viewerLogin: viewer),
            listing: ReviewingLabelListing(viewerLogin: viewer, candidates: candidates),
            ensureError: ensureError,
            addError: addError,
            removeError: removeError
        )
    }

    @Test func addIsANoOpWhenTheToggleIsOff() async {
        let backend = backend()
        await ReviewingLabelService.addOnReviewStart(
            prURL: url, repo: "acme/app", backend: backend, enabled: false)
        #expect(backend.log.ensured.isEmpty)
        #expect(backend.log.added.isEmpty)
    }

    @Test func addCreatesTheLabelThenAppliesIt() async {
        let backend = backend()
        await ReviewingLabelService.addOnReviewStart(
            prURL: url, repo: "acme/app", backend: backend, enabled: true)
        #expect(backend.log.ensured == ["acme/app"])
        #expect(backend.log.added == [url])
    }

    @Test func aPermissionErrorDoesNotEscapeTheAdd() async {
        let backend = backend(addError: ProviderError.commandFailed("Resource not accessible by integration"))
        await ReviewingLabelService.addOnReviewStart(
            prURL: url, repo: "acme/app", backend: backend, enabled: true)
        #expect(backend.log.added == [url])
    }

    @Test func ensureFailureStillAttemptsTheAdd() async {
        let backend = backend(ensureError: ProviderError.commandFailed("forbidden"))
        await ReviewingLabelService.addOnReviewStart(
            prURL: url, repo: "acme/app", backend: backend, enabled: true)
        #expect(backend.log.added == [url])
    }

    @Test func removeRunsOnlyWhenTheViewerAddedTheLabel() async {
        let mine = backend()
        await ReviewingLabelService.removeIfViewer(prURL: url, backend: mine, enabled: true)
        #expect(mine.log.removed == [url])

        let theirs = backend(actor: "bob")
        await ReviewingLabelService.removeIfViewer(prURL: url, backend: theirs, enabled: true)
        #expect(theirs.log.removed.isEmpty)

        let gone = backend(present: false)
        await ReviewingLabelService.removeIfViewer(prURL: url, backend: gone, enabled: true)
        #expect(gone.log.removed.isEmpty)
    }

    @Test @MainActor func removeSkipsAURLHeldForANewRound() async {
        let backend = backend()
        ReviewingLabelService.hold(url)
        defer { ReviewingLabelService.release(url) }
        await ReviewingLabelService.removeIfViewer(prURL: url, backend: backend, enabled: true)
        #expect(backend.log.removed.isEmpty)
    }

    @Test func removeIsANoOpWhenTheToggleIsOff() async {
        let backend = backend()
        await ReviewingLabelService.removeIfViewer(prURL: url, backend: backend, enabled: false)
        #expect(backend.log.removed.isEmpty)
    }

    @Test func sweepRemovesStaleLabelsTheViewerAdded() async {
        let live = "https://github.com/acme/app/pull/1"
        let stale = "https://github.com/acme/app/pull/2"
        let theirs = "https://github.com/acme/app/pull/3"
        let backend = backend(
            viewer: "ada",
            candidates: [
                ReviewingLabel.Candidate(url: live, latestActor: "ada"),
                ReviewingLabel.Candidate(url: stale, latestActor: "ada"),
                ReviewingLabel.Candidate(url: theirs, latestActor: "bob"),
            ]
        )
        await ReviewingLabelService.sweep(
            livePRURLs: [live], backend: backend, enabled: true)
        #expect(backend.log.removed == [stale])
    }

    @Test func sweepIsANoOpWhenTheToggleIsOff() async {
        let backend = backend(candidates: [
            ReviewingLabel.Candidate(url: url, latestActor: "ada"),
        ])
        await ReviewingLabelService.sweep(livePRURLs: [], backend: backend, enabled: false)
        #expect(backend.log.removed.isEmpty)
    }
}
