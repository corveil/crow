// Crow web UI (M2, CROW-581). A pure client: all state + actions go over the
// daemon's WebSockets — JSON-RPC at /rpc, terminal byte-stream at /terminal.
//
// CROW-1155: this file is the boot assembler. Shared `'use strict'` globals live
// in the concern scripts loaded before it from index.html; settings.js loads last.
'use strict';

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
document.getElementById('back-to-sidebar').onclick = () => {
  document.getElementById('app').classList.add('mobile-show-sidebar');
};
// Our own terminal context menu (copy/paste/select-all/clear) replaces the
// browser default over the coding pane.
//
// Long-press is the touch half of the same menu (CROW-1006). xterm draws into a
// canvas under `user-select: none`, so a phone has no native selection or copy
// callout to fall back on here — this menu IS the mobile context menu, and
// without a touch entry point copy and paste were simply unreachable. The bridge
// carries its own weight even where the platform has one: iOS Safari dispatches
// no `contextmenu` for a long-press on a plain element. Android Chrome does, so
// both paths fire ~500ms in — harmless, because showTerminalMenu closes any open
// menu before rebuilding it at (nearly) the same point, which reads as one menu.
{
  const wrap = document.getElementById('terminal-wrap');
  wrap.addEventListener('contextmenu', showTerminalMenu);
  attachLongPress(wrap, (x, y) => {
    showTerminalMenu({ preventDefault() {}, clientX: x, clientY: y });
  });
}

// Paint the left pane immediately — cached last-known layout, or skeleton
// placeholders — before the first /rpc round-trip (CROW-613). A stale-schema
// cache entry must not abort the rest of boot (polls / refreshSessions).
try {
  restoreSidebarCache();
  restoreNotifHistory();
  loadGridPins();
  renderSidebar();
} catch (_) {
  clearSidebarCache();
  sessions = [];
  // A poisoned notif history is filtered on restore, but reset here too so this
  // recovery path can't itself re-throw on the retry render below (review).
  notifHistory = [];
  lastSidebarSig = null;
  try { renderSidebar(); } catch (_) { /* keep going — RPC refresh will paint */ }
}
renderStatusBar();

// URL routing (CROW-936). An unrecognized hash is normalized to #/ up front so
// the address bar never keeps a shape the app can't reproduce on reload.
window.addEventListener('hashchange', onHashChange);
const bootRoute = currentRoute();
if (!bootRoute) navigate({ view: 'home' }, { replace: true });

function applyBootRoute() {
  const route = bootRoute || { view: 'home' };
  // Home is already the painted state, so there's nothing to apply. Everything
  // else goes through applyRoute, including session routes: it defers on
  // !sessionsLoaded itself, so it stays correct whichever of this and the boot
  // refreshSessions() wins the race. Setting pendingRoute here instead re-made
  // that decision with staler information — if list-sessions resolved before
  // the parser reached settings.js, the route sat in pendingRoute after
  // sessionsLoaded was already true and waited for the 10s poll (review).
  if (route.view !== 'home') applyRoute(route).catch(() => {});
}
// settings.js defines window.openSettings and loads *after* this file, so a
// #/settings/* deep link has to wait for it — at DOMContentLoaded both script
// tags have run. (readyState is already past 'loading' under the jsdom harness,
// which evaluates app.js against a fully parsed document.)
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', applyBootRoute, { once: true });
} else {
  applyBootRoute();
}

refreshSessions();
refreshLive();
loadUIConfig();
refreshVersionUpdateBanner();
// Fallback polls — the `changed` push (onServerChanged) drives the common case,
// so these are relaxed. refreshLive stays brisk: runtime PR/RC state isn't
// store-backed and so isn't covered by a nudge (CROW-581, M-D).
setInterval(refreshSessions, 10000);
setInterval(refreshLive, 4000);
// Prefetch ticket/review counts so the sidebar Tickets card + Reviews badge show
// before first open.
refreshBoard('tickets');
refreshBoard('reviews');
// Keep the open ticket/review board fresh (allowlist is manual-refresh only).
// Slow fallback — board changes are push-driven via the daemon's poll nudge.
setInterval(() => {
  if (selectedBoard === 'tickets' || selectedBoard === 'reviews') refreshBoard(selectedBoard);
}, 20000);
// Poll the selected session's images — new files aren't store-backed, so no
// `changed` nudge fires for them; a light 5s scan makes drops appear live.
setInterval(() => { if (selectedId) refreshArtifacts(selectedId); }, 5000);
