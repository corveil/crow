'use strict';
// Crow web UI — Terminal: xterm attach, wheel/touch/scrollback/reload/keys. Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// Terminal (xterm.js on one /terminal WebSocket; switch windows via control frame)
// ---------------------------------------------------------------------------
let term = null;
let fitAddon = null;
let searchAddon = null;
let termWs = null;
let termSkelTimer = null; // #677: safety timeout that clears the skeleton overlay
let termReconnectDelay = 1000; // #687: backoff between reconnect attempts (ms), reset on open
// CROW-1027: id of the pending onclose auto-reconnect. Tracked so a manual
// ↻ Reload (or attachWindow) can cancel it before opening its own socket —
// otherwise the stray timer fires a SECOND attach that races the reload's on the
// shared window/term (dead-wheel double-connect hazard).
let termReconnectTimer = null;

// In-flight state for the header's ↻ Reload button (CROW-979). Module state, not
// DOM state: `refreshLive` repaints the whole detail header every 4s, so a busy
// flag parked on the button node would be wiped mid-reload — the same reason
// `ticketRefreshPending` lives out here rather than on `.tickets-refresh`.
let terminalReloadPending = false;
let terminalReloadSettleTimer = null;
// A reattach is sub-second; this only has to be long enough not to cut a slow one
// short. It exists for the case where `onopen` never comes at all (see below).
const TERMINAL_RELOAD_SETTLE_MS = 10000;

function paintTerminalReloadState() {
  if (!selectedId) return;
  const s = sessions.find((x) => x.id === selectedId);
  if (s) renderHeader(s);
}

// Repaint only when the button is actually out of date. `refreshTerminals` runs on
// paths where nothing about the button changed (add/close terminal, a background
// "terminals changed" push), and an unconditional renderHeader there would also
// throw away an in-flight `markInReviewAction`, which parks its spinner on the
// button node rather than in module state.
function syncTerminalReloadEnabled() {
  const btn = document.querySelector('#detail-header .action-btn-reload');
  if (!btn) return;
  if (btn.disabled !== (terminalReloadPending || !activeTerminal)) paintTerminalReloadState();
}

// Header ↻ Reload. `reloadTerminal()` is synchronous and returns before the new
// socket is up, so "done" is the socket opening — cleared from connectTerminalWs's
// `onopen`, which fires for this reload and for the auto-reconnect that follows a
// failed one. `onclose` retries forever with backoff, though, so a daemon that
// never comes back would leave this spinning: the settle timer is the floor under
// that. Deliberately NOT routed through attachWindow(), whose
// `win === attachedWindow` guard would make an explicit reload a no-op.
function reloadTerminalAction() {
  if (terminalReloadPending) return; // coalesce a double-tap
  // Read `activeTerminal` here rather than at render time: renderHeader runs in
  // selectSession *before* the awaited refreshTerminals that rebinds it, so the
  // value captured during a paint can be the previous session's row.
  if (!term || !activeTerminal) return; // nothing attached — the button is disabled anyway
  terminalReloadPending = true;
  clearTimeout(terminalReloadSettleTimer);
  terminalReloadSettleTimer = setTimeout(clearTerminalReloadPending, TERMINAL_RELOAD_SETTLE_MS);
  paintTerminalReloadState();
  reloadTerminal();
}

// Idempotent: `onopen` also fires for reconnects nobody asked for, and repainting
// the header on each of those would be needless churn.
function clearTerminalReloadPending() {
  if (!terminalReloadPending) return;
  clearTimeout(terminalReloadSettleTimer);
  terminalReloadSettleTimer = null;
  terminalReloadPending = false;
  paintTerminalReloadState();
}

// Skeleton loading overlay (#677): mask the artifact-prone xterm (re)attach
// window (blank/garbled grid, reflow flash, mid-paint scrollback replay) with
// the CROW-613 shimmer. Toggled via a `.loading` class on #terminal-wrap.
// Idempotent (#687): a sustained reconnect loop re-enters this per attempt, so
// no-op when already up — re-adding `.loading` would restart the shimmer and, in
// the old code, re-arm the safety auto-hide, producing the strobe. The safety
// auto-hide now lives in connectTerminalWs's `onopen` (connected-but-quiet PTY
// case only), never in the connecting/reconnecting path.
function showTerminalSkeleton() {
  const wrap = document.getElementById('terminal-wrap');
  if (!wrap || wrap.classList.contains('loading')) return;
  wrap.classList.add('loading');
}
function hideTerminalSkeleton() {
  clearTimeout(termSkelTimer);
  termSkelTimer = null;
  const wrap = document.getElementById('terminal-wrap');
  if (wrap) wrap.classList.remove('loading', 'reconnecting');
}
// #687: switch the overlay to a calm, steady "Reconnecting…" treatment during a
// sustained disconnect (distinct from the brief attach shimmer). Cleared on a
// successful (re)attach (onopen) and on hide.
function setTerminalReconnecting(on) {
  const wrap = document.getElementById('terminal-wrap');
  if (wrap) wrap.classList.toggle('reconnecting', on);
}

// Terminal font stack: Nerd Fonts → system monospace.
const DEFAULT_TERM_FONT = '"MesloLGS NF", "MesloLGS Nerd Font", "JetBrainsMono Nerd Font", "Hack Nerd Font", "FiraCode Nerd Font", Menlo, Monaco, monospace';

// --- Per-surface hybrid scroll model (ADR-0013) -----------------------------
//
// Crow runs three scroll models side by side, chosen per tmux window:
//
//   * PLAIN SHELL / REVIEW surfaces keep the unified model — output flows into
//     xterm's 50k scrollback, the daemon replays tmux history on reconnect
//     (CROW-606), and the wheel scrolls that local buffer.
//   * AGENT-TUI surfaces own their own viewport like a naked terminal.
//     crowd sets `alternate-screen on` for those windows so an agent that
//     requests smcup keeps full-frame repaints in the alt buffer, which has
//     no scrollback. Inline renderers (Cursor, and Claude Code builds that
//     render inline — CROW-1023) never issue smcup: their history is a clean
//     transcript in the main buffer, so they keep the unified 50k and the
//     wheel at a non-mouse-tracking prompt scrolls that local viewport
//     (#850 / CROW-1010). Capping xterm scrollback to 0 on `agent_surface`
//     alone deleted Cursor's only scroll path (the #1008/#1009 regression).
//
// `agent_surface` comes from `list-terminals`, sourced from the tmux window
// option crowd actually set — NOT from `term.buffer.active.type`. The client
// can't use the buffer type here: crow-tmux.conf strips the client's
// smcup/rmcup, and `terminal-overrides` is keyed on the client's TERM while a
// single tmux client serves every tab, so there is no per-window client buffer
// state to read. `uses_alternate_screen` is the sibling flag: true only for a
// window that has ACTUALLY entered the alt buffer — detected per-window from
// tmux's runtime `#{alternate_on}` and latched sticky (CROW-1023), not a
// per-kind guess, so the two diverging Claude Code builds (alt vs inline) route
// correctly. The buffer/mouse-mode checks below are kept as an additional
// signal for surfaces that do legitimately enter the alt buffer.
function activeSurfaceIsAgent() {
  return !!(activeTerminal && activeTerminal.agent_surface);
}

function activeSurfaceUsesAltScreen() {
  return !!(activeTerminal && activeTerminal.uses_alternate_screen);
}

// Only true alt-buffer agents (Claude Code) skip xterm's local history —
// they live in tmux's scrollback-less alt buffer. Inline agents (Cursor)
// keep UNIFIED_SCROLLBACK: their transcript is the scrollback, and the
// wheel at a non-mouse-tracking prompt scrolls it (CROW-1010). Plain shells
// keep the unified 50k (CROW-606). One shared xterm, so this must re-run on
// every tab bind — not just at construct time. A missing flag (older daemon)
// keeps 50k rather than capping — taking scrollback away is what broke Cursor.
const UNIFIED_SCROLLBACK = 50000;
function applySurfaceScrollback() {
  if (!term || !term.options) return;
  const wanted = (activeSurfaceIsAgent() && activeSurfaceUsesAltScreen())
    ? 0 : UNIFIED_SCROLLBACK;
  if (term.options.scrollback === wanted) return;
  // CROW-1047: the alt-buffer latch caps xterm from 50k → 0. Truncating while
  // the user is mid-history in the transitional unlatched window resets ydisp to
  // 0 on the oldest surviving lines — session start — instead of a few lines up.
  // Defer until they return to the live edge; maybePollAltScreenLatch re-calls
  // this on every refreshTerminals pass until the cap lands.
  if (wanted === 0) {
    const buf = term.buffer && term.buffer.active;
    if (buf && buf.viewportY < buf.baseY) return;
  }
  term.options.scrollback = wanted;
}

