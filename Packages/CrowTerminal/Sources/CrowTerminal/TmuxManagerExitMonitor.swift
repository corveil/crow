import CrowCore
import Foundation

/// Manager-window foreground-command poll (#558).
///
/// Extracted from `TmuxBackend` (CROW-1222). The poll still hops the
/// blocking `display-message` off the main actor; `onExit` still fires
/// once and `SessionService` re-arms it.

extension TmuxBackend {
    /// Decide whether the Manager agent has exited, from one poll sample of its
    /// window's foreground command (#558). Because the agent (`claude …`) runs
    /// *inside* the window's shell wrapper rather than as the pane's direct
    /// child, its exit doesn't kill the pane — the foreground just falls back to
    /// a bare login shell. So we report an exit only once we've seen the agent
    /// actually running (`sawAgentRunning`, a non-shell foreground) and now see
    /// a bare login shell. `nil` (window gone / read failed) is never an exit —
    /// that path also covers teardown, keeping restart/shutdown false-positive
    /// free. Pure so the transition policy is unit-testable without tmux.
    nonisolated static func managerAgentDidExit(paneCommand: String?, sawAgentRunning: Bool) -> Bool {
        guard sawAgentRunning, let command = paneCommand else { return false }
        return orphanLoginShells.contains(command)
    }

    /// Advance the exit-monitor state machine by one poll sample, so the whole
    /// transition — not just its terminal condition — is unit-testable without
    /// tmux (#558). `sample` is the window's foreground command, or `nil` when
    /// the read was inconclusive (binding absent / `display-message` threw /
    /// window gone). Returns the updated `sawAgentRunning` latch and whether an
    /// exit should fire. A non-empty non-shell command latches "agent running";
    /// a bare login shell after that latch fires; `nil` and `""` are no-ops.
    nonisolated static func advanceExitMonitor(
        sawAgentRunning: Bool, sample: String?
    ) -> (sawAgentRunning: Bool, fired: Bool) {
        guard let command = sample else { return (sawAgentRunning, false) }
        if orphanLoginShells.contains(command) {
            return (sawAgentRunning, managerAgentDidExit(paneCommand: command, sawAgentRunning: sawAgentRunning))
        }
        if !command.isEmpty { return (true, false) }
        return (sawAgentRunning, false)
    }

    // MARK: - Manager exit monitor (#558)

    /// Watch the Manager terminal's tmux window and fire `onExit` the first time
    /// its foreground command falls back to a bare login shell after the agent
    /// was seen running — i.e. the Manager's `claude`/`codex`/… process exited.
    ///
    /// A `tmux attach-session` client only signals when the whole client dies,
    /// so it can't tell a per-window agent exit apart (#558). We poll
    /// `#{pane_current_command}` for the Manager window instead — the same
    /// signal the orphan reaper reads.
    ///
    /// At most one monitor runs; a second call cancels the first. The poll skips
    /// samples where the binding is absent (async adopt on launch hasn't landed
    /// yet) or the `display-message` throws (window gone / server down), so
    /// attach-client teardown and restart/shutdown never false-positive. Stops
    /// after firing once; `SessionService` re-arms it on the next Manager launch.
    ///
    /// The blocking `display-message` runs off the main actor (`Task.detached`)
    /// and only the `onExit` hop-back touches the UI thread — a perpetual poll
    /// must never stall AppKit even if the tmux subprocess wedges to its
    /// watchdog timeout.
    ///
    /// Sampling floor: an agent that both launches and exits inside one
    /// `pollInterval` is never observed running, so `sawAgentRunning` stays
    /// false and no banner fires. That's an accepted missed-detection inherent
    /// to polling, not a false positive.
    public func startManagerExitMonitor(
        id: UUID,
        pollInterval: TimeInterval = 3.0,
        onExit: @escaping @MainActor () -> Void
    ) {
        stopManagerExitMonitor()
        let nanos = UInt64(pollInterval * 1_000_000_000)
        managerExitMonitor = Task { [weak self] in
            var sawAgentRunning = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                guard let self else { return }
                // Capture the tmux handle + window index on the main actor, then
                // read `#{pane_current_command}` off it: `TmuxController.run`
                // blocks the calling thread (on a semaphore since #653, without
                // pumping the run loop), so keep that subprocess off the UI
                // thread. A missing binding/controller yields a `nil` sample (skip).
                let ctrl = self.controller
                let windowIndex = self.bindings[id]
                let raw: String? = await Task.detached { () -> String? in
                    guard let ctrl, let windowIndex else { return nil }
                    return try? ctrl.displayMessage(
                        target: "\(ctrl.sessionName):\(windowIndex)",
                        format: "#{pane_current_command}"
                    )
                }.value
                let sample = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
                if Task.isCancelled { return }
                let (nextSaw, fired) = Self.advanceExitMonitor(sawAgentRunning: sawAgentRunning, sample: sample)
                sawAgentRunning = nextSaw
                if fired {
                    CrowLog.info("[CrowTelemetry manager:exit_detected terminal=\(id) command=\(sample ?? "")]")
                    onExit()
                    return
                }
            }
        }
    }

    /// Cancel the Manager exit monitor if one is running. Idempotent.
    public func stopManagerExitMonitor() {
        managerExitMonitor?.cancel()
        managerExitMonitor = nil
    }
}
