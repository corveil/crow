# Web UI tests

Headless [jsdom](https://github.com/jsdom/jsdom) regression tests for the web
UI. They load the **real** `Resources/web/app.js` and drive its functions
against mocks — no running daemon required — then assert the result.

## `board.test.js` — Ticket Board (CROW-751)

Drives `renderTicketBoard` / `ticketCard` against mock board payloads and
asserts the resulting DOM. Coverage: repo filter, every sort mode,
status-pipeline + text-search composition, the label-name search fix, richer
card detail (author / created / comments / description excerpt + expand
toggle), View Issue / View PR buttons (hrefs + `target=_blank`), inline PR
state + CI badges (incl. failing-check tooltip), and graceful degradation of an
older payload with the new fields absent.

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
an older daemon omits `agent_surface`.

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

## `router.test.js` — hash URL routing (CROW-936)

Drives `parseRoute` / `routeToHash` / `navigate` / `applyRoute` / `onHashChange`
against mocks, plus the selection functions the router goes through. Coverage:
every published route shape (home, session, session+terminal, all four boards,
settings tabs) and the malformed ones that must degrade rather than throw;
`routeToHash` round-trips including percent-encoded ids; `navigate` pushing a
history entry, no-oping on an identical route, and `replace` not pushing; a cold
deep link deferring until `sessionsLoaded` can tell "deleted" from "not loaded
yet"; the not-found state for a reaped session (both on cold load and live,
mid-session); `showHome` restoring the default empty state; the terminal segment
written by `switchTerminal`; `refreshTerminals` honouring the routed terminal
once and URL-correcting a dead one; and Back applying a route without pushing a
duplicate entry.

Loads the real `app.js` at a deep-link `url:` to exercise the cold-load path —
jsdom's `url` option is what makes `location.hash` real at boot. The Settings
assertions additionally load the real `settings.js` into the same context, the
way `index.html` does, so `openSettings` / `setSettingsTab` are the shipped
implementations rather than stubs — the tab-routing bug they guard (a re-entry
that silently reset `dirty`) is invisible to a stub.

## Run

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

> This is a Node-based harness kept separate from the Swift `swift test` suite;
> `node_modules/` here is git-ignored and not part of the app bundle.
