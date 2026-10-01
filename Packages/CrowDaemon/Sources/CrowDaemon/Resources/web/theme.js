'use strict';
// Crow color scheme (CROW-1316). Blocking script in <head>, before theme.css,
// so the first paint already has data-theme. Preference is local to this
// browser: system | light | dark. Settings → General writes it; nothing here
// round-trips through daemon config.

(function () {
  var KEY = 'crow.color-scheme';

  function preference() {
    try {
      var v = localStorage.getItem(KEY);
      if (v === 'light' || v === 'dark' || v === 'system') return v;
    } catch (_) { /* private mode / denied storage */ }
    return 'system';
  }

  function systemDark() {
    return !!(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
  }

  function resolved(pref) {
    if (pref === 'light' || pref === 'dark') return pref;
    return systemDark() ? 'dark' : 'light';
  }

  function cssVar(name, fallback) {
    if (typeof getComputedStyle !== 'function') return fallback;
    var value = (getComputedStyle(document.documentElement).getPropertyValue(name) || '').trim();
    return value || fallback;
  }

  // Read by terminal.js, grid.js, tui-record.js, and web/terminal.html.
  // Missing tokens fall back to the dark palette so a stylesheet race cannot
  // hand xterm an empty color (css.toColor throws).
  function xtermTheme() {
    return {
      background: cssVar('--term-bg', '#0A060B'),
      foreground: cssVar('--term-fg', '#FFF7FB'),
      cursor: cssVar('--term-cursor', '#FF2D7A'),
      cursorAccent: cssVar('--term-cursor-accent', '#0A060B'),
      selectionBackground: cssVar('--term-selection', 'rgba(255, 45, 122, 0.35)'),
      selectionForeground: cssVar('--term-fg', '#FFF7FB'),
      black: cssVar('--term-black', '#0A060B'),
      red: cssVar('--term-red', '#FF6B63'),
      green: cssVar('--term-green', '#3DDC84'),
      yellow: cssVar('--term-yellow', '#FFD60A'),
      blue: cssVar('--term-blue', '#64B4FF'),
      magenta: cssVar('--term-magenta', '#FF2D7A'),
      cyan: cssVar('--term-cyan', '#5EE0D0'),
      white: cssVar('--term-white', '#FFF7FB'),
      brightBlack: cssVar('--term-bright-black', '#A894A2'),
      brightRed: cssVar('--term-bright-red', '#FF8A84'),
      brightGreen: cssVar('--term-bright-green', '#7AF0A8'),
      brightYellow: cssVar('--term-bright-yellow', '#FFE566'),
      brightBlue: cssVar('--term-bright-blue', '#9DCEFF'),
      brightMagenta: cssVar('--term-bright-magenta', '#FF7EAE'),
      brightCyan: cssVar('--term-bright-cyan', '#8FF3E8'),
      brightWhite: cssVar('--term-bright-white', '#FFFFFF'),
    };
  }

  function apply(pref) {
    var chosen = pref || preference();
    var theme = resolved(chosen);
    document.documentElement.setAttribute('data-theme', theme);
    document.documentElement.style.colorScheme = theme;
    var meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', theme === 'light' ? '#FAF9F5' : '#0A060B');
    try {
      window.dispatchEvent(new CustomEvent('crow-theme', { detail: { preference: chosen, theme: theme } }));
    } catch (_) { /* CustomEvent unavailable */ }
  }

  function setPreference(pref) {
    if (pref !== 'light' && pref !== 'dark' && pref !== 'system') pref = 'system';
    try { localStorage.setItem(KEY, pref); } catch (_) {}
    apply(pref);
  }

  window.CrowTheme = {
    KEY: KEY,
    preference: preference,
    setPreference: setPreference,
    apply: apply,
    resolved: resolved,
  };
  window.crowXtermTheme = xtermTheme;

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
  // script is still running. Re-apply once stylesheets have loaded.
  document.addEventListener('DOMContentLoaded', function () { apply(preference()); });
})();
