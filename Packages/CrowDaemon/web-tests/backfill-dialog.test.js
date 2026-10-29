const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource, loadSettingsSource } = require('./load-client');

// CROW-1378: Settings → Workspaces → "Backfill history…" must page backfill-scan.
//
// The daemon answers backfill-scan with counts only unless asked for rows
// (view: "sessions"), and cuts the rows into pages so a large history fits one
// reply. The dialog used to send `{}` and read `res.sessions`, which would now
// render an empty table for every history. This drives the real app.js +
// settings.js under jsdom against a paging mock and pins that the dialog asks
// for rows, walks every page of one snapshot (scan_id + next_offset), and
// lists every session exactly once. It also pins that a pre-paging daemon (every
// row in one reply, no next_offset) still loads in one call.

const epilogue = `
;globalThis.__t = {
  setRpc(fn) { rpc = fn; },
  openSettings: (tab) => window.openSettings(tab),
};
`;

const MARKUP = `<!doctype html><html><body>
  <div id="app">
    <aside id="sidebar"></aside>
    <main id="detail">
      <header id="detail-header"></header>
      <div id="tabbar"></div>
      <div id="terminal-wrap"><div id="terminal"></div></div>
      <div id="board"></div>
      <div id="detail-empty"><div class="empty-msg"></div></div>
    </main>
  </div>
  <div id="statusbar"></div>
</body></html>`;

// One workspace with a gateway, so the Backfill button is enabled.
function config() {
  return JSON.stringify({
    defaults: { provider: 'github', branchPrefix: 'feature/' },
    workspaces: [
      { id: 'ws-1', name: 'Acme', provider: 'github', cli: 'gh',
        alwaysInclude: [], autoReviewRepos: [], excludeReviewRepos: [], uploadSessionLogs: true,
        gateway: { baseURL: 'https://gw.corveil.example', customHeaders: { 'x-citadel-api-key': '' } } },
    ],
  });
}

function rows(n) {
  return Array.from({ length: n }, (_, i) => ({
    uid: 'uid-' + i, harness: 'claude', workspace: i % 2 ? 'Acme' : 'Other',
    repo_name: 'crow', owner_repo: 'corveil/crow', slug: 's' + i,
    modified_at: 1000 + i, size_bytes: 10, confidence: i % 3 ? 'medium' : 'high', upload_status: 'new',
  }));
}

const SUMMARY = (n) => ({ total: n, uploaded: 0, linkable: 0, repo_only: n, orphan: 0 });

// A daemon that pages: `pageSize` rows per reply, one snapshot `S1`.
function pagingDaemon(all, pageSize) {
  return (params) => {
    if (params.view !== 'sessions') {
      return { scan_id: 'S1', view: 'summary', summary: SUMMARY(all.length), total_matching: all.length };
    }
    if (params.offset && params.scan_id !== 'S1') throw new Error('later page not pinned to S1');
    const offset = params.offset || 0;
    const page = all.slice(offset, offset + pageSize);
    const next = offset + page.length < all.length ? offset + page.length : null;
    return {
      scan_id: 'S1', view: 'sessions', paged: true, summary: SUMMARY(all.length),
      total_matching: all.length, sessions: page, offset, limit: params.limit,
      returned: page.length, next_offset: next,
    };
  };
}

// A daemon from before paging: ignores params, every row at once.
function legacyDaemon(all) {
  return () => ({ sessions: all, summary: SUMMARY(all.length) });
}

