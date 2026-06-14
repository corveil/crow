import Foundation
import Testing
import CrowCore
import CrowProvider
@testable import Crow

/// CROW-505: `IssueTracker` re-fires `.changesRequested` transitions whose
/// auto-respond prompt has stalled (agent idle, head SHA unchanged, quiet
/// window elapsed). These tests cover the pure
/// `shouldReFireStalledChangesRequested` predicate plus the dedup-key
/// parse helpers that drive the wiring layer.
@Suite("IssueTracker stalled re-fire predicate (CROW-505)")
struct IssueTrackerStalledRefireTests {

    private let quietWindow: TimeInterval = 10 * 60
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    private func meta(emittedSecondsAgo: TimeInterval = 11 * 60, headShaAtEmit: String? = nil) -> EmittedTransitionMeta {
        EmittedTransitionMeta(
            emittedAt: now.addingTimeInterval(-emittedSecondsAgo),
            headShaAtEmit: headShaAtEmit ?? shaA
        )
    }

    private func status(
        review: PRStatus.ReviewStatus = .changesRequested,
        sha: String? = nil,
        reviewID: String? = "R_1",
        isOpen: Bool = true,
        mergeable: PRStatus.MergeStatus = .unknown
    ) -> PRStatus {
        PRStatus(
            checksPass: .pending,
            reviewStatus: review,
            mergeable: mergeable,
            failedCheckNames: [],
            headSha: sha ?? shaA,
            latestReviewID: reviewID,
            isOpen: isOpen
        )
    }

    // MARK: - Bug repro (Test 1)

    @Test
    func reFiresWhenAllConditionsMet() {
        // The CROW-505 bug repro: PR still in CHANGES_REQUESTED, agent went
        // idle without addressing all findings, head SHA hasn't advanced
        // (agent didn't push), and quiet window has elapsed.
        #expect(IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA),
            agentActivity: .idle,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    // MARK: - Anti-loop guarantee (Test 2)

    @Test
    func doesNotReFireWhenAgentPushedNewCommit() {
        // The single most important invariant: a real agent push advances the
        // head SHA, which kills the re-fire. This preserves the CROW-456
        // anti-loop guarantee — the agent's own response push doesn't
        // re-trigger the prompt that told it to push.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaB),  // SHA advanced
            agentActivity: .idle,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    // MARK: - Round-2 reviewer review still fires (Test 3)

    @Test
    func roundTwoFromReviewerProducesDistinctDedupKey() {
        // Reviewer submitting a fresh formal review rotates `latestReviewID`,
        // which produces a different `dedupeKey`. The existing
        // `applyPRStatuses` path emits unconditionally on a new key — the
        // re-fire predicate is never consulted for this case. Sanity check
        // by computing the two keys and asserting they differ.
        let sid = UUID()
        let r1 = PRStatusTransition(
            kind: .changesRequested, sessionID: sid, prURL: "https://example/1",
            prNumber: 1, headSha: shaA, latestReviewID: "R_1"
        )
        let r2 = PRStatusTransition(
            kind: .changesRequested, sessionID: sid, prURL: "https://example/1",
            prNumber: 1, headSha: shaA, latestReviewID: "R_2"
        )
        #expect(r1.dedupeKey != r2.dedupeKey)
    }

    // MARK: - Agent busy — no re-fire (Test 4)

    @Test
    func doesNotReFireWhileAgentWorking() {
        // Don't interrupt an agent that's actively working — they may already
        // be addressing the feedback.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA),
            agentActivity: .working,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    @Test
    func doesNotReFireWhileAgentWaiting() {
        // `.waiting` means the agent is blocked on user input — re-firing now
        // would push another prompt into a queue the user is about to answer.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA),
            agentActivity: .waiting,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    @Test
    func doesNotReFireWhileAgentDone() {
        // `.done` is the terminal "completed a turn" state — it's followed by
        // a hook reset to `.idle`. Re-firing on `.done` would race.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA),
            agentActivity: .done,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    // MARK: - Quiet window respected (Test 5)

    @Test
    func doesNotReFireBeforeQuietWindowElapsed() {
        // Quiet window: agents can spend 5+ minutes thinking on a hard
        // finding. Don't re-prompt before they've had a chance to act.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow - 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA),
            agentActivity: .idle,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    // MARK: - Terminal not launched (Test 6)

    @Test
    func doesNotReFireWhenTerminalNotLaunched() {
        // A pre-launch terminal (shellReady or earlier) can't be "stalled" —
        // the agent never ran. Wait for the launch to finish first.
        for readiness: TerminalReadiness in [.uninitialized, .surfaceCreated, .shellReady, .timedOut, .failed] {
            #expect(!IssueTracker.shouldReFireStalledChangesRequested(
                meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
                currentStatus: status(sha: shaA),
                agentActivity: .idle,
                terminalReadiness: readiness,
                now: now,
                quietWindow: quietWindow
            ), "expected no re-fire at readiness \(readiness)")
        }
    }

    @Test
    func doesNotReFireWhenTerminalReadinessUnknown() {
        // No managed terminal at all → no readiness entry. Can't re-fire.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA),
            agentActivity: .idle,
            terminalReadiness: nil,
            now: now,
            quietWindow: quietWindow
        ))
    }

    // MARK: - PR no longer in CHANGES_REQUESTED

    @Test
    func doesNotReFireWhenPRLeftChangesRequestedBucket() {
        // If the PR moved to APPROVED or the bucket cleared otherwise,
        // re-firing is meaningless. The re-arm path in `applyPRStatuses`
        // also drops the entry on this transition, but the predicate
        // double-checks.
        for review: PRStatus.ReviewStatus in [.approved, .reviewRequired, .unknown] {
            #expect(!IssueTracker.shouldReFireStalledChangesRequested(
                meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
                currentStatus: status(review: review, sha: shaA),
                agentActivity: .idle,
                terminalReadiness: .agentLaunched,
                now: now,
                quietWindow: quietWindow
            ), "expected no re-fire at review status \(review)")
        }
    }

