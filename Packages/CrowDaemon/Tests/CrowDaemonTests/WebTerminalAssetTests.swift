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

    /// The single line declaring the swallowed-mode set. Anchoring the per-mode
    /// assertions to it keeps them meaningful: a bare `contains("1000")` over
    /// all of `app.js` would match any unrelated timeout literal (review).
    private static func mouseModesLine(_ source: String) throws -> Substring {
        try #require(
            source.split(separator: "\n").first { $0.contains("const MOUSE_MODES") },
            "no `const MOUSE_MODES` declaration")
    }

    /// The body of a top-level `function <name>(` … `\n}` block, for asserting on
    /// one handler rather than the whole file.
    private static func functionBody(_ name: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "function \(name)("), "no \(name)")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"), "unterminated \(name)")
        return rest[..<end.lowerBound]
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
        let modes = try Self.mouseModesLine(source)
        for mode in ["1000", "1001", "1002", "1003", "1005", "1006", "1015", "1016"] {
            #expect(
                modes.contains(mode),
                "\(asset)'s MOUSE_MODES must include ?\(mode)")
        }
        for final in ["'h'", "'l'"] {
            #expect(
                source.contains("registerCsiHandler({ prefix: '?', final: \(final) }, swallowMouseMode)"),
                "\(asset) must register the swallow for CSI ? … \(final)")
        }
    }

    /// The wheel handler always CONSUMES the event, and ROUTES it by surface
    /// rather than dropping it (ADR-0013).
    ///
    /// Consuming is the #776 invariant: any early return hands the wheel to
    /// xterm's alternate-scroll fallback, which emits arrow keys that the agent
    /// TUI reads as input-history navigation. Routing is the #824 invariant: a
    /// plain shell scrolls the local 50k scrollback, while an agent surface
    /// forwards the tick to the app so it scrolls its own transcript.
    ///
    /// Asserted as the positive shape rather than the absence of a string, so
    /// reintroducing a bail with different wording still fails (review).
    @Test func wheelHandlerOwnsTheEventAndRoutesBySurface() throws {
        let body = try Self.functionBody("enableWheelScroll", in: Self.webAsset("app.js"))
        #expect(
            body.contains("appOwnsScroll()"),
            "the wheel must route by surface ownership, not unconditionally")
        #expect(body.contains("term.scrollLines("), "must scroll the local scrollback")
        #expect(
            body.contains("sendScrollToPTY("),
            "must forward the wheel to the app on an agent surface")
        for consume in ["e.preventDefault();", "e.stopPropagation();"] {
            #expect(body.contains(consume), "must always consume the wheel event: \(consume)")
        }
        // `if (!term) return;` — nothing else may short-circuit before the
        // preventDefault/stopPropagation pair below it.
        let returns = body.components(separatedBy: "return").count - 1
        #expect(returns == 1, "only the `if (!term)` guard may return early, found \(returns)")
    }

    /// The surface-ownership predicate the wheel and touch shims share. Agent
    /// surfaces are identified by the daemon-supplied `agent_surface` flag, NOT
    /// by `buffer.active.type`: crow-tmux.conf strips the client's smcup/rmcup
    /// and one tmux client serves every tab, so the client never actually enters
    /// the alternate buffer per-window and a buffer-type-only check would be
    /// permanently false (the trap the #822 prototype fell into).
    @Test func scrollOwnershipConsultsTheDaemonSuppliedSurfaceKind() throws {
        let source = try Self.webAsset("app.js")
        let body = try Self.functionBody("appOwnsScroll", in: source)
        #expect(body.contains("activeSurfaceIsAgent()"), "must consult the surface kind")
        #expect(
            body.contains("'alternate'") && body.contains("mouseTrackingMode"),
            "must keep the alt-buffer / mouse-tracking signals as well")
        #expect(
            try Self.functionBody("activeSurfaceIsAgent", in: source).contains("agent_surface"),
            "the surface kind comes from the list-terminals payload")
        // Touch must not diverge from the wheel — #777's shim and #824's wheel
        // routing have to agree about who owns the surface.
        #expect(
            try Self.functionBody("enableTouchScroll", in: source).contains("appOwnsScroll()"),
            "touch must share the wheel's ownership test")
    }

    /// The swallow is conditional on surface kind (ADR-0013): plain shells keep
    /// it (so drag-select and the context menu survive), agent surfaces let the
    /// mode toggles through so the app claims the wheel. Because that hands
    /// drags to the app, `macOptionClickForcesSelection` is the only way left to
    /// select text in an agent window — and xterm.js defaults it to false, so it
    /// must be set explicitly or the ⌥-drag escape hatch silently does nothing.
    @Test func mouseSwallowIsConditionalWithASelectionEscapeHatch() throws {
        let source = try Self.webAsset("app.js")
        #expect(
            try Self.functionBody("swallowMouseMode", in: source).contains("activeSurfaceIsAgent()"),
            "the swallow must be conditional on the surface kind")
        #expect(
            source.contains("macOptionClickForcesSelection: true"),
            "⌥-drag selection must be enabled explicitly (xterm.js defaults it to false)")
    }
}
