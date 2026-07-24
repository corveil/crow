import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// #838 regression: after a successful `addMergeLabel`, the merge icon must
/// stay lit until a fetch actually confirms `crow:merge`. The failure it
/// guards: an in-flight poll that started *before* the label was added
/// overwrites `appState.prStatus` in `applyPRStatuses` with pre-label data,
/// clearing the optimistic flag and re-introducing "stuck until the next
/// scheduled poll". The sticky `pendingMergeLabelSessions` marker ORs
/// `hasMergeLabel` across that clobber and clears itself once the label lands.
@Suite("IssueTracker crow:merge sticky optimistic flag (#838)")
@MainActor
struct IssueTrackerMergeLabelStickyTests {
    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-merge-sticky-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "0E8A16")
    private static let prURL = "https://github.com/corveil/crow/pull/836"

    private func makeTracker() -> (tracker: IssueTracker, sessionID: UUID, state: AppState) {
        let state = AppState()
        let session = Session(name: "feature/merge-sticky", kind: .work)
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #836", url: Self.prURL, linkType: .pr)
        ]
        let tracker = IssueTracker(appState: state, providerManager: ProviderManager(), store: Self.tempStore())
        return (tracker, session.id, state)
    }

    private func makePR(labels: [LabelInfo]) -> PRRecord {
        PRRecord(
            number: 836,
            url: Self.prURL,
            state: "OPEN",
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED",
            isDraft: false,
            headRefName: "feature/merge-sticky",
            headRefOid: "abc1234",
            baseRefName: "main",
            repoNameWithOwner: "corveil/crow",
            labels: labels,
            linkedIssueReferences: [],
            checksState: "SUCCESS",
            failedCheckNames: [],
            latestReviewStates: ["APPROVED"]
        )
    }

    @Test func stickyMarkerKeepsIconLitWhenInFlightPollLacksTheLabel() {
        // Simulates the clobber: a poll whose payload predates the label add
        // (labels: []) lands while the session is marked pending.
        let (tracker, sessionID, state) = makeTracker()
        tracker.pendingMergeLabelSessions = [sessionID]

        tracker.applyPRStatuses(viewerPRs: [makePR(labels: [])])

        // Icon stays lit despite the stale snapshot...
        #expect(state.prStatus[sessionID]?.hasMergeLabel == true)
        // ...and the marker persists until a fetch confirms the label.
        #expect(tracker.pendingMergeLabelSessions.contains(sessionID))
    }

    @Test func stickyMarkerClearsOnceAFetchConfirmsTheLabel() {
        // Durable path (stale-query labels + union) catches up: the next
        // snapshot carries crow:merge, so the marker is dropped and the flag
        // now stands on real data.
        let (tracker, sessionID, state) = makeTracker()
        tracker.pendingMergeLabelSessions = [sessionID]

        tracker.applyPRStatuses(viewerPRs: [makePR(labels: [Self.crowMergeLabel])])

        #expect(state.prStatus[sessionID]?.hasMergeLabel == true)
        #expect(!tracker.pendingMergeLabelSessions.contains(sessionID))
    }

    @Test func clobberThenConfirmKeepsIconLitThroughout() {
        // The full sequence: pending → stale poll (no label, sticky lit) →
        // real poll (label present, marker clears). The icon is true at every
        // step, so the user never sees it flicker off.
        let (tracker, sessionID, state) = makeTracker()
        tracker.pendingMergeLabelSessions = [sessionID]

        tracker.applyPRStatuses(viewerPRs: [makePR(labels: [])])
        #expect(state.prStatus[sessionID]?.hasMergeLabel == true)

        tracker.applyPRStatuses(viewerPRs: [makePR(labels: [Self.crowMergeLabel])])
        #expect(state.prStatus[sessionID]?.hasMergeLabel == true)
        #expect(!tracker.pendingMergeLabelSessions.contains(sessionID))
    }

    @Test func afterClearAGenuineLabelRemovalIsReflected() {
        // Once the marker is cleared, the sticky path must not mask a real
        // later removal — hasMergeLabel follows the fetched data again.
        let (tracker, sessionID, state) = makeTracker()
        tracker.pendingMergeLabelSessions = [sessionID]

        tracker.applyPRStatuses(viewerPRs: [makePR(labels: [Self.crowMergeLabel])]) // confirms + clears
        tracker.applyPRStatuses(viewerPRs: [makePR(labels: [])])                    // label removed

        #expect(state.prStatus[sessionID]?.hasMergeLabel == false)
        #expect(!tracker.pendingMergeLabelSessions.contains(sessionID))
    }

    @Test func markerForADeletedSessionIsPruned() {
        // A session deleted mid-window must not leak its marker. applyPRStatuses
        // intersects pending markers with live sessions each pass.
        let (tracker, sessionID, _) = makeTracker()
        let ghostID = UUID() // never in appState.sessions
        tracker.pendingMergeLabelSessions = [sessionID, ghostID]

        tracker.applyPRStatuses(viewerPRs: [makePR(labels: [])])

        #expect(!tracker.pendingMergeLabelSessions.contains(ghostID))
    }
}
