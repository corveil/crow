import Foundation
import Testing
import CrowCore
@testable import Crow

/// Reconciliation of unwatched job runs (CROW-579). On startup and each tick,
/// `JobScheduler` adopts active `.job` sessions it isn't already watching so a
/// finished run still auto-completes after an app relaunch (in-memory watch
/// lost) or if it predates the feature. `shouldReconcile` is the pure
/// eligibility gate; the adopted run is then judged by the same
/// `finishDecision` the fired path uses, so the two can't diverge.
@Suite("Job reconcile decision")
@MainActor
struct JobReconcileDecisionTests {

    // MARK: - Eligibility (shouldReconcile)

    @Test func adoptsActiveUnwatchedJob() {
        #expect(JobScheduler.shouldReconcile(kind: .job, status: .active, alreadyWatched: false))
    }

    @Test func skipsAlreadyWatchedJob() {
        // Runs we fired are already watched with their real delivery timestamp;
        // re-adopting would clobber their settle timing.
        #expect(!JobScheduler.shouldReconcile(kind: .job, status: .active, alreadyWatched: true))
    }

    @Test func skipsNonJobKinds() {
        for kind: SessionKind in [.work, .review, .manager] {
            #expect(!JobScheduler.shouldReconcile(kind: kind, status: .active, alreadyWatched: false))
        }
    }

    @Test func skipsNonActiveStatuses() {
        // Only `.active` job sessions are candidates — a completed/paused/
        // in-review/archived job must not be adopted (and re-completed).
        for status: SessionStatus in [.completed, .paused, .inReview, .archived] {
            #expect(!JobScheduler.shouldReconcile(kind: .job, status: status, alreadyWatched: false))
        }
    }

    // MARK: - Adoption contract (via the shared finishDecision)

    /// A reconciled run is adopted with `promptsDeliveredAt == now`, so it sits
    /// inside the settle window and can't complete on the adopting tick even
    /// when the agent already reads `.done`. This is the mid-gap guard: a
    /// multi-prompt job momentarily at rest between prompts isn't completed
    /// until it stays at rest across a full tick.
    @Test func adoptedRunWaitsOutSettleWindowBeforeCompleting() {
        let adoptedAt = Date(timeIntervalSince1970: 10_000)
        let settle: TimeInterval = 20
        let maxWatch: TimeInterval = 12 * 3600

        // Same instant it was adopted: 0s < settle → keep waiting.
        #expect(JobScheduler.finishDecision(
            now: adoptedAt,
            status: .active,
            startedAt: adoptedAt,
            promptsDeliveredAt: adoptedAt,
            readiness: .agentLaunched,
            activityState: .done,
            finishSettleDelay: settle,
            maxWatchDuration: maxWatch
        ) == .keepWaiting)

        // A full tick later, still at rest → complete.
        #expect(JobScheduler.finishDecision(
            now: adoptedAt.addingTimeInterval(30),
            status: .active,
            startedAt: adoptedAt,
            promptsDeliveredAt: adoptedAt,
            readiness: .agentLaunched,
            activityState: .done,
            finishSettleDelay: settle,
            maxWatchDuration: maxWatch
        ) == .complete)
    }

    /// Adopting with `startedAt == now` (not the session's real, possibly
    /// days-old, start) keeps a predates-the-feature run eligible: the
    /// `maxWatchDuration` cap counts from adoption, so it doesn't trip on an old
    /// session and can still complete once the settle window elapses.
    @Test func adoptedRunIsNotImmediatelyCappedForAnOldSession() {
        let adoptedAt = Date(timeIntervalSince1970: 10_000)
        #expect(JobScheduler.finishDecision(
            now: adoptedAt.addingTimeInterval(30),
            status: .active,
            startedAt: adoptedAt,               // adoption time, not createdAt
            promptsDeliveredAt: adoptedAt,
            readiness: .agentLaunched,
            activityState: .done,
            finishSettleDelay: 20,
            maxWatchDuration: 12 * 3600
        ) == .complete)
    }
}
