'use strict';
const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// CROW-1255: sampler addon + HUD. Classifier is vendored (CROW-1045: visualViewport
// is not "phone"). Detectors stay in Swift — this file locks sampler fields only.
const ADDON_JS =
  __dirname + '/../../CrowTerminal/Sources/CrowTerminal/Resources/xterm/xterm-addon-crow-tui-trace.js';

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };
const eq = (name, a, b) => check(name, JSON.stringify(a) === JSON.stringify(b));

function loadAddon(windowExtras) {
  const dom = new JSDOM('<!doctype html><html><body><div id="terminal"></div><div id="terminal-wrap"></div></body></html>',
    { runScripts: 'outside-only', url: 'http://localhost/' });
  const { window } = dom;
  // jsdom's window.navigator is a getter-only Window property, so
  // Object.assign(window, { navigator }) throws. Patch fields onto the
  // existing Navigator instead.
  const extras = Object.assign({}, windowExtras || {});
  const navPatch = extras.navigator;
  delete extras.navigator;
  Object.assign(window, extras);
  if (navPatch) {
    Object.keys(navPatch).forEach((k) => {
      try {
        Object.defineProperty(window.navigator, k, { configurable: true, value: navPatch[k] });
      } catch (_) { /* jsdom navigator is a getter-only Window property */ }
    });
  }
  window.HTMLCanvasElement.prototype.getContext = function () { return null; };
  const ctx = dom.getInternalVMContext();
  vm.runInContext(fs.readFileSync(ADDON_JS, 'utf8'), ctx, { filename: 'crow-tui-trace.js' });
  return { window, ctx, addon: ctx.CrowTuiTraceAddon };
}

console.log('classifier (CROW-1045: visualViewport is not phone):');
{
  const { addon } = loadAddon();
  eq('Tauri + visualViewport + coarse → desktop', addon.classifyFormFactor({
    __TAURI__: { core: {} },
    visualViewport: { height: 600, offsetTop: 0, width: 390 },
    innerWidth: 390,
    navigator: { maxTouchPoints: 5, userAgent: 'Mozilla', language: 'en' },
    matchMedia: (q) => ({ matches: /coarse/.test(q) }),
  }), 'desktop');
  eq('touch + narrow → phone', addon.classifyFormFactor({
    innerWidth: 390,
    navigator: { maxTouchPoints: 5, userAgent: 'Safari', language: 'en' },
    matchMedia: (q) => ({ matches: /coarse/.test(q) }),
    visualViewport: { height: 500, offsetTop: 0, width: 390 },
  }), 'phone');
  eq('touch + wide → tablet', addon.classifyFormFactor({
    innerWidth: 1024,
    navigator: { maxTouchPoints: 5, userAgent: 'Safari', language: 'en' },
    matchMedia: (q) => ({ matches: /coarse/.test(q) }),
  }), 'tablet');
  eq('no touch → browser', addon.classifyFormFactor({
    innerWidth: 1280,
    navigator: { maxTouchPoints: 0, userAgent: 'Chrome', language: 'en' },
    matchMedia: () => ({ matches: false }),
  }), 'browser');
}

console.log('\nsampler fields + arrived_at_top:');
{
  const { ctx, addon } = loadAddon({
    innerWidth: 390, innerHeight: 800, devicePixelRatio: 2,
    navigator: { maxTouchPoints: 5, userAgent: 'Safari', language: 'en-US' },
    matchMedia: (q) => ({ matches: /coarse/.test(q) }),
  });
  const term = {
    cols: 80, rows: 24, element: ctx.document.getElementById('terminal'),
    textarea: null, modes: { mouseTrackingMode: 'none' },
    buffer: { active: {
      cursorX: 3, cursorY: 7, viewportY: 12, baseY: 4, type: 'alternate',
      getLine: () => ({ translateToString: () => 'line' }),
    } },
  };
  const sample = addon.collectTuiSample(term, { arrivedAtTop: true, events: [] });
  check('form_factor present', typeof sample.form_factor === 'string');
  check('viewport.css_cols', sample.viewport.css_cols === 80);
  check('cursor.xterm_x', sample.cursor.xterm_x === 3);
  check('arrived_at_top flag', sample.arrived_at_top === true);
  check('visible_hash prefixed', String(sample.visible_hash).startsWith('sha256:'));
  check('KEYBOARD_MIN_OCCLUSION', addon.KEYBOARD_MIN_OCCLUSION === 120);
}

console.log('\nvisualViewport resize is rAF-coalesced:');
{
  const { window, ctx, addon } = loadAddon({
    innerWidth: 390, innerHeight: 800,
    navigator: { maxTouchPoints: 5, userAgent: 'Safari', language: 'en' },
    matchMedia: (q) => ({ matches: /coarse/.test(q) }),
  });
  let raf = [];
  window.requestAnimationFrame = (fn) => { raf.push(fn); return raf.length; };
  window.cancelAnimationFrame = () => { raf = []; };
  const vv = {
    height: 800, width: 390, offsetTop: 0,
    addEventListener: (t, fn) => { vv['on' + t] = fn; },
    removeEventListener: () => {},
  };
  window.visualViewport = vv;
  const inst = new addon.CrowTuiTraceAddon({ onSample: () => { samples++; } });
  let samples = 0;
  inst.activate({ cols: 80, rows: 24, buffer: { active: { cursorX: 0, cursorY: 0, viewportY: 0, baseY: 0, getLine: () => null } } });
  inst.start();
  samples = 0;
  vv.onresize();
  vv.onresize();
  vv.onresize();
  check('coalesce queues at most one rAF', raf.length <= 1);
  raf.forEach((fn) => fn());
  check('coalesced burst is not a sample storm', samples <= 2);
  inst.stop();
}

