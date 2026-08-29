const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// #931 regression tests for the RPC layer: per-method deadlines mirroring the
// CLI, and a timeout that can never leave a spurious "failed" modal on screen
// after the daemon answers. Same loader shape as row.test.js — the REAL app.js
// in a jsdom VM plus an epilogue exposing module-scope internals — with two
// necessary deviations, both because this file tests the transport itself:
//   • the fake WebSocket must FIRE onopen (row.test.js discards it), or
//     `rpcState.ready` never resolves and rpc() can't send;
//   • setTimeout/clearTimeout are a controllable queue rather than `() => 0`,
//     so a deadline can be fired on demand AND selected by its delay — which is
//     how we assert the table is keyed to the right wire method name.
const epilogue = `
;globalThis.__t = {
  rpc(m, p, o){ return rpc(m, p, o); },
  rpcState,
  rpcTimeoutFor(m){ return rpcTimeoutFor(m); },
  gcSettledRPCs(){ return gcSettledRPCs(); },
  sessionAction(m, id, x){ return sessionAction(m, id, x); },
  dismissModalDialog(t){ return dismissModalDialog(t); },
  RPC_DEFAULT_TIMEOUT_MS,
  RPC_LATE_WINDOW_MS,
};
`;
const appjs = loadClientSource() + epilogue;

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
// Fire (and remove) every queued timer scheduled with exactly `ms`. Selecting by
// delay is the point: it proves `add-merge-label` was armed at 60s and not at
// the 30s default.
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
    close() { this.closed = true; if (this._onclose) this._onclose(); },
    deliver(msg) { if (this._onmessage) this._onmessage({ data: JSON.stringify(msg) }); },
  };
  // rpcConnect assigns `ws.onopen` on the line after `new WebSocket(...)`, so
  // `ws` is already bound and calling the handler straight from the setter
  // resolves `rpcState.ready`.
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
// Node's own setTimeout — the VM's is the fake above.
const flush = () => new Promise((r) => setTimeout(r, 0));
const doc = window.document;
const modalNode = () => doc.querySelector('.modal-dialog-backdrop');
const modalText = () => {
  const b = modalNode();
  return b ? ((b.querySelector('.text-prompt-body') || {}).textContent || '') : null;
};
const modalTitle = () => {
  const b = modalNode();
  return b ? ((b.querySelector('.text-prompt-title') || {}).textContent || '') : null;
};

async function reset() {
  T.rpcState.pending.clear();
  timers.length = 0;
  doc.querySelectorAll('.modal-dialog-backdrop').forEach((b) => b.remove());
  if (cur()) cur().sent.length = 0;
  await flush();
}

// The newest socket. `ws.onclose` nulls `rpcState.ready`, so the next rpc()
// opens a fresh one — after the onclose block below, a captured reference would
// be stale.
const cur = () => sockets[sockets.length - 1];
const lastId = () => cur().sent[cur().sent.length - 1].id;
const deliver = (msg) => cur().deliver(msg);

