import Foundation
import Testing
@testable import CrowDaemon

/// Swift detectors are the source of truth (CROW-1255). No JS twins.
@Suite struct TuiObservationTests {

    @Test func cursorMismatchXtermVsTmux() {
        let client = sample(xtermX: 2, xtermY: 5)
        let tmux = tmuxSample(cursorX: 10, cursorY: 5)
        let found = TuiDetectors.detect(events: [
            .tmux(t: 10, sample: tmux, agentSurface: true),
            .client(t: 20, sample: client),
        ])
        #expect(found.contains { $0.kind == "cursor_mismatch" && $0.signature == "cursor_mismatch.xterm_vs_tmux" })
    }

    @Test func cursorMismatchXtermVsCss() {
        let client = sample(xtermX: 0, xtermY: 5, caretX: 0, caretY: 5 * 18 + 18)
        let tmux = tmuxSample(cursorX: 0, cursorY: 5)
        let found = TuiDetectors.detect(events: [
            .tmux(t: 10, sample: tmux, agentSurface: true),
            .client(t: 20, sample: client),
        ])
        #expect(found.contains { $0.kind == "cursor_mismatch" && $0.signature == "cursor_mismatch.xterm_vs_css" })
    }

    @Test func viewportMismatchKeyboardNoResize() {
        let found = TuiDetectors.detect(events: [
            .client(t: 0, sample: sample(keyboardInset: 0)),
            .client(t: 100, sample: sample(keyboardInset: 180, innerH: 800, vvH: 500, clientH: 500)),
        ])
        #expect(found.contains { $0.kind == "viewport_mismatch" && $0.signature == "viewport_mismatch.keyboard_no_resize" })
    }

    @Test func viewportMismatchDoesNotFireWhenResizeMatches() {
        let found = TuiDetectors.detect(events: [
            .client(t: 0, sample: sample(keyboardInset: 0)),
            .resize(t: 80, cols: 80, rows: 20, hidden: false, hasFocus: true),
            .client(t: 100, sample: sample(cssRows: 20, keyboardInset: 180)),
        ])
        #expect(!found.contains { $0.kind == "viewport_mismatch" })
    }

    @Test func gridMismatchPersists() {
        let css = sample(cssCols: 80, cssRows: 22)
        let tmux = tmuxSample(cols: 80, rows: 24)
        let found = TuiDetectors.detect(events: [
            .resize(t: 0, cols: 80, rows: 24, hidden: false, hasFocus: true),
            .tmux(t: 10, sample: tmux, agentSurface: true),
            .client(t: 20, sample: css),
            .tmux(t: 130, sample: tmux, agentSurface: true),
            .client(t: 140, sample: css),
        ])
        #expect(found.contains { $0.kind == "grid_mismatch" && $0.signature == "grid_mismatch.pty_tmux_css" })
    }

    @Test func resizeStormBurst() {
        let events: [TuiDetectors.Event] = (0..<5).map {
            .resize(t: $0 * 20, cols: 80, rows: 24 + $0, hidden: false, hasFocus: true)
        }
        let found = TuiDetectors.detect(events: events)
        #expect(found.contains { $0.kind == "resize_storm" && $0.signature == "resize_storm.burst" })
    }

    @Test func resizeStormAfterSelectWindow() {
        let found = TuiDetectors.detect(events: [
            .selectWindow(t: 0, agentSurface: true),
            .resize(t: 50, cols: 80, rows: 24, hidden: false, hasFocus: true),
        ])
        #expect(found.contains { $0.kind == "resize_storm" && $0.signature == "resize_storm.select_window_24x80" })
    }

    @Test func duplicateChromeFromHistoryDump() {
        let marker = "╭─ Claude Code ─╮"
        var lines: [String] = []
        for _ in 0..<3 {
            lines.append(contentsOf: Array(repeating: "....", count: 23))
            lines.append(marker)
        }
        let found = TuiDetectors.detect(events: [
            .dump(t: 10, text: lines.joined(separator: "\n"), ptyRows: 24),
        ])
        #expect(found.contains { $0.kind == "duplicate_chrome" && $0.signature == "duplicate_chrome.repeat_period" })
    }

