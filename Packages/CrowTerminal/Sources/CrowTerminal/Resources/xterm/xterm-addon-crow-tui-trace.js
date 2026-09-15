// Crow TUI form-factor sampler (CROW-1255), as a shared xterm.js addon.
//
// Collects the three-layer client sample (viewport / cursor / env) that the
// daemon cannot see. Does not open sockets — Start/Stop stay in the page that
// owns /rpc. Classifier is vendored here (do not wait on keyboardCapable() from
// a later worktree): Tauri → desktop even though visualViewport exists
// (CROW-1045); phone/tablet is touch/coarse, not "has visualViewport".
//
// Loaded via <script src> (not ES modules), UMD-style:
// window.CrowTuiTraceAddon.CrowTuiTraceAddon
(function (global) {
  'use strict';

  var KEYBOARD_MIN_OCCLUSION = 120;
  var SAMPLE_HZ = 4;
  var SAMPLE_MS = 1000 / SAMPLE_HZ;
  var COALESCE_FLOOR_MS = 80;

  function inTauri(g) {
    g = g || global;
    return !!(g && g.__TAURI__);
  }

  function pointerCoarse(g) {
    g = g || global;
    var mm = g.matchMedia;
    if (typeof mm === 'function') {
      try {
        var q = mm.call(g, '(pointer: coarse)');
        if (q && q.matches) return true;
      } catch (_) { /* embedded webview */ }
    }
    return false;
  }

  function classifyFormFactor(g) {
    g = g || global;
    if (inTauri(g)) return 'desktop';
    var nav = g.navigator || {};
    var touch = (typeof nav.maxTouchPoints === 'number' && nav.maxTouchPoints > 0) || pointerCoarse(g);
    if (touch) {
      var w = (g.innerWidth || (g.document && g.document.documentElement && g.document.documentElement.clientWidth) || 0);
      return w >= 768 ? 'tablet' : 'phone';
    }
    return 'browser';
  }

  function keyboardInset(g) {
    g = g || global;
    var vv = g.visualViewport;
    if (!vv) return 0;
    var layout = g.innerHeight || 0;
    var inset = layout - vv.height - (vv.offsetTop || 0);
    return inset > 0 ? Math.round(inset) : 0;
  }

  function CrowTuiTraceAddon(options) {
    options = options || {};
    this._term = null;
    this._onSample = typeof options.onSample === 'function' ? options.onSample : null;
    this._events = [];
    this._lastViewportY = 0;
    this._arrivedAtTop = false;
    this._raf = 0;
    this._timer = 0;
    this._lastImmediate = 0;
    this._lastTouch = 0;
    this._active = false;
  }

  CrowTuiTraceAddon.prototype.activate = function (term) {
    this._term = term;
    var buf = term.buffer && term.buffer.active;
    this._lastViewportY = buf ? buf.viewportY : 0;
  };

  CrowTuiTraceAddon.prototype.dispose = function () {
    this.stop();
    this._term = null;
  };

  CrowTuiTraceAddon.prototype.start = function () {
    if (this._active) return;
    this._active = true;
    var self = this;
    this._timer = (global.setInterval || setInterval)(function () {
      self._emit(false);
    }, SAMPLE_MS);
    var vv = global.visualViewport;
    if (vv && typeof vv.addEventListener === 'function') {
      this._onVV = function () { self._scheduleImmediate(); };
      vv.addEventListener('resize', this._onVV);
      vv.addEventListener('scroll', this._onVV);
    }
  };

  CrowTuiTraceAddon.prototype.stop = function () {
    this._active = false;
    if (this._timer) { (global.clearInterval || clearInterval)(this._timer); this._timer = 0; }
    if (this._raf && global.cancelAnimationFrame) global.cancelAnimationFrame(this._raf);
    this._raf = 0;
    var vv = global.visualViewport;
    if (vv && this._onVV && typeof vv.removeEventListener === 'function') {
      vv.removeEventListener('resize', this._onVV);
      vv.removeEventListener('scroll', this._onVV);
    }
    this._onVV = null;
  };

  CrowTuiTraceAddon.prototype.noteEvent = function (ev) {
    if (!ev) return;
    if (ev.kind === 'touchmove') {
      var now = Date.now();
      if (now - this._lastTouch < 100) return; // ≤10 Hz
      this._lastTouch = now;
    }
    this._events.push({
      kind: ev.kind,
      at_client: ev.at_client || Date.now(),
      prevent_default: ev.prevent_default,
      delta: ev.delta,
    });
    if (this._events.length > 8) this._events.shift();
    if (ev.kind === 'mark') {
      this._emit(true);
      return;
    }
    this._scheduleImmediate();
  };

  CrowTuiTraceAddon.prototype.collect = function () {
    return collectTuiSample(this._term, this._takeFlags());
  };

  CrowTuiTraceAddon.prototype._takeFlags = function () {
    var buf = this._term && this._term.buffer && this._term.buffer.active;
    var vy = buf ? buf.viewportY : 0;
    var arrived = vy === 0 && this._lastViewportY !== 0;
    this._lastViewportY = vy;
    var events = this._events.slice();
    this._events = [];
    return { arrivedAtTop: arrived, events: events };
  };

  CrowTuiTraceAddon.prototype._scheduleImmediate = function () {
    var self = this;
    var now = Date.now();
    if (now - this._lastImmediate < COALESCE_FLOOR_MS) {
      if (this._raf) return;
      this._raf = (global.requestAnimationFrame || function (cb) { return setTimeout(cb, COALESCE_FLOOR_MS); })(function () {
        self._raf = 0;
        self._emit(false);
      });
      return;
    }
    this._emit(false);
  };

  CrowTuiTraceAddon.prototype._emit = function (force) {
    if (!this._active && !force) return;
    this._lastImmediate = Date.now();
    if (!this._onSample) return;
    this._onSample(this.collect(), force);
  };

  function collectTuiSample(term, flags) {
    flags = flags || {};
    var g = global;
    var doc = g.document;
    var nav = g.navigator || {};
    var host = (term && term.element && term.element.parentElement) || (doc && doc.getElementById('terminal'));
    var vv = g.visualViewport;
    var cell = cellMetrics(term, host);
    var buf = term && term.buffer && term.buffer.active;
    var cursorX = buf ? buf.cursorX : 0;
    var cursorY = buf ? buf.cursorY : 0;
    var textarea = term && term.textarea;
    var taStyle = textarea && g.getComputedStyle ? g.getComputedStyle(textarea) : null;
    var taLeft = taStyle ? parseFloat(taStyle.left) || 0 : cursorX * cell.w;
    var taTop = taStyle ? parseFloat(taStyle.top) || 0 : cursorY * cell.h;
    var caret = caretCss(term, cell, cursorX, cursorY);
    var lines = visibleLines(buf, term);
    var hash = 'sha256:' + sha256Utf8(lines.join('\n'));
    var inset = keyboardInset(g);
    return {
      t_client: Date.now(),
      form_factor: classifyFormFactor(g),
      hidden: !!(doc && doc.hidden),
      has_focus: !!(doc && typeof doc.hasFocus === 'function' && doc.hasFocus()),
      arrived_at_top: !!flags.arrivedAtTop,
      env: {
        ua: nav.userAgent || '',
        tauri: inTauri(g),
        dpr: g.devicePixelRatio || 1,
        max_touch_points: typeof nav.maxTouchPoints === 'number' ? nav.maxTouchPoints : 0,
        pointer_coarse: pointerCoarse(g),
        webgl: probeWebGL(doc),
        locale: (nav.language || 'en'),
      },
      viewport: {
        inner_w: g.innerWidth || 0,
        inner_h: g.innerHeight || 0,
        client_w: host ? host.clientWidth : 0,
        client_h: host ? host.clientHeight : 0,
        vv_w: vv ? Math.round(vv.width) : null,
        vv_h: vv ? Math.round(vv.height) : null,
        vv_offset_top: vv ? Math.round(vv.offsetTop || 0) : null,
        vv_offset_left: vv ? Math.round(vv.offsetLeft || 0) : null,
        keyboard_inset_px: inset,
        css_cols: term ? term.cols : 0,
        css_rows: term ? term.rows : 0,
        cell_w: cell.w,
        cell_h: cell.h,
      },
      cursor: {
        xterm_x: cursorX,
        xterm_y: cursorY,
        xterm_viewport_y: buf ? buf.viewportY : 0,
        xterm_base_y: buf ? buf.baseY : 0,
        textarea_left_px: taLeft,
        textarea_top_px: taTop,
        caret_css_x: caret.x,
        caret_css_y: caret.y,
      },
      modes: {
        agent_surface: !!(flags.agentSurface),
        buffer_type: buf ? (buf.type || 'normal') : 'normal',
        mouse_tracking: (term && term.modes && term.modes.mouseTrackingMode) || 'none',
        app_owns_scroll: !!flags.appOwnsScroll,
        alt_screen_flag: !!(buf && buf.type === 'alternate'),
      },
      visible_hash: hash,
      visible_rows: term ? term.rows : 0,
      visible_lines: lines,
      events: flags.events || [],
    };
  }

  function cellMetrics(term, host) {
    if (term && typeof term._core !== 'undefined' && term._core._renderService) {
      var d = term._core._renderService.dimensions;
      if (d && d.css && d.css.cell) return { w: d.css.cell.width || 9, h: d.css.cell.height || 18 };
    }
    var cols = (term && term.cols) || 80;
    var rows = (term && term.rows) || 24;
    var w = host ? host.clientWidth : cols * 9;
    var h = host ? host.clientHeight : rows * 18;
    return { w: cols ? w / cols : 9, h: rows ? h / rows : 18 };
  }

  function caretCss(term, cell, cursorX, cursorY) {
    var el = term && term.element;
    if (el && global.document) {
      var node = el.querySelector('.xterm-cursor-layer .xterm-cursor') || el.querySelector('.xterm-cursor');
      if (node && node.getBoundingClientRect) {
        var r = node.getBoundingClientRect();
        var host = el.getBoundingClientRect();
        return { x: r.left - host.left, y: r.top - host.top };
      }
    }
    return { x: cursorX * cell.w, y: cursorY * cell.h };
  }

  function visibleLines(buf, term) {
    if (!buf || typeof buf.getLine !== 'function') return [];
    var rows = (term && term.rows) || 0;
    var y = buf.viewportY || 0;
    var out = [];
    for (var i = 0; i < rows; i++) {
      var line = buf.getLine(y + i);
      if (line && typeof line.translateToString === 'function') out.push(line.translateToString(true));
      else out.push('');
    }
    return out;
  }

  function probeWebGL(doc) {
    try {
      var c = doc && doc.createElement && doc.createElement('canvas');
      if (!c) return false;
      return !!(c.getContext('webgl') || c.getContext('experimental-webgl'));
    } catch (_) { return false; }
  }

  // Compact SHA-256 for greppable hashes. Not a security boundary.
  function sha256Utf8(str) {
    if (global.crypto && global.crypto.subtle && typeof TextEncoder === 'function') {
      // Sync fallback below — subtle is async; we need a sync hash for samples.
    }
    return sha256sync(str);
  }

  function sha256sync(ascii) {
    // FIPS 180-2 SHA-256, adapted for short terminal lines.
    function rrot(n, x) { return (x >>> n) | (x << (32 - n)); }
    var k = [
      0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
      0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
      0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
      0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
      0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
      0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ];
    var utf = unescape(encodeURIComponent(ascii));
    var len = utf.length;
    var words = [];
    for (var i = 0; i < len; i++) words[i >> 2] |= (utf.charCodeAt(i) & 0xff) << (24 - (i % 4) * 8);
    words[len >> 2] |= 0x80 << (24 - (len % 4) * 8);
    words[(((len + 8) >> 6) << 4) + 15] = len * 8;
    var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
    var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;
    for (var j = 0; j < words.length; j += 16) {
      var w = words.slice(j, j + 16);
      for (var t = 16; t < 64; t++) {
        var s0 = rrot(7, w[t-15]) ^ rrot(18, w[t-15]) ^ (w[t-15] >>> 3);
        var s1 = rrot(17, w[t-2]) ^ rrot(19, w[t-2]) ^ (w[t-2] >>> 10);
        w[t] = (w[t-16] + s0 + w[t-7] + s1) | 0;
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
      for (t = 0; t < 64; t++) {
        s1 = rrot(6, e) ^ rrot(11, e) ^ rrot(25, e);
        var ch = (e & f) ^ (~e & g);
        var temp1 = (h + s1 + ch + k[t] + w[t]) | 0;
        s0 = rrot(2, a) ^ rrot(13, a) ^ rrot(22, a);
        var maj = (a & b) ^ (a & c) ^ (b & c);
        var temp2 = (s0 + maj) | 0;
        h = g; g = f; f = e; e = (d + temp1) | 0;
        d = c; c = b; b = a; a = (temp1 + temp2) | 0;
      }
      h0 = (h0 + a) | 0; h1 = (h1 + b) | 0; h2 = (h2 + c) | 0; h3 = (h3 + d) | 0;
      h4 = (h4 + e) | 0; h5 = (h5 + f) | 0; h6 = (h6 + g) | 0; h7 = (h7 + h) | 0;
    }
    function hex(n) { return ('00000000' + (n >>> 0).toString(16)).slice(-8); }
    return hex(h0) + hex(h1) + hex(h2) + hex(h3) + hex(h4) + hex(h5) + hex(h6) + hex(h7);
  }

  var ns = {
    CrowTuiTraceAddon: CrowTuiTraceAddon,
    collectTuiSample: collectTuiSample,
    classifyFormFactor: classifyFormFactor,
    inTauri: inTauri,
    KEYBOARD_MIN_OCCLUSION: KEYBOARD_MIN_OCCLUSION,
  };
  global.CrowTuiTraceAddon = ns;
})(typeof window !== 'undefined' ? window : this);
