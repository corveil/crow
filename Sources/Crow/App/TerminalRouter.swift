import CrowCore
import CrowTerminal
import Foundation

/// Routes per-terminal operations to the tmux backend.
///
/// tmux is the only backend (#303), so this is a thin, centralized facade
/// over `TmuxBackend.shared` that keeps call sites readable and gives one
/// place to evolve the policy if another backend is ever added.
@MainActor
public enum TerminalRouter {

    /// Send text to a terminal via the load-buffer + paste-buffer route
    /// (PROD #3) — works for arbitrary payloads; `send-keys -l` would fail
    /// on >10KB strings.
    public static func send(_ terminal: SessionTerminal, text: String) {
        do {
            try TmuxBackend.shared.sendText(id: terminal.id, text: text)
        } catch {
            NSLog("[TerminalRouter] tmux sendText failed for \(terminal.id): \(error)")
        }
    }

    /// Destroy the terminal's tmux window.
    public static func destroy(_ terminal: SessionTerminal) {
        TmuxBackend.shared.destroyTerminal(id: terminal.id)
    }

    /// Mark the terminal as one whose readiness should be tracked.
    /// No-op for tmux: `startReadinessWatch` fires when the binding registers.
    public static func trackReadiness(for terminal: SessionTerminal) {
        // Intentionally empty — readiness is wired at register time.
    }

    /// Whether the terminal's tmux window is alive enough to receive a `send`.
    /// Callers that want to fail-soft when the user hasn't materialized the
    /// terminal yet — e.g. auto-respond and the session-card quick action
    /// buttons — gate on this instead of relying on the send to throw.
    public static func canSend(_ terminal: SessionTerminal) -> Bool {
        TmuxBackend.shared.isRegistered(id: terminal.id)
    }
}
