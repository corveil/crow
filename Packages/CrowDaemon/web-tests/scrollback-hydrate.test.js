const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-934: the shell-scrollback re-sync. tmux collapses pane redraws for a slow
// client (the browser), so the local xterm buffer holds far fewer lines than the
// pane's own history — measured 337/20000 for a browser-paced reader. Arriving
// at the top of the local buffer re-requests crowd's authoritative replay
// (`select-window` → `capture-pane -pe -S -50000`).
//
// The harness fakes BOTH timers and the clock, and drives the real
// `noteTerminalFrame` rather than a stand-in, because every bug found in review
// so far has lived across a timer boundary on the frame path:
//   - a stubbed no-op setTimeout hid a re-capture loop (#935 round 1);
//   - modelling a live frame as `scrollbackDirty = true` took the `else` branch
//     and hid a settle that live output could extend forever (round 2).
const epilogue = `
;globalThis.__t = {
  maybeHydrateScrollback(){ return maybeHydrateScrollback(); },
  noteTerminalFrame(){ return noteTerminalFrame(); },
  resetScrollbackSync(){ return resetScrollbackSync(); },
  set term(v){ term = v; },
  set termWs(v){ termWs = v; },
  set activeTerminal(v){ activeTerminal = v; },
  set scrollbackDirty(v){ scrollbackDirty = v; },
  get scrollbackDirty(){ return scrollbackDirty; },
  get hydratingScrollback(){ return hydratingScrollback; },
  get scrollbackFullySynced(){ return scrollbackFullySynced; },
  set lastViewportY(v){ lastViewportY = v; },
  set lastHydrateAt(v){ lastHydrateAt = v; },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body><div id="terminal"></div></body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;
window.WebSocket = function () {
  return { send() {}, close() {},
    set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
};
window.WebSocket.OPEN = 1;
window.TextEncoder = TextEncoder;
window.setInterval = () => 0;
window.requestAnimationFrame = () => 0;

// Fake clock + timers. Timers carry their due time so `advance` can fire only
// what has actually come due — the deadline cases depend on that ordering.
let fakeNow = 1e6;
window.Date.now = () => fakeNow;
let timerSeq = 1;
const timers = new Map();
window.setTimeout = (fn, ms) => { const id = timerSeq++; timers.set(id, { fn, due: fakeNow + (ms || 0) }); return id; };
window.clearTimeout = (id) => { timers.delete(id); };
function advance(ms) {
  fakeNow += ms;
  for (const [id, t] of [...timers.entries()]) {
    if (t.due <= fakeNow) { timers.delete(id); t.fn(); }
  }
}

const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

// ---- Fakes -----------------------------------------------------------------

// `baseY` is how many lines have scrolled off the top (whether scrollback exists
// at all); `viewportY` is where the user is looking, 0 == the very top. The fake
// records any attempt to move the viewport: the settle must never make one.
let sends, fake;
function setup({ agentSurface = false, usesAltScreen = false, baseY = 500, viewportY = 0, from = 400,
                 readyState = 1, window: win = 7, dirty = true } = {}) {
  sends = [];
  timers.clear();
  fake = {
    buffer: { active: { baseY, viewportY } },
    moves: 0,
    scrollToTop() { this.moves++; this.buffer.active.viewportY = 0; },
    scrollToBottom() { this.moves++; this.buffer.active.viewportY = this.buffer.active.baseY; },
    scrollLines(n) { this.moves++; },
  };
  T.term = fake;
  T.termWs = { readyState, send(s) { sends.push(JSON.parse(s)); } };
  T.activeTerminal = win === null ? null
    : { id: 't1', window: win, agent_surface: agentSurface, uses_alternate_screen: usesAltScreen };
  T.resetScrollbackSync();
  T.scrollbackDirty = dirty;
  T.lastViewportY = from; // where the user scrolled FROM (0 == already parked)
  T.lastHydrateAt = 0;
  return sends;
}
const selects = () => sends.filter((m) => m.type === 'select-window');

console.log('scrollback hydrate (CROW-934)');

// ---- Gating ----------------------------------------------------------------

{
  setup({ baseY: 297, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('arriving at the top of a thinned buffer re-requests the replay',
    selects().length === 1 && selects()[0].window === 7);
  check('  ... and marks the sync in flight', T.hydratingScrollback === true);
  check('  ... and clears the dirty flag', T.scrollbackDirty === false);
}
{
  setup({ agentSurface: true, usesAltScreen: true });
  T.maybeHydrateScrollback();
  check('alt-buffer agent (Claude Code) never re-syncs', selects().length === 0);
}
{
  // CROW-1048: an inline agent (Cursor, and every Manager tab) is agent_surface
  // and keeps the unified 50k so the wheel works (#1010), but mid-session
  // capture-pane replay deposits a second chrome copy. Connect/switch still
  // restore history; only this live hydrate is skipped.
  setup({ agentSurface: true, usesAltScreen: false });
  T.maybeHydrateScrollback();
  check('inline agent (Cursor/Manager) never mid-session re-syncs', selects().length === 0);
}
{
  // A plain shell inside a Claude session is uses_alternate_screen (kind-scoped)
  // yet NOT agent_surface — it has a real 50k buffer, so it stays eligible.
  setup({ agentSurface: false, usesAltScreen: true });
  T.maybeHydrateScrollback();
  check('plain shell in a Claude session still re-syncs', selects().length === 1);
}
{
  setup({ baseY: 0, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('short buffer (no scrollback yet) does not re-sync', selects().length === 0);
}
{
  setup({ baseY: 500, viewportY: 120 });
  T.maybeHydrateScrollback();
  check('mid-buffer scroll does not re-sync synchronously', selects().length === 0);
}
{
  setup({ dirty: false });
  T.maybeHydrateScrollback();
  check('already-synced buffer does not re-sync', selects().length === 0);
}
{
  setup();
  T.maybeHydrateScrollback(); T.maybeHydrateScrollback(); T.maybeHydrateScrollback();
  check('repeated calls within one in-flight sync issue exactly one capture', selects().length === 1);
}
{
  setup({ readyState: 3 /* CLOSED */ });
  T.maybeHydrateScrollback();
  check('closed socket does not re-sync', selects().length === 0);
}
{
  setup({ window: null });
  T.maybeHydrateScrollback();
  check('no active terminal does not re-sync', selects().length === 0);
}

// ---- Arrival, not position (round 1 Red + round 2 Green 1) -----------------

console.log('\n  parked at the top while output streams');
{
  // xterm fires onScroll for every line pushed at the bottom and pins a
  // top-parked viewport at ydisp 0, so "still at the top" fires forever. Only
  // ARRIVING there should capture.
  setup({ baseY: 400, viewportY: 0, from: 0 });
  T.maybeHydrateScrollback();
  check('already parked at the top does not capture', selects().length === 0);

  setup({ baseY: 400, viewportY: 0, from: 400 });
  T.maybeHydrateScrollback();      // arrival → one capture
  fake.buffer.active.baseY = 19949;
  advance(3000);                   // settle
  for (let line = 0; line < 500; line++) {
    T.scrollbackDirty = true;      // a live frame's bookkeeping
    T.maybeHydrateScrollback();    // its onScroll, viewport still pinned at 0
    advance(20);
  }
  check('500 output lines at the top do not each trigger a capture', selects().length === 1);
  check('  ... and the surface is not stuck mid-flight', T.hydratingScrollback === false);
}
{
  // Latch: a capture that comes back no deeper means the buffer already matches
  // the pane, so stop asking until the viewport leaves the top.
  setup({ baseY: 19949, viewportY: 0 });
  T.maybeHydrateScrollback();
  T.noteTerminalFrame();       // the replay lands
  advance(3000);               // settle; baseY unchanged → nothing new came back
  check('a capture that returns nothing new latches off', T.scrollbackFullySynced === true);
  T.lastHydrateAt = 0;         // prove the latch holds independent of the cooldown
  T.scrollbackDirty = true;
  T.lastViewportY = 400;       // and independent of the arrival gate
  T.maybeHydrateScrollback();
  check('  ... and a further arrival at the top does not re-capture', selects().length === 1);
  fake.buffer.active.viewportY = 900; // user scrolls away
  T.maybeHydrateScrollback();
  check('  ... leaving the top re-arms it', T.scrollbackFullySynced === false);
}
{
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  advance(3000); // no frame ever landed
  check('an empty flight does not latch (it proves nothing)', T.scrollbackFullySynced === false);
  // ...and it must not leave `scrollbackDirty` false either, or the retry the
  // missing latch is meant to allow would be blocked anyway.
  check('  ... and restores the dirty flag so a retry is possible', T.scrollbackDirty === true);
  T.lastHydrateAt = 0;
  T.lastViewportY = 400;
  T.maybeHydrateScrollback();
  check('  ... so arriving at the top again does re-capture', selects().length === 2);
}

// ---- The settle cannot be extended forever (round 2 Yellow 1) --------------

console.log('\n  busy shell during a flight');
{
  // Frames are not batched — one WS frame per PTY read chunk — so a build
  // printing faster than the quiet window used to hold the settle open forever,
  // latching hydratingScrollback true and silently disabling the feature.
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('a sync is in flight', T.hydratingScrollback === true);
  for (let i = 0; i < 200; i++) { T.noteTerminalFrame(); advance(100); } // 20 s of chatter
  check('the absolute deadline ends the flight anyway', T.hydratingScrollback === false);
  // Split rather than `A || B`: as a disjunct either half alone passed it, so it
  // could not fail for the reason it was named.
  check('  ... the latch did not trip (the replay did land)', T.scrollbackFullySynced === true);
  check('  ... and later live output can mark it dirty again', (() => {
    T.noteTerminalFrame(); return T.scrollbackDirty === true;
  })());
}

// ---- The settle never moves the viewport (round 3 Yellow) ------------------

console.log('\n  the settle leaves the viewport alone');
{
  // The replay rebuilds with isUserScrolling true, so ydisp stays pinned at 0
  // and the user is already on the oldest lines. A restore here would be a
  // no-op on that path — and a real, harmful scroll on the one path where the
  // user has left the top mid-flight.
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  T.noteTerminalFrame();
  fake.buffer.active.baseY = 19949;
  advance(3000);
  check('a landed replay does not move the viewport', fake.moves === 0);
}
{
  // The #668 jump-to-bottom pill mid-flight: scrollToBottom() clears
  // isUserScrolling, so ydisp tracks the bottom. The settle must not drag the
  // user off the live prompt back to line 1.
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  T.noteTerminalFrame();
  fake.buffer.active.baseY = 19949;
  fake.buffer.active.viewportY = 19949; // user hit the pill
  advance(3000);
  check('the jump-to-bottom pill mid-flight is not overridden', fake.moves === 0);
  check('  ... and the viewport is still at the bottom', fake.buffer.active.viewportY === 19949);
}

// ---- Teardown parity (round 1 Yellow 2, round 2 Green 2) -------------------

console.log('\n  teardown');
{
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('a sync is in flight', T.hydratingScrollback === true);
  T.resetScrollbackSync(); // what both reloadTerminal and onclose call
  check('reset clears the in-flight sync', T.hydratingScrollback === false);
  check('  ... re-arms the dirty flag', T.scrollbackDirty === true);
  check('  ... and clears the latch', T.scrollbackFullySynced === false);
  advance(3000);
  check('  ... and the dropped settle does nothing', fake.moves === 0 && T.scrollbackDirty === true);
}
{
  // Green 2: a new surface gets its own cooldown budget, not the old one's.
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();     // consumes the budget
  advance(3000);
  T.resetScrollbackSync();        // tab switch
  T.lastViewportY = 400;
  fake.buffer.active.viewportY = 0;
  T.maybeHydrateScrollback();
  check('reset clears the cooldown so a new surface can sync immediately',
    selects().length === 2);
}

// ---- CROW-1026: mid-buffer scroll-idle heal --------------------------------

console.log('\n  mid-buffer scroll-idle heal');
{
  // A hole the user parked on mid-buffer heals once scrolling AND output go
  // quiet — no trip to line 1, no manual Reload. The debounce is 400ms; advance
  // past it to fire the pending re-capture.
  setup({ baseY: 500, viewportY: 120 });
  T.maybeHydrateScrollback();
  check('the scroll itself issues no synchronous capture', selects().length === 0);
  advance(500);
  check('going idle mid-buffer heals the hole',
    selects().length === 1 && selects()[0].window === 7);
}
{
  // The debounce re-arms on every scroll AND every bottom-pushed line (onScroll
  // is not a user event), so a streaming build never trips it mid-stream.
  setup({ baseY: 500, viewportY: 120 });
  for (let i = 0; i < 50; i++) { T.maybeHydrateScrollback(); advance(100); } // 100 < 400
  check('a streaming build never fires the idle heal', selects().length === 0);
  advance(500);
  check('  ... but one settle after it stops heals once', selects().length === 1);
}
{
  // Alt-buffer agents (Claude Code) have no scrollback to fetch — excluded on the
  // idle path too, not only the arrival path.
  setup({ agentSurface: true, usesAltScreen: true, baseY: 500, viewportY: 120 });
  T.maybeHydrateScrollback();
  advance(500);
  check('alt-buffer agent is excluded from the idle heal', selects().length === 0);
}
{
  // CROW-1048: Cursor's idle-prompt chrome stacked after every tool call because
  // the 400ms idle heal re-injected capture-pane onto the already-painted TUI.
  // Same skip as the arrival path — agent_surface, not uses_alternate_screen.
  setup({ agentSurface: true, usesAltScreen: false, baseY: 500, viewportY: 120 });
  T.maybeHydrateScrollback();
  advance(500);
  check('inline agent is excluded from the idle heal', selects().length === 0);
}
{
  // The dirty flag is the idle path's primary brake: an already-synced buffer
  // (nothing thinned since the last sync) does not re-capture.
  setup({ baseY: 500, viewportY: 120, dirty: false });
  T.maybeHydrateScrollback();
  advance(500);
  check('a clean buffer does not idle-heal', selects().length === 0);
}
{
  // After an idle heal that returns new lines, scrollbackDirty stays false, so
  // fiddling the scroll again does not re-capture until fresh output dirties it.
  setup({ baseY: 500, viewportY: 120 });
  T.maybeHydrateScrollback();
  advance(500);                       // heal #1
  fake.buffer.active.baseY = 19949;   // the replay brought the full history...
  T.noteTerminalFrame();              // ...landing during the flight
  advance(3000);                      // settle: saw replay, baseY grew → not latched, dirty stays false
  check('the idle heal issued exactly one capture', selects().length === 1);
  check('  ... and consumed the dirty flag', T.scrollbackDirty === false);
  fake.buffer.active.viewportY = 90;  // user nudges the scroll again
  T.maybeHydrateScrollback();
  advance(500);
  check('  ... so a clean buffer does not heal again', selects().length === 1);
  T.noteTerminalFrame();              // fresh live output (not in flight) re-dirties
  check('  ... until fresh output marks it dirty', T.scrollbackDirty === true);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
