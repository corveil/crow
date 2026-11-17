const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource, loadSettingsSource } = require('./load-client');

// CROW-1462 (#1378): `crow backfill scan` now writes its rows to a file because
// the Unix socket caps a reply at 1 MiB. The Settings "Backfill history…" dialog
// is unchanged — it calls `backfill-scan` with no `output_path` over `/rpc`, whose
// replies aren't capped (WebSocketFrameSizeTests pins the daemon side). This pins
// the browser side: a scan reply past 1 MiB renders EVERY row, with no paging,
// and the dialog never asks the daemon to write a file.

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

// One workspace with a gateway, so its "Backfill history…" button is enabled.
function config() {
  return JSON.stringify({
    defaults: { provider: 'github', branchPrefix: 'feature/' },
    workspaces: [
      { id: 'ws-1', name: 'Acme', provider: 'github', cli: 'gh',
        alwaysInclude: [], autoReviewRepos: [], excludeReviewRepos: [], uploadSessionLogs: true,
        gateway: { baseURL: 'https://gw.example', customHeaders: {} } },
    ],
  });
}

// `count` rows shaped like the daemon's `backfillSessionJSON`.
function scanReply(count) {
  const sessions = [];
  for (let i = 0; i < count; i++) {
    const slug = '-Users-someone-Dev-Acme-acme-api-' + i + '-a-fairly-long-worktree-slug';
    sessions.push({
      uid: 'uid-' + i, harness: 'claude',
      file_path: '/Users/someone/.claude/projects/' + slug + '/' + i + '.jsonl',
      slug, cwd: '/Users/someone/Dev/Acme/acme-api-' + i, git_branch: 'feature/acme-api-' + i,
      modified_at: 1700000000 + i, size_bytes: 10000 + i,
      confidence: i % 3 === 0 ? 'medium' : 'high', upload_status: i % 5 === 0 ? 'uploaded' : 'new',
      ticket_kind: 'issue', worktree_exists: false,
      workspace: 'Acme', worktree_name: 'acme-api-' + i, repo_name: 'acme-api',
      owner_repo: 'acme/acme-api', host: 'github.com', ticket_number: i,
    });
  }
  return { sessions, summary: { total: count, uploaded: Math.ceil(count / 5), linkable: 0, repo_only: 0, orphan: 0 } };
}

function load(reply) {
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
  const calls = [];
  T.setRpc((method, params) => {
    calls.push({ method, params });
    if (method === 'get-config') return Promise.resolve({ config: config(), dev_root: '/dev' });
    if (method === 'list-agents') return Promise.resolve({ agents: [] });
    if (method === 'corveil-list-orgs') return Promise.resolve({ orgs: [] });
    if (method === 'backfill-scan') return Promise.resolve(reply);
    return Promise.reject(new Error('not stubbed: ' + method));
  });
  return { T, window, calls };
}

async function drain(n = 80) { for (let i = 0; i < n; i++) await Promise.resolve(); }

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

(async () => {
  console.log('The Backfill history dialog lists every row of a scan reply past 1 MiB:');
  const N = 4000;
  const reply = scanReply(N);
  const bytes = Buffer.byteLength(JSON.stringify(reply));
  check('the fixture reply is over 1 MiB (' + bytes + ' bytes)', bytes > 1 << 20);

  const h = load(reply);
  await h.T.openSettings('workspaces');
  await drain();
  const edit = Array.from(h.window.document.querySelectorAll('button')).find((b) => b.title === 'Edit');
  if (!edit) throw new Error('workspace Edit button not found');
  edit.onclick();
  await drain();
  const bfBtn = h.window.document.querySelector('.st-backfill-btn');
  check('the Backfill history button is enabled', !!bfBtn && !bfBtn.disabled);
  bfBtn.onclick();
  await drain();

  const scans = h.calls.filter((c) => c.method === 'backfill-scan');
  check('the dialog scanned once', scans.length === 1);
  check('without output_path — the dialog never has the daemon write a file',
    scans.length === 1 && !('output_path' in (scans[0].params || {})));

  const rows = h.window.document.querySelectorAll('.backfill-row');
  check('every row is rendered (' + rows.length + ' of ' + N + ')', rows.length === N);
  const summary = h.window.document.querySelector('.backfill-summary');
  check('the summary reports the full total', !!summary && summary.textContent.startsWith(N + ' on disk'));

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
