'use strict';
// Crow web UI — Hash router (CROW-936, ADR 0018). Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// URL routing (CROW-936)
//
// Hash-based, deliberately. `crowd` registers only exact literal paths
// (StaticAssets.swift) with no catch-all, so an *authenticated* cold load of a
// History-API path like /sessions/<id> would 404 in Hummingbird before ever
// reaching this file — while an unauthenticated one renders the login page (the
// auth middleware short-circuits with a 200), which is the confusing inverse of
// what you want. A fragment never leaves the browser, so `/` always resolves and
// the daemon needs no change at all. See docs/adr/0018-web-client-hash-routing.md.
//
//   #/                                   home / empty state
//   #/sessions/:sessionId
//   #/sessions/:sessionId/t/:terminalId
//   #/tickets  #/reviews  #/allowlist  #/scorecard  #/grid
//   #/settings/:tab
//
// Only the addressable view lives in the URL — scroll position, open menus,
// selection mode and board filters stay out of it on purpose.
// ---------------------------------------------------------------------------
const ROUTE_BOARDS = ['tickets', 'reviews', 'allowlist', 'scorecard', 'grid'];
// Mirrors TABS in settings.js. An unknown tab degrades to 'general' rather than
// 404ing, so a link from an older/newer build still opens Settings.
const ROUTE_SETTINGS_TABS = [
  'general', 'automation', 'workspaces', 'jobs', 'notifications', 'webaccess', 'integrations', 'about',
];

// The exact hash we last wrote ourselves. `location.hash = …` fires hashchange
// asynchronously; re-applying the route we just applied would re-run
// selectSession → refreshTerminals → attachWindow and tear down a live terminal
// socket for nothing. Matching on the value (not a bare boolean) means a hash
// someone else changed in the same tick is still honoured.
let selfWroteHash = null;
// A session route that arrived before the first list-sessions landed. `sessions`
// can be pre-filled from the localStorage sidebar cache, so membership alone
// cannot tell "deleted" from "not loaded yet" — only `sessionsLoaded` can.
let pendingRoute = null;
// Terminal id from the URL, consumed once by the next refreshTerminals.
let pendingTerminalId = null;

