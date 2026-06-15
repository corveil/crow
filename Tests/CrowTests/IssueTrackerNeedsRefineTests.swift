import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import Crow

/// CROW-508 acceptance tests for the stateless "needs refine" dispatch path
/// in `IssueTracker`. Drives `applyPRStatuses` end-to-end with fixture
/// `PRRecord`s and asserts the emitted `.changesRequested` transitions,
/// covering each of the four acceptance criteria in the ticket:
///
/// 1. Round-N stall — review newer than last commit → fires on idle poll.
/// 2. Merge-from-main doesn't reset — `lastSubstantiveCommitAt` upstream-
///    filtered to exclude merge commits, so a "Update branch" push leaves
///    the rule firing.
/// 3. Real fix flips it — non-merge commit advances the timestamp, rule
///    stops firing.
/// 4. Restart-safe — fresh tracker (no `seenPRs`, no `lastRefineDispatchAt`)
///    skips first poll, fires on second, blocks on cooldown.
@Suite("IssueTracker stateless needsRefine (CROW-508)")
@MainActor
struct IssueTrackerNeedsRefineTests {
    private let prURL = "https://github.com/foo/bar/pull/123"
    private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let reviewAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let beforeReview = Date(timeIntervalSince1970: 1_699_999_000)
    private let afterReview = Date(timeIntervalSince1970: 1_700_001_000)

    /// Build a tracker + session + managed terminal + PR link + idle hook
    /// state so the dispatch path's gates (terminal idle, agent activity
    /// idle, `respondToChangesRequested` on) are satisfied. Callers can
    /// override readiness/activity per test by mutating after construction.
    private func makeTracker(
        respondToChangesRequested: Bool = true,
        readiness: TerminalReadiness = .agentLaunched,
        agentIdle: Bool = true
    ) -> (tracker: IssueTracker, sessionID: UUID, captured: TransitionCapture) {
        let state = AppState()
        let session = Session(name: "feature/stateless-test", kind: .work)
        state.sessions = [session]
        state.links[session.id] = [
            SessionLink(sessionID: session.id, label: "PR #123", url: prURL, linkType: .pr)
        ]
        let terminal = SessionTerminal(
            sessionID: session.id,
            name: "Claude",
            cwd: "/tmp",
            command: "claude",
            isManaged: true
        )
        state.terminals[session.id] = [terminal]
        state.terminalReadiness[terminal.id] = readiness
        // Hook state activity defaults to .idle from AppState — set
        // explicitly when the test wants it busy.
        if !agentIdle {
            state.hookState(for: session.id).activityState = .working
        }

        let tracker = IssueTracker(appState: state, providerManager: ProviderManager())
        tracker.respondToChangesRequestedProvider = { respondToChangesRequested }

        let captured = TransitionCapture()
        tracker.onPRStatusTransitions = { transitions in
            captured.append(transitions)
        }
        return (tracker, session.id, captured)
    }

    /// Fixture PR with the stateless rule's inputs populated. Defaults
    /// produce a "needs refine" snapshot — override per test as needed.
    private func makeViewerPR(
        reviewDecision: String = "CHANGES_REQUESTED",
        state: String = "OPEN",
        sha: String? = nil,
        lastChangesRequestedAt: Date?,
        lastSubstantiveCommitAt: Date?
    ) -> PRRecord {
        PRRecord(
            number: 123,
            url: prURL,
            state: state,
            mergeable: "MERGEABLE",
            mergeStateStatus: "CLEAN",
            reviewDecision: reviewDecision,
            isDraft: false,
            headRefName: "feature/stateless-test",
            headRefOid: sha ?? shaA,
            baseRefName: "main",
            repoNameWithOwner: "foo/bar",
            labels: [],
            linkedIssueReferences: [],
            checksState: "SUCCESS",
            failedCheckNames: [],
            latestReviewStates: ["CHANGES_REQUESTED"],
            lastChangesRequestedAt: lastChangesRequestedAt,
            lastSubstantiveCommitAt: lastSubstantiveCommitAt
        )
    }

    // MARK: - Acceptance Test 1 — round-N stall fires on idle poll (after first-observation skip)

    @Test
    func roundNStallFiresOnSecondPoll() {
        let (tracker, _, captured) = makeTracker()
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)

        // Poll 1: first observation — must NOT dispatch.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 0)
        #expect(tracker.seenPRs.contains(prURL))

