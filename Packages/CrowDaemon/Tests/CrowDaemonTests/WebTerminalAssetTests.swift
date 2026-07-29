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

    /// `source` with its comments removed, for assertions about what the code
    /// *does*. The prose around a handler legitimately names the thing the
    /// handler must not call (e.g. #875's "the right-click menu still calls
    /// pasteIntoTerminal()"), and that explanation is the part most worth
    /// keeping — so it must not trip the guard.
    ///
    /// Both `/* … */` and `//` forms, so a block comment can't smuggle a
    /// mention past a negative assertion (review). Only *closed* block comments
    /// are dropped: an unterminated `/*` is left in place, which can make a
    /// guard fail loudly but never pass silently.
    private static func stripComments(_ source: String) -> String {
        var withoutBlocks = ""
        var rest = Substring(source)
        while let open = rest.range(of: "/*"),
              let close = rest.range(of: "*/", range: open.upperBound..<rest.endIndex) {
            withoutBlocks += rest[..<open.lowerBound]
            rest = rest[close.upperBound...]
        }
        withoutBlocks += rest
        return withoutBlocks.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[..<marker.lowerBound]
            }
            .joined(separator: "\n")
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
    /// TUI reads as input-history navigation. Routing is the #824/#850 invariant:
    /// a plain shell — and an agent idling at its prompt — scrolls the local
    /// viewport, while a mouse-tracking app forwards the tick so it scrolls its
    /// own transcript (never arrow keys, which would be history nav).
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
            "must forward the wheel to the app when it is mouse-tracking")
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
        // The daemon flag must be consulted FIRST and must be able to answer
        // `false`. There is one shared xterm across tabs, and agent surfaces now
        // let the mouse-mode DECSETs through, so `mouseTrackingMode` can outlive
        // the tab that set it — an ungated legacy branch would let a known plain
        // shell inherit it and forward the wheel to the PTY.
        #expect(
            body.contains("typeof activeTerminal.agent_surface === 'boolean'"),
            "must treat a known surface kind as authoritative in BOTH directions")
        #expect(
            body.contains("return activeTerminal.agent_surface && mouseTracking;"),
            "a known surface is authoritative: a plain shell always scrolls locally, and an agent forwards only while mouse-tracking — at a plain prompt it scrolls the local viewport rather than the history-nav arrow keys (#850)")
        #expect(
            body.contains("'alternate'") && body.contains("mouseTrackingMode"),
            "must keep the alt-buffer / mouse-tracking signals as the unclassified fallback")
        #expect(
            try Self.functionBody("activeSurfaceIsAgent", in: source).contains("agent_surface"),
            "the surface kind comes from the list-terminals payload")
        // Touch must not diverge from the wheel — #777's shim and #824's wheel
        // routing have to agree about who owns the surface.
        #expect(
            try Self.functionBody("enableTouchScroll", in: source).contains("appOwnsScroll()"),
            "touch must share the wheel's ownership test")
    }

    /// `refreshTerminals` must REBIND `activeTerminal` to the freshly-fetched
    /// row, not merely check the old one is still present.
    ///
    /// `activeTerminal` stopped being a selection marker once `agent_surface`
    /// began driving the wheel/mouse routing (ADR-0013) — and that field can
    /// change under a stable terminal id, because `list-terminals` answers with
    /// the pre-binding fallback until the tmux window exists and with the
    /// authoritative option read afterwards. Holding the stale object left the
    /// client routing on an outdated flag until the user switched tabs.
    ///
    /// Asserted on source shape because driving `refreshTerminals` needs a live
    /// RPC socket; the jsdom suite covers the routing this feeds.
    @Test func refreshTerminalsRebindsTheActiveTerminalToTheFreshRow() throws {
        let body = try Self.functionBody("refreshTerminals", in: Self.webAsset("app.js"))
        #expect(
            body.contains("activeTerminal = terminals.find("),
            "must re-resolve activeTerminal from the fresh list, not keep the old object")
        #expect(
            body.contains("|| terminals[0] || null"),
            "must still fall back to the first terminal, then null")
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

    /// #875: neither surface may handle the paste chord in its key handler, and
    /// any branch that DOES shadow a browser default must cancel the event.
    ///
    /// `attachCustomKeyEventHandler` returning `false` only makes xterm skip its
    /// own key handling — xterm's `_keyDown` returns early, before any
    /// `cancel()` — so the browser's default gesture still runs. Handling Cmd+V
    /// there pasted once explicitly and once more when the native paste fired
    /// xterm's own `paste` listener (registered on the helper textarea), with
    /// bracketed-paste wrapping applied twice. Leaving the chord alone is what
    /// makes it exactly one paste: xterm's listener already wraps and forwards
    /// it, needs no clipboard-read permission, and works over plain http
    /// (`--host 0.0.0.0`), where `navigator.clipboard` doesn't exist and the
    /// explicit path was a no-op anyway. The right-click menu keeps the explicit
    /// path — a click is not a paste gesture, so nothing native fires there.
    ///
    /// Asserted on both surfaces because they carry separate implementations of
    /// the same handler (the drift this suite exists to prevent).
    @Test func keyHandlersLeavePasteToTheBrowserAndCancelWhatTheyDoHandle() throws {
        let appJS = try Self.webAsset("app.js")
        let body = Self.stripComments(String(try Self.functionBody("handleTerminalKey", in: appJS)))
        #expect(
            !body.contains("pasteIntoTerminal"),
            "app.js's key handler must not paste on Cmd+V — the native paste already does (#875)")
        #expect(
            !body.lowercased().contains("e.key === 'v'"),
            "app.js's key handler must not claim the paste chord at all (#875)")
        for cancel in ["e.preventDefault();", "e.stopPropagation();"] {
            #expect(
                body.contains(cancel),
                "a branch that shadows a browser default must cancel the event: \(cancel)")
        }
        #expect(
            appJS.contains("action: pasteIntoTerminal"),
            "the right-click menu keeps the explicit paste path — it has no native gesture")

        let debugPage = try Self.webAsset("terminal.html")
        #expect(
            !Self.stripComments(debugPage).lowercased().contains("e.key === 'v'"),
            "terminal.html's key handler must not claim the paste chord either (#875)")
        #expect(
            debugPage.contains("addItem('Paste', true, pasteClipboard)"),
            "terminal.html's right-click menu keeps the explicit paste path")
        #expect(
            debugPage.contains("e.preventDefault();") && debugPage.contains("e.stopPropagation();"),
            "terminal.html's copy branch must cancel the browser default")
    }

    /// CROW-916: both live surfaces must rewrite Shift+Enter to a sequence the
    /// agent can tell apart from a plain Enter.
    ///
    /// xterm.js's key table has no `shiftKey` branch for keyCode 13
    /// (`e.altKey ? ESC+CR : CR`), so without this the two chords reach the PTY
    /// as the same bare `\r` and Claude Code submits on both. CSI-u is the right
    /// sequence because `crow-tmux.conf`'s extended-keys setup carries it to
    /// apps that negotiate extended keys and downgrades it to a plain `\r` for
    /// apps that don't — a literal `ESC CR` would reach vim as "leave insert
    /// mode, then Enter".
    ///
    /// This is the guard that was missing. #599 added the handler to
    /// CrowTerminal's `terminal.html` and pinned it there
    /// (`BundledResourcesTests.terminalHTMLHandlesModifiedEnter`) — but ADR 0010
    /// retired that surface, so the passing test covered a page nothing loads
    /// while both shipping surfaces regressed unasserted. Parameterized over the
    /// live assets so it can't happen the same way twice.
    ///
    /// Asserted on the comment-stripped source: the rationale prose names the
    /// sequence too, and a guard that a comment can satisfy guards nothing. The
    /// branch is matched as one contiguous condition rather than as separate
    /// `'Enter'` / `shiftKey` mentions — `app.js`'s modal dialogs already test
    /// `e.key === 'Enter'`, so the loose form passes on the unfixed file.
    @Test(arguments: ["app.js", "terminal.html"])
    func modifiedEnterIsDistinguishableFromPlainEnter(asset: String) throws {
        let code = Self.stripComments(try Self.webAsset(asset))
        #expect(
            code.contains(#"sendToPTY('\x1b[13;2u')"#),
            "\(asset) must SEND CSI-u for Shift+Enter, not a bare \\r (CROW-916)")
        #expect(
            code.contains("e.key === 'Enter' && e.shiftKey"),
            "\(asset)'s terminal key handler must branch on Shift+Enter")
        #expect(
            code.contains("e.preventDefault();") && code.contains("e.stopPropagation();"),
            "\(asset)'s Shift+Enter branch must cancel the event — returning false leaves xterm's own cancel unreached, so the keypress phase writes a second \\r (#875)")
    }

    /// Cancelling a gesture and being able to perform it are one decision: a
    /// surface may only `preventDefault()` the copy chord if its copy always
    /// delivers. `navigator.clipboard` is absent over plain http (a
    /// `--host 0.0.0.0` daemon) and `writeText` can reject where it exists, so
    /// without the legacy `execCommand` path cancelling turns Cmd+C into a
    /// silent no-op — the same non-secure-context trap that decided #875's paste
    /// direction, which is why the debug page's copy was left cancelling with no
    /// fallback in the first cut (review).
    ///
    /// Reading the clipboard is guarded rather than fallback'd: there is no
    /// `execCommand('paste')` for a web page, so the menu simply does nothing
    /// where the API is missing — and Cmd+V still pastes, natively.
    @Test(arguments: ["app.js", "terminal.html"])
    func clipboardWritesAlwaysDeliverAndReadsAreGuarded(asset: String) throws {
        let source = try Self.webAsset(asset)
        #expect(
            source.contains("navigator.clipboard && navigator.clipboard.writeText"),
            "\(asset) must feature-detect writeText before using it")
        #expect(
            source.contains("execCommand('copy')"),
            "\(asset) must keep the non-secure-context copy fallback")
        #expect(
            source.contains("navigator.clipboard && navigator.clipboard.readText"),
            "\(asset) must guard readText — it has no fallback to reach for")
    }

    /// CROW-907: an empty board is an empty list, not an error. `boardEmpty` once
    /// appended "Boards require the Crow desktop app to be running." to every
    /// empty board — false since `crowd` serves the boards off its own
    /// IssueTracker/AllowListService (CROW-581 M-C, ADR 0010). Pin the hint out of
    /// the executed source so it can't creep back, and pin the allowlist's own
    /// scanning state — the load-bearing half of the fix, since the allowlist is
    /// never cached and would otherwise flash "empty" during the CROW-593 scan.
    @Test func emptyBoardsDropTheStaleDesktopAppHint() throws {
        let source = try Self.webAsset("app.js")
        #expect(
            !Self.stripComments(source).contains("desktop app to be running"),
            "the stale 'requires the Crow desktop app' board hint must stay deleted (CROW-907)")
        #expect(
            try Self.functionBody("boardEmpty", in: source).contains("'board-empty', msg"),
            "boardEmpty must render only the caller's context message")
        #expect(
            try Self.functionBody("renderAllowlist", in: source).contains("Scanning allowlist"),
            "renderAllowlist must show a scanning state, not 'No allowlist entries', mid-scan")
        // The allowlist never polls or caches, so `scanning` keys on `d == null`;
        // refreshBoard must seed a settled snapshot on a failed read or that
        // scanning state strands forever (a spinner that lies — the very thing
        // CROW-907 removes).
        #expect(
            try Self.functionBody("refreshBoard", in: source)
                .contains("boardData.allowlist = { entries: [], loading: false }"),
            "refreshBoard must seed the allowlist on a failed read so it can't wedge on 'Scanning…'")
        #expect(
            !(try Self.webAsset("app.css")).contains(".board-empty-hint"),
            "the board-empty-hint CSS rule is dead once the hint is gone")
    }

    /// CROW-917: the Select-sessions toggle lives in the far-right icon column
    /// (`sidebarIconColumn`, stacked under bell/gear/+), NOT in the left stack
    /// (`sidebarLeftStack`, which holds the Tickets card + nav rows). Pin the
    /// placement so the toggle can't drift into the left stack, and keep the
    /// now-dead `.tk-tool.nav-selecting` rule out of app.css — only `.nav-select`
    /// and `.action-btn` ever take `nav-selecting`. (Supersedes CROW-913's
    /// nav-row-vs-tools-stack pinning, which this PR reverses.)
    @Test func selectToggleLivesInIconColumnNotTheLeftStack() throws {
        let js = try Self.webAsset("app.js")
        // Anchor on the behaviour (selectionMode), not the icon name: a Select
        // toggle re-added to the left stack with any glyph should still fail.
        #expect(
            try !Self.stripComments(String(Self.functionBody("sidebarLeftStack", in: js)))
                .contains("selectionMode"),
            "the Select toggle's selection logic must not live in the left sidebar stack (CROW-917)")
        let iconCol = try Self.functionBody("sidebarIconColumn", in: js)
        #expect(
            iconCol.contains("'nav-select'") && iconCol.contains("selectionMode"),
            "sidebarIconColumn must render the Select toggle (its selectionMode logic) in the icon column")
        let css = try Self.webAsset("app.css")
        #expect(
            !css.contains(".tk-tool.nav-selecting"),
            "the .tk-tool.nav-selecting rule is dead once Select leaves the tools stack")
        // `.nav-select` alone is a substring of `.nav-selecting` (app.css's
        // `.action-btn.nav-selecting`), so anchor to the rule opening AND the
        // compound form — the latter is what keeps the active toggle red over
        // `:hover`, so it's the part most worth freezing (review).
        #expect(
            css.contains(".nav-select {") && css.contains(".nav-select.nav-selecting"),
            "the relocated Select toggle needs its .nav-select styles")
    }

    /// CROW-917: two layout decisions with no other pin, both verified to regress
    /// silently (deleting either leaves every suite green). The right column's four
    /// `flex:1` icons divide the left column's height, so a short Manager-less /
    /// cold-start column would push them under the WCAG 2.2 §2.5.8 target-size
    /// minimum without the `min-height` floor a prior review round mandated; and
    /// relocating the new-manager `"+"` into that column (out of the nav rows) is
    /// half this PR's purpose, yet the Select pin above only anchors on `.nav-select`.
    @Test func iconColumnHasWcagFloorAndHoldsTheNewManagerButton() throws {
        // stripComments the CSS: the floor's value is also named in the rule's doc
        // comment, so a bare whole-file `contains` false-passes off the prose once
        // the declaration itself is deleted (caught by mutation-testing this pin).
        let css = Self.stripComments(try Self.webAsset("app.css"))
        #expect(
            css.contains("min-height: 24px"),
            "the right column's icon buttons need the 24px WCAG 2.5.8 target-size floor (CROW-917 review)")
        // Pin the append, not the `el('button', 'nav-plus', …)` construction: the
        // regression the review names is the "+" being built but not rendered, so a
        // `contains("'nav-plus'")` would miss a dropped appendChild (also mutation-checked).
        let js = try Self.webAsset("app.js")
        let iconCol = try Self.functionBody("sidebarIconColumn", in: js)
        #expect(
            iconCol.contains("col.appendChild(plus)"),
            "the new-manager \"+\" must be appended to the icon column, not the nav rows (CROW-917)")
    }

    /// CROW-917: the ticket box spans the full width of the left column and is
    /// only ~2 button-rows tall, so it lines up with the Notifications+Settings
    /// pair in the right icon column. Pin `min-height` (NOT a hard `height`, which
    /// would clip the counts row out the bottom when a raised browser min-font
    /// grows them — the #913 fixed-px failure mode) and the single-row flex counts
    /// (the #913 two-column grid only existed to keep the width-capped box narrow;
    /// #917 supersedes that cap, so the counts are one horizontal row again).
    @Test func ticketBoxIsFullWidthAndShort() throws {
        let css = try Self.webAsset("app.css")
        #expect(
            css.contains("min-height: 64px"),
            "the ticket card must be ~2 button-rows tall via min-height (not a clipping fixed height) (CROW-917)")
        #expect(
            css.contains(".tickets-counts { display: flex;"),
            "the counts must be a single horizontal flex row now the full-width box no longer needs the compact two-column grid (CROW-917)")
        #expect(
            !css.contains("width: max-content; max-width: 160px"),
            "the #913 content-sized width cap is superseded — the card is full-width in the left column now")
    }
}