// CROW-1023: `uses_alternate_screen` is detected per-window from tmux's RUNTIME
// alt-buffer state, which an alt-buffer agent (e.g. Claude Code 2.1.233) only
// reaches AFTER it launches and issues smcup — usually a few seconds after
// new-terminal/recreate snapshots the row at `false`. `list-terminals` is not
// polled (onServerChanged/refreshLive don't re-read it), so without this nudge
// an alt-buffer agent's row would stay `false`, applySurfaceScrollback would
// leave xterm at UNIFIED_SCROLLBACK, and its live frames would fossilize in the
// local viewport — the #822 regression the cap-to-0 exists to prevent.
//
// So while the ATTACHED surface is an agent surface not yet latched to the alt
// buffer, re-read `list-terminals` on a short bounded schedule until it latches
// (`uses_alternate_screen` flips true → applySurfaceScrollback caps to 0 and
// xterm discards any frames that fossilized in the meantime) or the budget runs
// out — at which point it is a genuinely inline build (Cursor / inline Claude)
// that correctly keeps the 50k. Bounded and per-surface: switching to a new
// unlatched agent tab refreshes the budget; a latched or non-agent surface arms
// nothing. Not a tab-switch dependency (that was the review gap) — it self-arms
// from every refreshTerminals until the flag settles.
const ALT_LATCH_POLL_MS = 1000;
const ALT_LATCH_POLL_MAX = 15; // ~15s: agent launch + first alt-screen frame
let altLatchPollTimer = null;
let altLatchPollTermId = null;
let altLatchPollLeft = 0;
function maybePollAltScreenLatch() {
  const t = activeTerminal;
  // A window must exist (else `uses_alternate_screen` is still the pre-window
  // prior, not a real read) and the surface must be an as-yet-uncapped agent.
  const unlatched = !!(t && t.agent_surface && t.window != null && !t.uses_alternate_screen);
  if (!unlatched) { // latched, gone, or not an agent surface → stop watching
    clearTimeout(altLatchPollTimer);
    altLatchPollTimer = null;
    altLatchPollTermId = null;
    return;
  }
  if (t.id !== altLatchPollTermId) { // a fresh surface to stabilize → fresh budget
    altLatchPollTermId = t.id;
    altLatchPollLeft = ALT_LATCH_POLL_MAX;
  }
  if (altLatchPollLeft <= 0) return; // gave up → a genuinely inline build (keeps 50k)
  if (altLatchPollTimer) return;     // already scheduled
  altLatchPollTimer = setTimeout(() => {
    altLatchPollTimer = null;
    altLatchPollLeft -= 1;
    refreshTerminals(); // rebinds activeTerminal + applySurfaceScrollback, then re-arms here
  }, ALT_LATCH_POLL_MS);
}

// Mouse-mode swallow — same handler as web/terminal.html (CROW-581). The agent
// TUIs turn the xterm mouse protocol on themselves, and crow-tmux.conf's
// `mouse off` means tmux forwards those DECSETs straight through to this
// client.
//
// On a PLAIN SHELL we drop them: left alone, xterm.js enters mouse-reporting
// mode and every mouse MOVE emits an SGR report to the PTY → the TUI repaints →
// the viewport is yanked to the bottom while the user is scrolled up;
// drag-select and the browser context menu are eaten too (#776).
//
// On an AGENT SURFACE we let them THROUGH, so the agent claims the wheel and
// owns its own scroll exactly like a naked terminal (ADR-0013). The cost is the
// one the swallow was avoiding: native drag-select and the right-click menu are
// eaten inside agent windows. Hold ⌥ (Alt) to force selection anyway — that's
// why `macOptionClickForcesSelection` is enabled in the Terminal config, since
// xterm.js gates the Mac force-selection path on it and it defaults to false.
const MOUSE_MODES = new Set([1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016]);
function swallowMouseMode(params) {
  if (activeSurfaceIsAgent()) return false; // agent surface → let it own the mouse
  const arr = params && params.params ? params.params : params;
  const len = arr ? arr.length : 0;
  for (let i = 0; i < len; i++) {
    const v = arr[i];
    if (MOUSE_MODES.has(Array.isArray(v) ? v[0] : v)) return true; // handled → drop it
  }
  return false; // not a mouse mode → let xterm apply it normally
}

// The modifier that forces a text selection when the app owns the mouse.
// Mirrors xterm.js's own `shouldForceSelection`: Alt on macOS (which is why
// `macOptionClickForcesSelection` must be enabled), Shift on every other
// platform. Best-effort UA sniff — only ever used for a label.
function forceSelectModifierLabel() {
  const ua = (navigator.userAgent || '') + ' ' + (navigator.platform || '');
  return /Mac|iPhone|iPad|iPod/.test(ua) ? '⌥' : 'Shift';
}

// True when the wheel/touch scroll should be FORWARDED to the app on the other
// end instead of scrolling xterm's local buffer. Shared by the wheel and touch
// shims so both agree on who owns the surface.
//
// Forwarding is right in exactly one case: the app is actively MOUSE-TRACKING,
// so the tick becomes an SGR wheel button (`\x1b[<64/65`) it scrolls its own
// transcript with (an agent TUI showing a scrollable view, vim, htop, …).
// Everything else — a plain shell AND an agent TUI idling at its prompt —
// scrolls the local xterm viewport. Forwarding a NON-mouse wheel would fall to
// sendScrollToPTY's arrow-key branch, which Claude Code / Cursor read as
// input-HISTORY navigation rather than scrollback — the #850 bug. Scrolling the
// local viewport instead matches the desktop terminal and web/terminal.html,
// neither of which forwards a non-mouse wheel.
//
// `agent_surface` (daemon-supplied) is AUTHORITATIVE whenever we have it and is
// consulted BEFORE the mouse-mode check — that ordering is load-bearing, not
// defensive coding. There is ONE shared xterm instance across every tab, and
// agent surfaces now let DECSET 1000–1016 through, so
// `term.modes.mouseTrackingMode` can outlive the tab that set it: `attachWindow`
// clears it via `clearTermBuffer()` (in-place agent switch) or `reloadTerminal()`
// (shells) when the socket is already OPEN, and skips that during a reconnect.
// If we tested the mode first,
// a shell tab visited right after an agent tab would inherit that stale mode and
// forward the wheel to the PTY — regressing the exact shell path this model
// exists to preserve. So a KNOWN surface reads its own kind and only an agent
// that is genuinely mouse-tracking forwards. The alt-buffer / mouse-tracking
// fallbacks apply ONLY before the first `list-terminals` lands (no metadata).
function appOwnsScroll() {
  const modes = (term && term.modes) || {};
  const mouseTracking = !!(modes.mouseTrackingMode && modes.mouseTrackingMode !== 'none');
  if (activeTerminal && typeof activeTerminal.agent_surface === 'boolean') {
    // Agent TUI → forward only while it's mouse-tracking (SGR wheel scrolls the
    // agent's transcript); at a plain prompt fall through to a LOCAL viewport
    // scroll instead of the arrow keys it reads as history nav (#850). A plain
    // shell always scrolls locally, even if a prior agent tab left the shared
    // xterm mouse-tracking.
    return activeTerminal.agent_surface && mouseTracking;
  }
  if (mouseTracking) return true;
  const buf = term && term.buffer && term.buffer.active;
  return !!(buf && buf.type === 'alternate');
}

// CROW-1020: xterm paints its scrollbar slider from the JS `theme` object, not
// from CSS, so the gold thumb has to be handed across from app.css's --scroll-*
// tokens rather than styled in place. Left alone, xterm derives the slider from
// the FOREGROUND at 0.20 alpha — #d4d4d4 over #1e1e1e is 1.67:1, under WCAG 2.2
// §1.4.11's 3:1 floor, which is why the bar read as "gone" even while it was
// technically being drawn.
//
// A missing token yields an omitted key, so xterm falls back to its own default
// instead of us duplicating the literal here — app.css stays the one place the
// palette is written down. `rgba(r, g, b, a)` is one of the forms xterm's
// css.toColor parses (alongside #rgb/#rrggbb/#rrggbbaa), so the token text goes
// over verbatim.
const TERM_SCROLLBAR_TOKENS = {
  scrollbarSliderBackground: '--scroll-thumb',
  scrollbarSliderHoverBackground: '--scroll-thumb-hover',
  scrollbarSliderActiveBackground: '--scroll-thumb-active',
};
function scrollbarTheme() {
  const theme = {};
  if (typeof getComputedStyle !== 'function' || !document.documentElement) return theme;
  const css = getComputedStyle(document.documentElement);
  for (const key of Object.keys(TERM_SCROLLBAR_TOKENS)) {
    const value = (css.getPropertyValue(TERM_SCROLLBAR_TOKENS[key]) || '').trim();
    if (value) theme[key] = value;
  }
  return theme;
}

// CROW-1020: xterm 6 scrolls through a VS Code scrollable element built with
// `vertical: ScrollbarVisibility.Auto`, so the thumb fades out whenever the
// pointer is off the grid — you cannot grab what is not drawn. app.css pins it
// visible while this class is on.
//
// The class is gated on the buffer actually HAVING history, not just on the
// surface allowing it: with nothing to scroll, xterm sizes the slider to the
// whole track, so an ungated pin would paint a permanent stripe down every
// empty terminal. `baseY` (lines that have scrolled off the top) is exactly
// xterm's own "is the bar needed" test, and it is 0 in the alternate screen —
// which is where alt-buffer agents like Claude Code live and where there is no
// local scrollback to reach anyway (see applySurfaceScrollback).
function updateTerminalScrollbar() {
  const wrap = document.getElementById('terminal-wrap');
  if (!wrap) return;
  const buf = term && term.buffer && term.buffer.active;
  wrap.classList.toggle('has-scrollback', !!buf && buf.baseY > 0);
}

