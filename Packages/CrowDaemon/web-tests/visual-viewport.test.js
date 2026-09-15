const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-988 regression: the visual-viewport fit addon. Drives the real
// xterm-addon-crow-viewport.js (served to the web UI at /xterm/…) against a fake
// visualViewport, a fake xterm and a controllable rAF, so the geometry maths and
// the "leave every non-phone surface alone" guards are pinned without a device.
// CROW-1045 adds the desktop-WKWebView guard: `visualViewport` presence is not a
// keyboard, so a non-touch surface must stay fully inert (case 1b).
// CROW-1078 adds the cursor reconciliation: re-home the off-screen helper
// textarea so iOS stops chasing it (cases 10, 11), keep the keyboard-presence
// test independent of a chased visual-viewport scroll (case 12), and repaint the
// cursor when the inset changes (case 13). keyboardCapable is exported and shared
// with app.js's WebGL gate (case 14).
// CROW-1263: iPad Chrome accessory bars + layout pan — preventScroll focus
// wrapper (15), overlay viewport meta on a fake iPad UA (16), accessory-height
// occlusion with a chased offsetTop pinned back to 0 (17), rAF-coalesced
// accessory animation (18).
const ADDON_JS =
  __dirname + '/../../CrowTerminal/Sources/CrowTerminal/Resources/xterm/xterm-addon-crow-viewport.js';

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

const LAYOUT_HEIGHT = 800; // layout viewport — unchanged by an iOS keyboard
const HOST_TOP = 120;      // the web app's terminal sits below header + tabbar