// Hash → route object, or null when it matches nothing (caller normalizes to
// home). Segments are decoded, so an id containing %2F survives the round-trip.
function parseRoute(hash) {
  const parts = String(hash || '').replace(/^#\/?/, '').split('/').filter(Boolean);
  let seg;
  try { seg = parts.map(decodeURIComponent); } catch (_) { return null; } // malformed %-escape
  if (!seg.length) return { view: 'home' };
  if (seg[0] === 'sessions' && seg[1]) {
    if (seg.length === 2) return { view: 'session', sessionId: seg[1] };
    if (seg.length === 4 && seg[2] === 't') {
      return { view: 'session', sessionId: seg[1], terminalId: seg[3] };
    }
    return null;
  }
  if (seg.length === 1 && ROUTE_BOARDS.indexOf(seg[0]) !== -1) {
    return { view: 'board', board: seg[0] };
  }
  if (seg[0] === 'settings' && seg.length <= 2) {
    return { view: 'settings', tab: ROUTE_SETTINGS_TABS.indexOf(seg[1]) !== -1 ? seg[1] : 'general' };
  }
  return null;
}

function routeToHash(route) {
  if (!route) return '#/';
  if (route.view === 'session' && route.sessionId) {
    return '#/sessions/' + encodeURIComponent(route.sessionId)
      + (route.terminalId ? '/t/' + encodeURIComponent(route.terminalId) : '');
  }
  if (route.view === 'board' && route.board) return '#/' + route.board;
  if (route.view === 'settings') return '#/settings/' + (route.tab || 'general');
  return '#/';
}

function currentRoute() { return parseRoute(location.hash); }

// Write `route` to the address bar. A no-op when the hash already matches —
// which is what lets the selection functions below call this unconditionally:
// when a route is being *applied* (Back/Forward, cold load) the hash is already
// correct, so the write falls out instead of pushing a duplicate history entry.
function navigate(route, opts) {
  const next = routeToHash(route);
  // Above the no-op return on purpose: a navigation supersedes a deep link still
  // waiting on the first list-sessions even when it lands on the same hash —
  // clicking the very row the pending route names is the one case that reaches
  // here with nothing to write, and leaving it set re-applied the route later
  // (harmless, but not what the invalidation says it does). The sidebar is
  // painted early from the localStorage cache (CROW-613), so its rows and board
  // pills are clickable during exactly that window.
  pendingRoute = null;
  if (next === (location.hash || '#/')) return;
  if (opts && opts.replace) { history.replaceState(null, '', next); return; } // fires no event
  selfWroteHash = next;
  location.hash = next; // pushes a history entry — this is what makes Back work
}

// Drive the app to `route`, always through the existing selection entry points
// (selectSession / selectBoard / openSettings) so routed and clicked navigation
// can never disagree.
async function applyRoute(route) {
  if (!route) {
    navigate({ view: 'home' }, { replace: true });
    route = { view: 'home' };
  }
  if (route.view === 'settings') {
    // parseRoute degrades an unknown tab to 'general'. Rewrite the bogus hash
    // *in place* first, so the address bar can't sit on a shape the app
    // silently reinterprets and Back can't return to one (review).
    if (routeToHash(route) !== (location.hash || '#/')) navigate(route, { replace: true });
    // Already open: move the tab in place. Re-entering openSettings would
    // re-fetch the config and reset `dirty`, so arriving at a tab via Back
    // would silently discard edits that clicking the same tab preserves.
    if (window.settingsIsOpen && window.settingsIsOpen()
      && window.setSettingsTab && window.setSettingsTab(route.tab)) return;
    if (window.openSettings) await window.openSettings(route.tab);
    return;
  }
  // Leaving #/settings/* (Back, or a deep link elsewhere) closes the modal —
  // *unforced*, so it prompts about unsaved edits exactly like ✕ / Esc /
  // backdrop-click do. Routing made Back a cheap in-app gesture, so letting it
  // be the one exit that discards silently would recreate the asymmetry this
  // PR already fixed for tab switches. A refused close keeps the modal up, so
  // put the URL back and abandon the route.
  if (window.settingsIsOpen && window.settingsIsOpen() && window.closeSettings) {
    const closed = await window.closeSettings();
    if (closed === false) {
      // The browser has already moved the history index, so this replaceState
      // overwrites the *destination* entry rather than restoring the one we came
      // from — cancelling a discard costs that entry. Taken knowingly:
      // history.forward() would preserve it but is a no-op when there's nothing
      // forward (a hand-edited URL), leaving the address bar wrong while the
      // modal is still up, which is the worse failure. closeSettings' own
      // routeBeforeSettings gets the user back on eventual close (review).
      const tab = window.settingsActiveTab ? window.settingsActiveTab() : 'general';
      navigate({ view: 'settings', tab: tab }, { replace: true });
      return;
    }
  }
  if (route.view === 'board') { selectBoard(route.board); return; }
  if (route.view === 'session') {
    // Cold load: hold the route until the first list-sessions decides whether
    // this id exists, so a deep link never flashes "not found" on a slow start.
    if (!sessionsLoaded) { pendingRoute = route; return; }
    if (!sessions.some((s) => s.id === route.sessionId)) {
      showSessionNotFound(route.sessionId);
      return;
    }
    pendingTerminalId = route.terminalId || null;
    await selectSession(route.sessionId, { fromRoute: true });
    return;
  }
  showHome();
}

function onHashChange() {
  const cur = location.hash || '#/';
  if (selfWroteHash === cur) { selfWroteHash = null; return; } // our own write
  selfWroteHash = null;
  applyRoute(currentRoute()).catch(() => {});
}