console.log('\nHUD-on without bind sends zero samples / marks / resizes:');
{
  const dom = new JSDOM(`<!doctype html><html><body>
    <div id="app"><div id="detail">
      <div id="terminal-wrap" style="position:relative"><div id="terminal"></div></div>
      <div id="detail-recordings"></div>
    </div></div>
  </body></html>`, { runScripts: 'outside-only', url: 'http://localhost/' });
  const { window } = dom;
  const sent = [];
  window.WebSocket = function () {};
  window.WebSocket.OPEN = 1;
  window.setInterval = () => 0;
  window.clearInterval = () => {};
  window.requestAnimationFrame = (fn) => { fn(); return 1; };
  window.cancelAnimationFrame = () => {};
  window.HTMLCanvasElement.prototype.getContext = function () { return null; };
  const ctx = dom.getInternalVMContext();
  vm.runInContext(fs.readFileSync(ADDON_JS, 'utf8'), ctx, { filename: 'crow-tui-trace.js' });
  try { vm.runInContext(loadClientSource(), ctx, { filename: 'client.js' }); }
  catch (e) { console.log('[load warn]', e.message); }
  vm.runInContext(`
    term = {
      cols: 80, rows: 24, loadAddon: function () {},
      buffer: { active: { cursorX: 0, cursorY: 0, viewportY: 0, baseY: 0, type: 'normal',
        getLine: function () { return { translateToString: function () { return ''; } }; } } },
      element: document.getElementById('terminal'),
      textarea: null, modes: { mouseTrackingMode: 'none' },
    };
    termWs = { readyState: WebSocket.OPEN, send: function (s) { globalThis.__tuiSent.push(s); } };
    selectedId = 'sess';
    activeTerminal = { id: 'term' };
    globalThis.__tuiSent = [];
  `, ctx);
  ctx.__tuiSent = sent;
  vm.runInContext('globalThis.__tuiSent = []; tuiToggleHud();', ctx);
  const payloads = ctx.__tuiSent || [];
  check('HUD toggle sent nothing', payloads.length === 0);
  check('no resize frame', payloads.every((p) => p.indexOf('"resize"') === -1));
  check('no tui-sample', payloads.every((p) => p.indexOf('tui-sample') === -1));
  check('no tui-mark', payloads.every((p) => p.indexOf('tui-mark') === -1));
  const hud = window.document.getElementById('tui-hud');
  check('HUD overlay exists', !!hud);
  const wrap = window.document.getElementById('terminal-wrap');
  const style = window.getComputedStyle ? window.getComputedStyle(hud) : { position: 'absolute' };
  // jsdom may not apply app.css; pin the stylesheet contract separately below.
  check('HUD node is inside #terminal-wrap', hud && hud.parentElement === wrap);
}

console.log('\nnot_active clears sessionStorage:');
{
  const { window, ctx } = loadAddon({});
  vm.runInContext(fs.readFileSync(ADDON_JS, 'utf8'), ctx, { filename: 'crow-tui-trace.js' });
  try { vm.runInContext(loadClientSource(), ctx, { filename: 'client.js' }); }
  catch (e) { /* client may already be partially defined when addon-only world */ }
  vm.runInContext(`
    sessionStorage.setItem('crow.tui.recording', JSON.stringify({ recording_id: 'rec-1' }));
    selectedId = 'other';
    onTuiRecordEvent({ kind: 'not_active', recording_id: 'rec-1' });
  `, ctx);
  const stored = ctx.sessionStorage.getItem('crow.tui.recording');
  check('sessionStorage cleared on not_active', stored == null || stored === 'null');
}

console.log('\nplayback path does not fetch().text() the whole file:');
{
  const src = fs.readFileSync(__dirname + '/../Sources/CrowDaemon/Resources/web/tui-record.js', 'utf8');
  check('uses getReader sliding window', src.includes('getReader') && src.includes('res.body'));
  check('never response.text() the pty file', !src.includes('response.text()') && !src.includes('res.text()'));
  check('openTuiPlayback exported', src.includes('window.openTuiPlayback'));
}

console.log('\nHUD CSS does not change FitAddon geometry:');
{
  const css = fs.readFileSync(__dirname + '/../Sources/CrowDaemon/Resources/web/app.css', 'utf8');
  check('#tui-hud is position:absolute', /#tui-hud\s*\{[^}]*position:\s*absolute/.test(css));
  check('#tui-hud pointer-events none', /#tui-hud\s*\{[^}]*pointer-events:\s*none/.test(css));
}

console.log('\nHUD keyboard_inset_px includes accessory height (CROW-1263):');
{
  const { window, addon } = loadAddon({ innerWidth: 1024, innerHeight: 800 });
  Object.defineProperty(window.document.documentElement, 'clientHeight', {
    value: 800, configurable: true,
  });
  window.visualViewport = { height: 412, offsetTop: 388, width: 1024 };
  const term = {
    cols: 80, rows: 24, element: window.document.getElementById('terminal'),
    textarea: null, modes: { mouseTrackingMode: 'none' },
    buffer: { active: {
      cursorX: 0, cursorY: 0, viewportY: 0, baseY: 0, type: 'normal',
      getLine: () => ({ translateToString: () => '' }),
    } },
  };
  const sample = addon.collectTuiSample(term, { events: [] });
  // 800 - 412 = 388 (keyboard + two ~44px bars). Subtracting offsetTop would
  // have reported 0 — the CROW-1078 #4 false negative for the HUD.
  check('inset is layout - vv.height, not chased away by offsetTop',
    sample.viewport.keyboard_inset_px === 388);
}

if (fail) {
  console.log('\n' + fail + ' failed, ' + pass + ' passed');
  process.exit(1);
}
console.log('\n' + pass + ' passed');
