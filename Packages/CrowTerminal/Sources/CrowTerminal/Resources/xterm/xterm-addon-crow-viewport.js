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
// CROW-1078: opening the keyboard also left the xterm *cursor* misaligned — the
// drawn caret and the iOS IME/caret accessory landing on different cells. Two
// causes, both handled here so the reconciliation lives in one shared place
// instead of per front-end: (1) iOS scrolls the visual viewport to chase
// xterm's helper textarea, which parks off-screen at `left:-9999em` — so re-home
// the parked state on-screen (touch only), and the field no longer flies away,
// which also keeps the occlusion maths honest (see `_apply`). (2) after an inset
// is applied or restored the drawn cursor can lag the moved host — so force a
// repaint, which also re-runs xterm's textarea sync onto the cell. A WebGL
// canvas is a compositor layer that ignores that repaint while iOS animates the
// viewport, so `app.js` drops WebGL on touch surfaces (sharing the exported
// `keyboardCapable`, below) and uses the DOM renderer there. All of it stays
// behind the same keyboardCapable + visualViewport guards, so desktop and
// non-touch webviews are wholly unchanged.
//
// CROW-1263: iPad Chrome still pans the visual viewport on focus, even with the
// helper on-screen. Two accessory bars (Chrome Autofill + iPadOS QuickType)
// stack above the keyboard and Chrome scrolls `visualViewport.offsetTop` so the
// field sits above both — the whole TUI jumps up, FitAddon SIGWINCHes against a
// moving viewport, and the agent grid corrupts. A page cannot hide those bars
// (`autocomplete="off"` is ignored; there is no web API). What we can do: (1)
// ask iOS Chrome to *overlay* the keyboard (`interactive-widget=overlays-content`
// + `virtualKeyboard.overlaysContent`, Android keeps `resizes-content`), (2)
// wrap the helper's `focus({ preventScroll: true })` and pin `offsetTop` back to
// 0 on focus/scroll, (3) stamp the helper so it looks less like a form, (4) keep
// occlusion as `layoutHeight - vv.height` so a chased offsetTop cannot read as
// "no keyboard". Accessory animation is a visualViewport event burst — the
// existing rAF coalesce is one apply per frame, and an unchanged geometry after
// the pin is not a SIGWINCH.
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

  // iPhone / iPad, including iPadOS 13+ which reports as Macintosh + touch.
  // Used to swap `interactive-widget` to overlay (CROW-1263) without touching
  // Chrome/Android's `resizes-content` path (CROW-988).
  function isAppleTouchDevice(global) {
    var nav = global.navigator;
    if (!nav) {
      return false;
    }
    var ua = nav.userAgent || '';
    if (/iPad|iPhone|iPod/.test(ua)) {
      return true;
    }
    return nav.platform === 'MacIntel' && typeof nav.maxTouchPoints === 'number'
      && nav.maxTouchPoints > 1;
  }

  // iOS: overlay the software keyboard (and accessory bars) instead of
  // shrinking/panning the layout viewport. Idempotent. A no-op on Android and
  // desktop — those keep the HTML default `resizes-content`. The same swap also
  // lives as an inline <head> script so it lands before first paint; this copy
  // re-applies if a later navigation or xterm attach races it.
  function applyInteractiveWidgetPolicy(global) {
    if (!isAppleTouchDevice(global)) {
      return false;
    }
    var doc = global.document;
    if (doc && typeof doc.querySelector === 'function') {
      var meta = doc.querySelector('meta[name="viewport"]');
      if (meta) {
        var content = meta.getAttribute('content') || '';
        if (content.indexOf('interactive-widget=resizes-content') !== -1) {
          meta.setAttribute('content', content.replace(
            'interactive-widget=resizes-content',
            'interactive-widget=overlays-content'
          ));
        }
      }
    }
    try {
      var vk = global.navigator && global.navigator.virtualKeyboard;
      if (vk) {
        vk.overlaysContent = true;
      }
    } catch (_) { /* Virtual Keyboard API is optional */ }
    return true;
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
    this._textarea = null;      // xterm's focus/IME helper textarea (CROW-1078)
    this._onFocus = null;       // re-sync when the keyboard is raised on focus
    this._pinning = false;      // re-entry guard: scrollTo can itself fire scroll
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

    // CROW-1263: overlay on iPhone/iPad so Chrome does not resize/pan the layout
    // viewport out from under the grid. Android keeps the HTML default.
    applyInteractiveWidgetPolicy(global);

    var self = this;
    this._onChange = function () {
      // Pin synchronously so a chased offsetTop does not survive until the
      // coalesced frame (that leftover pan is the TUI jump). Then one apply.
      self._pinViewport();
      self._schedule();
    };
    // `scroll` matters as much as `resize`: iOS reports a keyboard that shifts
    // the visual viewport within an unchanged layout viewport as a scroll.
    // Accessory-bar animation is the same burst (CROW-1263); rAF coalesces it.
    vv.addEventListener('resize', this._onChange);
    vv.addEventListener('scroll', this._onChange);

    // CROW-1078: stop iOS scrolling the visual viewport to chase the off-screen
    // helper textarea, and reconcile the cursor the moment the keyboard is
    // raised. `_homeTextarea` re-parks the field on-screen (a no-op once it's on
    // a real cell — xterm's inline sync wins). CROW-1263: wrap focus so iOS
    // cannot pan on tap, stamp the helper so it looks less like a form, and pin
    // offsetTop on the focus event itself (the vv scroll trails the keyboard).
    this._homeTextarea();
    this._onFocus = function () {
      self._pinViewport();
      self._prepareTextarea();
      self._schedule();
    };
    this._prepareTextarea();

    // Evaluate once up front — a terminal can be attached with the keyboard
    // already open (switching sessions/tabs mid-typing).
    this._schedule();
  };

  // Coalesce a burst of viewport events into one measurement per frame. iOS
  // emits a stream of them while the keyboard (and Chrome/iPadOS accessory bars)
  // animates in — applying per event is the #637 / #661 SIGWINCH storm.
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

    this._prepareTextarea();

    var root = global.document && global.document.documentElement;
    var layoutHeight = root ? root.clientHeight : 0;
    // Bottom edge of the visible area in LAYOUT-viewport coordinates — the same
    // space getBoundingClientRect() reports in, which is what makes this work
    // for a terminal that isn't full-page (the web app's is below a header and
    // a tab bar). `offsetTop` is how far the visual viewport has been pushed
    // down inside the layout viewport, so it must be added, not subtracted —
    // EXCEPT when we just pinned a Chrome/iOS chase back to the origin
    // (CROW-1263): offsetTop may not have updated this turn, and adding the
    // stale pan would size the host as if the TUI had been shoved up.
    var pinned = this._pinViewport();
    var offsetTop = pinned ? 0 : (vv.offsetTop || 0);
    var visibleBottom = offsetTop + vv.height;

    // Is a software keyboard up? The shrink of the VISIBLE height against the
    // layout viewport — `layoutHeight - vv.height` — is the keyboard's height,
    // and it is independent of how far iOS has scrolled the visual viewport
    // (`offsetTop`). Testing `layoutHeight - visibleBottom` instead let a scroll
    // that iOS did to chase the off-screen helper textarea read as "no keyboard"
    // (offsetTop + height ≈ layoutHeight → ≈ 0) even with the keyboard open —
    // CROW-1078 #4. CROW-1263 pins a chased offsetTop before sizing so a
    // leftover pan cannot shove the host. On these `overflow: hidden` pages
    // nothing but the keyboard shrinks the visible height, so this can't
    // false-positive.
    var keyboardHeight = layoutHeight - vv.height;

    if (keyboardHeight <= KEYBOARD_MIN_OCCLUSION) {
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

  // CROW-1263: Chrome iOS pans visualViewport.offsetTop to keep the helper
  // above Autofill + iPadOS accessory bars. offsetTop is read-only; pinning it
  // is `window.scrollTo(0, 0)`. Guarded against re-entry because that scroll
  // itself fires a `visualViewport` `scroll`. A no-op when already at origin.
  CrowViewportAddon.prototype._pinViewport = function () {
    var vv = this._vv;
    if (!vv) {
      return false;
    }
    if (this._pinning) {
      return true;
    }
    var top = vv.offsetTop || 0;
    var left = vv.offsetLeft || 0;
    var y = global.scrollY || global.pageYOffset || 0;
    var x = global.scrollX || global.pageXOffset || 0;
    if (!top && !left && !y && !x) {
      return false;
    }
    this._pinning = true;
    try {
      if (typeof global.scrollTo === 'function') {
        global.scrollTo(0, 0);
      }
    } catch (_) { /* some webviews reject scrollTo during keyboard animation */ }
    this._pinning = false;
    return true;
  };

  // Best-effort: make the IME helper look less like a login/payment field so
  // Chrome's Autofill accessory is less likely to appear. Chrome iOS currently
  // draws that strip on almost every focused text box (no web API hides it);
  // these attributes are what we can stamp. Do NOT use new-password /
  // one-time-code / cc-csc — those swap in a *different* accessory. Re-applied
  // after open() because xterm recreates/syncs the node (CROW-1263).
  CrowViewportAddon.prototype._stampTextarea = function (ta) {
    if (!ta || typeof ta.setAttribute !== 'function') {
      return;
    }
    ta.setAttribute('autocomplete', 'off');
    ta.setAttribute('autocorrect', 'off');
    ta.setAttribute('autocapitalize', 'off');
    ta.setAttribute('spellcheck', 'false');
    ta.setAttribute('name', 'crow-tty');
    ta.setAttribute('data-lpignore', 'true');
  };

  // iOS scrolls the visual viewport on textarea.focus() unless preventScroll is
  // set. Wrap the instance method after open(); xterm's own callers (term.focus,
  // IME) then inherit it. Idempotent per node.
  CrowViewportAddon.prototype._wrapFocus = function (ta) {
    if (!ta || typeof ta.focus !== 'function' || ta.focus._crowPinned) {
      return;
    }
    var orig = ta.focus.bind(ta);
    var wrapped = function (options) {
      var opts = { preventScroll: true };
      if (options && typeof options === 'object') {
        for (var k in options) {
          if (Object.prototype.hasOwnProperty.call(options, k)) {
            opts[k] = options[k];
          }
        }
        opts.preventScroll = true;
      }
      return orig(opts);
    };
    wrapped._crowPinned = true;
    ta.focus = wrapped;
  };

  // Stamp + wrap + listen. xterm can replace the helper node after open(), so
  // this is safe to re-run; it only rebinds when the element identity changes.
  CrowViewportAddon.prototype._prepareTextarea = function () {
    var term = this._term;
    var ta = term && term.textarea;
    if (!ta) {
      return;
    }
    this._stampTextarea(ta);
    this._wrapFocus(ta);
    if (ta === this._textarea) {
      return;
    }
    if (this._textarea && this._onFocus && typeof this._textarea.removeEventListener === 'function') {
      this._textarea.removeEventListener('focus', this._onFocus);
    }
    this._textarea = ta;
    if (this._onFocus && typeof ta.addEventListener === 'function') {
      ta.addEventListener('focus', this._onFocus);
    }
  };

  // Re-home xterm's parked helper textarea from off-screen-left to the on-screen
  // top-left, once per document, on touch surfaces only (the caller is already
  // behind the keyboardCapable guard). xterm hides the caret by parking
  // `.xterm-helper-textarea` at `left:-9999em`; the instant it's focused iOS
  // scrolls the *visual* viewport to drag that off-screen field into view, which
  // shifts offsetLeft/offsetTop, strands the drawn cursor, and muddies the
  // occlusion test (CROW-1078 #1/#4). The rule (deliberately NOT `!important`,
  // and appended after xterm.css so it wins the parked state on equal
  // specificity) moves only the park. It yields to xterm's own inline left/top —
  // written on cursor-move/render — so the field still tracks the cursor cell; it
  // just never flies to -9999em in between. Offset compensation is intentionally
  // NOT applied: the textarea and the drawn cursor are siblings in the same
  // absolute coordinate space, so they move together under a visual-viewport
  // shift — subtracting `offset*` would de-align them, not align them.
  CrowViewportAddon.prototype._homeTextarea = function () {
    var doc = global.document;
    if (!doc || !doc.head || doc.getElementById('crow-vv-textarea-home')) {
      return;
    }
    var style = doc.createElement('style');
    style.id = 'crow-vv-textarea-home';
    style.textContent = '.xterm .xterm-helper-textarea{left:0;}';
    doc.head.appendChild(style);
  };

  // Repaint the grid so the drawn cursor catches up to a just-changed host inset,
  // and xterm's textarea sync re-runs onto the cell (CROW-1078 #3). A no-op-safe
  // nudge on any renderer; WebGL is not used on touch surfaces (app.js drops it
  // there, #5) precisely because its compositor layer would ignore this.
  CrowViewportAddon.prototype._resyncCursor = function () {
    var term = this._term;
    if (!term || typeof term.refresh !== 'function') {
      return;
    }
    try {
      var rows = (typeof term.rows === 'number' && term.rows > 0) ? term.rows : 1;
      term.refresh(0, rows - 1);
    } catch (_) { /* renderer not ready → the pending fit repaints next frame */ }
  };

  CrowViewportAddon.prototype._refit = function (pin) {
    if (this._onResize) {
      try { this._onResize(); } catch (_) { /* the page's fit is its own problem */ }
    }
    // The host's inset just changed (or was released) — drag the drawn cursor
    // and the IME caret back onto the cell (CROW-1078 #3).
    this._resyncCursor();
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
    if (this._textarea && this._onFocus) {
      this._textarea.removeEventListener('focus', this._onFocus);
    }
    if (this._applied && this._host) {
      this._host.style.height = this._savedHeight;
    }
    // The injected `#crow-vv-textarea-home` <style> is left in place on purpose:
    // it is document-global, id-guarded, inert without an xterm textarea, and a
    // recycled/next terminal on the same document still wants the on-screen park.
    this._applied = false;
    this._keyboardOpen = false;
    this._onChange = null;
    this._onFocus = null;
    this._textarea = null;
    this._pinning = false;
    this._vv = null;
    this._host = null;
    this._term = null;
  };

  // `keyboardCapable` is exported alongside the addon so other surfaces (app.js's
  // WebGL gate, CROW-1078 #5) share this one touch test instead of re-deriving it
  // and drifting — the parity trap this addon exists to avoid.
  global.CrowViewportAddon = {
    CrowViewportAddon: CrowViewportAddon,
    keyboardCapable: function () { return keyboardCapable(global); },
    isAppleTouchDevice: function () { return isAppleTouchDevice(global); },
    applyInteractiveWidgetPolicy: function () { return applyInteractiveWidgetPolicy(global); },
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
