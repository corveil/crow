'use strict';
// Crow color scheme (CROW-1316) and skin (CROW-1333). Blocking script in
// <head>, before theme.css, so the first paint already has data-theme and the
// chosen skin. Both choices are local to this browser — nothing here
// round-trips through daemon config. Settings → General writes them.
//
//   crow.color-scheme  system | light | dark
//   crow.skin          a skin id from /skins.json; absent means the daemon's
//                      default (CROW-1334), which is Corveil unless
//                      `crow skin default set` named another
//   crow.skin.default  the last default /skins.json reported, so a browser that
//                      has not chosen paints the default before the fetch
//   crow.skin.cache    {id, name, light, css} — the last CSS crowd generated
//                      for that skin. Applied synchronously here so a reload
//                      never flashes Corveil first, then refreshed from the
//                      daemon after load in case the skin file changed.
//
// Corveil is theme.css itself and has no generated CSS. Any other skin's CSS
// is scoped to :root[data-skin="<id>"], so the attribute and the <style> must
// agree; a stale cache for another id is ignored rather than painted.
//
// Live reload (CROW-1334). /skins.json carries a `revision` that changes when a
// skin is added, edited or removed, or the default moves. This page polls it
// while visible; on a change it refetches the active skin's CSS, and a stored
// choice crowd no longer offers is dropped so the browser follows the default.

