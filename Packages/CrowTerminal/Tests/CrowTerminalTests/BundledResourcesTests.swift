import Foundation
import Testing
@testable import CrowTerminal

@Suite("Bundled resources")
struct BundledResourcesTests {

    @Test func wrapperScriptIsBundled() throws {
        let url = try #require(BundledResources.shellWrapperScriptURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func tmuxConfIsBundled() throws {
        let url = try #require(BundledResources.tmuxConfURL)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func wrapperScriptHasShebang() throws {
        let url = try #require(BundledResources.shellWrapperScriptURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        // Sanity: it's a real shell script, not stripped at bundle time.
        #expect(body.hasPrefix("#!/usr/bin/env bash"))
        // It honors $CROW_SENTINEL — load-bearing for the production wiring.
        #expect(body.contains("CROW_SENTINEL"))
    }

    @Test func tmuxConfHasPassthroughOn() throws {
        // allow-passthrough on must be set at server start (Phase 2a §4
        // finding from #198). Without this, OSC sequences from the wrapper
        // are consumed by tmux's emulator and never reach the xterm.js surface.
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("allow-passthrough on"))
    }

    @Test func tmuxConfDisablesStatusBar() throws {
        // Status bar steals one cell row from the terminal surface; Crow
        // has its own session UI, so we hide tmux's.
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("status off"))
    }

    @Test func tmuxConfDisablesMouseAndAlternateScreen() throws {
        // Mouse OFF (CROW-593): `mouse on` made tmux capture the wheel and drop
        // the pane into copy-mode on every scroll — the "scroll takeover". Off
        // hands scrolling AND selection to the outer terminal (xterm.js on the
        // web, native on desktop). Alternate-screen OFF keeps inner TUIs (Claude
        // Code, Cursor) rendering into the pane's MAIN buffer, so their output
        // lands in xterm.js's scrollback and the wheel scrolls the window
        // natively — instead of the alternate buffer falling back to arrow-key
        // "alternate scroll", which navigates the agent's input history.
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("set -gs mouse off"))
        #expect(!body.contains("set -gs mouse on"))
        #expect(body.contains("set -gs alternate-screen off"))
        // Cancel the client's smcup/rmcup so tmux renders into the outer
        // terminal's main buffer (scrollback), not its alternate buffer — the
        // load-bearing half of the native-wheel-scroll fix.
        #expect(body.contains("smcup@:rmcup@"))
        // The mouse copy bindings are retained but dormant (tmux gets no mouse
        // events while off), so flipping `mouse` back to `on` restores the tuned
        // #445/#452 selection behavior without re-authoring them.
        #expect(body.contains(#"bind -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-no-clear "pbcopy""#))
        #expect(body.contains(#"bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-no-clear "pbcopy""#))
        #expect(body.contains("bind -T root DoubleClick1Pane"))
        #expect(body.contains("bind -T root TripleClick1Pane"))
    }

    @Test func terminalHTMLHandlesModifiedEnter() throws {
        // #598: xterm.js sends the same \r for Enter and Shift+Enter, so the
        // host page must intercept modified Enter and emit distinct sequences
        // (CSI-u \x1b[13;2u for Shift+Enter, ESC CR for Option+Enter) or
        // Claude Code submits instead of inserting a newline. The xterm
        // resources get re-vendored wholesale (see Resources/xterm/VERSION),
        // so pin the handler's presence against an accidental overwrite.
        let url = try #require(BundledResources.terminalHTMLURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("attachCustomKeyEventHandler"))
        #expect(body.contains(#"\x1b[13;2u"#))
        #expect(body.contains(#"\x1b\r"#))
    }

    @Test func terminalHTMLLoadsJumpToBottomAddon() throws {
        // #668: jump-to-bottom (#633/#635) now lives in a shared xterm.js addon
        // so the desktop AND web surfaces load one implementation. The host page
        // must pull in the addon script and load it — pin that wiring against an
        // accidental overwrite when the xterm resources get re-vendored wholesale
        // (see Resources/xterm/VERSION). The behavior itself is pinned against
        // the addon file below.
        let url = try #require(BundledResources.terminalHTMLURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("xterm-addon-crow-jumpbottom.js"))
        #expect(body.contains("CrowJumpBottomAddon"))
        // The old inline control was deleted in favor of the addon — a stray
        // `#crow-jump-bottom` id/style would mean the inline copy crept back in.
        // (The addon script filename is `crow-jumpbottom`, no hyphen, so it
        // doesn't trip this.)
        #expect(!body.contains("crow-jump-bottom"))
    }

    @Test func jumpToBottomAddonIsBundled() throws {
        // #668: the shared addon file is what actually implements the control
        // (button + scroll wiring), and the daemon serves this exact file to the
        // web UI at /xterm/…, so both surfaces stay in sync. Pin its presence and
        // its load-bearing API surface.
        let dir = try #require(BundledResources.xtermDirectoryURL)
        let url = dir.appendingPathComponent("xterm-addon-crow-jumpbottom.js")
        #expect(FileManager.default.fileExists(atPath: url.path))
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("crow-jump-bottom"))
        #expect(body.contains("scrollToBottom"))
        #expect(body.contains("onScroll"))
        // Namespaced UMD global matching the vendored addons
        // (window.FitAddon.FitAddon → window.CrowJumpBottomAddon.CrowJumpBottomAddon).
        #expect(body.contains("CrowJumpBottomAddon"))
    }

    @Test func tmuxConfHasNoBarePrefixUnbind() throws {
        // #473: a bare `unbind-key -a` (no `-T`) defaults to the prefix
        // table, which is empty/non-existent after the first clear on
        // Crow's tmux server. The command errored with `table prefix
        // doesn't exist` and made `source-file` return exit 1 — breaking
        // #451's reconcile-on-attach gating. The fix uses an explicit
        // `bind-key -T prefix Any …` stub followed by
        // `unbind-key -a -T prefix` so the clear is idempotent. This test
        // pins both invariants: the bare form is gone, and the
        // stub-then-clear pair is present in that order.
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            #expect(
                trimmed != "unbind-key -a" && trimmed != "unbind -a",
                "bare `unbind-key -a` would re-introduce the #473 exit-1 bug"
            )
        }
        let stubIdx = body.range(of: "bind-key -T prefix Any send-keys")
        let clearIdx = body.range(of: "unbind-key -a -T prefix")
        #expect(stubIdx != nil, "missing stub bind that pre-creates the prefix table")
        #expect(clearIdx != nil, "missing explicit `unbind-key -a -T prefix`")
        if let s = stubIdx, let c = clearIdx {
            #expect(s.lowerBound < c.lowerBound, "stub must precede the clear")
        }
    }
}
