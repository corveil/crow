# Web UI tests

Headless [jsdom](https://github.com/jsdom/jsdom) regression tests for the web
UI. They load the **real** `Resources/web/app.js` and drive its functions
against mocks — no running daemon required — then assert the result.

## `board.test.js` — Ticket Board (CROW-751)

Drives `renderTicketBoard` / `ticketCard` against mock board payloads and
asserts the resulting DOM. Coverage: repo filter, every sort mode,
status-pipeline + text-search composition, the label-name search fix, richer
card detail (author / created / comments / description excerpt + expand
toggle), Open Issue / Open PR buttons (hrefs + `target=_blank`), inline PR
state + CI badges (incl. failing-check tooltip), and graceful degradation of an
older payload with the new fields absent.

## `touch-scroll.test.js` — mobile terminal scroll (#777)

Drives `enableTouchScroll` against a fake xterm + PTY socket. Coverage: the
non-passive `touchmove` + `preventDefault` that stops iOS Safari's overscroll
from rubber-banding the same frame, local scrollback scrolling with sub-cell
accumulation, the alternate-screen branch (SGR wheel reports when the TUI has
mouse tracking on, cursor keys otherwise, capped per event), multi-touch
pass-through, and degenerate cell metrics.

## Run

```sh
cd Packages/CrowDaemon/web-tests
npm install     # once — pulls jsdom (dev-only, not shipped in the app)
npm test
```

Exit code is non-zero if any assertion fails.

> This is a Node-based harness kept separate from the Swift `swift test` suite;
> `node_modules/` here is git-ignored and not part of the app bundle.