function ensureTerminal() {
  if (term) return;
  fitAddon = new FitAddon.FitAddon();
  const imageAddon = new ImageAddon.ImageAddon({ sixelSupport: true, iipSupport: true, kittySupport: true });
  searchAddon = new SearchAddon.SearchAddon();
  const webLinksAddon = new WebLinksAddon.WebLinksAddon();
  // Config block mirrors web/terminal.html (the standalone debug page). It also
  // named CrowTerminal/Resources/xterm/terminal.html, but that page lost its
  // last consumer when ADR-0010 retired the macOS app — its crowWrite/crowInput
  // bridge has no caller — so it is no longer a front-end to stay in sync with.
  term = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: DEFAULT_TERM_FONT,
    theme: { background: '#1e1e1e', foreground: '#d4d4d4', ...scrollbarTheme() },
    scrollback: UNIFIED_SCROLLBACK,
    allowTransparency: true,
    // Required to switch `term.unicode.activeVersion` off Unicode 6 (CROW-1157).
    allowProposedApi: true,
    // Escape hatch for agent surfaces, where we stop swallowing mouse modes so
    // the agent owns the wheel (ADR-0013) — which also means xterm reports
    // drags to the app instead of selecting text. xterm.js's Mac force-select
    // path is `altKey && macOptionClickForcesSelection`, and this option
    // DEFAULTS TO FALSE, so without it ⌥-drag would silently do nothing and
    // there'd be no way to select text inside an agent window at all.
    macOptionClickForcesSelection: true,
  });
  term.loadAddon(fitAddon);
  // CROW-1157: xterm.js defaults to Unicode 6 cell widths, so emoji and many
  // symbols in Claude Code's status line (`ctx: 0%`, mode glyphs) occupy 1
  // cell here while tmux and Node's string-width count them as 2. Claude then
  // CUP-places the hardware cursor several columns past the glyphs it painted,
  // which reads as a caret floating after the footer while typed text inserts
  // at the prompt. Unicode 11 matches that wcwidth; load before open()/first
  // write so no PTY frame is measured on the old tables. Guarded like the
  // viewport addon — a failed /xterm fetch must not take ensureTerminal down.
  if (typeof Unicode11Addon === 'object' && Unicode11Addon
      && typeof Unicode11Addon.Unicode11Addon === 'function') {
    try {
      term.loadAddon(new Unicode11Addon.Unicode11Addon());
      term.unicode.activeVersion = '11';
    } catch (_) { /* addon or proposed unicode API unavailable */ }
  }
  term.loadAddon(imageAddon);
  term.loadAddon(searchAddon);
  term.loadAddon(webLinksAddon);

  // Registered before open()/first write so no mode toggle slips past.
  term.parser.registerCsiHandler({ prefix: '?', final: 'h' }, swallowMouseMode);
  term.parser.registerCsiHandler({ prefix: '?', final: 'l' }, swallowMouseMode);

  // #677: seed the skeleton before first open() so it covers the initial xterm
  // layout / first-fit reflow flash; connectTerminalWs() re-arms it below.
  showTerminalSkeleton();
  term.open(document.getElementById('terminal'));
  applySurfaceScrollback();
  // Jump-to-bottom pill (#668), shared with the desktop surface. Must load after
  // open() so the addon can anchor its button to the terminal's container.
  term.loadAddon(new CrowJumpBottomAddon.CrowJumpBottomAddon());
  // CROW-988: keep the grid inside the *visual* viewport so a phone's software
  // keyboard can't sit on top of the prompt line. Inert without
  // window.visualViewport and while nothing keyboard-sized occludes the page, so
  // desktop is untouched. Feeds the same coalesced fitTerminal every other
  // resize route uses. Guarded like the WebGL load below — a failed asset fetch
  // must not take ensureTerminal (and with it the whole terminal) down.
  if (typeof CrowViewportAddon === 'object' && CrowViewportAddon
      && typeof CrowViewportAddon.CrowViewportAddon === 'function') {
    term.loadAddon(new CrowViewportAddon.CrowViewportAddon({ onResize: fitTerminal }));
  }
  // WebGL renderer for throughput; must load after open(). Falls back to the
  // default renderer if the GL context is unavailable or gets lost.
  //
  // CROW-1078: skipped on touch surfaces (iOS/iPad). A WebGL canvas is its own
  // compositor layer that often fails to re-composite while Safari animates the
  // *visual* viewport with the software keyboard, so the drawn cursor strands at
  // its old screen position while the IME caret (a DOM textarea) follows the
  // keyboard — the two land on different cells. The DOM/canvas renderer follows
  // the viewport correctly and honors the viewport addon's post-inset repaint.
  // `keyboardCapable()` is the SAME touch test the viewport addon gates on,
  // shared from its namespace so the two can't drift; requiring `visualViewport`
  // too makes this condition identical to "the viewport addon will engage" — so
  // WebGL is dropped on exactly the surfaces where the keyboard can animate the
  // viewport, and non-visualViewport webviews keep WebGL unchanged. If the addon
  // failed to load, `skipWebgl` stays false and WebGL loads exactly as before.
  let skipWebgl = false;
  try {
    skipWebgl = !!window.visualViewport
      && typeof CrowViewportAddon === 'object' && CrowViewportAddon
      && typeof CrowViewportAddon.keyboardCapable === 'function'
      && CrowViewportAddon.keyboardCapable();
  } catch (_) { skipWebgl = false; }
  if (!skipWebgl) {
    try {
      const webglAddon = new WebglAddon.WebglAddon();
      webglAddon.onContextLoss(() => webglAddon.dispose());
      term.loadAddon(webglAddon);
    } catch (_) { /* WebGL unavailable → canvas/DOM renderer */ }
  }
  term.onData(sendToPTY);
  // CROW-934: hydrate the shell scrollback from tmux when the user reaches the
  // top of what the live stream actually delivered.
  term.onScroll(maybeHydrateScrollback);
  // CROW-1020: keep the "there is history to grab" class in step with the
  // buffer. Same pair of triggers as the #668 jump-to-bottom pill, for the same
  // reason — onScroll is what fires when the user moves, onRender is what fires
  // when output (or a tab bind, or a reload) changes what there is to move
  // through. classList.toggle with an unchanged value is a no-op, so the
  // per-frame call costs nothing.
  term.onScroll(updateTerminalScrollbar);
  term.onRender(updateTerminalScrollbar);
  term.attachCustomKeyEventHandler(handleTerminalKey);
  enableTouchScroll(document.getElementById('terminal'));
  enableWheelScroll(document.getElementById('terminal'));
  enableFileDrop(document.getElementById('terminal'));
  window.addEventListener('resize', fitTerminal);
  // #667: on regaining focus/visibility, this surface reclaims ownership of the
  // shared tmux window size — so "window-size latest" converges to "the surface
  // you most recently focused." Same-size reclaim uses `if_needed` so it does
  // not SIGWINCH the agent (CROW-1162). Registered once (ensureTerminal is
  // `if (term) return` guarded).
  window.addEventListener('focus', takeTerminalOwnership);
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden) takeTerminalOwnership();
  });
  // Observe the container itself, not just the window: splitter drags / panel
  // collapses resize the surface without firing a window `resize` (#661). Both
  // routes funnel through the coalesced, deduped fitTerminal.
  if (window.ResizeObserver) {
    new ResizeObserver(fitTerminal).observe(document.getElementById('terminal'));
  }
  // The first fit can run with the Menlo fallback before the Nerd Font loads;
  // once its cell metrics settle the grid recomputes, so re-fit (deduped).
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitTerminal);
  connectTerminalWs();
}

// The one guarded writer to the PTY socket, shared by term.onData and the touch
// scroll shim below (mirrors terminal.html's sendToPTY of the same name).
function sendToPTY(text) {
  if (!text) return;
  if (termWs && termWs.readyState === WebSocket.OPEN) termWs.send(new TextEncoder().encode(text));
}

// One rendered row in CSS pixels. `.xterm-screen` is exactly rows × cellHeight
// under both the WebGL and DOM renderers, so it's a truer metric than the
// container's clientHeight (which carries padding and, on mobile, the keyboard
// inset / dPR mis-fit that made the old `clientHeight / rows` yield delta 0).
function terminalCellHeight(node) {
  const rows = (term && term.rows) || 0;
  if (rows > 0) {
    const screen = term.element && term.element.querySelector('.xterm-screen');
    const h = screen ? screen.clientHeight / rows : 0;
    if (isFinite(h) && h >= 4) return h;
    const fallback = (node ? node.clientHeight : 0) / rows;
    if (isFinite(fallback) && fallback >= 4) return fallback;
  }
  return 18;
}

