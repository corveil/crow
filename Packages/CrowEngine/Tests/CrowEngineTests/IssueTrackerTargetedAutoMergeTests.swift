import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// #931: `addMergeLabel` used to end with `await refresh()` — a full
/// multi-provider board poll (4-5s measured) run solely so `autoMergeWarning`
/// could read a freshly populated `autoMergeState`. It now does a targeted
/// per-PR fetch and evaluates that one session through `evaluateAutoMerge`, the
/// *same* function the poll path runs for every session.
///
/// Two things have to hold for that swap to be safe, and both are asserted here:
/// the single-session path must reach the same verdict the poll path would, and
/// the read-your-write label union must survive a fetch that comes back without
/// the label GitHub was told about milliseconds earlier.
@Suite("add-merge-label re-evaluates one session, not the whole board (#931)")
@MainActor
struct IssueTrackerTargetedAutoMergeTests {
    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-targeted-automerge-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "1D76DB")
    private static let prURL = "https://github.com/corveil/crow/pull/931"

    private func makeTracker(
        watcherEnabled: Bool = true,
        autoMergeEnabledAt: Date? = nil
    ) -> (tracker: IssueTracker, session: Session, state: AppState) {
        let state = AppState()
        let session = Session(name: "feature/x", kind: .work, autoMergeEnabledAt: autoMergeEnabledAt)
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #931", url: Self.prURL, linkType: .pr)
        ]
        let tracker = IssueTracker(
            appState: state, providerManager: ProviderManager(), store: Self.tempStore())
        tracker.autoMergeWatcherEnabledProvider = { watcherEnabled }
        return (tracker, session, state)
    }

    /// Labeled, open, and a real auto-merge candidate — but the repo has
    /// GitHub's "Allow auto-merge" off and checks are still running, so it lands
    /// on `.repoDisallowsAutoMergePending`. That branch *publishes a verdict and
    /// dispatches nothing*, which is what these tests need: a real published
    /// verdict, no `Task` spawned, and `autoMergeInFlight` left clear so a second
    /// evaluation reaches the same branch rather than the in-flight one.
    ///
    /// A draft would be simpler but publishes *nothing* — `.draft` maps to a nil
    /// state on purpose (the PR already reads as a draft on screen, so a second
    /// chip would be redundant).
    private func labeledPendingPR() -> PRRecord {
        PRRecord(
            number: 931, url: Self.prURL, state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED",
            isDraft: false, headRefOid: "abc", repoNameWithOwner: "corveil/crow",
            labels: [Self.crowMergeLabel], checksState: "PENDING",
            repoAutoMergeAllowed: false)
    }

    /// The same PR as the provider's read side reports it when it hasn't caught
    /// up with the label we just added.
    private func unlabeledPendingPR() -> PRRecord {
        PRRecord(
            number: 931, url: Self.prURL, state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED",
            isDraft: false, headRefOid: "abc", repoNameWithOwner: "corveil/crow",
            labels: [], checksState: "PENDING",
            repoAutoMergeAllowed: false)
    }

    // MARK: - The extraction is a single code path

    @Test("a single-session evaluation matches what the poll path publishes")
    func targetedEvaluationMatchesThePollPath() {
        let pr = labeledPendingPR()

        // Poll path: every session, through applyPRStatuses → applyAutoMerge.
        let (pollTracker, _, pollState) = makeTracker()
        pollTracker.applyPRStatuses(viewerPRs: [pr])
        let pollVerdict = pollState.autoMergeState[pollState.sessions[0].id]

        // Targeted path: one session, one-entry snapshot.
        let (oneTracker, oneSession, oneState) = makeTracker()
        oneTracker.evaluateAutoMerge(session: oneSession, byURL: [Self.prURL: pr])
        let oneVerdict = oneState.autoMergeState[oneSession.id]

        #expect(pollVerdict != nil, "the poll path publishes a verdict for this PR")
        #expect(oneVerdict?.reason == pollVerdict?.reason)
        #expect(oneVerdict?.phase == pollVerdict?.phase)
    }

    @Test("the watcher-off verdict is the same from either caller")
    func watcherOffVerdictMatchesThePollPath() {
        let pr = labeledPendingPR()

        let (pollTracker, _, pollState) = makeTracker(watcherEnabled: false)
        pollTracker.applyPRStatuses(viewerPRs: [pr])
        let pollVerdict = pollState.autoMergeState[pollState.sessions[0].id]

        let (oneTracker, oneSession, oneState) = makeTracker(watcherEnabled: false)
        oneTracker.publishWatcherOffVerdict(session: oneSession, byURL: [Self.prURL: pr])

        #expect(pollVerdict != nil)
        #expect(oneState.autoMergeState[oneSession.id]?.reason == pollVerdict?.reason)
    }

    // MARK: - Read-your-write

    @Test("withLabels preserves every field, including repoAutoMergeAllowed")
    func withLabelsIsAFullCopy() {
        // `repoAutoMergeAllowed` decides a branch in `evaluateAutoMerge`, and
        // `withURL` (the older sibling helper) drops it — so this must not.
        let pr = PRRecord(
            number: 931, url: Self.prURL, state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: "BEHIND", reviewDecision: "APPROVED",
            headRefName: "feature/x", headRefOid: "abc", baseRefName: "main",
            repoNameWithOwner: "corveil/crow", labels: [], checksState: "SUCCESS",
            mergeCommitOid: "deadbeef", repoAutoMergeAllowed: false)

        let relabeled = IssueTracker.withLabels(pr, labels: [Self.crowMergeLabel])

        #expect(IssueTracker.hasAutoMergeLabel(pr: relabeled))
        #expect(relabeled.repoAutoMergeAllowed == false)
        #expect(relabeled.mergeCommitOid == "deadbeef")
        #expect(relabeled.mergeStateStatus == "BEHIND")
        #expect(relabeled.headRefOid == "abc")
        #expect(relabeled.baseRefName == "main")
        #expect(relabeled.url == Self.prURL)
    }

    @Test("a fetch that lags the label still evaluates as labeled")
    func aLaggingFetchStillEvaluatesAsLabeled() {
        // `backend.addMergeLabel` threw on failure, so the label provably IS on
        // the PR — but GitHub's read side can lag a fetch issued milliseconds
        // later. Without the union, the evaluation reads "no merge label",
        // publishes nothing, dispatches nothing, and the user gets a bare
        // success for a label the watcher won't look at until the next poll:
        // #888's exact shape.
        let (tracker, session, state) = makeTracker()
        let lagging = unlabeledPendingPR()

        tracker.evaluateAutoMerge(session: session, byURL: [Self.prURL: lagging])
        #expect(state.autoMergeState[session.id] == nil,
                "without the union an unlabeled record earns no auto-merge verdict")

        let unioned = IssueTracker.withLabels(lagging, labels: lagging.labels + [Self.crowMergeLabel])
        tracker.evaluateAutoMerge(session: session, byURL: [Self.prURL: unioned])
        #expect(state.autoMergeState[session.id] != nil,
                "the read-your-write union makes the targeted pass see the label it just added")
    }

    // MARK: - A failed targeted fetch must not become a false alarm

    @Test("an empty targeted fetch stalls rather than warning")
    func anEmptyFetchDoesNotProduceAWarning() {
        // Crow already armed this PR, so `.notInViewerPRs` is the honest verdict
        // — but it is `.stalled`, and `autoMergeWarning` only speaks for
        // `.blocked`. `addMergeLabel` therefore returns nil: an honest success
        // for a label that really did land, not a false alarm about a fetch.
        let (tracker, session, state) = makeTracker(autoMergeEnabledAt: Date())

        let outcome = tracker.evaluateAutoMerge(session: session, byURL: [:])

        #expect(outcome.dispatch == .none)
        #expect(outcome.skip?.contains("not-in-viewer-prs") == true)
        #expect(state.autoMergeState[session.id]?.phase == .stalled)
        #expect(tracker.autoMergeWarning(sessionID: session.id) == nil)
    }

    @Test("an empty targeted fetch on a never-armed PR says nothing at all")
    func anEmptyFetchOnANeverArmedPRIsSilent() {
        // Review #899: auto-merge vocabulary only for PRs that asked for it.
        let (tracker, session, state) = makeTracker()

        tracker.evaluateAutoMerge(session: session, byURL: [:])

        #expect(state.autoMergeState[session.id] == nil)
        #expect(tracker.autoMergeWarning(sessionID: session.id) == nil)
    }

    @Test("the watcher-off warning does not depend on any fetch succeeding")
    func watcherOffWarningIsIndependentOfTheFetch() {
        // The one warning `addMergeLabel` can still return when the targeted
        // fetch comes back empty — it's read off the setting, not off a PR.
        let (tracker, session, _) = makeTracker(watcherEnabled: false)

        let warning = tracker.autoMergeWarning(sessionID: session.id)

        #expect(warning?.contains("auto-merge watcher is off") == true)
    }
}
