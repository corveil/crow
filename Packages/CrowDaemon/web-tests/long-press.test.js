const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-1006: long-press → terminal context menu on touch devices. xterm draws
// into a canvas that xterm.css marks `user-select: none`, so a phone has no
// native selection or copy callout over the grid — Crow's own menu is the mobile
// context menu, and before this bridge it was reachable only by right-click.
//
// Drives the real boot-time registration in Resources/web/app.js against a fake
// xterm, synthesised touch events, and a controllable clock. Same harness shape
// as touch-scroll.test.js: an epilogue evaluated in app.js's own top-level
// lexical scope exposes the module-scope bindings the menu reads.
const epilogue = `
;globalThis.__t = {
  set term(v){ term = v; },
  set activeTerminal(v){ activeTerminal = v; },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="app">
       <div id="terminal-wrap"><div id="terminal"></div></div>
     </div>
   </body></html>`,
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
window.requestAnimationFrame = () => 0;

// Controllable clock. attachLongPress arms a 500ms timer and cancels it with the
// id it got back, so ids must be truthy (its `if (timer)` guard) — hence 1-based.
// Only the 500ms timers are ever fired by hand; app.js's own boot timers stay
// parked, which is the point of not using real ones.
const timers = [];
window.setTimeout = (fn, ms) => timers.push({ fn, ms, live: true });
window.clearTimeout = (id) => { const t = timers[id - 1]; if (t) t.live = false; };
function fireLongPressTimers() {
  let fired = 0;
  for (const t of timers) {
    if (t.live && t.ms === 500) { t.live = false; t.fn(); fired++; }
  }
  return fired;
}

const clipboard = [];
Object.defineProperty(window.navigator, 'clipboard', {
  configurable: true,
  value: { writeText: (t) => { clipboard.push(t); return Promise.resolve(); } },
});

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

const wrap = realGet('terminal-wrap');

// Reset to a known state: no open menu, a fake xterm with the given selection.
// `term = null` models the pre-attach window, where the menu must stay away.
// Returns the fake so a case can re-wire it (T.term is a write-only accessor —
// the epilogue exposes the binding, not its value).
function setup({ selection = '', agentSurface = false, noTerm = false } = {}) {
  const m = window.document.querySelector('.ctx-menu');
  if (m) m.remove();
  clipboard.length = 0;
  for (const t of timers) t.live = false; // park anything left armed
  const calls = [];
  const term = noTerm ? null : {
    getSelection: () => selection,
    selectAll: () => calls.push('selectAll'),
    clear: () => calls.push('clear'),
  };
  T.term = term;
  T.activeTerminal = { id: 't1', window: 1, agent_surface: agentSurface };
  return { calls, term };
}

const touch = (type, points) => {
  const e = new window.Event(type, { bubbles: true, cancelable: true });
  e.touches = points.map(([clientX, clientY]) => ({ clientX, clientY }));
  wrap.dispatchEvent(e);
  return e;
};
const rightClick = (x, y) => {
  const e = new window.Event('contextmenu', { bubbles: true, cancelable: true });
  e.clientX = x;
  e.clientY = y;
  wrap.dispatchEvent(e);
  return e;
};
const menu = () => window.document.querySelector('.ctx-menu');
const labels = () => Array.from(menu() ? menu().querySelectorAll('.ctx-item') : []).map((n) => n.textContent);
const clickItem = (label) => {
  const item = Array.from(menu().querySelectorAll('.ctx-item')).find((n) => n.textContent === label);
  item.dispatchEvent(new window.Event('click', { bubbles: true, cancelable: true }));
};

// ---- The regression itself -------------------------------------------------

console.log('A still long-press opens the terminal menu:');
{
  setup();
  touch('touchstart', [[100, 200]]);
  check('a 500ms timer is armed on touchstart', fireLongPressTimers() === 1);
  check('the menu opened', !!menu());
  check('Paste / Select all / Clear / Reload offered',
    labels().join('|') === 'Paste|Select all|Clear|Reload terminal');
  check('positioned at the touch point', menu().style.left === '100px' && menu().style.top === '200px');
}

