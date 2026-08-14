const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-979 regression tests for the header's ↻ Reload button. Before it, the only
// route to `reloadTerminal()` was the terminal's right-click menu — which a touch
// device cannot open, so on a phone the cheap recovery for a corrupted surface did
// not exist at all.
//
// Same loader shape as the other files here (the REAL app.js in a jsdom VM plus an
// epilogue exposing module-scope internals), with two deviations this file needs:
//   • the fake /terminal socket STORES its handlers instead of discarding them, so
//     a test can fire `onopen` on demand — that transition is what settles the
//     spinner, and firing it on assignment (rpc-timeout.test.js's shape) would make
//     the in-flight state unobservable;
//   • setTimeout/clearTimeout are a controllable queue selectable by delay, so the
//     10s settle timer can be fired without also firing the 1500s skeleton timer.
const epilogue = `
;globalThis.__t = {
  renderHeader(s){ return renderHeader(s); },
  showEmptyDetail(m, o){ return showEmptyDetail(m, o); },
  showTerminalMenu(e){ return showTerminalMenu(e); },
  reloadTerminalAction(){ return reloadTerminalAction(); },
  reloadTerminal(){ return reloadTerminal(); },
  connectTerminalWs(){ return connectTerminalWs(); },
  clearTerminalReloadPending(){ return clearTerminalReloadPending(); },
  syncTerminalReloadEnabled(){ return syncTerminalReloadEnabled(); },
  get terminalReloadPending(){ return terminalReloadPending; },
  get termWs(){ return termWs; },
  set termWs(v){ termWs = v; },
  set term(v){ term = v; },
  set sessions(v){ sessions = v; },
  set selectedId(v){ selectedId = v; },
  set activeTerminal(v){ activeTerminal = v; },
  TERMINAL_RELOAD_SETTLE_MS,
  SCROLLBACK_HEAL_MS,
  SCROLLBACK_HEAL_MAX,
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const APP_CSS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.css';

const dom = new JSDOM(
  `<!doctype html><html><head>
     <style>${fs.readFileSync(APP_CSS, 'utf8')}</style>
   </head><body>
     <div id="app"><header id="detail-header"></header><div id="tabbar"></div>
       <div id="terminal-wrap"><div id="terminal"></div></div><div id="board"></div>
       <div id="sidebar"></div></div>
   </body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;

// --- controllable timers ----------------------------------------------------
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

// --- fake sockets -----------------------------------------------------------
// Every `new WebSocket(...)` lands here; `sockets` is append-only so a test can
// assert that reloadTerminal really tore one down and built another.
const sockets = [];
window.WebSocket = function (url) {
  const s = {
    url, readyState: 0, closed: false, sent: [],
    send(d) { this.sent.push(d); },
    close() { this.closed = true; this.readyState = 3; if (this._onclose) this._onclose({}); },
    fireOpen() { this.readyState = 1; if (this._onopen) this._onopen(); },
  };
  Object.defineProperty(s, 'onopen', { set(fn) { s._onopen = fn; }, get() { return s._onopen; } });
  Object.defineProperty(s, 'onmessage', { set(fn) { s._onmessage = fn; }, get() { return s._onmessage; } });
  Object.defineProperty(s, 'onclose', { set(fn) { s._onclose = fn; }, get() { return s._onclose; } });
  Object.defineProperty(s, 'onerror', { set(fn) { s._onerror = fn; }, get() { return s._onerror; } });
  sockets.push(s);
  return s;
};
window.WebSocket.OPEN = 1;

const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try {
  vm.runInContext(fs.readFileSync(APP_JS, 'utf8') + epilogue, ctx, { filename: 'app.js' });
} catch (e) {
  console.log('[load warn]', e.message);
}
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

// --- helpers ----------------------------------------------------------------
const SESSION_ID = 's1';
let lastTerm = null;
function fakeTerm() {
  return {
    resets: 0,
    reset() { this.resets++; },
    buffer: { active: { viewportY: 0, baseY: 0 } },
    getSelection() { return ''; },
    selectAll() {}, clear() {}, write() {}, focus() {},
  };
}
// Put the app in "session <kind> selected, one terminal attached" and paint.
function mount(kind, opts) {
  const o = opts || {};
  const s = { id: SESSION_ID, name: 'sess', status: 'active', kind };
  T.sessions = [s];
  T.selectedId = SESSION_ID;
  T.activeTerminal = o.noTerminal ? null : { id: 't1', name: 'Claude Code', window: 3 };
  lastTerm = o.noTerm ? null : fakeTerm();
  T.term = lastTerm;
  T.termWs = null;
  T.clearTerminalReloadPending();
  T.renderHeader(s);
  return s;
}
function reloadBtn() {
  return [...window.document.querySelectorAll('#detail-header .actions-cluster .action-btn')]
    .find((b) => b.textContent.includes('Reload')) || null;
}

