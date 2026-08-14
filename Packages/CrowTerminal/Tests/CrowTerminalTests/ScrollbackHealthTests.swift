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
        // the full history-limit. This is the #804/#821 case and must STAY
        // detected — a window that never opted into the alt screen has no
        // business being in it.
        #expect(TmuxBackend.isScrollbackDegraded(historyLimit: 50000, alternateOn: true))
        #expect(TmuxBackend.isScrollbackDegraded(
            historyLimit: 50000, alternateOn: true, alternateScreenEnabled: false))
    }

    // MARK: - Kind-awareness (ADR-0013)

    @Test func agentSurfaceInAlternateBufferIsHealthy() {
        // An agent-TUI window is CONFIGURED for the alt screen so its repaints
        // don't silt up the scrollback (#822). Being in that buffer is the
        // design working — flagging it would badge every agent tab with the ⚠
        // "Recreate" affordance.
        #expect(!TmuxBackend.isScrollbackDegraded(
            historyLimit: 50000, alternateOn: true, alternateScreenEnabled: true))
        // Also healthy before the agent has actually entered the alt screen.
        #expect(!TmuxBackend.isScrollbackDegraded(
            historyLimit: 50000, alternateOn: false, alternateScreenEnabled: true))
    }

    @Test func leftoverInlineAgentHistoryClampIsDegraded() {
        // CROW-1010 retracted the CROW-1008 `history-limit 0` clamp. A window
        // still sitting at 0 — born after that rebuild, before this fix —
        // fails the floor so the UI badges ⚠ Recreate (the only heal; the
        // limit is frozen at birth). A plain shell at 0 was always degraded.
        #expect(TmuxBackend.isScrollbackDegraded(
            historyLimit: TmuxBackend.inlineAgentHistoryLimit,
            alternateOn: false,
            alternateScreenEnabled: true))
        #expect(TmuxBackend.isScrollbackDegraded(
            historyLimit: TmuxBackend.inlineAgentHistoryLimit,
            alternateOn: false,
            alternateScreenEnabled: false))
    }

    /// A failed tmux read must be distinguishable from a successful read that
    /// found nothing. `list-terminals` re-derives `agent_surface` from
    /// `SessionTerminal.isAgentSurface` when tmux can't answer; if failure were
    /// reported as an empty set, every bound agent tab would instead be told
    /// `agent_surface: false` — so the client would swallow mouse modes and
    /// scroll xterm locally while tmux has that window in the alternate buffer,
    /// which has no scrollback to scroll.
    @Test @MainActor func classificationReportsFailureDistinctlyFromAnEmptyResult() {
        // A fresh, unconfigured backend has no controller, so the read cannot
        // run — the same shape as tmux being unavailable at runtime. Uses its
        // own instance rather than `.shared` so the result doesn't depend on
        // whether this host happens to have a live tmux server.
        let backend = TmuxBackend()
        #expect(backend.windowScrollbackClassification() == nil,
                "a read that could not run must be nil, not ([], [], [])")
        // The fail-open convenience accessors still collapse it to empty.
        #expect(backend.degradedWindowIndices().isEmpty)
        #expect(backend.agentSurfaceWindowIndices().isEmpty)
        // CROW-1023: the alt-buffer accessor fails open too — a failed read must
        // not report windows as latched (which would cap their scrollback to 0).
        #expect(backend.altBufferWindowIndices().isEmpty)
    }

    @Test func agentSurfaceStillFailsTheHistoryFloor() {
        // Kind-awareness only relaxes the alt-buffer term. A pre-config window
        // is caught by the floor whether or not it's an agent surface — which
        // is what keeps the CROW-804 detection meaningful, since the real
        // casualties measured history_limit=5000 alongside alternate_on=1.
        #expect(TmuxBackend.isScrollbackDegraded(
            historyLimit: 5000, alternateOn: true, alternateScreenEnabled: true))
        #expect(TmuxBackend.isScrollbackDegraded(
            historyLimit: 5000, alternateOn: false, alternateScreenEnabled: true))
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

    // MARK: - Alt-buffer latch (CROW-1023)

    @Test func altBufferLatchRecordsAWindowInTheAltBuffer() {
        // A window currently in the alt buffer enters the latch → the client
        // caps its scrollback (an alt-buffer Claude build).
        #expect(TmuxBackend.updatedAltBufferLatch(
            liveWindows: [(4, true)], prior: []) == [4])
    }

    @Test func altBufferLatchIsSticky() {
        // THE core property: once observed in the alt buffer, a window stays
        // latched even when a later read finds it back in the main buffer
        // (an alt-buffer build shelling out / exiting). Without this the client
        // would flip its scrollback to 50k and back every such transient.
        #expect(TmuxBackend.updatedAltBufferLatch(
            liveWindows: [(4, false)], prior: [4]) == [4])
    }

    @Test func inlineWindowNeverLatches() {
        // A window never seen in the alt buffer (an INLINE Claude build, or
        // Cursor) stays out of the latch → keeps the unified 50k, a working
        // wheel, and a visible scrollbar. This is the CROW-1023 fix.
        #expect(TmuxBackend.updatedAltBufferLatch(
            liveWindows: [(4, false)], prior: []).isEmpty)
        // Still empty after many inline reads.
        var latch: Set<Int> = []
        for _ in 0..<5 {
            latch = TmuxBackend.updatedAltBufferLatch(liveWindows: [(4, false)], prior: latch)
        }
        #expect(latch.isEmpty)
    }

    @Test func altBufferLatchPrunesKilledWindows() {
        // A killed index drops out of the latch so a reused index doesn't
        // inherit a stale observation (belt-and-suspenders with the explicit
        // clear at register/kill).
        #expect(TmuxBackend.updatedAltBufferLatch(
            liveWindows: [(5, true)], prior: [4]) == [5])
    }

    @Test func altBufferLatchKeepsAStillLivingLatchedWindow() {
        // A previously latched window that still exists — even in the main
        // buffer now — is retained, while a new alt-buffer window is added.
        #expect(TmuxBackend.updatedAltBufferLatch(
            liveWindows: [(1, true), (2, false)], prior: [2]) == [1, 2])
    }
}
