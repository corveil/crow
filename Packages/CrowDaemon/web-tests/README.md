# Web UI tests

Headless [jsdom](https://github.com/jsdom/jsdom) regression tests for the web
UI. They load the **real** classic client scripts from `Resources/web/` (concatenated
in `index.html` order by `load-client.js`) and drive their functions
against mocks — no running daemon required — then assert the result.

## `board.test.js` — Ticket Board (CROW-751)

Drives `renderTicketBoard` / `ticketCard` against mock board payloads and
asserts the resulting DOM. Coverage: repo filter, every sort mode,
status-pipeline + text-search composition, the label-name search fix, richer
card detail (author / created / comments / description excerpt + expand
toggle), View Issue / View PR buttons (hrefs + `target=_blank`), inline PR
state + CI badges (incl. failing-check tooltip), and graceful degradation of an
older payload with the new fields absent.

## `scorecard.test.js` — Manager metering on the scorecard (CROW-983)

Drives the real `renderScorecard` against a synthetic `ScorecardDTO` and
asserts the Manager card's DOM. Coverage: the widened chip set (active time,
cache hit ratio, tokens/prompt, API error rate, compactions/active hour, tool
calls, commits) and its formatting, the efficiency grade badge + deduction
line, the ungraded/below-floor degradation, per-Manager grouping (and the
absence of a heading for a single Manager), the `groupManagerWeeks` helper
including the fallback name for a deleted Manager, and graceful degradation
when a pre-#767 daemon sends no `managerWeeks` field at all.

Also pins the framing that keeps a Manager legible as *outside* the graded
aggregate: the "efficiency only" pill, the explainer naming the excluded
outcome surfaces, and the absence of any shipped count on a Manager row.

## `touch-scroll.test.js` — mobile terminal scroll (#777)

Drives `enableTouchScroll` against a fake xterm + PTY socket. Coverage: the
non-passive `touchmove` + `preventDefault` that stops iOS Safari's overscroll
from rubber-banding the same frame, local scrollback scrolling with sub-cell
accumulation, the alternate-screen branch (SGR wheel reports when the TUI has
mouse tracking on, cursor keys otherwise, capped per event), multi-touch
pass-through, and degenerate cell metrics.

## `wheel-scroll.test.js` — per-surface hybrid scroll (#824, ADR-0013)