console.log('the ↻ Reload button renders for every session kind:');
for (const kind of ['work', 'review', 'job', 'manager']) {
  mount(kind);
  const b = reloadBtn();
  check(kind + ': button present', !!b);
  check(kind + ': shows the ↻ glyph', !!(b && b.querySelector('.reload-glyph')));
}

console.log('\nmanager sessions get an action cluster at all (the #680 gap):');
{
  // Every other header button sits inside `if (s.kind !== 'manager')`, so before
  // CROW-979 a Manager with no links rendered no header row whatsoever — which is
  // exactly the surface with no tabs to hang a control off either.
  mount('manager');
  const cluster = window.document.querySelector('#detail-header .actions-cluster');
  check('cluster exists for a manager', !!cluster);
  check('and holds only Reload', !!cluster && cluster.children.length === 1);
}

console.log('\nrefreshTerminals only repaints the header when the button is stale:');
{
  // selectSession paints the header BEFORE awaiting refreshTerminals, so the
  // button starts disabled and must flip once activeTerminal binds — but the same
  // sync runs on add/close-terminal and background pushes, where an unconditional
  // renderHeader would also throw away an in-flight In Review spinner (that one
  // keeps its state on the node, not in module state).
  mount('work', { noTerminal: true });
  check('starts disabled with nothing bound', reloadBtn().disabled === true);
  const stale = reloadBtn();
  T.activeTerminal = { id: 't1', name: 'Claude Code', window: 3 };
  T.syncTerminalReloadEnabled();
  check('flips to enabled once bound', reloadBtn().disabled === false);
  check('header was rebuilt', reloadBtn() !== stale);

  // Nothing changed this time — the node must survive untouched.
  const fresh = reloadBtn();
  fresh.dataset.marker = 'kept';
  T.syncTerminalReloadEnabled();
  check('no repaint when already correct', reloadBtn().dataset.marker === 'kept');
}

console.log('\nglyph and spinner share one box, so the swap causes no layout shift:');
{
  // The CROW-797 fix for the tickets ↻: spin an inner node inside stationary
  // chrome. That only holds if the two nodes are the same size.
  mount('work');
  const glyph = reloadBtn().querySelector('.reload-glyph');
  const gs = glyph && window.getComputedStyle(glyph);
  check('↻ glyph is 12×12', !!gs && gs.width === '12px' && gs.height === '12px');
}

console.log('\ndisabled when nothing is attached, enabled when something is:');
{
  mount('work', { noTerminal: true });
  const b = reloadBtn();
  check('present but disabled', !!b && b.disabled === true);
  check('title explains why', !!b && b.title === 'No terminal attached');

  mount('work');
  const b2 = reloadBtn();
  check('enabled with a terminal attached', !!b2 && b2.disabled === false);
  check('title describes the action', !!b2 && /Reload the terminal/.test(b2.title));
}

console.log('\nclick reloads: buffer reset, old socket dropped, new socket opened:');
{
  mount('work');
  // Stand an already-open socket up so reloadTerminal has one to tear down. The
  // fake's close() fires onclose, so leaving this handler attached would make the
  // reconnect loop re-enter — which is precisely what reloadTerminal detaches to
  // prevent, and what this asserts.
  const old = new window.WebSocket('ws://localhost/terminal');
  old.readyState = 1;
  let staleOnCloseFired = false;
  old.onclose = () => { staleOnCloseFired = true; };
  T.termWs = old;
  const before = sockets.length;

  reloadBtn().click();

  check('xterm buffer reset', lastTerm.resets === 1);
  check('old socket closed', old.closed === true);
  check('old handlers detached first', old.onclose === null);
  check('stale onclose never ran', staleOnCloseFired === false);
  check('a fresh socket was opened', sockets.length === before + 1);
  check('…and it is the live one', T.termWs === sockets[sockets.length - 1]);
  check('pending flag set', T.terminalReloadPending === true);
}