console.log('\nThe trailing emulated click is swallowed:');
{
  setup();
  touch('touchstart', [[100, 200]]);
  fireLongPressTimers();
  const end = touch('touchend', []);
  check('touchend is preventDefault\'ed so the tap never reaches xterm', end.defaultPrevented);
  check('the menu is still open after the finger lifts', !!menu());
}

console.log('\nA scroll drag cancels instead of opening a menu (#777 stays intact):');
{
  setup();
  touch('touchstart', [[100, 200]]);
  touch('touchmove', [[100, 260]]); // past the 10px threshold
  check('no timer left to fire', fireLongPressTimers() === 0);
  check('no menu', !menu());
  const end = touch('touchend', []);
  check('touchend is NOT preventDefault\'ed, so a drag keeps its native tap semantics',
    !end.defaultPrevented);
}

console.log('\nA sub-threshold wobble still counts as a long-press:');
{
  setup();
  touch('touchstart', [[100, 200]]);
  touch('touchmove', [[104, 206]]); // inside the 10px threshold
  check('the timer survives', fireLongPressTimers() === 1);
  check('the menu opened', !!menu());
}

console.log('\nMulti-touch is not a long-press:');
{
  setup();
  touch('touchstart', [[100, 200], [180, 240]]); // pinch
  check('nothing armed', fireLongPressTimers() === 0);
  check('no menu', !menu());
}

console.log('\nCopy is offered only when there is a selection:');
{
  setup({ selection: '' });
  touch('touchstart', [[10, 10]]);
  fireLongPressTimers();
  check('no Copy without a selection', !labels().includes('Copy'));

  setup({ selection: 'hello from the pty' });
  touch('touchstart', [[10, 10]]);
  fireLongPressTimers();
  check('Copy is first once something is selected', labels()[0] === 'Copy');
  clickItem('Copy');
  check('tapping Copy writes the selection to the clipboard', clipboard.join() === 'hello from the pty');
  check('the menu closes behind the tap', !menu());
}

// The whole point of the ticket: on a phone this two-step (long-press → Select
// all, long-press → Copy) is the ONLY route to the transcript's text, since
// xterm has no touch drag-select.
console.log('\nSelect all → Copy is reachable entirely by touch:');
{
  let selection = '';
  const { calls, term } = setup({ selection: '' });
  term.selectAll = () => { calls.push('selectAll'); selection = 'buffer contents'; };
  term.getSelection = () => selection;

  touch('touchstart', [[10, 10]]);
  fireLongPressTimers();
  clickItem('Select all');
  touch('touchend', []);
  check('Select all ran', calls.join() === 'selectAll');

  touch('touchstart', [[10, 10]]);
  fireLongPressTimers();
  check('the second long-press now offers Copy', labels()[0] === 'Copy');
  clickItem('Copy');
  check('...and it copies the selected buffer', clipboard.join() === 'buffer contents');
}

console.log('\nOn an agent surface the force-select hint still rides along:');
{
  setup({ agentSurface: true });
  touch('touchstart', [[10, 10]]);
  fireLongPressTimers();
  check('hint shown when nothing is selected', !!menu().querySelector('.ctx-hint'));
}

console.log('\nNo terminal attached yet → no menu:');
{
  setup({ noTerm: true });
  touch('touchstart', [[10, 10]]);
  check('the timer still fires', fireLongPressTimers() === 1);
  check('but showTerminalMenu bails', !menu());
}

console.log('\nDesktop right-click is unchanged:');
{
  setup({ selection: 'sel' });
  const e = rightClick(42, 84);
  check('the browser menu is suppressed', e.defaultPrevented);
  check('Crow\'s menu opened', !!menu());
  check('same items as the long-press path', labels()[0] === 'Copy');
  check('positioned at the cursor', menu().style.left === '42px' && menu().style.top === '84px');
}

console.log('\n' + (fail ? `FAIL — ${fail} failed, ${pass} passed` : `OK — ${pass} passed`));
process.exit(fail ? 1 : 0);
