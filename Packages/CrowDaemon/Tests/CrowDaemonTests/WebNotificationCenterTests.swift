import Foundation
import Testing
@testable import CrowDaemon

/// Drift guard for the notification center served out of `Resources/web/notifications.js`
/// and `sidebar.js` (CROW-909 / CROW-1155). There's no JS test runner in this repo, so — like
/// `WebTerminalAssetTests` — these pin the non-obvious invariants of the feature
/// against the classic client source a reviewer actually edits. The bugs each one
/// guards were all live at first review (PR #910): a detached-anchor mispositon,
/// a poisoned-cache render wedge, a multi-tab last-writer-wins clobber, and a
/// dedup gap.
@Suite struct WebNotificationCenterTests {
    /// Walk up to `Resources/web/<name>` and read it (the assets are `.copy`d, so
    /// the repo copy is the source of truth). Mirrors `WebTerminalAssetTests`.
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

    /// Every classic client script in `index.html` order (CROW-1155). Function
    /// greps follow the split; a collision across files is the same silent-win
    /// bug as two `function foo(` in the old monolith.
    private static func webClientJS(includingSettings: Bool = false) throws -> String {
        let names = includingSettings
            ? StaticAssets.uiJavaScriptFiles
            : StaticAssets.uiJavaScriptFiles.filter { $0 != "settings.js" && !$0.hasPrefix("settings-") }
        return try names.map { try webAsset($0) }.joined(separator: "\n")
    }

    /// The body of a top-level `function <name>(` … `\n}` block, so an assertion
    /// is about one handler rather than the whole file. Same shape as
    /// `WebTerminalAssetTests.functionBody`.
    private static func functionBody(_ name: String, in source: String) throws -> Substring {
        let start = try #require(source.range(of: "function \(name)("), "no \(name)")
        let rest = source[start.upperBound...]
        let end = try #require(rest.range(of: "\n}\n"), "unterminated \(name)")
        return rest[..<end.lowerBound]
    }

    /// `source` with `/* … */` and `//` comments removed, for negative
    /// assertions where the prose legitimately names the thing the code must not
    /// do. Copied from `WebTerminalAssetTests.stripComments`.
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