        // Poll 2: PR snapshot unchanged, rule still holds → fires.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 1)
        #expect(tracker.lastRefineDispatchAt[prURL] != nil)
    }

    // MARK: - Acceptance Test 2 — merge-from-main does NOT advance the timestamp

    @Test
    func mergeFromMainDoesNotFlipTheRule() {
        // The upstream parser excludes merge commits from `lastSubstantiveCommitAt`,
        // so a "Update branch" push leaves the timestamp at its pre-review
        // value. From the tracker's perspective: the rule keeps firing.
        let (tracker, _, captured) = makeTracker()
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.seenPRs.insert(prURL)  // skip first-observation gate

        // Snapshot is post-"Update branch": commit timestamp is still pre-review.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 1)
    }

    // MARK: - Acceptance Test 3 — real fix advances the timestamp, rule stops firing

    @Test
    func realFixStopsTheRule() {
        let (tracker, _, captured) = makeTracker()
        tracker.seenPRs.insert(prURL)  // skip first-observation gate

        // Real fix push: lastSubstantiveCommitAt advances past lastChangesRequestedAt.
        let afterFix = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: afterReview)
        tracker.applyPRStatuses(viewerPRs: [afterFix])
        #expect(captured.changesRequestedCount == 0)
    }

    // MARK: - Acceptance Test 4 — restart safety: first-observation skip + cooldown

    @Test
    func restartFreshTrackerSkipsThenFiresThenCoolsDown() {
        let (tracker, _, captured) = makeTracker()
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)

        // Poll 1 after restart: first-observation skip blocks dispatch.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 0)

        // Poll 2: eligible. Fires once.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 1)
        let firstDispatchAt = tracker.lastRefineDispatchAt[prURL]
        #expect(firstDispatchAt != nil)

        // Poll 3 (< cooldown elapsed): cooldown blocks further dispatch.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 1)
        #expect(tracker.lastRefineDispatchAt[prURL] == firstDispatchAt)

        // Simulate cooldown elapsed by backdating the dispatch clock.
        tracker.lastRefineDispatchAt[prURL] = Date().addingTimeInterval(-IssueTracker.needsRefineCooldown - 1)
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 2)
    }

    // MARK: - Defense-in-depth gates

    @Test
    func respondToChangesRequestedOffSuppressesDispatch() {
        let (tracker, _, captured) = makeTracker(respondToChangesRequested: false)
        tracker.seenPRs.insert(prURL)
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 0)
    }

    @Test
    func busyAgentSuppressesDispatch() {
        let (tracker, _, captured) = makeTracker(agentIdle: false)
        tracker.seenPRs.insert(prURL)
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 0)
    }

    @Test
    func preLaunchTerminalSuppressesDispatch() {
        let (tracker, _, captured) = makeTracker(readiness: .uninitialized)
        tracker.seenPRs.insert(prURL)
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 0)
    }

    // MARK: - Cooldown-re-fire notification dedup (review feedback)

    @Test
    func firstDispatchHasIsCooldownReFireFalse() {
        // The first dispatch for a reviewer submission must NOT carry the
        // notification-skip flag — the user is seeing the event for the
        // first time and needs the macOS banner.
        let (tracker, _, captured) = makeTracker()
        tracker.seenPRs.insert(prURL)
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 1)
        #expect(captured.all.first?.isCooldownReFire == false)
    }

    @Test
    func cooldownReFireSetsTheFlagForSameReviewerSubmission() {
        // Same review, agent went back to idle without committing, cooldown
        // elapsed → re-prompt is useful (agent is stuck) but the macOS
        // banner is redundant. Carry the flag so AppDelegate skips it.
        let (tracker, _, captured) = makeTracker()
        tracker.seenPRs.insert(prURL)
        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [pr])
        // Backdate the cooldown clock so the next call dispatches again.
        tracker.lastRefineDispatchAt[prURL] = Date().addingTimeInterval(-IssueTracker.needsRefineCooldown - 1)
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 2)
        #expect(captured.all[0].isCooldownReFire == false)
        #expect(captured.all[1].isCooldownReFire == true)
    }

    @Test
    func newReviewerSubmissionClearsTheFlag() {
        // A fresh CHANGES_REQUESTED review from the reviewer advances
        // `lastChangesRequestedAt`. The next dispatch IS a new event and
        // must notify — flag must flip back to false.
        let (tracker, _, captured) = makeTracker()
        tracker.seenPRs.insert(prURL)
        let pr1 = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [pr1])
        tracker.lastRefineDispatchAt[prURL] = Date().addingTimeInterval(-IssueTracker.needsRefineCooldown - 1)

        let laterReviewAt = reviewAt.addingTimeInterval(3600)
        let pr2 = makeViewerPR(lastChangesRequestedAt: laterReviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [pr2])
        #expect(captured.changesRequestedCount == 2)
        #expect(captured.all[1].isCooldownReFire == false)
    }

    // MARK: - Stale-entry prune (review feedback)

    @Test
    func prunesEphemeralStateForPRsWithoutLiveSession() {
        // A PR linked to a deleted (or never-existed) session must NOT
        // linger in `seenPRs` / `lastRefineDispatchAt` /
        // `lastNotifiedChangesRequestedAt`. Otherwise the maps grow
        // unboundedly across the process's lifetime.
        let (tracker, _, _) = makeTracker()
        let stalePRURL = "https://github.com/foo/bar/pull/999"
        tracker.seenPRs.insert(stalePRURL)
        tracker.lastRefineDispatchAt[stalePRURL] = Date()
        tracker.lastNotifiedChangesRequestedAt[stalePRURL] = reviewAt

        let livePR = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)
        tracker.applyPRStatuses(viewerPRs: [livePR])

        #expect(!tracker.seenPRs.contains(stalePRURL))
        #expect(tracker.lastRefineDispatchAt[stalePRURL] == nil)
        #expect(tracker.lastNotifiedChangesRequestedAt[stalePRURL] == nil)
        // The live PR still gets recorded normally.
        #expect(tracker.seenPRs.contains(prURL))
    }

    // MARK: - Two sessions sharing a PR URL (Green 2 — review feedback)

    @Test
    func twoSessionsSharingPRBothSkipFirstObservation() {
        // Two sessions linked to the same PR within one poll: with naive
        // ordering, session A inserts into `seenPRs` and session B then sees
        // the URL already-seen → B dispatches on the very first poll. The
        // snapshot-at-start guards against that.
        let state = AppState()
        let sessionA = Session(name: "session-a", kind: .work)
        let sessionB = Session(name: "session-b", kind: .work)
        state.sessions = [sessionA, sessionB]
        state.links[sessionA.id] = [SessionLink(sessionID: sessionA.id, label: "PR #123", url: prURL, linkType: .pr)]
        state.links[sessionB.id] = [SessionLink(sessionID: sessionB.id, label: "PR #123", url: prURL, linkType: .pr)]
        let termA = SessionTerminal(sessionID: sessionA.id, name: "A", cwd: "/tmp", command: "claude", isManaged: true)
        let termB = SessionTerminal(sessionID: sessionB.id, name: "B", cwd: "/tmp", command: "claude", isManaged: true)
        state.terminals[sessionA.id] = [termA]
        state.terminals[sessionB.id] = [termB]
        state.terminalReadiness[termA.id] = .agentLaunched
        state.terminalReadiness[termB.id] = .agentLaunched

        let tracker = IssueTracker(appState: state, providerManager: ProviderManager())
        tracker.respondToChangesRequestedProvider = { true }
        let captured = TransitionCapture()
        tracker.onPRStatusTransitions = { captured.append($0) }

        let pr = makeViewerPR(lastChangesRequestedAt: reviewAt, lastSubstantiveCommitAt: beforeReview)

        // Poll 1: both sessions must observe "not seen yet" and skip.
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 0)
        #expect(tracker.seenPRs.contains(prURL))

        // Poll 2: both sessions can dispatch (cooldown is per-PR so only
        // the first one wins, but the snapshot fix is about poll 1).
        tracker.applyPRStatuses(viewerPRs: [pr])
        #expect(captured.changesRequestedCount == 1)
    }
}

/// Captures emitted transitions across multiple polls. Class so the test's
/// closure can mutate it without value-type aliasing surprises.
@MainActor
private final class TransitionCapture {
    var all: [PRStatusTransition] = []
    func append(_ ts: [PRStatusTransition]) { all.append(contentsOf: ts) }
    var changesRequestedCount: Int { all.filter { $0.kind == .changesRequested }.count }
}
