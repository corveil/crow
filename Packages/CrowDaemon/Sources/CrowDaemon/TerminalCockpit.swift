import CrowTerminal
import Foundation

/// Owns the shared tmux "cockpit" session that browser terminals attach to.
///
/// Reuses the portable ``TmuxController`` plus the bundled `crow-tmux.conf`
/// (extended-keys, allow-passthrough, etc.). One session is shared across every
/// browser tab — each `/terminal` WebSocket runs its own PTY doing
/// `tmux attach-session`, exactly as the macOS app's cockpit does. Wrapping the
/// shell in `crow-shell-wrapper.sh` (OSC readiness markers, agent auto-launch)
/// is a deliberate M1 follow-up; the plain shell already proves the byte path.
struct TerminalCockpit: Sendable {
    static let sessionName = "crow-cockpit"
    let controller: TmuxController

    init?(devRoot: String) {
        guard let tmux = Self.resolveTmuxBinary() else { return nil }
        let socketPath = NSTemporaryDirectory() + "crowd-tmux.sock"
        controller = TmuxController(tmuxBinary: tmux, socketPath: socketPath, sessionName: Self.sessionName)
        ensureSession()
    }

    /// Create the cockpit session (default shell, `crow-tmux.conf` applied) if it
    /// doesn't exist yet. Idempotent — extra browser tabs attach to the same
    /// session. A failed create surfaces to the user as an attach error inside
    /// the terminal, which is easier to diagnose than aborting daemon boot.
    private func ensureSession() {
        guard !controller.hasSession() else { return }
        let conf = BundledResources.tmuxConfURL?.path
        try? controller.newSessionDetached(configPath: conf, env: [:], command: nil)
    }

    /// The command a PTY runs to join the cockpit:
    /// `tmux -S <sock> attach-session -t crow-cockpit`. Streaming this PTY's
    /// bytes to xterm.js is the entire M1 terminal path.
    func attachCommand() -> String {
        "\(Self.shellQuote(controller.tmuxBinary)) -S \(Self.shellQuote(controller.socketPath)) "
            + "attach-session -t \(Self.shellQuote(Self.sessionName))"
    }

    /// First usable tmux binary: `CROW_TMUX` override, then common install
    /// locations (Linux `/usr/bin`, Homebrew, `/usr/local`).
    private static func resolveTmuxBinary() -> String? {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CROW_TMUX"],
           fm.isExecutableFile(atPath: override) {
            return override
        }
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux", "/bin/tmux"]
        where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
