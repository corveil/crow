const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// #777 regression: the mobile terminal touch-scroll shim. Drives the real
// enableTouchScroll from Resources/web/app.js against a fake xterm + PTY socket.
// Same harness shape as board.test.js — an epilogue evaluated in app.js's own
// top-level lexical scope exposes the module-scope bindings we need.
const epilogue = `
;globalThis.__t = {
  enableTouchScroll(node){ return enableTouchScroll(node); },
  set term(v){ term = v; },
  set termWs(v){ termWs = v; },
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

const CELL = 20; // px per row in the fakes below

// A fresh #terminal node with the listeners attached, plus recorders for what
// the shim did. Returns a small driver for synthesising a one-finger drag.
function setup({ rows = 24, screenHeight = rows * CELL, altScreen = false,
                 mouseTrackingMode = 'none', applicationCursorKeysMode = false } = {}) {
  const node = window.document.createElement('div');
  window.document.body.appendChild(node);
  Object.defineProperty(node, 'clientHeight', { value: rows * CELL, configurable: true });

  const element = window.document.createElement('div');
  const screen = window.document.createElement('div');
  screen.className = 'xterm-screen';
  Object.defineProperty(screen, 'clientHeight', { value: screenHeight, configurable: true });
  element.appendChild(screen);

  const scrolled = [];
  const sent = [];
  T.term = {
    rows, element,
    buffer: { active: { type: altScreen ? 'alternate' : 'normal' } },
    modes: { mouseTrackingMode, applicationCursorKeysMode },
    scrollLines: (n) => scrolled.push(n),
  };
  T.termWs = {
    readyState: 1,
    send: (bytes) => sent.push(new TextDecoder().decode(bytes)),
  };

  // Record listener registration so we can assert passive-ness directly.
  const opts = {};
  const realAdd = node.addEventListener.bind(node);
  node.addEventListener = (type, fn, o) => { opts[type] = o; realAdd(type, fn, o); };
  T.enableTouchScroll(node);

  let defaultPrevented = 0;
  const touch = (type, ys) => {
    const e = new window.Event(type, { bubbles: true, cancelable: true });
    e.touches = ys.map((clientY) => ({ clientY }));
    node.dispatchEvent(e);
    if (e.defaultPrevented) defaultPrevented++;
  };
  return {
    node, opts, scrolled, sent,
    start: (y) => touch('touchstart', [y]),
    move: (y) => touch('touchmove', [y]),
    moveTwo: (y) => touch('touchmove', [y, y + 40]),
    end: () => touch('touchend', []),
    prevented: () => defaultPrevented,
  };
}

// ---- The regression itself -------------------------------------------------

console.log('Gesture ownership (#777 root cause):');
{
  const t = setup();
  check('touchmove registered non-passive', t.opts.touchmove && t.opts.touchmove.passive === false);
  check('touchstart stays passive', t.opts.touchstart && t.opts.touchstart.passive === true);
  t.start(500);
  t.move(400);
  check('preventDefault called on a one-finger drag', t.prevented() === 1);
}

// Direction convention (unchanged from the pre-#777 shim, and the natural touch
// one): the content follows the finger. Dragging the finger DOWN pulls older
// content into view — negative deltas, i.e. back through history.
console.log('\nNormal buffer scrolls the local scrollback:');
{
  const t = setup();
  t.start(500);
  t.move(500 + 5 * CELL); // drag down 5 rows → back through history
  check('scrollLines(-5) — dragging down walks back through history', t.scrolled.join() === '-5');
  t.move(500); // drag back up 5 rows
  check('scrollLines(+5) on the way back to the bottom', t.scrolled.join() === '-5,5');
  check('nothing written to the PTY', t.sent.length === 0);
}

console.log('\nSub-cell drags accumulate instead of being truncated away:');
{
  const t = setup();
  t.start(500);
  [7, 14, 20].forEach((d) => t.move(500 + d)); // three part-row moves summing to one row
  check('three part-row moves produce exactly one line', t.scrolled.join() === '-1');
  const t2 = setup();
  t2.start(500);
  t2.move(500 + 7);
  check('a single sub-cell move scrolls nothing yet', t2.scrolled.length === 0);
  check('...but is still preventDefault\'ed', t2.prevented() === 1);
}

console.log('\nAlternate screen (TUI) forwards to the PTY — scrollLines is a no-op there:');
{
  const t = setup({ altScreen: true, mouseTrackingMode: 'vt200' });
  t.start(500);
  t.move(500 + 3 * CELL); // back through history
  check('no local scrollLines in the alt buffer', t.scrolled.length === 0);
  check('3 SGR wheel-up reports sent', t.sent.join() === '\x1b[<64;1;1M'.repeat(3));
  t.move(500 + 1 * CELL); // forward 2 rows
  check('wheel-down reports on the way back', t.sent[1] === '\x1b[<65;1;1M'.repeat(2));
}
{
  const t = setup({ altScreen: true, mouseTrackingMode: 'none' });
  t.start(500);
  t.move(500 + 2 * CELL);
  check('no mouse tracking → normal cursor keys', t.sent.join() === '\x1b[A\x1b[A');
}
{
  const t = setup({ altScreen: true, mouseTrackingMode: 'none', applicationCursorKeysMode: true });
  t.start(500);
  t.move(500 + 2 * CELL);
  check('application cursor keys → SS3 form', t.sent.join() === '\x1bOA\x1bOA');
}
{
  const t = setup({ altScreen: true, mouseTrackingMode: 'none' });
  t.start(500);
  t.move(500 + 100 * CELL); // a fling
  check('a fling is capped at 24 lines', t.sent.join() === '\x1b[A'.repeat(24));
}

console.log('\nMulti-touch is left to the browser:');
{
  const t = setup();
  t.start(500);
  t.moveTwo(400);
  check('two-finger move does not scroll', t.scrolled.length === 0);
  check('two-finger move is not preventDefault\'ed', t.prevented() === 0);
}

console.log('\nDegenerate metrics do not throw or emit NaN:');
{
  const t = setup({ rows: 0, screenHeight: 0 });
  t.start(500);
  t.move(500 + 36); // 2 × the 18px fallback cell
  check('rows: 0 falls back to an 18px cell', t.scrolled.join() === '-2');
}
{
  const t = setup({ screenHeight: 0 }); // no rendered screen yet → container fallback
  t.start(500);
  t.move(500 + 2 * CELL);
  check('zero-height screen falls back to the container metric', t.scrolled.join() === '-2');
  check('no NaN scrolls', t.scrolled.every((n) => Number.isFinite(n)));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
