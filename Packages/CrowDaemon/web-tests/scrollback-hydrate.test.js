const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-934: the shell-scrollback re-sync. tmux collapses pane redraws for a slow
// client (the browser), so the local xterm buffer holds far fewer lines than the
// pane's own history — measured 337/20000 for a browser-paced reader. Reaching
// the top of the local buffer re-requests crowd's authoritative replay
// (`select-window` → `capture-pane -pe -S -50000`).
//
// Timers are a FAKE QUEUE rather than the no-op stub the other scroll suites
// use, because the whole settle cycle — the restore, the latch, the dirty/settle
// branch in onmessage — only exists across a timer boundary. The #935 review
// found a re-capture loop that lived exactly there: `onScroll` is not a
// user-scroll event (xterm's BufferService.scroll ends in an unconditional
// `_onScroll.fire`), so a viewport parked at the top re-armed the capture on
// every output line. A stubbed timer cannot see that; the loop case below is the
// regression pin.
const epilogue = `
;globalThis.__t = {
  maybeHydrateScrollback(){ return maybeHydrateScrollback(); },
  resetScrollbackSync(){ return resetScrollbackSync(); },
  sendToPTY(s){ return sendToPTY(s); },
  set term(v){ term = v; },
  set termWs(v){ termWs = v; },
  set activeTerminal(v){ activeTerminal = v; },
  set scrollbackDirty(v){ scrollbackDirty = v; },
  get scrollbackDirty(){ return scrollbackDirty; },
  get hydratingScrollback(){ return hydratingScrollback; },
  get scrollbackFullySynced(){ return scrollbackFullySynced; },
  set hydrateSawReplay(v){ hydrateSawReplay = v; },
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

// Fake timers: collect pending callbacks so a test can run them on demand.
let timerSeq = 1;
const timers = new Map();
window.setTimeout = (fn, ms) => { const id = timerSeq++; timers.set(id, { fn, ms }); return id; };
window.clearTimeout = (id) => { timers.delete(id); };
// Run every pending timer once (the settle is the only one these tests arm).
function runTimers() {
  const due = [...timers.entries()];
  timers.clear();
  for (const [, t] of due) t.fn();
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
// at all); `viewportY` is where the user is looking, 0 == the very top.
let sends, fake;
function setup({ agentSurface = false, baseY = 500, viewportY = 0,
                 readyState = 1, window: win = 7, dirty = true } = {}) {
  sends = [];
  timers.clear();
  fake = {
    buffer: { active: { baseY, viewportY } },
    scrolledToTop: 0,
    scrollToTop() { this.scrolledToTop++; this.buffer.active.viewportY = 0; },
  };
  T.term = fake;
  T.termWs = { readyState, send(s) { sends.push(JSON.parse(s)); } };
  T.activeTerminal = win === null ? null : { id: 't1', window: win, agent_surface: agentSurface };
  T.resetScrollbackSync();
  T.scrollbackDirty = dirty;
  T.lastHydrateAt = 0; // no cooldown carried in from a previous case
  return sends;
}
const selects = () => sends.filter((m) => m.type === 'select-window');

console.log('scrollback hydrate (CROW-934)');

// ---- Gating ----------------------------------------------------------------

{
  setup({ baseY: 297, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('shell at top of a thinned buffer re-requests the replay',
    selects().length === 1 && selects()[0].window === 7);
  check('  ... and marks the sync in flight', T.hydratingScrollback === true);
  check('  ... and clears the dirty flag', T.scrollbackDirty === false);
}
{
  setup({ agentSurface: true });
  T.maybeHydrateScrollback();
  check('agent surface never re-syncs', selects().length === 0);
}
{
  setup({ baseY: 0, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('short buffer (no scrollback yet) does not re-sync', selects().length === 0);
}
{
  setup({ baseY: 500, viewportY: 120 });
  T.maybeHydrateScrollback();
  check('mid-buffer scroll does not re-sync', selects().length === 0);
}
{
  setup({ dirty: false });
  T.maybeHydrateScrollback();
  check('already-synced buffer does not re-sync', selects().length === 0);
}
{
  setup();
  T.maybeHydrateScrollback(); T.maybeHydrateScrollback(); T.maybeHydrateScrollback();
  check('repeated scrolls within one in-flight sync issue exactly one capture', selects().length === 1);
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

// ---- The #935 review's Red finding: no unbounded re-capture loop -----------

console.log('\n  streaming output while parked at the top');
{
  // The exact repro: read early output while a build keeps printing. Every
  // output line marks the buffer dirty and fires onScroll with the viewport
  // still pinned at 0. Before the fix this re-armed a full 50k capture per line.
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();          // first capture
  fake.buffer.active.baseY = 19949;    // replay brought real history back
  runTimers();                         // settle
  let capturesAfterFirst = 0;
  for (let line = 0; line < 500; line++) {
    T.scrollbackDirty = true;          // a live frame landed
    fake.buffer.active.viewportY = 0;  // xterm pins a top-parked viewport
    T.maybeHydrateScrollback();        // its onScroll
    runTimers();
  }
  capturesAfterFirst = selects().length - 1;
  check('500 output lines at the top do not each trigger a capture', capturesAfterFirst === 0);
  check('  ... the cooldown/latch holds it to the single initial capture', selects().length === 1);
  // The capture DID come back deeper here, so the latch is off — this case is
  // pinning the cooldown specifically, not passing by way of the latch.
  check('  ... and it is the cooldown doing it (latch is off)', T.scrollbackFullySynced === false);
}
{
  // Latch: a capture that comes back no deeper means the buffer already matches
  // the pane, so stop asking until the viewport leaves the top.
  setup({ baseY: 19949, viewportY: 0 });
  T.maybeHydrateScrollback();
  runTimers(); // baseY unchanged → nothing new came back
  check('a capture that returns nothing new latches off', T.scrollbackFullySynced === true);
  T.lastHydrateAt = 0; // prove the latch alone holds, independent of the cooldown
  T.scrollbackDirty = true;
  T.maybeHydrateScrollback();
  check('  ... and a further scroll at the top does not re-capture', selects().length === 1);
  fake.buffer.active.viewportY = 900;  // user scrolls away
  T.maybeHydrateScrollback();
  check('  ... leaving the top re-arms it', T.scrollbackFullySynced === false);
}

// ---- The #935 review's Yellow 1: the restore must not yank the viewport ----

console.log('\n  viewport restore');
{
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  fake.buffer.active.baseY = 19949;
  fake.buffer.active.viewportY = 19949; // rebuild parked at the bottom
  T.hydrateSawReplay = true;            // what onmessage sets when a frame lands
  runTimers();
  check('a landed replay restores the user to the oldest lines', fake.scrolledToTop === 1);
}
{
  // Yellow 1: scrollOnUserInput deliberately takes a typing user to the bottom.
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  fake.buffer.active.baseY = 19949;
  fake.buffer.active.viewportY = 19949;
  T.hydrateSawReplay = true;
  T.sendToPTY('l');                     // user starts typing mid-flight
  runTimers();
  check('typing mid-flight suppresses the restore', fake.scrolledToTop === 0);
}
{
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  runTimers();
  check('no restore when no replay ever landed (the 2000 ms self-heal path)',
    fake.scrolledToTop === 0);
  check('  ... and the flight is still cleared', T.hydratingScrollback === false);
}

// ---- Teardown parity (review Yellow 2) -------------------------------------

console.log('\n  teardown');
{
  setup({ baseY: 400, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('a sync is in flight', T.hydratingScrollback === true);
  T.resetScrollbackSync(); // what both reloadTerminal and onclose now call
  check('reset clears the in-flight sync', T.hydratingScrollback === false);
  check('  ... re-arms the dirty flag', T.scrollbackDirty === true);
  check('  ... and clears the latch', T.scrollbackFullySynced === false);
  runTimers();
  check('  ... and the dropped settle cannot move the viewport', fake.scrolledToTop === 0);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
