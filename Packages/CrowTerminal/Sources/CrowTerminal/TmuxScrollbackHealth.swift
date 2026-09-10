import CrowCore
import Foundation

/// Scrollback-health classification, sticky alt-buffer latch (CROW-1023),
/// and `enableAlternateScreen` (#822 / ADR 0013).
///
/// Extracted from `TmuxBackend` (CROW-1222). `list-terminals` still reports
/// `uses_alternate_screen` from the latch, not the static per-kind flag.

extension TmuxBackend {
    // MARK: - Scrollback health (CROW-804)

    /// Pure policy: a window's scroll-up can't show the full transcript when its
    /// pane is in the alternate buffer (no scrollback) OR its `history_limit` is
    /// below the ceiling we bake into new windows. tmux freezes both at window
    /// birth and can't resize/undo either in place (see `crow-tmux.conf`
    /// history-limit caveat), so a degraded window's only remedy is recreation.
    /// `nonisolated static` so the policy is unit-testable without tmux.
    ///
    /// `alternateScreenEnabled` makes the alt-buffer half of that test
    /// KIND-AWARE (ADR-0013). Under the per-surface hybrid scroll model an
    /// agent-TUI window deliberately runs with `alternate-screen on`, so
    /// `alternateOn == true` there is the design working, not a stuck window —
    /// flagging it would badge every agent tab with the ⚠ "Recreate" affordance.
    /// The `history_limit` floor still applies to those windows, and it is what
    /// keeps the CROW-804/#821 detection meaningful: the real pre-config
    /// casualties measured `history_limit=5000` alongside `alternate_on=1`, so
    /// they stay caught by the floor.
    ///
    /// CROW-1010 retracted the CROW-1008 inline-agent `history-limit 0` clamp,
    /// so an agent window at 0 is a leftover of that clamp and fails the floor
    /// like any other under-cap window (Recreate rebuilds it at 50k). A plain
    /// shell at 0 was always degraded.
    ///
    /// Known blind spot: an agent window genuinely wedged in the alt buffer at
    /// the full 50000 limit is now indistinguishable from the normal state.
    /// That is the accepted cost of the hybrid model — the alternative is a
    /// false ⚠ on every healthy agent surface.
    nonisolated public static func isScrollbackDegraded(
        historyLimit: Int,
        alternateOn: Bool,
        alternateScreenEnabled: Bool = false,
        floor: Int = TmuxBackend.scrollbackHistoryLimit
    ) -> Bool {
        if historyLimit < floor { return true }
        // An agent surface is SUPPOSED to be in the alt buffer.
        return alternateScreenEnabled ? false : alternateOn
    }

    /// Pure CROW-1023 alt-buffer latch update. Given the live windows (index +
    /// current `#{alternate_on}`) and the prior latch, return the new latch:
    /// every window ever observed in the alt buffer, minus windows that no
    /// longer exist.
    ///
    /// STICKY (union) is the point — a Claude/agent build that enters the alt
    /// screen once keeps the capped-0 scroll model through its transient
    /// main-buffer drops (shell-out, exit) instead of flip-flopping xterm's
    /// scrollback every poll. PRUNE (intersect with live indices) keeps a killed
    /// window's observation from leaking to whatever tmux later assigns that
    /// index. `nonisolated static` so the policy is unit-testable without tmux,
    /// exactly like `isScrollbackDegraded`.
    nonisolated public static func updatedAltBufferLatch(
        liveWindows: [(index: Int, alternateOn: Bool)],
        prior: Set<Int>
    ) -> Set<Int> {
        var latch = prior
        for w in liveWindows where w.alternateOn { latch.insert(w.index) }
        latch.formIntersection(liveWindows.map(\.index))
        return latch
    }

