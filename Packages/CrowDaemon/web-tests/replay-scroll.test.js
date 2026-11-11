const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// CROW-1403: the replay crowd sends on every select-window (CROW-606) must not
// cost the reader their place or their history.
//
//   * Every replay opens with ESC[3J. xterm's ED3 drops ydisp to 0, and while
//     the user is scrolled up the rebuilt history streams in under a viewport
//     pinned there, so a mid-read reconnect / heal / hydrate landed them on
//     line 1 (the "scrolling suddenly jumps to the top" report). The client now
//     records the reader's distance from the live edge when the ED3 is parsed
//     and restores it once that socket message has been parsed.
//   * The socket names the window it will select, so crowd can start the PTY
//     at that window's size instead of 0×0 (= tmux's 80×24).
//   * A window that leaves the alt buffer gets its scrollback cap lifted, and
//     the history the cap discarded is replayed. Reload re-reads the flags
//     first when capped, so it no longer replays into a 0-line buffer.
const epilogue = `
;globalThis.__t = {
  noteScrollbackClear(p){ return noteScrollbackClear(p); },
  restoreReplayScroll(){ return restoreReplayScroll(); },
  clearTermBuffer(){ return clearTermBuffer(); },
  terminalSocketPath(){ return terminalSocketPath(); },
  connectTerminalWs(){ return connectTerminalWs(); },
  refreshTerminals(){ return refreshTerminals(); },
  reloadTerminalWithFreshFlags(){ return reloadTerminalWithFreshFlags(); },
  applySurfaceScrollback(){ return applySurfaceScrollback(); },
  get replayScrollAnchor(){ return replayScrollAnchor; },
  set replayScrollAnchor(v){ replayScrollAnchor = v; },
  set term(v){ term = v; },
  get term(){ return term; },
  get termWs(){ return termWs; },
  set termWs(v){ termWs = v; },
  set activeTerminal(v){ activeTerminal = v; },
  get activeTerminal(){ return activeTerminal; },
  get attachedWindow(){ return attachedWindow; },
  set attachedWindow(v){ attachedWindow = v; },
  set selectedId(v){ selectedId = v; },
  set sessions(v){ sessions = v; },
  set rpc(fn){ rpc = fn; },
  set refreshTerminalsImpl(fn){ refreshTerminals = fn; },
  set reloadTerminalImpl(fn){ reloadTerminal = fn; },
};
`;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="app"><div id="terminal-wrap"><div id="tabbar"></div><div id="terminal"></div></div></div>
   </body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;
window.setTimeout = () => 0;
window.clearTimeout = () => {};
window.setInterval = () => 0;
window.requestAnimationFrame = () => 0;

