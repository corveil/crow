import CrowTerminal
import Foundation

/// Bridges the daemon to the tmux "cockpit" that holds every session's
/// terminals — one tmux window per `SessionTerminal` (CROW-581).
///
/// It attaches to the **same** tmux server the desktop Crow app uses
/// (`$TMPDIR/crow-tmux.sock`, session `crow-cockpit`), adopting it when the app
/// is running so the web UI shows the real, live terminals. Each browser
/// `/terminal` connection gets its own ephemeral **grouped** session
/// (`tmux new-session -t crow-cockpit`), which shares the cockpit's window list
/// but keeps an independent current-window pointer — so selecting a window in
/// the browser never hijacks the desktop app's visible window.
struct TerminalCockpit: Sendable {
    static let sessionName = "crow-cockpit"
    let controller: TmuxController

    init?(devRoot: String) {
        guard let tmux = Self.resolveTmuxBinary() else { return nil }
        // Match the app's stable socket path (#330) so we share its tmux server
        // and its live session windows rather than spinning up an isolated one.
        let socketPath = Self.appTmuxSocketPath()
        controller = TmuxController(tmuxBinary: tmux, socketPath: socketPath, sessionName: Self.sessionName)
        ensureSession()
    }

    /// Adopt the app's cockpit if it's already running; otherwise create a bare
    /// one (default shell anchor) so the daemon works standalone too. A failed
    /// create surfaces as an attach error in the browser rather than aborting.
    private func ensureSession() {
        guard !controller.hasSession() else { return }
        let conf = BundledResources.tmuxConfURL?.path
        try? controller.newSessionDetached(configPath: conf, env: [:], command: nil)
    }

    /// Create an ephemeral grouped session sharing `crow-cockpit`'s windows but
    /// with its own current-window pointer. Returns the group name to attach to.
    func openViewSession() -> String {
        let group = "crowd-web-" + UUID().uuidString.prefix(8).lowercased()
        _ = try? controller.run(["new-session", "-d", "-s", group, "-t", Self.sessionName])
        return group
    }

    func closeViewSession(_ group: String) {
        _ = try? controller.run(["kill-session", "-t", group])
    }

    /// `tmux -S <sock> attach-session -t <group>` — the command a PTY runs to
    /// join a browser's private view of the shared cockpit.
    func attachCommand(group: String) -> String {
        "\(Self.shellQuote(controller.tmuxBinary)) -S \(Self.shellQuote(controller.socketPath)) "
            + "attach-session -t \(Self.shellQuote(group))"
    }

    /// Switch a browser's grouped view to a specific window index, leaving every
    /// other client (incl. the desktop app) on its own current window.
    func selectWindow(group: String, index: Int) {
        _ = try? controller.run(["select-window", "-t", "\(group):\(index)"])
    }

    /// The desktop app's stable tmux socket: `$TMPDIR/crow-tmux.sock` (#330).
    private static func appTmuxSocketPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CROW_TMUX_SOCKET"], !override.isEmpty {
            return override
        }
        let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return URL(fileURLWithPath: tmpdir).appendingPathComponent("crow-tmux.sock").path
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