    // MARK: - PR no longer open (CROW-505 review #2)

    @Test
    func doesNotReFireOnMergedPR() {
        // A PR that merged while in CHANGES_REQUESTED keeps reviewDecision
        // unchanged, but the re-fire must not prompt the agent to "address
        // review feedback" on a merged PR — there's nothing to push to.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA, isOpen: false, mergeable: .merged),
            agentActivity: .idle,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    @Test
    func doesNotReFireOnClosedUnmergedPR() {
        // Same concern, the more common case: PR closed without merging.
        // `mergeable` stays `.unknown` on closed PRs — only `isOpen` flags
        // this as dead. The reviewer's specific blocker.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: status(sha: shaA, isOpen: false, mergeable: .unknown),
            agentActivity: .idle,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    @Test
    func doesNotReFireWhenCurrentStatusMissing() {
        // No persisted PR status for the session → we can't reason about
        // SHA equality or bucket membership. Refuse.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: meta(emittedSecondsAgo: quietWindow + 1, headShaAtEmit: shaA),
            currentStatus: nil,
            agentActivity: .idle,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    @Test
    func doesNotReFireWhenBaselineShaNil() {
        // Migrated entries from before CROW-505 may have nil headShaAtEmit.
        // Without a baseline we can't prove the author hasn't pushed —
        // refuse rather than risk an unwanted re-fire.
        #expect(!IssueTracker.shouldReFireStalledChangesRequested(
            meta: EmittedTransitionMeta(emittedAt: now.addingTimeInterval(-(quietWindow + 1)), headShaAtEmit: nil),
            currentStatus: status(sha: shaA),
            agentActivity: .idle,
            terminalReadiness: .agentLaunched,
            now: now,
            quietWindow: quietWindow
        ))
    }

    // MARK: - Dedup-key parsers

    @Test
    func parsesSessionIDAndKindFromDedupKey() {
        let sid = UUID()
        let crKey = "\(sid.uuidString)|changesRequested|R_1"
        let cfKey = "\(sid.uuidString)|checksFailing|\(shaA)"

        #expect(IssueTracker.parseSessionID(fromDedupKey: crKey) == sid)
        #expect(IssueTracker.parseSessionID(fromDedupKey: cfKey) == sid)
        #expect(IssueTracker.parseKind(fromDedupKey: crKey) == .changesRequested)
        #expect(IssueTracker.parseKind(fromDedupKey: cfKey) == .checksFailing)
    }

    @Test
    func parsersReturnNilForMalformedKeys() {
        #expect(IssueTracker.parseSessionID(fromDedupKey: "not-a-uuid|changesRequested|R_1") == nil)
        #expect(IssueTracker.parseSessionID(fromDedupKey: "no-pipe-anywhere") == nil)
        #expect(IssueTracker.parseKind(fromDedupKey: "\(UUID().uuidString)|unknownKind|x") == nil)
        #expect(IssueTracker.parseKind(fromDedupKey: "missing-discriminator") == nil)
    }
}

/// Integration coverage for `IssueTracker.reFireStalledChangesRequested`: the
/// map-walking pass that consults the predicate, builds synthetic transitions,
/// and bumps the dedup-meta timestamp. The predicate is covered above in
/// isolation; these tests catch wiring drift — gate-off behavior, terminal
/// resolution, and the `emittedAt` refresh that prevents same-poll re-fires.
@Suite("IssueTracker stalled re-fire wiring (CROW-505)")
@MainActor
struct IssueTrackerStalledRefireWiringTests {

