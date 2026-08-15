const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-988 regression: the visual-viewport fit addon. Drives the real
// xterm-addon-crow-viewport.js (served to the web UI at /xterm/…) against a fake
// visualViewport, a fake xterm and a controllable rAF, so the geometry maths and
// the "leave every non-phone surface alone" guards are pinned without a device.
// CROW-1045 adds the desktop-WKWebView guard: `visualViewport` presence is not a
// keyboard, so a non-touch surface must stay fully inert (case 1b).
const ADDON_JS =
  __dirname + '/../../CrowTerminal/Sources/CrowTerminal/Resources/xterm/xterm-addon-crow-viewport.js';

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

const LAYOUT_HEIGHT = 800; // layout viewport — unchanged by an iOS keyboard
const HOST_TOP = 120;      // the web app's terminal sits below header + tabbar

// A fresh world per case: the addon holds module-free per-instance state, but
// each test wants its own listener set, rAF queue and host element.
function makeWorld({ hasVisualViewport = true, hostTop = HOST_TOP, keyboardCapable = true } = {}) {
  const dom = new JSDOM('<!doctype html><html><body><div id="host"></div></body></html>',
    { runScripts: 'outside-only', url: 'http://localhost/' });
  const { window } = dom;

  // CROW-1045: the addon now gates on a keyboard-capable surface (touch), not
  // merely `visualViewport` presence — a desktop WKWebView exposes visualViewport
  // but has no software keyboard. jsdom implements neither `matchMedia` nor a
  // non-zero `maxTouchPoints`, so it reads as desktop by default; hand it a
  // `matchMedia` that answers `(pointer: coarse)` to model a phone/tablet. The
  // one desktop case flips this off to prove the addon stays wholly inert.
  window.matchMedia = (q) => ({ media: q, matches: keyboardCapable && /coarse/.test(q) });

  // rAF we drive by hand. Callbacks registered DURING a flush land in the next
  // one, matching the browser — the addon relies on that to pin the prompt only
  // after the page's own (frame-coalesced) refit has landed.
  let queue = [];
  window.requestAnimationFrame = (fn) => { queue.push(fn); return queue.length; };
  const flush = () => { const due = queue; queue = []; due.forEach((fn) => fn()); };
  const frames = () => queue.length;

  const listeners = {};
  const vv = {
    height: LAYOUT_HEIGHT,
    offsetTop: 0,
    addEventListener: (t, fn) => { (listeners[t] = listeners[t] || []).push(fn); },
    removeEventListener: (t, fn) => {
      listeners[t] = (listeners[t] || []).filter((f) => f !== fn);
    },
  };
  if (hasVisualViewport) window.visualViewport = vv;

  Object.defineProperty(window.document.documentElement, 'clientHeight',
    { value: LAYOUT_HEIGHT, configurable: true });

  const host = window.document.getElementById('host');
  host.getBoundingClientRect = () => ({ top: hostTop, bottom: LAYOUT_HEIGHT, height: 0 });
  // jsdom has no layout, so clientHeight is 0 for everything — the addon reads it
  // to tell "hidden" from "laid out", so give it a real box by default.
  let clientHeight = LAYOUT_HEIGHT - hostTop;
  Object.defineProperty(host, 'clientHeight', {
    get: () => clientHeight, configurable: true,
  });

  const ctx = dom.getInternalVMContext();
  vm.runInContext(fs.readFileSync(ADDON_JS, 'utf8'), ctx, { filename: 'crow-viewport.js' });

  // Fake terminal: `term.element.parentElement` is the container passed to
  // term.open(), which is what the addon defaults its host to.
  const element = window.document.createElement('div');
  host.appendChild(element);
  const scrolls = [];
  const resizes = [];
  const term = {
    element,
    buffer: { active: { viewportY: 10, baseY: 10 } }, // at the live edge
    scrollToBottom: () => scrolls.push(1),
  };

  const addon = new ctx.CrowViewportAddon.CrowViewportAddon({
    onResize: () => resizes.push(1),
  });

  // Fire what iOS fires, then settle the frame(s) the addon schedules.
  const emit = (type = 'resize') => {
    (listeners[type] || []).forEach((fn) => fn());
    flush();
  };

  return {
    window, vv, host, term, addon, scrolls, resizes, listeners, flush, frames, emit,
    activate: () => addon.activate(term),
    height: () => host.style.height,
    // A keyboard of `px`, iOS-style: visual viewport shrinks, layout does not.
    keyboard: (px) => { vv.height = LAYOUT_HEIGHT - px; },
    // `display: none` — the web app hides the terminal while a board is open.
    hide: () => { clientHeight = 0; },
    show: () => { clientHeight = LAYOUT_HEIGHT - hostTop; },
  };
}

// ---- 1. No visualViewport → the page is left exactly as it was --------------
{
  console.log('no visualViewport');
  const w = makeWorld({ hasVisualViewport: false });
  w.activate();
  check('registers no listeners', Object.keys(w.listeners).length === 0);
  check('schedules no frames', w.frames() === 0);
  check('writes no inline height', w.height() === '');
  check('dispose is safe', (() => { try { w.addon.dispose(); return true; } catch (_) { return false; } })());
}

