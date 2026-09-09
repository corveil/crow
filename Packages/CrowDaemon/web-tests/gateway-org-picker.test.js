const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource, loadSettingsSource } = require('./load-client');

// CROW-1123 behaviour test: the org-dropdown gateway editor. Runs the real app.js +
// settings.js under jsdom against mocks (same loader shape as
// integrations-corveil.test.js), driving the Manager AI-gateway picker on the
// Automation tab.
//
// Guards the three behaviours that are invisible in a string check and were the
// round-1 review's Yellow findings, plus the CROW-1212 picker-state / flicker
// regressions:
//   1. Happy path: connected → an org dropdown is offered; picking an org calls
//      corveil-select-org, POSTs { orgId } to /config/manager-gateway, and the card
//      then shows the derived gateway. The browser never sends the key secret.
//      The dropdown STAYS on the picked org (no snap-back to the placeholder).
//   2. A failed pick RESETS the <select> back to the placeholder, so re-picking the
//      SAME org fires `change` again (HTML `change` won't re-fire for an unchanged
//      value, which would otherwise strand this ticket's primary control).
//   3. A best-effort connection refresh that throws AFTER the gateway is written must
//      NOT report the pick as failed — the gateway is stored, so the card shows it
//      set and never prints "Failed:".
//   4. Lazy corveil-list-orgs load and a successful pick update the picker in place
//      — the settings modal node identity is unchanged (no innerHTML teardown).

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

// A connected config as get-config would send it: OAuth token strings + per-org key
// secrets stripped (the derivation happens server-side), non-secret metadata kept.
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
  });
}

// Returns a handle whose `hooks` the test mutates to inject failures, and which
// records the rpc methods called and the gateway POST bodies sent.
function load({ config, local }) {
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
    // corveil-list-orgs → one org, not yet provisioned.
    listOrgs: () => Promise.resolve({ orgs: [
      { org_id: 'org_acme', org_name: 'Acme Corp', role: 'admin', is_active: true, provisioned: false },
    ] }),
    selectOrg: () => Promise.resolve({ saved: true, reused: false,
      org: { org_id: 'org_acme', org_name: 'Acme Corp', key_id: 'k1', key_prefix: 'sk-citadel-Ab' } }),
    gatewayPost: () => Promise.resolve({ ok: true, body: { saved: true, gateway_set: true } }),
    // When set true, the NEXT get-config (the post-pick connection refresh) rejects
    // once — the "best-effort refresh throws after the write" case.
    failNextGetConfig: false,
  };

  let configBody = config;
  window.fetch = (url, init) => {
    const u = String(url);
    if (u.startsWith('/auth/context')) {
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ local: !!local }) });
    }
    if (u.startsWith('/config/manager-gateway')) {
      const parsed = init && init.body ? JSON.parse(init.body) : {};
      calls.gatewayPosts.push(parsed);
      return hooks.gatewayPost().then((r) => ({
        ok: r.ok !== false,
        status: r.status || 200,
        json: () => Promise.resolve(r.body || {}),
      }));
    }
    // /autostart and /version.json — settings.js tolerates both failing.
    return Promise.resolve({ ok: false, json: () => Promise.reject(new Error('n/a')) });
  };
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

  const ctx = dom.getInternalVMContext();
  const src = loadClientSource() + epilogue + loadSettingsSource();
  try {
    vm.runInContext(src, ctx, { filename: 'app+settings.js' });
  } catch (e) {
    console.log('[load warn]', e.message);
  }
  const T = ctx.__t;
  if (!T) throw new Error('epilogue did not run');
  T.setRpc((method, params) => {
    calls.rpc.push({ method, params });
    if (method === 'get-config') {
      if (hooks.failNextGetConfig) { hooks.failNextGetConfig = false; return Promise.reject(new Error('refresh boom')); }
      return Promise.resolve({ config: configBody, dev_root: '/dev' });
    }
    if (method === 'list-agents') return Promise.resolve({ agents: [] });
    if (method === 'corveil-list-orgs') return hooks.listOrgs();
    if (method === 'corveil-select-org') return hooks.selectOrg();
    return Promise.reject(new Error('not stubbed: ' + method));
  });
  return { T, window, hooks, calls, setConfig: (c) => { configBody = c; } };
}

async function drain(n = 60) { for (let i = 0; i < n; i++) await Promise.resolve(); }

function orgSelect(window) {
  return Array.from(window.document.querySelectorAll('select')).find(
    (s) => Array.from(s.options).some((o) => /organization/i.test(o.textContent))) || null;
}

// Open Settings on the Automation tab and wait for the org dropdown to populate
// (its lazy corveil-list-orgs load resolves and re-renders).
async function openAutomation(opts) {
  const h = load(opts);
  await h.T.openSettings('automation');
  for (let i = 0; i < 120; i++) {
    const sel = orgSelect(h.window);
    if (sel && Array.from(sel.options).some((o) => o.value === 'org_acme')) return h;
    await Promise.resolve();
  }
  throw new Error('org dropdown never populated');
}

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

