import Foundation

/// Pure detectors over a structured event log. Swift tests are the source of
/// truth; there are no JS detector twins (CROW-1255).
enum TuiDetectors {

    enum Event: Equatable {
        case resize(t: Int, cols: Int, rows: Int, hidden: Bool?, hasFocus: Bool?)
        case selectWindow(t: Int, agentSurface: Bool)
        case tmux(t: Int, sample: TuiTmuxSample, agentSurface: Bool)
        case client(t: Int, sample: TuiClientSample)
        case dump(t: Int, text: String, ptyRows: Int)
        case output(t: Int)
    }

    static func detect(
        events: [Event],
        sessionID: UUID? = nil,
        terminalID: UUID? = nil
    ) -> [TuiObservation] {
        var observations: [TuiObservation] = []
        var lastResizes: [(t: Int, cols: Int, rows: Int)] = []
        var lastResizeT: Int?
        var lastSelect: (t: Int, agent: Bool)?
        var lastTmux: (t: Int, sample: TuiTmuxSample, agent: Bool)?
        var lastClient: (t: Int, sample: TuiClientSample)?
        var lastJoinMismatchT: Int?
        var lastPtySize: (cols: Int, rows: Int)?
        var hadOutput = false
        var lastSampleHadFocus: (t: Int, hidden: Bool, hasFocus: Bool)?

        for event in events {
            switch event {
            case .output:
                hadOutput = true

            case .resize(let t, let cols, let rows, let hidden, let hasFocus):
                lastResizes.append((t, cols, rows))
                lastResizes = lastResizes.filter { t - $0.t <= 200 }
                lastResizeT = t
                lastPtySize = (cols, rows)
                if lastResizes.count >= 5 {
                    observations.append(obs(
                        t: t, kind: "resize_storm", severity: "red",
                        signature: "resize_storm.burst",
                        sessionID: sessionID, terminalID: terminalID,
                        formFactor: lastClient?.sample.formFactor,
                        facts: ["count": .int(lastResizes.count), "window_ms": .int(200)]))
                }
                if let sel = lastSelect, t - sel.t <= 200, sel.agent, cols == 80, rows == 24 {
                    observations.append(obs(
                        t: t, kind: "resize_storm", severity: "red",
                        signature: "resize_storm.select_window_24x80",
                        sessionID: sessionID, terminalID: terminalID,
                        formFactor: lastClient?.sample.formFactor,
                        facts: ["cols": .int(cols), "rows": .int(rows)]))
                }
                let focus = lastSampleHadFocus
                if let focus, t - focus.t <= 1000, focus.hidden || !focus.hasFocus {
                    observations.append(obs(
                        t: t, kind: "focus_steal", severity: "red",
                        signature: "focus_steal.background_resize",
                        sessionID: sessionID, terminalID: terminalID,
                        formFactor: lastClient?.sample.formFactor,
                        facts: ["hidden": .bool(focus.hidden), "has_focus": .bool(focus.hasFocus)]))
                }
                if let hidden, let hasFocus {
                    lastSampleHadFocus = (t, hidden, hasFocus)
                }

            case .selectWindow(let t, let agent):
                lastSelect = (t, agent)

            case .tmux(let t, let sample, let agent):
                lastTmux = (t, sample, agent)
                if agent != sample.alternateScreen || (agent && !sample.alternateOn && sample.alternateScreen) {
                    // agent_surface vs tmux #{alternate-screen} vs #{alternate_on}
                    let disagree = agent != sample.alternateScreen
                        || (sample.alternateScreen != sample.alternateOn)
                    if disagree {
                        observations.append(obs(
                            t: t, kind: "alt_disagreement", severity: "yellow",
                            signature: "alt_disagreement.agent_vs_tmux",
                            sessionID: sessionID, terminalID: terminalID,
                            formFactor: lastClient?.sample.formFactor,
                            facts: [
                                "agent_surface": .bool(agent),
                                "alternate_screen": .bool(sample.alternateScreen),
                                "alternate_on": .bool(sample.alternateOn),
                            ]))
                    }
                }
                if let client = lastClient {
                    let dt = abs(t - client.t)
                    if dt > TuiLimits.joinWindowMs {
                        observations.append(obs(
                            t: t, kind: "sample_gap", severity: "yellow",
                            signature: "sample_gap.join_window",
                            sessionID: sessionID, terminalID: terminalID,
                            formFactor: client.sample.formFactor,
                            facts: ["delta_ms": .int(dt)]))
                    } else {
                        appendJoined(
                            t: max(t, client.t),
                            tmux: sample,
                            client: client.sample,
                            pty: lastPtySize,
                            lastMismatchT: &lastJoinMismatchT,
                            hadOutput: hadOutput,
                            lastSelect: lastSelect,
                            sessionID: sessionID,
                            terminalID: terminalID,
                            into: &observations)
                    }
                }

            case .client(let t, let sample):
                if let prev = lastClient {
                    appendClientPair(
                        prevT: prev.t, prev: prev.sample,
                        t: t, sample: sample,
                        lastSelect: lastSelect,
                        lastPty: lastPtySize,
                        lastTmux: lastTmux,
                        lastResizeT: lastResizeT,
                        sessionID: sessionID,
                        terminalID: terminalID,
                        into: &observations)
                }
                lastClient = (t, sample)
                lastSampleHadFocus = (t, sample.hidden, sample.hasFocus)
                if let tmux = lastTmux {
                    let dt = abs(t - tmux.t)
                    if dt > TuiLimits.joinWindowMs {
                        observations.append(obs(
                            t: t, kind: "sample_gap", severity: "yellow",
                            signature: "sample_gap.join_window",
                            sessionID: sessionID, terminalID: terminalID,
                            formFactor: sample.formFactor,
                            facts: ["delta_ms": .int(dt)]))
                    } else {
                        appendJoined(
                            t: max(t, tmux.t),
                            tmux: tmux.sample,
                            client: sample,
                            pty: lastPtySize,
                            lastMismatchT: &lastJoinMismatchT,
                            hadOutput: hadOutput,
                            lastSelect: lastSelect,
                            sessionID: sessionID,
                            terminalID: terminalID,
                            into: &observations)
                    }
                }

            case .dump(let t, let text, let ptyRows):
                if let chrome = duplicateChrome(text: text, ptyRows: ptyRows) {
                    observations.append(obs(
                        t: t, kind: "duplicate_chrome", severity: "red",
                        signature: "duplicate_chrome.repeat_period",
                        sessionID: sessionID, terminalID: terminalID,
                        formFactor: lastClient?.sample.formFactor,
                        facts: [
                            "marker": .string(chrome.marker),
                            "period": .int(chrome.period),
                            "copies": .int(chrome.copies),
                        ]))
                }
            }
        }
        return observations
    }