// A fresh world per case: the addon holds module-free per-instance state, but
// each test wants its own listener set, rAF queue and host element.
function makeWorld({
  hasVisualViewport = true,
  hostTop = HOST_TOP,
  keyboardCapable = true,
  userAgent,
  platform,
  maxTouchPoints,
  virtualKeyboard = false,
} = {}) {
  const html = '<!doctype html><html><head>'
    + '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">'
    + '</head><body><div id="host"></div></body></html>';
  const dom = new JSDOM(html, {
    runScripts: 'outside-only',
    url: 'http://localhost/',
    userAgent: userAgent || 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) jsdom',
  });
  const { window } = dom;

  // CROW-1045: the addon now gates on a keyboard-capable surface (touch), not
  // merely `visualViewport` presence — a desktop WKWebView exposes visualViewport
  // but has no software keyboard. jsdom implements neither `matchMedia` nor a
  // non-zero `maxTouchPoints`, so it reads as desktop by default; hand it a
  // `matchMedia` that answers `(pointer: coarse)` to model a phone/tablet. The
  // one desktop case flips this off to prove the addon stays wholly inert.
  window.matchMedia = (q) => ({ media: q, matches: keyboardCapable && /coarse/.test(q) });

  if (typeof platform === 'string') {
    Object.defineProperty(window.navigator, 'platform', { configurable: true, value: platform });
  }
  if (typeof userAgent === 'string') {
    Object.defineProperty(window.navigator, 'userAgent', { configurable: true, value: userAgent });
  }
  if (typeof maxTouchPoints === 'number') {
    Object.defineProperty(window.navigator, 'maxTouchPoints', { configurable: true, value: maxTouchPoints });
  }
  if (virtualKeyboard) {
    Object.defineProperty(window.navigator, 'virtualKeyboard', {
      configurable: true, value: { overlaysContent: false },
    });
  }

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

  const pageScrolls = [];
  window.scrollX = 0;
  window.scrollY = 0;
  window.scrollTo = (x, y) => {
    if (x && typeof x === 'object') {
      y = x.top || 0;
      x = x.left || 0;
    }
    pageScrolls.push([x || 0, y || 0]);
    vv.offsetTop = 0;
    vv.offsetLeft = 0;
    window.scrollX = 0;
    window.scrollY = 0;
  };

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
  // The helper textarea xterm parks off-screen; the addon re-homes it and hooks
  // its focus to reconcile the cursor (CROW-1078). A real element so a dispatched
  // focus event reaches the addon's listener.
  const textarea = window.document.createElement('textarea');
  textarea.className = 'xterm-helper-textarea';
  element.appendChild(textarea);
  const focusCalls = [];
  const nativeFocus = textarea.focus.bind(textarea);
  textarea.focus = function (opts) {
    focusCalls.push(opts);
    try { return nativeFocus(opts); } catch (_) { /* jsdom focus can throw */ }
  };
  const scrolls = [];
  const resizes = [];
  const refreshes = [];
  const term = {
    element,
    textarea,
    rows: 24,
    refresh: (a, b) => refreshes.push([a, b]),
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
    window, vv, host, term, addon, scrolls, resizes, refreshes, listeners, flush, frames, emit,
    pageScrolls, focusCalls,
    activate: () => addon.activate(term),
    height: () => host.style.height,
    // A keyboard of `px`, iOS-style: visual viewport shrinks, layout does not.
    keyboard: (px) => { vv.height = LAYOUT_HEIGHT - px; },
    // `display: none` — the web app hides the terminal while a board is open.
    hide: () => { clientHeight = 0; },
    show: () => { clientHeight = LAYOUT_HEIGHT - hostTop; },
    // iOS raises the keyboard on focus; dispatch it, then settle the frame.
    focus: () => { textarea.dispatchEvent(new window.Event('focus')); flush(); },
    // Call the (possibly wrapped) focus method — CROW-1263 preventScroll.
    focusMethod: () => { textarea.focus(); },
    viewportMeta: () => window.document.querySelector('meta[name="viewport"]'),
    // The on-screen park <style> the addon injects (touch surfaces only).
    homeStyle: () => window.document.getElementById('crow-vv-textarea-home'),
    // The addon's exported namespace (keyboardCapable is shared with app.js).
    ns: () => ctx.CrowViewportAddon,
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

// ---- 7. A chased offsetTop is pinned, not followed ----------------------------
// CROW-988 added offsetTop into visibleBottom so a shifted visual viewport still
// reached the on-screen band. CROW-1263 pins that shift back to the origin
// (Chrome Autofill + iPadOS bars) so the TUI does not jump up with it.
{
  console.log('shifted visual viewport is pinned');
  const w = makeWorld();
  w.activate();
  w.vv.height = 400;
  w.vv.offsetTop = 50; // Chrome/iOS chased the helper
  w.emit();
  check('pins offsetTop back to 0', w.vv.offsetTop === 0);
  check('host sized as if the pan never happened', w.height() === '280px'); // 400 - 120
  check('asked the page to scroll to origin', w.pageScrolls.length >= 1);
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

// ---- 10. Touch surface re-homes the parked helper textarea -----------------
// CROW-1078 #1: xterm parks .xterm-helper-textarea at left:-9999em. On a touch
// surface iOS scrolls the visual viewport to chase that off-screen field the
// instant it's focused, stranding the cursor. The addon re-parks it on-screen
// with a stylesheet rule that must yield to xterm's own inline sync.
{
  console.log('touch surface re-homes the parked helper textarea');
  const w = makeWorld();
  check('no park style before activate', !w.homeStyle());
  w.activate();
  const style = w.homeStyle();
  check('injects the on-screen park style', !!style);
  check('parks the field on-screen, not at -9999em',
    !!style && /left:\s*0/.test(style.textContent) && !/9999/.test(style.textContent));
  check('rule is NOT !important (so xterm inline sync still wins the cell)',
    !!style && !/!important/i.test(style.textContent));
  check('targets the helper textarea',
    !!style && /\.xterm-helper-textarea/.test(style.textContent));
}

// ---- 11. Focus reconciles the cursor the moment the keyboard is raised ------
// iOS opens the keyboard on focus, before the trailing vv resize/scroll — so a
// focus reconcile makes the first keyboard frame correct.
{
  console.log('focus reconciles when the keyboard is raised');
  const w = makeWorld();
  w.activate();
  w.keyboard(300);     // keyboard-sized shrink already present at focus time
  w.focus();
  check('focus sized the host', w.height() === '380px');
  check('focus repainted the cursor', w.refreshes.length >= 1);
}

// ---- 12. A chased visual-viewport scroll still reads as a keyboard ----------
// CROW-1078 #4: iOS scrolls the visual viewport (offsetTop grows) to chase the
// textarea. The OLD occlusion test, layoutHeight - (offsetTop + height), then
// computes ~0 and wrongly restores. Keyboard height, layoutHeight - height, is
// independent of the scroll and still fires. CROW-1263 then pins offsetTop back
// to 0 so the host is NOT sized as if the TUI had been shoved up with the pan.
{
  console.log('chased visual-viewport scroll still reads as keyboard');
  const w = makeWorld();
  w.activate();
  w.vv.offsetTop = 200; // iOS scrolled down chasing the field
  w.keyboard(300);      // vv.height = 500
  w.emit();
  // Old math: 800 - (200 + 500) = 100 ≤ 120 → would have restored (no keyboard).
  // New math: 800 - 500 = 300 > 120 → detected.
  check('still detects the keyboard', w.resizes.length === 1);
  // Pin treats the chase as undone, so visibleBottom is height (500), not 700.
  check('host sized without following the pan', w.height() === '380px'); // 500 - 120
  check('offsetTop leftover is 0', w.vv.offsetTop === 0);
  check('cursor repainted on apply', w.refreshes.length >= 1);
}

// ---- 13. Cursor is repainted on both apply and restore ---------------------
// CROW-1078 #3: after the inset is applied or released the drawn cursor can lag
// the moved host, so the addon forces a repaint each way.
{
  console.log('cursor repainted on apply and restore');
  const w = makeWorld();
  w.activate();
  w.keyboard(300);
  w.emit();
  const afterOpen = w.refreshes.length;
  check('repaints when the inset is applied', afterOpen >= 1);
  check('repaint spans the whole grid', w.refreshes[0][0] === 0 && w.refreshes[0][1] === 23);
  w.keyboard(0);
  w.emit();
  check('repaints again when the inset is released', w.refreshes.length > afterOpen);
}

// ---- 14. keyboardCapable is exported and shared with app.js -----------------
// CROW-1078 #5: app.js drops WebGL on touch surfaces using THIS test, so it must
// be exported and agree with the addon's own gate.
{
  console.log('keyboardCapable is exported and shared');
  const phone = makeWorld();                          // coarse pointer
  check('exported as a function', typeof phone.ns().keyboardCapable === 'function');
  check('true on a touch surface', phone.ns().keyboardCapable() === true);
  const desk = makeWorld({ keyboardCapable: false }); // desktop WKWebView
  check('false on a non-touch surface', desk.ns().keyboardCapable() === false);
  // And the desktop surface injects no park style / wires no focus reconcile.
  desk.activate();
  check('desktop injects no park style', !desk.homeStyle());
  desk.keyboard(300);
  desk.focus();
  check('desktop does not size on focus', desk.height() === '');
  check('desktop does not repaint on focus', desk.refreshes.length === 0);
  desk.focusMethod();
  check('desktop does not wrap focus with preventScroll',
    !desk.focusCalls.some((o) => o && o.preventScroll === true));
  check('desktop does not stamp the helper as crow-tty',
    desk.term.textarea.getAttribute('name') !== 'crow-tty');
}

const IPAD_CHROME_UA = 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0.6099.119 Mobile/15E148 Safari/604.1';
const ANDROID_CHROME_UA = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.144 Mobile Safari/537.36';

// ---- 15. preventScroll focus wrapper + form-unlike helper stamps ------------
{
  console.log('preventScroll focus wrapper and helper stamps');
  const w = makeWorld();
  w.activate();
  const ta = w.term.textarea;
  check('autocomplete off', ta.getAttribute('autocomplete') === 'off');
  check('autocorrect off', ta.getAttribute('autocorrect') === 'off');
  check('autocapitalize off', ta.getAttribute('autocapitalize') === 'off');
  check('spellcheck false', ta.getAttribute('spellcheck') === 'false');
  check('name is crow-tty, not a form field', ta.getAttribute('name') === 'crow-tty');
  check('data-lpignore', ta.getAttribute('data-lpignore') === 'true');
  check('does not request a password/otp/csc accessory',
    !/new-password|one-time-code|cc-csc/.test(ta.getAttribute('autocomplete') || ''));
  w.focusMethod();
  check('focus wrapper passed preventScroll',
    w.focusCalls.some((o) => o && o.preventScroll === true));
}

// ---- 16. Overlay viewport meta on a fake iPad UA ----------------------------
{
  console.log('overlay viewport meta on iPad Chrome UA');
  const ipad = makeWorld({ userAgent: IPAD_CHROME_UA, virtualKeyboard: true });
  check('default HTML is resizes-content (Android path)',
    /interactive-widget=resizes-content/.test(ipad.viewportMeta().getAttribute('content')));
  ipad.activate();
  const content = ipad.viewportMeta().getAttribute('content');
  check('iPad swaps to overlays-content', /interactive-widget=overlays-content/.test(content));
  check('iPad no longer asks to resize the layout', !/resizes-content/.test(content));
  check('virtualKeyboard.overlaysContent',
    ipad.window.navigator.virtualKeyboard.overlaysContent === true);

  const android = makeWorld({
    userAgent: ANDROID_CHROME_UA,
    platform: 'Linux armv8l',
    virtualKeyboard: true,
  });
  android.activate();
  check('Android keeps resizes-content',
    /interactive-widget=resizes-content/.test(android.viewportMeta().getAttribute('content')));
  check('Android does not force overlaysContent',
    android.window.navigator.virtualKeyboard.overlaysContent === false);

  const ipadOS = makeWorld({
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
    platform: 'MacIntel',
    maxTouchPoints: 5,
  });
  ipadOS.activate();
  check('iPadOS-as-MacIntel also overlays',
    /overlays-content/.test(ipadOS.viewportMeta().getAttribute('content')));
}

// ---- 17. Keyboard + stacked accessory bars, chased offsetTop, pinned --------
// Chrome Autofill (~44px) + iPadOS bar (~44px) + keyboard. Chrome pans so
// offsetTop + height ≈ innerHeight — the CROW-1078 #4 false negative if
// occlusion used visibleBottom, and the TUI jump if sizing followed the pan.
{
  console.log('accessory-height occlusion with chased offsetTop');
  const w = makeWorld();
  w.activate();
  w.flush(); // settle the activate schedule
  const keyboard = 300;
  const accessory = 44;
  const ipadBar = 44;
  const occlusion = keyboard + accessory + ipadBar; // 388
  w.vv.height = LAYOUT_HEIGHT - occlusion; // 412
  w.vv.offsetTop = occlusion;              // 388 + 412 = 800, chased flush with layout
  w.emit('scroll');
  check('still detects keyboard+bars (occlusion > 120)', w.resizes.length === 1);
  check('host sized to un-panned visual height', w.height() === '292px'); // 412 - 120
  check('window.scrollTo pinned origin',
    w.pageScrolls.length >= 1 && w.pageScrolls.every((p) => p[0] === 0 && p[1] === 0));
  check('no leftover offsetTop after pin', w.vv.offsetTop === 0);
}

// ---- 18. Accessory animation is one fit at rest, not a SIGWINCH storm -------
{
  console.log('accessory animation coalesces to one fit');
  const w = makeWorld();
  w.activate();
  w.flush();
  w.keyboard(300);
  w.vv.offsetTop = 20;
  for (let i = 0; i < 6; i++) {
    (w.listeners.scroll || []).forEach((fn) => fn());
  }
  check('burst queues at most one rAF', w.frames() === 1);
  w.flush();
  check('one refit at rest', w.resizes.length === 1);
  w.flush();
  check('no extra SIGWINCH after rest', w.resizes.length === 1);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
