const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { WEB, loadClientSource } = require('./load-client');

// CROW-1460 regression tests: hide workspace content while the web UI is
// disconnected. Loads the REAL client scripts into a jsdom built from the REAL
// index.html body (so #app, #conn-cover, #session-scrim and #statusbar are the
// shipped markup), with:
//   • a fake /rpc WebSocket whose open/close the test drives by hand — the cover
//     is all about what happens between those two events;
//   • a controllable timer queue, so the 3s grace is fired (or not) on demand;
//   • a stubbed fetch for the /auth/check probe behind session expiry.
const epilogue = `
;globalThis.__t = {
  get wsConnected() { return wsConnected; },
  get sessionDead() { return sessionDead; },
  get sessions() { return sessions; },
  set sessions(v) { sessions = v; },
  boardData,
  gridTerms,
  setTerm(t) { term = t; },
  uiConfig,
  DISCONNECT_COVER_GRACE_MS,
  renderStatusBar() { renderStatusBar(); },
};
`;
const appjs = loadClientSource() + epilogue;

const html = fs.readFileSync(WEB + 'index.html', 'utf8');
const body = html.slice(html.indexOf('<body'), html.lastIndexOf('</body>') + '</body>'.length)
  .replace(/<script[\s\S]*?<\/script>/g, '');
