'use strict';
// CROW-1333 behaviour test: skins in theme.js.
//
// What the ticket's acceptance hangs on, client side:
//   * a reload paints the chosen skin BEFORE first paint — from the cached CSS,
//     synchronously, with data-skin stamped to match — and never a stale cache
//     belonging to another skin;
//   * switching skins fetches /skins/<id>.css, caches it, repaints and fires
//     `crow-theme` (which is what recolors live terminals);
//   * a dark-only skin pins data-theme="dark" whatever the scheme preference;
//   * a skin crowd no longer has falls back to Corveil instead of sticking;
//   * a failed fetch leaves crow.skin on the skin that is actually painted.
//
// theme.js runs on its own here, as it does in <head> before anything else.
const assert = require('assert');
const fs = require('fs');
const { JSDOM } = require('jsdom');
const { WEB } = require('./load-client');

const THEME_JS = fs.readFileSync(WEB + 'theme.js', 'utf8');

const CATALOG = {
  default: 'corveil',
  skins: [
    { id: 'corveil', name: 'Corveil', light: true },
    { id: 'corveil-classic', name: 'Corveil Classic', light: false },
    { id: 'graphite', name: 'Graphite', light: true },
    { id: 'broken', name: 'Broken', light: true }, // listed, but its CSS 404s
  ],
};
const CSS = {
  'corveil-classic': ':root[data-skin="corveil-classic"]:not([data-theme="light"]) { --accent: #DDC482; }',
  graphite: ':root[data-skin="graphite"]:not([data-theme="light"]) { --accent: #8AA4C8; }',
};

// `storage` seeds localStorage before theme.js runs; `systemDark` is the OS.
function boot({ storage = {}, systemDark = false } = {}) {
  const dom = new JSDOM('<!doctype html><html><head></head><body></body></html>', {
    runScripts: 'outside-only', url: 'http://localhost/',
  });
  const { window } = dom;
  for (const [k, v] of Object.entries(storage)) window.localStorage.setItem(k, v);
  window.matchMedia = () => ({ matches: systemDark, addEventListener() {} });
  const fetched = [];
  window.fetch = (url) => {
    fetched.push(url);
    if (url === '/skins.json') return Promise.resolve({ ok: true, json: () => Promise.resolve(CATALOG) });
    const m = /^\/skins\/([a-z0-9-]+)\.css$/.exec(url);
    if (m && CSS[m[1]]) return Promise.resolve({ ok: true, text: () => Promise.resolve(CSS[m[1]]) });
    return Promise.resolve({ ok: false, status: 404 });
  };
  const events = [];
  window.addEventListener('crow-theme', (e) => events.push(e.detail));
  window.eval(THEME_JS);
  return { window, fetched, events, root: window.document.documentElement };
}

const skinStyle = (window) => window.document.getElementById('crow-skin');
const cacheOf = (window) => JSON.parse(window.localStorage.getItem('crow.skin.cache') || 'null');

