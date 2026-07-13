import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import Crow

/// #699: the v2 combined score reads PR attributions through the read-only
/// `AppState.prAttributions` mirror (CrowUI cannot import CrowPersistence).
/// These tests lock in that the mirror is hydrated on load and resynced by
/// every IssueTracker attribution write path — the same contract
/// `ScorecardWiringTests` locks in for analytics snapshots.
@MainActor
@Suite("PR attribution mirror wiring")
struct PRAttributionMirrorWiringTests {

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-pr-attribution-mirror-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private func makeTracker(store: JSONStore, appState: AppState) -> IssueTracker {
        IssueTracker(appState: appState, providerManager: ProviderManager(), store: store)
    }

    private func makePR(
        url: String = "https://github.com/corveil/crow/pull/42",
        number: Int = 42,
        state: String = "OPEN",
        repo: String = "corveil/crow"
    ) -> IssueTracker.ViewerPR {
        IssueTracker.ViewerPR(
            number: number,
            url: url,
            state: state,
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED",
            isDraft: false,
            headRefName: "feature/x",
            headRefOid: "abc1234",
            baseRefName: "main",
            repoNameWithOwner: repo,
            labels: [],
            linkedIssueReferences: [],
            checksState: "SUCCESS",
            failedCheckNames: [],
            latestReviewStates: ["APPROVED"]
        )
    }

    private func mergedAttribution(
        url: String,
        number: Int,
        firstSeenAt: Date,
        mergedAt: Date?,
        files: [String]?
    ) -> PRSessionAttribution {
        PRSessionAttribution(
            prURL: url,
            repoNameWithOwner: "corveil/crow",
            prNumber: number,
            sessionIDs: [UUID()],
            state: mergedAt != nil ? "MERGED" : "OPEN",
            mergedAt: mergedAt,
            firstSeenAt: firstSeenAt,
            updatedAt: firstSeenAt,
            changedFiles: files
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_752_000_600)
    private let t2 = Date(timeIntervalSince1970: 1_752_001_200)

    @Test
    func hydrateStatePopulatesPRAttributionMirror() {
        let store = Self.tempStore()
        let persisted = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/1", number: 1,
            firstSeenAt: t0, mergedAt: t1, files: nil)
        store.mutate { $0.prAttributions = [persisted.prURL: persisted] }

        let appState = AppState()
        let service = SessionService(store: store, appState: appState)
        service.hydrateState()

        #expect(appState.prAttributions == [persisted.prURL: persisted])
    }

    @Test
    func hydrateStateWithNoAttributionsLeavesMirrorEmpty() {
        let appState = AppState()
        let service = SessionService(store: Self.tempStore(), appState: appState)
        service.hydrateState()
        #expect(appState.prAttributions.isEmpty)
    }

    @Test
    func recordPRAttributionSyncsMirror() {
        let store = Self.tempStore()
        let appState = AppState()
        let tracker = makeTracker(store: store, appState: appState)
        let pr = makePR()
        let sessionID = UUID()

        tracker.recordPRAttribution(
            pr: pr,
            commits: [CommitInfo(sha: "abc1234", message: "feat: thing\n\nCrow-Session: \(sessionID.uuidString)\n")],
            now: t0)

        #expect(appState.prAttributions == (store.data.prAttributions ?? [:]))
        #expect(appState.prAttributions[pr.url]?.sessionIDs == [sessionID])
    }

    @Test
    func updatePRAttributionsSyncsMirrorOnStateTransition() {
        let store = Self.tempStore()
        let appState = AppState()
        let tracker = makeTracker(store: store, appState: appState)
        let pr = makePR()
        let sessionID = UUID()
        tracker.recordPRAttribution(
            pr: pr,
            commits: [CommitInfo(sha: "abc1234", message: "feat: thing\n\nCrow-Session: \(sessionID.uuidString)\n")],
            now: t0)

        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED")], now: t1)

        #expect(appState.prAttributions == (store.data.prAttributions ?? [:]))
        #expect(appState.prAttributions[pr.url]?.state == "MERGED")
        #expect(appState.prAttributions[pr.url]?.mergedAt == t1)
    }

    @Test
    func detectPostMergeFixesSyncsMirror() {
        let store = Self.tempStore()
        let appState = AppState()
        let tracker = makeTracker(store: store, appState: appState)
        let fixed = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/1", number: 1,
            firstSeenAt: t0, mergedAt: t0, files: ["Sources/App/Foo.swift"])
        let fix = mergedAttribution(
            url: "https://github.com/corveil/crow/pull/2", number: 2,
            firstSeenAt: t1, mergedAt: t2, files: ["Sources/App/Foo.swift"])
        store.mutate { $0.prAttributions = [fixed.prURL: fixed, fix.prURL: fix] }

        tracker.detectPostMergeFixes(now: t2)

        #expect(appState.prAttributions == (store.data.prAttributions ?? [:]))
        #expect(appState.prAttributions[fixed.prURL]?.postMergeFixes?.first?.fixPRURL == fix.prURL)
    }
}
