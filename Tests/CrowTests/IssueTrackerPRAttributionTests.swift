import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import Crow

/// PR→session attribution persistence (#693, ADR 0008 follow-up 5).
/// Tests drive `recordPRAttribution` / `updatePRAttributions` directly with
/// explicit `now:` values, so there is no timing dependence, and read back
/// through the store / `PRAttributionRepository` to prove durability.
@MainActor
@Suite("IssueTracker PR→session attribution store")
struct IssueTrackerPRAttributionTests {

    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-pr-attribution-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private func makeTracker(store: JSONStore, appState: AppState = AppState()) -> IssueTracker {
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

    private func message(for uuid: UUID) -> String {
        "feat: thing\n\nCrow-Session: \(uuid.uuidString)\n"
    }

    /// Wrap plain messages as `CommitInfo`s (#694 changed
    /// `recordPRAttribution` to take commits so it can store SHAs; these
    /// tests only exercise the message-derived behavior).
    private func commits(_ messages: String...) -> [CommitInfo] {
        messages.map { CommitInfo(sha: "", message: $0) }
    }

    private func commits(_ messages: [String]) -> [CommitInfo] {
        messages.map { CommitInfo(sha: "", message: $0) }
    }

    private let t0 = Date(timeIntervalSince1970: 1_752_000_000)
    private let t1 = Date(timeIntervalSince1970: 1_752_000_600)

    // MARK: - Capture (recordPRAttribution)

    @Test func multipleTrailersAcrossCommitsMapToOneEntry() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let a = UUID()
        let b = UUID()
        let pr = makePR()

        tracker.recordPRAttribution(
            pr: pr,
            commits: commits(message(for: a), "fix: no trailer\n", message(for: b), message(for: a)),
            now: t0)

        let attribution = store.data.prAttributions?[pr.url]
        #expect(attribution?.sessionIDs == [a, b])   // deduped, first-seen order
        #expect(attribution?.state == "OPEN")
        #expect(attribution?.prNumber == pr.number)
        #expect(attribution?.repoNameWithOwner == pr.repoNameWithOwner)
        #expect(attribution?.mergedAt == nil)
        #expect(attribution?.firstSeenAt == t0)
    }

    @Test func noTrailerCommitsCreateNoEntry() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)

        tracker.recordPRAttribution(
            pr: makePR(),
            commits: commits("fix: external contribution\n\nCo-Authored-By: Someone\n"),
            now: t0)

        #expect(store.data.prAttributions?.isEmpty ?? true)
    }

    @Test func unknownSessionTrailerIsPersistedWhileGateStaysFalse() {
        // Attribution is ground truth (the session may live on another
        // machine or have been reaped); the auto-merge gate's known-session
        // filter is a separate concern and must keep rejecting it.
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let unknown = UUID()
        let pr = makePR()
        let messages = [message(for: unknown)]

        tracker.recordPRAttribution(pr: pr, commits: commits(messages), now: t0)

        #expect(store.data.prAttributions?[pr.url]?.sessionIDs == [unknown])
        #expect(!IssueTracker.crowAuthored(commitMessages: messages, knownSessionIDs: [UUID()]))
    }

    @Test func recaptureMergesNewIDsAndNeverDropsSeenOnes() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let a = UUID()
        let b = UUID()
        let pr = makePR()

        tracker.recordPRAttribution(pr: pr, commits: commits(message(for: a)), now: t0)
        // A rebase dropped the commit carrying `a`; a new commit carries `b`.
        tracker.recordPRAttribution(pr: pr, commits: commits(message(for: b)), now: t1)

        let attribution = store.data.prAttributions?[pr.url]
        #expect(attribution?.sessionIDs == [a, b])
        #expect(attribution?.firstSeenAt == t0)
        #expect(attribution?.updatedAt == t1)
    }

    @Test func noChangeRecaptureWritesNothing() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let a = UUID()
        let pr = makePR()

        tracker.recordPRAttribution(pr: pr, commits: commits(message(for: a)), now: t0)
        tracker.recordPRAttribution(pr: pr, commits: commits(message(for: a)), now: t1)

        // Nothing material changed, so updatedAt must still be the first write.
        #expect(store.data.prAttributions?[pr.url]?.updatedAt == t0)
    }

    // MARK: - State updates (updatePRAttributions)

    @Test func mergeObservationSetsStateAndStampsMergedAtOnce() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let pr = makePR()
        tracker.recordPRAttribution(pr: pr, commits: commits(message(for: UUID())), now: t0)

        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED")], now: t1)
        var attribution = store.data.prAttributions?[pr.url]
        #expect(attribution?.state == "MERGED")
        #expect(attribution?.mergedAt == t1)

        // A later poll observing MERGED again must not move the timestamp.
        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED")], now: t1.addingTimeInterval(600))
        attribution = store.data.prAttributions?[pr.url]
        #expect(attribution?.mergedAt == t1)
        #expect(attribution?.updatedAt == t1)
    }

    @Test func closeObservationLeavesMergedAtNil() {
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)
        let pr = makePR()
        tracker.recordPRAttribution(pr: pr, commits: commits(message(for: UUID())), now: t0)

        tracker.updatePRAttributions(viewerPRs: [makePR(state: "CLOSED")], now: t1)

        let attribution = store.data.prAttributions?[pr.url]
        #expect(attribution?.state == "CLOSED")
        #expect(attribution?.mergedAt == nil)
    }

    @Test func stateUpdatesNeverCreateEntries() {
        // Attribution requires a trailer parse; a polled PR that was never
        // captured must not gain an entry from state updates alone.
        let store = Self.tempStore()
        let tracker = makeTracker(store: store)

        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED")], now: t0)

        #expect(store.data.prAttributions?.isEmpty ?? true)
    }

    // MARK: - End-to-end rollup

    @Test func mergedPRIsCountableInWindowRollupAfterRelaunch() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-pr-attribution-\(UUID().uuidString)")
        let store = JSONStore(directory: dir)
        let tracker = makeTracker(store: store)
        let sessionID = UUID()
        let pr = makePR()

        tracker.recordPRAttribution(pr: pr, commits: commits(message(for: sessionID)), now: t0)
        tracker.updatePRAttributions(viewerPRs: [makePR(state: "MERGED")], now: t1)

        // Reload from disk to prove the rollup works across relaunch.
        let repo = PRAttributionRepository(store: JSONStore(directory: dir))
        let window = DateInterval(start: t0, end: t1.addingTimeInterval(3_600))
        #expect(repo.mergedPRCount(for: sessionID, in: window) == 1)
        #expect(repo.mergedPRCount(for: sessionID, in: DateInterval(start: t1.addingTimeInterval(3_600), duration: 3_600)) == 0)
    }
}
