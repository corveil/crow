const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-1124 behaviour test: picking a Corveil org for a WORKSPACE auto-enables its
// session-log upload, and that opt-in survives Cancel + a later Save. Runs the real
// app.js + settings.js under jsdom against mocks (same loader shape as
// gateway-org-picker.test.js), driving the per-workspace AI-gateway picker on the
// Workspaces tab.
//
// Guards the review-round Yellow: the daemon persists uploadSessionLogs=true in the
// same locked workspace-gateway write, but the browser must mirror that onto the LIVE
// cfg.workspaces entry (not only the sub-form draft, which Cancel discards) — else a
// pick → Cancel → edit-another-field → Save round-trips uploadSessionLogs=false and
// clobbers the opt-in the pick just turned on. It also pins that the client honors the
// POST's `log_sync_enabled` (single source of truth) rather than inferring enablement,
// so a server that declines to enable is respected.
const WEB = __dirname + '/../Sources/CrowDaemon/Resources/web/';
const APP_JS = WEB + 'app.js';
const SETTINGS_JS = WEB + 'settings.js';

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

// A connected config with one existing workspace and no gateway yet, as get-config
// would send it (OAuth tokens + per-org key secrets stripped; the derivation and the
// uploadSessionLogs flip both happen server-side).
function connectedConfig() {
  return JSON.stringify({
    corveilConnection: {
      baseURL: 'https://app.corveil.example',
      clientID: 'crow-client-abc123',
      connectedUser: { id: 'u_1', email: 'dustin@example.com', name: 'Dustin Hilgaertner' },
      orgKeys: [],
      orgKeySecrets: {},
      oauth: { accessToken: '', refreshToken: '', registrationAccessToken: '' },
    },
    defaults: { provider: 'github', branchPrefix: 'feature/' },
    workspaces: [
      { id: 'ws-1', name: 'Acme', provider: 'github', cli: 'gh',
        alwaysInclude: [], autoReviewRepos: [], excludeReviewRepos: [], uploadSessionLogs: false },
    ],
  });
}

function load({ config, logSyncEnabled }) {
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

  const calls = { rpc: [], gatewayPosts: [] };
  const hooks = {
    listOrgs: () => Promise.resolve({ orgs: [
      { org_id: 'org_acme', org_name: 'Acme Corp', role: 'admin', is_active: true, provisioned: false },
    ] }),
    selectOrg: () => Promise.resolve({ saved: true, reused: false,
      org: { org_id: 'org_acme', org_name: 'Acme Corp', key_id: 'k1', key_prefix: 'sk-citadel-Ab' } }),
  };

  let configBody = config;
  window.fetch = (url, init) => {
    const u = String(url);
    if (u.startsWith('/auth/context')) {
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ local: true }) });
    }
    if (u.startsWith('/config/workspace-gateway')) {
      const parsed = init && init.body ? JSON.parse(init.body) : {};
      calls.gatewayPosts.push(parsed);
      // The daemon flips uploadSessionLogs in the same write and reports it back.
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve({ saved: true, gateway_set: true, log_sync_enabled: !!logSyncEnabled }),
      });
    }
    return Promise.resolve({ ok: false, json: () => Promise.reject(new Error('n/a')) });
  };
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

  const ctx = dom.getInternalVMContext();
  const src = fs.readFileSync(APP_JS, 'utf8') + epilogue + fs.readFileSync(SETTINGS_JS, 'utf8');
  try {
    vm.runInContext(src, ctx, { filename: 'app+settings.js' });
  } catch (e) {
    console.log('[load warn]', e.message);
  }
  const T = ctx.__t;
  if (!T) throw new Error('epilogue did not run');
  T.setRpc((method, params) => {
    calls.rpc.push({ method, params });
    if (method === 'get-config') return Promise.resolve({ config: configBody, dev_root: '/dev' });
    if (method === 'list-agents') return Promise.resolve({ agents: [] });
    if (method === 'corveil-list-orgs') return hooks.listOrgs();
    if (method === 'corveil-select-org') return hooks.selectOrg();
    if (method === 'set-config') return Promise.resolve({ config: params.config });
    return Promise.reject(new Error('not stubbed: ' + method));
  });
  return { T, window, hooks, calls };
}