// Remote host: signedInOverWeb() is only true off loopback, which the expiry
// path needs (loopback can never reach sessionDead).
const dom = new JSDOM(`<!doctype html><html>${body}</html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'https://crow.example.test/' });
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
const pendingAt = (ms) => timers.filter((t) => t.ms === ms).length;

// --- fake /rpc socket: opened and closed by the test ------------------------
const sockets = [];
window.WebSocket = function (url) {
  const s = {
    url, sent: [], closed: false, readyState: 0,
    send(d) { this.sent.push(JSON.parse(d)); },
    open() { this.readyState = 1; if (this._onopen) this._onopen(); },
    close(code) {
      if (this.closed) return;
      this.closed = true; this.readyState = 3;
      if (this._onclose) this._onclose({ code: code || 1006, reason: '', wasClean: false });
    },
  };
  Object.defineProperty(s, 'onopen', { set(fn) { s._onopen = fn; } });
  Object.defineProperty(s, 'onmessage', { set(fn) { s._onmessage = fn; } });
  Object.defineProperty(s, 'onclose', { set(fn) { s._onclose = fn; } });
  Object.defineProperty(s, 'onerror', { set(fn) { s._onerror = fn; } });
  Object.defineProperty(s, 'binaryType', { set() {} });
  sockets.push(s);
  return s;
};
window.WebSocket.OPEN = 1;
let authStatus = 204;
window.fetch = async (url) => {
  if (String(url).startsWith('/auth/check')) return { status: authStatus, ok: authStatus < 300 };
  throw new Error('offline');
};

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (client threw before it)'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };
const flush = () => new Promise((r) => setImmediate(r));
const $ = (id) => window.document.getElementById(id);
const rpcSockets = () => sockets.filter((s) => /\/rpc$/.test(s.url));
const curRpc = () => rpcSockets()[rpcSockets().length - 1];
const coverUp = () => !$('conn-cover').hidden;
const GRACE = T.DISCONNECT_COVER_GRACE_MS;

(async function run() {
  console.log('Static markup and CSS:');
  const css = fs.readFileSync(WEB + 'app.css', 'utf8');
  const rule = (sel) => {
    const m = css.match(new RegExp('(^|\\n)' + sel.replace(/[.#]/g, '\\$&') + '\\s*\\{([^}]*)\\}'));
    return m ? m[2] : '';
  };
  const cover = rule('.app-cover');
  check('#conn-cover and #session-scrim share the .app-cover class',
    $('conn-cover').classList.contains('app-cover') && $('session-scrim').classList.contains('app-cover'));
  check('the cover is opaque (the app background, not the see-through --overlay)',
    /background:\s*var\(--bg-deep\)/.test(cover) && !/--overlay/.test(cover));
  const z = Number((cover.match(/z-index:\s*(\d+)/) || [])[1]);
  check('the cover sits above modals and Settings (z > 2200)', z > 2200);
  check('the cover sits below the setup wizard (z < 3000)', z < 3000);
  const lifted = Number((rule('body.app-covered #statusbar').match(/z-index:\s*(\d+)/) || [])[1]);
  check('body.app-covered lifts #statusbar above the cover', lifted > z);
  check('#session-scrim no longer has its own see-through rule', !/#session-scrim\s*\{/.test(css));
  // CROW-1471: the particle crow sits in the shipped markup (crowd is down
  // while the cover shows, so nothing can be fetched then), above the title.
  const brand = $('conn-cover-brand');
  check('#conn-cover carries a .brand-mark host with the /brand.svg fallback',
    !!brand && brand.classList.contains('brand-mark') && $('conn-cover').contains(brand)
    && brand.querySelector('img') && brand.querySelector('img').getAttribute('src') === '/brand.svg');
  check('the crow sits above the "Disconnected" title',
    !!brand && brand.nextElementSibling && brand.nextElementSibling.classList.contains('scrim-title'));
  check('the session-expired scrim has no brand mark', !$('session-scrim').querySelector('.brand-mark'));

  console.log('\nBoot: not yet connected counts as disconnected:');
  await flush();
  check('boot opened an /rpc socket', rpcSockets().length >= 1);
  check('cover is not up immediately (cache paint may show during the grace)', !coverUp());
  check('a grace timer is armed', pendingAt(GRACE) === 1);
  fireTimersAt(GRACE);
  check('first connect slower than the grace → cover goes up', coverUp());
  check('#app is inert behind it', $('app').inert === true);
  check('body.app-covered set so the status bar stays above', window.document.body.classList.contains('app-covered'));
  check('status bar still reads Connecting…', $('statusbar').querySelector('.conn-label').textContent === 'Connecting…');

  console.log('\nConnect clears the cover:');
  curRpc().open();
  await flush();
  check('wsConnected', T.wsConnected === true);
  check('cover hidden', !coverUp());
  check('#app interactive again', $('app').inert === false);
  check('body.app-covered cleared', !window.document.body.classList.contains('app-covered'));
  check('no stray grace timer left armed', pendingAt(GRACE) === 0);

  console.log('\nA drop shorter than the grace never shows the cover:');
  curRpc().close();
  await flush();
  check('disconnected', T.wsConnected === false);
  check('cover not shown yet', !coverUp());
  check('grace timer armed once', pendingAt(GRACE) === 1);
  fireTimersAt(1000); // rpc.js reconnect backoff
  await flush();
  const before = curRpc().sent.length;
  curRpc().open();
  await flush();
  check('reconnect cancels the grace timer', pendingAt(GRACE) === 0);
  check('cover never went up', !coverUp());
  fireTimersAt(0);  // deferred resync
  fireTimersAt(50); // onServerChanged coalescing tick
  await flush();
  const sentNow = curRpc().sent.slice(before).map((m) => m.method);
  check('reconnect re-fetches sessions', sentNow.includes('list-sessions'));
  check('reconnect re-fetches boards', sentNow.includes('list-tickets') && sentNow.includes('list-reviews'));

  console.log('\nA sustained drop covers the app; reconnect clears it:');
  curRpc().close();
  await flush();
  fireTimersAt(GRACE);
  check('cover up after the grace', coverUp());
  check('cover is not the expired scrim', $('session-scrim').hidden);
  check('a rapid re-render does not re-arm the timer while shown', (() => {
    T.renderStatusBar();
    return pendingAt(GRACE) === 0;
  })());
  fireTimersAt(1000);
  await flush();
  curRpc().open();
  await flush();
  check('cover cleared on its own once /rpc reconnects', !coverUp());

  console.log('\nDisconnect alone does not purge localStorage:');
  window.localStorage.setItem('crow.sidebar.cache', '{"sessions":[]}');
  curRpc().close();
  await flush();
  fireTimersAt(GRACE);
  check('sidebar cache survives a plain disconnect', window.localStorage.getItem('crow.sidebar.cache') !== null);
  fireTimersAt(1000);
  await flush();
  curRpc().open();
  await flush();

  console.log('\nSession expiry: opaque scrim and in-page data cleared:');
  T.uiConfig.webPasswordSet = true;
  T.sessions = [{ id: 'a', name: 'secret-session' }];
  T.boardData.tickets = { issues: [{ title: 'secret ticket' }] };
  T.boardData.reviews = { reviews: [] };
  let resets = 0;
  T.setTerm({ reset() { resets++; } });
  let disposed = 0;
  T.gridTerms.set('a', { term: { dispose() { disposed++; } } });
  $('sidebar').textContent = 'secret-session';
  $('board').textContent = 'secret ticket';
  authStatus = 401;
  curRpc().close();
  for (let i = 0; i < 5; i++) await flush();
  check('sessionDead', T.sessionDead === true);
  check('expired scrim shown', !$('session-scrim').hidden);
  check('disconnected cover not stacked on top of it', !coverUp());
  check('no grace timer armed while dead', pendingAt(GRACE) === 0);
  check('#app inert', $('app').inert === true);
  check('status bar lifted above the scrim', window.document.body.classList.contains('app-covered'));
  check('sessions emptied', Array.isArray(T.sessions) && T.sessions.length === 0);
  check('boardData emptied', Object.keys(T.boardData).every((k) => T.boardData[k] === null));
  check('session xterm buffer reset', resets === 1);
  check('grid xterms disposed', disposed === 1 && T.gridTerms.size === 0);
  check('sidebar DOM blanked', $('sidebar').textContent === '');
  check('board DOM blanked', $('board').textContent === '');
  check('localStorage purged (existing CROW-909 behavior)', window.localStorage.getItem('crow.sidebar.cache') === null);

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.log('FATAL', e); process.exit(2); });
