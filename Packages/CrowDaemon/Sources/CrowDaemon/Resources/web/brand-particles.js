'use strict';
// Animated particle crow brandmark (CROW-1469).
//
// A trimmed port of corveil.com's particle engine
// (corveil/corveil marketing/redesign/assets/js/particles.js): WebGL points,
// additive blending, a soft radial sprite and the same breathing motion, plus a
// `crow` formation built from brand-points.js. On first sight the dots form from
// the site's golden-angle sphere into the crow (quintic ease, 2.4 s), then the
// mark breathes and sways.
//
// Shape of the integration:
// - A mark lives in a host element that also holds an <img> of /brand.svg. The
//   img is the fallback: it stays visible until WebGL is up, and comes back if
//   there is no WebGL or the context is lost.
// - mount(host) is idempotent per host. The sidebar is rebuilt wholesale by
//   renderSidebar(), so sidebar.js keeps one host node and re-appends it rather
//   than mounting a new canvas (and a new WebGL context) on every render.
// - One requestAnimationFrame loop drives every mark. It only runs while some
//   mark is on screen (IntersectionObserver) and stops itself otherwise.
// - prefers-reduced-motion: the formed crow, drawn once, no loop.
// - setColor('gold'|'pink') recolors in place: the WebGL palette, the fallback
//   imgs, the favicon and any other `img[data-brand-static]`.
(function () {
  // Crow's accent (app.css --gold-dark #B38E46 → --gold #DDC482) and Corveil's
  // pink ramp (#E60073 → #FF4AA2, from particles.js). Bottom → top of the bird.
  const PALETTES = {
    gold: [[179 / 255, 142 / 255, 70 / 255], [221 / 255, 196 / 255, 130 / 255]],
    pink: [[230 / 255, 0, 115 / 255], [1, 74 / 255, 162 / 255]],
  };
  // The approved preview's "In Crow" tuning for the 96–120 px marks.
  const OPTS = { fill: 0.92, px: 0.30, min: 0.12, max: 0.75, minOp: 0.65, maxOp: 1, amp: 0.03, sway: 0.25 };
  const CROW_SCALE = 2.6, SPHERE_R = 2.5, FOV = 60;
  const INTRO_DELAY_MS = 300, INTRO_MS = 2400;

  const marks = new Set();
  let raf = 0;
  let color = 'gold';
  // The color the plain /brand.svg URL was first decoded in. The server picks
  // that file from the setting, so once the setting moves the plain URL would
  // keep showing the old image; srcFor() pins the new color with ?color=.
  let pageColor = null;
  // Marks hold their first frame until the configured color is known, so a pink
  // setting doesn't open with a gold formation. loadUIConfig() calls setColor()
  // whether or not the config load succeeds; the timeout covers anything else.
  let colorKnown = false;
  setTimeout(() => { if (!colorKnown) { colorKnown = true; kick(); } }, 2000);

  const motionQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  function motionOK() { return !(motionQuery && motionQuery.matches); }
  if (motionQuery && motionQuery.addEventListener) {
    motionQuery.addEventListener('change', () => { for (const m of marks) m.anim = null; kick(); });
  }

  function hash(i, salt, k) { const x = Math.sin((i + 1) * 12.9898 + salt * 78.233 + k * 37.719) * 43758.5453; return x - Math.floor(x); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function clamp01(v) { return v < 0 ? 0 : v > 1 ? 1 : v; }
  function quintic(t) { return t * t * t * (t * (t * 6 - 15) + 10); }

  function sphere(out, n) {
    for (let i = 0; i < n; i++) {
      const y = 1 - (i / Math.max(1, n - 1)) * 2, r = Math.sqrt(Math.max(0, 1 - y * y)), th = Math.PI * (1 + Math.sqrt(5)) * i;
      out[i * 3] = Math.cos(th) * r * SPHERE_R; out[i * 3 + 1] = y * SPHERE_R; out[i * 3 + 2] = Math.sin(th) * r * SPHERE_R;
    }
    return out;
  }
  function crow(out, pts, n) {
    for (let i = 0; i < n; i++) {
      const d = pts[i * 4 + 2];
      out[i * 3] = pts[i * 4] * CROW_SCALE;
      out[i * 3 + 1] = pts[i * 4 + 1] * CROW_SCALE;
      out[i * 3 + 2] = (hash(i, 7, 0) - 0.5) * (0.25 + 0.5 * d); // thin body depth, so the sway reads
    }
    return out;
  }
  // The site's soft round sprite: a white radial falloff, alpha 1 → 0.8 at
  // 40% of the radius → 0 at the edge. Built as raw RGBA, so there's no 2D
  // canvas and no color literal (the dot color comes from aColor).
  const SPRITE = 64;
  function sprite() {
    const px = new Uint8Array(SPRITE * SPRITE * 4), h = SPRITE / 2;
    for (let y = 0; y < SPRITE; y++) {
      for (let x = 0; x < SPRITE; x++) {
        const r = Math.hypot(x + 0.5 - h, y + 0.5 - h) / h;
        const a = r < 0.4 ? 1 - 0.5 * r : 0.8 * clamp01((1 - r) / 0.6);
        const o = (y * SPRITE + x) * 4;
        px[o] = px[o + 1] = px[o + 2] = 255; px[o + 3] = Math.round(a * 255);
      }
    }
    return px;
  }

  // The site's vertex shader, with a per-canvas pixel scale in place of 300.
  const VERT = [
    'attribute vec3 aFrom; attribute vec3 aTo; attribute float aSize; attribute float aPhase; attribute float aFreq; attribute float aOpacity; attribute vec3 aColor;',
    'uniform mat4 uP; uniform mat4 uMV; uniform float uTime; uniform float uMorph; uniform float uMin; uniform float uMax; uniform float uAmp; uniform float uPx;',
    'varying float vO; varying vec3 vC;',
    'void main(){ vec3 p = mix(aFrom, aTo, uMorph);',
    ' p += vec3(sin(uTime*aFreq+aPhase), cos(uTime*aFreq*0.7+aPhase*1.3), sin(uTime*aFreq*0.5+aPhase*0.8)) * uAmp;',
    ' vec4 mv = uMV * vec4(p,1.0); gl_PointSize = mix(uMin,uMax,aSize) * (uPx / max(0.001,-mv.z));',
    ' gl_Position = uP * mv; vO = aOpacity; vC = aColor; }',
  ].join('\n');
  const FRAG = 'precision mediump float; uniform sampler2D uS; varying float vO; varying vec3 vC; void main(){ vec4 t = texture2D(uS, gl_PointCoord); gl_FragColor = vec4(vC, t.a*vO); }';

  function persp(fovy, asp, n, f) { const t = 1 / Math.tan(fovy * Math.PI / 360), nf = 1 / (n - f); return [t / asp, 0, 0, 0, 0, t, 0, 0, 0, 0, (f + n) * nf, -1, 0, 0, 2 * f * n * nf, 0]; }
  function modelView(z, ry, rx) {
    const cy = Math.cos(ry), sy = Math.sin(ry), cx = Math.cos(rx), sx = Math.sin(rx);
    return [cy, 0, -sy, 0, sy * sx, cx, cy * sx, 0, sy * cx, -sx, cy * cx, 0, 0, 0, -z, 1];
  }

  // The fallback/static URL for `c`. Plain /brand.svg while `c` is the color
  // the page first saw, so no img refetches (or blinks) at boot.
  function srcFor(c) { return (pageColor === null || c === pageColor) ? '/brand.svg' : '/brand.svg?color=' + c; }

  class Mark {
    // Returns with `this.gl` null when WebGL is unavailable; the caller drops it.
    constructor(host) {
      this.host = host;
      this.gl = null;
      const pts = window.CROW_BRAND_POINTS;
      if (!pts || !pts.length || typeof window.WebGLRenderingContext === 'undefined') return;
      const cv = document.createElement('canvas');
      cv.setAttribute('aria-hidden', 'true');
      let gl = null;
      try { gl = cv.getContext('webgl', { alpha: true, antialias: true, premultipliedAlpha: true }); } catch (_) { gl = null; }
      if (!gl) return;
      const n = Math.floor(pts.length / 4);
      const sh = (t, s) => { const x = gl.createShader(t); gl.shaderSource(x, s); gl.compileShader(x); return x; };
      const pr = gl.createProgram();
      gl.attachShader(pr, sh(gl.VERTEX_SHADER, VERT)); gl.attachShader(pr, sh(gl.FRAGMENT_SHADER, FRAG));
      gl.linkProgram(pr);
      if (gl.getProgramParameter && !gl.getProgramParameter(pr, gl.LINK_STATUS)) return;
      gl.useProgram(pr);
      this.gl = gl; this.cv = cv; this.n = n; this.pts = pts;
      this.crowPos = crow(new Float32Array(n * 3), pts, n);
      this.spherePos = sphere(new Float32Array(n * 3), n);

      const size = new Float32Array(n), phase = new Float32Array(n), freq = new Float32Array(n), op = new Float32Array(n);
      for (let i = 0; i < n; i++) {
        const d = pts[i * 4 + 2], b = pts[i * 4 + 3], r = hash(i, 9, 0);
        // Bright, dense regions carry the big soft bokeh dots of the original.
        size[i] = clamp01(0.08 + 0.55 * Math.pow(b, 1.4) * (0.4 + 0.6 * r) + (d > 0.55 && r > 0.93 ? 0.45 : 0));
        phase[i] = hash(i, 9, 1) * Math.PI * 2; freq[i] = 0.5 + hash(i, 9, 2) * 1.5;
        op[i] = lerp(OPTS.minOp, OPTS.maxOp, hash(i, 9, 3));
      }
      this.col = new Float32Array(n * 3);
      this.loc = {};
      for (const a of ['aFrom', 'aTo', 'aSize', 'aPhase', 'aFreq', 'aOpacity', 'aColor']) this.loc[a] = gl.getAttribLocation(pr, a);
      for (const u of ['uP', 'uMV', 'uTime', 'uMorph', 'uMin', 'uMax', 'uAmp', 'uPx', 'uS']) this.loc[u] = gl.getUniformLocation(pr, u);
      const buf = (data, attr, sz) => {
        const bb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, bb); gl.bufferData(gl.ARRAY_BUFFER, data, gl.DYNAMIC_DRAW);
        gl.enableVertexAttribArray(this.loc[attr]); gl.vertexAttribPointer(this.loc[attr], sz, gl.FLOAT, false, 0, 0); return bb;
      };
      this.bFrom = buf(this.crowPos, 'aFrom', 3); this.bTo = buf(this.crowPos, 'aTo', 3);
      buf(size, 'aSize', 1); buf(phase, 'aPhase', 1); buf(freq, 'aFreq', 1); buf(op, 'aOpacity', 1);
      this.bCol = buf(this.col, 'aColor', 3);
      this.setPalette(color);
      const tx = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tx);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, SPRITE, SPRITE, 0, gl.RGBA, gl.UNSIGNED_BYTE, sprite());
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.uniform1i(this.loc.uS, 0);
      gl.disable(gl.DEPTH_TEST); gl.enable(gl.BLEND); gl.blendFunc(gl.SRC_ALPHA, gl.ONE); gl.clearColor(0, 0, 0, 0);
      gl.uniform1f(this.loc.uMin, OPTS.min); gl.uniform1f(this.loc.uMax, OPTS.max);

      this.morph = 1; this.anim = null; this.introPending = true;
      this.visible = !('IntersectionObserver' in window); // assume on screen without IO
      this.sized = false;
      cv.addEventListener('webglcontextlost', (e) => { e.preventDefault(); this.lose(); });
      host.appendChild(cv);
      host.classList.add('live');
      if ('IntersectionObserver' in window) {
        this.io = new IntersectionObserver((entries) => {
          this.visible = entries[entries.length - 1].isIntersecting;
          if (this.visible) { this.sized = false; kick(); }
        }, { threshold: 0.01 });
        this.io.observe(host);
      }
      if ('ResizeObserver' in window) {
        this.ro = new ResizeObserver(() => { this.sized = false; kick(); });
        this.ro.observe(host);
      }
    }

    // Context gone: back to the static img for good, and out of the loop.
    lose() {
      this.gl = null;
      this.host.classList.remove('live');
      if (this.io) this.io.disconnect();
      if (this.ro) this.ro.disconnect();
      marks.delete(this);
    }

    resize() {
      const gl = this.gl, w = this.host.clientWidth, h = this.host.clientHeight;
      if (!w || !h) return false; // display:none or detached — try again when it shows
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      this.cv.width = Math.max(1, Math.round(w * dpr)); this.cv.height = Math.max(1, Math.round(h * dpr));
      gl.viewport(0, 0, this.cv.width, this.cv.height);
      this.camZ = (CROW_SCALE / OPTS.fill) / Math.tan(FOV * Math.PI / 360);
      gl.uniformMatrix4fv(this.loc.uP, false, persp(FOV, w / h, 0.1, 100));
      gl.uniform1f(this.loc.uPx, this.cv.height * OPTS.px);
      this.sized = true;
      return true;
    }

    setPalette(name) {
      const pal = name === 'pink' ? PALETTES.pink : PALETTES.gold, pts = this.pts, col = this.col, gl = this.gl;
      for (let i = 0; i < this.n; i++) {
        const ct = clamp01((pts[i * 4 + 1] + 1) / 2);
        for (let k = 0; k < 3; k++) col[i * 3 + k] = lerp(pal[0][k], pal[1][k], ct);
      }
      gl.bindBuffer(gl.ARRAY_BUFFER, this.bCol); gl.bufferSubData(gl.ARRAY_BUFFER, 0, col);
    }

    // Morph sphere → crow after `delay` ms (the site's quintic ease).
    formFromSphere(now, delay) {
      const gl = this.gl;
      gl.bindBuffer(gl.ARRAY_BUFFER, this.bFrom); gl.bufferSubData(gl.ARRAY_BUFFER, 0, this.spherePos);
      this.morph = 0; this.anim = { t0: now + delay, dur: INTRO_MS };
    }

    draw(now, motion) {
      const gl = this.gl;
      if (!this.sized && !this.resize()) return;
      if (this.introPending) {
        this.introPending = false;
        if (motion) this.formFromSphere(now, INTRO_DELAY_MS);
      }
      if (this.anim) {
        if (!motion) { this.anim = null; this.morph = 1; } else {
          const k = clamp01((now - this.anim.t0) / this.anim.dur);
          this.morph = quintic(k);
          if (k >= 1) { this.anim = null; this.morph = 1; }
        }
      }
      const t = now * 0.001;
      const ry = motion ? Math.sin(t * 0.25) * OPTS.sway + (1 - this.morph) * 1.4 : 0;
      const rx = motion ? Math.sin(t * 0.1) * 0.08 : 0;
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.uniformMatrix4fv(this.loc.uMV, false, modelView(this.camZ, ry, rx));
      gl.uniform1f(this.loc.uTime, motion ? t : 0);
      gl.uniform1f(this.loc.uMorph, this.morph);
      gl.uniform1f(this.loc.uAmp, motion ? OPTS.amp : 0);
      gl.drawArrays(gl.POINTS, 0, this.n);
    }
  }

  // One loop for every mark. Re-arms only while motion is on and some mark is
  // on screen; with reduced motion each kick() paints one still frame.
  function frame(now) {
    raf = 0;
    if (!colorKnown) return;
    const motion = motionOK();
    let drew = false;
    for (const m of marks) {
      if (!m.gl || !m.visible || !m.host.isConnected) continue;
      m.draw(now, motion);
      drew = true;
    }
    if (drew && motion) raf = requestAnimationFrame(frame);
  }
  function kick() {
    if (!raf && marks.size && typeof requestAnimationFrame === 'function') raf = requestAnimationFrame(frame);
  }

  const byHost = new WeakMap();
  function mount(host) {
    if (!host) return null;
    if (byHost.has(host)) return byHost.get(host);
    const img = host.querySelector('img');
    if (img) img.setAttribute('data-brand-static', '');
    const m = new Mark(host);
    const live = m.gl ? m : null;
    byHost.set(host, live); // a failed mount stays failed: no retry loop of new contexts
    if (live) { marks.add(live); kick(); }
    return live;
  }

  function setColor(name) {
    const next = name === 'pink' ? 'pink' : 'gold';
    if (pageColor === null) pageColor = next;
    const changed = next !== color || !colorKnown;
    color = next;
    colorKnown = true;
    if (!changed) return;
    for (const m of marks) if (m.gl) m.setPalette(color);
    const src = srcFor(color);
    for (const im of document.querySelectorAll('img[data-brand-static]')) {
      if (im.getAttribute('src') !== src) im.setAttribute('src', src);
    }
    for (const link of document.querySelectorAll('link[rel="icon"]')) {
      if (link.getAttribute('href') !== src) link.setAttribute('href', src);
    }
    kick();
  }

  window.crowBrand = {
    mount,
    setColor,
    color: () => color,
    // The /brand.svg URL for the current color, for imgs made after boot.
    src: () => srcFor(color),
  };

  // The empty-state mark ships in index.html; the sidebar's is built by sidebar.js.
  const empty = document.getElementById('empty-brand');
  if (empty) mount(empty);
})();
