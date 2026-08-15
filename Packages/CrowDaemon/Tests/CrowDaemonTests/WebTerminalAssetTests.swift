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

    /// The declarations of the first CSS rule opened by `opener` — a selector's
    /// trailing text plus ` {` — up to that rule's closing brace. Lets a pin say
    /// WHICH rule it expects a declaration in without also freezing the
    /// selector's line breaks and indentation (CROW-1016).
    private static func ruleBody(openedBy opener: String, in css: String) throws -> Substring {
        let start = try #require(css.range(of: opener), "no rule opened by \(opener)")
        let end = try #require(
            css.range(of: "}", range: start.upperBound..<css.endIndex),
            "unterminated rule opened by \(opener)")
        return css[start.upperBound..<end.lowerBound]
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
        let capBody = try Self.functionBody("applySurfaceScrollback", in: source)
        #expect(
            capBody.contains("activeSurfaceIsAgent()") && capBody.contains("activeSurfaceUsesAltScreen()"),
            "xterm scrollback caps to 0 only for alt-buffer agents; inline agents keep UNIFIED_SCROLLBACK (CROW-1010)")
        #expect(
            try Self.functionBody("activeSurfaceUsesAltScreen", in: source).contains("uses_alternate_screen"),
            "the alt-buffer capability comes from the list-terminals payload")
        #expect(
            capBody.contains("term.options.scrollback"),
            "the cap is the live xterm option, reapplied on every tab bind")
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
            body.contains("pendingTerminalId && terminals.find(")
                && body.contains("t.id === (activeTerminal && activeTerminal.id)"),
            "must re-resolve activeTerminal from the fresh list, not keep the old object")
        #expect(
            body.contains("|| terminals[0] || null"),
            "must still fall back to the first terminal, then null")
        #expect(
            body.contains("applySurfaceScrollback()"),
            "rebinding the active row must re-apply the alt-buffer vs inline vs shell xterm scrollback cap (CROW-1010)")
    }

    /// CROW-1035: attaching to an agent TUI must switch in place, not take the
    /// #673 full reload. The reload's new PTY (24×80 then SIGWINCH) plus the
    /// capture-pane replay is what jumps Claude's caret and doubles Cursor
    /// chrome. Shells keep the reload so a surface another client reshaped
    /// still self-heals. The jsdom suite drives the branch; this pins the
    /// routing so a later edit can't silently send agents back through reload.
    @Test func attachWindowSwitchesAgentSurfacesInPlace() throws {
        let source = try Self.webAsset("app.js")
        let attach = try Self.functionBody("attachWindow", in: source)
        #expect(
            attach.contains("activeSurfaceIsAgent()") && attach.contains("switchAgentWindow("),
            "an agent surface must take the in-place switch, not reloadTerminal")
        #expect(
            attach.contains("reloadTerminal()"),
            "a plain shell must still take the #673 full reload")
        let inPlace = try Self.functionBody("switchAgentWindow", in: source)
        #expect(
            inPlace.contains("term.reset()") && inPlace.contains("selectWindow("),
            "in-place switch resets the local buffer then select-windows on the live socket")
        #expect(
            !inPlace.contains("reloadTerminal(") && !inPlace.contains("connectTerminalWs("),
            "in-place switch must not tear down the PTY")
        #expect(
            inPlace.contains("armScrollbackHeal()"),
            "inline agents stay eligible for the CROW-1027 post-switch heal")
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
    /// This is the guard that was missing. #599 added the handler only to the
    /// macOS app's `terminal.html`, which ADR 0010 retired — so it covered a
    /// page nothing loads while both shipping surfaces regressed unasserted.
    /// Parameterized over the live assets so it can't happen the same way twice.
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

    /// CROW-988: a software keyboard shrinks only the VISUAL viewport on iOS, so
    /// the grid must be refit against `visualViewport` or the prompt line ends up
    /// under the keyboard with no way to scroll it back. The logic lives in the
    /// shared `xterm-addon-crow-viewport.js` (pinned separately by
    /// `BundledResourcesTests.viewportAddonIsBundled`) — but an addon nobody
    /// loads fixes nothing, and the two live pages wire their xterm setups
    /// independently, which is exactly how the mouse-mode swallow (#776) shipped
    /// on one surface and not the other. Pin the script tag AND the load on both.
    ///
    /// Also pin that the addon is handed a refit callback: the addon
    /// deliberately doesn't call `fitAddon.fit()` itself (each page wraps the fit
    /// in its own dedup/ownership rules), so an omitted `onResize` resizes the
    /// host element and leaves the xterm grid at its old row count — the
    /// clipped-rows half of the bug, silently.
    @Test(arguments: ["app.js", "terminal.html"])
    func terminalSurfacesRefitAgainstTheVisualViewport(asset: String) throws {
        let code = Self.stripComments(try Self.webAsset(asset))
        #expect(
            code.contains("CrowViewportAddon.CrowViewportAddon("),
            "\(asset) must construct the visual-viewport addon (CROW-988)")
        #expect(
            code.contains("onResize:"),
            "\(asset) must hand the addon its own refit — the addon never calls fit() itself")
    }

    /// The `<script src>` half of the above, on the pages that own the tag.
    /// `app.js` is loaded by `index.html`, so that's where its tag lives.
    @Test(arguments: ["index.html", "terminal.html"])
    func terminalPagesShipTheViewportAddon(page: String) throws {
        let source = try Self.webAsset(page)
        #expect(
            source.contains("xterm-addon-crow-viewport.js"),
            "\(page) must load the visual-viewport addon (CROW-988)")
    }

    /// `interactive-widget=resizes-content` makes Chrome/Android shrink the
    /// LAYOUT viewport for the keyboard, which puts that platform back on the
    /// ordinary `100dvh` + window-`resize` path the pages already handle; without
    /// it Android overlays the keyboard and depends entirely on the addon.
    /// `viewport-fit=cover` is what lets the terminal background go full-bleed —
    /// `terminal.html` was the one page missing it (CROW-988).
    @Test(arguments: ["index.html", "terminal.html"])
    func viewportMetaHandlesTheSoftwareKeyboard(page: String) throws {
        let source = try Self.webAsset(page)
        let meta = try #require(
            source.split(separator: "\n", omittingEmptySubsequences: false)
                .first { $0.contains("name=\"viewport\"") },
            "\(page) must declare a viewport meta")
        #expect(
            meta.contains("interactive-widget=resizes-content"),
            "\(page)'s viewport meta must let Android resize the layout viewport (CROW-988)")
        #expect(
            meta.contains("viewport-fit=cover"),
            "\(page)'s viewport meta must opt into the full-bleed safe-area layout")
    }

    /// CROW-1006: both terminal surfaces must reach their context menu by
    /// long-press, not right-click alone.
    ///
    /// The grid is a canvas that `xterm.css` marks `user-select: none`, so a
    /// phone has no native selection or copy callout over it — these menus *are*
    /// the mobile context menu, and until this bridge landed copy and paste were
    /// unreachable there. A `contextmenu` listener is not enough on its own:
    /// iOS Safari dispatches no `contextmenu` for a long-press on a plain
    /// element, which is the case this exists for.
    ///
    /// Asserted per-surface because the two carry separate implementations (the
    /// drift this suite exists to prevent) — `app.js` reuses its shared
    /// `attachLongPress`, the debug page inlines an equivalent.
    ///
    /// Deliberately NOT run through `stripComments`: every assertion here is
    /// positive, and the shapes matched are code, not prose. `stripComments`
    /// pairs the `/*` inside app.js's `// … #/settings/*` line comment with a
    /// later `*after*`, swallowing the region this registration lives in — a
    /// hazard only *negative* guards need to bear.
    @Test func bothTerminalSurfacesOpenTheirMenuOnLongPress() throws {
        let appJS = try Self.webAsset("app.js")
        #expect(
            appJS.contains("wrap.addEventListener('contextmenu', showTerminalMenu)"),
            "app.js must keep the desktop right-click path on #terminal-wrap")
        #expect(
            appJS.contains("attachLongPress(wrap,"),
            "app.js must bridge long-press to the same menu on #terminal-wrap (CROW-1006)")

        let debugPage = try Self.webAsset("terminal.html")
        // One builder, two entry points: routing both through `openMenu` is what
        // keeps the touch menu from drifting from the right-click one *within*
        // the page, the way the two pages once drifted from each other.
        #expect(
            debugPage.contains("openMenu(e.clientX, e.clientY)")
                && debugPage.contains("openMenu(sx, sy)"),
            "terminal.html's right-click and long-press must build the same menu (CROW-1006)")
    }

    /// The gesture contract the bridge above depends on, pinned on both
    /// surfaces: a press must be still, single-fingered, and held — otherwise
    /// the menu would ambush a scroll drag (the #777 touch-scroll shim owns the
    /// same finger) or a pinch. The trailing `preventDefault` matters just as
    /// much: without it the emulated click lands on the surface underneath and
    /// dismisses the menu it just opened.
    @Test(arguments: ["app.js", "terminal.html"])
    func longPressIsStillSingleFingeredAndHeld(asset: String) throws {
        let code = try Self.webAsset(asset)
        #expect(
            code.contains("}, 500)"),
            "\(asset)'s long-press must be held, not instant")
        #expect(
            code.contains("touches.length !== 1"),
            "\(asset) must ignore multi-touch — a pinch is not a long-press")
        #expect(
            code.contains("> 10 ||"),
            "\(asset) must cancel on movement so a scroll drag never opens the menu")
        #expect(
            code.contains("if (fired) { e.preventDefault();"),
            "\(asset) must swallow the emulated click, or the menu closes itself")
    }

    /// iOS must not pre-empt either menu with its own long-press sheet. Nothing
    /// is given up by suppressing it: the grid carries `user-select: none`
    /// already, so there is no native selection for the callout to act on — only
    /// a sheet that would race Crow's menu for the same gesture (CROW-1006).
    @Test(arguments: ["app.css", "terminal.html"])
    func theTerminalGridSuppressesTheIOSCallout(asset: String) throws {
        let source = try Self.webAsset(asset)
        let block = try #require(
            source.range(of: "#terminal {"),
            "\(asset) must style #terminal")
        let rule = source[block.lowerBound...].prefix(while: { $0 != "}" })
        #expect(
            rule.contains("-webkit-touch-callout: none"),
            "\(asset)'s #terminal must suppress the iOS long-press callout (CROW-1006)")
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

    /// CROW-917/922: layout decisions with no other pin, verified to regress silently
    /// (reverting any leaves every suite green). CROW-922 made the right column's icon
    /// buttons natural-size (`flex: 0 0 auto`) with a `min-height` floor above the WCAG
    /// 2.2 §2.5.8 target-size minimum, and centers the stack (`justify-content: center`)
    /// so the non-stretching buttons don't bunch at the top under `align-items: stretch`
    /// — both pinned as whole-rule text below, so a revert to `flex: 1 1 0` or a dropped
    /// `justify-content` is caught, not just a changed floor value. Separately, relocating
    /// the new-manager `"+"` into that column (out of the nav rows) is half CROW-917's
    /// purpose, yet the Select pin above only anchors on `.nav-select`.
    @Test func iconColumnHasWcagFloorAndHoldsTheNewManagerButton() throws {
        // stripComments the CSS: the floor value + `flex: 0 0 auto` are also named in the
        // rules' doc comments, so a whole-file `contains` would false-pass off the prose
        // once a declaration is deleted (this pin is mutation-checked against that).
        let css = Self.stripComments(try Self.webAsset("app.css"))
        // Pin the whole button rule, not just the floor: the CROW-922 regressions to
        // guard are `flex: 1 1 0` creeping back (buttons stretch again) and losing the
        // 28px floor, so anchor both to the `.sidebar-right > button` selector.
        #expect(
            css.contains(".sidebar-right > button { flex: 0 0 auto; width: 100%; min-height: 28px; }"),
            "the right column's buttons must be natural-size (flex:0 0 auto) with the 28px WCAG 2.5.8 floor, not flex-filling (CROW-917/922)")
        // And that the column centers its now-non-stretching stack — dropping this leaves
        // the buttons bunched at the top under `.sidebar-top`'s `align-items: stretch`.
        #expect(
            css.contains(".sidebar-right { flex: 0 0 auto; width: 30px; display: flex; flex-direction: column; justify-content: center; gap: 6px; }"),
            "the right icon column must center its fixed-size button stack (CROW-922)")
        // Pin the append, not the `el('button', 'nav-plus', …)` construction: the
        // regression the review names is the "+" being built but not rendered, so a
        // `contains("'nav-plus'")` would miss a dropped appendChild (also mutation-checked).
        let js = try Self.webAsset("app.js")
        let iconCol = try Self.functionBody("sidebarIconColumn", in: js)
        #expect(
            iconCol.contains("col.appendChild(plus)"),
            "the new-manager \"+\" must be appended to the icon column, not the nav rows (CROW-917)")
    }

    /// CROW-917/922: the ticket box spans the full width of the left column and is
    /// only ~2 button-rows tall. (Pre-CROW-922 the same `min-height` also lined the
    /// box up with the right column's icon pair; that column no longer derives its
    /// height from the left, so `min-height: 64px` is now just the box's own size, not
    /// load-bearing for cross-column alignment.) Pin `min-height` (NOT a hard `height`,
    /// which would clip the counts row out the bottom when a raised browser min-font
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

    /// CROW-924: the "Tickets" title centres in the full-width box, superseding the
    /// left-pinning `space-between` head CROW-913 used while the card was compact. The
    /// centring is a 3-column grid whose two outer tracks both read `--tk-refresh` — the
    /// same token the refresh button sizes from — so the left spacer can't drift from the
    /// button's width and silently de-centre the title. That single source of truth is the
    /// durability fix; the two literal `22px`s it replaces were a standing, untested trap
    /// (a WCAG target-size bump to one would de-centre with every suite still green). Pin
    /// the whole grid rule (a revert to `space-between` or to hardcoded outer widths fails
    /// here), the title's own centre-track placement + alignment (the invariant itself),
    /// that the button derives its box from the same token, and that the token is actually
    /// defined (a dangling var() drops the grid to `none` and the button to `auto`).
    @Test func ticketTitleCentresViaGrid() throws {
        // stripComments: `--tk-refresh`, "grid", and "space-between" all appear in the
        // .tickets-card / .tickets-head doc comments, so a raw-file `contains` would
        // false-pass off the prose once a declaration is deleted (mutation-checked).
        let css = Self.stripComments(try Self.webAsset("app.css"))
        #expect(
            css.contains(".tickets-head { display: grid; grid-template-columns: var(--tk-refresh) 1fr var(--tk-refresh); align-items: center; gap: 4px; }"),
            "the title must centre via the var-driven 3-column grid, not a left-pinning space-between row (CROW-924)")
        #expect(
            css.contains("width: var(--tk-refresh); height: var(--tk-refresh);"),
            "the refresh button must size from --tk-refresh so the mirror spacer track can't drift from it and de-centre the title (CROW-924)")
        // Pin the title's own placement + alignment — the invariant this change exists for.
        // Both declarations are load-bearing and drop silently: without `text-align: center`
        // the title left-aligns in the 1fr track (the pre-CROW-924 look); without
        // `grid-column: 2` too, the title (first child) auto-places into the 22px spacer
        // track and ellipsises to nothing at the left edge. Anchor on the selector so a
        // revert of either fails here.
        #expect(
            css.contains(".tickets-title { grid-column: 2; text-align: center;"),
            "the title must sit in the centre track and centre its text there, or it auto-places into the 22px spacer (CROW-924)")
        // Pin the token's DEFINITION, not just its two consumers: an unresolvable var()
        // computes to the property's unset value — grid-template-columns → `none` (the
        // explicit grid vanishes, title no longer centred or ellipsising) and the button's
        // width/height → `auto` (collapses to the glyph, losing the CROW-797 stationary box).
        // stripComments drops the doc-comment mentions of the token, and `var(--tk-refresh)`
        // has no colon, so `--tk-refresh:` matches ONLY the declaration and fails if it's
        // deleted. Value-agnostic on purpose: the documented WCAG 2.5.8 bump (22px→28px)
        // stays a genuine one-token edit here rather than a two-place change in this test too.
        #expect(
            css.contains("--tk-refresh:"),
            "the --tk-refresh token both the head's spacer track and the button derive from must be defined, or the var() references resolve to `none`/`auto` (CROW-924)")
    }

    /// CROW-1020: the scrollbar policy, both halves of it.
    ///
    /// CROW-1016 read "the scrollbar is gone" as being about `#sidebar`/`#board`
    /// — those were the panes carrying CROW-593's hide rule — and #1019 gave
    /// them a permanent styled gutter. Wrong surface: what people grab is the
    /// TERMINAL's history thumb. So this pins the corrected split, in one test
    /// because the two halves are one decision and must not drift apart:
    ///
    ///   * the sidebar and board stay overlay chrome (hide rule restored);
    ///   * the terminal gets a bar you can see and grab.
    ///
    /// The terminal half needs BOTH of its pieces, and neither substitutes for
    /// the other. xterm 6 paints its slider from JS `theme` options (so the
    /// colour has to come from app.js, not CSS) and builds its scrollable
    /// element with `ScrollbarVisibility.Auto` (so the thumb fades out unless
    /// CSS pins it). Half of that leaves either an invisible bar or a
    /// disappearing one — which is the bug, twice over.
    @Test func sidebarStaysOverlayAndTerminalGetsAVisibleScrollbar() throws {
        // stripComments throughout: these rules' own doc comments name
        // `scrollbar-width: none`, `.has-scrollback` and both engines, so a
        // raw-file `contains` would false-pass off the prose once a declaration
        // is deleted (mutation-checked, like the CROW-924 pins above).
        let css = Self.stripComments(try Self.webAsset("app.css"))
        let appJS = Self.stripComments(try Self.webAsset("app.js"))

        // 1. Sidebar and board are back to scrolling without a gutter. Scoped to
        // the rule body so this fails if the hide migrates to some other pane
        // and leaves these two pinned open.
        let hide = try Self.ruleBody(openedBy: "#board, #sidebar {", in: css)
        #expect(
            hide.contains("scrollbar-width: none"),
            "the sidebar/board hide must stay: they are overlay chrome, and a permanent gutter is real width off a 350px sidebar (CROW-1020)")
        #expect(
            hide.contains("-ms-overflow-style: none"),
            "the legacy Edge/IE half of the hide belongs with it (CROW-1020)")
        #expect(
            try Self.ruleBody(openedBy: "#board::-webkit-scrollbar, #sidebar::-webkit-scrollbar {", in: css)
                .contains("width: 0"),
            "WebKit/Blink ignore scrollbar-width, so the pseudo-element half of the hide is not optional (CROW-1020)")

        // 2. The terminal's bar is pinned visible. `opacity` alone is not
        // enough — xterm.css's `.invisible` sets `pointer-events: none` too, so
        // dropping that line leaves a thumb you can see and cannot grab, which
        // is a subtler version of the same complaint.
        let termBar = try Self.ruleBody(
            openedBy: "#terminal-wrap.has-scrollback .xterm-scrollable-element > .scrollbar.vertical {",
            in: css)
        #expect(
            termBar.contains("opacity: 1"),
            "the terminal thumb must be pinned opaque, or xterm's Auto visibility fades it out whenever the pointer leaves (CROW-1020)")
        #expect(
            termBar.contains("pointer-events: auto"),
            "xterm.css's .invisible also kills pointer-events, so the thumb must be made grabbable and not merely visible (CROW-1020)")

        // 3. …and only while there is history. Ungated, the pin would paint a
        // permanent stripe down every empty terminal: xterm sizes the slider to
        // the FULL track when the bar is not needed. The class is toggled from
        // app.js off the buffer's baseY (behaviour covered by
        // web-tests/terminal-scrollbar.test.js); what this pins is that the CSS
        // still asks for it rather than matching #terminal-wrap outright.
        #expect(
            appJS.contains("classList.toggle('has-scrollback'"),
            "app.css gates the terminal thumb on .has-scrollback, so app.js must still be the thing that sets it (CROW-1020)")

        // 4. The colour handoff. xterm derives the slider from the FOREGROUND at
        // 0.20 alpha — 1.67:1 on #1e1e1e, under WCAG 2.2 §1.4.11's 3:1 — so
        // without an explicit theme the pinned bar is pinned invisible, and
        // every assertion above still passes.
        #expect(
            appJS.contains("scrollbarSliderBackground: '--scroll-thumb'"),
            "xterm paints its slider from JS theme options, so the thumb colour must be handed over there (CROW-1020)")
        #expect(
            appJS.contains("...scrollbarTheme()"),
            "scrollbarTheme() must actually reach the Terminal's theme, not just be defined (CROW-1020)")

        // 5. The tokens it reads must exist: a missing one is dropped rather
        // than sent as an empty string (xterm's css.toColor THROWS on that, at
        // construction), so this failing means a silently default-coloured bar.
        // `var(--scroll-…)` has no colon, so the trailing colon matches only the
        // declarations.
        for token in ["--scroll-thumb:", "--scroll-thumb-hover:", "--scroll-thumb-active:"] {
            #expect(
                css.contains(token),
                "the \(token.dropLast()) token app.js reads for xterm's slider must be defined (CROW-1020)")
        }
    }
}
