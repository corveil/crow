const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const APP_CSS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.css';
const VERSION_BANNER_DISMISS_KEY = 'crow.updateBannerDismissedSha';

const epilogue = `
;globalThis.__t = {
  render(status) { renderVersionUpdateBanner(status); },
  refresh() { return refreshVersionUpdateBanner(); },
  setRpc(fn) { rpc = fn; },
  visible() {
    const b = document.getElementById('update-banner');
    return b && window.getComputedStyle(b).display !== 'none';
  },
  dismiss() { document.querySelector('.update-banner-dismiss').click(); },
  compareLink() { return document.querySelector('.update-banner-compare-link'); },
};
`;

function makeStorage(initial = {}) {
  const data = { ...initial };
  let setItemThrows = false;
  let getItemThrows = false;
  return {
    storage: {
      getItem(k) {
        if (getItemThrows) throw new DOMException('SecurityError');
        return Object.prototype.hasOwnProperty.call(data, k) ? data[k] : null;
      },
      setItem(k, v) {
        if (setItemThrows) throw new DOMException('QuotaExceededError');
        data[k] = String(v);
      },
      removeItem(k) { delete data[k]; },
      clear() { for (const k of Object.keys(data)) delete data[k]; },
      get length() { return Object.keys(data).length; },
      key() { return null; },
    },
    setSetItemThrows(v) { setItemThrows = v; },
    setGetItemThrows(v) { getItemThrows = v; },
    get(k) { return data[k]; },
  };
}

function load(storageWrap) {
  const dom = new JSDOM(
    `<!doctype html><html><head>
       <style>${fs.readFileSync(APP_CSS, 'utf8')}</style>
     </head><body>
       <div id="update-banner" class="update-banner" hidden role="status">
         <span class="update-banner-text"></span>
         <a class="update-banner-compare-link" hidden href="#" target="_blank" rel="noopener noreferrer">See changes</a>
         <button type="button" class="update-banner-dismiss" aria-label="Dismiss update notice">×</button>
       </div>
     </body></html>`,
    { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
  );
  const { window } = dom;
  Object.defineProperty(window, 'localStorage', {
    value: storageWrap.storage, configurable: true, writable: true,
  });
  window.WebSocket = function () {
    return { send() {}, close() {},
      set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  window.setInterval = () => 0;
  window.setTimeout = () => 0;
  window.requestAnimationFrame = () => 0;
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

  const ctx = dom.getInternalVMContext();
  try {
    vm.runInContext(fs.readFileSync(APP_JS, 'utf8') + epilogue, ctx, { filename: 'app.js' });
  } catch (e) {
    console.log('[load warn]', e.message);
  }
  const T = ctx.__t;
  if (!T) throw new Error('epilogue did not run');
  return { T, storage: storageWrap, window };
}

let pass = 0;
let fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

(async () => {
  console.log('[hidden] hides via computed style on first paint:');
  {
    const { T } = load(makeStorage());
    check('banner starts hidden', !T.visible());
  }

  console.log('\nbehind → shown, up_to_date → hidden:');
  {
    const { T } = load(makeStorage());
    T.render({ state: 'behind', behind_by: 3, remote_sha: 'aaa' });
    check('shown when behind', T.visible());
    T.render({ state: 'up_to_date' });
    check('hidden again', !T.visible());
  }

  console.log('\ndismiss survives a re-render for the same sha:');
  {
    const { T } = load(makeStorage());
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'aaa' });
    check('shown for aaa', T.visible());
    T.dismiss();
    check('dismiss hid it', !T.visible());
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'aaa' });
    check('stays hidden on re-render', !T.visible());
  }

  console.log('\na new sha re-shows after dismiss:');
  {
    const { T } = load(makeStorage());
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'aaa' });
    T.dismiss();
    T.render({ state: 'behind', behind_by: 2, remote_sha: 'bbb' });
    check('bbb shown after aaa dismissed', T.visible());
  }

  console.log('\nsetItem throws but in-memory dismiss sticks across poll:');
  {
    const storage = makeStorage({ [VERSION_BANNER_DISMISS_KEY]: 'aaa' });
    const { T } = load(storage);
    check('stale aaa persisted', storage.get(VERSION_BANNER_DISMISS_KEY) === 'aaa');
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'bbb' });
    check('banner shown for bbb', T.visible());
    storage.setSetItemThrows(true);
    T.dismiss();
    check('dismiss hid it', !T.visible());
    check('storage still holds stale aaa', storage.get(VERSION_BANNER_DISMISS_KEY) === 'aaa');
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'bbb' });
    check('stays hidden on re-render', !T.visible());
  }

  console.log('\nno-sha dismiss is session-only until a sha arrives:');
  {
    const { T } = load(makeStorage());
    T.render({ state: 'behind', behind_by: 2 });
    check('shown without remote_sha', T.visible());
    T.dismiss();
    check('dismiss hid it', !T.visible());
    T.render({ state: 'behind', behind_by: 2 });
    check('stays hidden on re-render', !T.visible());
    T.render({ state: 'behind', behind_by: 2, remote_sha: 'aaa' });
    check('reshown when remote_sha arrives', T.visible());
  }

  console.log('\ngetItem throws but banner still renders when behind:');
  {
    const storage = makeStorage();
    const { T } = load(storage);
    storage.setGetItemThrows(true);
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'aaa' });
    check('shown when getItem throws', T.visible());
  }

  console.log('\ngetItem throws but in-memory dismiss still sticks:');
  {
    const storage = makeStorage();
    const { T } = load(storage);
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'aaa' });
    T.dismiss();
    storage.setGetItemThrows(true);
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'aaa' });
    check('stays hidden on re-render', !T.visible());
  }

  console.log('\nrefreshVersionUpdateBanner hides banner on RPC failure:');
  {
    const { T } = load(makeStorage());
    T.render({ state: 'behind', behind_by: 1, remote_sha: 'aaa' });
    check('shown before RPC failure', T.visible());
    T.setRpc(() => Promise.reject(new Error('rpc failed')));
    await T.refresh();
    check('hidden after RPC failure', !T.visible());
  }

  console.log('\ncompare link shown when compare_url present:');
  {
    const { T } = load(makeStorage());
    const url = 'https://github.com/corveil/crow/compare/abc...def';
    T.render({ state: 'behind', behind_by: 2, remote_sha: 'def5678', compare_url: url });
    const link = T.compareLink();
    check('compare link visible', link && !link.hidden);
    check('compare link href', link && link.getAttribute('href') === url);
    T.render({ state: 'behind', behind_by: 2, remote_sha: 'def5678' });
    check('compare link hidden without url', link && link.hidden);
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
