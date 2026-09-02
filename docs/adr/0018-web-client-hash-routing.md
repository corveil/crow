# 0018 — The web client routes on the URL fragment (hash routing)

- **Status:** Accepted
- **Date:** 2026-08-04
- **Deciders:** @danny, Claude

## Context

The web client rendered every view from in-memory state at a single static URL. Selecting a session,
switching terminal tabs, opening a board or Settings changed nothing in the address bar, so there was
no deeplinking, no bookmarking, Back left the app instead of going back a screen, and a reload always
returned to "Select a session" ([#936](https://github.com/corveil/crow/issues/936)).

Adding routing meant first choosing where the route lives, and the two options are not
interchangeable here.

`crowd` serves the web UI from `StaticAssets.mount` as a set of **exact literal paths** — `/`,
`/index.html`, `/login`, `/app.js`, `/app.css`, the CROW-1155 concern scripts (`/rpc.js`,
`/notifications.js`, …), the CROW-1160 Settings tab scripts (`/settings-general.js`, …) plus the
Settings shell `/settings.js`, `/settings.css`, `/brand.svg`,
`/version.json`, `/terminal.html`, `/xterm/:file` — plus `/artifacts/:session/:file`, `/autostart`,
and `/auth/*` from their own mounters. There is no wildcard, no catch-all, and no `FileMiddleware`.
Hummingbird answers anything unmatched with a bare 404.

That makes History-API routing a server change, not a client one, and the server it changes is
awkward in three specific ways:

- **The auth middleware inverts the failure.** `WebAuthMiddleware` wraps every route and returns the
  login page with HTTP 200 for any navigational GET
  (`serveLoginPageForUnauthorized`: `method == .get && accept.contains("text/html")`). So an
  *unauthenticated* `GET /sessions/<id>` renders login, while an *authenticated* one falls through to
  the router and 404s — the deep link works only when you are logged out.
- **A catch-all has to not swallow the rest.** `/login`, `/logout`, `/health`, `/brand.svg`,
  `/artifacts/*`, `/xterm/*`, `/autostart`, `/auth/*`, and the `/rpc` + `/terminal` websockets all
  have to keep matching first, and `appliesCSP(to:)` keys on the literal filename `"index.html"`, so
  the fallback has to route back through `webResponse("index.html", …)` to keep its CSP.
- **The desktop shell reloads to a path it cannot serve.** `crow-desktop` is a Tauri window pointed at
  the daemon (ADR [0010](./0010-retire-the-macos-app.md) — the web UI is the only client), and
  `src-tauri/src/lib.rs` calls `window.location.reload()`. Under History routing that re-requests the
  deep path and hits the same 404.

A fragment has none of these problems: it never leaves the browser, so `/` is the only path ever
requested.

## Decision

The web client routes on the URL **fragment**. Routes are:

```
#/                                   home / empty state
#/sessions/:sessionId
#/sessions/:sessionId/t/:terminalId
#/tickets  #/reviews  #/scorecard  #/grid
#/settings/:tab
```

The router lives in `router.js` (`parseRoute` / `routeToHash` / `navigate` / `applyRoute` /
`onHashChange`) — a classic script loaded before the `app.js` boot assembler. `script-src 'self'`
forbids inline bootstrapping, and the router reads and writes the shared selection state declared
in `sidebar.js`.

Routed navigation goes **through the existing selection functions** (`selectSession`, `selectBoard`,
`switchTerminal`, `openSettings`) rather than beside them, so a URL and a click cannot disagree.
`navigate()` is a no-op when the computed hash already matches, which is what keeps applying a route
from pushing a second history entry.

That invariant only holds if applying a route and initiating one stay distinguishable. A click may
enrich the URL from current state — re-selecting the session you're on keeps its `/t/<id>` — but a
call that is *applying* a URL must treat that URL as authoritative and synthesize nothing, or the
`navigate()` no-op becomes a push. `selectSession(id, { fromRoute: true })` marks the difference.
Getting this wrong walled Back inside a session: every visit leaves `#/sessions/A` followed by
`#/sessions/A/t/T`, and re-pushing `/t/T` while applying the bare entry truncated the forward entry
so Back could never move past it.

Only the addressable view is encoded. Scroll position, open menus, selection mode, and board filters
stay out of the URL.

What pushes a history entry and what replaces one is a deliberate split, not an accident of where the
code happened to land. **Pushes:** opening and closing Settings, switching terminal tabs, selecting a
session or board — each is a view the user chose and should be able to Back out of. **Replaces:**
Settings sub-tab switches inside an already-open modal, and every URL *correction* the app makes on
the user's behalf — normalizing an unroutable hash, dropping a terminal id the session no longer has,
and landing home after deleting the session you were viewing. The test is whether Back returning
there would be useful: a sub-tab is UI noise, and a corrected or dead-end URL is somewhere the user
can never meaningfully return to.

An unknown or stale id resolves to an explicit not-found state rather than a blank pane; Crow's
retention reaper deletes completed sessions, so a dead link is the *expected* fate of a shared URL,
not an edge case. That card echoes the offending id back only when it matches the UUID shape a
session id actually has — it is the surface a shared, stale link lands on, so unbounded
attacker-chosen text there would render as Crow's own explanation.

**`crowd` is unchanged.** No Swift file is touched by this decision.

## Consequences

**Easier:** sessions, terminals, boards and Settings tabs are linkable, bookmarkable and survive a
reload; Back/Forward move between views; the change is web-assets-only, so it ships without a daemon
rebuild (ADR 0010) and lands in the Tauri shell at the same time; a logged-out recipient of a deep
link keeps it through login, because the auth middleware serves the login page *at the requested URL*
and `login.html` now hands the fragment back.

**Harder / must live with:** URLs carry a `#`, which is less tidy than a real path and is dropped by
some link-shorteners and chat unfurlers. The fragment is invisible to the server, so `crowd` can never
do anything route-aware (server-side redirects, per-view auth, SSR, analytics) without revisiting
this. Terminal ids are only meaningful on the machine that owns the tmux server, so a
`#/sessions/…/t/…` link shared across machines silently degrades to the session's first tab —
deliberate, but it means the terminal segment is a convenience, not a guarantee.

Moving to History routing later is a contained change — swap `location.hash` for `pushState`, keep
`parseRoute`/`applyRoute` as they are — plus the daemon catch-all and its exclusion list.

## Alternatives considered

- **History API (`/sessions/<id>`):** rejected for now — it needs a catch-all in `StaticAssets.swift`
  that must not swallow `/login`, `/artifacts/*`, `/xterm/*`, `/autostart`, `/auth/*` or the two
  websocket upgrades, has to preserve the filename-keyed CSP, and still leaves the Tauri
  `location.reload()` path 404ing. Real cost, no user-visible gain beyond a prettier URL.
- **A routing library (react-router et al.):** rejected — there is no bundler, no module system and no
  framework; `index.html` loads classic scripts in order. A ~150-line router is smaller than the toolchain
  needed to install one.
- **Persist the last view in `localStorage` instead:** rejected — it restores *your* place on reload
  but gives no shareable link, no Back/Forward, and no bookmarking, which is most of the ask.
- **Put transient state (scroll, filters, selection mode) in the URL too:** rejected — it makes every
  incidental interaction a history entry and turns Back into an undo stack for UI noise.

## References

- PR: https://github.com/corveil/crow/pull/937 (CROW-936)
- Related ADRs: [0010](./0010-retire-the-macos-app.md) (the web UI is the only client — so this is
  the only routing model there is), [0009](./0009-crowd-sole-authority-clients-only.md) (`crowd` is
  the authority; routing is pure client state)
- Code: `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/router.js` (router),
  `…/Resources/web/sidebar.js` (selection state), `…/Resources/web/app.js` (boot),
  `…/Resources/web/settings.js` (tab routing; tab bodies in `settings-*.js`, CROW-1160), `…/Resources/web/login.html` (fragment survives login),
  `Packages/CrowDaemon/Sources/CrowDaemon/StaticAssets.swift` (the literal-path route table this
  decision is shaped by — unchanged)
- Test: `Packages/CrowDaemon/web-tests/router.test.js`, run in CI by the `parity` job