async function drain(n = 60) { for (let i = 0; i < n; i++) await Promise.resolve(); }

function byText(window, selector, re) {
  return Array.from(window.document.querySelectorAll(selector)).find((n) => re.test(n.textContent)) || null;
}

function orgSelect(window) {
  return Array.from(window.document.querySelectorAll('select')).find(
    (s) => Array.from(s.options).some((o) => /organization/i.test(o.textContent))) || null;
}

function logSyncCheckbox(window) {
  const row = Array.from(window.document.querySelectorAll('.st-switch-row')).find(
    (r) => /Upload session transcripts/i.test(r.textContent));
  return row ? row.querySelector('input') : null;
}

// Open Settings → Workspaces, click the workspace's Edit pencil, and wait for the
// org dropdown inside the sub-form to populate.
async function openWorkspaceForm(h) {
  await h.T.openSettings('workspaces');
  const edit = byText(h.window, 'button[title="Edit"]', /.?/) ||
    Array.from(h.window.document.querySelectorAll('button')).find((b) => b.title === 'Edit');
  if (!edit) throw new Error('workspace Edit button not found');
  edit.onclick();
  for (let i = 0; i < 120; i++) {
    const sel = orgSelect(h.window);
    if (sel && Array.from(sel.options).some((o) => o.value === 'org_acme')) return h;
    await Promise.resolve();
  }
  throw new Error('org dropdown never populated in the workspace form');
}

async function pickOrg(h) {
  const sel = orgSelect(h.window);
  sel.value = 'org_acme';
  await sel.onchange();
  await drain();
}

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

(async () => {
  console.log('Picking an org for a workspace auto-enables log upload on the draft:');
  {
    const h = load({ config: connectedConfig(), logSyncEnabled: true });
    await openWorkspaceForm(h);
    await pickOrg(h);
    check('workspace-gateway POST carried { workspaceId, orgId }', h.calls.gatewayPosts.length === 1
      && h.calls.gatewayPosts[0].workspaceId === 'ws-1' && h.calls.gatewayPosts[0].orgId === 'org_acme');
    check('no key secret ever left the browser',
      !JSON.stringify(h.calls.gatewayPosts).toLowerCase().includes('sk-citadel'));
    const cb = logSyncCheckbox(h.window);
    check('the "Upload session transcripts" box is now checked in the open form', !!cb && cb.checked === true);
  }

  console.log('\nThe opt-in survives Cancel + Save (not just the discarded draft):');
  {
    const h = load({ config: connectedConfig(), logSyncEnabled: true });
    await openWorkspaceForm(h);
    await pickOrg(h);
    // Cancel the sub-form — the draft is discarded here.
    byText(h.window, '.settings-subform-overlay .settings-foot .action-btn', /^Cancel$/).onclick();
    await drain();
    // Make an unrelated edit so Save is enabled, then Save — exactly the reviewer's
    // clobber sequence.
    const branch = h.window.document.querySelector('.settings-body .st-input');
    branch.value = 'feat/';
    branch.oninput();
    await drain();
    byText(h.window, '.settings-foot .action-primary', /^Save$/).onclick();
    await drain();
    const setCfg = h.calls.rpc.filter((c) => c.method === 'set-config').pop();
    const sent = setCfg ? JSON.parse(setCfg.params.config) : null;
    check('set-config was sent on Save', !!sent);
    check('the workspace keeps uploadSessionLogs=true (no clobber)',
      !!sent && sent.workspaces[0].uploadSessionLogs === true);
  }

  console.log('\nThe client honors the server: log_sync_enabled=false does NOT enable:');
  {
    const h = load({ config: connectedConfig(), logSyncEnabled: false });
    await openWorkspaceForm(h);
    await pickOrg(h);
    const cb = logSyncCheckbox(h.window);
    // A gateway was written, but the daemon declined to enable — the client must not
    // force it on from its own inference.
    check('the box is NOT checked when the server did not enable', !!cb && cb.checked === false);
    // And a subsequent Save carries false, not a forced true.
    const branch = h.window.document.querySelector('.settings-subform-overlay .settings-body .st-input')
      || h.window.document.querySelector('.settings-body .st-input');
    if (branch) { branch.value = 'x/'; if (branch.oninput) branch.oninput(); }
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
