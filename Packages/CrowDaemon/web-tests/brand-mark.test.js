const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// CROW-1469: the animated particle crow (brand-particles.js) in the sidebar and
// the empty state. Runs the REAL classic client under jsdom with a fake WebGL
// context that records every call, and checks the parts that can regress
// silently in a browser:
// - renderSidebar() rebuilds #sidebar wholesale, so the mark must survive it:
//   50 re-renders leave exactly one WebGL context per mounted mark;
// - setColor() recolors in place (palette upload, fallback imgs, favicon);
// - prefers-reduced-motion paints one still, formed frame and stops the loop;
// - marks hold their first frame until the configured color is known;
// - no WebGL → no canvas, the /brand.svg <img> stays.

const epilogue = `
;globalThis.__t = {
  renderSidebar(){ lastSidebarSig = null; renderSidebar(); },
  uiConfig,
  loadUIConfig,
};
`;
const source = loadClientSource() + epilogue;

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

// A recursive no-op proxy: any property read is a callable that records the call
// and returns another proxy; SCREAMING_CASE reads are GL enum constants.
function recorder(log, label) {
  const make = () => new Proxy(function () {}, {
    get(target, k) {
      if (k in target && k !== 'call' && k !== 'apply' && k !== 'bind') return target[k];
      if (typeof k !== 'string') return undefined;
      if (/^[A-Z0-9_]+$/.test(k)) return 1;
      return (...args) => {
        log.push([label, k, args]);
        // Tag uniform locations so a test can tell uMorph from uMin/uMax.
        return k === 'getUniformLocation' ? { uniform: args[1] } : make();
      };
    },
    set(target, k, v) { target[k] = v; return true; },
  });
  return make();
}