console.log('\n…and the button spins in place while it reconnects:');
{
  const b = reloadBtn();
  check('button disabled', !!b && b.disabled === true);
  check('spinner swapped in', !!b && !!b.querySelector('.action-spinner'));
  check('↻ glyph swapped out', !!b && b.querySelector('.reload-glyph') === null);
  check('title says reloading', !!b && b.title === 'Reloading terminal…');
  // The spinner and the glyph occupy the same 12×12 box, so the swap can't shift
  // the button's width (the CROW-797 fix, applied to this button).
  const spinNode = b && b.querySelector('.action-spinner');
  const spin = spinNode && window.getComputedStyle(spinNode);
  check('spinner is 12×12', !!spin && spin.width === '12px' && spin.height === '12px');
}

console.log('\nthe socket opening settles it:');
{
  sockets[sockets.length - 1].fireOpen();
  check('pending flag cleared', T.terminalReloadPending === false);
  const b = reloadBtn();
  check('↻ glyph restored', !!b && !!b.querySelector('.reload-glyph'));
  check('no spinner left', !!b && b.querySelector('.action-spinner') === null);
  check('button re-enabled', !!b && b.disabled === false);
}

console.log('\na reconnect that never opens still settles (no forever-spinner):');
{
  // onclose retries with backoff indefinitely, so "wait for onopen" alone would
  // spin until the daemon came back — which for a dead daemon is never.
  mount('work');
  reloadBtn().click();
  check('pending while in flight', T.terminalReloadPending === true);
  check('settle timer armed', timerCountAt(T.TERMINAL_RELOAD_SETTLE_MS) === 1);
  fireTimersAt(T.TERMINAL_RELOAD_SETTLE_MS);
  check('pending cleared by the settle timer', T.terminalReloadPending === false);
  check('↻ glyph restored', !!reloadBtn().querySelector('.reload-glyph'));
}

console.log('\nsettle timer is disarmed when the socket opens first:');
{
  mount('work');
  reloadBtn().click();
  check('armed on click', timerCountAt(T.TERMINAL_RELOAD_SETTLE_MS) === 1);
  sockets[sockets.length - 1].fireOpen();
  check('disarmed on open', timerCountAt(T.TERMINAL_RELOAD_SETTLE_MS) === 0);
}

console.log('\na double-tap coalesces into one reload:');
{
  mount('work');
  const before = sockets.length;
  const b = reloadBtn();
  b.click();
  // The re-render replaces the node, but the stale one still carries the handler —
  // the closest a test gets to a real double-tap landing before the repaint.
  b.click();
  check('only one socket opened', sockets.length === before + 1);
}

console.log('\nclicking with nothing attached is a no-op, not a throw:');
{
  mount('work', { noTerminal: true });
  const before = sockets.length;
  let threw = false;
  try { T.reloadTerminalAction(); } catch (_) { threw = true; }
  check('did not throw', threw === false);
  check('no socket opened', sockets.length === before);
  check('no pending flag stranded', T.terminalReloadPending === false);

  mount('work', { noTerm: true });
  let threw2 = false;
  try { T.reloadTerminalAction(); } catch (_) { threw2 = true; }
  check('no xterm instance: did not throw', threw2 === false);
  check('no xterm instance: no pending flag', T.terminalReloadPending === false);
}

console.log('\ndeselecting the session drops a pending reload:');
{
  mount('work');
  reloadBtn().click();
  check('pending before deselect', T.terminalReloadPending === true);
  T.showEmptyDetail('Select a session');
  check('cleared by showEmptyDetail', T.terminalReloadPending === false);
  check('settle timer disarmed too', timerCountAt(T.TERMINAL_RELOAD_SETTLE_MS) === 0);
}

console.log('\nthe existing right-click path is untouched:');
{
  mount('work');
  T.showTerminalMenu({ preventDefault() {}, clientX: 10, clientY: 10 });
  const items = [...window.document.querySelectorAll('.ctx-menu .ctx-item')].map((n) => n.textContent);
  check('“Reload terminal” still in the terminal menu', items.includes('Reload terminal'));
  const menu = window.document.querySelector('.ctx-menu');
  if (menu) menu.remove();
}

