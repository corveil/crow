const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { WEB, loadClientSource } = require('./load-client');

// CROW-1030 behaviour test: the build SHA in Settings → About is a link to that
// commit on corveil/crow, and an unlinkable stamp stays inert text.
//
// Two layers, because the bug this guards has two halves:
//   1. `crowCommitURL` decides linked-vs-inert. Everything the ticket calls out
//      as a 404 risk (`dev`, missing, non-hex) has to return null there.
//   2. renderAbout has to actually *use* it — a correct helper that the About
//      tab never calls looks identical to the bug from the user's side. So the
//      real settings.js modal is opened on the About tab and the rendered DOM
//      is inspected, rather than asserting on the helper alone.
//
// Loader shape follows router.test.js / version-banner.test.js: run the real
// app.js + settings.js under jsdom against mocks.
const SETTINGS_JS = WEB + 'settings.js';

const epilogue = `
;globalThis.__t = {
  commitURL: (s) => crowCommitURL(s),
  setRpc(fn) { rpc = fn; },
  openSettings: (tab) => window.openSettings(tab),
};
`;

// Only the containers app.js and settings.js touch on this path.
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

// `version` is what GET /version.json returns; null makes the fetch fail.
function load(version) {
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
    if (String(url).startsWith('/version.json')) {
      return version
        ? Promise.resolve({ ok: true, json: () => Promise.resolve(version) })
        : Promise.resolve({ ok: false, json: () => Promise.reject(new Error('no body')) });
    }
    // /auth/context and /autostart — settings.js tolerates both failing.
    return Promise.resolve({ ok: false, json: () => Promise.reject(new Error('n/a')) });
  };
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

  const ctx = dom.getInternalVMContext();
  const src = loadClientSource() + epilogue + fs.readFileSync(SETTINGS_JS, 'utf8');
  try {
    vm.runInContext(src, ctx, { filename: 'app+settings.js' });
  } catch (e) {
    console.log('[load warn]', e.message);
  }
  const T = ctx.__t;
  if (!T) throw new Error('epilogue did not run');
  // get-config is the only RPC the About path needs to succeed; list-agents and
  // version-update-get are best-effort and settings.js swallows their failures.
  T.setRpc((method) => (method === 'get-config'
    ? Promise.resolve({ config: '{}', dev_root: '/dev' })
    : Promise.reject(new Error('not stubbed: ' + method))));
  return { T, window };
}

// Opens Settings on About and returns the .st-about-ver line once /version.json
// has been applied. The mocks resolve synchronously, so this only has to drain
// microtasks — but it polls rather than counting `await`s so adding a step to
// openSettings' promise chain can't silently turn this into a no-op assertion
// against the "Loading version…" placeholder.
async function aboutLine(version) {
  const { T, window } = load(version);
  await T.openSettings('about');
  for (let i = 0; i < 50; i++) {
    const line = window.document.querySelector('.st-about-ver');
    if (line && line.textContent !== 'Loading version…') return line;
    await Promise.resolve();
  }
  throw new Error('version line never resolved past the placeholder');
}

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

(async () => {
  console.log('crowCommitURL links a real sha:');
  {
    const { T } = load(null);
    check('short sha',
      T.commitURL('2a24aeb3') === 'https://github.com/corveil/crow/commit/2a24aeb3');
    const full = 'abc1234567890abcdef1234567890abcdef12345';
    check('full 40-char sha',
      T.commitURL(full) === 'https://github.com/corveil/crow/commit/' + full);
    check('uppercase normalizes to lowercase',
      T.commitURL('2A24AEB3') === 'https://github.com/corveil/crow/commit/2a24aeb3');
    check('surrounding whitespace trimmed',
      T.commitURL('  2a24aeb3\n') === 'https://github.com/corveil/crow/commit/2a24aeb3');
  }

  console.log('\ncrowCommitURL refuses anything that would 404:');
  {
    const { T } = load(null);
    const bad = [
      ['dev', 'dev'],
      ['', 'empty string'],
      ['   ', 'whitespace only'],
      [null, 'null'],
      [undefined, 'undefined'],
      ['2a24ae', '6 chars'],
      ['abc1234567890abcdef1234567890abcdef123456', '41 chars'],
      ['zzzzzzz', 'non-hex'],
      ['2a24aeb3/../../evil', 'path traversal'],
      ['2a24aeb3 abc', 'interior space'],
    ];
    for (const [sha, label] of bad) check(label + ' → null', T.commitURL(sha) === null);
  }

  console.log('\nAbout renders the sha as a link:');
  {
    const line = await aboutLine({
      version: '0.1.0',
      gitSha: '2a24aeb3',
      gitShaFull: '2a24aeb3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      buildDate: '2026-08-14',
    });
    const a = line && line.querySelector('a.st-about-sha');
    check('sha is an anchor', !!a);
    check('anchor shows the SHORT sha', a && a.textContent === '2a24aeb3');
    check('href uses the FULL sha',
      a && a.getAttribute('href')
        === 'https://github.com/corveil/crow/commit/2a24aeb3aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    check('opens in a new tab', a && a.getAttribute('target') === '_blank');
    check('rel=noopener', a && a.getAttribute('rel') === 'noopener');
    check('version and date survive the rewrite',
      line && line.textContent === 'Version 0.1.0 · 2a24aeb3 · 2026-08-14');
  }

  console.log('\nAbout falls back to the short sha when gitShaFull is absent:');
  {
    const line = await aboutLine({ version: '0.1.0', gitSha: '2a24aeb3', buildDate: '2026-08-14' });
    const a = line && line.querySelector('a.st-about-sha');
    check('href built from gitSha',
      a && a.getAttribute('href') === 'https://github.com/corveil/crow/commit/2a24aeb3');
  }

  console.log('\nAbout leaves an unlinkable sha as plain text:');
  {
    const line = await aboutLine({ version: '0.1.0', gitSha: 'dev', buildDate: '2026-08-14' });
    check('no anchor for dev', line && !line.querySelector('a'));
    check('dev still shown', line && line.textContent === 'Version 0.1.0 · dev · 2026-08-14');
  }

  console.log('\nA non-hex gitShaFull does not sneak into the href:');
  {
    // gitShaFull is what the href is built from, so a malformed full stamp must
    // fall to inert text even though the displayed short one looks fine.
    const line = await aboutLine({
      version: '0.1.0', gitSha: '2a24aeb3', gitShaFull: 'not-a-sha', buildDate: '2026-08-14',
    });
    check('no anchor', line && !line.querySelector('a'));
    check('short sha still shown', line && line.textContent.includes('2a24aeb3'));
  }

  console.log('\nAbout without a buildDate or sha still renders:');
  {
    const line = await aboutLine({ version: '0.1.0' });
    check('version only', line && line.textContent === 'Version 0.1.0');
  }

  console.log('\nA failed /version.json still reports something:');
  {
    const line = await aboutLine(null);
    check('unavailable message', line && line.textContent === 'Version unavailable');
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