    // MARK: - Joined (tmux + client)

    private static func appendJoined(
        t: Int,
        tmux: TuiTmuxSample,
        client: TuiClientSample,
        pty: (cols: Int, rows: Int)?,
        lastMismatchT: inout Int?,
        hadOutput: Bool,
        lastSelect: (t: Int, agent: Bool)?,
        sessionID: UUID?,
        terminalID: UUID?,
        into observations: inout [TuiObservation]
    ) {
        let cssCols = client.viewport.cssCols
        let cssRows = client.viewport.cssRows
        let ptyCols = pty?.cols ?? tmux.cols
        let ptyRows = pty?.rows ?? tmux.rows
        let gridMismatch = ptyCols != tmux.cols || ptyRows != tmux.rows
            || cssCols != tmux.cols || cssRows != tmux.rows
            || cssCols != ptyCols || cssRows != ptyRows
        if gridMismatch {
            if let prev = lastMismatchT, t - prev >= 100 {
                observations.append(obs(
                    t: t, kind: "grid_mismatch", severity: "red",
                    signature: "grid_mismatch.pty_tmux_css",
                    sessionID: sessionID, terminalID: terminalID,
                    formFactor: client.formFactor,
                    facts: [
                        "pty": .object(["cols": .int(ptyCols), "rows": .int(ptyRows)]),
                        "tmux": .object(["cols": .int(tmux.cols), "rows": .int(tmux.rows)]),
                        "css": .object(["cols": .int(cssCols), "rows": .int(cssRows)]),
                    ]))
            }
            lastMismatchT = t
        } else {
            lastMismatchT = nil
        }

        let cellW = max(client.viewport.cellW, 1)
        let cellH = max(client.viewport.cellH, 1)
        let xtermCssX = Double(client.cursor.xtermX) * cellW
        let xtermCssY = Double(client.cursor.xtermY) * cellH
        let caretDeltaX = abs(xtermCssX - client.cursor.caretCssX) / cellW
        let caretDeltaY = abs(xtermCssY - client.cursor.caretCssY) / cellH
        let textareaDeltaX = abs(client.cursor.textareaLeftPx - client.cursor.caretCssX) / cellW
        let textareaDeltaY = abs(client.cursor.textareaTopPx - client.cursor.caretCssY) / cellH
        let tmuxDeltaX = abs(client.cursor.xtermX - tmux.cursorX)
        let tmuxDeltaY = abs(client.cursor.xtermY - tmux.cursorY)
        if caretDeltaX >= 0.5 || caretDeltaY >= 0.5
            || textareaDeltaX >= 0.5 || textareaDeltaY >= 0.5
            || tmuxDeltaX >= 1 || tmuxDeltaY >= 1 {
            let sig = (caretDeltaY >= 0.5 || caretDeltaX >= 0.5)
                ? "cursor_mismatch.xterm_vs_css"
                : (tmuxDeltaX >= 1 || tmuxDeltaY >= 1)
                    ? "cursor_mismatch.xterm_vs_tmux"
                    : "cursor_mismatch.textarea_vs_css"
            observations.append(obs(
                t: t, kind: "cursor_mismatch", severity: "red",
                signature: sig,
                sessionID: sessionID, terminalID: terminalID,
                formFactor: client.formFactor,
                facts: [
                    "xterm": .object(["row": .int(client.cursor.xtermY), "col": .int(client.cursor.xtermX)]),
                    "tmux": .object(["row": .int(tmux.cursorY), "col": .int(tmux.cursorX)]),
                    "delta_cells": .object(["row": .double(caretDeltaY), "col": .double(caretDeltaX)]),
                    "keyboard_inset_px": .int(client.viewport.keyboardInsetPx),
                    "vv_offset_top": .int(client.viewport.vvOffsetTop ?? 0),
                ]))
        }

        if !client.modes.agentSurface, hadOutput,
           tmux.historySize >= 200 {
            let xtermLines = client.cursor.xtermBaseY + client.viewport.cssRows
            let ratio = Double(xtermLines) / Double(max(tmux.historySize, 1))
            if ratio < 0.25 {
                observations.append(obs(
                    t: t, kind: "buffer_hole", severity: "yellow",
                    signature: "buffer_hole.basey_vs_history",
                    sessionID: sessionID, terminalID: terminalID,
                    formFactor: client.formFactor,
                    facts: [
                        "xterm_base_y": .int(client.cursor.xtermBaseY),
                        "history_size": .int(tmux.historySize),
                        "ratio": .double(ratio),
                    ]))
            }
        }
    }