    private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    /// Build an `IssueTracker` whose appState contains a single work session
    /// with a PR link, a managed terminal at `.agentLaunched`, an idle hook
    /// state, and a prior PRStatus in CHANGES_REQUESTED on `shaA`. Seeds an
    /// `emittedTransitionMeta` entry that has been sitting for ~2× the quiet
    /// window — so the pure predicate would say "re-fire".
    private func makeStalledTracker(
        toggleOn: Bool,
        sessionKind: SessionKind = .work,
        agentActivity: AgentActivityState = .idle,
        readiness: TerminalReadiness? = .agentLaunched
    ) -> (IssueTracker, UUID, String) {
        let state = AppState()
        let sid = UUID()
        let session = Session(id: sid, name: "feature-test", kind: sessionKind)
        state.sessions = [session]

        let prLink = SessionLink(
            sessionID: sid,
            label: "PR #1",
            url: "https://github.com/radiusmethod/crow/pull/1",
            linkType: .pr
        )
        state.links[sid] = [prLink]

        let terminal = SessionTerminal(
            sessionID: sid,
            name: "Claude Code",
            cwd: "/tmp",
            isManaged: true
        )
        state.terminals[sid] = [terminal]
        if let readiness {
            state.terminalReadiness[terminal.id] = readiness
        }
        state.hookState(for: sid).activityState = agentActivity

        let tracker = IssueTracker(appState: state, providerManager: ProviderManager())
        tracker.respondToChangesRequestedProvider = { toggleOn }

        let status = PRStatus(
            checksPass: .pending,
            reviewStatus: .changesRequested,
            mergeable: .unknown,
            failedCheckNames: [],
            headSha: shaA,
            latestReviewID: "R_1"
        )
        tracker.previousPRStatus[sid] = status

        let key = "\(sid.uuidString)|changesRequested|R_1"
        let now = Date()
        tracker.emittedTransitionMeta[key] = EmittedTransitionMeta(
            emittedAt: now.addingTimeInterval(-IssueTracker.stalledRefireQuietWindow * 2),
            headShaAtEmit: shaA
        )

        return (tracker, sid, key)
    }

    // MARK: - The gate

    @Test
    func toggleOffSuppressesAllSyntheticTransitions() {
        // Reviewer's regression catch (review on PR #507): an opted-out user
        // must not see synthetic transitions, even when every predicate
        // condition is satisfied. Without the gate, `onPRStatusTransitions`
        // would fire `notifyPRTransition` every quiet window — pure macOS
        // notification noise for zero useful action.
        let (tracker, _, key) = makeStalledTracker(toggleOn: false)
        let metaBefore = tracker.emittedTransitionMeta[key]

        let transitions = tracker.reFireStalledChangesRequested(now: Date())

        #expect(transitions.isEmpty)
        // Meta must not be touched by the no-op path — bumping `emittedAt`
        // when nothing fired would lose the original dispatch timestamp.
        #expect(tracker.emittedTransitionMeta[key] == metaBefore)
    }

    @Test
    func toggleOnPermitsSyntheticTransitionAndBumpsEmittedAt() {
        let now = Date()
        let (tracker, sid, key) = makeStalledTracker(toggleOn: true)
        let originalEmittedAt = tracker.emittedTransitionMeta[key]?.emittedAt

        let transitions = tracker.reFireStalledChangesRequested(now: now)

        #expect(transitions.count == 1)
        #expect(transitions[0].kind == .changesRequested)
        #expect(transitions[0].sessionID == sid)
        #expect(transitions[0].headSha == shaA)
        #expect(transitions[0].latestReviewID == "R_1")
        // emittedAt bumped to `now` so the next poll inside the quiet window
        // doesn't immediately re-fire again.
        #expect(tracker.emittedTransitionMeta[key]?.emittedAt == now)
        #expect(tracker.emittedTransitionMeta[key]?.emittedAt != originalEmittedAt)
    }

    // MARK: - Review-session gate

    @Test
    func reviewSessionsAreSkippedEvenWhenToggleOn() {
        // Mirrors the `AutoRespondCoordinator.shouldSkipReviewSession` policy:
        // never commit on behalf of a reviewer. The map-walking pass checks
        // `session.kind != .review` so the synthetic transition never reaches
        // the notification fan-out either.
        let (tracker, _, _) = makeStalledTracker(toggleOn: true, sessionKind: .review)
        let transitions = tracker.reFireStalledChangesRequested(now: Date())
        #expect(transitions.isEmpty)
    }

    // MARK: - Activity / readiness gates (integration view of the predicate)

    @Test
    func agentWorkingSuppressesSyntheticTransition() {
        let (tracker, _, _) = makeStalledTracker(toggleOn: true, agentActivity: .working)
        #expect(tracker.reFireStalledChangesRequested(now: Date()).isEmpty)
    }

    @Test
    func unlaunchedTerminalSuppressesSyntheticTransition() {
        let (tracker, _, _) = makeStalledTracker(toggleOn: true, readiness: .shellReady)
        #expect(tracker.reFireStalledChangesRequested(now: Date()).isEmpty)
    }

    @Test
    func missingManagedTerminalSuppressesSyntheticTransition() {
        // Edge: no terminal entry at all (e.g. session created but terminal
        // never materialized). Predicate sees `terminalReadiness: nil` and
        // refuses.
        let (tracker, _, _) = makeStalledTracker(toggleOn: true, readiness: nil)
        #expect(tracker.reFireStalledChangesRequested(now: Date()).isEmpty)
    }
}
