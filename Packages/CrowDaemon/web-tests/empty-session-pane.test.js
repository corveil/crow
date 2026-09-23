const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// CROW-1295: selecting a session whose list-terminals is empty must drop the
// previous window. A session that still has a terminal attaches as before.
const epilogue = `
;globalThis.__t = {
  refreshTerminals: () => refreshTerminals(),
  relaunchSessionAgent: () => relaunchSessionAgent(),
  sendToPTY: (t) => sendToPTY(t),
  get activeTerminal() { return activeTerminal; },
  set activeTerminal(v) { activeTerminal = v; },
  get attachedWindow() { return attachedWindow; },
  set attachedWindow(v) { attachedWindow = v; },
  get terminalDetached() { return terminalDetached; },
  get terminals() { return terminals; },
  get selectedId() { return selectedId; },
  set selectedId(v) { selectedId = v; },
  get sessions() { return sessions; },
  set sessions(v) { sessions = v; },
  set term(v) { term = v; },
  get term() { return term; },
  set termWs(v) { termWs = v; },
  get termWs() { return termWs; },
  setRpc(fn) { rpc = fn; },
};
`;

const MARKUP = `<!doctype html><html><body>
  <div id="app" class="has-selection">
    <button id="back-to-sidebar"></button>
    <aside id="sidebar"></aside>
    <main id="detail">
      <header id="detail-header"></header>
      <div id="detail-artifacts"></div>
      <div id="tabbar"></div>
      <div id="terminal-wrap"><div id="terminal"></div></div>
      <div id="board"></div>
      <div id="detail-empty"><div class="empty-msg">Select a session</div></div>
    </main>
  </div>
  <div id="statusbar"></div>
</body></html>`;

