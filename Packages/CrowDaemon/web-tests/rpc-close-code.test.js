const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-956 regression tests for the /rpc close path. `crowd` caps an inbound
// WebSocket message and can only refuse an over-limit one by closing the socket
// with code 1009 — no request id was ever decoded, so there is nothing to
// correlate a JSON-RPC error reply to. That close used to be indistinguishable
// from a crashed daemon: both rejected in-flight calls with "rpc: connection
// closed", and the client reconnected a second later either way, so a Settings
// save that could never succeed looked exactly like a transient blip.
//
// Same loader shape as rpc-timeout.test.js — the REAL app.js in a jsdom VM plus
// an epilogue exposing module-scope internals, an onopen-firing fake socket, and
// a controllable timer queue (needed for the reconnect assertion). The one
// deviation is that this file's fake `close(code)` delivers a CloseEvent-shaped
// argument, which is the whole subject under test.
const epilogue = `
;globalThis.__t = {
  rpc(m, p, o){ return rpc(m, p, o); },
  rpcState,
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="sidebar"></div><div id="board"></div><div id="header"></div>
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

// --- fake /rpc socket -------------------------------------------------------
const sockets = [];
window.WebSocket = function () {
  const s = {
    sent: [], closed: false,
    send(d) { this.sent.push(JSON.parse(d)); },
    // `close(code)` — the deviation from rpc-timeout.test.js. A real CloseEvent
    // always carries a code; 1005 ("no status received") is what browsers report
    // when the peer closed without one, and 1006 is an abnormal drop.
    close(code) {
      this.closed = true;
      if (this._onclose) this._onclose({ code: code || 1005, reason: '', wasClean: code !== 1006 });
    },
    deliver(msg) { if (this._onmessage) this._onmessage({ data: JSON.stringify(msg) }); },
  };
  Object.defineProperty(s, 'onopen', { set(fn) { s._onopen = fn; fn(); } });
  Object.defineProperty(s, 'onmessage', { set(fn) { s._onmessage = fn; } });
  Object.defineProperty(s, 'onclose', { set(fn) { s._onclose = fn; } });
  Object.defineProperty(s, 'onerror', { set(fn) { s._onerror = fn; } });
  sockets.push(s);
  return s;
};
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };
const flush = () => new Promise((r) => setTimeout(r, 0));

// The newest socket: `ws.onclose` nulls `rpcState.ready`, so the next rpc()
// opens a fresh one and a captured reference goes stale.
const cur = () => sockets[sockets.length - 1];

async function reset() {
  T.rpcState.pending.clear();
  timers.length = 0;
  if (cur()) cur().sent.length = 0;
  await flush();
}

(async function run() {
  T.rpc('list-sessions').catch(() => {});
  await flush();
  check('a single /rpc socket backs every call', sockets.length === 1);

  console.log('\n1009 (message too large) is reported as itself, not as a dead daemon:');
  await reset();
  let err = null;
  const pSave = T.rpc('set-config', { config: 'x'.repeat(64) }).catch((e) => { err = e; });
  await flush();
  cur().close(1009);
  await pSave;
  check('names the method', err && /set-config/.test(err.message));
  check('says too large', err && /too large/.test(err.message));
  check('names the close code', err && /1009/.test(err.message));
  check('is NOT the generic connection-closed message',
    err && !/connection closed/.test(err.message));
  // Tagged like the timeout rejection, so a caller can branch without matching
  // on prose.
  check('tagged err.rpcTooLarge', err && err.rpcTooLarge === true);
  check('tagged err.rpcMethod', err && err.rpcMethod === 'set-config');
  check('map fully cleared', T.rpcState.pending.size === 0);

  console.log('\nEvery other close still reads exactly as it did:');
  await reset();
  let bare = null;
  const pBare = T.rpc('list-sessions').catch((e) => { bare = e; });
  await flush();
  cur().close(); // 1005 — peer closed with no status
  await pBare;
  check('no code → connection closed', bare && bare.message === 'rpc: connection closed');
  check('no code → untagged', bare && bare.rpcTooLarge === undefined);

  await reset();
  let abnormal = null;
  const pAbnormal = T.rpc('list-sessions').catch((e) => { abnormal = e; });
  await flush();
  cur().close(1006); // abnormal closure — a genuinely dead daemon
  await pAbnormal;
  check('1006 → connection closed', abnormal && abnormal.message === 'rpc: connection closed');

  console.log('\nA 1009 close leaves the rest of the teardown alone:');
  await reset();
  let lateFired = false;
  const pLate = T.rpc('add-merge-label', {}, { onLate: () => { lateFired = true; } }).catch(() => {});
  await flush();
  fireTimersAt(60000); // times out and is retained as settled
  await pLate;
  check('settled entry retained before close', T.rpcState.pending.size === 1);
  cur().close(1009);
  await flush();
  // Same reasoning as the generic close: the socket died before the daemon
  // answered, so the outcome is genuinely unknown and "too large" would be a
  // guess. Settled entries are dropped in silence either way.
  check('settled entry dropped without firing onLate', lateFired === false);
  check('map fully cleared', T.rpcState.pending.size === 0);

  console.log('\nReconnect is unchanged after a 1009:');
  await reset();
  const before = sockets.length;
  const pRe = T.rpc('list-sessions').catch(() => {});
  await flush();
  cur().close(1009);
  await pRe;
  // 1009 is per-MESSAGE, not per-connection: the socket is fine for every other
  // request, and staying offline over one oversized payload would take the whole
  // UI down. Nothing re-sends the offending message, so there is no retry loop.
  check('a reconnect is armed', fireTimersAt(1000) === 1);
  await flush();
  check('a fresh socket was opened', sockets.length > before);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