Drives `enableWheelScroll` and `swallowMouseMode` against a fake xterm + PTY
socket. Coverage: the #776 invariant that the handler always consumes the wheel
(capture-phase, non-passive, `preventDefault`) on every surface; routing by
surface — a plain shell scrolls the local 50k scrollback and writes nothing to
the PTY, while an agent surface forwards SGR wheel reports (or cursor keys when
the app isn't mouse-tracking) and never scrolls locally; the legacy alt-buffer
and mouse-tracking signals still routing to the app; the conditional mouse-mode
swallow (swallowed on a shell, passed through on an agent surface, never
swallowing a non-mouse mode like `?25`), including xterm's params-object and
sub-parameter shapes; and graceful degradation when `activeTerminal` is null or
an older daemon omits `agent_surface`. CROW-1010: `applySurfaceScrollback` caps
xterm scrollback to 0 only for alt-buffer agents (`uses_alternate_screen`); an
inline agent (Cursor) keeps `UNIFIED_SCROLLBACK`.

## `long-press.test.js` — mobile terminal context menu (CROW-1006)

Drives the boot-time registration on `#terminal-wrap` against a fake xterm,
synthesised touch events, and a controllable clock. The grid is a canvas under
`user-select: none`, so a phone has no native selection or copy callout there —
Crow's own menu *is* the mobile context menu, and long-press is its only touch
entry point.

Coverage: a still 500ms press opens the menu at the touch point; the trailing
emulated click is swallowed so the tap never reaches xterm (and never closes the
menu it just opened); a drag past the 10px threshold cancels instead and leaves
`touchend` uncancelled, so an ordinary scroll drag keeps its native tap
semantics; a sub-threshold wobble still counts; multi-touch (pinch) arms
nothing; `Copy` appears only with a selection; the full touch-only `Select all`
→ `Copy` route that is the whole point of the ticket; the agent-surface
force-select hint; the pre-attach `term === null` guard; and the desktop
`contextmenu` path producing the same menu at the cursor.

## `key-handler.test.js` — terminal copy/paste keys (#875)

Drives `handleTerminalKey` and `pasteIntoTerminal` against a fake xterm +
clipboard. Coverage: the #875 regression — Cmd+V is left entirely to the
browser, so the native paste (which xterm already bracketed-paste-wraps) is the
only one that fires, instead of that plus an explicit `term.paste` for a double
paste; the right-click menu still pasting exactly once, and degrading without
throwing where `navigator.clipboard` is absent (plain http); Cmd/Ctrl+C copying
the selection and cancelling the browser default, while Ctrl+C with no
selection still falls through as SIGINT; Cmd+F cancelling the browser find bar
and opening ours; and non-keydown / unmodified keys passing through untouched.

## `session-switch-attach.test.js` — agent tab/session switch (CROW-1035)

Drives `attachWindow` against a fake xterm + a live `/terminal` socket. Coverage: switching to a Claude (alt-buffer) or Cursor (inline agent) surface is in-place — no new WebSocket, `clearTermBuffer` + `select-window` with `replay: false` on the existing socket, neither agent class arms the CROW-1027 heal on that path (no PTY resize; a second replay stacks Cursor chrome, CROW-1048); a plain shell still takes the #673 full reload; re-clicking the attached window is a no-op; a missing socket only records `attachedWindow`. Connect/reload still heals a one-screen attach (`terminal-reload.test.js`).

## `terminal-reload.test.js` — header ↻ Reload button (CROW-979)

Drives `renderHeader` and `reloadTerminalAction` against a fake xterm + a fake
`/terminal` socket whose `onopen` fires on demand. Coverage: the button renders
for work / review / job **and manager** sessions (managers previously got no
action cluster at all, since every other button sits inside the
`kind !== 'manager'` guard, and they have no tabs to hang a control off either);
disabled with nothing attached and enabled once `activeTerminal` binds; a click
resetting the xterm buffer, detaching the old socket's handlers *before* closing
it, and opening a fresh one; the `↻`-swapped-for-`.action-spinner` in-flight
treatment, both nodes boxed to the same 12×12 so the swap can't shift the button
(the CROW-797 tickets-refresh fix); the spinner settling when the socket opens,
and — because `onclose` retries with backoff forever — also settling via the
`TERMINAL_RELOAD_SETTLE_MS` timer when the socket never opens at all; the timer
being disarmed when `onopen` wins the race; double-tap coalescing; clicking with
no terminal (or no xterm) being a no-op rather than a throw; `showEmptyDetail`
dropping a pending reload with the session; and the pre-existing right-click
"Reload terminal" menu item still being present.

## `row.test.js` — sidebar session rows (CROW-773)

Drives `sessionRow`. Coverage: the PR pill's status glyphs for every
checks/review state, merged collapsing to a single purple check, the conflict
`⚠`, the `crow:merge` label `🏷` as a signal independent of the `⛙`
auto-merge-enabled glyph, the composed `aria-label`, graceful degradation when
the live `pr` entry is missing or `has_pr: false`, and the ticket-label pills
(2-pill cap + `+N` overflow, hidden under `hideSessionDetails`).

## `rpc-timeout.test.js` — JSON-RPC deadlines + late responses (#931)

Drives `rpc`, `rpcTimeoutFor`, `sessionAction` and `dismissModalDialog` against
a fake `/rpc` socket and a controllable timer queue. Coverage: the per-method
timeout table mirroring the CLI's (incl. the wire-name check — `crow job run`
sends `job-run` while Settings' "Run now" sends `run-job`, so both must be
listed) and the 30s default; a timeout rejecting with a tagged `err.rpcTimeout`
while *retaining* the pending entry rather than deleting it; a late response
routing to the `onLate` hook instead of vanishing into `onmessage`'s `!waiter`
guard; `sessionAction` showing a "Still running" advisory rather than a "failed"
modal, then dismissing it on late success, surfacing an additive `warning` (#888)
if one comes back, and replacing it with the real error on late failure;
`dismissModalDialog` refusing to yank a dialog that superseded its own;
`ws.onclose` rejecting unsettled calls and dropping settled ones without firing
`onLate`; and the settled-entry GC.

Unlike the other files, this one's fake `WebSocket` actually fires `onopen` (so
`rpcState.ready` resolves) and its `setTimeout`/`clearTimeout` are a controllable
queue rather than no-ops — deadlines have to fire on demand, and firing them *by
delay* is what proves each method was armed from the table.

## `rpc-close-code.test.js` — JSON-RPC close codes (CROW-956)

`crowd` caps an inbound WebSocket message and can only refuse an over-limit one
by *closing* with code 1009: no request id was ever decoded, so there is nothing
to correlate a JSON-RPC error reply to. That close used to be indistinguishable
from a crashed daemon — both rejected in-flight calls with "rpc: connection
closed" and reconnected a second later — which is what made an unsavable
Settings tab so hard to diagnose.

Coverage: a 1009 close rejecting in-flight calls with a message naming the
method, "too large", and the code, tagged `err.rpcTooLarge` / `err.rpcMethod`
like the timeout rejection; **every other close still reading exactly as it did**
(no code and 1006 both keep the verbatim `rpc: connection closed`, untagged);
settled entries still dropped without firing `onLate`; and the reconnect still
being armed afterwards — 1009 is per-*message*, not per-connection, so refusing
to reconnect would take the whole UI offline over one oversized payload.