function boot({ webgl = true, reducedMotion = false, emptyState = true } = {}) {
  const dom = new JSDOM(
    `<!doctype html><html><head>
       <link rel="icon" type="image/svg+xml" href="/brand.svg">
       <link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png">
       <link rel="apple-touch-icon" href="/apple-touch-icon.png">
     </head><body>
       <div id="sidebar"></div><div id="board"></div><div id="header"></div>
       ${emptyState ? '<div id="detail-empty"><div class="empty-brand brand-mark" id="empty-brand"><img src="/brand.svg" alt=""></div></div>' : ''}
     </body></html>`,
    { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' });
  const { window } = dom;
  window.WebSocket = function () {
    return { send() {}, close() {}, set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
  };
  window.setInterval = () => 0;
  window.setTimeout = () => 0;
  // Manual rAF: the test runs queued frames itself.
  const frames = [];
  window.requestAnimationFrame = (fn) => { frames.push(fn); return frames.length; };
  // The client wires handlers onto index.html nodes this fixture doesn't carry.
  const realGet = window.document.getElementById.bind(window.document);
  window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');
  // A live media query: setReduced() flips it and fires 'change' like the OS toggle.
  const mq = { matches: reducedMotion, listeners: [], addEventListener(_, fn) { this.listeners.push(fn); } };
  window.matchMedia = () => mq;
  const setReduced = (v) => { mq.matches = v; for (const fn of mq.listeners) fn({ matches: v }); };
  // jsdom does no layout: give every element a size so marks can size their canvas.
  Object.defineProperty(window.HTMLElement.prototype, 'clientWidth', { get() { return 120; } });
  Object.defineProperty(window.HTMLElement.prototype, 'clientHeight', { get() { return 120; } });
  const gl = [];
  const contexts = { webgl: 0, '2d': 0 };
  if (webgl) {
    window.WebGLRenderingContext = function () {};
    window.HTMLCanvasElement.prototype.getContext = function (type) {
      contexts[type] = (contexts[type] || 0) + 1;
      return recorder(type === 'webgl' ? gl : [], type);
    };
  } else {
    window.HTMLCanvasElement.prototype.getContext = function (type) {
      contexts[type] = (contexts[type] || 0) + 1;
      return null;
    };
  }
  const ctx = dom.getInternalVMContext();
  try { vm.runInContext(source, ctx, { filename: 'client.js' }); }
  catch (e) { console.log('[load warn]', e.message); }
  const T = ctx.__t;
  if (!T) { console.log('FATAL: epilogue did not run'); process.exit(2); }
  const runFrames = (now) => { const fs = frames.splice(0); for (const f of fs) f(now); return fs.length; };
  return { window, T, gl, contexts, frames, runFrames, setReduced, brand: window.crowBrand };
}

const morphValues = (gl) => gl
  .filter(([, k, a]) => k === 'uniform1f' && a[0] && a[0].uniform === 'uMorph')
  .map(([, , a]) => a[1]);
const draws = (gl) => gl.filter(([, k]) => k === 'drawArrays').length;

console.log('\nSidebar re-render keeps one WebGL context per mark:');
{
  const b = boot();
  check('crowBrand is exposed', !!b.brand && typeof b.brand.mount === 'function');
  const emptyHost = b.window.document.getElementById('empty-brand');
  check('empty state mounted at load (canvas added)', !!emptyHost.querySelector('canvas'));
  b.T.renderSidebar();
  const first = b.window.document.getElementById('brand-img');
  check('sidebar mark rendered as a .brand-mark host', !!first && first.classList.contains('brand-mark'));
  check('not live before the first frame: the /brand.svg img stays up',
    !first.classList.contains('live') && !emptyHost.classList.contains('live')
    && !!first.querySelector('canvas') && !!first.querySelector('img'));
  b.runFrames(1000);
  check('still not live while the color is unknown', !first.classList.contains('live'));
  b.brand.setColor('gold');
  b.runFrames(1000);
  check('live after the first drawn frame (canvas shown, img kept as fallback)',
    first.classList.contains('live') && emptyHost.classList.contains('live'));
  for (let i = 0; i < 50; i++) b.T.renderSidebar();
  const after = b.window.document.getElementById('brand-img');
  check('50 re-renders: still 2 contexts total (sidebar + empty state)', b.contexts.webgl === 2);
  check('50 re-renders: the same host node is re-appended', after === first);
  check('the host holds exactly one canvas', after.querySelectorAll('canvas').length === 1);
  check('mount() is idempotent per host', b.brand.mount(after) === b.brand.mount(after) && b.contexts.webgl === 2);
}

console.log('\nFirst frame waits for the configured color:');
{
  const b = boot();
  b.T.renderSidebar();
  b.runFrames(1000);
  check('no draw before setColor()', draws(b.gl) === 0);
  b.brand.setColor('gold');
  b.runFrames(1000);
  check('draws once the color is known', draws(b.gl) === 2);
  check('motion on: the loop re-arms', b.frames.length === 1);
  // Intro: sphere → crow, so morph starts below 1 and reaches 1 after 2.4 s + delay.
  b.gl.length = 0;
  b.runFrames(1000 + 300 + 1200);
  const mid = morphValues(b.gl).filter((v) => v > 0 && v < 1);
  check('mid-formation: morph between 0 and 1', mid.length > 0);
  b.gl.length = 0;
  b.runFrames(1000 + 300 + 2400 + 50);
  check('formation done: morph back at 1', morphValues(b.gl).includes(1));
}

console.log('\nsetColor() recolors in place:');
{
  const b = boot();
  b.T.renderSidebar();
  b.brand.setColor('gold');
  const doc = b.window.document;
  const sideImg = doc.querySelector('#brand-img img');
  const icon = doc.querySelector('link[rel="icon"][type="image/svg+xml"]');
  check('boot color gold keeps the plain /brand.svg (no refetch)',
    sideImg.getAttribute('src') === '/brand.svg' && icon.getAttribute('href') === '/brand.svg'
    && doc.querySelector('link[rel="icon"][type="image/png"]').getAttribute('href') === '/icon-192.png');
  b.gl.length = 0;
  b.brand.setColor('pink');
  check('color() reports pink', b.brand.color() === 'pink');
  check('palette re-uploaded for both marks', b.gl.filter(([, k]) => k === 'bufferSubData').length === 2);
  check('fallback imgs pinned to ?color=pink',
    sideImg.getAttribute('src') === '/brand.svg?color=pink'
    && doc.querySelector('#empty-brand img').getAttribute('src') === '/brand.svg?color=pink');
  check('favicon follows', icon.getAttribute('href') === '/brand.svg?color=pink');
  check('raster icons untouched (PNG icon, apple-touch-icon)',
    doc.querySelector('link[rel="icon"][type="image/png"]').getAttribute('href') === '/icon-192.png'
    && doc.querySelector('link[rel="apple-touch-icon"]').getAttribute('href') === '/apple-touch-icon.png');
  check('src() for new imgs (About) follows', b.brand.src() === '/brand.svg?color=pink');
  b.gl.length = 0;
  b.brand.setColor('pink');
  check('same color again is a no-op', b.gl.filter(([, k]) => k === 'bufferSubData').length === 0);
  b.brand.setColor('nonsense');
  check('an unknown color falls back to gold', b.brand.color() === 'gold'
    && sideImg.getAttribute('src') === '/brand.svg');
}

console.log('\nloadUIConfig() hands the setting to the mark:');
{
  const b = boot();
  b.window.fetch = async () => ({ ok: false });
  // rpc() is a WebSocket call in the client; stub the one get-config reply.
  b.window.eval(`rpc = async (m) => m === 'get-config'
    ? { config: JSON.stringify({ sidebar: { brandmarkColor: 'pink' } }) } : {};`);
  b.T.loadUIConfig().then(() => {
    check('uiConfig.brandmarkColor = pink', b.T.uiConfig.brandmarkColor === 'pink');
    check('crowBrand recolored to pink', b.brand.color() === 'pink');
    finish();
  });
}

function finish() {
  console.log('\nprefers-reduced-motion: one still frame, no loop:');
  {
    const b = boot({ reducedMotion: true });
    b.T.renderSidebar();
    b.brand.setColor('gold');
    b.runFrames(1000);
    check('both marks drawn', draws(b.gl) === 2);
    check('formed crow (morph 1), no intro', morphValues(b.gl).includes(1)
      && !morphValues(b.gl).some((v) => v > 0 && v < 1));
    check('loop does not re-arm', b.frames.length === 0);
    b.brand.setColor('pink');
    check('a recolor paints one more frame', b.runFrames(2000) === 1 && b.frames.length === 0);
  }

  console.log('\nReduced motion turned on mid-formation settles on the formed crow:');
  {
    const b = boot();
    b.T.renderSidebar();
    b.brand.setColor('gold');
    b.runFrames(1000);
    b.gl.length = 0;
    b.runFrames(1000 + 300 + 1200);
    check('formation in flight', morphValues(b.gl).some((v) => v > 0 && v < 1));
    b.setReduced(true);
    b.gl.length = 0;
    b.runFrames(2600);
    const after = morphValues(b.gl);
    check('next frame draws morph 1, not a half-formed crow', after.length > 0 && after.every((v) => v === 1));
    check('and the loop stops', b.frames.length === 0);
  }

  console.log('\nNo WebGL: the static mark stays:');
  {
    const b = boot({ webgl: false });
    b.T.renderSidebar();
    const host = b.window.document.getElementById('brand-img');
    check('no WebGL context requested', b.contexts.webgl === 0);
    check('no canvas, not live', !host.querySelector('canvas') && !host.classList.contains('live'));
    check('fallback img shows /brand.svg', host.querySelector('img').getAttribute('src') === '/brand.svg');
    check('mount() returns null', b.brand.mount(host) === null);
    b.brand.setColor('gold');
    b.brand.setColor('pink');
    check('fallback img still recolors', host.querySelector('img').getAttribute('src') === '/brand.svg?color=pink');
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
}
