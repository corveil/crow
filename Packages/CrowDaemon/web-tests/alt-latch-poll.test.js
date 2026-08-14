const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-1023: the alt-buffer detection latches server-side only AFTER an
// alt-buffer agent launches and enters the alt screen — several seconds after
// new-terminal/recreate snapshots `uses_alternate_screen: false`. list-terminals
// is not polled, so `maybePollAltScreenLatch` re-reads it on a short bounded
// schedule while the ATTACHED surface is an unlatched agent, until it latches
// (→ applySurfaceScrollback caps to 0) or the budget runs out (a genuinely
// inline build that keeps 50k). This suite drives that scheduler in isolation:
// `refreshTerminals` is stubbed to a counter (function bindings are reassignable
// like `rpc`), so we test arm/disarm/budget without app.js's full refresh path.
const epilogue = `
;globalThis.__t = {
  maybePollAltScreenLatch(){ return maybePollAltScreenLatch(); },
  set activeTerminal(v){ activeTerminal = v; },
  get activeTerminal(){ return activeTerminal; },
  set refreshTerminals(fn){ refreshTerminals = fn; },
  ALT_LATCH_POLL_MS,
  ALT_LATCH_POLL_MAX,
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';

const dom = new JSDOM(
  `<!doctype html><html><body><div id="terminal"></div></body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;

// Controllable timer queue selectable by delay (same shape as terminal-reload).
let timerSeq = 0;
const timers = [];
window.setTimeout = (fn, ms) => { timers.push({ id: ++timerSeq, fn, ms: ms || 0 }); return timerSeq; };
window.clearTimeout = (id) => { const i = timers.findIndex((t) => t.id === id); if (i >= 0) timers.splice(i, 1); };
window.setInterval = () => 0;
window.requestAnimationFrame = () => 0;
function fireTimersAt(ms) {
  const hits = timers.filter((t) => t.ms === ms);
  hits.forEach((t) => { timers.splice(timers.indexOf(t), 1); t.fn(); });
  return hits.length;
}
function timerCountAt(ms) { return timers.filter((t) => t.ms === ms).length; }

window.WebSocket = function () { return { send() {}, close() {} }; };
window.WebSocket.OPEN = 1;
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(fs.readFileSync(APP_JS, 'utf8') + epilogue, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

const POLL = T.ALT_LATCH_POLL_MS;

// Model the server: refreshTerminals is stubbed to (a) count calls, (b) re-arm
// the scheduler exactly as the real one does (it ends with maybePollAltScreenLatch),
// and (c) optionally flip the latch after N reads to simulate the agent entering
// the alt buffer.
let refreshCalls = 0;
let flipAfter = Infinity;
function installStub() {
  refreshCalls = 0;
  T.refreshTerminals = () => {
    refreshCalls += 1;
    if (refreshCalls >= flipAfter && T.activeTerminal) {
      T.activeTerminal = { ...T.activeTerminal, uses_alternate_screen: true };
    }
    T.maybePollAltScreenLatch(); // the real refreshTerminals calls this at its tail
  };
}

console.log('CROW-1023: the alt-screen latch poll arms only for an unlatched agent surface:');
{
  installStub(); flipAfter = Infinity;
  // Unlatched agent surface with a real window → arm.
  T.activeTerminal = { id: 't1', window: 3, agent_surface: true, uses_alternate_screen: false };
  T.maybePollAltScreenLatch();
  check('unlatched agent surface arms a poll', timerCountAt(POLL) === 1);

  // Latched agent surface → clear.
  T.activeTerminal = { id: 't1', window: 3, agent_surface: true, uses_alternate_screen: true };
  T.maybePollAltScreenLatch();
  check('a latched agent surface disarms the poll', timerCountAt(POLL) === 0);

  // Plain shell → never arm.
  T.activeTerminal = { id: 't2', window: 4, agent_surface: false };
  T.maybePollAltScreenLatch();
  check('a plain shell never arms', timerCountAt(POLL) === 0);

  // Agent surface with no window yet (pre-window prior, not a real read) → don't poll.
  T.activeTerminal = { id: 't3', window: null, agent_surface: true, uses_alternate_screen: false };
  T.maybePollAltScreenLatch();
  check('no window yet → no poll (the prior is not a real read)', timerCountAt(POLL) === 0);
}

console.log('\nan alt-buffer build latches within a few reads and then stops polling:');
{
  installStub(); flipAfter = 3; // server latches on the 3rd re-read
  T.activeTerminal = { id: 'a1', window: 5, agent_surface: true, uses_alternate_screen: false };
  T.maybePollAltScreenLatch();
  check('armed initially', timerCountAt(POLL) === 1);
  fireTimersAt(POLL); // read #1 (still false) → re-arm
  fireTimersAt(POLL); // read #2 (still false) → re-arm
  check('still polling before it latches', timerCountAt(POLL) === 1 && refreshCalls === 2);
  fireTimersAt(POLL); // read #3 → stub flips uses_alternate_screen true → maybePoll clears
  check('latched read stops the poll', timerCountAt(POLL) === 0);
  check('it took exactly the reads needed', refreshCalls === 3);
}

console.log('\na genuinely inline build gives up after the budget (and keeps 50k):');
{
  installStub(); flipAfter = Infinity; // never enters the alt buffer (inline Claude / Cursor)
  T.activeTerminal = { id: 'i1', window: 6, agent_surface: true, uses_alternate_screen: false };
  T.maybePollAltScreenLatch();
  // Drain every armed tick; each fire re-arms until the budget is spent.
  let guard = 0;
  while (timerCountAt(POLL) > 0 && guard < 100) { fireTimersAt(POLL); guard += 1; }
  check('polling stops after the bounded budget', timerCountAt(POLL) === 0);
  check('it read exactly ALT_LATCH_POLL_MAX times, no runaway', refreshCalls === T.ALT_LATCH_POLL_MAX);
}

console.log('\nswitching to a different unlatched agent tab refreshes the budget:');
{
  installStub(); flipAfter = Infinity;
  T.activeTerminal = { id: 'x1', window: 7, agent_surface: true, uses_alternate_screen: false };
  T.maybePollAltScreenLatch();
  let guard = 0;
  while (timerCountAt(POLL) > 0 && guard < 100) { fireTimersAt(POLL); guard += 1; }
  check('first tab exhausted its budget', refreshCalls === T.ALT_LATCH_POLL_MAX && timerCountAt(POLL) === 0);
  // A different terminal id gets a fresh budget rather than staying stuck at 0.
  T.activeTerminal = { id: 'x2', window: 8, agent_surface: true, uses_alternate_screen: false };
  T.maybePollAltScreenLatch();
  check('a new agent tab re-arms', timerCountAt(POLL) === 1);
}

console.log(`\n${pass} passed, ${fail} failed`);
if (fail) process.exit(1);