async function main() {
  // 1. Default: Corveil is theme.css itself — no data-skin, no injected CSS.
  {
    const { window, root } = boot({ systemDark: false });
    assert.strictEqual(root.getAttribute('data-skin'), null);
    assert.strictEqual(skinStyle(window), null);
    assert.strictEqual(root.getAttribute('data-theme'), 'light', 'system light follows the OS');
  }

  // 2. A cached skin paints synchronously at boot (no flash), before any fetch.
  {
    const cache = { id: 'graphite', name: 'Graphite', light: true, css: CSS.graphite };
    const { window, root, fetched } = boot({
      storage: { 'crow.skin': 'graphite', 'crow.skin.cache': JSON.stringify(cache) },
    });
    assert.strictEqual(root.getAttribute('data-skin'), 'graphite');
    assert.strictEqual(skinStyle(window).textContent, CSS.graphite);
    assert.deepStrictEqual(fetched, [], 'first paint must not wait on the network');
  }

  // 3. A cache for a different skin is never painted under the chosen id.
  {
    const cache = { id: 'graphite', name: 'Graphite', light: true, css: CSS.graphite };
    const { window, root } = boot({
      storage: { 'crow.skin': 'corveil-classic', 'crow.skin.cache': JSON.stringify(cache) },
    });
    assert.strictEqual(root.getAttribute('data-skin'), null);
    assert.strictEqual(skinStyle(window), null);
  }

  // 4. A cached dark-only skin pins dark even when the user chose Light.
  {
    const cache = { id: 'corveil-classic', name: 'Corveil Classic', light: false, css: CSS['corveil-classic'] };
    const { window, root } = boot({
      storage: { 'crow.color-scheme': 'light', 'crow.skin': 'corveil-classic', 'crow.skin.cache': JSON.stringify(cache) },
    });
    assert.strictEqual(root.getAttribute('data-theme'), 'dark');
    assert.strictEqual(window.CrowTheme.lightAvailable(), false);
    assert.strictEqual(window.CrowTheme.preference(), 'light', 'the stored preference is kept for later skins');
  }

  // 5. setSkin fetches, caches, repaints and announces — live, no reload.
  {
    const { window, root, fetched, events } = boot({ storage: { 'crow.color-scheme': 'light' } });
    await new Promise((r) => setTimeout(r, 0)); // let jsdom's own DOMContentLoaded pass
    events.length = 0;
    await window.CrowTheme.setSkin('corveil-classic');
    assert.deepStrictEqual(fetched, ['/skins.json', '/skins/corveil-classic.css']);
    assert.strictEqual(root.getAttribute('data-skin'), 'corveil-classic');
    assert.strictEqual(skinStyle(window).textContent, CSS['corveil-classic']);
    assert.strictEqual(root.getAttribute('data-theme'), 'dark', 'Classic is dark only');
    assert.strictEqual(window.localStorage.getItem('crow.skin'), 'corveil-classic');
    assert.deepStrictEqual(cacheOf(window), {
      id: 'corveil-classic', name: 'Corveil Classic', light: false, css: CSS['corveil-classic'],
    });
    const last = events[events.length - 1];
    assert.strictEqual(last.skin, 'corveil-classic');
    assert.strictEqual(last.lightAvailable, false);

    // …and back to a light-capable skin restores the Light choice.
    await window.CrowTheme.setSkin('graphite');
    assert.strictEqual(root.getAttribute('data-theme'), 'light');

    // Back to Corveil removes the injected CSS and the cache.
    await window.CrowTheme.setSkin('corveil');
    assert.strictEqual(root.getAttribute('data-skin'), null);
    assert.strictEqual(skinStyle(window), null);
    assert.strictEqual(window.localStorage.getItem('crow.skin'), null);
    assert.strictEqual(cacheOf(window), null);
  }

  // 6. A skin crowd no longer serves falls back to Corveil on the post-load refresh.
  {
    const cache = { id: 'retired', name: 'Retired', light: true, css: ':root[data-skin="retired"] {}' };
    const { window, root } = boot({
      storage: { 'crow.skin': 'retired', 'crow.skin.cache': JSON.stringify(cache) },
    });
    assert.strictEqual(root.getAttribute('data-skin'), 'retired', 'cache paints first');
    // jsdom fires DOMContentLoaded after the parse; theme.js refreshes from crowd there.
    for (let i = 0; i < 5; i++) await new Promise((r) => setTimeout(r, 0));
    assert.strictEqual(root.getAttribute('data-skin'), null);
    assert.strictEqual(window.CrowTheme.skin(), 'corveil');
  }

  // 8. A failed CSS fetch does not record the skin: crow.skin stays on what is painted.
  {
    const { window, root } = boot();
    await new Promise((r) => setTimeout(r, 0));
    await window.CrowTheme.setSkin('graphite');
    await assert.rejects(window.CrowTheme.setSkin('broken'));
    assert.strictEqual(window.CrowTheme.skin(), 'graphite');
    assert.strictEqual(window.localStorage.getItem('crow.skin'), 'graphite');
    assert.strictEqual(root.getAttribute('data-skin'), 'graphite');
    assert.strictEqual(cacheOf(window).id, 'graphite');
  }

  // 9. A slower, older switch never overwrites a newer one.
  {
    const { window, root } = boot();
    await new Promise((r) => setTimeout(r, 0));
    const first = window.CrowTheme.setSkin('corveil-classic');
    const second = window.CrowTheme.setSkin('graphite');
    await Promise.all([first, second]);
    assert.strictEqual(window.CrowTheme.skin(), 'graphite');
    assert.strictEqual(root.getAttribute('data-skin'), 'graphite');
  }

  // 7. A malformed stored id is treated as Corveil, not spliced into a selector.
  {
    const { root, window } = boot({ storage: { 'crow.skin': 'x"] body { display:none } [x="' } });
    assert.strictEqual(window.CrowTheme.skin(), 'corveil');
    assert.strictEqual(root.getAttribute('data-skin'), null);
  }

  console.log('skins: ok');
}

main().catch((err) => { console.error(err); process.exit(1); });
