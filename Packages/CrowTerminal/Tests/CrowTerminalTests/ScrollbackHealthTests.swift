import Testing
@testable import CrowTerminal

/// Pure-policy tests for the CROW-804 scrollback-degradation check. No tmux
/// required — `isScrollbackDegraded` is a `nonisolated static` predicate, so
/// this suite always runs (unlike the tmux-gated integration suites).
@Suite("Scrollback degradation policy")
struct ScrollbackHealthTests {

    @Test func oldHistoryLimitIsDegraded() {
        // Windows born under the old 5000/2000 default keep that cap forever.
        #expect(TmuxBackend.isScrollbackDegraded(historyLimit: 5000, alternateOn: false))
        #expect(TmuxBackend.isScrollbackDegraded(historyLimit: 2000, alternateOn: false))
    }

    @Test func alternateBufferIsDegraded() {
        // A pane stuck in the alternate-screen buffer has NO scrollback, even at
        // the full history-limit.
        #expect(TmuxBackend.isScrollbackDegraded(historyLimit: 50000, alternateOn: true))
    }

    @Test func fullLimitMainBufferIsHealthy() {
        #expect(!TmuxBackend.isScrollbackDegraded(historyLimit: 50000, alternateOn: false))
    }

    @Test func floorIsInclusiveBoundary() {
        // Exactly at the floor is healthy; one below is degraded.
        let floor = TmuxBackend.scrollbackHistoryLimit
        #expect(!TmuxBackend.isScrollbackDegraded(historyLimit: floor, alternateOn: false))
        #expect(TmuxBackend.isScrollbackDegraded(historyLimit: floor - 1, alternateOn: false))
    }

    @Test func customFloorIsHonored() {
        // A caller can tighten the floor; a window below the custom floor is degraded.
        #expect(TmuxBackend.isScrollbackDegraded(historyLimit: 10000, alternateOn: false, floor: 20000))
        #expect(!TmuxBackend.isScrollbackDegraded(historyLimit: 10000, alternateOn: false, floor: 5000))
    }
}