Same harness as `rpc-timeout.test.js`, with one deviation: this file's fake
`close(code)` delivers a CloseEvent-shaped `{code, reason, wasClean}` argument,
which is the subject under test. The other suites' fakes call `onclose` with no
argument at all, which is exactly why `app.js` guards on `!!event` before reading
`event.code`.

## `router.test.js` — hash URL routing (CROW-936)

Drives `parseRoute` / `routeToHash` / `navigate` / `applyRoute` / `onHashChange`
against mocks, plus the selection functions the router goes through. Coverage:
every published route shape (home, session, session+terminal, all four boards,
settings tabs) and the malformed ones that must degrade rather than throw;
`routeToHash` round-trips including percent-encoded ids; `navigate` pushing a
history entry, no-oping on an identical route, `replace` not pushing, and
invalidating a still-deferred deep link so a click during cold load wins; a cold
deep link deferring until `sessionsLoaded` can tell "deleted" from "not loaded
yet"; the not-found state for a reaped session (both on cold load and live,
mid-session); `showHome` restoring the default empty state; the terminal segment
written by `switchTerminal` (and not written without a selection); the URL being
re-pointed whenever it names a terminal the session no longer has — a dead id
from the link *or* a tab closed from another client; re-selecting the open
session keeping its `/t/<id>`; Back applying a route without pushing a duplicate
entry; **Back escaping a session after a tab switch** — the one sequence every
session visit produces, driven through a small history model since jsdom doesn't
model Back against a vm context; dead-end destinations (an unknown settings tab,
the session you just deleted) replacing rather than pushing; and routing away
from a dirty Settings modal prompting exactly like ✕ does, restoring the URL
when the user cancels.

Loads the real `app.js` at a deep-link `url:` to exercise the cold-load path —
jsdom's `url` option is what makes `location.hash` real at boot. The Settings
assertions additionally load the real settings scripts (`settings-*.js` + `settings.js`) into the
same context, the way `index.html` does, so `openSettings` / `setSettingsTab` are the shipped
implementations rather than stubs — the tab-routing bug they guard (a re-entry
that silently reset `dirty`) is invisible to a stub.

## `version-banner.test.js` — version-update banner (#942)

Drives `renderVersionUpdateBanner` / `refreshVersionUpdateBanner` against
mock `localStorage` and `rpc`, with the real `app.css` injected so assertions
use computed style (not just the `hidden` property). Coverage: `[hidden]`
genuinely hides the flex banner, behind/up-to-date toggling, SHA dismiss
surviving a poll, a new SHA re-showing, the `setItem`-throws path with stale
storage, no-SHA session dismiss resetting when a SHA arrives, `getItem` throws
not blocking render or in-memory dismiss, and RPC failure hiding the banner.

## `grid.test.js` — Session grid (CROW-1153)

Drives `gridRoster` / pin helpers / `renderSessionGrid` against mock sessions.
Coverage: column count (1 / 2×2 / 3×3 / 4×4), pinned-first roster with
active auto-fill and activity sort, pin persist + reorder in `localStorage`,
the Grid nav pill, Pin/Unpin on the session menu, `#/grid` routing, empty
state copy, and cell DOM (pinned class, name, column count). Snapshot
painting is skipped — jsdom has no xterm.js, matching a failed asset fetch.

## Run

Tests must not evaluate a single concern file in isolation: `load-client.js`
concatenates every classic script in `index.html` order (settings.js and settings-*.js optional)
so `let`/`const` bindings stay shared, matching the browser.

```sh
cd Packages/CrowDaemon/web-tests
npm ci          # once — installs jsdom at the locked version (dev-only, not shipped)
npm test
```

Exit code is non-zero if any assertion fails.

`package-lock.json` **is** committed (and `npm ci` used in CI) because this suite
now gates every PR — with it ignored, a `jsdom` patch release could turn an
unrelated PR red.

### `npm test` vs `npm run test:ci`

`test` runs everything. `test:ci` is the same list **minus `row.test.js`**, and is
what `.github/workflows/ci.yml` runs.

`row.test.js` has 10 pre-existing failures on `main` — its own comment (above
`pillIcons`) names the cause: CROW-802 moved PR status parts to SVG `.ico` spans,
but the `r.glyphs` assertions still read text-only `.pr-ico`, so they assert on
glyphs that are no longer text. Fixing them means deciding what the icons *should*
render, which is a change to `row`, not to the harness. Until someone makes that
call, gating CI on the whole suite would land every PR red — so CI runs the nine
green files and this note exists so the exclusion can't quietly become permanent.

Note the exclusion drops the file **wholesale**, so its 43 *passing* assertions
stop gating too. Whoever repairs the 10 should re-add `row` to `test:ci` in the
same change — the win is restoring 43, not just fixing 10.

> This is a Node-based harness kept separate from the Swift `swift test` suite;
> `node_modules/` here is git-ignored and not part of the app bundle.
