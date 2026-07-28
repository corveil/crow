import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// Review #899: the watcher-**off** path guards its verdict on
/// `hasAutoMergeLabel`, but the watcher-**on** absent-PR path published
/// `.notInViewerPRs` for *any* session with a `.pr` link. An ordinary feature
/// PR that aged out of the 50-most-recently-updated-open window would grow an
/// orange ⛙ "Auto-merge waiting" chip it never earned — auto-merge vocabulary
/// on a session that never used auto-merge, which is the exact class of
/// misleading signal #888 exists to remove.
///
/// `pr` is nil on that branch, so the label can't be read off the record; the
/// verdict now gates on prior knowledge instead — the last fetch that *did* see
/// the PR (`prStatus.hasMergeLabel`), or the fact that Crow already armed it
/// (`Session.autoMergeEnabledAt`).
@Suite("Auto-merge verdict is only spoken about PRs that asked for it (#899)")
@MainActor
struct IssueTrackerNotInViewerPRsTests {
    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-notinviewer-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "0E8A16")
    private static let prURL = "https://github.com/corveil/crow/pull/836"

    private func makeTracker(
        autoMergeEnabledAt: Date? = nil
    ) -> (tracker: IssueTracker, sessionID: UUID, state: AppState) {
        let state = AppState()
        let session = Session(name: "feature/x", kind: .work, autoMergeEnabledAt: autoMergeEnabledAt)
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #836", url: Self.prURL, linkType: .pr)
        ]
        let tracker = IssueTracker(appState: state, providerManager: ProviderManager(), store: Self.tempStore())
        // The branch under test sits behind the watcher gate.
        tracker.autoMergeWatcherEnabledProvider = { true }
        return (tracker, session.id, state)
    }

    /// Draft on purpose: it carries the label (so `prStatus.hasMergeLabel`
    /// records that a fetch saw it) but is never an auto-merge candidate, so
    /// nothing dispatches and the in-flight marker stays clear — leaving the
    /// next poll free to reach the absent-PR branch rather than the in-flight one.
    private func labeledDraftPR() -> PRRecord {
        PRRecord(
            number: 836, url: Self.prURL, state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
            isDraft: true, headRefOid: "abc", repoNameWithOwner: "corveil/crow",
            labels: [Self.crowMergeLabel], checksState: "SUCCESS")
    }

    private func unlabeledDraftPR() -> PRRecord {
        PRRecord(
            number: 836, url: Self.prURL, state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
            isDraft: true, headRefOid: "abc", repoNameWithOwner: "corveil/crow",
            labels: [], checksState: "SUCCESS")
    }

    /// Some *other* session's PR. The fetch must be non-empty — an empty one
    /// short-circuits `applyAutoMerge` before the branch under test.
    private func someoneElsesPR() -> PRRecord {
        PRRecord(
            number: 999, url: "https://github.com/corveil/crow/pull/999", state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
            headRefOid: "def", repoNameWithOwner: "corveil/crow", checksState: "SUCCESS")
    }

    @Test func anUnlabeledPRThatFallsOutOfTheFetchGetsNoAutoMergeChip() {
        let (tracker, sessionID, state) = makeTracker()
        // A fetch that saw the PR without the label…
        tracker.applyPRStatuses(viewerPRs: [unlabeledDraftPR()])
        #expect(state.prStatus[sessionID]?.hasMergeLabel == false)

        // …then one that doesn't see it at all.
        tracker.applyPRStatuses(viewerPRs: [someoneElsesPR()])

        #expect(state.autoMergeState[sessionID] == nil,
                "a PR that never asked for auto-merge must not grow an auto-merge chip")
    }

    @Test func aLabeledPRThatFallsOutOfTheFetchStillReportsTheFetchProblem() {
        let (tracker, sessionID, state) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [labeledDraftPR()])
        #expect(state.prStatus[sessionID]?.hasMergeLabel == true)

        tracker.applyPRStatuses(viewerPRs: [someoneElsesPR()])

        let verdict = state.autoMergeState[sessionID]
        #expect(verdict?.reason == "not-in-viewer-prs")
        #expect(verdict?.phase == .stalled, "a fetch gap is transient, not a block")
        #expect(verdict?.permanent == false)
    }

    @Test func anAlreadyArmedSessionReportsItEvenWithoutPriorLabelState() {
        // No prior fetch at all — `prStatus` is empty — but Crow has already
        // enabled auto-merge on this session, which is its own proof the PR
        // asked for it.
        let (tracker, sessionID, state) = makeTracker(autoMergeEnabledAt: Date())
        #expect(state.prStatus[sessionID] == nil)

        tracker.applyPRStatuses(viewerPRs: [someoneElsesPR()])

        #expect(state.autoMergeState[sessionID]?.reason == "not-in-viewer-prs")
    }

    @Test func aStaleVerdictIsClearedWhenTheLabelGoesAway() {
        // Labeled → verdict published. Label removed → the next absent-PR poll
        // must drop the chip rather than leave it lit forever.
        let (tracker, sessionID, state) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [labeledDraftPR()])
        tracker.applyPRStatuses(viewerPRs: [someoneElsesPR()])
        #expect(state.autoMergeState[sessionID] != nil)

        tracker.applyPRStatuses(viewerPRs: [unlabeledDraftPR()])
        tracker.applyPRStatuses(viewerPRs: [someoneElsesPR()])

        #expect(state.autoMergeState[sessionID] == nil)
    }

    @Test func theFetchHealthLogLineIsNotGatedOnTheLabel() {
        // Only the *chip* is gated. `not-in-viewer-prs` in the automation log is
        // a CROW-782 fetch-health signal that predates #888 and still fires for
        // every linked PR missing from the fetch — narrowing it would re-hide
        // the scope/rate-limit problems it was added to surface. Proven
        // indirectly: an unlabeled session reaches the branch (no chip) rather
        // than being skipped earlier, which is what the previous test asserts.
        let (tracker, sessionID, state) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [unlabeledDraftPR()])
        tracker.applyPRStatuses(viewerPRs: [someoneElsesPR()])
        // The session still has a PR link and live status — it was evaluated,
        // just not chipped.
        #expect(state.prStatus[sessionID] != nil)
        #expect(state.autoMergeState[sessionID] == nil)
    }
}