    @Test func duplicateChromeDoesNotFireFromOneHertzViewport() {
        let marker = "╭─ Claude Code ─╮"
        var lines: [String] = []
        for _ in 0..<3 {
            lines.append(contentsOf: Array(repeating: "....", count: 23))
            lines.append(marker)
        }
        let text = lines.joined(separator: "\n")
        let tmux = tmuxSample()
        var stored = tmux
        stored.viewportText = text
        let found = TuiDetectors.detect(events: [
            .tmux(t: 10, sample: stored, agentSurface: true),
            .client(t: 20, sample: sample()),
        ])
        #expect(!found.contains { $0.kind == "duplicate_chrome" })
    }

    @Test func scrollJump() {
        let found = TuiDetectors.detect(events: [
            .client(t: 0, sample: sample(arrivedAtTop: false, viewportY: 40)),
            .client(t: 50, sample: sample(arrivedAtTop: false, viewportY: 0)),
        ])
        #expect(found.contains { $0.kind == "scroll_jump" && $0.signature == "scroll_jump.viewport_to_zero" })
    }

    @Test func scrollJumpSuppressedWhenArrivedAtTop() {
        let found = TuiDetectors.detect(events: [
            .client(t: 0, sample: sample(arrivedAtTop: false, viewportY: 40)),
            .client(t: 50, sample: sample(arrivedAtTop: true, viewportY: 0)),
        ])
        #expect(!found.contains { $0.kind == "scroll_jump" })
    }

    @Test func scrollNoop() {
        let ev = TuiClientEvent(kind: "touchmove", atClient: 1, preventDefault: true, delta: 3)
        let found = TuiDetectors.detect(events: [
            .client(t: 0, sample: sample(appOwnsScroll: false, visibleHash: "sha256:same")),
            .client(t: 50, sample: sample(appOwnsScroll: false, visibleHash: "sha256:same", events: [ev])),
        ])
        #expect(found.contains { $0.kind == "scroll_noop" && $0.signature == "scroll_noop.unchanged_hash" })
    }

    @Test func cursorBelowInputAfterSwitch() {
        var lines = Array(repeating: "          ", count: 24)
        lines[20] = "> compose here"
        lines[23] = "        "
        let found = TuiDetectors.detect(events: [
            .selectWindow(t: 0, agentSurface: true),
            .client(t: 10, sample: sample(cssRows: 24, xtermY: 0, agentSurface: true)),
            .client(t: 80, sample: sample(
                cssRows: 24, xtermY: 23, agentSurface: true, visibleLines: lines)),
        ])
        #expect(found.contains { $0.kind == "cursor_below_input" && $0.signature == "cursor_below_input.after_switch" })
    }

    @Test func altDisagreement() {
        let found = TuiDetectors.detect(events: [
            .tmux(t: 10, sample: tmuxSample(alternateOn: false, alternateScreen: false), agentSurface: true),
        ])
        #expect(found.contains { $0.kind == "alt_disagreement" && $0.signature == "alt_disagreement.agent_vs_tmux" })
    }

    @Test func bufferHole() {
        let tmux = tmuxSample(historySize: 400)
        let client = sample(cssRows: 24, baseY: 0, agentSurface: false)
        let found = TuiDetectors.detect(events: [
            .output(t: 0),
            .tmux(t: 10, sample: tmux, agentSurface: false),
            .client(t: 20, sample: client),
        ])
        #expect(found.contains { $0.kind == "buffer_hole" && $0.signature == "buffer_hole.basey_vs_history" })
    }

    @Test func focusSteal() {
        let found = TuiDetectors.detect(events: [
            .client(t: 0, sample: sample(hidden: true, hasFocus: false)),
            .resize(t: 50, cols: 80, rows: 24, hidden: true, hasFocus: false),
        ])
        #expect(found.contains { $0.kind == "focus_steal" && $0.signature == "focus_steal.background_resize" })
    }