// Translate N lines of scroll into what a wheel tick would send, for the case
// where the local buffer can't scroll: the alternate screen has no scrollback,
// so term.scrollLines is a silent no-op there (#777 — on mobile that read as
// "the same frame forever"). Matches enableWheelScroll's policy of letting a
// fullscreen TUI own the wheel. Negative = up/back.
const MAX_PTY_SCROLL_LINES = 24; // a fling must not flood the PTY
function sendScrollToPTY(lines) {
  const n = Math.min(Math.abs(lines), MAX_PTY_SCROLL_LINES);
  if (n === 0) return;
  const up = lines < 0;
  const modes = (term && term.modes) || {};
  // Mouse-reporting apps (and tmux, whose `mouse on` relays to them) want SGR
  // wheel buttons 64/65. The cursor-key branch is now only the UNCLASSIFIED
  // alt-buffer fallback (a genuine fullscreen app like less/vim before
  // list-terminals lands): appOwnsScroll no longer forwards a non-mouse agent
  // wheel here, so this branch never turns an agent's wheel into history nav
  // (#850).
  let seq;
  if (modes.mouseTrackingMode && modes.mouseTrackingMode !== 'none') {
    seq = up ? '\x1b[<64;1;1M' : '\x1b[<65;1;1M';
  } else {
    const ss3 = modes.applicationCursorKeysMode;
    seq = up ? (ss3 ? '\x1bOA' : '\x1b[A') : (ss3 ? '\x1bOB' : '\x1b[B');
  }
  sendToPTY(seq.repeat(n));
}

// xterm.js doesn't scroll its scrollback on touch drags — map a one-finger
// vertical swipe to the terminal so it's scrollable on mobile. Registered
// non-passive and preventDefault'ed: a passive listener can't stop iOS Safari's
// native overscroll, so the browser rubber-banded the canvas while this shim
// tried to scroll the buffer, and the native gesture won (#777). `#terminal`
// also carries `touch-action: none` so Safari never claims the gesture at all.
function enableTouchScroll(node) {
  let lastY = null;
  let accum = 0; // sub-cell remainder, so slow drags aren't truncated away
  node.addEventListener('touchstart', (e) => {
    if (e.touches.length === 1) { lastY = e.touches[0].clientY; accum = 0; }
    else lastY = null; // pinch/multi-touch is not ours
  }, { passive: true });
  node.addEventListener('touchmove', (e) => {
    if (lastY == null || e.touches.length !== 1 || !term) return;
    e.preventDefault(); // own the gesture instead of racing Safari's overscroll
    const y = e.touches[0].clientY;
    accum += (lastY - y) / terminalCellHeight(node);
    lastY = y;
    const delta = Math.trunc(accum);
    if (delta === 0) return;
    accum -= delta;
    // Same ownership test as the wheel (ADR-0013) so touch and wheel never
    // disagree about who owns the surface.
    if (appOwnsScroll()) sendScrollToPTY(delta);
    else term.scrollLines(delta);
  }, { passive: false });
  node.addEventListener('touchend', () => { lastY = null; accum = 0; }, { passive: true });
  node.addEventListener('touchcancel', () => { lastY = null; accum = 0; }, { passive: true });
}

// Device normalization for the wheel (CROW-835). Translate ONE `wheel` event
// into fractional PHYSICAL notches so a notched mouse, a trackpad, and a
// free-spinning wheel all land at ~1 notch per detent — instead of the old fixed
// ±3, which (forwarded to an agent that already scrolls several lines per notch)
// flew multiple pages. `e.deltaMode` disambiguates the unit; the pixel branch
// magnitude-snaps a discrete detent to exactly one notch regardless of whether
// the device reports 100/120/240 px, while sub-detent trackpad deltas fall
// through to the accumulator in enableWheelScroll.
const WHEEL_NOTCH_MIN_PX = 40; // a single pixel-mode delta at least this big is one detent
function wheelNotches(e) {
  const mode = e.deltaMode || 0;
  if (mode === 1) { // line mode (Firefox mouse): OS 3 lines/notch
    const lines = e.deltaY;
    // Magnitude-snap like the pixel branch (CROW-835): one DOM event is one
    // physical detent even when the OS reports many lines (free-spin / fling).
    // Without this, a forwarded SGR burst can fly Claude's transcript to the top.
    return Math.abs(lines) >= 3 ? Math.sign(lines) : lines / 3;
  }
  if (mode === 2) { // page mode (rare)
    return Math.abs(e.deltaY) >= 1 ? Math.sign(e.deltaY) : e.deltaY;
  }
  const px = e.deltaY;                  // pixel mode (Chrome/Safari mouse + all trackpads)
  return Math.abs(px) >= WHEEL_NOTCH_MIN_PX ? Math.sign(px) : px / WHEEL_NOTCH_MIN_PX;
}

// Route the wheel by surface (ADR-0013, refined by #850) — the mirror of what
// enableTouchScroll does for touch:
//
//   * PLAIN SHELL, or an AGENT SURFACE idling at its prompt → scroll xterm's
//     local viewport. On a shell that's the 50k scrollback; on an agent (whose
//     transcript lives in tmux's scrollback-less alt buffer) it's a harmless
//     no-op — but critically NOT the arrow-key history nav forwarding used to
//     produce (#850). Matches the desktop terminal and web/terminal.html.
//   * MOUSE-TRACKING app (an agent showing a scrollable view, vim, htop) →
//     forward the tick so it becomes an SGR wheel button the app scrolls its
//     own transcript with, like a naked terminal.
//
// This handler always CONSUMES the event (capture + preventDefault +
// stopPropagation) so xterm's own alternate-scroll fallback never runs. That
// fallback emits ARROW KEYS, which Claude Code reads as input-history
// navigation — the #776/#850 bug. `appOwnsScroll` (mouse-tracking, per above)
// decides forward-vs-local; forwarding goes through sendScrollToPTY, which caps
// a fling so it can't flood the PTY.
//
// Magnitude is device-normalized to whole notches (wheelNotches) with a
// sub-notch accumulator (mirroring enableTouchScroll's `accum`), then scaled by
// the user's per-path sensitivity (CROW-835): a forwarded wheel sends
// `agentWheelNotches` reports per notch (default 1 — one detent in, one out),
// a local scroll moves `wheelScrollLines` lines per notch (default 3 — the
// historical feel). The `if (!term)` guard is the only early exit; a partial
// notch simply consumes the event and waits for more.
function enableWheelScroll(node) {
  let accum = 0; // sub-notch remainder, so slow trackpad dust isn't truncated away
  node.addEventListener('wheel', (e) => {
    if (!term) return;
    e.preventDefault();
    e.stopPropagation();
    accum += wheelNotches(e);
    const notches = Math.trunc(accum);
    if (notches !== 0) {
      accum -= notches;
      if (appOwnsScroll()) sendScrollToPTY(notches * (uiConfig.agentWheelNotches || 1));
      else term.scrollLines(notches * (uiConfig.wheelScrollLines || 3));
    }
  }, { capture: true, passive: false });
}

// Drag-and-drop files into the composer (#644 images, #652 any file). The
// browser can't read a dropped file's filesystem path (and may be a remote
// client), so upload the bytes to crowd, which writes them into the session's
// artifacts dir on the host and returns an absolute path. We then paste that
// (escaped) path into the terminal — parity with a Finder drop into the
// standalone Cursor/Claude Code TUIs, which the agents already consume. No
// trailing newline → the path is inserted, not submitted, so the user can add a
// prompt before pressing Enter. Images additionally surface in the Artifacts
// panel; other files (source, docs, archives, PDFs) are referenced by path only.
function enableFileDrop(node) {
  node.addEventListener('dragover', (e) => {
    // dataTransfer.files is empty during dragover — only .types is populated —
    // so accept any file drag here (all types are handled on drop).
    if (e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files')) {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
    }
  });
  node.addEventListener('drop', (e) => {
    const files = e.dataTransfer && e.dataTransfer.files;
    if (!files || !files.length) return; // not a file drop → leave to the browser
    e.preventDefault();                   // never navigate the app away on a file drop
    if (selectedId) uploadDroppedFiles(Array.from(files)); // images + non-images alike
  });
}