const sockets = [];
window.WebSocket = function (url) {
  const s = { url, readyState: 0, sent: [], send(d) { this.sent.push(d); }, close() { this.readyState = 3; } };
  sockets.push(s);
  return s;
};
window.WebSocket.OPEN = 1;
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(loadClientSource() + epilogue, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

// Models the part of xterm this needs. Writing an ED3 runs the registered CSI
// handler first (that is noteScrollbackClear in the real terminal), then trims
// the scrollback, which sets ydisp to 0. A scrolled-up reader stays pinned at 0
// while the rebuilt history arrives, so the frame leaves viewportY at 0 and
// baseY at `nextBaseY`. The write callback fires once the data is parsed.
function xtermish(baseY, viewportY) {
  return {
    options: { scrollback: 50000 },
    buffer: { active: { baseY, viewportY } },
    nextBaseY: null,
    scrolledTo: null,
    scrollToLine(n) { this.scrolledTo = n; this.buffer.active.viewportY = n; },
    replays: 0,
    write(data, cb) {
      const s = typeof data === 'string' ? data : Buffer.from(data).toString('latin1');
      if (s.includes('\x1b[3J')) {
        this.replays++;
        T.noteScrollbackClear([3]);
        this.buffer.active.viewportY = 0;
        if (this.nextBaseY != null) this.buffer.active.baseY = this.nextBaseY;
      }
      if (cb) cb();
    },
    reset() {}, focus() {},
  };
}
const REPLAY = '\x1b[H\x1b[2J\x1b[3J' + 'history\r\n'.repeat(5);
// Built in the jsdom realm: the client's `event.data instanceof ArrayBuffer`
// checks the page's ArrayBuffer, and a Node-realm buffer would be dropped.
const bytes = (s) => window.Uint8Array.from(Buffer.from(s, 'latin1')).buffer;

function openSocket() {
  sockets.length = 0;
  T.activeTerminal = { id: 't1', name: 'Codex', window: 3, agent_surface: true, uses_alternate_screen: false };
  T.connectTerminalWs();
  const sock = sockets[0];
  sock.readyState = 1;
  return sock;
}

console.log('CROW-1403: a replay keeps a scrolled-up reader where they were:');
{
  T.term = xtermish(476, 436); // 40 lines above the live edge
  const sock = openSocket();
  T.term.nextBaseY = 476;
  sock.onmessage({ data: bytes(REPLAY) });
  check('the replay reached xterm', T.term.replays === 1);
  check('the reader is back 40 lines above the live edge, not on line 1',
    T.term.buffer.active.viewportY === 436);
  check('the anchor is spent once the replay message is parsed', T.replayScrollAnchor === null);
}

console.log('\na hydrate that brings back older lines keeps the same text in view:');
{
  T.term = xtermish(476, 436);
  const sock = openSocket();
  T.term.nextBaseY = 576; // 100 older lines came back at the top
  sock.onmessage({ data: bytes(REPLAY) });
  check('distance from the live edge is preserved (576 - 40)', T.term.buffer.active.viewportY === 536);
}

console.log('\na reader at the live edge is left to follow live output:');
{
  T.term = xtermish(476, 476);
  const sock = openSocket();
  T.term.nextBaseY = 480;
  sock.onmessage({ data: bytes(REPLAY) });
  check('the replay reached xterm', T.term.replays === 1);
  check('no scrollToLine at the live edge', T.term.scrolledTo === null);
}

// #1435 review: a reader on line 1 is the CROW-934 arrival-at-top hydrate
// asking for OLDER lines. The shell's local buffer is thinned (273 of ~20k
// lines), so keeping its height as the distance from the live edge would park
// the reader at ~19663 of the rebuilt history instead of on the oldest lines.
console.log('\nan arrival-at-top hydrate still lands on the oldest lines:');
{
  T.term = xtermish(273, 0);
  const sock = openSocket();
  T.term.nextBaseY = 19936;
  sock.onmessage({ data: bytes(REPLAY) });
  check('the replay reached xterm', T.term.replays === 1);
  check('no anchor is taken on line 1', T.term.scrolledTo === null);
  check('the reader stays on the oldest lines (ydisp 0)', T.term.buffer.active.viewportY === 0);
}

console.log('\nonly ED3 (clear scrollback) records an anchor:');
{
  T.term = xtermish(100, 50);
  T.replayScrollAnchor = null;
  T.noteScrollbackClear([2]);
  check('ED2 (clear screen) does not', T.replayScrollAnchor === null);
  T.noteScrollbackClear([0]);
  check('ED0 does not', T.replayScrollAnchor === null);
  check('the handler never consumes the sequence (xterm still clears)', T.noteScrollbackClear([3]) === false);
  check('ED3 does', T.replayScrollAnchor && T.replayScrollAnchor.linesFromBottom === 50);
  T.replayScrollAnchor = null;
}

console.log('\nlive output (no ED3) never moves the reader:');
{
  T.term = xtermish(476, 436);
  const sock = openSocket();
  sock.onmessage({ data: bytes('streaming token\r\n') });
  check('no scrollToLine for a live frame', T.term.scrolledTo === null);
}

console.log('\nour own clearTermBuffer (in-place switch) drops the anchor:');
{
  T.term = xtermish(476, 436);
  T.clearTermBuffer();
  check('no anchor survives the local clear', T.replayScrollAnchor === null);
  T.restoreReplayScroll();
  check('so the next window does not inherit the old position', T.term.scrolledTo === null);
}

console.log('\nCROW-1403: the socket names the window it will select:');
{
  T.term = xtermish(0, 0);
  sockets.length = 0;
  T.activeTerminal = { id: 't1', window: 7, agent_surface: true };
  T.connectTerminalWs();
  check('?window= carries the active window', /\/terminal\?window=7$/.test(sockets[0].url));
  T.activeTerminal = null;
  check('no active terminal → plain /terminal', T.terminalSocketPath() === '/terminal');
  T.activeTerminal = { id: 't1', window: null };
  check('no window yet → plain /terminal', T.terminalSocketPath() === '/terminal');
  T.activeTerminal = { id: 't1', window: 0 };
  check('window 0 is a real window', T.terminalSocketPath() === '/terminal?window=0');
}

function selectWindows(sock) {
  return sock.sent.map((d) => { try { return JSON.parse(d); } catch (_) { return null; } })
    .filter((m) => m && m.type === 'select-window');
}

(async () => {
  console.log('\nCROW-1403: a window leaving the alt buffer gets its history replayed:');
  {
    T.sessions = [{ id: 's1', name: 's', status: 'active', kind: 'work' }];
    T.selectedId = 's1';
    T.term = xtermish(0, 0);
    T.term.options.scrollback = 0; // capped while the Ctrl+G editor was open
    const sock = { readyState: 1, sent: [], send(d) { this.sent.push(d); }, close() {} };
    T.termWs = sock;
    T.activeTerminal = { id: 't1', name: 'Claude Code', window: 3, agent_surface: true, uses_alternate_screen: true };
    T.attachedWindow = 3;
    T.rpc = async () => ({ terminals: [
      { id: 't1', name: 'Claude Code', window: 3, agent_surface: true, uses_alternate_screen: false },
    ] });
    await T.refreshTerminals();
    check('the cap is lifted back to the unified 50k', T.term.options.scrollback === 50000);
    const sel = selectWindows(sock);
    check('one select-window asks crowd to replay the discarded history',
      sel.length === 1 && sel[0].window === 3 && sel[0].replay === undefined);

    sock.sent.length = 0;
    await T.refreshTerminals();
    check('a refresh that changes nothing sends nothing', selectWindows(sock).length === 0);
  }

  console.log('\nReload re-reads the flags first only when the surface is capped:');
  {
    const order = [];
    T.refreshTerminalsImpl = async () => { order.push('refresh'); };
    T.reloadTerminalImpl = () => { order.push('reload'); };
    T.term = xtermish(0, 0);
    T.term.options.scrollback = 0;
    T.reloadTerminalWithFreshFlags();
    await new Promise((r) => setImmediate(r));
    check('capped: refresh, then reload', order.join(',') === 'refresh,reload');
    order.length = 0;
    T.term.options.scrollback = 50000;
    T.reloadTerminalWithFreshFlags();
    check('uncapped: reload right away, no extra read', order.join(',') === 'reload');
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
