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
        if !controller.hasSession() {
            let conf = BundledResources.tmuxConfURL?.path
            try? controller.newSessionDetached(configPath: conf, env: [:], command: nil)
        }
        // Reap grouped sessions this or a prior crowd leaked (#667). Runs on
        // every startup, whether we adopted or created the cockpit.
        reapOrphanedViewSessions()
        logDegradedScrollbackWindows()
    }

    /// Diagnostic: log every window whose scroll-up can't show the full
    /// transcript — stuck in the alternate-screen buffer (`alternate_on=1`)
    /// and/or capped below the current `history-limit` because it was created
    /// before the config bump. tmux can't heal these in place; the web UI badges
    /// them and offers a recreate (CROW-804). Best-effort; never throws.
    private func logDegradedScrollbackWindows() {
        guard let windows = try? controller.listWindowScrollback() else { return }
        for w in windows where TmuxBackend.isScrollbackDegraded(
            historyLimit: w.historyLimit, alternateOn: w.alternateOn) {
            NSLog("[CrowTelemetry tmux:scrollback_degraded index=\(w.index) history_limit=\(w.historyLimit) alternate_on=\(w.alternateOn ? 1 : 0)]")
        }
    }

    /// Kill `crowd-web-*` grouped sessions left detached by a prior crowd's
    /// restart/crash (#667). Each `/terminal` connection creates one via
    /// `openViewSession` and is supposed to tear it down via
    /// `defer closeViewSession` (TerminalWebSocket), but a crowd that dies
    /// mid-connection never runs that defer — while the separate tmux server
    /// keeps the group alive. These groups carry no persisted state and are
    /// never re-adopted (a reconnecting browser opens a fresh group), so any
    /// DETACHED one is pure garbage; leaked groups also pin windows at stale
    /// sizes and pile up on the shared server across restarts.
    ///
    /// Safety: only kill groups with `session_attached == 0`. A live browser
    /// holds its group attached via the PTY running `attach-session`, so an
    /// in-use view (even one owned by a concurrent crowd on this shared server)
    /// is `attached >= 1` and skipped. Best-effort; never throws.
    private func reapOrphanedViewSessions() {
        guard let out = try? controller.run(
            ["list-sessions", "-F", "#{session_name} #{session_attached}"]
        ) else { return }
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2,
                  parts[0].hasPrefix("crowd-web-"),
                  parts[1] == "0" else { continue }
            _ = try? controller.run(["kill-session", "-t", String(parts[0])])
        }
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

    /// How many lines of pane history to replay on (re)connect. Matched to the
    /// xterm.js client scrollback (`scrollback: 50000` in app.js) and the tmux
    /// `history-limit` (crow-tmux.conf) so the full retained history survives a
    /// crowd restart or browser reload (CROW-606).
    static let replayLines = 50000

    /// Capture window `index`'s pane scrollback (history + current screen) and
    /// package it as bytes ready to write into a reconnecting xterm.js buffer.
    /// Returns `nil` when the capture fails (best-effort — a live-only pane is
    /// still preferable to dropping the connection). See `replayFrame`.
    func replayData(group: String, index: Int) -> Data? {
        guard let raw = try? controller.capturePane(
            target: "\(group):\(index)", linesBack: Self.replayLines, escapes: true)
        else { return nil }
        return Self.replayFrame(from: raw)
    }

    /// Transform a `capture-pane -pe` blob into a self-contained replay frame for
    /// xterm.js. Pure (no tmux) so it's unit-testable. Steps:
    ///   1. strip trailing newlines — `capture-pane` pads a trailing LF that would
    ///      otherwise push the viewport down one row versus tmux's own redraw;
    ///   2. convert bare LF → CRLF — `capture-pane` emits `\n` only, and xterm.js
    ///      treats `\n` as line-feed-without-carriage-return, so raw output would
    ///      stair-step down the screen;
    ///   3. prepend `ESC[H ESC[2J ESC[3J` (home + clear screen + clear scrollback)
    ///      so repeated selects/reconnects REBUILD the buffer rather than stack
    ///      duplicate copies of the history.
    /// The blob keeps the current screen at its tail, so tmux's live attach redraw
    /// repaints those same viewport rows in place — the replayed history lands
    /// above the live viewport regardless of which write wins the race.
    static func replayFrame(from raw: String) -> Data {
        let trimmed = raw.replacingOccurrences(of: "[\r\n]+$", with: "", options: .regularExpression)
        let crlf = trimmed.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let clear = "\u{1b}[H\u{1b}[2J\u{1b}[3J"
        return Data((clear + crlf).utf8)
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
