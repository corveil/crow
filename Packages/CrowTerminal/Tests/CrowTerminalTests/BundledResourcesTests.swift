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

    @Test func tmuxConfDisablesMouse() throws {
        // tmux mouse on enables terminal mouse reporting, which makes
        // libghostty clear selection on mouse-up (#445).
        let url = try #require(BundledResources.tmuxConfURL)
        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("set -gs mouse off"))
        #expect(!body.contains("set -gs mouse on"))
    }
}
