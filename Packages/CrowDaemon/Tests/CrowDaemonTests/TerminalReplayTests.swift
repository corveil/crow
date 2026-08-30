import Foundation
import Testing
@testable import CrowDaemon

/// `TerminalCockpit.replayFrame` massages a `capture-pane -pe` blob into a
/// self-contained frame that rebuilds a reconnecting xterm.js buffer (CROW-606).
/// Pure transform — no tmux — so its shape is asserted directly here.
@Suite struct TerminalReplayTests {
    /// Every frame must lead with the clear so repeated selects/reconnects
    /// REBUILD the scrollback rather than stack duplicate copies of history.
    private static let clearPrefix = "\u{1b}[H\u{1b}[2J\u{1b}[3J"

    @Test func prependsClearAndConvertsLineEndings() {
        let data = TerminalCockpit.replayFrame(from: "line1\nline2\nline3")
        let s = String(decoding: data, as: UTF8.self)
        #expect(s == Self.clearPrefix + "line1\r\nline2\r\nline3")
    }

    @Test func stripsTrailingNewlinesToAvoidRowOffset() {
        // capture-pane pads a trailing LF; keeping it would push the viewport
        // one row below where tmux's live redraw repaints.
        let data = TerminalCockpit.replayFrame(from: "only\n\n")
        #expect(String(decoding: data, as: UTF8.self) == Self.clearPrefix + "only")
    }

    @Test func preservesInteriorBlankLinesAndEscapes() {
        // Interior blanks are real history rows; SGR escapes (from `-e`) pass
        // through untouched.
        let raw = "a\n\n\u{1b}[31mred\u{1b}[0m\n"
        let data = TerminalCockpit.replayFrame(from: raw)
        #expect(String(decoding: data, as: UTF8.self)
            == Self.clearPrefix + "a\r\n\r\n\u{1b}[31mred\u{1b}[0m")
    }

    @Test func idempotentOnAlreadyCRLFInput() {
        // Guards against double-CR if a capture ever arrives with CRLF.
        let data = TerminalCockpit.replayFrame(from: "x\r\ny")
        #expect(String(decoding: data, as: UTF8.self) == Self.clearPrefix + "x\r\ny")
    }

    @Test func emptyCaptureIsJustTheClear() {
        let data = TerminalCockpit.replayFrame(from: "")
        #expect(String(decoding: data, as: UTF8.self) == Self.clearPrefix)
    }

    /// CROW-1035: an alt-buffer pane's live attach already paints the current
    /// frame. Replaying the capture on top is what parks the caret below the
    /// input box. Shells and inline agents (alternate_on=0) still replay.
    @Test func altBufferPaneSkipsScrollbackReplay() {
        #expect(TerminalCockpit.shouldReplayScrollback(alternateOn: true) == false)
        #expect(TerminalCockpit.shouldReplayScrollback(alternateOn: false) == true)
    }

    /// CROW-1043: `select-window` re-arms the pane's mouse-tracking mode so the
    /// in-place agent switch's `term.reset()` can't strand the forwarded wheel.
    /// `flags` is `#{mouse_standard_flag}#{mouse_button_flag}#{mouse_any_flag}`
    /// `#{mouse_utf8_flag}#{mouse_sgr_flag}`.
    @Test func mouseModeReArmBuildsDecsetEnablesFromFlags() {
        // A real Claude Code / Manager pane: any-event tracking + SGR encoding.
        #expect(TerminalCockpit.mouseModeReArmSequence(flags: "00101")
            == "\u{1b}[?1003h\u{1b}[?1006h")
        // Standard tracking + SGR.
        #expect(TerminalCockpit.mouseModeReArmSequence(flags: "10001")
            == "\u{1b}[?1000h\u{1b}[?1006h")
        // Every mode set, in canonical order.
        #expect(TerminalCockpit.mouseModeReArmSequence(flags: "11111")
            == "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1005h\u{1b}[?1006h")
    }

    /// No active mouse mode (a shell, or an agent idling without tracking) → no
    /// sequence, so the client keeps its local-viewport scroll rather than being
    /// forced to forward a wheel nothing is listening for.
    @Test func mouseModeReArmIsNilWhenNoModeActive() {
        #expect(TerminalCockpit.mouseModeReArmSequence(flags: "00000") == nil)
    }

    /// A failed read / an older tmux that can't answer these flags must yield nil
    /// rather than a truncated, malformed DECSET.
    @Test func mouseModeReArmRejectsMalformedFlagStrings() {
        #expect(TerminalCockpit.mouseModeReArmSequence(flags: "") == nil)
        #expect(TerminalCockpit.mouseModeReArmSequence(flags: "1") == nil)
        #expect(TerminalCockpit.mouseModeReArmSequence(flags: "001010") == nil)
    }

    @Test func plainPreviewTextStripsAnsiAndTrailingNewlines() {
        let text = TerminalCockpit.plainPreviewText(from: "line1\n\u{1b}[31mred\u{1b}[0m\n\n")
        #expect(text == "line1\nred")
    }

    /// CROW-1162: `if_needed` resize skips the PTY ioctl when the window is
    /// already this size. Parsing is the gate; garbage / zeros must not skip.
    @Test func parseColsRowsAcceptsPositivePairs() {
        #expect(TerminalCockpit.parseColsRows("120 40").map { [$0.cols, $0.rows] } == [120, 40])
        #expect(TerminalCockpit.parseColsRows("  80\t24\n").map { [$0.cols, $0.rows] } == [80, 24])
    }

    @Test func parseColsRowsRejectsGarbage() {
        #expect(TerminalCockpit.parseColsRows("") == nil)
        #expect(TerminalCockpit.parseColsRows("120") == nil)
        #expect(TerminalCockpit.parseColsRows("0 40") == nil)
        #expect(TerminalCockpit.parseColsRows("-1 24") == nil)
        #expect(TerminalCockpit.parseColsRows("wide tall") == nil)
    }
}
