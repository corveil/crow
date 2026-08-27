const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-1122 behaviour test: Settings → Integrations Corveil card. Runs the real
// app.js + settings.js under jsdom against mocks, the same loader shape as
// about-sha-link.test.js.
//
// The bug this guards is subtle and invisible in a string check: get-config
// encodes AppConfig with a DEFAULT Swift JSONEncoder, whose .deferredToDate
// strategy emits a Date as a NUMBER of seconds since the 2001-01-01 reference
// epoch — not unix ms, and not ISO. Handing that to `new Date(n)` (which reads a
// number as unix ms) renders the date in January 1970. So the connected card is
// rendered against a get-config that carries the Swift-epoch numbers, and the
// rendered date text is asserted to show the real year and never 1970.
//
// It also pins the read-only gate: Connect/Disconnect are actionable only when the
// connection reports `local` (a local-direct browser), read-only otherwise.
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

// The Swift reference epoch (2001-01-01T00:00:00Z) in unix ms — how a numeric
// Swift Date must be interpreted. Kept independent of settings.js so the test
// fails if the production formula drifts.
const SWIFT_EPOCH_MS = Date.UTC(2001, 0, 1);
// Encode a JS Date the way Swift's .deferredToDate encoder would: seconds since
// the 2001 reference epoch (a number).
function swiftSeconds(iso) {
  return (new Date(iso).getTime() - SWIFT_EPOCH_MS) / 1000;
}

// A config as get-config would send it: OAuth token strings stripped, Date fields
// as Swift-epoch NUMBERS.
function connectedConfig() {
  return JSON.stringify({
    corveilConnection: {
      baseURL: 'https://app.corveil.example',
      clientID: 'crow-client-abc123',
      connectedUser: { id: 'u_1', email: 'dustin@example.com', name: 'Dustin Hilgaertner' },
      orgKeys: [
        {
          orgID: 'org_acme', orgName: 'Acme Corp', keyID: 'k1',
          keyPrefix: 'sk-citadel-AbCd', createdAt: swiftSeconds('2026-08-01T12:00:00Z'),
        },
      ],
      oauth: {
        accessToken: '', refreshToken: '', registrationAccessToken: '',
        accessTokenExpiresAt: swiftSeconds('2026-09-01T12:00:00Z'),
      },
    },
  });
}

// `local` drives GET /auth/context (isLocal); `config` is the get-config body.
function load({ config, local }) {
  const dom = new JSDOM(MARKUP, {
    runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/',
  });
  const { window } = dom;
  window.WebSocket = function () {
    return { send() {}, close() {},
      set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  window.setInterval = () => 0;
  window.setTimeout = () => 0;
  window.requestAnimationFrame = () => 0;
  window.matchMedia = () => ({ matches: false, addListener() {}, addEventListener() {} });
  window.fetch = (url) => {
    const u = String(url);
    if (u.startsWith('/auth/context')) {
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ local: !!local }) });
    }
    // /autostart and /version.json — settings.js tolerates both failing.
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
  T.setRpc((method) => (method === 'get-config'
    ? Promise.resolve({ config, dev_root: '/dev' })
    : method === 'list-agents'
      ? Promise.resolve({ agents: [] })
      : Promise.reject(new Error('not stubbed: ' + method))));
  return { T, window };
}

// Open Settings on Integrations and return the rendered .settings-body once the
// Corveil card has painted (openSettings' promise chain has drained).
async function integrationsBody({ config, local }) {
  const { T, window } = load({ config, local });
  await T.openSettings('integrations');
  for (let i = 0; i < 50; i++) {
    const status = window.document.querySelector('.st-corveil-status');
    if (status) return window.document.querySelector('.settings-body');
    await Promise.resolve();
  }
  throw new Error('Corveil card never rendered');
}

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

function buttonByText(root, text) {
  return Array.from(root.querySelectorAll('button')).find((b) => b.textContent.includes(text)) || null;
}

(async () => {
  console.log('Connected card renders Swift-epoch dates in the real year, not 1970:');
  {
    const body = await integrationsBody({ config: connectedConfig(), local: true });
    const text = body.textContent;
    // The year the production code should show, computed the correct way here.
    const expiryYear = String(new Date('2026-09-01T12:00:00Z').getFullYear());
    const provisionedYear = String(new Date('2026-08-01T12:00:00Z').getFullYear());
    check('identity line shows the connected user',
      text.includes('Connected as Dustin Hilgaertner (dustin@example.com)'));
    check('access-token expiry shows the real year', text.includes('access token expires')
      && text.includes(expiryYear));
    check('org row shows the real provisioned year',
      text.includes('provisioned') && text.includes(provisionedYear));
    check('no date rendered as January 1970 (the misread-as-unix-ms bug)',
      !text.includes('1970'));
    // Prove the number really WAS the Swift-epoch shape a naive new Date(n) breaks
    // on — so this test would fail if the fix were reverted.
    const rawExpiry = JSON.parse(connectedConfig()).corveilConnection.oauth.accessTokenExpiresAt;
    check('the fixture date is a bare number the buggy path misreads as 1970',
      typeof rawExpiry === 'number' && new Date(rawExpiry).getUTCFullYear() === 1970);
  }

  console.log('\nConnected + local: Disconnect is actionable, no Connect:');
  {
    const body = await integrationsBody({ config: connectedConfig(), local: true });
    check('Disconnect button present', !!buttonByText(body, 'Disconnect'));
    check('no Connect button', !buttonByText(body, 'Connect to Corveil'));
    check('base URL is rendered in a field', Array.from(body.querySelectorAll('input'))
      .some((i) => i.value === 'https://app.corveil.example'));
  }

  console.log('\nConnected + remote: read-only, no Disconnect button:');
  {
    const body = await integrationsBody({ config: connectedConfig(), local: false });
    check('identity still shown', body.textContent.includes('Connected as Dustin Hilgaertner'));
    check('no Disconnect button', !buttonByText(body, 'Disconnect'));
    check('read-only note present', body.textContent.includes('only from a local browser'));
  }

  console.log('\nDisconnected + local: Connect + base-URL input offered:');
  {
    const body = await integrationsBody({ config: '{}', local: true });
    check('status says not connected', body.textContent.includes('Not connected'));
    check('Connect button present', !!buttonByText(body, 'Connect to Corveil'));
    check('base URL input present',
      !!Array.from(body.querySelectorAll('input')).find((i) => /corveil\.example/.test(i.placeholder)));
  }

  console.log('\nDisconnected + remote: read-only, no Connect button:');
  {
    const body = await integrationsBody({ config: '{}', local: false });
    check('no Connect button', !buttonByText(body, 'Connect to Corveil'));
    check('read-only note present', body.textContent.includes('from a local browser'));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