// Backslash-escape whitespace and shell metacharacters, matching what
// Terminal.app/iTerm insert on a Finder drop (the byte stream the agent TUIs
// already parse). In practice the artifacts path has none of these, so this is
// belt-and-suspenders.
function shellEscapePath(p) {
  return p.replace(/([\s'"\\$`&|;<>()*?!#~\[\]{}])/g, '\\$1');
}

async function uploadDroppedFiles(files) {
  const sid = selectedId;
  const paths = [];
  for (const file of files) {
    try {
      const res = await fetch('/artifacts/' + encodeURIComponent(sid), {
        method: 'POST',
        headers: {
          // Empty for unknown types — the server derives the extension from the
          // filename, so fall back to a generic binary type.
          'Content-Type': file.type || 'application/octet-stream',
          'X-Filename': encodeURIComponent(file.name || 'file'),
        },
        body: file,
        credentials: 'same-origin',
      });
      if (!res.ok) continue;
      const data = await res.json();
      if (data && data.path) paths.push(shellEscapePath(data.path));
    } catch (_) { /* skip this file */ }
  }
  if (paths.length && term) {
    term.focus();
    // Route through xterm's paste so bracketed-paste mode wraps it (same path as
    // pasteIntoTerminal); onData forwards the wrapped bytes to the PTY.
    term.paste(paths.join(' ') + ' ');
  }
}

// The terminal's custom key handler (attached in ensureTerminal). At module
// scope so the jsdom suite can drive it directly — same reason swallowMouseMode
// lives out here.
//
// Cmd/Ctrl+C copies the selection (falling through to SIGINT when nothing is
// selected so Ctrl+C still interrupts), Cmd+F opens our find prompt. Lets the
// browser own copy instead of tmux's copy-mode. Shift+Enter is rewritten to a
// distinguishable CSI-u sequence (see the branch).
//
// A branch that shadows a browser default must preventDefault(): returning
// false only makes xterm skip its OWN key handling (its _keyDown returns early,
// before any cancel()), so the browser's default gesture still runs (#875).
function handleTerminalKey(e) {
  if (e.type !== 'keydown') return true;
  // Shift+Enter → CSI-u, so Claude Code can tell it from a plain Enter and
  // inserts a newline instead of submitting (#598/CROW-916). xterm.js's key
  // table has no shiftKey branch for keyCode 13 — `e.altKey ? ESC+CR : CR` —
  // so both chords otherwise arrive at the PTY as the same bare \r, and
  // xterm.js 6.0 has no CSI-u/modifyOtherKeys support of its own to turn on.
  // crow-tmux.conf's `extended-keys on` + `xterm*:extkeys` carries this to
  // apps that negotiate extended keys and downgrades it to a plain \r for apps
  // that don't, so nothing leaks into vim or a shell.
  //
  // Option+Enter is deliberately NOT handled: xterm already maps altKey + Enter
  // to ESC CR natively, so a branch here would only restate the library.
  // `!e.altKey` keeps Shift+Option+Enter on that native path.
  //
  // preventDefault() is load-bearing, not cosmetic. xterm cancels Enter itself
  // (`o.cancel = true`), but returning false makes its _keyDown return BEFORE
  // that cancel (#875) — and this handler waves the keypress phase straight
  // through, so an uncancelled keydown would let keypress fire and write a
  // second \r.
  //
  // Ported from CrowTerminal's terminal.html (#599), which stopped being a live
  // surface when the macOS app was retired (ADR 0010).
  if (e.key === 'Enter' && e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey) {
    sendToPTY('\x1b[13;2u');
    e.preventDefault();
    e.stopPropagation();
    return false;
  }
  const mod = e.metaKey || e.ctrlKey;
  if (mod && (e.key === 'c' || e.key === 'C') && term.hasSelection()) {
    copyToClipboard(term.getSelection());
    // Safe to own the gesture: copyToClipboard always delivers — writeText, or
    // fallbackCopy's execCommand in a non-secure context.
    e.preventDefault();
    e.stopPropagation();
    return false;
  }
  // #875: Cmd+V is deliberately NOT handled here. Pasting explicitly *and*
  // returning false double-pasted, because the browser's native paste gesture
  // still fired xterm's own `paste` listener (on the helper textarea) and wrote
  // the clipboard a second time. Leaving the event alone gives exactly one
  // paste — xterm's listener routes it through paste(), so bracketed-paste
  // wrapping is applied once, then onData → sendToPTY. macOS Cmd+V produces no
  // key data in xterm, so nothing leaks to the PTY either.
  //
  // The native gesture is also strictly more capable than reading the clipboard
  // ourselves: it needs no clipboard-read permission and works over plain http
  // (`--host 0.0.0.0`), where navigator.clipboard doesn't exist at all. The
  // right-click menu still calls pasteIntoTerminal() — a click is not a paste
  // gesture, so there it's the only path.
  if (e.metaKey && (e.key === 'f' || e.key === 'F')) {
    // Without this the browser's own find bar opens over our prompt.
    e.preventDefault();
    e.stopPropagation();
    textPrompt('Find in terminal', '', { okLabel: 'Find' }).then((q) => {
      if (q && searchAddon) { try { searchAddon.findNext(q); } catch (_) {} }
    });
    return false;
  }
  if (switcherBindingOpens(e, uiConfig.switcherBinding)) {
    if (uiConfig.switcherEnabled && switcherCapturesInTerminal()) {
      switcherOnBinding(e);
      e.preventDefault();
      e.stopPropagation();
      return false;
    }
  }
  return true;
}

// Paste the browser clipboard into the terminal (writes to the PTY, same path
// as typing). readText() needs a user gesture — the right-click menu click is
// one. Cmd+V never comes through here (#875); the browser pastes it natively.
function pasteIntoTerminal() {
  if (!term || !(navigator.clipboard && navigator.clipboard.readText)) return;
  navigator.clipboard.readText().then((text) => {
    // Route through xterm's paste so bracketed-paste mode wraps it when the app
    // enabled it — otherwise hidden newlines in the clipboard auto-execute in the
    // shell (review). onData then forwards the (wrapped) bytes to the PTY.
    if (text) term.paste(text);
  }).catch(() => { /* denied / empty */ });
}

// Our own right-click menu for the terminal (copy selection / paste / select
// all / clear) — replaces the browser default, which we suppress. Copy appears
// only when there's a selection.
function showTerminalMenu(e) {
  e.preventDefault();
  closeContextMenu();
  if (!term) return;
  const sel = term.getSelection();
  const items = [];
  if (sel) items.push({ label: 'Copy', action: () => copyToClipboard(sel) });
  items.push({ label: 'Paste', action: pasteIntoTerminal });
  items.push({ label: 'Select all', action: () => term.selectAll() });
  items.push({ label: 'Clear', action: () => term.clear() });
  items.push({ label: 'Reload terminal', action: reloadTerminal });
  const menu = el('div', 'ctx-menu');
  for (const it of items) {
    const item = el('div', 'ctx-item', it.label);
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); it.action(); };
    menu.appendChild(item);
  }
  // On an agent surface the app receives the mouse (ADR-0013), so a plain drag
  // scrolls the agent instead of selecting. Surface the escape hatch rather
  // than leaving the user to discover it. xterm.js's force-select modifier is
  // platform-dependent — ⌥ on macOS (gated on macOptionClickForcesSelection,
  // set in ensureTerminal), Shift everywhere else — and this UI is reachable
  // from any browser, so name the right key for the client we're running on.
  if (activeSurfaceIsAgent() && !sel) {
    const hint = el('div', 'ctx-hint', `Hold ${forceSelectModifierLabel()} to select text`);
    menu.appendChild(hint);
  }
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// CROW-1027: cancel a queued onclose auto-reconnect. Idempotent — safe to call
// when nothing is pending, and a no-op when the timer's own callback (which nulls
// the id first) is what's running.
function clearTermReconnectTimer() {
  clearTimeout(termReconnectTimer);
  termReconnectTimer = null;
}

function connectTerminalWs() {
  if (sessionDead) { hideTerminalSkeleton(); return; } // don't loop after an expired remote cookie (review Yellow); clear any overlay so the #679 scrim owns the screen
  // CROW-1027: this attach supersedes any queued auto-reconnect — drop it so two
  // sockets can't race on the shared window/term.
  clearTermReconnectTimer();
  // #677: cover this (re)attach — initial connect, auto-reconnect, and the
  // explicit Reload path — with the skeleton. Agent tab/session switches no
  // longer tear the socket down (CROW-1035); they raise the overlay from
  // switchAgentWindow instead. `painted` gates the hide to the FIRST PTY byte
  // of THIS socket.
  showTerminalSkeleton();
  let painted = false;
  termWs = new WebSocket(wsURL('/terminal'));
  termWs.binaryType = 'arraybuffer';
  termWs.onopen = () => {
    // Connected — this is the brief attach case, not a reconnect loop. Drop the
    // steady "Reconnecting…" treatment, reset the backoff, and (only now) arm
    // the safety auto-hide so the overlay never strands on a quiet PTY that
    // sends no immediate output. #687: this timer must NOT live in
    // showTerminalSkeleton, or it re-fires during the disconnect loop → strobe.
    setTerminalReconnecting(false);
    clearTerminalReloadPending(); // CROW-979: the header ↻ settles when we're attached again
    termReconnectDelay = 1000;
    clearTimeout(termSkelTimer);
    termSkelTimer = setTimeout(hideTerminalSkeleton, 1500);
    // A fresh PTY starts at a default winsize, so force the real size through
    // even if cols/rows match the previous socket, and fit synchronously so the
    // resize reaches the PTY before the scrollback replay (select-window) below.
    lastTermCols = 0;
    lastTermRows = 0;
    applyTermFit();
    if (activeTerminal) {
      selectWindow(activeTerminal.window);
      // Keep the attach bookkeeping truthful after any (re)connect — initial
      // connect, reloadTerminal, or a dropped-socket auto-reconnect (#673).
      attachedWindow = activeTerminal.window;
      // CROW-1027: the fit above races the replay's capture, which can rebuild a
      // one-screen (dead-wheel) buffer. Verify shortly after and re-capture if so.
      armScrollbackHeal();
    }
  };
  termWs.onmessage = (event) => {
    if (event.data instanceof ArrayBuffer) {
      term.write(new Uint8Array(event.data));
      noteTerminalFrame(); // CROW-934 scrollback re-sync bookkeeping
      // Fade the skeleton out once the first real content has landed — rAF so
      // the hide follows the paint, not precedes it.
      if (!painted) { painted = true; requestAnimationFrame(hideTerminalSkeleton); }
    }
  };
  termWs.onclose = (event) => {
    // #687: a sustained disconnect must show ONE steady overlay, not strobe. So
    // don't hide here — keep the overlay up (idempotent showTerminalSkeleton is
    // a no-op if already loading) and switch it to the calm "Reconnecting…"
    // state; it clears on the first painted byte once reconnected. Only cancel
    // the connected-quiet safety auto-hide so it can't fire mid-loop and blank
    // the overlay. A dead session still stops reconnecting and hands off to the
    // #679 expired scrim.
    clearTimeout(termSkelTimer);
    termSkelTimer = null;
    // CROW-956: 1009 is crowd's per-message ceiling. The only thing big enough
    // to hit it on this socket is a paste — sendToPTY ships the whole clipboard
    // in one frame — and the reconnect below is otherwise indistinguishable
    // from a daemon restart, so the paste just silently vanished. A modal
    // rather than a term.write: the skeleton overlay goes up on this same path
    // and would hide an in-buffer notice, which the reconnect's scrollback
    // replay would then overwrite anyway.
    if (event && event.code === 1009) {
      alertModal('That paste was too large for the terminal — send it in smaller pieces.');
    }
    // CROW-934: this path reconnects WITHOUT going through reloadTerminal, so it
    // needs the same teardown — a sync left in flight across the drop would have
    // the fresh attach's own replay consumed as its replay (#935 review).
    resetScrollbackSync();
    if (sessionDead) { hideTerminalSkeleton(); return; }
    setTerminalReconnecting(true);
    showTerminalSkeleton();
    // CROW-1027: track the id so a manual reload can cancel this before it fires
    // (null it first inside the callback so a later clear is a harmless no-op).
    termReconnectTimer = setTimeout(() => { termReconnectTimer = null; connectTerminalWs(); }, termReconnectDelay);
    termReconnectDelay = Math.min(termReconnectDelay * 2, 10000);
  };
  termWs.onerror = () => termWs.close(); // funnels to onclose (keeps overlay up)
}

// Resize path (#661): in a browser the window `resize` event and normal page
// churn (flexbox, scrollbar appearance, devicePixelRatio changes) fire
// constantly, so an unguarded fit()+resize storms tmux with SIGWINCH and the
// grid thrashes into the corruption in the screenshot. Coalesce bursts to one
// fit per animation frame, drop no-op resizes, and never fit a 0×0/detached
// container (degenerate proposeDimensions makes a junk grid). Mirrors the
// desktop surface's applyFit/scheduleFit dedup in
// CrowTerminal/Resources/xterm/terminal.html.
let lastTermCols = 0;
let lastTermRows = 0;
let fitScheduled = false;

function applyTermFit() {
  if (!term || !fitAddon) return;
  // #667: a backgrounded surface must not become tmux's "latest" client and
  // steal the shared window size. Multiple surfaces (Tauri desktop, browser,
  // phone) share one grouped-session window whose size is `window-size latest`,
  // so an idle tab that fit()s + resizes on relayout would reflow the window for
  // the surface actually in use → the garbled rows from #661. Gate here: only
  // the focused/visible surface owns the size. It re-asserts on regaining focus
  // via takeTerminalOwnership() (window focus / visibilitychange).
  if (document.hidden || !document.hasFocus()) return;
  const node = document.getElementById('terminal');
  if (!node || !node.isConnected || node.clientWidth < 1 || node.clientHeight < 1) return;
  try { fitAddon.fit(); } catch (_) { return; }
  // Only tell the PTY when the grid actually changed — a same-size resize is a
  // needless SIGWINCH that makes the agent TUI re-reflow and clobber (#637).
  if (term.cols === lastTermCols && term.rows === lastTermRows) return;
  lastTermCols = term.cols;
  lastTermRows = term.rows;
  sendTermResize(false);
}

// Push cols/rows to the PTY. `ifNeeded` (CROW-1162) asks the daemon to skip the
// ioctl when the tmux window is already this size, so a tab-refocus can reclaim
// `window-size latest` without a same-size SIGWINCH. Ordinary fits (the grid
// actually changed) always ioctl.
function sendTermResize(ifNeeded) {
  if (!termWs || termWs.readyState !== WebSocket.OPEN) return;
  const msg = { type: 'resize', rows: term.rows, cols: term.cols };
  if (ifNeeded) msg.if_needed = true;
  termWs.send(JSON.stringify(msg));
}

// Coalesce a burst of resize/observer events into a single fit per frame. Used
// by the window `resize` listener and the container ResizeObserver; the WS-open
// path calls applyTermFit() directly so the PTY winsize is set synchronously
// before the scrollback replay (select-window).
function fitTerminal() {
  if (fitScheduled) return;
  fitScheduled = true;
  requestAnimationFrame(() => { fitScheduled = false; applyTermFit(); });
}

// #667: on regaining focus, re-assert this surface's size so it becomes tmux's
// "latest" client and reclaims the shared window size from whatever background
// surface last touched it — even if this surface's own grid didn't change (which
// applyTermFit's lastTermCols/lastTermRows dedup would otherwise swallow).
//
// CROW-1162: do NOT reset the dedup and force a same-size ioctl. TIOCSWINSZ
// always becomes tmux MSG_RESIZE, which redraws the client and SIGWINCHes the
// agent TUI even when cols/rows are unchanged. Fit locally; if the grid moved,
// send a real resize; if it didn't, send `if_needed` so the daemon ioctl's only
// when the *window* (another surface) actually differs. Wired to window `focus`
// and document `visibilitychange`.
function takeTerminalOwnership() {
  if (!term || !fitAddon) return;
  if (document.hidden || !document.hasFocus()) return;
  const node = document.getElementById('terminal');
  if (!node || !node.isConnected || node.clientWidth < 1 || node.clientHeight < 1) return;
  try { fitAddon.fit(); } catch (_) { return; }
  const same = term.cols === lastTermCols && term.rows === lastTermRows;
  lastTermCols = term.cols;
  lastTermRows = term.rows;
  sendTermResize(same);
}

// Same leading sequence as `TerminalCockpit.replayFrame` (CROW-606): home, clear
// screen, clear scrollback. Used on in-place agent switches instead of
// `term.reset()` — reset also clears `mouseTrackingMode` and other parser state
// tmux re-sends only as deltas, which is what parked Claude's caret below the
// TUI after #1036 (CROW-1035, CROW-1043).
const TERM_BUFFER_CLEAR = '\x1b[H\x1b[2J\x1b[3J';

function clearTermBuffer() {
  if (!term) return;
  try { term.write(TERM_BUFFER_CLEAR); } catch (_) {}
}

function selectWindow(win, opts) {
  if (win == null) return;
  if (termWs && termWs.readyState === WebSocket.OPEN) {
    const msg = { type: 'select-window', window: win };
    if (opts && opts.replay === false) msg.replay = false;
    termWs.send(JSON.stringify(msg));
  }
}

// CROW-934: re-sync a scrollback surface's history from tmux's pane.
//
// tmux collapses pane redraws when the attached client can't drain them fast
// enough, and the browser IS that slow client. Measured against the bundled
// config: `seq 1 20000` leaves all 19 989 lines in the pane's own history, but
// a browser-paced reader receives only ~337 of them (a raw reader gets 19 768).
// So the local xterm buffer is NOT a faithful copy of the pane — scroll-up hits
// its top after a few screens while tmux still holds the rest, and the middle
// grows holes as thinned live output accumulates (CROW-1026).
//
// crowd's `select-window` reply carries the authoritative copy
// (`capture-pane -pe -S -50000`, CROW-606) and REBUILDS the buffer in place, so
// re-requesting it is idempotent. It already ran on connect and on a tab CHANGE
// (attachWindow → reload for shells, in-place select-window for agents),
// which is why switching away and back "fixed" the history — but the tab
// you sit on never re-synced.
//
// Two triggers: reaching the top of the local buffer (asking for older lines)
// and, since CROW-1026, going idle parked on a hole mid-buffer. Only a PLAIN
// SHELL is eligible. An agent surface — alt-buffer OR inline — must not
// mid-session re-capture (CROW-1048). Cursor never issues smcup; its live
// bytes ARE the transcript. Re-injecting capture-pane onto that already-painted
// chrome is how the idle/prompt tip, model line, and cwd stack after every
// tool call (and when scrolling history). #1010 kept the unified 50k so the
// wheel still works; connect/reload select-window still restores that history
// (CROW-606). In-place agent switches skip replay (CROW-1035). Only a true
// alt-buffer agent was already excluded server-side
// (capture returns just the viewport); CROW-1048 extends the skip to inline
// agents for a different reason: the replay is harmful, not empty.
//
// Two independent brakes, because `onScroll` is NOT a user-scroll event: xterm's
// BufferService.scroll ends in an unconditional `this._onScroll.fire(ydisp)`, so
// it fires for every line pushed at the bottom, and a viewport the user parked
// at the top stays pinned at `ydisp === 0` (`Math.max(ydisp - 1, 0)` once the
// buffer is full). Reading early output while a build keeps printing therefore
// satisfies every guard on every output line. Without a brake each capture
// re-armed the next one — two tmux spawns and the whole 50k history per round
// trip, indefinitely (#935 review).
//
//   * Arriving at the top is a TRANSITION, not a position. xterm pins a
//     top-parked viewport at `ydisp === 0` while output streams, so "still at
//     the top" fires forever; "just got here" fires once per visit and covers
//     the wheel, touch, the scrollbar and Shift+PageUp alike.
//   * `lastHydrateAt` is the backstop if that ever fires more than expected.
//   * `scrollbackFullySynced` latches off entirely once a capture comes back
//     with nothing new, until the viewport leaves the top. That is also what
//     keeps the one speculative capture per tab (the connect replay already left
//     the buffer authoritative, but we can't tell that without asking) from
//     repeating.
const HYDRATE_MIN_INTERVAL_MS = 5000;
// A flight ends this long after the last frame, but never later than
// HYDRATE_MAX_FLIGHT_MS after it armed. The cap is load-bearing: frames are not
// batched (one WS binary frame per PTY read chunk), so on a shell printing more
// often than the quiet window, an extend-only settle would never fire and
// `hydratingScrollback` would latch true for the life of the socket — silently
// disabling the feature on exactly the workload it exists for (#935 review).
const HYDRATE_QUIET_MS = 150;
const HYDRATE_MAX_FLIGHT_MS = 3000;
let scrollbackDirty = true; // live output may have dropped lines since the last sync
let hydratingScrollback = false;
let hydrateSettleTimer = null;
let hydrateArmedAt = 0; // start of the current flight, for the absolute deadline
let hydrateBaseY = 0; // scrollback depth when the capture was armed
let hydrateSawReplay = false; // did any bytes actually land during the flight?
let scrollbackFullySynced = false; // last capture returned nothing new
let lastHydrateAt = 0;
let lastViewportY = 0; // previous scroll position, to detect arrival at the top

// CROW-1027: post-attach scrollback self-heal. The reload/attach fits (resizes)
// the pane immediately before select-window replays it, so `capture-pane` can run
// mid-reflow and come back ONE screen tall — the replay's ESC[3J then wipes what
// little history the buffer had, leaving `baseY === 0` and a dead wheel. A brief
// settle after attach, then a re-capture when the buffer really is one screen
// tall, rebuilds it against a now-settled pane. Gated on `baseY === 0` so a
// healthy attach (the common case) sends nothing, and bounded so it never loops.
const SCROLLBACK_HEAL_MS = 250; // distinct from 1500 (skeleton) / 10000 (reload settle)
const SCROLLBACK_HEAL_MAX = 2; // bounded re-captures — accept a genuine one-screen pane after this
let scrollbackHealTimer = null;
let scrollbackHealLeft = 0;

// CROW-1026: arrival-at-top is not the only place a hole appears — the thinned
// live stream drops lines anywhere in the middle, and the user may be parked on
// one. Debounce off `onScroll` (which also fires for every line pushed at the
// bottom): the timer re-arms on each scroll AND each output frame, so it fires
// exactly once, only after scrolling AND output have both gone quiet. During a
// streaming build it never fires; when the user stops on a mid-buffer hole it
// re-captures once, subject to every brake the arrival path uses.
const HYDRATE_SCROLL_IDLE_MS = 400;
let hydrateIdleTimer = null;

// The flight ends this long after the last frame, but never later than the
// arm-time deadline. There is deliberately NO viewport restore here: the replay
// rebuilds the buffer while `isUserScrolling` is true (which the trigger's
// `viewportY === 0 && baseY > 0` guards imply), and every write then takes
// `isUserScrolling || i.ydisp++` / `isUserScrolling && (ydisp = max(ydisp-1,0))`,
// so `ydisp` stays pinned at 0 — the rebuild leaves the user on the oldest lines
// by itself. A `scrollToTop()` here would be `Viewport.scrollLines(-0)`, the same
// scrollTop, hence a no-op on that path; the ONLY way to reach it non-inert is
// the user leaving the top mid-flight (the #668 pill calls `scrollToBottom()`,
// clearing `isUserScrolling` so `ydisp` tracks the bottom), where it would yank
// them off the live prompt to line 1 of a 20k buffer. It never helps and acts
// only when acting is wrong, so it is gone (#935 review round 3).
function scheduleHydrateSettle(ms) {
  clearTimeout(hydrateSettleTimer);
  const remaining = hydrateArmedAt + HYDRATE_MAX_FLIGHT_MS - Date.now();
  hydrateSettleTimer = setTimeout(() => {
    hydratingScrollback = false;
    const buf = term && term.buffer && term.buffer.active;
    if (hydrateSawReplay) {
      // Nothing deeper came back → the local buffer already matches the pane, so
      // stop asking until the viewport moves off the top.
      if (buf && buf.baseY <= hydrateBaseY) scrollbackFullySynced = true;
    } else {
      // An empty flight proves nothing — neither that we synced (so no latch)
      // nor that the buffer is clean. Arming cleared `scrollbackDirty` on the
      // premise of a sync that never happened; put it back so a retry is
      // possible without waiting for live output.
      scrollbackDirty = true;
    }
  }, Math.max(0, Math.min(ms, remaining)));
}

// The socket's per-frame bookkeeping, named so the tests can drive the real
// thing rather than a stand-in (the extend-forever bug above lived here and the
// suite modelled only the `else` branch, so it couldn't see it).
function noteTerminalFrame() {
  // While a re-sync is in flight these bytes are (or accompany) the replay —
  // record that one landed and hold the settle open until the rebuild is quiet.
  // Otherwise they're live output, which tmux may again have thinned, so the
  // next arrival at the top should re-sync.
  if (hydratingScrollback) { hydrateSawReplay = true; scheduleHydrateSettle(HYDRATE_QUIET_MS); }
  else scrollbackDirty = true;
}

// Shared by reloadTerminal and the onclose auto-reconnect: both tear the socket
// down, and a sync left in flight across one would have the fresh attach's own
// replay consumed as its replay.
function resetScrollbackSync() {
  clearTimeout(hydrateSettleTimer);
  hydrateSettleTimer = null;
  clearTimeout(hydrateIdleTimer); // CROW-1026: drop a pending mid-buffer re-sync too
  hydrateIdleTimer = null;
  hydratingScrollback = false;
  hydrateSawReplay = false;
  scrollbackFullySynced = false;
  scrollbackDirty = true;
  lastHydrateAt = 0; // the new surface gets its own budget, not the old one's
  lastViewportY = 0; // ...and its own scroll history, not the old one's position
  // CROW-1027: drop any pending self-heal — a fresh attach arms its own.
  clearTimeout(scrollbackHealTimer);
  scrollbackHealTimer = null;
  scrollbackHealLeft = 0;
}

// CROW-1027: arm the post-attach scrollback check. Called from onopen after
// select-window, so it runs once per (re)attach; resetScrollbackSync clears it on
// the next teardown.
function armScrollbackHeal() {
  clearTimeout(scrollbackHealTimer);
  scrollbackHealLeft = SCROLLBACK_HEAL_MAX;
  scrollbackHealTimer = setTimeout(verifyScrollbackAfterAttach, SCROLLBACK_HEAL_MS);
}

// If the attach's replay rebuilt a one-screen buffer (`baseY === 0`) on a surface
// that owns its scrollback locally, re-issue one select-window so crowd re-captures
// the pane — by now the resize's reflow has settled, so the capture carries the
// full history and the wheel comes back. A healthy buffer (`baseY > 0`) sends
// nothing. Bounded by scrollbackHealLeft so a genuinely one-screen pane is accepted
// rather than re-captured forever.
function verifyScrollbackAfterAttach() {
  scrollbackHealTimer = null;
  if (!term || !activeTerminal) return;
  // Only a TRUE alt-buffer agent (Claude Code that entered the alt screen)
  // forwards the wheel and has no local scrollback to repair (AC #3). An inline
  // agent — Cursor, or an inline-rendering Claude build (CROW-1023) — keeps the
  // unified 50k and CAN land on a one-screen buffer after a resize-then-capture
  // attach, so connect/reload still heals. This is NOT the same gate as
  // fireScrollbackCapture: that skip is mid-session (CROW-1048); this heal is
  // first-attach only and is not armed from switchAgentWindow.
  if (activeSurfaceIsAgent() && activeSurfaceUsesAltScreen()) return;
  if (activeTerminal.window == null) return;
  if (!termWs || termWs.readyState !== WebSocket.OPEN) return;
  const buf = term.buffer && term.buffer.active;
  if (!buf || buf.type === 'alternate') return;
  if (buf.baseY > 0) return; // scrollback present → healthy, stop
  if (scrollbackHealLeft <= 0) return; // exhausted → accept a real one-screen pane
  scrollbackHealLeft -= 1;
  selectWindow(activeTerminal.window); // re-capture against the now-settled pane
  scrollbackHealTimer = setTimeout(verifyScrollbackAfterAttach, SCROLLBACK_HEAL_MS);
}

// Shared arm tail for both hydrate triggers (arrival-at-top and the CROW-1026
// scroll-idle mid-buffer heal). The caller has already decided this surface has a
// hole worth re-fetching; here we apply the surface/socket/cooldown brakes and, if
// they pass, arm exactly one authoritative re-capture.
function fireScrollbackCapture(buf) {
  if (!activeTerminal || activeTerminal.window == null) return;
  // Agent TUIs must not mid-session re-capture (CROW-1048). An alt-buffer
  // Claude has nothing to fetch (capture is the live frame). An inline agent
  // (Cursor) keeps the unified 50k, but replaying that pane onto an already-
  // painted TUI deposits a second chrome copy — the #1014 sediment. Shells
  // still hydrate: their live stream is a thinned log, not a repainting TUI.
  if (activeSurfaceIsAgent()) return;
  if (!termWs || termWs.readyState !== WebSocket.OPEN) return;
  const now = Date.now();
  if (now - lastHydrateAt < HYDRATE_MIN_INTERVAL_MS) return;
  lastHydrateAt = now;
  hydratingScrollback = true;
  scrollbackDirty = false;
  hydrateArmedAt = now;
  hydrateBaseY = buf.baseY;
  hydrateSawReplay = false;
  scheduleHydrateSettle(2000);
  selectWindow(activeTerminal.window);
}

// CROW-1026: (re)arm the scroll-idle mid-buffer heal. Debounced off `onScroll`,
// which also fires for every line pushed at the bottom — so a streaming build
// keeps pushing the deadline out and this never fires mid-stream; it fires once
// when scrolling AND output have both gone quiet.
function scheduleHydrateIdle() {
  clearTimeout(hydrateIdleTimer);
  hydrateIdleTimer = setTimeout(hydrateWhenIdle, HYDRATE_SCROLL_IDLE_MS);
}

// Heal a hole the user parked on mid-buffer, without a trip to line 1. The arrival
// path owns viewportY 0; this owns everything below it. Every brake the arrival
// path uses still applies (in-flight, latch, dirty, cooldown, settle), so #935's
// extend-forever cannot return: a heal that finds new lines leaves scrollbackDirty
// false until fresh output dirties it, and one that finds nothing new latches via
// the unchanged settle. As on the arrival path there is no viewport restore, so
// the rebuild (isUserScrolling) leaves the user at the top of the healed history.
function hydrateWhenIdle() {
  if (!term) return;
  if (activeSurfaceIsAgent()) return; // defense in depth (CROW-1048 / #1047)
  const buf = term.buffer.active;
  if (buf.viewportY === 0) return; // the top is the arrival path's job
  if (hydratingScrollback) return;
  if (scrollbackFullySynced || !scrollbackDirty) return;
  if (buf.baseY === 0) return;
  fireScrollbackCapture(buf);
}

function maybeHydrateScrollback() {
  if (!term) return;
  // CROW-1048: don't even arm the idle timer on an agent TUI. fireScrollbackCapture
  // would no-op, but onScroll fires per output line and a 400ms timer per line
  // is wasted work — and a future edit that widened the capture gate would
  // silently re-stack Cursor chrome after every tool call.
  if (activeSurfaceIsAgent()) return;
  scheduleHydrateIdle(); // CROW-1026: any scroll/frame re-arms the mid-buffer heal
  const buf = term.buffer.active;
  const arrivedAtTop = buf.viewportY === 0 && lastViewportY !== 0;
  lastViewportY = buf.viewportY;
  if (hydratingScrollback) return;
  // Leaving the top re-arms the latch — there is new ground to cover next time.
  if (buf.viewportY !== 0) { scrollbackFullySynced = false; return; }
  // Parked at the top rather than newly arrived: xterm fires onScroll for every
  // line pushed at the bottom, and pins ydisp at 0 while the user sits there.
  if (!arrivedAtTop) return;
  if (scrollbackFullySynced || !scrollbackDirty) return;
  // `baseY > 0` is load-bearing: on a tab that has printed less than one screen
  // viewportY is permanently 0, so there is no scrollback to go fetch.
  if (buf.baseY === 0) return;
  fireScrollbackCapture(buf);
}

// Which tmux window this shared surface shows changes on both a terminal-tab
// switch (switchTerminal) and a session switch (refreshTerminals).
//
// Shells keep the #673 full reload (term.reset + fresh socket): a plain
// select-window on the live socket left the grid mismatched when another
// surface had reshaped the window, and only Reload recovered it.
//
// Agent TUIs must NOT take that path (CROW-1035). The reload opens a new
// PTY at tmux's default 24×80, SIGWINCHes it to the real size, then injects
// a capture-pane replay that races the live attach redraw. On Claude (alt
// buffer) the caret lands below the input box; on Cursor the footer chrome
// stacks one extra copy. Switch those in place: clear the local buffer so
// the previous window's cells don't leak (not `term.reset()` — that also
// clears modes tmux won't re-send), then select-window with `replay: false`
// on the live socket. No new PTY, no same-size SIGWINCH (#637), no
// capture-pane dump racing the live attach (alt-buffer and inline alike).
//
// Only act when the target window differs, so background refreshes /
// re-clicking the active tab don't churn. When the socket isn't open yet,
// connectTerminalWs's onopen selects this window against a fresh surface.
let attachedWindow = null;
function attachWindow(win) {
  if (win == null || win === attachedWindow) return;
  attachedWindow = win;
  if (!termWs || termWs.readyState !== WebSocket.OPEN) return;
  if (activeSurfaceIsAgent()) { switchAgentWindow(win); return; }
  reloadTerminal();
}

// In-place window switch for agent TUIs. See attachWindow.
function switchAgentWindow(win) {
  if (!term) return;
  showTerminalSkeleton();
  clearTimeout(termSkelTimer);
  termSkelTimer = setTimeout(hideTerminalSkeleton, 1500);
  clearTermBuffer();
  applySurfaceScrollback();
  resetScrollbackSync();
  selectWindow(win, { replay: false });
  // CROW-1091: run the SAME sizing step the reload/connect attach runs, which
  // this in-place path had skipped. `reloadTerminal`/onopen call `applyTermFit()`
  // on attach — and `fitAddon.fit()` re-syncs xterm's scroll area, which is what
  // gives the history scrollbar its geometry — so a shell switch already resized
  // itself. The agent in-place switch (CROW-1035) did neither, so a switched-in
  // surface kept the previous window's grid geometry and its scrollbar sizing
  // until a manual reload re-ran the fit — the reported "no scroll bar until
  // refresh." Fit here too (deferred a frame via fitTerminal so it measures the
  // pane at its settled post-switch layout — the tab bar / header height differs
  // between session kinds), and re-check the pinned-visible class right away so it
  // reflects the switched-in buffer instead of the previous window's. No replay
  // and no new PTY, so this stays clear of the CROW-1035 caret jump and CROW-1048
  // chrome stacking a full reload would reintroduce; a same-size switch fits to
  // identical cols/rows, so applyTermFit sends no SIGWINCH (#637).
  //
  // CROW-1162: this is the same coalesced `fitTerminal` the container
  // ResizeObserver uses, so a post-switch layout settle does not double-fire a
  // PTY resize — both collapse to one applyTermFit per animation frame.
  fitTerminal();
  updateTerminalScrollbar();
  // Do not arm CROW-1027 here. In-place switch has no new PTY and no
  // SIGWINCH, so the mid-reflow one-screen capture that heal exists for
  // cannot happen. A second select-window 250ms later (the fake-xterm
  // baseY===0 case, or a slow 50k replay) re-injects the current chrome
  // on top of the first replay — the CROW-1035 stack, back on the
  // switch path (CROW-1048). Connect/reload still arm the heal: that
  // attach really does resize first.
}

// Right-click "Reload terminal" (#661): recover a corrupted/thrashed surface
// without a full browser refresh. Reset the xterm buffer to drop the mangled
// grid, then force a clean WebSocket reconnect — the fresh attach re-fits and
// re-selects the window (onopen), so crowd replays the pane's tmux scrollback
// and repaints against a now-stable layout. Same recovery a page reload gives,
// scoped to the terminal surface. Detach the old socket's handlers first so its
// onclose/onerror can't reconnect or close the new socket (they reference the
// module-level termWs, which we're about to reassign).
function reloadTerminal() {
  if (!term) return;
  try { term.reset(); } catch (_) {}
  lastTermCols = 0;
  lastTermRows = 0;
  // CROW-934: the reconnect re-selects the window, so crowd replays the pane
  // anyway — drop any in-flight re-sync (its restore would fight the fresh
  // attach) and treat the rebuilt buffer as needing one again.
  resetScrollbackSync();
  // CROW-1027: cancel a queued auto-reconnect so it can't open a second socket
  // that races the one we're about to build on the shared window/term.
  clearTermReconnectTimer();
  if (termWs) {
    const old = termWs;
    old.onopen = old.onmessage = old.onclose = old.onerror = null;
    try { old.close(); } catch (_) {}
    termWs = null;
  }
  connectTerminalWs();
}