// ---- 1b. Desktop WKWebView (has visualViewport, no keyboard) → inert ---------
// CROW-1045 regression: the macOS desktop app is a WKWebView that exposes
// `visualViewport` just like a phone, and under viewport-fit=cover its layout
// viewport can outrun the visible height enough to look like a keyboard. With no
// software keyboard on the surface, the addon must not act on that — it has to
// be as inert as the no-visualViewport case, or it shrinks a full-height grid
// and strands a dead band below it.
{
  console.log('desktop WKWebView (no software keyboard)');
  const w = makeWorld({ keyboardCapable: false });
  w.activate();
  check('registers no listeners', Object.keys(w.listeners).length === 0);
  check('schedules no frames', w.frames() === 0);
  // A keyboard-sized occlusion that WOULD size the host on a phone…
  w.keyboard(300);
  w.emit();       // no subscription, so nothing runs — asserted for intent
  check('writes no inline height', w.height() === '');
  check('asks for no refit', w.resizes.length === 0);
  check('dispose is safe', (() => { try { w.addon.dispose(); return true; } catch (_) { return false; } })());
}

// ---- 2. Browser chrome only → still inert ----------------------------------
{
  console.log('browser chrome (sub-threshold occlusion)');
  const w = makeWorld();
  w.activate();
  w.keyboard(60); // iOS Safari's collapsing toolbars, not a keyboard
  w.emit();
  check('subscribes to resize and scroll',
    (w.listeners.resize || []).length === 1 && (w.listeners.scroll || []).length === 1);
  check('writes no inline height', w.height() === '');
  check('asks for no refit', w.resizes.length === 0);
}

// ---- 3. Keyboard opens → host reaches the visible bottom, prompt pinned -----
{
  console.log('keyboard opens');
  const w = makeWorld();
  w.activate();
  w.keyboard(300);
  w.emit();
  // Visible bottom is 800-300 = 500 in layout coords; the host starts at 120.
  check('host sized to the visible bottom', w.height() === '380px');
  check('asks the page to refit', w.resizes.length === 1);
  check('does not pin before the refit lands', w.scrolls.length === 0);
  w.flush(); // the frame the addon deferred the pin to
  check('pins the prompt one frame later', w.scrolls.length === 1);

  // A repeat event with identical geometry must not storm the PTY with a
  // same-size SIGWINCH.
  w.emit();
  check('no-ops an unchanged geometry', w.resizes.length === 1);
}

// ---- 4. Rotation with the keyboard open → recomputed ------------------------
{
  console.log('rotation with the keyboard open');
  const w = makeWorld();
  w.activate();
  w.keyboard(300);
  w.emit();
  w.flush();
  w.keyboard(200); // landscape keyboard is shorter
  w.emit();
  check('host resized to the new visible bottom', w.height() === '480px');
  check('refit again', w.resizes.length === 2);
  w.flush();
  check('re-pins (user was at the live edge)', w.scrolls.length === 2);
}

// ---- 5. Scrolled-up user keeps their place ---------------------------------
{
  console.log('scrolled-up user, keyboard already open');
  const w = makeWorld();
  w.activate();
  w.keyboard(300);
  w.emit();
  w.flush();
  check('opening pinned once', w.scrolls.length === 1);
  w.term.buffer.active.viewportY = 3; // scrolled back through history
  w.keyboard(260);
  w.emit();
  w.flush();
  check('refit happened', w.resizes.length === 2);
  check('but the viewport was left alone', w.scrolls.length === 1);
}

// ---- 6. Keyboard closes → CSS takes back over -------------------------------
{
  console.log('keyboard closes');
  const w = makeWorld();
  w.host.style.height = '55%'; // a pre-existing inline height must survive
  w.activate();
  w.keyboard(300);
  w.emit();
  check('overrides while open', w.height() === '380px');
  w.keyboard(0);
  w.emit();
  check('restores the height it found', w.height() === '55%');
  check('refits on the way back', w.resizes.length === 2);
  w.emit();
  check('stays quiet once restored', w.resizes.length === 2);
}

// ---- 7. offsetTop is added, not subtracted ---------------------------------
{
  console.log('shifted visual viewport');
  const w = makeWorld();
  w.activate();
  w.vv.height = 400;
  w.vv.offsetTop = 50; // visible band is [50, 450) inside an 800px layout
  w.emit();
  check('host reaches offsetTop + height', w.height() === '330px'); // 450 - 120
}

// ---- 8. A host with no layout box is never sized ---------------------------
{
  console.log('hidden host (board open over the terminal)');
  const w = makeWorld();
  w.activate();
  w.hide();
  w.keyboard(300);
  w.emit();
  check('no height stranded on a hidden host', w.height() === '');
  check('no refit asked for', w.resizes.length === 0);

  // Releasing stays unconditional: hiding the terminal mid-keyboard must not
  // strand the override, so the restore path has to run on a hidden host too.
  w.show();
  w.emit();
  check('sizes once it has a box again', w.height() === '380px');
  w.hide();
  w.keyboard(0);
  w.emit();
  check('released even though the host is hidden', w.height() === '');
}

// ---- 9. dispose unwinds everything -----------------------------------------
{
  console.log('dispose');
  const w = makeWorld();
  w.activate();
  w.keyboard(300);
  w.emit();
  check('applied before dispose', w.height() === '380px');
  w.addon.dispose();
  check('inline height released', w.height() === '');
  check('listeners removed',
    (w.listeners.resize || []).length === 0 && (w.listeners.scroll || []).length === 0);
  // A frame already in flight must not touch a disposed terminal.
  w.flush();
  check('no pin after dispose', w.scrolls.length === 0);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
