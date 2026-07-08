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
}