(function () {
  var KEY = 'crow.color-scheme';
  var SKIN_KEY = 'crow.skin';
  var SKIN_CACHE_KEY = 'crow.skin.cache';
  var SKIN_DEFAULT_KEY = 'crow.skin.default';
  var POLL_MS = 10000;
  var DEFAULT_SKIN = 'corveil';
  var STYLE_ID = 'crow-skin';
  var catalog = null; // last /skins.json, once fetched
  var catalogRequest = null; // the in-flight fetch, shared by concurrent callers
  var ID_RE = /^[a-z0-9][a-z0-9-]{0,63}$/;

  function read(key) {
    try { return localStorage.getItem(key); } catch (_) { return null; } // private mode / denied storage
  }
  function write(key, value) {
    try {
      if (value === null) localStorage.removeItem(key);
      else localStorage.setItem(key, value);
    } catch (_) {}
  }

  function preference() {
    var v = read(KEY);
    if (v === 'light' || v === 'dark' || v === 'system') return v;
    return 'system';
  }

  // The skin this browser picked in Settings, or null to follow the default.
  function chosenSkin() {
    var v = read(SKIN_KEY);
    return (v && ID_RE.test(v)) ? v : null;
  }

  // The daemon-wide default, as last reported by /skins.json.
  function defaultSkin() {
    if (catalog && typeof catalog.default === 'string' && ID_RE.test(catalog.default)) return catalog.default;
    var v = read(SKIN_DEFAULT_KEY);
    return (v && ID_RE.test(v)) ? v : DEFAULT_SKIN;
  }

  function skin() {
    return chosenSkin() || defaultSkin();
  }

  function rememberCatalog(c) {
    catalog = (c && Array.isArray(c.skins)) ? c : { default: DEFAULT_SKIN, skins: [] };
    var d = (typeof catalog.default === 'string' && ID_RE.test(catalog.default)) ? catalog.default : DEFAULT_SKIN;
    write(SKIN_DEFAULT_KEY, d === DEFAULT_SKIN ? null : d);
    return catalog;
  }

  function listed(id) {
    if (id === DEFAULT_SKIN) return true;
    if (!catalog) return true; // unknown yet: assume it still exists
    for (var i = 0; i < catalog.skins.length; i++) if (catalog.skins[i].id === id) return true;
    return false;
  }

  function skinCache() {
    try {
      var c = JSON.parse(read(SKIN_CACHE_KEY) || 'null');
      return (c && typeof c.id === 'string' && typeof c.css === 'string') ? c : null;
    } catch (_) { return null; }
  }

  // Whether the active skin has a light palette. Unknown counts as yes: until
  // the catalog or a cache says otherwise, do not override the user's choice.
  function skinSupportsLight() {
    var id = skin();
    if (id === DEFAULT_SKIN) return true;
    if (catalog) {
      for (var i = 0; i < catalog.skins.length; i++) {
        if (catalog.skins[i].id === id) return catalog.skins[i].light !== false;
      }
    }
    var c = skinCache();
    if (c && c.id === id) return c.light !== false;
    return true;
  }

  function systemDark() {
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }

  // A dark-only skin pins dark whatever the scheme preference says.
  function resolved(pref) {
    if (!skinSupportsLight()) return 'dark';
    if (pref === 'light' || pref === 'dark') return pref;
    return systemDark() ? 'dark' : 'light';
  }

  function cssVar(name) {
    if (typeof getComputedStyle !== 'function') return '';
    return (getComputedStyle(document.documentElement).getPropertyValue(name) || '').trim();
  }

  // Read by terminal.js, grid.js, tui-record.js, and web/terminal.html. A
  // token that is not resolvable yet (stylesheet race) is left out rather than
  // sent empty — xterm's css.toColor throws on '' — so xterm falls back to its
  // own default for that slot until the next `crow-theme` re-applies.
  var XTERM_TOKENS = {
    background: '--term-bg', foreground: '--term-fg',
    cursor: '--term-cursor', cursorAccent: '--term-cursor-accent',
    selectionBackground: '--term-selection', selectionForeground: '--term-fg',
    black: '--term-black', red: '--term-red', green: '--term-green', yellow: '--term-yellow',
    blue: '--term-blue', magenta: '--term-magenta', cyan: '--term-cyan', white: '--term-white',
    brightBlack: '--term-bright-black', brightRed: '--term-bright-red',
    brightGreen: '--term-bright-green', brightYellow: '--term-bright-yellow',
    brightBlue: '--term-bright-blue', brightMagenta: '--term-bright-magenta',
    brightCyan: '--term-bright-cyan', brightWhite: '--term-bright-white',
  };
  function xtermTheme() {
    var theme = {};
    for (var key in XTERM_TOKENS) {
      var value = cssVar(XTERM_TOKENS[key]);
      if (value) theme[key] = value;
    }
    return theme;
  }

  // Put the skin's CSS (or none, for Corveil) in place and stamp data-skin.
  function paintSkin(id, css) {
    var root = document.documentElement;
    var style = document.getElementById(STYLE_ID);
    if (id === DEFAULT_SKIN || !css) {
      root.removeAttribute('data-skin');
      if (style && style.parentNode) style.parentNode.removeChild(style);
      return;
    }
    if (!style) {
      style = document.createElement('style');
      style.id = STYLE_ID;
      (document.head || root).appendChild(style);
    }
    if (style.textContent !== css) style.textContent = css;
    root.setAttribute('data-skin', id);
  }

  function apply(pref) {
    var chosen = pref || preference();
    var theme = resolved(chosen);
    var root = document.documentElement;
    root.setAttribute('data-theme', theme);
    root.style.colorScheme = theme;
    var meta = document.querySelector('meta[name="theme-color"]');
    var bg = cssVar('--bg-deep');
    if (meta && bg) meta.setAttribute('content', bg);
    try {
      window.dispatchEvent(new CustomEvent('crow-theme', {
        detail: { preference: chosen, theme: theme, skin: skin(), lightAvailable: skinSupportsLight() },
      }));
    } catch (_) { /* CustomEvent unavailable */ }
  }

  function setPreference(pref) {
    if (pref !== 'light' && pref !== 'dark' && pref !== 'system') pref = 'system';
    write(KEY, pref);
    apply(pref);
  }

  function fetchJSON(url) {
    return fetch(url, { credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error(url + ' ' + r.status);
      return r.json();
    });
  }
  function fetchText(url) {
    return fetch(url, { credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error(url + ' ' + r.status);
      return r.text();
    });
  }

  // The skins crowd offers. Cached for the page's lifetime.
  function skins() {
    if (catalog) return Promise.resolve(catalog);
    if (typeof fetch !== 'function') return Promise.resolve({ default: DEFAULT_SKIN, skins: [] });
    if (!catalogRequest) {
      catalogRequest = fetchJSON('/skins.json').then(rememberCatalog, function (err) {
        catalogRequest = null; // let a later call retry
        throw err;
      });
    }
    return catalogRequest;
  }

  // Fetch, cache and paint `id`, and only then record `choice` as this
  // browser's pick (a skin id, or null to follow the default): a failed fetch
  // leaves crow.skin on the skin that is actually painted. `choice` undefined
  // repaints without touching the pick — the live-reload path, which must not
  // pin a browser that follows the default. A skin crowd no longer has falls
  // back to the default (then Corveil) instead of leaving a stale palette in
  // place. `skinRequest` drops a response a newer switch overtook.
  var skinRequest = 0;
  function record(choice) {
    if (choice !== undefined) write(SKIN_KEY, choice);
  }
  function loadSkin(id, choice) {
    var request = ++skinRequest;
    if (id === DEFAULT_SKIN) {
      record(choice);
      write(SKIN_CACHE_KEY, null);
      paintSkin(DEFAULT_SKIN, '');
      apply(preference());
      return Promise.resolve(DEFAULT_SKIN);
    }
    return skins().then(function (c) {
      if (request !== skinRequest) return skin();
      var entry = null;
      for (var i = 0; i < c.skins.length; i++) if (c.skins[i].id === id) entry = c.skins[i];
      if (!entry) {
        // Gone: drop it as a pick, and paint the default (or Corveil, if the
        // default is what went missing).
        if (choice === id || chosenSkin() === id) write(SKIN_KEY, null);
        var fallback = defaultSkin() === id ? DEFAULT_SKIN : defaultSkin();
        return loadSkin(fallback);
      }
      return fetchText('/skins/' + encodeURIComponent(id) + '.css').then(function (css) {
        if (request !== skinRequest) return skin(); // a newer switch won
        record(choice);
        write(SKIN_CACHE_KEY, JSON.stringify({ id: id, name: entry.name, light: entry.light !== false, css: css }));
        paintSkin(id, css);
        apply(preference());
        return id;
      });
    });
  }

  // Pick a skin for this browser; null (or '') goes back to following the
  // daemon's default.
  function setSkin(id) {
    var choice = (typeof id === 'string' && ID_RE.test(id)) ? id : null;
    return loadSkin(choice || defaultSkin(), choice);
  }

  // Re-read /skins.json; when its revision moved, repaint from it and tell
  // listeners (the Settings picker) with `crow-skins`.
  var lastRevision = null;
  var seenCatalog = false;
  function refreshCatalog() {
    if (typeof fetch !== 'function') return Promise.resolve(null);
    return fetch('/skins.json', { credentials: 'same-origin', cache: 'no-cache' }).then(function (r) {
      if (!r.ok) throw new Error('/skins.json ' + r.status);
      return r.json();
    }).then(function (c) {
      var revision = (c && typeof c.revision === 'string') ? c.revision : null;
      var first = !seenCatalog;
      if (!first && revision === lastRevision) return catalog;
      seenCatalog = true;
      lastRevision = revision;
      rememberCatalog(c);
      catalogRequest = null;
      var chosen = chosenSkin();
      if (chosen && !listed(chosen)) write(SKIN_KEY, null);
      var id = skin();
      var done = (first && id === DEFAULT_SKIN && !document.documentElement.hasAttribute('data-skin'))
        ? Promise.resolve(id) : loadSkin(id);
      return done.then(function () {
        if (!first) {
          try { window.dispatchEvent(new CustomEvent('crow-skins', { detail: catalog })); } catch (_) {}
        }
        return catalog;
      });
    });
  }

  var pollTimer = null;
  function poll() {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(function () {
      pollTimer = null;
      if (document.visibilityState === 'hidden') return; // resumes on visibilitychange
      refreshCatalog().catch(function () {}).then(poll);
    }, POLL_MS);
  }

  window.CrowTheme = {
    KEY: KEY,
    SKIN_KEY: SKIN_KEY,
    DEFAULT_SKIN: DEFAULT_SKIN,
    preference: preference,
    setPreference: setPreference,
    apply: apply,
    resolved: resolved,
    skin: skin,
    chosenSkin: chosenSkin,
    defaultSkin: defaultSkin,
    skins: skins,
    setSkin: setSkin,
    refresh: refreshCatalog,
    lightAvailable: skinSupportsLight,
  };
  window.crowXtermTheme = xtermTheme;

  // First paint: the cached skin CSS, synchronously.
  var initial = skin();
  var cached = skinCache();
  if (initial !== DEFAULT_SKIN && cached && cached.id === initial) paintSkin(initial, cached.css);
  apply(preference());

  if (window.matchMedia) {
    var mq = window.matchMedia('(prefers-color-scheme: dark)');
    var onChange = function () {
      if (preference() === 'system') apply('system');
    };
    if (mq.addEventListener) mq.addEventListener('change', onChange);
    else if (mq.addListener) mq.addListener(onChange);
  }

  // theme-color needs computed CSS, which is empty while this blocking head
  // script is still running. Re-apply once stylesheets have loaded, then
  // refresh the skin from crowd: the cache may be stale, or missing on a first
  // visit (that one paint is the default skin; every later one is not).
  document.addEventListener('DOMContentLoaded', function () {
    apply(preference());
    if (typeof fetch === 'function') {
      refreshCatalog().catch(function () { /* offline / crowd restarting: keep the cache */ }).then(poll);
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') {
          refreshCatalog().catch(function () {}).then(poll);
        }
      });
    }
  });
})();