(async function run() {
  // Boot may or may not have opened the socket; force one so `cur()` exists.
  T.rpc('list-sessions').catch(() => {});
  await flush();
  check('a single /rpc socket backs every call', sockets.length === 1);

  console.log('\nPer-method timeout table mirrors the CLI:');
  check('default is 30s', T.rpcTimeoutFor('list-sessions') === 30000);
  check('unknown method falls back to the default',
    T.rpcTimeoutFor('no-such-method') === T.RPC_DEFAULT_TIMEOUT_MS);
  check('rebuild-scorecard 180s', T.rpcTimeoutFor('rebuild-scorecard') === 180000);
  check('refresh-tickets 120s', T.rpcTimeoutFor('refresh-tickets') === 120000);
  check('start-review 120s', T.rpcTimeoutFor('start-review') === 120000);
  check('batch-start-review 120s', T.rpcTimeoutFor('batch-start-review') === 120000);
  // The wire-name check: `crow job run` sends job-run, Settings' "Run now" sends
  // run-job. Keying only off the CLI verb would leave the web button on 30s.
  check('job-run 120s (CLI wire name)', T.rpcTimeoutFor('job-run') === 120000);
  check('run-job 120s (web wire name)', T.rpcTimeoutFor('run-job') === 120000);
  check('add-merge-label 60s', T.rpcTimeoutFor('add-merge-label') === 60000);
  check('mark-issue-done 60s', T.rpcTimeoutFor('mark-issue-done') === 60000);
  check('quick-action 60s', T.rpcTimeoutFor('quick-action') === 60000);
  check('get-state 60s', T.rpcTimeoutFor('get-state') === 60000);
  check('batch-work-on-issues 60s', T.rpcTimeoutFor('batch-work-on-issues') === 60000);

  console.log('\nTimeout rejects tagged and RETAINS the pending entry:');
  await reset();
  let caught = null;
  const p = T.rpc('add-merge-label', { session_id: 's1' }).catch((e) => { caught = e; });
  await flush();
  const id1 = lastId();
  check('armed at the table value, not the default', fireTimersAt(60000) === 1);
  await p;
  check('rejected', !!caught);
  check('tagged err.rpcTimeout', caught.rpcTimeout === true);
  check('tagged err.rpcMethod', caught.rpcMethod === 'add-merge-label');
  check('message names the method and the deadline',
    /add-merge-label/.test(caught.message) && /60s/.test(caught.message));
  check('pending entry retained (not deleted)', T.rpcState.pending.has(id1));
  check('entry flagged settled', T.rpcState.pending.get(id1).settled === true);

  console.log('\nA late response routes to onLate, not the dropped-message path:');
  await reset();
  let late = null;
  const p2 = T.rpc('add-merge-label', { session_id: 's1' }, {
    onLate: (result, error) => { late = { result, error }; },
  }).catch(() => {});
  await flush();
  const id2 = lastId();
  fireTimersAt(60000);
  await p2;
  deliver({ jsonrpc: '2.0', id: id2, result: { ok: true, warning: 'watcher is off' } });
  check('onLate fired with the result', late && late.result && late.result.ok === true);
  check('onLate error arg is null on success', late && late.error === null);
  check('entry dropped once delivered', !T.rpcState.pending.has(id2));

  console.log('\nA late *error* response reaches onLate as an Error:');
  await reset();
  late = null;
  const p3 = T.rpc('add-merge-label', {}, { onLate: (r, e) => { late = { r, e }; } }).catch(() => {});
  await flush();
  const id3 = lastId();
  fireTimersAt(60000);
  await p3;
  deliver({ jsonrpc: '2.0', id: id3, error: { message: 'label create denied' } });
  check('onLate result arg is null on failure', late && late.r === null);
  check('onLate carries the daemon message', late && /label create denied/.test(late.e.message));

  console.log('\nsessionAction: timeout shows an advisory, not "failed":');
  await reset();
  const sa = T.sessionAction('add-merge-label', 's1');
  await flush();
  const id4 = lastId();
  fireTimersAt(60000);
  await flush();
  check('a modal is up', modalText() !== null);
  check('titled "Still running"', modalTitle() === 'Still running');
  check('does NOT say failed', !/failed/i.test(modalText()));
  check('says it is still running on the daemon', /still running on the daemon/.test(modalText()));

  console.log('\n…and a late success takes that advisory down:');
  deliver({ jsonrpc: '2.0', id: id4, result: { ok: true } });
  await flush();
  await sa;
  check('advisory dismissed', modalNode() === null);

  console.log('\n…a late success WITH a warning replaces it with the warning (#888):');
  await reset();
  const sa2 = T.sessionAction('add-merge-label', 's1');
  await flush();
  const id5 = lastId();
  fireTimersAt(60000);
  await flush();
  deliver({ jsonrpc: '2.0', id: id5, result: { ok: true, warning: 'auto-merge watcher is off' } });
  await flush();
  await sa2;
  check('warning shown', /auto-merge watcher is off/.test(modalText() || ''));
  check('not the advisory any more', modalTitle() !== 'Still running');

  console.log('\n…and a late failure replaces it with the real error:');
  await reset();
  const sa3 = T.sessionAction('add-merge-label', 's1');
  await flush();
  const id6 = lastId();
  fireTimersAt(60000);
  await flush();
  deliver({ jsonrpc: '2.0', id: id6, error: { message: 'gh: not authenticated' } });
  await flush();
  await sa3;
  check('one modal, not two', doc.querySelectorAll('.modal-dialog-backdrop').length === 1);
  check('reads as a real failure',
    /add-merge-label failed: gh: not authenticated/.test(modalText()));

  console.log('\nA non-timeout rejection still reads as a plain failure:');
  await reset();
  const sa4 = T.sessionAction('set-locked', 's1', { locked: true });
  await flush();
  deliver({ jsonrpc: '2.0', id: lastId(), error: { message: 'session not found' } });
  await sa4;
  check('titled Crow (alertModal default), not "Still running"', modalTitle() === 'Crow');
  check('says failed', /set-locked failed: session not found/.test(modalText()));

  console.log('\ndismissModalDialog only retracts its own dialog:');
  await reset();
  const sa5 = T.sessionAction('add-merge-label', 's1');
  await flush();
  const id7 = lastId();
  fireTimersAt(60000);
  await flush();
  check('advisory up', modalTitle() === 'Still running');
  // Something else (a user action) supersedes it before the reply lands.
  modalNode().__token = { someone: 'else' };
  deliver({ jsonrpc: '2.0', id: id7, result: { ok: true } });
  await flush();
  await sa5;
  check('a superseding dialog is never yanked', modalNode() !== null);
  check('stale token is a no-op', T.dismissModalDialog({}) === false);
  check('null token is a no-op', T.dismissModalDialog(null) === false);

  console.log('\nonclose clears both settled and unsettled entries:');
  await reset();
  let closeErr = null, lateAfterClose = false;
  const pA = T.rpc('list-sessions').catch((e) => { closeErr = e; });
  await flush();
  const pB = T.rpc('add-merge-label', {}, { onLate: () => { lateAfterClose = true; } }).catch(() => {});
  await flush();
  fireTimersAt(60000); // B times out and is retained
  await pB;
  check('one settled + one live entry before close', T.rpcState.pending.size === 2);
  cur().close();
  await pA;
  check('unsettled rejected with connection closed',
    closeErr && /connection closed/.test(closeErr.message));
  check('map fully cleared', T.rpcState.pending.size === 0);
  check('settled entry dropped silently — no onLate on an unknown outcome',
    lateAfterClose === false);

  console.log('\nSettled entries are garbage-collected:');
  await reset();
  const pC = T.rpc('add-merge-label', {}).catch(() => {});
  await flush();
  const id8 = lastId();
  fireTimersAt(60000);
  await pC;
  check('retained immediately after the timeout', T.rpcState.pending.has(id8));
  T.rpcState.pending.get(id8).settledAt = Date.now() - (T.RPC_LATE_WINDOW_MS + 1000);
  T.gcSettledRPCs();
  check('swept once past the late window', !T.rpcState.pending.has(id8));

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
