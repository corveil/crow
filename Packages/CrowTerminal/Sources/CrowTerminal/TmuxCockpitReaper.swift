import CrowCore
import Foundation

/// Cockpit unbound-window reap (#408) and targeted-auto orphan reconcile
/// (CROW-581). Unrelated to the legacy PID-socket `TmuxOrphanReaper`.
///
/// Extracted from `TmuxBackend` (CROW-1222). Policy statics stay on
/// `TmuxBackend` so existing tests keep calling `TmuxBackend.shouldReap*`
/// with no assertion changes.

extension TmuxBackend {
    /// Bare login shells we consider "orphaned" when a cockpit window is not
    /// referenced by any terminal — i.e. a window left at a shell with no agent
    /// running (#408). Anything else (claude/codex/node/an editor/…) is left
    /// alone. tmux reports `pane_current_command` without the login-shell `-`
    /// prefix, but we match both forms defensively.
    nonisolated static let orphanLoginShells: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "sh", "-sh",
        "fish", "-fish", "dash", "-dash", "ksh", "tcsh", "csh", "login",
    ]

    /// Decide whether a single cockpit window should be reaped. Pure so the
    /// policy is unit-testable: reap only when the window is NOT referenced by a
    /// live terminal AND its pane is sitting at a bare login shell. Never reaps
    /// a window running an agent (or any non-shell process), so an agent that
    /// exited and left the user at a shell — but whose terminal still references
    /// the window — is preserved (it's in `keep`).
    nonisolated static func shouldReapWindow(index: Int, command: String, keep: Set<Int>) -> Bool {
        if keep.contains(index) { return false }
        return orphanLoginShells.contains(command)
    }

    /// Targeted-auto orphan policy (CROW-581). Reap a cockpit window that no live
    /// terminal references (`!keep.contains`) when it is either a forgotten bare
    /// login shell OR a positively-identified coding-agent window (its pinned
    /// name is one of `agentWindowNames`) that has stayed orphaned across two
    /// passes (`seenOrphanedLastPass`, the grace). NEVER reaps the session anchor
    /// (index 0), a bound window, an unknown/infra window, or a **Manager**
    /// (name contains "manager") — Managers are long-lived and may be unbound.
    /// Pure so the policy is unit-testable without tmux.
    nonisolated static func shouldReapOrphanWindow(
        index: Int, name: String, command: String, keep: Set<Int>,
        agentWindowNames: Set<String>, seenOrphanedLastPass: Bool
    ) -> Bool {
        if index == 0 { return false }
        if keep.contains(index) { return false }
        if name.range(of: "manager", options: [.caseInsensitive]) != nil { return false }
        if orphanLoginShells.contains(command) { return true }
        if agentWindowNames.contains(name) { return seenOrphanedLastPass }
        return false
    }

    /// Reap orphaned cockpit windows per `shouldReapOrphanWindow` (targeted-auto).
    /// `keepWindowIndices` are windows referenced by persisted terminals — unioned
    /// with the in-memory `bindings` so a just-adopted window is never reaped.
    /// `agentWindowNames` are the display names `new-terminal` pins on managed
    /// agent windows. Tracks the agent-orphan set for the next pass's grace.
    /// Best-effort; returns the count reaped (CROW-581).
    @discardableResult
    public func reconcileOrphanWindows(keepWindowIndices: Set<Int>, agentWindowNames: Set<String>) -> Int {
        guard let ctrl = controller else { return 0 }
        let keep = keepWindowIndices.union(bindings.values)
        let windows = listCockpitWindows()
        let previouslyOrphaned = orphanGraceWindows
        var stillOrphanedAgents: Set<Int> = []
        var reaped = 0
        for w in windows {
            // Agent-named orphans are grace candidates for the next pass.
            if w.index != 0, !keep.contains(w.index), agentWindowNames.contains(w.name),
               w.name.range(of: "manager", options: [.caseInsensitive]) == nil {
                stillOrphanedAgents.insert(w.index)
            }
            if Self.shouldReapOrphanWindow(
                index: w.index, name: w.name, command: w.command, keep: keep,
                agentWindowNames: agentWindowNames,
                seenOrphanedLastPass: previouslyOrphaned.contains(w.index)) {
                ctrl.killWindow(index: w.index)
                CrowLog.info("[CrowTelemetry tmux:orphan_window_reaped index=\(w.index) name=\(w.name) command=\(w.command)]")
                reaped += 1
            }
        }
        orphanGraceWindows = stillOrphanedAgents
        if reaped > 0 { CrowLog.info("[Crow] Reaped \(reaped) orphaned cockpit window(s) (CROW-581)") }
        return reaped
    }

    /// Reap cockpit windows that no live terminal references AND that are
    /// sitting at a bare login shell — leaked windows from a timed-out
    /// `new-window` or a forgotten terminal (#408). `keepWindowIndices` is the
    /// set of window indices referenced by persisted terminals; it is unioned
    /// with the in-memory `bindings` so a window created/adopted this run is
    /// never reaped. Best-effort; returns the count reaped.
    @discardableResult
    public func reapUnboundCockpitWindows(keepWindowIndices: Set<Int>) -> Int {
        guard let ctrl = controller else { return 0 }
        let keep = keepWindowIndices.union(bindings.values)
        let windows: [(index: Int, command: String)]
        do {
            windows = try ctrl.listWindowCommands()
        } catch {
            reportIfTimeout(error)
            return 0
        }
        var reaped = 0
        for window in windows where Self.shouldReapWindow(index: window.index, command: window.command, keep: keep) {
            ctrl.killWindow(index: window.index)
            CrowLog.info("[CrowTelemetry tmux:orphan_window_reaped index=\(window.index) command=\(window.command)]")
            reaped += 1
        }
        if reaped > 0 {
            CrowLog.info("[Crow] Reaped \(reaped) orphaned bare-shell cockpit window(s) (#408)")
        }
        return reaped
    }
}
