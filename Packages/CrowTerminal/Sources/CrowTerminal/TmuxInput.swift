import CrowCore
import Foundation

/// Paste / search / prompt-nav / select-all / clear-history / cwd.
///
/// Extracted from `TmuxBackend` (CROW-1222). Paste-Enter settle delay and
/// copy-mode cancel stay exactly as they were — this is a structural split,
/// not a timing or tmux-option change.

extension TmuxBackend {
    /// Settle time between `paste-buffer` and the submitting `Enter`.
    ///
    /// Bracketed-paste TUIs (Claude Code, Cursor's `agent`) need the
    /// `\e[201~` bracket-end to finish before Enter arrives. 50ms was enough
    /// for short Claude auto-respond lines (#272) but large Cursor pastes
    /// (multi-KB Manager / job prompts) still race: the agent starts working
    /// while sticky text remains in the composer, looking like a double paste
    /// (#631). 200ms clears the composer for those payloads without a second
    /// Enter (which would re-submit leftover text).
    public static let pasteEnterSettleDelay: TimeInterval = 0.2

    /// Send text to `id`'s window via the buffer-paste path. Works for
    /// arbitrary-size payloads (Phase 3 §3 finding: send-keys -l fails
    /// on >10KB; load-buffer + paste-buffer scales to 50KB+ in 133ms).
    ///
    /// Quirk: agent TUIs enable bracketed-paste mode, which wraps
    /// `paste-buffer` output in `\e[200~…\e[201~`. A trailing `\n` inside the
    /// bracket is treated as literal text, not as Enter — so prompts that
    /// rely on `\n` to submit (quick actions, auto-respond) get pasted but
    /// never submitted (#264). Strip the trailing newline before pasting and
    /// deliver a separate `Enter` via `send-keys` afterwards.
    ///
    /// `pasteEnterSettleDelay` between the paste and the Enter keystroke
    /// gives the TUI time to process the bracket-end sequence (`\e[201~`).
    /// Without this, Enter can arrive early: Claude may drop it entirely
    /// (#272); Cursor may submit but leave the prompt sitting in the input
    /// box (#631).
    ///
    /// We also pre-cancel copy-mode on the pane before any delivery (#486).
    /// The bundled `crow-tmux.conf` keeps `mouse on` so wheel scrollback
    /// works (#452), but the default `WheelUpPane` puts the pane into
    /// copy-mode, where both `paste-buffer` and `send-keys Enter` are
    /// silently consumed by copy-mode key bindings instead of reaching the
    /// underlying shell. Without the cancel, every programmatic send into
    /// a pane the user has scrolled (Manager paste, auto-respond, quick
    /// actions, bare-Enter submits) is dropped.
    public func sendText(id: UUID, text: String) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            let endsWithNewline = text.hasSuffix("\n")
            let payload = endsWithNewline ? String(text.dropLast()) : text

            // Cancel copy-mode if the user scrolled the pane into it before
            // we deliver anything. Covers both the paste-buffer path (which
            // is a no-op in copy-mode) and the bare-Enter path (where
            // `send-keys Enter` would otherwise hit the copy-mode key table
            // — default emacs `copy-selection-and-cancel`, vi `cancel` —
            // exiting copy-mode without delivering a CR to the shell (#486).
            try ctrl.cancelCopyModeIfActive(target: target)

