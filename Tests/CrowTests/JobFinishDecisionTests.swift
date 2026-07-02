import Foundation
import Testing
import CrowCore
@testable import Crow

/// Auto-complete decision for finished job runs (CROW-561). A job's session
/// should transition to `.completed` only when its agent has finished
/// successfully — every prompt delivered, a settle window elapsed, the agent
/// launched and now at rest (`.done`/`.idle`) — and never while it is still
/// working, awaiting input, or errored (`.waiting`).
@Suite("Job finish decision")
@MainActor
struct JobFinishDecisionTests {
    let now = Date(timeIntervalSince1970: 10_000)
    let settle: TimeInterval = 20
    let maxWatch: TimeInterval = 12 * 3600

    /// Wrapper with the common "finished successfully" defaults filled in:
    /// active session, launched, all prompts delivered past the settle window.
    /// `deliveredSecondsAgo == nil` models "prompts not all delivered yet".
    private func decide(
        status: SessionStatus? = .active,
        startedSecondsAgo: TimeInterval = 60,
        deliveredSecondsAgo: TimeInterval? = 25,
        readiness: TerminalReadiness? = .agentLaunched,
        activity: AgentActivityState
    ) -> JobScheduler.RunDecision {
        JobScheduler.finishDecision(
            now: now,
            status: status,
            startedAt: now.addingTimeInterval(-startedSecondsAgo),
            promptsDeliveredAt: deliveredSecondsAgo.map { now.addingTimeInterval(-$0) },
            readiness: readiness,
            activityState: activity,
            finishSettleDelay: settle,
            maxWatchDuration: maxWatch
        )
    }

    @Test func completesWhenAgentDoneAfterSettle() {
        #expect(decide(activity: .done) == .complete)
    }

    @Test func completesWhenAgentIdleAfterSettle() {
        // TUI agents (Cursor/OpenCode) rest at `.idle` when finished.
        #expect(decide(activity: .idle) == .complete)
    }

    @Test func doesNotCompleteWhileWorking() {
        #expect(decide(activity: .working) == .keepWaiting)
    }

    @Test func doesNotCompleteWhileWaiting() {
        // `.waiting` covers both awaiting-input and errored (StopFailure) — the
        // run must stay active so it surfaces, not silently complete.
        #expect(decide(activity: .waiting) == .keepWaiting)
    }

    @Test func doesNotCompleteBeforeAllPromptsDelivered() {
        #expect(decide(deliveredSecondsAgo: nil, activity: .done) == .keepWaiting)
    }

    @Test func doesNotCompleteInsideSettleWindow() {
        // Delivered only 5s ago (< 20s settle) — guards against catching a stale
        // top-level `.done` from an earlier prompt.
        #expect(decide(deliveredSecondsAgo: 5, activity: .done) == .keepWaiting)
    }

    @Test func doesNotCompleteBeforeAgentLaunched() {
        #expect(decide(readiness: .shellReady, activity: .done) == .keepWaiting)
        #expect(decide(readiness: nil, activity: .done) == .keepWaiting)
    }

    @Test func stopsWatchingWhenSessionGone() {
        #expect(decide(status: nil, activity: .done) == .stopWatching)
    }

    @Test func stopsWatchingWhenNoLongerActive() {
        // Manually completed/archived out from under us → give up watching.
        #expect(decide(status: .archived, activity: .done) == .stopWatching)
        #expect(decide(status: .completed, activity: .done) == .stopWatching)
    }

    @Test func stopsWatchingAfterMaxDuration() {
        #expect(decide(startedSecondsAgo: maxWatch + 60, activity: .working) == .stopWatching)
    }
}
