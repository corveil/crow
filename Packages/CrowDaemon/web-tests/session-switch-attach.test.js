const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-1035: switching to a Claude / Cursor session must NOT take the #673
// full reload (new PTY at 24×80 → SIGWINCH → capture-pane replay). That path
// parks Claude's caret below the input box and stacks Cursor's footer chrome.
// Agent surfaces switch in place (clear buffer + select-window with replay:false
// on the live socket); plain shells keep the reload so a surface another client
// reshaped still self-heals.
const epilogue = `
;globalThis.__t = {
  attachWindow(win){ return attachWindow(win); },
  switchAgentWindow(win){ return switchAgentWindow(win); },
  reloadTerminal(){ return reloadTerminal(); },
  connectTerminalWs(){ return connectTerminalWs(); },
  get attachedWindow(){ return attachedWindow; },
  set attachedWindow(v){ attachedWindow = v; },
  get termWs(){ return termWs; },
  set termWs(v){ termWs = v; },
  get term(){ return term; },
  set term(v){ term = v; },
  set activeTerminal(v){ activeTerminal = v; },
  get activeTerminal(){ return activeTerminal; },
  SCROLLBACK_HEAL_MS,
  SCROLLBACK_HEAL_MAX,
  TERM_BUFFER_CLEAR,
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="app"><div id="terminal-wrap"><div id="terminal"></div></div></div>
   </body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;

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

function fakeTerm() {
  return {
    clears: 0,
    reset() { this.resets = (this.resets || 0) + 1; },
    write(d) {
      if (d === T.TERM_BUFFER_CLEAR) this.clears++;
    },
    options: { scrollback: 50000 },
    buffer: { active: { viewportY: 0, baseY: 0 } },
    focus() {},
  };
}

function openSocket() {
  const s = {
    readyState: window.WebSocket.OPEN,
    sent: [],
    send(d) { this.sent.push(d); },
    close() { this.closed = true; this.readyState = 3; },
    closed: false,
  };
  T.termWs = s;
  return s;
}

function selectWindowPayloads(sock) {
  return sock.sent.map((d) => {
    try { return JSON.parse(d); } catch (_) { return null; }
  }).filter((m) => m && m.type === 'select-window');
}

function selectWindowCount(sock) {
  return selectWindowPayloads(sock).length;
}

function mount(surface) {
  T.attachedWindow = null;
  T.term = fakeTerm();
  T.activeTerminal = surface;
  return openSocket();
}

const claude = { id: 't-claude', name: 'Claude Code', window: 3, agent_surface: true, uses_alternate_screen: true };
const cursor = { id: 't-cursor', name: 'Cursor', window: 4, agent_surface: true, uses_alternate_screen: false };
const shell = { id: 't-shell', name: 'Shell', window: 5, agent_surface: false };

console.log('CROW-1035: switching to a Claude (alt-buffer) session is in-place:');
{
  const sock = mount(claude);
  const socketsBefore = sockets.length;
  const clearsBefore = T.term.clears;
  T.attachWindow(claude.window);
  check('no new WebSocket', sockets.length === socketsBefore);
  check('live socket was not closed', sock.closed === false);
  check('xterm buffer was cleared, not reset', T.term.clears === clearsBefore + 1);
  check('select-window went out on the live socket', selectWindowCount(sock) === 1);
  check('in-place agent switch skips scrollback replay', selectWindowPayloads(sock)[0].replay === false);
  check('attachedWindow tracks the new window', T.attachedWindow === claude.window);
  fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('alt-buffer agent does not self-heal-recapture', selectWindowCount(sock) === 1);
}

console.log('\nCROW-1035: switching to a Cursor (inline agent) session is in-place:');
{
  const sock = mount(cursor);
  const socketsBefore = sockets.length;
  T.attachWindow(cursor.window);
  check('no new WebSocket', sockets.length === socketsBefore);
  check('live socket was not closed', sock.closed === false);
  check('select-window went out on the live socket', selectWindowCount(sock) === 1);
  check('inline agent in-place switch skips replay', selectWindowPayloads(sock)[0].replay === false);
  T.term.buffer.active.baseY = 0;
  fireTimersAt(T.SCROLLBACK_HEAL_MS);
  check('in-place switch does not CROW-1027 recapture (no PTY resize to heal)', selectWindowCount(sock) === 1);
}

console.log('\nplain shell tabs still take the #673 full reload:');
{
  const sock = mount(shell);
  const socketsBefore = sockets.length;
  T.attachWindow(shell.window);
  check('reload opened a new WebSocket', sockets.length === socketsBefore + 1);
  check('old socket handlers were detached (reload path)', sock.closed === true || T.termWs !== sock);
  check('attachedWindow tracks the shell window', T.attachedWindow === shell.window);
}

console.log('\nre-clicking the already-attached window is a no-op:');
{
  const sock = mount(claude);
  T.attachedWindow = claude.window;
  const sentBefore = sock.sent.length;
  const clearsBefore = T.term.clears;
  T.attachWindow(claude.window);
  check('no select-window', sock.sent.length === sentBefore);
  check('no buffer clear', T.term.clears === clearsBefore);
}

console.log('\nno open socket: attachWindow only records the window (onopen will select):');
{
  T.term = fakeTerm();
  T.termWs = null;
  T.attachedWindow = null;
  T.activeTerminal = claude;
  T.attachWindow(claude.window);
  check('records attachedWindow', T.attachedWindow === claude.window);
  check('does not throw without a socket', true);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
