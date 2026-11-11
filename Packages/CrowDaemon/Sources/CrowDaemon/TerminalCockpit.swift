import CrowCore
import CrowTerminal
import Foundation

/// One visible-pane capture for a session-grid cell (CROW-1153). `snapshot` is
/// already framed for xterm.js (home + clear + CRLF), matching `replayFrame`.
struct GridPaneSnapshot: Sendable, Equatable {
    var snapshot: String
    var cols: Int
    var rows: Int
}

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
    /// When set, `snapshotPane` delegates here instead of calling tmux (unit tests).
    private let snapshotCapture: (@Sendable (Int) -> GridPaneSnapshot?)?

    init?(devRoot: String) {
        guard let tmux = Self.resolveTmuxBinary() else { return nil }
        // Match the app's stable socket path (#330) so we share its tmux server
        // and its live session windows rather than spinning up an isolated one.
        let socketPath = Self.appTmuxSocketPath()
        controller = TmuxController(tmuxBinary: tmux, socketPath: socketPath, sessionName: Self.sessionName)
        previewCapture = nil
        snapshotCapture = nil
        ensureSession()
    }

    /// Stub cockpit for handler tests — no tmux server required.
    init(
        previewCapture: @escaping @Sendable (Int) -> String?,
        snapshotCapture: (@Sendable (Int) -> GridPaneSnapshot?)? = nil
    ) {
        controller = TmuxController(
            tmuxBinary: "/bin/false", socketPath: "/dev/null", sessionName: Self.sessionName)
        self.previewCapture = previewCapture
        self.snapshotCapture = snapshotCapture
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

    /// Current window size of a grouped view, for CROW-1162's `if_needed` resize
    /// (skip the PTY ioctl when the window is already the requested size).
    func windowSize(group: String) -> (cols: Int, rows: Int)? {
        guard let raw = try? controller.displayMessage(
            target: group, format: "#{window_width} #{window_height}")
        else { return nil }
        return Self.parseColsRows(raw)
    }

    /// The size a view's PTY should start at, so attaching resizes nothing
    /// (CROW-1403). With no size the PTY is 0×0, which tmux treats as 80×24.
    /// Under `window-size latest` the new client counts as latest as soon as it
    /// attaches, so every attach squeezed the shared agent window to 80×24 on
    /// every surface until the browser sent its real size. A browser that
    /// reconnects while unfocused never sends one (`applyTermFit` is gated on
    /// focus, #667), so the window stayed at 80 columns until the user came
    /// back.
    ///
    /// `window` is the window the browser is about to select. It is selected
    /// first so the attach lands on it, and the PTY takes that window's current
    /// size. Without it, the view's current window is used.
    func attachSize(group: String, window: Int?) -> (rows: UInt16, cols: UInt16)? {
        if let window { selectWindow(group: group, index: window) }
        guard let size = windowSize(group: group) else { return nil }
        return (UInt16(clamping: size.rows), UInt16(clamping: size.cols))
    }

    /// Parse `"cols rows"` from `display-message`. Pure so the skip-ioctl gate
    /// is unit-testable without tmux.
    static func parseColsRows(_ raw: String) -> (cols: Int, rows: Int)? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2,
              let cols = Int(parts[0]), let rows = Int(parts[1]),
              cols > 0, rows > 0
        else { return nil }
        return (cols, rows)
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
        let probe = replayProbe(group: group, index: index)
        if !Self.shouldReplayScrollback(alternateOn: probe.alternateOn) {
            return nil
        }
        guard let raw = try? controller.capturePane(
            target: "\(group):\(index)", linesBack: Self.replayLines, escapes: true)
        else { return nil }
        return Self.replayFrame(from: raw, cursor: probe.cursor)
    }

    /// Where tmux has the pane's cursor, so a replay can leave xterm's caret
    /// where the live attach would (CROW-1403). Zero-based, pane-relative.
    struct ReplayCursor: Equatable {
        let x: Int
        let y: Int
        let visible: Bool
    }

    /// `#{alternate_on}` plus the cursor for `group:index`, in one tmux call.
    /// A failed read reports `alternateOn: false` and no cursor, so it still
    /// takes the CROW-606 replay path (shells / inline agents) rather than
    /// silently dropping history.
    func replayProbe(group: String, index: Int) -> (alternateOn: Bool, cursor: ReplayCursor?) {
        guard let raw = try? controller.displayMessage(
            target: "\(group):\(index)",
            format: "#{alternate_on} #{cursor_x} #{cursor_y} #{cursor_flag}")
        else { return (false, nil) }
        return Self.parseReplayProbe(raw)
    }

    /// Parse `"<alternate_on> <cursor_x> <cursor_y> <cursor_flag>"`. Pure, so the
    /// shape is unit-testable without tmux. A short or malformed read keeps
    /// whatever it could parse: a bad cursor never blocks the replay.
    static func parseReplayProbe(_ raw: String) -> (alternateOn: Bool, cursor: ReplayCursor?) {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        let alternateOn = parts.first == "1"
        guard parts.count >= 4,
              let x = Int(parts[1]), let y = Int(parts[2]),
              x >= 0, y >= 0
        else { return (alternateOn, nil) }
        return (alternateOn, ReplayCursor(x: x, y: y, visible: parts[3] == "1"))
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
    /// (`switchAgentWindow`, CROW-1035) clears the xterm buffer before `select-window`
    /// without a full `term.reset()` (which would also clear `mouseTrackingMode`). tmux emits mouse-mode changes to a
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

    /// ANSI snapshot of a cockpit window's *visible* frame for the session grid
    /// (CROW-1153). Does not attach a PTY — capture-pane is read-only — so a
    /// 16-cell wall cannot SIGWINCH the shared agent window. Best-effort.
    func snapshotPane(windowIndex: Int) -> GridPaneSnapshot? {
        if let snapshotCapture { return snapshotCapture(windowIndex) }
        let target = "\(Self.sessionName):\(windowIndex)"
        guard let raw = try? controller.captureVisiblePane(target: target, escapes: true) else {
            return nil
        }
        let framed = String(data: Self.replayFrame(from: raw), encoding: .utf8) ?? raw
        var cols = 80
        var rows = 24
        if let dim = try? controller.displayMessage(
            target: target, format: "#{pane_width} #{pane_height}"),
           let parsed = Self.parseColsRows(dim)
        {
            cols = min(parsed.cols, 400)
            rows = min(parsed.rows, 200)
        }
        return GridPaneSnapshot(snapshot: framed, cols: cols, rows: rows)
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
    ///   1. drop capture-pane's final line terminator, and only that. Every
    ///      screen row is printed, including the blank rows below the last
    ///      output, and those blanks are real rows. Trimming all trailing
    ///      newlines (as this did until CROW-1403) moved every replayed screen
    ///      row down by the number of blank rows. Every Claude Code pane has one
    ///      under its footer, so the replay painted the screen one row low.
    ///      That is the "one-line stack" CROW-1035 and CROW-1048 reported, and
    ///      the reason in-place agent switches stopped replaying;
    ///   2. convert bare LF → CRLF — `capture-pane` emits `\n` only, and xterm.js
    ///      treats `\n` as line-feed-without-carriage-return, so raw output would
    ///      stair-step down the screen;
    ///   3. prepend `ESC[H ESC[2J ESC[3J` (home + clear screen + clear scrollback)
    ///      so repeated selects/reconnects REBUILD the buffer rather than stack
    ///      duplicate copies of the history;
    ///   4. with a `cursor`, reset SGR and put the caret where tmux has it, with
    ///      tmux's visibility. Without this the caret was left at the end of the
    ///      last replayed row, below the agent's input box, until the agent next
    ///      moved it.
    /// History plus the full screen is `history_size + pane_height` rows, so the
    /// last row lands on xterm's bottom row and every screen row sits where the
    /// live attach paints it. Whichever write wins the race, the screen matches.
    static func replayFrame(from raw: String, cursor: ReplayCursor? = nil) -> Data {
        var lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if lines.hasSuffix("\n") { lines.removeLast() }
        let crlf = lines.replacingOccurrences(of: "\n", with: "\r\n")
        let clear = "\u{1b}[H\u{1b}[2J\u{1b}[3J"
        var frame = clear + crlf
        if let cursor {
            frame += "\u{1b}[0m\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H"
            frame += cursor.visible ? "\u{1b}[?25h" : "\u{1b}[?25l"
        }
        return Data(frame.utf8)
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
