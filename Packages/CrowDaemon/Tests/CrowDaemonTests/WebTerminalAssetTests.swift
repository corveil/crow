import Foundation
import Testing
@testable import CrowDaemon

/// Drift guard for the terminal surfaces served out of `Resources/web`.
///
/// There are two xterm.js setups in that directory — the app's inline terminal
/// (`app.js` → `ensureTerminal`) and the standalone single-terminal page
/// (`terminal.html`). #776: the inline one shipped WITHOUT the mouse-mode
/// swallow that `terminal.html` has carried since CROW-581, so the agent TUI's
/// mouse tracking stayed live in the app and every mouse move yanked a
/// scrolled-up viewport back to the bottom. These tests pin the swallow into
/// both files so the two can't silently diverge again while they remain
/// separate implementations.
@Suite struct WebTerminalAssetTests {
    /// Walk up from this source file to the repo's `Resources/web` directory —
    /// same lookup style as `CrowAttributionTests`' footer drift guard. The
    /// assets are `.copy`d resources, so asserting on the repo copy (rather than
    /// a bundle) keeps the test about what a reviewer actually edits.
    private static func webAsset(_ name: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<10 {
            let candidate = dir.appendingPathComponent(
                "Sources/CrowDaemon/Resources/web/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        let url = try #require(found, "could not locate Resources/web/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Both surfaces must drop the mouse-tracking DECSET/DECRST toggles
    /// (`?1000/1001/1002/1003/1005/1006/1015/1016`) at the parser, for `h` (set)
    /// and `l` (reset) alike — a swallow that covers only one of the two leaves
    /// the mode reachable.
    @Test(arguments: ["app.js", "terminal.html"])
    func swallowsMouseTrackingModes(asset: String) throws {
        let source = try Self.webAsset(asset)
        #expect(
            source.contains("MOUSE_MODES"),
            "\(asset) must keep the mouse-mode swallow (#776)")
        for mode in ["1000", "1001", "1002", "1003", "1005", "1006", "1015", "1016"] {
            #expect(
                source.contains(mode),
                "\(asset) must swallow mouse mode ?\(mode)")
        }
        for final in ["'h'", "'l'"] {
            #expect(
                source.contains("registerCsiHandler({ prefix: '?', final: \(final) }, swallowMouseMode)"),
                "\(asset) must register the swallow for CSI ? … \(final)")
        }
    }

    /// The wheel handler owns the event in BOTH buffers. Returning early on the
    /// alternate buffer would hand the wheel to xterm's alternate-scroll
    /// fallback, which emits arrow keys the agent TUI reads as input-history
    /// navigation (crow-tmux.conf's `alternate-screen off` rationale, #776).
    @Test func wheelHandlerNeverFallsThroughOnAlternateBuffer() throws {
        let source = try Self.webAsset("app.js")
        #expect(!source.contains("return; // let TUIs handle the wheel"))
    }
}
