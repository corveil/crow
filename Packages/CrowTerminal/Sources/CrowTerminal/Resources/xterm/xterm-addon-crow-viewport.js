// Crow visual-viewport fit (CROW-988), as a shared xterm.js addon.
//
// On a phone, opening the software keyboard hides the agent's prompt line. iOS
// Safari (and Chrome/Android by default) shrink the *visual* viewport and leave
// the *layout* viewport alone, so `window.innerHeight`, `height: 100%` and even
// `100dvh` all still report the full pre-keyboard height and `window.resize`
// never fires. The grid keeps rendering at its old size and its bottom rows —
// where the prompt sits — end up underneath the keyboard, unreachable (the
// terminal surfaces are `overflow: hidden`, so they can't be scrolled into view
// either). `window.visualViewport` is the only signal that anything changed.
//
// This subscribes to it and sizes the terminal's host element so its bottom
// edge lands on the bottom of the *visible* area, then asks the page to refit
// and pins the prompt. Written once here, as an addon, so every surface that
// loads it stays in sync instead of hand-mirroring the logic per front-end —
// the parity drift that bit reflow-debounce #661/#662 and the mouse-mode
// swallow #776.
//
// Deliberately inert everywhere a keyboard can't occlude the page. Three
// independent guards: absent `visualViewport` (older embedded webviews) is a
// hard no-op; a surface with no software keyboard (the desktop WKWebView — see
// below) never even subscribes; and past those, any occlusion below
// KEYBOARD_MIN_OCCLUSION is ignored. Nothing is written to the host's style
// until a keyboard-sized inset actually appears, and it is restored verbatim
// when that inset goes away.
//
// CROW-1045: `visualViewport` presence alone is NOT "this surface has a
// keyboard." The macOS desktop app is a WKWebView (Tauri), and WKWebViews
// expose `visualViewport` just like a phone does. Under `viewport-fit=cover`
// its layout viewport (`documentElement.clientHeight`) can outrun the visible
// `visualViewport.height` by the window chrome / safe-area — an offset the
// occlusion test above then mistakes for a keyboard, shrinking the terminal
// host and stranding a dead band below the grid (the reported regression). A
// software keyboard only exists on a touch surface, so gate the whole addon on
// that: coarse pointer or touch points. Desktop fails both and stays inert,
// exactly like the no-`visualViewport` case; phones and tablets are unchanged.
//
// Loaded via <script src> (not ES modules), so it exposes a namespaced UMD-style
// global matching the vendored addons
// (window.FitAddon.FitAddon → window.CrowViewportAddon.CrowViewportAddon).
(function (global) {
  'use strict';

  // How much of the layout viewport must be occluded before we treat it as a
  // software keyboard. Mobile browser chrome (iOS Safari's collapsing toolbars)
  // routinely puts `visualViewport.height` 40-60px below the layout viewport
  // with no keyboard in sight, and desktop pinch-zoom is smaller still; the
  // shortest phone keyboard — landscape, on a small device — is comfortably
  // north of 150px. 120 separates the two without straddling either.
  var KEYBOARD_MIN_OCCLUSION = 120;

  // Never size the host below this. A pathological measurement (a mid-rotation
  // frame, a host scrolled off the visible area) would otherwise hand
  // FitAddon a 0-or-negative box, whose degenerate proposeDimensions makes a
  // junk grid — the same failure the host pages already guard against.
  var MIN_HOST_HEIGHT = 40;

  // Does this surface have a software keyboard that can occlude the page? Only a
  // touch surface does. `visualViewport` is not the test — desktop WKWebViews
  // (the Tauri macOS app) expose it too, and CROW-1045 is exactly that surface
  // tripping the occlusion detector on window chrome. `maxTouchPoints > 0` is
  // the primary signal (iOS reports 5, macOS reports 0); `(pointer: coarse)` is
  // the fallback for the rare touch device that under-reports it. Both are
  // wrapped/typed defensively — an embedded webview may lack `matchMedia`, and a
  // throwing/absent one must read as "not touch," i.e. desktop, i.e. inert.
  function keyboardCapable(global) {
    var nav = global.navigator;
    if (nav && typeof nav.maxTouchPoints === 'number' && nav.maxTouchPoints > 0) {
      return true;
    }
    var mm = global.matchMedia;
    if (typeof mm === 'function') {
      try {
        var q = mm.call(global, '(pointer: coarse)');
        if (q && q.matches) {
          return true;
        }
      } catch (_) { /* no usable matchMedia → treat as non-touch */ }
    }
    return false;
  }

  /// `options.host`    element to size; defaults to the container passed to
  ///                   `term.open()` (i.e. `term.element.parentElement`).
  /// `options.onResize` called after the host is resized — the page's own
  ///                   coalesced fit + PTY resize. The addon deliberately does
  ///                   NOT call `fitAddon.fit()` itself: each surface wraps the
  ///                   fit in its own dedup/ownership rules (app.js gates on
  ///                   focus so a background tab can't steal tmux's shared
  ///                   window size, #667) and reaching past that would
  ///                   reintroduce exactly what those guards exist to stop.
  function CrowViewportAddon(options) {
    options = options || {};
    this._onResize = typeof options.onResize === 'function' ? options.onResize : null;
    this._host = options.host || null;
    this._applied = false;      // have we written to host.style.height?
    this._savedHeight = '';     // the inline height we found there, restored on undo
    this._keyboardOpen = false;
    this._pending = false;      // a frame is already scheduled
  }

  // ITerminalAddon.activate — must run after term.open() so term.element exists.
  CrowViewportAddon.prototype.activate = function (term) {
    var vv = global.visualViewport;
    // No signal → leave the page exactly as it was. This is the whole
    // "non-visualViewport webviews are unchanged" guarantee.
    if (!vv) {
      return;
    }
    // No software keyboard on this surface → same hard no-op (CROW-1045). The
    // desktop WKWebView has `visualViewport` but no keyboard, so acting on its
    // occlusion would shrink a full-height terminal for nothing. Bail before
    // subscribing so this surface never even schedules a measurement.
    if (!keyboardCapable(global)) {
      return;
    }
    var host = this._host || (term.element && term.element.parentElement);
    if (!host) {
      return;
    }
    this._term = term;
    this._host = host;
    this._vv = vv;

    var self = this;
    this._onChange = function () { self._schedule(); };
    // `scroll` matters as much as `resize`: iOS reports a keyboard that shifts
    // the visual viewport within an unchanged layout viewport as a scroll.
    vv.addEventListener('resize', this._onChange);
    vv.addEventListener('scroll', this._onChange);

    // Evaluate once up front — a terminal can be attached with the keyboard
    // already open (switching sessions/tabs mid-typing).
    this._schedule();
  };

  // Coalesce a burst of viewport events into one measurement per frame. iOS
  // emits a stream of them while the keyboard animates in.
  CrowViewportAddon.prototype._schedule = function () {
    if (this._pending) {
      return;
    }
    this._pending = true;
    var self = this;
    global.requestAnimationFrame(function () {
      self._pending = false;
      self._apply();
    });
  };

  CrowViewportAddon.prototype._apply = function () {
    var term = this._term;
    var host = this._host;
    var vv = this._vv;
    if (!term || !host || !vv || !host.isConnected) {
      return; // disposed or detached between the event and the frame
    }

    var root = global.document && global.document.documentElement;
    var layoutHeight = root ? root.clientHeight : 0;
    // Bottom edge of the visible area in LAYOUT-viewport coordinates — the same
    // space getBoundingClientRect() reports in, which is what makes this work
    // for a terminal that isn't full-page (the web app's is below a header and
    // a tab bar). `offsetTop` is how far the visual viewport has been pushed
    // down inside the layout viewport, so it must be added, not subtracted.
    var visibleBottom = vv.offsetTop + vv.height;
    var occluded = layoutHeight - visibleBottom;

    if (occluded <= KEYBOARD_MIN_OCCLUSION) {
      this._restore();
      return;
    }

    // A host with no layout box measures as a zero-rect at the document origin,
    // which would compute a full-viewport height and strand it there for
    // whenever the element comes back. The web app hides the whole terminal
    // while a board is open, and a board has its own focusable inputs — so this
    // is reachable, not theoretical. Skip only the *apply* path: releasing a
    // height (above) is safe on a hidden element and must stay unconditional, or
    // hiding the terminal mid-keyboard would strand the override for good.
    if (host.clientHeight < 1) {
      return;
    }

    var available = Math.round(visibleBottom - host.getBoundingClientRect().top);
    var next = Math.max(available, MIN_HOST_HEIGHT) + 'px';
    var opening = !this._keyboardOpen;
    if (!opening && host.style.height === next) {
      return; // geometry unchanged — a same-size refit is a needless SIGWINCH
    }
    if (!this._applied) {
      this._savedHeight = host.style.height;
      this._applied = true;
    }
    // Pin the prompt when the keyboard opens (revealing it is the point), and
    // otherwise only when the user was already at the live edge — a shrinking
    // grid can push a pinned viewport off the bottom, but someone who scrolled
    // up with the keyboard open kept their place on purpose.
    var pin = opening || this._atBottom();
    this._keyboardOpen = true;
    host.style.height = next;
    this._refit(pin);
  };

  // Undo everything we wrote and hand sizing back to the stylesheet. Idempotent:
  // the common case (no keyboard, ever) never took the branch that sets
  // `_applied`, so this returns without touching the DOM.
  CrowViewportAddon.prototype._restore = function () {
    this._keyboardOpen = false;
    if (!this._applied) {
      return;
    }
    this._applied = false;
    this._host.style.height = this._savedHeight;
    this._savedHeight = '';
    this._refit(false);
  };

  CrowViewportAddon.prototype._atBottom = function () {
    var b = this._term.buffer && this._term.buffer.active;
    return !b || b.viewportY >= b.baseY;
  };

  CrowViewportAddon.prototype._refit = function (pin) {
    if (this._onResize) {
      try { this._onResize(); } catch (_) { /* the page's fit is its own problem */ }
    }
    if (!pin) {
      return;
    }
    // The host pages coalesce their fit to the NEXT frame, so the grid still has
    // its pre-resize row count right now. Scrolling to the bottom here would
    // land on the old geometry and the fit would drop the prompt back out of
    // view — so pin one frame later, after the refit has landed.
    var self = this;
    global.requestAnimationFrame(function () {
      if (!self._term) {
        return;
      }
      try { self._term.scrollToBottom(); } catch (_) { /* disposed mid-frame */ }
    });
  };

  // ITerminalAddon.dispose — the web UI creates/switches/closes terminals, so
  // this must leave no stacked visualViewport listeners and no inline height
  // stranded on a recycled host element.
  CrowViewportAddon.prototype.dispose = function () {
    if (this._vv && this._onChange) {
      this._vv.removeEventListener('resize', this._onChange);
      this._vv.removeEventListener('scroll', this._onChange);
    }
    if (this._applied && this._host) {
      this._host.style.height = this._savedHeight;
    }
    this._applied = false;
    this._keyboardOpen = false;
    this._onChange = null;
    this._vv = null;
    this._host = null;
    this._term = null;
  };

  global.CrowViewportAddon = { CrowViewportAddon: CrowViewportAddon };
})(typeof globalThis !== 'undefined' ? globalThis : window);