    private static func appendClientPair(
        prevT: Int,
        prev: TuiClientSample,
        t: Int,
        sample: TuiClientSample,
        lastSelect: (t: Int, agent: Bool)?,
        lastPty: (cols: Int, rows: Int)?,
        lastTmux: (t: Int, sample: TuiTmuxSample, agent: Bool)?,
        lastResizeT: Int?,
        sessionID: UUID?,
        terminalID: UUID?,
        into observations: inout [TuiObservation]
    ) {
        if sample.cursor.xtermViewportY == 0 && prev.cursor.xtermViewportY != 0
            && !sample.arrivedAtTop {
            observations.append(obs(
                t: t, kind: "scroll_jump", severity: "red",
                signature: "scroll_jump.viewport_to_zero",
                sessionID: sessionID, terminalID: terminalID,
                formFactor: sample.formFactor,
                facts: [
                    "from": .int(prev.cursor.xtermViewportY),
                    "to": .int(sample.cursor.xtermViewportY),
                    "arrived_at_top": .bool(sample.arrivedAtTop),
                ]))
        }

        let scrollEvents = sample.events.filter {
            ($0.kind == "touchmove" || $0.kind == "wheel") && ($0.delta ?? 0) != 0
        }
        if !scrollEvents.isEmpty, !sample.modes.appOwnsScroll,
           sample.visibleHash == prev.visibleHash {
            observations.append(obs(
                t: t, kind: "scroll_noop", severity: "yellow",
                signature: "scroll_noop.unchanged_hash",
                sessionID: sessionID, terminalID: terminalID,
                formFactor: sample.formFactor,
                facts: [
                    "delta": .int(scrollEvents.first?.delta ?? 0),
                    "prevent_default": .bool(scrollEvents.first?.preventDefault ?? false),
                ]))
        }

        // ADR-0013 / #850: agent_surface && mouse_tracking → appOwnsScroll;
        // a plain shell never owns scroll just because mouse-tracking was left on.
        let mouse = sample.modes.mouseTracking != "none"
        let expectedOwns = sample.modes.agentSurface && mouse
        if sample.modes.appOwnsScroll != expectedOwns {
            observations.append(obs(
                t: t, kind: "scroll_ownership", severity: "yellow",
                signature: "scroll_ownership.truth_table",
                sessionID: sessionID, terminalID: terminalID,
                formFactor: sample.formFactor,
                facts: [
                    "app_owns_scroll": .bool(sample.modes.appOwnsScroll),
                    "agent_surface": .bool(sample.modes.agentSurface),
                    "mouse_tracking": .string(sample.modes.mouseTracking),
                ]))
        }

        let inset = sample.viewport.keyboardInsetPx
        let resizeIsRecent = lastResizeT.map { t - $0 <= TuiLimits.joinWindowMs } ?? false
        if inset >= TuiLimits.keyboardMinOcclusionPx, !resizeIsRecent {
            observations.append(obs(
                t: t, kind: "viewport_mismatch", severity: "red",
                signature: "viewport_mismatch.keyboard_no_resize",
                sessionID: sessionID, terminalID: terminalID,
                formFactor: sample.formFactor,
                facts: [
                    "keyboard_inset_px": .int(inset),
                    "inner_h": .int(sample.viewport.innerH),
                    "vv_h": .int(sample.viewport.vvH ?? 0),
                    "client_h": .int(sample.viewport.clientH),
                ]))
        }

        let rows = sample.viewport.cssRows
        let agent = sample.modes.agentSurface
        let trigger: Bool = {
            if let sel = lastSelect, t - sel.t <= 500, sel.agent { return true }
            if let pty = lastPty, pty.cols == 80, pty.rows == 24 { return true }
            return false
        }()
        if agent, trigger, sample.cursor.xtermY >= rows - 1, rows > 0 {
            let lines = sample.visibleLines ?? []
            let cursorRow = sample.cursor.xtermY
            let cursorEmpty = cursorRow < lines.count
                ? lines[cursorRow].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                : true
            if cursorEmpty, scanComposeMarker(lines: lines, from: cursorRow) {
                observations.append(obs(
                    t: t, kind: "cursor_below_input", severity: "red",
                    signature: "cursor_below_input.after_switch",
                    sessionID: sessionID, terminalID: terminalID,
                    formFactor: sample.formFactor,
                    facts: [
                        "cursor_y": .int(sample.cursor.xtermY),
                        "rows": .int(rows),
                    ]))
            }
        }
    }