function load(scanHandler) {
  const dom = new JSDOM(MARKUP, {
    runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/',
  });
  const { window } = dom;
  window.WebSocket = function () {
    return { send() {}, close() {},
      set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  window.setTimeout = (fn) => { fn(); return 0; };
  window.setInterval = () => 0;
  window.requestAnimationFrame = () => 0;
  window.matchMedia = () => ({ matches: false, addListener() {}, addEventListener() {} });
  window.confirm = () => true;
  window.fetch = (url) => {
    if (String(url).startsWith('/auth/context')) {
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ local: true }) });
    }
    return Promise.resolve({ ok: false, json: () => Promise.reject(new Error('n/a')) });
  };
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

  const ctx = dom.getInternalVMContext();
  try {
    vm.runInContext(loadClientSource() + epilogue + loadSettingsSource(), ctx, { filename: 'app+settings.js' });
  } catch (e) {
    console.log('[load warn]', e.message);
  }
  const T = ctx.__t;
  if (!T) throw new Error('epilogue did not run');
  const scans = [];
  T.setRpc((method, params) => {
    if (method === 'get-config') return Promise.resolve({ config: config(), dev_root: '/dev' });
    if (method === 'list-agents') return Promise.resolve({ agents: [] });
    if (method === 'corveil-list-orgs') return Promise.resolve({ orgs: [] });
    if (method === 'backfill-scan') {
      scans.push(params);
      try { return Promise.resolve(scanHandler(params)); } catch (e) { return Promise.reject(e); }
    }
    return Promise.reject(new Error('not stubbed: ' + method));
  });
  return { T, window, scans };
}

async function drain(n = 200) { for (let i = 0; i < n; i++) await Promise.resolve(); }

async function openBackfill(h) {
  await h.T.openSettings('workspaces');
  await drain();
  const edit = Array.from(h.window.document.querySelectorAll('button')).find((b) => b.title === 'Edit');
  if (!edit) throw new Error('workspace Edit button not found');
  edit.onclick();
  await drain();
  const btn = h.window.document.querySelector('.st-backfill-btn');
  if (!btn) throw new Error('Backfill history button not found');
  if (btn.disabled) throw new Error('Backfill history button is disabled');
  btn.onclick();
  await drain();
}

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

(async () => {
  console.log('The dialog asks for rows and walks every page of one snapshot:');
  {
    const all = rows(250);
    const h = load(pagingDaemon(all, 100));
    await openBackfill(h);
    check('three backfill-scan calls (100 + 100 + 50)', h.scans.length === 3);
    check('every call asks for view: "sessions"', h.scans.every((p) => p.view === 'sessions'));
    check('later pages are pinned to the first scan_id',
      h.scans.slice(1).every((p) => p.scan_id === 'S1'));
    check('offsets follow next_offset', JSON.stringify(h.scans.map((p) => p.offset || 0)) === '[0,100,200]');
    const trs = h.window.document.querySelectorAll('.backfill-table tbody tr');
    check('the table lists all 250 sessions (not an empty table)', trs.length === 250);
    const summary = h.window.document.querySelector('.backfill-summary').textContent;
    check('the header shows the scan summary', /^250 on disk/.test(summary));
    // Default selection still covers this workspace's high-confidence rows on every page.
    const expected = all.filter((s) => s.workspace === 'Acme' && s.confidence === 'high').length;
    const checked = Array.from(trs).filter((tr) => tr.querySelector('input').checked).length;
    check('default selection spans every page (' + expected + ' rows)', checked === expected);
    const btn = h.window.document.querySelector('.backfill-modal .action-primary');
    check('the Backfill button counts the selection', btn.textContent === 'Backfill (' + expected + ')');
  }

  console.log('\nA pre-paging daemon still loads in one call:');
  {
    const h = load(legacyDaemon(rows(30)));
    await openBackfill(h);
    check('one backfill-scan call', h.scans.length === 1);
    check('the table lists all 30 sessions',
      h.window.document.querySelectorAll('.backfill-table tbody tr').length === 30);
  }

  console.log('\nA page that does not advance fails loudly instead of looping:');
  {
    const h = load((params) => ({
      scan_id: 'S1', paged: true, summary: SUMMARY(5), total_matching: 5,
      sessions: rows(1), next_offset: 0,
    }));
    await openBackfill(h);
    check('stopped after the stuck page', h.scans.length === 2);
    const summary = h.window.document.querySelector('.backfill-summary').textContent;
    check('the header reports the scan failure', /^Scan failed: .*did not advance/.test(summary));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
