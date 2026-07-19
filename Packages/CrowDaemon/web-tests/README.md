# Web Ticket Board tests

Headless [jsdom](https://github.com/jsdom/jsdom) regression tests for the web
**Ticket Board** (CROW-751). They load the **real** `Resources/web/app.js` and
drive `renderTicketBoard` / `ticketCard` against mock board payloads — no
running daemon required — then assert the resulting DOM.

Coverage: repo filter, every sort mode, status-pipeline + text-search
composition, the label-name search fix, richer card detail (author / created /
comments / description excerpt + expand toggle), Open Issue / Open PR buttons
(hrefs + `target=_blank`), inline PR state + CI badges (incl. failing-check
tooltip), and graceful degradation of an older payload with the new fields
absent.

## Run

```sh
cd Packages/CrowDaemon/web-tests
npm install     # once — pulls jsdom (dev-only, not shipped in the app)
npm test
```

Exit code is non-zero if any assertion fails.

> This is a Node-based harness kept separate from the Swift `swift test` suite;
> `node_modules/` here is git-ignored and not part of the app bundle.