(async () => {
  console.log('Connected + local: the Manager gateway offers an org dropdown:');
  {
    const h = await openAutomation({ config: connectedConfig(), local: true });
    check('corveil-list-orgs was called', h.calls.rpc.some((c) => c.method === 'corveil-list-orgs'));
    const sel = orgSelect(h.window);
    check('org dropdown rendered with the membership', !!sel
      && Array.from(sel.options).some((o) => o.textContent.includes('Acme Corp')));
    check('manual editor still reachable under Advanced',
      !!h.window.document.querySelector('details.st-advanced-gateway'));
  }

  console.log('\nPicking an org provisions the key and writes the derived gateway:');
  {
    const h = await openAutomation({ config: connectedConfig(), local: true });
    const sel = orgSelect(h.window);
    sel.value = 'org_acme';
    await sel.onchange();
    await drain();
    check('corveil-select-org was called for the org',
      h.calls.rpc.some((c) => c.method === 'corveil-select-org' && c.params && c.params.org_id === 'org_acme'));
    check('gateway POST carried { orgId } and no manual base URL / headers', h.calls.gatewayPosts.length === 1
      && h.calls.gatewayPosts[0].orgId === 'org_acme'
      && h.calls.gatewayPosts[0].baseURL === undefined && h.calls.gatewayPosts[0].headers === undefined);
    check('card now shows the gateway set from the connection',
      h.window.document.body.textContent.includes('Gateway set from your Corveil connection'));
    check('no key secret ever left the browser (POST body has no x-citadel value)',
      !JSON.stringify(h.calls.gatewayPosts).toLowerCase().includes('sk-citadel'));
    const selAfter = orgSelect(h.window);
    check('dropdown still shows the picked org (no snap-back to placeholder)',
      !!selAfter && selAfter.value === 'org_acme');
    check('same <select> after pick (picker updated in place, not via S.render)',
      selAfter === sel);
  }

  console.log('\nA failed pick resets the select so the same org can be retried:');
  {
    const h = await openAutomation({ config: connectedConfig(), local: true });
    h.hooks.selectOrg = () => Promise.reject(new Error('mint failed'));
    const sel = orgSelect(h.window);
    sel.value = 'org_acme';
    await sel.onchange();
    await drain();
    check('select reset to the placeholder (empty value)', sel.value === '');
    check('select re-enabled for another attempt', sel.disabled === false);
    check('failure is surfaced', h.window.document.body.textContent.includes('Failed'));
    check('no gateway was written', h.calls.gatewayPosts.length === 0);
  }

  console.log('\nA post-write refresh failure does NOT report the pick as failed:');
  {
    const h = await openAutomation({ config: connectedConfig(), local: true });
    // select-org + the gateway POST succeed; only the connection refresh throws.
    h.hooks.failNextGetConfig = true;
    const sel = orgSelect(h.window);
    sel.value = 'org_acme';
    await sel.onchange();
    await drain();
    check('the gateway was still written', h.calls.gatewayPosts.length === 1
      && h.calls.gatewayPosts[0].orgId === 'org_acme');
    check('card shows the gateway set (pick completed)',
      h.window.document.body.textContent.includes('Gateway set from your Corveil connection'));
    check('the pick was NOT reported as failed',
      !h.window.document.body.textContent.includes('Failed:'));
  }

  console.log('\nLazy org load does not rebuild the settings modal:');
  {
    let release;
    const pending = new Promise((resolve) => { release = resolve; });
    const h = load({ config: connectedConfig(), local: true });
    h.hooks.listOrgs = () => pending.then(() => ({ orgs: [
      { org_id: 'org_acme', org_name: 'Acme Corp', role: 'admin', is_active: true, provisioned: false },
    ] }));
    await h.T.openSettings('automation');
    await drain();
    const modal = h.window.document.querySelector('.settings-modal');
    const sel = orgSelect(h.window);
    check('loading placeholder shown before orgs arrive',
      !!sel && /Loading/i.test(sel.options[0] && sel.options[0].textContent));
    release();
    await drain();
    check('same settings modal after orgs arrive (no full-modal flicker)',
      h.window.document.querySelector('.settings-modal') === modal);
    check('same <select> after orgs arrive', orgSelect(h.window) === sel);
    check('membership now in the dropdown',
      !!sel && Array.from(sel.options).some((o) => o.value === 'org_acme'));
  }

  console.log('\nAdvanced manual clear drops the cached org selection:');
  {
    const h = await openAutomation({ config: connectedConfig(), local: true });
    const sel = orgSelect(h.window);
    sel.value = 'org_acme';
    await sel.onchange();
    await drain();
    check('picked org is selected before clear', orgSelect(h.window).value === 'org_acme');
    // In-place pick does not rebuild the Advanced editor, so it still offers
    // "Set gateway" (no Clear). Empty URL+headers is apply(null) — a clear.
    const details = h.window.document.querySelector('details.st-advanced-gateway');
    const save = Array.from(details.querySelectorAll('button'))
      .find((b) => /^(Set|Update) gateway$/.test(b.textContent));
    check('Advanced save is still offered after a pick', !!save);
    await save.onclick();
    await drain();
    const selAfter = orgSelect(h.window);
    check('dropdown snaps back to the placeholder after manual clear',
      !!selAfter && selAfter.value === '');
    check('status no longer claims a Corveil-derived gateway',
      !h.window.document.body.textContent.includes('Gateway set from your Corveil connection'));
  }

  console.log('\nAdvanced manual set also drops the cached org selection:');
  {
    const h = await openAutomation({ config: connectedConfig(), local: true });
    const sel = orgSelect(h.window);
    sel.value = 'org_acme';
    await sel.onchange();
    await drain();
    const details = h.window.document.querySelector('details.st-advanced-gateway');
    details.querySelector('input.st-input').value = 'https://gateway.example.com';
    details.querySelector('textarea').value = 'X-Api-Key: sk-test';
    const save = Array.from(details.querySelectorAll('button'))
      .find((b) => /^(Set|Update) gateway$/.test(b.textContent));
    await save.onclick();
    await drain();
    const selAfter = orgSelect(h.window);
    check('dropdown is placeholder after a manual gateway write',
      !!selAfter && selAfter.value === '');
    check('status shows a manually-entered gateway',
      h.window.document.body.textContent.includes('A manually-entered gateway is set'));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