    @Test func sampleGapJoinWindow() {
        let found = TuiDetectors.detect(events: [
            .tmux(t: 0, sample: tmuxSample(), agentSurface: true),
            .client(t: 400, sample: sample()),
        ])
        #expect(found.contains { $0.kind == "sample_gap" && $0.signature == "sample_gap.join_window" })
    }

    @Test func scrollOwnershipTruthTable() {
        let found = TuiDetectors.detect(events: [
            .client(t: 0, sample: sample(agentSurface: false, mouseTracking: "all", appOwnsScroll: true)),
            .client(t: 50, sample: sample(agentSurface: false, mouseTracking: "all", appOwnsScroll: true)),
        ])
        #expect(found.contains { $0.kind == "scroll_ownership" && $0.signature == "scroll_ownership.truth_table" })
    }

    @Test func scanComposeMarkerFindsBoxAndPrompt() {
        #expect(TuiDetectors.scanComposeMarker(lines: ["hello", "╭────╮", "    "], from: 2))
        #expect(TuiDetectors.scanComposeMarker(lines: ["  > ask", "    "], from: 1))
        #expect(!TuiDetectors.scanComposeMarker(lines: ["plain", "text"], from: 1))
    }
}

private func sample(
    formFactor: String = "phone",
    hidden: Bool = false,
    hasFocus: Bool = true,
    arrivedAtTop: Bool = false,
    cssCols: Int = 80,
    cssRows: Int = 24,
    keyboardInset: Int = 0,
    innerH: Int = 800,
    vvH: Int? = 800,
    clientH: Int = 600,
    xtermX: Int = 0,
    xtermY: Int = 0,
    viewportY: Int = 10,
    baseY: Int = 0,
    caretX: Double? = nil,
    caretY: Double? = nil,
    agentSurface: Bool = true,
    mouseTracking: String = "none",
    appOwnsScroll: Bool = false,
    visibleHash: String = "sha256:aaa",
    visibleLines: [String]? = nil,
    events: [TuiClientEvent] = []
) -> TuiClientSample {
    let cellW = 9.0
    let cellH = 18.0
    return TuiClientSample(
        tClient: 0,
        formFactor: formFactor,
        hidden: hidden,
        hasFocus: hasFocus,
        arrivedAtTop: arrivedAtTop,
        env: TuiClientEnv(
            ua: "test", tauri: false, dpr: 1, maxTouchPoints: 5,
            pointerCoarse: true, webgl: true, locale: "en"),
        viewport: TuiClientViewport(
            innerW: 390, innerH: innerH, clientW: 390, clientH: clientH,
            vvW: 390, vvH: vvH, vvOffsetTop: 0, vvOffsetLeft: 0,
            keyboardInsetPx: keyboardInset, cssCols: cssCols, cssRows: cssRows,
            cellW: cellW, cellH: cellH),
        cursor: TuiClientCursor(
            xtermX: xtermX, xtermY: xtermY,
            xtermViewportY: viewportY, xtermBaseY: baseY,
            textareaLeftPx: Double(xtermX) * cellW,
            textareaTopPx: Double(xtermY) * cellH,
            caretCssX: caretX ?? Double(xtermX) * cellW,
            caretCssY: caretY ?? Double(xtermY) * cellH),
        modes: TuiClientModes(
            agentSurface: agentSurface, bufferType: agentSurface ? "alternate" : "normal",
            mouseTracking: mouseTracking, appOwnsScroll: appOwnsScroll,
            altScreenFlag: agentSurface),
        visibleHash: visibleHash,
        visibleRows: cssRows,
        events: events,
        visibleLines: visibleLines)
}

private func tmuxSample(
    cols: Int = 80,
    rows: Int = 24,
    cursorX: Int = 0,
    cursorY: Int = 0,
    alternateOn: Bool = true,
    alternateScreen: Bool = true,
    historySize: Int = 0
) -> TuiTmuxSample {
    TuiTmuxSample(
        t: 0, cols: cols, rows: rows, cursorX: cursorX, cursorY: cursorY,
        alternateOn: alternateOn, alternateScreen: alternateScreen,
        paneInMode: false, historySize: historySize, historyLimit: 50_000,
        viewportHash: "sha256:tmux", viewportText: nil)
}