function load() {
  const dom = new JSDOM(MARKUP, {
    runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/',
  });
  const { window } = dom;
  window.TextEncoder = TextEncoder; // jsdom omits it; real browsers have it
  window.WebSocket = function () {
    return { send() {}, close() {}, readyState: 1,
      set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  window.WebSocket.OPEN = 1;
  window.setInterval = () => 0;
  window.setTimeout = () => 0;
  window.clearTimeout = () => {};
  window.requestAnimationFrame = () => 0;
  const ctx = dom.getInternalVMContext();
  vm.runInContext(loadClientSource() + epilogue, ctx, { filename: 'app.js' });
  const T = ctx.__t;
  if (!T) { console.log('FATAL: epilogue did not run'); process.exit(2); }
  T.window = window;
  T.term = {
    clears: 0,
    write(d) { if (String(d).includes('\x1b[2J')) this.clears++; },
    options: { scrollback: 50000 },
    buffer: { active: { viewportY: 0, baseY: 0 } },
    focus() {},
  };
  return T;
}

let failed = 0;
function check(name, ok) {
  console.log((ok ? '  ok  ' : '  FAIL ') + name);
  if (!ok) failed++;
}

async function main() {

const WORK = { id: 'sess-empty', name: 'catalog', kind: 'work' };
const PREV = { id: 'term-prev', name: 'crow', window: 4, agent_surface: true };

console.log('empty list clears the previous window and shows relaunch:');
{
  const T = load();
  T.sessions = [WORK];
  T.selectedId = WORK.id;
  T.activeTerminal = PREV;
  T.attachedWindow = PREV.window;
  const sock = { readyState: T.window.WebSocket.OPEN, sent: [], send(d) { this.sent.push(d); } };
  T.termWs = sock;
  T.setRpc(async () => ({ terminals: [] }));
  await T.refreshTerminals();
  const wrap = T.window.document.getElementById('terminal-wrap');
  const bar = T.window.document.getElementById('tabbar');
  check('active terminal cleared', T.activeTerminal === null);
  check('attached window cleared', T.attachedWindow === null);
  check('surface detached', T.terminalDetached === true);
  check('buffer cleared', T.term.clears === 1);
  check('empty overlay is up', wrap.classList.contains('no-terminal'));
  check('relaunch is offered', !!T.window.document.querySelector('.terminal-empty-relaunch:not([hidden])'));
  check('no terminal tab is invented', bar.querySelectorAll('.tab:not(.add)').length === 0);
  check('the add tab stays', bar.querySelectorAll('.tab.add').length === 1);
  check('no select-window while empty', sock.sent.length === 0);
  T.sendToPTY('x');
  check('keystrokes do not reach the previous window', sock.sent.length === 0);
}

console.log('\na session that still has a terminal attaches as before:');
{
  const T = load();
  T.sessions = [WORK];
  T.selectedId = WORK.id;
  T.activeTerminal = PREV;
  T.attachedWindow = 2;
  const sock = { readyState: T.window.WebSocket.OPEN, sent: [], send(d) { this.sent.push(d); } };
  T.termWs = sock;
  const next = { id: 'term-live', name: 'Grok', window: 8, agent_surface: true, uses_alternate_screen: true };
  T.setRpc(async () => ({ terminals: [next] }));
  await T.refreshTerminals();
  const wrap = T.window.document.getElementById('terminal-wrap');
  check('attaches the live window', T.attachedWindow === 8);
  check('that tab is active', T.activeTerminal && T.activeTerminal.id === 'term-live');
  check('empty overlay stays down', !wrap.classList.contains('no-terminal'));
  check('not detached', T.terminalDetached === false);
  const frames = sock.sent.map((d) => { try { return JSON.parse(d); } catch (_) { return null; } })
    .filter((m) => m && m.type === 'select-window');
  check('select-window for the live window', frames.length === 1 && frames[0].window === 8);
}

console.log('\na failed list does not detach the current window:');
{
  const T = load();
  T.sessions = [WORK];
  T.selectedId = WORK.id;
  T.activeTerminal = PREV;
  T.attachedWindow = PREV.window;
  T.setRpc(async () => { throw new Error('down'); });
  await T.refreshTerminals();
  const wrap = T.window.document.getElementById('terminal-wrap');
  check('previous window stays attached', T.attachedWindow === PREV.window);
  check('overlay stays down', !wrap.classList.contains('no-terminal'));
  check('not detached', T.terminalDetached === false);
}

console.log('\nrelaunch opens a terminal and attaches it:');
{
  const T = load();
  T.sessions = [WORK];
  T.selectedId = WORK.id;
  T.attachedWindow = PREV.window;
  T.activeTerminal = PREV;
  const sock = { readyState: T.window.WebSocket.OPEN, sent: [], send(d) { this.sent.push(d); } };
  T.termWs = sock;
  const calls = [];
  let launched = false;
  T.setRpc(async (method, params) => {
    calls.push(method);
    if (method === 'relaunch-agent') { launched = true; return { terminal_id: 'term-new', session_id: WORK.id }; }
    if (method === 'list-terminals') {
      return launched
        ? { terminals: [{ id: 'term-new', name: 'Grok', window: 11, agent_surface: true, uses_alternate_screen: false }] }
        : { terminals: [] };
    }
    return params || {};
  });
  await T.refreshTerminals();
  check('started empty', T.terminalDetached === true);
  await T.relaunchSessionAgent();
  check('relaunch-agent was called', calls.includes('relaunch-agent'));
  check('the new terminal is active', T.activeTerminal && T.activeTerminal.id === 'term-new');
  check('its window is attached', T.attachedWindow === 11);
  check('overlay is gone', !T.window.document.getElementById('terminal-wrap').classList.contains('no-terminal'));
  check('keystrokes flow again', (() => { T.sendToPTY('hi'); return sock.sent.some((d) => !(typeof d === 'string' && d.startsWith('{'))); })());
}

console.log('\na failed relaunch does not paint onto the session switched to mid-request:');
{
  const T = load();
  const other = { id: 'sess-other', name: 'other', kind: 'work' };
  T.sessions = [WORK, other];
  T.selectedId = WORK.id;
  T.activeTerminal = PREV;
  T.attachedWindow = PREV.window;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  T.setRpc(async (method) => {
    if (method === 'relaunch-agent') {
      await gate;
      throw new Error('could not open a terminal window');
    }
    return { terminals: [] };
  });
  await T.refreshTerminals();
  const pending = T.relaunchSessionAgent();
  T.selectedId = other.id;
  await T.refreshTerminals();
  release();
  await pending;
  const sub = T.window.document.querySelector('.terminal-empty-sub');
  const btn = T.window.document.querySelector('.terminal-empty-relaunch');
  check('the other session is the one on screen', T.selectedId === other.id);
  check('its empty state is up', T.window.document.getElementById('terminal-wrap').classList.contains('no-terminal'));
  check('the previous relaunch error is not shown', sub && !sub.textContent.includes('could not open'));
  check('the button is not stuck relaunching', btn && btn.textContent === 'Relaunch agent' && btn.disabled === false);
}

console.log('\na manager with no terminal has no relaunch button:');
{
  const T = load();
  const manager = { id: 'mgr', name: 'Manager 2', kind: 'manager' };
  T.sessions = [manager];
  T.selectedId = manager.id;
  T.attachedWindow = 1;
  T.setRpc(async () => ({ terminals: [] }));
  await T.refreshTerminals();
  const btn = T.window.document.querySelector('.terminal-empty-relaunch');
  check('overlay is up', T.window.document.getElementById('terminal-wrap').classList.contains('no-terminal'));
  check('relaunch is hidden', !!btn && btn.hidden === true);
  check('previous window was cleared', T.attachedWindow === null);
}

  if (failed) { console.log('\n' + failed + ' failed'); process.exit(1); }
  console.log('\nall passed');
}

main().catch((err) => { console.error(err); process.exit(1); });
