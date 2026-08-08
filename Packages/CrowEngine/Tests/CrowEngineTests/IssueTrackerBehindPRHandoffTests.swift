import Foundation
import Testing
import CrowCore
import CrowPersistence
import CrowProvider
@testable import CrowEngine

/// #944 — the two watcher-coordination bugs that let a behind-but-clean PR sit
/// untouched forever, exercised through the real dispatch bookkeeping rather
/// than the pure predicates.
///
/// Every session here uses `provider = .corveil` on purpose: it has no
/// `CodeBackend`, so `codeBackend(for:)` returns nil and a dispatched `Task`
/// can only log — it can never shell out to `gh`. That is also exactly the
/// no-backend return path the leak regression needs.
@Suite("Auto-rebase / auto-merge hand-off and in-flight leaks (#944)")
@MainActor
struct IssueTrackerBehindPRHandoffTests {
    private static func tempStore() -> JSONStore {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crow-944-\(UUID().uuidString)")
        return JSONStore(directory: dir)
    }

    private static let prURL = "https://github.com/corveil/crow/pull/944"
    private static let head = "deadbeef"
    private static let crowMergeLabel = LabelInfo(name: "crow:merge", color: "1D76DB")
    private static var headKey: String { "\(prURL)\n\(head)" }

    private func makeTracker() -> (tracker: IssueTracker, session: Session, state: AppState) {
        let state = AppState()
        var session = Session(name: "feature/x", kind: .work)
        session.provider = .corveil
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #944", url: Self.prURL, linkType: .pr)
        ]
        let tracker = IssueTracker(
            appState: state, providerManager: ProviderManager(), store: Self.tempStore())
        tracker.autoMergeWatcherEnabledProvider = { true }
        tracker.autoRebaseAndResolveConflictsProvider = { true }
        return (tracker, session, state)
    }

    /// A `crow:merge` PR that is BEHIND — i.e. one `shouldUpdateBranchBeforeMerge`
    /// claims for the auto-merge update-branch path, which is the only shape
    /// the precedence rule applies to.
    private func behindMergeCandidate(labeled: Bool = true) -> PRRecord {
        unlabeledPR(mergeStateStatus: "BEHIND", labels: labeled ? [Self.crowMergeLabel] : [])
    }

    /// The same PR shaped by whichever `mergeStateStatus` a test needs.
    /// `PRRecord`'s fields are `let`, so vary it here rather than mutating.
    private func unlabeledPR(
        mergeStateStatus: String,
        reviewDecision: String = "REVIEW_REQUIRED",
        labels: [LabelInfo] = []
    ) -> PRRecord {
        PRRecord(
            number: 944, url: Self.prURL, state: "OPEN",
            mergeable: "MERGEABLE", mergeStateStatus: mergeStateStatus,
            reviewDecision: reviewDecision, isDraft: false,
            headRefName: "feature/x", headRefOid: Self.head, baseRefName: "main",
            repoNameWithOwner: "corveil/crow", labels: labels)
    }

    // MARK: - Precedence hand-off

    /// Before #944 this `continue` was unconditional: once auto-merge burned
    /// its one-shot per-head key and gave up, auto-rebase kept yielding forever
    /// and *nobody* brought the branch up to date.
    @Test func autoRebaseTakesOverOnceAutoMergeHasSpentItsUpdateBranchAttempt() {
        let (tracker, _, _) = makeTracker()
        let pr = behindMergeCandidate()

        // Auto-merge hasn't tried yet → auto-rebase must yield.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(!tracker.autoRebaseAttempted.contains(Self.headKey))
        // ...and auto-merge is the one that claimed it.
        #expect(tracker.autoUpdateBranchAttempted.contains(Self.headKey))

        // Simulate auto-merge having finished and given up on this head: the
        // per-head key stays set, the in-flight marker is cleared.
        tracker.autoMergeInFlight.removeAll()

        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(tracker.autoRebaseAttempted.contains(Self.headKey))
    }

    /// The in-flight disjunct is load-bearing: `autoUpdateBranchAttempted`
    /// is inserted *before* the async attempt runs, and `applyAutoMerge` runs
    /// synchronously immediately before `applyAutoRebase` in the same poll — so
    /// keying on `!contains` alone, both watchers would act on one branch at once.
    @Test func autoRebaseYieldsWhileAutoMergeIsStillInFlight() {
        let (tracker, _, _) = makeTracker()
        let pr = behindMergeCandidate()

        tracker.applyPRStatuses(viewerPRs: [pr])
        // Auto-merge dispatched this poll, so its marker is set...
        #expect(tracker.autoMergeInFlight.contains(Self.prURL))
        // ...and auto-rebase did not touch the branch.
        #expect(!tracker.autoRebaseAttempted.contains(Self.headKey))
    }

    /// An unlabeled BEHIND PR was never auto-merge's to claim, so auto-rebase
    /// owns it from the first poll.
    @Test func autoRebaseOwnsBehindPRsThatAreNotMergeCandidates() {
        let (tracker, _, _) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [behindMergeCandidate(labeled: false)])
        #expect(tracker.autoRebaseAttempted.contains(Self.headKey))
        #expect(tracker.autoUpdateBranchAttempted.isEmpty)
    }

    /// The #944 headline: BLOCKED masks BEHIND, so this PR was invisible to the
    /// watcher until a reviewer approved it. It must now be dispatched.
    @Test func blockedPRIsDispatchedWithoutWaitingForApproval() {
        let (tracker, _, _) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [unlabeledPR(mergeStateStatus: "BLOCKED")])
        #expect(tracker.autoRebaseAttempted.contains(Self.headKey))
    }

    @Test func cleanPRIsStillNotDispatched() {
        let (tracker, _, _) = makeTracker()
        tracker.applyPRStatuses(viewerPRs: [
            unlabeledPR(mergeStateStatus: "CLEAN", reviewDecision: "APPROVED"),
        ])
        #expect(tracker.autoRebaseAttempted.isEmpty)
    }

    // MARK: - autoMergeInFlight leak

    /// Regression: `attemptUpdateBranch`'s `codeBackend` guard used to return
    /// *above* the `defer`, latching the PR URL in `autoMergeInFlight` for the
    /// process lifetime. `evaluateAutoMerge` then skipped it every poll and —
    /// since nothing recorded a reason — published the bare `.inFlight` verdict,
    /// i.e. the UI claimed Crow was mid-attempt on a PR it had abandoned.
    @Test func updateBranchDoesNotLeakInFlightWhenThereIsNoCodeBackend() async {
        let (tracker, session, _) = makeTracker()
        let pr = behindMergeCandidate()
        tracker.autoMergeInFlight.insert(Self.prURL)

        await tracker.attemptUpdateBranch(session: session, pr: pr, headKey: Self.headKey)

        #expect(!tracker.autoMergeInFlight.contains(Self.prURL))
    }

    /// Same leak on the no-Crow-trailer path. Suppression is
    /// `autoUpdateBranchAttempted`'s job — it returns before any dispatch — so
    /// clearing the marker costs no extra backend calls, and the reason is
    /// recorded rather than lost.
    @Test func updateBranchDoesNotLeakInFlightWithoutACrowTrailer() async {
        let (tracker, session, _) = makeTracker()
        // A GitHub session so `codeBackend(for:)` resolves and the trailer
        // check is the guard that actually fires. The commit fetch fails with
        // no network/`gh`, which `prHasCrowAuthoredCommit` reports as "not
        // Crow-authored" — the exact path under test.
        var githubSession = session
        githubSession.provider = .github
        tracker.autoMergeInFlight.insert(Self.prURL)

        await tracker.attemptUpdateBranch(
            session: githubSession, pr: behindMergeCandidate(), headKey: Self.headKey)

        #expect(!tracker.autoMergeInFlight.contains(Self.prURL))
    }

    // MARK: - Per-head pruning

    /// `autoUpdateBranchAttempted` was never pruned — it grew for the daemon's
    /// lifetime. Pruning happens in `applyAutoMerge` (after its non-empty
    /// guard), not `evaluateAutoMerge`, which is also called with a
    /// single-entry map and would wipe every other PR's key.
    @Test func updateBranchKeysArePrunedForHeadsNoLongerInThePoll() {
        let (tracker, _, _) = makeTracker()
        let stale = "https://github.com/corveil/crow/pull/1\nold"
        tracker.autoUpdateBranchAttempted.insert(stale)
        tracker.autoUpdateBranchFailureCounts[stale] = 2

        tracker.applyPRStatuses(viewerPRs: [behindMergeCandidate()])

        #expect(!tracker.autoUpdateBranchAttempted.contains(stale))
        #expect(tracker.autoUpdateBranchFailureCounts[stale] == nil)
    }

    /// A failed/empty poll must not wipe live bookkeeping — the non-empty guard
    /// sits above the pruning for exactly this reason.
    @Test func anEmptyPollDoesNotWipeLiveKeys() {
        let (tracker, _, _) = makeTracker()
        tracker.autoUpdateBranchAttempted.insert(Self.headKey)
        tracker.autoRebaseAttempted.insert(Self.headKey)

        tracker.applyPRStatuses(viewerPRs: [])

        #expect(tracker.autoUpdateBranchAttempted.contains(Self.headKey))
        #expect(tracker.autoRebaseAttempted.contains(Self.headKey))
    }

    // MARK: - Up-to-date re-check

    /// The trap widening created: a PR probed while merely BLOCKED-and-not-yet-
    /// behind latches, and the base moving afterwards is invisible in
    /// `headRefOid`. A *change* in GitHub's view of the same head re-arms it —
    /// and only a change, so a persistent disagreement can't hot-loop.
    @Test func aLatchedUpToDateHeadIsRecheckedWhenGitHubsViewChanges() {
        let (tracker, _, _) = makeTracker()

        // Pretend the probe already concluded "already on base" while BLOCKED.
        tracker.autoRebaseAttempted.insert(Self.headKey)
        tracker.autoRebaseUpToDateHeads[Self.headKey] = "BLOCKED"

        // Same status → no re-check.
        tracker.applyPRStatuses(viewerPRs: [unlabeledPR(mergeStateStatus: "BLOCKED")])
        #expect(tracker.autoRebaseUpToDateHeads[Self.headKey] == "BLOCKED")

        // GitHub flips to BEHIND → re-armed, and the new status is recorded so
        // the next identical poll is a no-op.
        tracker.autoRebaseInFlight.removeAll()
        tracker.applyPRStatuses(viewerPRs: [unlabeledPR(mergeStateStatus: "BEHIND")])
        #expect(tracker.autoRebaseUpToDateHeads[Self.headKey] == "BEHIND")
    }

    // MARK: - Published verdicts

    /// Turning the watcher off must not leave chips behind — but the clear has
    /// to sit above the non-empty guard so a failed poll can't masquerade as a
    /// toggle-off.
    @Test func disablingTheWatcherClearsPublishedVerdicts() {
        let (tracker, session, state) = makeTracker()
        state.autoRebaseState[session.id] = AutoRebaseState(
            phase: .blocked, reason: "out-of-sync-diverged", message: "…", permanent: true)

        tracker.autoRebaseAndResolveConflictsProvider = { false }
        tracker.applyPRStatuses(viewerPRs: [behindMergeCandidate()])

        #expect(state.autoRebaseState[session.id] == nil)
    }

    /// A PR that stops being a candidate — hand-rebased, merged, closed — is
    /// the only recovery path, since `attemptRebase` never runs for it again.
    /// Without this a `blocked` chip would outlive its cause forever.
    @Test func aPRThatStopsBeingACandidateClearsItsVerdict() {
        let (tracker, session, state) = makeTracker()
        state.autoRebaseState[session.id] = AutoRebaseState(
            phase: .blocked, reason: "out-of-sync-diverged", message: "…", permanent: true)

        tracker.applyPRStatuses(viewerPRs: [unlabeledPR(mergeStateStatus: "CLEAN")])

        #expect(state.autoRebaseState[session.id] == nil)
    }
}
