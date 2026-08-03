const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-934: the shell-scrollback re-sync. tmux collapses pane redraws for a slow
// client (the browser), so the local xterm buffer holds far fewer lines than the
// pane's own history — measured 337/20000 for a browser-paced reader. Reaching
// the top of the local buffer re-requests crowd's authoritative replay
// (`select-window` → `capture-pane -pe -S -50000`).
//
// These cases pin the GATING, which is where the cost and the regression risk
// live: an over-eager trigger fires a tmux capture on every output burst, and an
// under-eager one leaves the bug in place. Same harness shape as
// wheel-scroll.test.js — an epilogue evaluated in app.js's own top-level lexical
// scope exposes the module-scope bindings.
const epilogue = `
;globalThis.__t = {
  maybeHydrateScrollback(){ return maybeHydrateScrollback(); },
  set term(v){ term = v; },
  set termWs(v){ termWs = v; },
  set activeTerminal(v){ activeTerminal = v; },
  set scrollbackDirty(v){ scrollbackDirty = v; },
  get scrollbackDirty(){ return scrollbackDirty; },
  set hydratingScrollback(v){ hydratingScrollback = v; },
  get hydratingScrollback(){ return hydratingScrollback; },
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
window.setTimeout = () => 0;
window.requestAnimationFrame = () => 0;
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

// `baseY` is how many lines have scrolled off the top (i.e. whether scrollback
// exists at all); `viewportY` is where the user is looking, 0 == the very top.
function setup({ agentSurface = false, baseY = 500, viewportY = 0,
                 readyState = 1, window: win = 7, dirty = true } = {}) {
  const sends = [];
  T.term = {
    buffer: { active: { baseY, viewportY } },
    scrollToTop() {},
  };
  T.termWs = { readyState, send(s) { sends.push(JSON.parse(s)); } };
  T.activeTerminal = win === null ? null : { id: 't1', window: win, agent_surface: agentSurface };
  T.hydratingScrollback = false;
  T.scrollbackDirty = dirty;
  return sends;
}
const selects = (sends) => sends.filter((m) => m.type === 'select-window');

// ---- Cases -----------------------------------------------------------------

console.log('scrollback hydrate (CROW-934)');

// The bug this fixes: a shell tab sitting on a thinned buffer, scrolled to the top.
{
  const sends = setup({ agentSurface: false, baseY: 297, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('shell at top of a thinned buffer re-requests the replay',
    selects(sends).length === 1 && selects(sends)[0].window === 7);
  check('  ... and marks the sync in flight so it is not re-issued', T.hydratingScrollback === true);
  check('  ... and clears the dirty flag', T.scrollbackDirty === false);
}

// An agent keeps its transcript in the scrollback-less alt buffer and repaints
// it itself (ADR-0013) — a capture there returns only the viewport.
{
  const sends = setup({ agentSurface: true });
  T.maybeHydrateScrollback();
  check('agent surface never re-syncs', selects(sends).length === 0);
}

// The `baseY === 0` guard. On a tab that has printed less than one screen,
// viewportY is permanently 0, so testing "at the top" alone would fire a tmux
// capture on every output burst for the life of the tab.
{
  const sends = setup({ baseY: 0, viewportY: 0 });
  T.maybeHydrateScrollback();
  check('short buffer (no scrollback yet) does not re-sync', selects(sends).length === 0);
}

{
  const sends = setup({ baseY: 500, viewportY: 120 });
  T.maybeHydrateScrollback();
  check('mid-buffer scroll does not re-sync', selects(sends).length === 0);
}

// Idempotence: one capture per output burst, not one per scroll event.
{
  const sends = setup({ dirty: false });
  T.maybeHydrateScrollback();
  check('already-synced buffer does not re-sync', selects(sends).length === 0);
}
{
  const sends = setup();
  T.maybeHydrateScrollback();
  T.maybeHydrateScrollback();
  T.maybeHydrateScrollback();
  check('repeated scrolls at the top issue exactly one capture', selects(sends).length === 1);
}

{
  const sends = setup({ readyState: 3 /* CLOSED */ });
  T.maybeHydrateScrollback();
  check('closed socket does not re-sync', selects(sends).length === 0);
}
{
  const sends = setup({ window: null });
  T.maybeHydrateScrollback();
  check('no active terminal does not re-sync', selects(sends).length === 0);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