            var didPaste = false
            if !payload.isEmpty {
                let bufferName = "crow-\(id.uuidString)"
                try ctrl.loadBufferFromStdin(name: bufferName, data: Data(payload.utf8))
                defer { ctrl.deleteBuffer(name: bufferName) }
                try ctrl.pasteBuffer(name: bufferName, target: target)
                didPaste = true
            }
            if endsWithNewline {
                // Give the TUI time to process the paste bracket-end before
                // the Enter key arrives. Only needed when we actually pasted
                // content — a bare "\n" (Enter-only) needs no delay.
                if didPaste {
                    Thread.sleep(forTimeInterval: Self.pasteEnterSettleDelay)
                }
                try ctrl.sendKeys(target: target, keys: ["Enter"])
            }
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Drop the scrollback buffer for terminal `id` via `tmux clear-history`.
    /// On-screen rows survive — only the off-screen history is wiped — matching
    /// what macOS Terminal "Clear" and iTerm2 "Clear Buffer" do. Surfaced from
    /// the terminal context menu.
    public func clearHistory(id: UUID) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            _ = try ctrl.run(["clear-history", "-t", target])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Enter tmux copy-mode and select the entire scrollback for terminal
    /// `id` — the "Select All" equivalent for a terminal pane. Surfaced from
    /// the terminal context menu. After this, Copy
    /// (or Cmd+C) writes the captured text to the macOS pasteboard via the
    /// existing `copy-pipe-no-clear` binding.
    public func selectAll(id: UUID) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            // -H makes copy-mode enter without scrolling the screen first.
            _ = try ctrl.run(["copy-mode", "-H", "-t", target])
            try ctrl.sendKeys(target: target, keys: ["-X", "history-top"])
            try ctrl.sendKeys(target: target, keys: ["-X", "begin-selection"])
            try ctrl.sendKeys(target: target, keys: ["-X", "history-bottom"])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Read the live working directory of terminal `id`'s pane via
    /// `tmux display-message -p -F '#{pane_current_path}'`. Used by
    /// smart-detect `path:line` resolution (#471 gap 5) to honour the
    /// pane's *current* cwd rather than the cockpit surface's static
    /// `workingDirectory` (which is fixed to `$HOME` at create time and
    /// never tracks the shell's `cd`s). Returns nil on any error so the
    /// caller can fall back without crashing.
    public func activePaneCwd(id: UUID) -> String? {
        guard let windowIndex = bindings[id] else { return nil }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            let raw = try ctrl.displayMessage(target: target, format: "#{pane_current_path}")
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            reportIfTimeout(error)
            return nil
        }
    }

    /// Direction for `searchInScrollback`. `backward` walks toward older
    /// output (the common case for Cmd+F on terminal history); `forward`
    /// walks toward newer output.
    public enum SearchDirection {
        case backward
        case forward
    }

    /// Enter tmux copy-mode and start a search for `query` in the
    /// scrollback of terminal `id` (#471 gap 2). Powers the Cmd+F search
    /// affordance. `tmux send-keys -X search-backward "<query>"` jumps the
    /// copy-mode cursor to the most recent match; subsequent calls to
    /// `searchAgain` step through additional matches without re-running
    /// the search. The pane stays in copy-mode until the caller invokes
    /// `exitCopyMode` (or the user hits ESC).
    public func searchInScrollback(
        id: UUID,
        query: String,
        direction: SearchDirection
    ) throws {
        guard !query.isEmpty else { return }
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            _ = try ctrl.run(["copy-mode", "-H", "-t", target])
            let command = direction == .backward ? "search-backward" : "search-forward"
            try ctrl.sendKeys(target: target, keys: ["-X", command, query])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Step to the next/previous match for the active search in terminal
    /// `id`'s copy-mode (#471 gap 2). Maps to `search-again` /
    /// `search-reverse` per tmux's own conventions.
    public func searchAgain(id: UUID, reverse: Bool) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            let command = reverse ? "search-reverse" : "search-again"
            try ctrl.sendKeys(target: target, keys: ["-X", command])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Leave copy-mode in terminal `id`, restoring normal shell input.
    /// Used by the search bar's Done button (#471 gap 2) and by callers
    /// that want to abandon a prompt-jump (#471 gap 6).
    public func exitCopyMode(id: UUID) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            try ctrl.sendKeys(target: target, keys: ["-X", "cancel"])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }

    /// Jump the copy-mode cursor to the previous OSC 133;A prompt-start
    /// marker in terminal `id` (#471 gap 6). Requires the shell wrapper
    /// to emit a non-passthrough OSC 133;A so tmux's emulator sees it.
    /// Enters copy-mode if not already there.
    public func previousPrompt(id: UUID) throws {
        try sendPromptNav(id: id, command: "previous-prompt")
    }

    /// Sibling of `previousPrompt`. Steps forward through OSC 133;A marks.
    public func nextPrompt(id: UUID) throws {
        try sendPromptNav(id: id, command: "next-prompt")
    }

    private func sendPromptNav(id: UUID, command: String) throws {
        guard let windowIndex = bindings[id] else {
            throw TmuxBackendError.unknownTerminal(id)
        }
        do {
            let ctrl = try ensureRunningServer()
            let target = "\(ctrl.sessionName):\(windowIndex)"
            _ = try ctrl.run(["copy-mode", "-H", "-t", target])
            try ctrl.sendKeys(target: target, keys: ["-X", command])
        } catch {
            reportIfTimeout(error)
            throw error
        }
    }
}
