const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource, loadSettingsSource } = require('./load-client');

// CROW-1122 behaviour test: Settings → Integrations Corveil card. Runs the real
// app.js + settings.js under jsdom against mocks, the same loader shape as
// about-sha-link.test.js.
//
// Guards three things that are invisible in a string check:
//   1. Swift-epoch date decoding. get-config encodes AppConfig with a DEFAULT
//      Swift JSONEncoder (.deferredToDate), so Date fields arrive as a NUMBER of
//      seconds since the 2001-01-01 reference epoch — not unix ms. Handing that to
//      `new Date(n)` renders the date in January 1970. The connected card is
//      rendered against those numbers and the text is asserted to show the real
//      year, never 1970.
//   2. The local/remote read-only gate across all four states.
//   3. The connect-poll composition (round-2 review): a re-render (Refresh / tab
//      return) while a sign-in poll is in flight must NOT present a second, enabled
//      Connect; the poll timeout must re-enable Connect; a completed sign-in must
//      flip to the connected view. Driven with a controllable setTimeout so the
//      24 × 2.5s poll runs deterministically.

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

// `local` drives GET /auth/context (isLocal); `config` is the initial get-config
// body. Returns handles a test can drive: a controllable setTimeout queue
// (`flushTimers`), a `setConfig` to simulate the connection completing out of band.
function load({ config, local }) {
  const dom = new JSDOM(MARKUP, {
    runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/',
  });
  const { window } = dom;
  window.WebSocket = function () {
    return { send() {}, close() {},
      set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  // Controllable timers: settings.js's connect poll schedules via setTimeout, so a
  // test can flush the queue to run the 24 ticks deterministically instead of
  // waiting real 2.5s intervals.
  const timers = [];
  window.setTimeout = (fn) => { timers.push(fn); return timers.length; };
  window.setInterval = () => 0;
  window.requestAnimationFrame = () => 0;
  window.matchMedia = () => ({ matches: false, addListener() {}, addEventListener() {} });

  let configBody = config;
  window.fetch = (url) => {
    const u = String(url);
    if (u.startsWith('/auth/context')) {
      return Promise.resolve({ ok: true, json: () => Promise.resolve({ local: !!local }) });
    }
    if (u.startsWith('/integrations/corveil/connect')) {
      return Promise.resolve({
        ok: true,
        json: () => Promise.resolve({ authorizeURL: 'https://app.corveil.example/oauth/authorize?x=1' }),
      });
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
  T.setRpc((method) => (method === 'get-config'
    ? Promise.resolve({ config: configBody, dev_root: '/dev' })
    : method === 'list-agents'
      ? Promise.resolve({ agents: [] })
      : Promise.reject(new Error('not stubbed: ' + method))));

  async function flushTimers(max = 200) {
    let n = 0;
    while (timers.length && n < max) {
      const fn = timers.shift();
      try { fn(); } catch (_) { /* poll tick errors are non-fatal */ }
      for (let i = 0; i < 30; i++) await Promise.resolve(); // drain the tick's awaits
      n++;
    }
  }
  return { T, window, timers, flushTimers, setConfig: (c) => { configBody = c; } };
}

// Open Settings on Integrations and return the load handle once the Corveil card
// has painted. Discards any timers queued during boot/open so flushTimers later
// drives only the connect poll.
async function openIntegrations({ config, local }) {
  const h = load({ config, local });
  await h.T.openSettings('integrations');
  for (let i = 0; i < 50; i++) {
    if (h.window.document.querySelector('.st-corveil-status')) { h.timers.length = 0; return h; }
    await Promise.resolve();
  }
  throw new Error('Corveil card never rendered');
}

async function integrationsBody(opts) {
  const h = await openIntegrations(opts);
  return h.window.document.querySelector('.settings-body');
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
function connectBtn(window) { return buttonByText(window.document, 'Connect to Corveil'); }
function refreshBtn(window) { return buttonByText(window.document, 'Refresh status'); }
function urlInput(window) {
  return Array.from(window.document.querySelectorAll('input')).find((i) => /corveil\.example/.test(i.placeholder));
}

(async () => {
  console.log('Connected card renders Swift-epoch dates in the real year, not 1970:');
  {
    const body = await integrationsBody({ config: connectedConfig(), local: true });
    const text = body.textContent;
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

  // Round-2 review: a re-render (Refresh / tab return) while a sign-in poll is in
  // flight must NOT drop a fresh enabled Connect over it. setTimeout is queued and
  // not flushed here, so the poll stays "in flight" across the Refresh re-render.
  console.log('\nConnect stays disabled across a re-render while polling:');
  {
    const h = await openIntegrations({ config: '{}', local: true });
    urlInput(h.window).value = 'https://app.corveil.example';
    await connectBtn(h.window).onclick(); // POST resolves, poll starts, card re-renders
    check('Connect disabled while poll in flight', connectBtn(h.window).disabled === true);
    check('waiting copy shown', h.window.document.body.textContent.includes('updates automatically'));
    check('fallback sign-in link shown', !!h.window.document.querySelector('a[target="_blank"]'));
    // Refresh re-renders the card mid-poll — Connect must stay disabled (the hole).
    await refreshBtn(h.window).onclick();
    check('Connect STILL disabled after Refresh re-render', connectBtn(h.window).disabled === true);
  }

  console.log('\nPoll timeout re-enables Connect with recovery copy:');
  {
    const h = await openIntegrations({ config: '{}', local: true });
    urlInput(h.window).value = 'https://app.corveil.example';
    await connectBtn(h.window).onclick();
    check('disabled during poll', connectBtn(h.window).disabled === true);
    await h.flushTimers(); // drive all 24 ticks; config stays '{}' → never connects
    check('Connect re-enabled after timeout', connectBtn(h.window).disabled === false);
    check('recovery copy shown', h.window.document.body.textContent.includes('Still not connected'));
  }

  console.log('\nPoll detects a completed sign-in and flips to the connected view:');
  {
    const h = await openIntegrations({ config: '{}', local: true });
    urlInput(h.window).value = 'https://app.corveil.example';
    await connectBtn(h.window).onclick();
    h.setConfig(connectedConfig()); // the sign-in completed out of band
    await h.flushTimers();          // next tick observes the stored connection
    const text = h.window.document.body.textContent;
    check('connected identity now shown', text.includes('Connected as Dustin Hilgaertner'));
    check('no Connect button in the connected view', !buttonByText(h.window.document, 'Connect to Corveil'));
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