    /// Scan up ≤6 visible rows for a box-drawing codepoint or a leading `>`.
    static func scanComposeMarker(lines: [String], from cursorRow: Int) -> Bool {
        let start = max(0, cursorRow - 6)
        let end = min(lines.count, cursorRow)
        guard start < end else { return false }
        for i in start..<end {
            let line = lines[i]
            if line.contains(where: { ch in
                guard let v = ch.unicodeScalars.first?.value else { return false }
                return (0x2500...0x257F).contains(v)
            }) { return true }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") { return true }
        }
        return false
    }

    /// Same ≥8-char marker repeating every `ptyRows` (±1) lines, ≥3 copies.
    /// Reads a **history dump**, never the 1 Hz viewport capture.
    static func duplicateChrome(text: String, ptyRows: Int) -> (marker: String, period: Int, copies: Int)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard ptyRows > 0, lines.count >= ptyRows * 2 else { return nil }
        let viewport = Array(lines.suffix(ptyRows))
        guard let markerLine = viewport.last(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8
        }) else { return nil }
        let marker = markerLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker.count >= 8 else { return nil }
        var copies = 0
        for (i, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == marker {
                copies += 1
                _ = i
            }
        }
        // Period: distance between copies should be ptyRows ± 1.
        var indexes: [Int] = []
        for (i, line) in lines.enumerated() where line.trimmingCharacters(in: .whitespacesAndNewlines) == marker {
            indexes.append(i)
        }
        guard copies >= 3, indexes.count >= 3 else { return nil }
        let periods = zip(indexes, indexes.dropFirst()).map { $1 - $0 }
        guard periods.contains(where: { abs($0 - ptyRows) <= 1 }) else { return nil }
        return (marker, periods.first { abs($0 - ptyRows) <= 1 } ?? ptyRows, copies)
    }

    static func report(
        recordingID: UUID,
        status: TuiRecordingStatus,
        ptySource: TuiPtySource,
        clientSamples: Bool,
        formFactor: String?,
        durationMs: Int,
        bytes: Int,
        observations: [TuiObservation]
    ) -> TuiReport {
        var counts: [String: Int] = [:]
        var signatures: [String] = []
        var firstRed: TuiFirstRed?
        for o in observations {
            counts[o.kind, default: 0] += 1
            if !signatures.contains(o.signature) { signatures.append(o.signature) }
            if firstRed == nil, o.severity == "red" {
                firstRed = TuiFirstRed(t: o.t, kind: o.kind, signature: o.signature)
            }
        }
        if ptySource == .none {
            counts["pty_source_none", default: 0] += 1
            if !signatures.contains("pty_source.none") { signatures.append("pty_source.none") }
        }
        if !clientSamples {
            counts["client_samples_false", default: 0] += 1
            if !signatures.contains("client_samples.false") { signatures.append("client_samples.false") }
        }
        return TuiReport(
            recordingID: recordingID,
            status: status,
            ptySource: ptySource,
            clientSamples: clientSamples,
            formFactor: formFactor,
            durationMs: durationMs,
            bytes: bytes,
            counts: counts,
            firstRed: firstRed,
            signatures: signatures)
    }

    private static func obs(
        t: Int, kind: String, severity: String, signature: String,
        sessionID: UUID?, terminalID: UUID?, formFactor: String?,
        facts: [String: TuiFact]
    ) -> TuiObservation {
        TuiObservation(
            t: t, kind: kind, severity: severity, formFactor: formFactor,
            sessionID: sessionID, terminalID: terminalID,
            signature: signature, facts: facts)
    }
}
