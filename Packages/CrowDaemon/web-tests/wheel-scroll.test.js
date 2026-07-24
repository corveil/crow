const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// #824 / ADR-0013: the per-surface hybrid scroll model. Drives the real
// enableWheelScroll + swallowMouseMode from Resources/web/app.js against a fake
// xterm + PTY socket. Same harness shape as touch-scroll.test.js — an epilogue
// evaluated in app.js's own top-level lexical scope exposes the module-scope
// bindings we need (which is why swallowMouseMode lives at module scope rather
// than nested inside ensureTerminal).
const epilogue = `
;globalThis.__t = {
  enableWheelScroll(node){ return enableWheelScroll(node); },
  swallowMouseMode(params){ return swallowMouseMode(params); },
  appOwnsScroll(){ return appOwnsScroll(); },
  showTerminalMenu(e){ return showTerminalMenu(e); },
  wheelNotches(e){ return wheelNotches(e); },
  set term(v){ term = v; },
  set termWs(v){ termWs = v; },
  set activeTerminal(v){ activeTerminal = v; },
  get uiConfig(){ return uiConfig; },
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
window.TextEncoder = TextEncoder; // jsdom omits it; real browsers have it
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

// A fresh #terminal node with the wheel listener attached, plus recorders for
// what the handler did. `agentSurface` models the daemon-supplied
// `agent_surface` flag from the list-terminals payload.
function setup({ agentSurface = false, altScreen = false,
                 mouseTrackingMode = 'none', applicationCursorKeysMode = false } = {}) {
  const node = window.document.createElement('div');
  window.document.body.appendChild(node);

  const scrolled = [];
  const sent = [];
  T.term = {
    rows: 24,
    buffer: { active: { type: altScreen ? 'alternate' : 'normal' } },
    modes: { mouseTrackingMode, applicationCursorKeysMode },
    scrollLines: (n) => scrolled.push(n),
  };
  T.termWs = {
    readyState: 1,
    send: (bytes) => sent.push(new TextDecoder().decode(bytes)),
  };
  T.activeTerminal = { id: 't1', window: 1, agent_surface: agentSurface };

  const opts = {};
  const realAdd = node.addEventListener.bind(node);
  node.addEventListener = (type, fn, o) => { opts[type] = o; realAdd(type, fn, o); };
  T.enableWheelScroll(node);

  let defaultPrevented = 0;
  const wheel = (deltaY, deltaMode) => {
    const e = new window.Event('wheel', { bubbles: true, cancelable: true });
    e.deltaY = deltaY;
    if (deltaMode !== undefined) e.deltaMode = deltaMode;
    node.dispatchEvent(e);
    if (e.defaultPrevented) defaultPrevented++;
  };
  return {
    node, opts, scrolled, sent,
    wheel, // (deltaY, deltaMode?) — deltaMode defaults to 0 (pixel)
    up: () => wheel(-120),
    down: () => wheel(120),
    prevented: () => defaultPrevented,
  };
}

// ---- Event ownership (#776 invariant) --------------------------------------

console.log('The wheel handler owns the event on every surface (#776):');
{
  const t = setup();
  check('wheel registered non-passive', t.opts.wheel && t.opts.wheel.passive === false);
  check('wheel registered in the capture phase', t.opts.wheel && t.opts.wheel.capture === true);
  t.up();
  check('preventDefault called on a plain shell', t.prevented() === 1);
}
{
  const t = setup({ agentSurface: true });
  t.up();
  check('preventDefault called on an agent surface too', t.prevented() === 1);
}

// ---- Routing (#824 / ADR-0013) ---------------------------------------------

console.log('\nPlain shell scrolls the unified local scrollback:');
{
  const t = setup();
  t.up();
  check('scrollLines(-3) on wheel-up', t.scrolled.join() === '-3');
  t.down();
  check('scrollLines(+3) on wheel-down', t.scrolled.join() === '-3,3');
  check('nothing written to the PTY', t.sent.length === 0);
}

console.log('\nAgent surface forwards the wheel to the app:');
{
  // The agent turned mouse tracking on and — because the swallow is now
  // conditional — xterm actually recorded it, so we speak SGR wheel buttons.
  // CROW-835: one physical notch (deltaY ±120, pixel mode) forwards exactly ONE
  // SGR wheel report — not the old ±3 that flew pages in Claude Code.
  const t = setup({ agentSurface: true, mouseTrackingMode: 'any' });
  t.up();
  check('one SGR wheel-up report per notch', t.sent.join() === '\x1b[<64;1;1M');
  t.down();
  check('one SGR wheel-down report on the way back', t.sent[1] === '\x1b[<65;1;1M');
  check('no local scrollLines on an agent surface', t.scrolled.length === 0);
}
{
  // An agent surface whose app has NOT enabled mouse tracking still must not
  // scroll the (empty) local buffer — that was the "same frame forever" bug.
  const t = setup({ agentSurface: true, mouseTrackingMode: 'none' });
  t.up();
  check('no mouse tracking → cursor keys, still not scrollLines', t.sent.join() === '\x1b[A');
  check('still nothing scrolled locally', t.scrolled.length === 0);
}

// There is ONE shared xterm across every tab, and agent surfaces now let the
// mouse-mode DECSETs through, so `modes.mouseTrackingMode` can outlive the tab
// that set it (attachWindow only resets when the socket is already OPEN). A
// KNOWN shell must never inherit that and start forwarding the wheel.
console.log('\nA known plain shell ignores stale state from a previous agent tab:');
{
  const t = setup({ agentSurface: false, mouseTrackingMode: 'any' });
  t.up();
  check('sticky mouseTrackingMode does not hijack the shell', t.scrolled.join() === '-3');
  check('nothing forwarded to the PTY', t.sent.length === 0);
}
{
  const t = setup({ agentSurface: false, altScreen: true });
  t.up();
  check('a stale alternate buffer does not hijack the shell either', t.scrolled.join() === '-3');
  check('still nothing forwarded to the PTY', t.sent.length === 0);
}

// Those same signals remain the fallback when the daemon hasn't told us the
// surface kind yet — pre-#824 behavior for an unclassified surface.
console.log('\nWith no surface metadata, the legacy signals still apply:');
{
  const t = setup({ agentSurface: false, altScreen: true, mouseTrackingMode: 'vt200' });
  T.activeTerminal = null;
  t.up();
  check('unclassified + alternate buffer forwards to the PTY', t.sent.length > 0 && t.scrolled.length === 0);
}
{
  const t = setup({ agentSurface: false, mouseTrackingMode: 'any' });
  T.activeTerminal = { id: 't1', window: 1 }; // no agent_surface field
  t.up();
  check('unclassified + mouse tracking forwards to the PTY', t.sent.length > 0 && t.scrolled.length === 0);
}

// ---- Device normalization (CROW-835) ---------------------------------------

// wheelNotches maps ONE event to fractional physical notches by deltaMode, so a
// mouse, a trackpad, and a free-spin wheel all land near 1 notch per detent.
console.log('\nwheelNotches normalizes by deltaMode:');
{
  const n = (deltaY, deltaMode) => T.wheelNotches({ deltaY, deltaMode });
  // Pixel mode (0): a discrete detent (|delta| >= 40) snaps to exactly ±1,
  // regardless of whether the device reports 100, 120, or 240 px.
  check('pixel 120 → +1 notch', n(120, 0) === 1);
  check('pixel -100 → -1 notch', n(-100, 0) === -1);
  check('pixel 240 → still +1 notch (no burst)', n(240, 0) === 1);
  check('pixel 1000 → still +1 notch (no page-fly)', n(1000, 0) === 1);
  // Sub-detent pixel deltas (trackpad dust) stay fractional so they accumulate.
  check('pixel 10 → 0.25 notch (accumulates)', Math.abs(n(10, 0) - 0.25) < 1e-9);
  check('absent deltaMode is treated as pixel', n(120) === 1 && n(120, undefined) === 1);
  // Line mode (1, Firefox mouse): 3 lines is one OS notch.
  check('line 3 → +1 notch', n(3, 1) === 1);
  check('line 1 → 1/3 notch (accumulates)', Math.abs(n(1, 1) - 1 / 3) < 1e-9);
  // Page mode (2, rare): one page per notch.
  check('page 1 → +1 notch', n(1, 2) === 1);
}

console.log('\nSub-detent trackpad deltas accumulate into whole notches:');
{
  // Plain shell, pixel mode: four 10px deltas (40px total) = one notch = 3 lines.
  const t = setup({ agentSurface: false });
  t.wheel(10, 0); t.wheel(10, 0); t.wheel(10, 0);
  check('three 10px deltas (<40) emit nothing yet', t.scrolled.length === 0);
  t.wheel(10, 0);
  check('the fourth crosses 40px → one notch = 3 lines', t.scrolled.join() === '3');
  check('every dust event is still consumed (#776)', t.prevented() === 4);
}
{
  // Agent surface, pixel mode: two 30px deltas (60px total, each < 40) accumulate
  // into one forwarded notch — a free-spin wheel doesn't burst. (30/40 = 0.75 is
  // exact in IEEE754, so the accumulator crosses 1.0 cleanly on the second event.)
  const t = setup({ agentSurface: true, mouseTrackingMode: 'any' });
  t.wheel(30, 0);
  check('one 30px delta (<40) forwards nothing yet', t.sent.length === 0);
  t.wheel(30, 0);
  check('the second completes a notch → one SGR report', t.sent.join() === '\x1b[<65;1;1M');
}

// ---- Configurable sensitivity (CROW-835) -----------------------------------

console.log('\nWheel sensitivity scales by uiConfig (config round-trip):');
{
  const saved = { l: T.uiConfig.wheelScrollLines, a: T.uiConfig.agentWheelNotches };
  // Agent surface: agentWheelNotches multiplies the forwarded report count.
  T.uiConfig.agentWheelNotches = 2;
  const a = setup({ agentSurface: true, mouseTrackingMode: 'any' });
  a.down();
  check('agentWheelNotches=2 → two SGR reports per notch', a.sent.join() === '\x1b[<65;1;1M'.repeat(2));
  // Plain shell: wheelScrollLines multiplies the local scroll.
  T.uiConfig.wheelScrollLines = 8;
  const s = setup({ agentSurface: false });
  s.down();
  check('wheelScrollLines=8 → scrollLines(8) per notch', s.scrolled.join() === '8');
  T.uiConfig.wheelScrollLines = saved.l;
  T.uiConfig.agentWheelNotches = saved.a;
}

// ---- Conditional mouse-mode swallow ----------------------------------------

console.log('\nThe mouse-mode swallow is conditional on the surface:');
{
  setup({ agentSurface: false });
  const swallowed = [1000, 1001, 1002, 1003, 1005, 1006, 1015, 1016]
    .every((m) => T.swallowMouseMode([m]) === true);
  check('plain shell swallows every tracking mode (#776)', swallowed);
  check('plain shell lets a non-mouse mode through (?25 cursor)', T.swallowMouseMode([25]) === false);
}
{
  setup({ agentSurface: true });
  const passed = [1000, 1002, 1003, 1006, 1016]
    .every((m) => T.swallowMouseMode([m]) === false);
  check('agent surface lets the tracking modes through', passed);
  check('agent surface still lets a non-mouse mode through', T.swallowMouseMode([25]) === false);
}
{
  // xterm passes a params object, not a bare array — the shim handles both.
  setup({ agentSurface: false });
  check('unwraps the xterm params object', T.swallowMouseMode({ params: [1006] }) === true);
  check('handles sub-parameter arrays', T.swallowMouseMode([[1006, 0]]) === true);
  check('empty params are not swallowed', T.swallowMouseMode([]) === false);
}

// ---- Degenerate state ------------------------------------------------------

console.log('\nMissing surface metadata degrades to the shell path:');
{
  const t = setup({ agentSurface: false });
  T.activeTerminal = null; // no list-terminals payload yet
  t.up();
  check('no activeTerminal → scrolls locally, does not throw', t.scrolled.join() === '-3');
  check('...and swallows mouse modes as before', T.swallowMouseMode([1006]) === true);
}
{
  const t = setup({ agentSurface: false });
  T.activeTerminal = { id: 't1', window: 1 }; // older daemon: field absent
  t.up();
  check('absent agent_surface field → shell path', t.scrolled.join() === '-3');
}

// ---- Selection escape-hatch discoverability --------------------------------

// Letting mouse modes through costs native drag-select on agent surfaces, so
// the ⌥/Shift-drag hint is the only in-product teaching of the way back. It
// lives in the right-click menu, which stays reachable under live mouse
// tracking: xterm.js's only `contextmenu` listener is `rightClickHandler`,
// which calls neither preventDefault() nor stopPropagation(), and our listener
// sits on the #terminal-wrap ANCESTOR of xterm's element, so the event bubbles
// up regardless of what the app is reporting.
console.log('\nThe selection hint is discoverable on agent surfaces:');
function openMenu({ agentSurface, selection = '' }) {
  document.querySelectorAll('.ctx-menu').forEach((n) => n.remove());
  T.term = { getSelection: () => selection, selectAll() {}, clear() {} };
  T.activeTerminal = { id: 't1', window: 1, agent_surface: agentSurface };
  const e = new window.Event('contextmenu', { bubbles: true, cancelable: true });
  T.showTerminalMenu(e);
  return document.querySelector('.ctx-menu');
}
const { document } = window;
{
  const menu = openMenu({ agentSurface: true });
  const hint = menu && menu.querySelector('.ctx-hint');
  check('agent surface shows the selection hint', !!hint);
  check('hint names a modifier key', !!hint && /⌥|Shift/.test(hint.textContent));
  check('hint is not a clickable menu item', !!hint && !hint.classList.contains('ctx-item'));
}
{
  const menu = openMenu({ agentSurface: false });
  check('plain shell shows no hint (drag-select just works)', menu && !menu.querySelector('.ctx-hint'));
}
{
  const menu = openMenu({ agentSurface: true, selection: 'already selected' });
  check('no hint once the user has a selection', menu && !menu.querySelector('.ctx-hint'));
  check('...and Copy is offered instead',
    menu && [...menu.querySelectorAll('.ctx-item')].some((n) => n.textContent === 'Copy'));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