    /// The per-window classifications the web UI needs, from ONE `list-windows`
    /// read: which windows are scrollback-degraded (CROW-804 ⚠ Recreate), which
    /// run the agent-TUI scroll model (ADR-0013 wheel/mouse routing), and which
    /// have actually entered the alternate buffer (CROW-1023, the sticky
    /// `uses_alternate_screen` latch).
    ///
    /// They ship together on every `list-terminals` RPC, and each is derived
    /// from the same three fields, so reading twice would fork a second `tmux`
    /// subprocess per call for nothing.
    ///
    /// Returns `nil` when tmux is unavailable or the read fails — deliberately
    /// NOT a triple of empty sets. Empty is a perfectly valid SUCCESS (a server
    /// of nothing but plain shells), so emptiness cannot double as a failure
    /// signal. Callers that need to fall back to a different source of truth on
    /// failure — `list-terminals` re-deriving `agent_surface` from
    /// `SessionTerminal.isAgentSurface`, and `uses_alternate_screen` from the
    /// `AgentRegistry` capability — can only do that if failure is
    /// distinguishable. Callers that are happy to fail open collapse it with
    /// `?? []`.
    ///
    /// Not read-only: it maintains the alt-buffer latch (`observedAltBufferWindows`).
    /// Confined to `@MainActor` like the rest of this type, so the mutation is
    /// race-free.
    public func windowScrollbackClassification(
        floor: Int = TmuxBackend.scrollbackHistoryLimit
    ) -> (degraded: Set<Int>, agentSurfaces: Set<Int>, altBuffer: Set<Int>)? {
        guard let ctrl = controller else { return nil }
        do {
            let windows = try ctrl.listWindowScrollback()
            let degraded = windows.filter {
                Self.isScrollbackDegraded(
                    historyLimit: $0.historyLimit,
                    alternateOn: $0.alternateOn,
                    alternateScreenEnabled: $0.alternateScreenEnabled,
                    floor: floor)
            }
            let agents = windows.filter(\.alternateScreenEnabled)
            // CROW-1023: update the sticky alt-buffer latch from this read (pure
            // policy in `updatedAltBufferLatch`), then report it as the third set.
            observedAltBufferWindows = Self.updatedAltBufferLatch(
                liveWindows: windows.map { ($0.index, $0.alternateOn) },
                prior: observedAltBufferWindows)
            return (Set(degraded.map(\.index)),
                    Set(agents.map(\.index)),
                    observedAltBufferWindows)
        } catch {
            reportIfTimeout(error)
            return nil
        }
    }

    /// Window indices whose scrollback is degraded per `isScrollbackDegraded`.
    /// Fails open (`[]`) — not badging a window on a failed read is the safe
    /// direction, and matches `listCockpitWindows`. Callers needing BOTH this
    /// and the agent-surface set should use `windowScrollbackClassification`
    /// so tmux is only read once.
    public func degradedWindowIndices(floor: Int = TmuxBackend.scrollbackHistoryLimit) -> Set<Int> {
        windowScrollbackClassification(floor: floor)?.degraded ?? []
    }

    /// Window indices configured as agent-TUI surfaces (`alternate-screen on`),
    /// i.e. the windows that own their own viewport + scrollback under the
    /// hybrid scroll model (ADR-0013). Read from tmux rather than inferred from
    /// window names so the daemon and the web client route on the SAME ground
    /// truth the daemon actually applied.
    public func agentSurfaceWindowIndices() -> Set<Int> {
        windowScrollbackClassification()?.agentSurfaces ?? []
    }

    /// Window indices that have entered the alternate buffer at least once and
    /// are latched to the capped-0 scroll model (CROW-1023). This — not the
    /// static per-kind capability — is what `list-terminals` forwards as
    /// `uses_alternate_screen`. Fails open (`[]`); a window not yet observed in
    /// the alt buffer is treated as inline (unified 50k), which is the safe
    /// direction (a real alt-buffer build re-latches within a poll, an inline
    /// build stays scrollable).
    public func altBufferWindowIndices() -> Set<Int> {
        windowScrollbackClassification()?.altBuffer ?? []
    }

    /// Give one window the agent-TUI scroll model: `alternate-screen on`, so a
    /// repainting agent keeps its frames in the alt buffer (which has no
    /// scrollback) instead of depositing every repaint into the shared 50k
    /// history as duplicate-frame sediment (#822, ADR-0013).
    ///
    /// Best-effort by design: the window is already usable without it, so a
    /// failure here must never fail terminal creation. Returns whether it stuck.
    @discardableResult
    public func enableAlternateScreen(index: Int) -> Bool {
        guard let ctrl = controller else { return false }
        do {
            try ctrl.setWindowOption(index: index, name: "alternate-screen", value: "on")
            return true
        } catch {
            reportIfTimeout(error)
            CrowLog.info("[Crow] could not set alternate-screen on window \(index): \(error)")
            return false
        }
    }

    /// Live per-window scrollback tuple. Empty when tmux is down. Test/debug
    /// counterpart of `windowScrollbackClassification` that keeps the raw
    /// `history_limit` so CROW-1010 can assert inline agents keep the 50k cap.
    func windowScrollbackSnapshot() -> [(index: Int, historyLimit: Int, alternateOn: Bool, alternateScreenEnabled: Bool)] {
        guard let ctrl = controller else { return [] }
        return (try? ctrl.listWindowScrollback()) ?? []
    }
}
