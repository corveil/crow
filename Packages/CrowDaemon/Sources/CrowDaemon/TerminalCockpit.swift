import CrowCore
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
    /// When set, `previewText` delegates here instead of calling tmux (unit tests).
    private let previewCapture: (@Sendable (Int) -> String?)?

    init?(devRoot: String) {
        guard let tmux = Self.resolveTmuxBinary() else { return nil }
        // Match the app's stable socket path (#330) so we share its tmux server
        // and its live session windows rather than spinning up an isolated one.
        let socketPath = Self.appTmuxSocketPath()
        controller = TmuxController(tmuxBinary: tmux, socketPath: socketPath, sessionName: Self.sessionName)
        previewCapture = nil
        ensureSession()
    }

    /// Stub cockpit for handler tests — no tmux server required.
    init(previewCapture: @escaping @Sendable (Int) -> String?) {
        controller = TmuxController(
            tmuxBinary: "/bin/false", socketPath: "/dev/null", sessionName: Self.sessionName)
        self.previewCapture = previewCapture
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
            historyLimit: w.historyLimit,
            alternateOn: w.alternateOn,
            alternateScreenEnabled: w.alternateScreenEnabled) {
            CrowLog.info("[CrowTelemetry tmux:scrollback_degraded index=\(w.index) history_limit=\(w.historyLimit) alternate_on=\(w.alternateOn ? 1 : 0)]")
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

    /// How many lines of pane history to replay on (re)connect. Wired to
    /// `TmuxBackend.scrollbackHistoryLimit` — the same value baked into the tmux
    /// `history-limit` (crow-tmux.conf) and the xterm.js client scrollback
    /// (`scrollback: 50000` in app.js) — so the full retained history survives a
    /// crowd restart or browser reload (CROW-606) and the daemon replay can't
    /// drift from the policy floor (CROW-804 review).
    static let replayLines = TmuxBackend.scrollbackHistoryLimit

    /// Lines captured for the session-switcher preview card (CROW-976).
    static let previewLines = 15

    /// Capture window `index`'s pane scrollback (history + current screen) and
    /// package it as bytes ready to write into a reconnecting xterm.js buffer.
    /// Returns `nil` when the capture fails (best-effort — a live-only pane is
    /// still preferable to dropping the connection) **or** when the pane is in
    /// the alternate buffer — injecting that frame races the live attach
    /// redraw and parks the TUI caret below the input box (CROW-1035). See
    /// `replayFrame` and `shouldReplayScrollback`.
    func replayData(group: String, index: Int) -> Data? {
        if !Self.shouldReplayScrollback(alternateOn: paneIsOnAlternateScreen(group: group, index: index)) {
            return nil
        }
        guard let raw = try? controller.capturePane(
            target: "\(group):\(index)", linesBack: Self.replayLines, escapes: true)
        else { return nil }
        return Self.replayFrame(from: raw)
    }

    /// `#{alternate_on}` for `group:index`. `false` when tmux doesn't answer
    /// so a failed probe still takes the CROW-606 replay path (shells / inline
    /// agents) rather than silently dropping history.
    func paneIsOnAlternateScreen(group: String, index: Int) -> Bool {
        guard let raw = try? controller.displayMessage(
            target: "\(group):\(index)", format: "#{alternate_on}")
        else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Whether `select-window` should follow up with a capture-pane replay.
    /// Alt-buffer panes already have their current frame painted by the live
    /// attach; a second, line-oriented dump of that same frame is what jumps
    /// Claude's caret below the input box (CROW-1035).
    static func shouldReplayScrollback(alternateOn: Bool) -> Bool {
        !alternateOn
    }

    /// The DECSET mouse-tracking sequences a `select-window` must re-send so the
    /// browser's xterm mouse mode matches the pane again. Returns `nil` when the
    /// pane reports no active mouse mode (a shell, or an agent idling without
    /// tracking) — there is nothing to re-arm and the client keeps its local
    /// viewport scroll (ADR-0013).
    ///
    /// Why the daemon has to do this at all (CROW-1043): an in-place agent switch
    /// (`switchAgentWindow`, CROW-1035) calls `term.reset()` before `select-window`,
    /// which clears xterm's `mouseTrackingMode`. tmux emits mouse-mode changes to a
    /// client as **deltas**, so switching between two agent windows that share the
    /// same mouse state (Claude → Claude / the Manager) repaints no mouse DECSET —
    /// the client is stranded at `mouseTrackingMode: none`, `appOwnsScroll()` returns
    /// `false`, and the forwarded wheel goes dead until an explicit Reload re-attaches
    /// with the full initial state. Re-sending the pane's ACTUAL mouse mode restores
    /// the wheel deterministically, independent of tmux's per-client delta. The
    /// sequence is inert on a plain-shell surface — `swallowMouseMode` drops DECSET
    /// 1000–1016 there — so it is safe to emit on every `select-window`.
    func mouseModeReArmData(group: String, index: Int) -> Data? {
        guard let raw = try? controller.displayMessage(
            target: "\(group):\(index)",
            // Order: standard(1000) button(1002) any(1003) utf8(1005) sgr(1006).
            format: "#{mouse_standard_flag}#{mouse_button_flag}#{mouse_any_flag}#{mouse_utf8_flag}#{mouse_sgr_flag}")
        else { return nil }
        return Self.mouseModeReArmSequence(flags: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .map { Data($0.utf8) }
    }

    /// Build the DECSET enables for a `#{mouse_*_flag}` string. Pure (no tmux) so
    /// its shape is unit-testable. `flags` is the five `"0"`/`"1"` characters in the
    /// order standard/button/any/utf8/sgr; any other shape (a failed read, an older
    /// tmux) yields `nil` rather than a malformed sequence.
    static func mouseModeReArmSequence(flags: String) -> String? {
        let chars = Array(flags)
        guard chars.count == 5 else { return nil }
        let modes: [(Int, Character)] = [
            (1000, chars[0]), (1002, chars[1]), (1003, chars[2]), (1005, chars[3]), (1006, chars[4]),
        ]
        let esc = "\u{1b}"
        var seq = ""
        for (mode, flag) in modes where flag == "1" {
            seq += "\(esc)[?\(mode)h"
        }
        return seq.isEmpty ? nil : seq
    }

    /// Capture the last `previewLines` rows of a cockpit window as plain text for
    /// the session-switcher card. Best-effort — returns nil when capture fails.
    func previewText(windowIndex: Int) -> String? {
        if let previewCapture { return previewCapture(windowIndex) }
        guard let raw = try? controller.capturePane(
            target: "\(Self.sessionName):\(windowIndex)",
            linesBack: Self.previewLines,
            escapes: true)
        else { return nil }
        return Self.plainPreviewText(from: raw)
    }

    /// Strip trailing padding and ANSI escapes for a monospace preview block.
    static func plainPreviewText(from raw: String) -> String {
        let trimmed = raw.replacingOccurrences(of: "[\r\n]+$", with: "", options: .regularExpression)
        let esc = "\u{1B}"
        let noAnsi = trimmed.replacingOccurrences(
            of: esc + "(?:[@-Z\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression)
        return noAnsi.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
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
