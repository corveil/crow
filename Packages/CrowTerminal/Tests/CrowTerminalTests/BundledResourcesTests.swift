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
        // are consumed by tmux's emulator and never reach Ghostty.
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("allow-passthrough on"))
    }

    @Test func tmuxConfDisablesStatusBar() throws {
        // Status bar steals one cell row from the Ghostty surface; Crow
        // has its own session UI, so we hide tmux's.
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("status off"))
    }

    @Test func tmuxConfEnablesMouseWithCopyPipeNoClear() throws {
        // Mouse must be on so the wheel drives tmux pane scrollback (#452 —
        // turning mouse off to fix the #445 selection-clear killed wheel
        // scrollback under tmux). Selection-clear is instead handled by
        // overriding the copy bindings to use `copy-pipe-no-clear`, which
        // copies to the macOS pasteboard without exiting copy mode (the
        // default `copy-pipe-and-cancel` is what wiped the highlight).
        // Drag is overridden in both copy-mode tables; double/triple
        // click are overridden in root so word/line selection is
        // consistent with the drag behavior.
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("set -gs mouse on"))
        #expect(!body.contains("set -gs mouse off"))
        #expect(body.contains(#"bind -T copy-mode    MouseDragEnd1Pane send-keys -X copy-pipe-no-clear "pbcopy""#))
        #expect(body.contains(#"bind -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-no-clear "pbcopy""#))
        #expect(body.contains("bind -T root DoubleClick1Pane"))
        #expect(body.contains("bind -T root TripleClick1Pane"))
        #expect(body.contains(#"send-keys -X select-word ; run -d0.3 ; send-keys -X copy-pipe-no-clear "pbcopy""#))
        #expect(body.contains(#"send-keys -X select-line ; run -d0.3 ; send-keys -X copy-pipe-no-clear "pbcopy""#))
    }
}