    /// Every event funnels through `emitEvent`, so the history append lives there
    /// — the one chokepoint the whole feature hangs off. If this call is dropped,
    /// nothing is ever recorded and the bell stays permanently empty.
    @Test func emitEventRecordsToTheCenter() throws {
        let body = try Self.functionBody("emitEvent", in: Self.webClientJS())
        #expect(
            body.contains("recordNotification(event, key, detail)"),
            "emitEvent must append to the history, not just play the sound/banner")
    }

    /// The Red from review: `renderSidebar()` does `root.innerHTML = ''` and
    /// rebuilds the tools stack, detaching the `bell` passed in as the anchor. A
    /// detached node measures all-zeros, so the panel must capture
    /// getBoundingClientRect BEFORE the seen-marking repaint or it clamps to the
    /// viewport corner instead of under the bell — and that path fires exactly
    /// when the badge is showing, i.e. the normal reason to open it.
    @Test func panelMeasuresAnchorBeforeTheSeenMarkingRepaint() throws {
        let body = String(try Self.functionBody("openNotificationPanel", in: Self.webClientJS()))
        let measure = try #require(body.range(of: "getBoundingClientRect("), "panel must measure the anchor")
        let repaint = try #require(body.range(of: "renderSidebar()"), "panel must repaint after marking seen")
        #expect(
            measure.lowerBound < repaint.lowerBound,
            "the anchor rect must be captured before renderSidebar() detaches the bell")
    }

    /// The Yellow that wedges the sidebar: `restoreNotifHistory` must drop
    /// non-object entries, or a parseable-but-wrong array (`[null, …]`, a foreign
    /// schema) lets a later `e.seen` read throw inside notifUnreadCount →
    /// sidebarSignature → every renderSidebar, and the sidebar stays dead until
    /// the key is cleared by hand.
    @Test func restoreFiltersPoisonedEntries() throws {
        let body = try Self.functionBody("restoreNotifHistory", in: Self.webClientJS())
        #expect(
            body.contains("typeof e === 'object'"),
            "restore must filter to plain objects so a poisoned array can't wedge the render")
    }

    /// The boot recovery path must reset `notifHistory` too, not only the sidebar
    /// cache — otherwise a poisoned history survives into the retry render (and
    /// every later poll-driven render, some outside a try) and the recovery
    /// itself re-throws.
    @Test func bootCatchResetsTheHistory() throws {
        let source = Self.stripComments(try Self.webAsset("app.js"))
        // The boot recovery block is the only place that clears the sidebar cache
        // and resets `sessions` back-to-back — anchor on that pair so a different
        // clearSidebarCache() caller (the logout button) isn't matched.
        let anchor = try #require(
            source.range(of: "clearSidebarCache();\n  sessions = [];"),
            "no boot recovery block")
        let window = source[anchor.lowerBound...].prefix(200)
        #expect(
            window.contains("notifHistory = []"),
            "the boot catch must reset notifHistory so a poisoned key self-heals")
    }

    /// The multi-tab Yellow: localStorage is per-origin, so `recordNotification`
    /// must re-read the shared store before appending (compose, not clobber a
    /// concurrent tab), and a `storage` listener must re-sync this tab. Without
    /// both, tabs silently drop each other's entries and the badge re-inflates.
    @Test func recordReReadsAndTabsStayInSync() throws {
        let source = try Self.webClientJS()
        let body = try Self.functionBody("recordNotification", in: source)
        #expect(
            body.contains("restoreNotifHistory();"),
            "record must re-read the shared store before appending (multi-tab compose)")
        #expect(
            source.contains("addEventListener('storage'"),
            "a storage listener must re-sync history across tabs on the same origin")
    }

    /// Record-time dedup mirroring the sound/banner channels' 2s per-(key,event)
    /// window — a flapping poll or repeated server push produced duplicate popups
    /// there, and would produce duplicate rows here.
    @Test func recordDedupsWithinTwoSeconds() throws {
        let body = try Self.functionBody("recordNotification", in: Self.webClientJS())
        #expect(
            body.contains("_lastRecordAt[k]") && body.contains("< 2000"),
            "record must carry the same 2s per-(key,event) dedup as the sibling channels")
    }

    /// The unread count is not store-backed, so it must be named in
    /// `sidebarSignature` or an appended notification never repaints the badge
    /// (the signature guard would short-circuit the render).
    @Test func unreadCountIsInTheSidebarSignature() throws {
        let body = try Self.functionBody("sidebarSignature", in: Self.webClientJS())
        #expect(
            body.contains("notifUnreadCount()"),
            "sidebarSignature must include the unread count so the badge repaints")
    }

    /// External navigation is gated: `classifyNotification` only tags an entry
    /// `url` after an http(s) scheme test, so `javascript:`/`data:` keys can never
    /// reach window.open, and the open severs the opener. Both must hold.
    @Test func externalOpenIsSchemeGuardedAndOpenerSevered() throws {
        let source = try Self.webClientJS()
        let classify = try Self.functionBody("classifyNotification", in: source)
        #expect(
            classify.contains(#"/^https?:\/\//.test(key)"#),
            "only http(s) keys may be classified as an external URL")
        let nav = try Self.functionBody("navigateToNotification", in: source)
        #expect(
            nav.contains("'_blank', 'noopener'"),
            "external open must sever the opener reference")
        #expect(
            nav.contains(#"/^https?:\/\//.test(entry.target)"#),
            "the stored target's scheme must be re-tested at click time (defense-in-depth)")
    }

    /// The panel renders every user/server string through `el(...)` (textContent),
    /// never innerHTML — the property that keeps a hostile PR title / issue body
    /// from being an XSS vector.
    @Test func panelBuildsRowsWithoutInnerHTML() throws {
        let body = Self.stripComments(String(
            try Self.functionBody("openNotificationPanel", in: Self.webClientJS())))
        #expect(
            !body.contains("innerHTML"),
            "the panel must not use innerHTML — user/server strings go through el()'s textContent")
    }

    /// Second-round Red 1: the outside-click closer must be removable, not
    /// `{ once: true }`. A click inside a menu that stopPropagations never reaches
    /// document, so a once-listener stays armed with no menu on screen and the
    /// next open's click bubbles up and tears the fresh menu straight down. Every
    /// menu opener must arm through the shared helper, and closeContextMenu must
    /// remove the handle — so no site is left on the leaky pattern.
    @Test func outsideClickCloserIsRemovableNotOnce() throws {
        let source = try Self.webClientJS()
        #expect(
            !source.contains("closeContextMenu, { once: true }"),
            "no menu may arm the outside-click close as a leaky { once: true } listener")
        #expect(
            try Self.functionBody("closeContextMenu", in: source)
                .contains("removeEventListener('click', _ctxMenuCloser)"),
            "closeContextMenu must remove the armed outside-click listener")
        // Every left-click/anchored menu opener arms through the one helper.
        let arms = source.components(separatedBy: "armContextMenuClose();").count - 1
        #expect(arms >= 6, "all menu openers must arm via armContextMenuClose(); found \(arms)")
    }

    /// Second-round Red 2: the notification history holds the same class of data
    /// as the sidebar cache (session names, PR/issue titles, issue URLs), so it
    /// must be purged at both auth boundaries — otherwise the next user on a
    /// shared browser can open the bell and read the previous user's workspace.
    /// One helper drops both keys; both the logout and cookie-death paths call it.
    @Test func authBoundariesPurgeTheNotificationHistory() throws {
        let source = try Self.webClientJS()
        let helper = try Self.functionBody("purgeSharedBrowserCaches", in: source)
        #expect(
            helper.contains("clearSidebarCache()") && helper.contains("removeItem(NOTIF_HISTORY_KEY)"),
            "the purge helper must drop BOTH the sidebar cache and the notif history key")
        #expect(
            try Self.functionBody("handleAuthOnDisconnect", in: source)
                .contains("purgeSharedBrowserCaches()"),
            "the cookie-death path must purge the shared caches")
        // The logout handler is an inline onclick, not a named function — assert
        // there are at least two call sites (logout + cookie death), and that the
        // boot-catch recovery is NOT one of them (it must keep a valid history).
        let calls = source.components(separatedBy: "purgeSharedBrowserCaches();").count - 1
        #expect(calls >= 2, "both auth boundaries must call the purge helper; found \(calls)")
    }

    /// Second-round Yellow 3: the center honors the MASTER notification levels —
    /// globalMute and the per-event `enabled` toggle — so a muted / switched-off
    /// event doesn't pile up an un-opt-out-able badge. The sub-toggles and focus
    /// rule stay bypassed (the log isn't an interruption); this only pins the two
    /// master gates.
    @Test func recordHonorsGlobalMuteAndThePerEventToggle() throws {
        let body = try Self.functionBody("recordNotification", in: Self.webClientJS())
        #expect(body.contains("N.globalMute"), "record must respect global mute")
        #expect(
            body.contains("cfg.enabled === false"),
            "record must respect the per-event master toggle")
    }

    /// Second-round Yellow 4: appends coalesce to one sidebar repaint per task,
    /// not one per event — a detector tick transitioning k sessions must not do k
    /// full innerHTML rebuilds. record must schedule (not call renderSidebar
    /// directly), and the scheduler must use a microtask so onServerNotify still
    /// paints within the turn.
    @Test func recordCoalescesTheSidebarRepaint() throws {
        let source = try Self.webClientJS()
        let body = try Self.functionBody("recordNotification", in: source)
        #expect(
            body.contains("scheduleNotifRepaint()"),
            "record must schedule a coalesced repaint")
        #expect(
            !body.contains("renderSidebar()"),
            "record must not call renderSidebar() directly per event")
        #expect(
            try Self.functionBody("scheduleNotifRepaint", in: source).contains("Promise.resolve().then"),
            "the repaint must coalesce on a microtask")
    }

    /// Third-round Red 1: app.js is loaded as a classic <script>, so two top-level
    /// `function foo(` declarations in one scope don't error — the LATER one
    /// silently wins for every call. The new `notifRelTime(ts)` (epoch ms) shipped
    /// as `relTime`, colliding with the pre-existing `relTime(iso)` card helper, so
    /// every panel timestamp resolved to the ISO version and rendered empty. Guard
    /// the whole class rather than the instance: assert no duplicate top-level
    /// function names. (A per-function assertion can't catch it — `functionBody`
    /// matches the first declaration, i.e. the dead one.)
    @Test func noDuplicateTopLevelFunctionNames() throws {
        let source = try Self.webClientJS(includingSettings: true)
        var counts: [String: Int] = [:]
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            // Top-level declarations start at column 0 — nested/method functions and
            // function expressions are indented or preceded by `= `/`(`.
            for prefix in ["function ", "async function "] where rawLine.hasPrefix(prefix) {
                let after = rawLine.dropFirst(prefix.count)
                guard let paren = after.firstIndex(of: "(") else { break }
                let name = after[..<paren]
                if !name.isEmpty,
                   name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }) {
                    counts[String(name), default: 0] += 1
                }
                break
            }
        }
        let dups = counts.filter { $0.value > 1 }.keys.sorted()
        #expect(
            dups.isEmpty,
            "duplicate top-level function name(s) across classic client scripts — in a classic <script> the later declaration silently wins for every call: \(dups)")
    }

    /// Third-round Yellow 2: restoreNotifHistory must treat a MISSING key as
    /// "empty", not "no change". A purge in another tab fires a storage event with
    /// newValue === null; an early return would leave this tab's stale in-memory
    /// history intact, which its next seen-marking would persist straight back —
    /// re-creating the key logout just dropped. The `notifRelTime` rename must have
    /// landed too (no lingering epoch-ms call to the ISO `relTime`).
    @Test func restoreTreatsMissingKeyAsEmptyAndTimestampUsesTheRenamedHelper() throws {
        let source = try Self.webClientJS()
        #expect(
            try Self.functionBody("restoreNotifHistory", in: source)
                .contains("if (!raw) { notifHistory = []; return; }"),
            "a removed key must reset the in-memory history, so a cross-tab purge can't be re-persisted")
        #expect(
            source.contains("notif-time', notifRelTime(entry.ts)"),
            "the panel timestamp must call the renamed epoch-ms helper, not the ISO relTime")
    }
}