// --- CROW-1027: post-attach scrollback self-heal + reconnect-timer cancel -----
// The reload attach fits (resizes) the pane immediately before select-window
// replays it, so `capture-pane` can run mid-reflow and rebuild a ONE-screen
// (dead-wheel) buffer. onopen arms a short settle; if the buffer really came back
// one screen tall (`baseY === 0`) on a shell surface, it re-issues select-window
// so crowd re-captures the now-settled pane.
function selectWindowCount(sock) {
  return sock.sent.filter((d) => { try { return JSON.parse(d).type === 'select-window'; } catch (_) { return false; } }).length;
}

console.log('\nCROW-1027: a reload that rebuilds a one-screen buffer self-heals:');
{
  mount('work'); // shell surface — activeTerminal carries no agent_surface flag
  T.reloadTerminal();
  const sock = sockets[sockets.length - 1];
  sock.fireOpen(); // onopen → selectWindow (initial) + armScrollbackHeal
  const initial = selectWindowCount(sock);
  check('initial attach selected the window once', initial === 1);
  lastTerm.buffer.active.baseY = 0; // daemon replay landed one screen tall
  fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('dead wheel triggers one re-capture', selectWindowCount(sock) === initial + 1);
  lastTerm.buffer.active.baseY = 42; // the re-capture rebuilt real history
  fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('a healthy buffer stops re-capturing', selectWindowCount(sock) === initial + 1);
  check('the wheel is live again (baseY > 0)', lastTerm.buffer.active.baseY > 0);
}

console.log('\nCROW-1027: a healthy attach never re-captures:');
{
  mount('work');
  T.reloadTerminal();
  const sock = sockets[sockets.length - 1];
  lastTerm.buffer.active.baseY = 30; // scrollback already present when onopen fires
  sock.fireOpen();
  const n = selectWindowCount(sock);
  fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('no extra select-window on a healthy buffer', selectWindowCount(sock) === n);
}

console.log('\nCROW-1027: self-heal is bounded and never loops:');
{
  mount('work');
  T.reloadTerminal();
  const sock = sockets[sockets.length - 1];
  sock.fireOpen();
  const initial = selectWindowCount(sock);
  lastTerm.buffer.active.baseY = 0; // stays dead however many times we re-capture
  for (let i = 0; i < 5; i++) fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('caps at SCROLLBACK_HEAL_MAX re-captures', selectWindowCount(sock) === initial + T.SCROLLBACK_HEAL_MAX);
  check('no self-heal timer left armed', timerCountAt(T.SCROLLBACK_HEAL_MS) === 0);
}

console.log('\nCROW-1027: alt-buffer agents (Claude Code) are unaffected:');
{
  mount('work');
  T.activeTerminal = { id: 't1', name: 'Claude Code', window: 3, agent_surface: true };
  T.reloadTerminal();
  const sock = sockets[sockets.length - 1];
  sock.fireOpen();
  const initial = selectWindowCount(sock);
  lastTerm.buffer.active.baseY = 0;
  fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('agent surface: no self-heal re-capture', selectWindowCount(sock) === initial);

  // Even a non-agent surface parked on the ALT buffer has no local scrollback to
  // repair, so the buffer-type gate short-circuits too.
  mount('work');
  T.reloadTerminal();
  const sock2 = sockets[sockets.length - 1];
  sock2.fireOpen();
  const initial2 = selectWindowCount(sock2);
  lastTerm.buffer.active.baseY = 0;
  lastTerm.buffer.active.type = 'alternate';
  fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('alt buffer type: no self-heal re-capture', selectWindowCount(sock2) === initial2);
}

console.log('\nCROW-1027: a reload cancels a pending auto-reconnect (no double-connect):');
{
  mount('work');
  T.connectTerminalWs();
  const s0 = sockets[sockets.length - 1];
  s0.fireOpen(); // resets the reconnect backoff to 1000ms
  s0.close();    // simulate a dropped socket → arms the auto-reconnect timer
  check('auto-reconnect armed at 1000ms', timerCountAt(1000) === 1);
  const before = sockets.length;
  T.reloadTerminal(); // manual reload builds its own socket...
  check('reload built exactly one new socket', sockets.length === before + 1);
  check('reload cancelled the pending reconnect', timerCountAt(1000) === 0);
  const after = sockets.length;
  fireTimersAt(1000); // the stray reconnect, had it survived, would have attached here
  check('no second attach races the reload', sockets.length === after);
  check('termWs is the reload’s socket', T.termWs === sockets[sockets.length - 1]);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);