// Crow jump-to-bottom control (#635 → #668), as a shared xterm.js addon.
//
// Long agent/chat output leaves no fast path back to the live edge once you
// scroll up; this shows a pill when the viewport is above the bottom and snaps
// back on click. Implemented once here so BOTH surfaces load it the same way —
// the desktop WKWebView page (CrowTerminal/Resources/xterm/terminal.html) and
// the web UI (served at /xterm/… by the daemon: web/index.html + app.js, and
// the web/terminal.html debug page) — instead of hand-mirroring the control per
// front-end (the parity drift that bit reflow-debounce #661 and #662).
//
// Pure terminal + DOM, no transport coupling: it only needs the Terminal, its
// element, onScroll/onRender, an at-bottom check (buffer.active.viewportY/baseY)
// and scrollToBottom(). Loaded via <script src> (not ES modules), so it exposes
// a namespaced UMD-style global matching the vendored addons
// (window.FitAddon.FitAddon → window.CrowJumpBottomAddon.CrowJumpBottomAddon).
(function (global) {
  'use strict';

  var STYLE_ID = 'crow-jumpbottom-style';

  // Injected once per document; keyed on a CLASS (not an id) because the web UI
  // can host more than one terminal element. Ported verbatim from the inline
  // #635 styles that used to live in terminal.html.
  var CSS = [
    '.crow-jump-bottom {',
    '  position: absolute;',
    '  right: 16px;',
    '  bottom: 16px;',
    '  width: 34px;',
    '  height: 34px;',
    '  padding: 0;',
    '  display: flex;',
    '  align-items: center;',
    '  justify-content: center;',
    '  font-size: 20px;',
    '  line-height: 1;',
    '  color: #ddc482;',
    '  background: #22262a;',
    '  border: 1px solid rgba(221, 196, 130, 0.35);',
    '  border-radius: 17px;',
    '  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.5);',
    '  cursor: pointer;',
    '  z-index: 10;',
    '  opacity: 1;',
    '  transition: opacity 0.12s ease;',
    '}',
    '.crow-jump-bottom:hover {',
    '  background: #2a2f34;',
    '  border-color: rgba(221, 196, 130, 0.6);',
    '}',
    '.crow-jump-bottom.hidden {',
    '  opacity: 0;',
    '  visibility: hidden;',
    '  pointer-events: none;',
    '}',
  ].join('\n');

  function injectStyleOnce() {
    if (document.getElementById(STYLE_ID)) {
      return;
    }
    var style = document.createElement('style');
    style.id = STYLE_ID;
    style.textContent = CSS;
    (document.head || document.documentElement).appendChild(style);
  }

  function CrowJumpBottomAddon() {}

  // ITerminalAddon.activate — must run after term.open() so term.element exists.
  CrowJumpBottomAddon.prototype.activate = function (term) {
    this._term = term;
    var self = this;

    // The button anchors to the terminal's container (the element passed to
    // term.open()), NOT document.body — desktop is full-page but web is a
    // tabbed container, so absolute positioning must be relative to the
    // viewport it belongs to.
    var container = term.element && term.element.parentElement;
    if (!container) {
      return;
    }
    this._container = container;

    injectStyleOnce();

    // Give the absolutely-positioned button a positioning context. Record when
    // we set it so dispose() can revert (relative with no offsets doesn't move
    // the container, so fit/resize is unaffected).
    if (getComputedStyle(container).position === 'static') {
      container.style.position = 'relative';
      this._setPosition = true;
    }

    var btn = document.createElement('button');
    btn.className = 'crow-jump-bottom hidden';
    btn.setAttribute('aria-label', 'Jump to latest output');
    btn.setAttribute('title', 'Jump to bottom');
    btn.innerHTML = '&#9662;'; // ▾
    container.appendChild(btn);
    this._btn = btn;

    this._onClick = function () {
      term.scrollToBottom();
      term.focus(); // restore typing focus stolen by the button
      self._update();
    };
    btn.addEventListener('click', this._onClick);

    // onScroll is the primary trigger (leaving the bottom only ever happens via
    // a user scroll — new output while pinned auto-scrolls and stays pinned);
    // onRender is a safety-net re-check.
    this._scrollDisposable = term.onScroll(function () { self._update(); });
    this._renderDisposable = term.onRender(function () { self._update(); });

    this._update();
  };

  CrowJumpBottomAddon.prototype._atBottom = function () {
    var b = this._term.buffer.active;
    return b.viewportY >= b.baseY;
  };

  CrowJumpBottomAddon.prototype._update = function () {
    if (this._btn) {
      this._btn.classList.toggle('hidden', this._atBottom());
    }
  };

  // ITerminalAddon.dispose — tear down cleanly so the web UI (which
  // creates/switches/closes terminals) never leaks duplicate buttons or
  // stacked scroll listeners.
  CrowJumpBottomAddon.prototype.dispose = function () {
    if (this._scrollDisposable) {
      this._scrollDisposable.dispose();
      this._scrollDisposable = null;
    }
    if (this._renderDisposable) {
      this._renderDisposable.dispose();
      this._renderDisposable = null;
    }
    if (this._btn) {
      if (this._onClick) {
        this._btn.removeEventListener('click', this._onClick);
      }
      this._btn.remove();
      this._btn = null;
    }
    if (this._setPosition && this._container) {
      this._container.style.position = '';
      this._setPosition = false;
    }
    this._container = null;
    this._term = null;
    // The shared <style> is left in place — it's id-guarded and harmless.
  };

  global.CrowJumpBottomAddon = { CrowJumpBottomAddon: CrowJumpBottomAddon };
})(typeof globalThis !== 'undefined' ? globalThis : window);
