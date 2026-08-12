const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// #875 regression: the terminal's custom key handler. Drives the real
// handleTerminalKey + pasteIntoTerminal from Resources/web/app.js against a fake
// xterm + clipboard. Same harness shape as wheel-scroll.test.js — an epilogue
// evaluated in app.js's own top-level lexical scope exposes the module-scope
// bindings (which is why handleTerminalKey lives at module scope rather than
// nested inside ensureTerminal).
//
// The handler is invoked the way xterm invokes it: called directly with the
// keydown, its return value deciding only whether xterm runs its OWN key
// handling. Returning false does NOT cancel the event — that's the bug this
// file pins.
//
// CROW-916 adds the Shift+Enter cases. `termWs` is exposed too so those can
// assert the bytes that actually reach the socket, through the real sendToPTY.
const epilogue = `
;globalThis.__t = {
  handleTerminalKey(e){ return handleTerminalKey(e); },
  pasteIntoTerminal(){ return pasteIntoTerminal(); },
  set term(v){ term = v; },
  set searchAddon(v){ searchAddon = v; },
  set termWs(v){ termWs = v; },
  set uiConfig(v){ Object.assign(uiConfig, v); },
  armSwitcherPrefix(){ return armSwitcherPrefix(); },
  disarmSwitcherPrefix(){ return disarmSwitcherPrefix(); },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body><div id="terminal"></div></body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;
window.WebSocket = function () {
  return { send() {}, close() {},
    set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
};
window.WebSocket.OPEN = 1;
window.TextEncoder = TextEncoder; // jsdom omits it; real browsers have it
window.setInterval = () => 0;
window.setTimeout = () => 0;
window.requestAnimationFrame = () => 0;
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

// ---- Fakes -----------------------------------------------------------------

// A fake xterm plus recorders for everything the handler can reach: what got
// pasted into the terminal, what got written to the system clipboard, and what
// reached the PTY socket.
const pasted = [];
const copied = [];
const sent = [];
let clipboardText = '';

function setup({ selection = '' } = {}) {
  pasted.length = 0;
  copied.length = 0;
  sent.length = 0;
  window.document.querySelectorAll('.text-prompt-backdrop').forEach((n) => n.remove());
  T.term = {
    hasSelection: () => selection.length > 0,
    getSelection: () => selection,
    paste: (t) => pasted.push(t),
    focus() {},
  };
  T.searchAddon = { findNext() {} };
  // The real sendToPTY writes UTF-8 bytes to this, so decoding here measures
  // exactly what the PTY would receive.
  T.termWs = {
    readyState: window.WebSocket.OPEN,
    send: (bytes) => sent.push(new TextDecoder().decode(bytes)),
  };
}

// navigator.clipboard is absent in jsdom (and in a real browser over plain
// http, which is the case `withoutClipboard` models).
function withClipboard() {
  Object.defineProperty(window.navigator, 'clipboard', {
    configurable: true,
    value: {
      readText: () => Promise.resolve(clipboardText),
      writeText: (t) => { copied.push(t); return Promise.resolve(); },
    },
  });
}
function withoutClipboard() {
  Object.defineProperty(window.navigator, 'clipboard', { configurable: true, value: undefined });
}

// xterm hands the handler the raw KeyboardEvent; we count the cancellation calls
// the handler makes on it.
function key(k, { meta = false, ctrl = false, shift = false, alt = false, type = 'keydown' } = {}) {
  const e = {
    type, key: k, metaKey: meta, ctrlKey: ctrl, shiftKey: shift, altKey: alt,
    prevented: 0, stopped: 0,
    preventDefault() { e.prevented++; },
    stopPropagation() { e.stopped++; },
  };
  return e;
}

const settle = () => new Promise((r) => process.nextTick(r));

async function main() {
  // ---- Cmd+V: the browser's native paste owns it (#875) --------------------

  // The whole bug: the handler pasted explicitly AND returned false, but false
  // doesn't cancel the event, so the browser's native paste fired xterm's own
  // `paste` listener too and the clipboard landed twice (double-wrapped for
  // bracketed paste, at that). The handler must now leave Cmd+V entirely alone.
  console.log('Cmd+V is left to the browser so it pastes exactly once (#875):');
  {
    withClipboard();
    clipboardText = 'hello';
    setup();
    const e = key('v', { meta: true });
    const result = T.handleTerminalKey(e);
    await settle();
    check('returns true (the event is not intercepted)', result === true);
    check('does not paste explicitly — that was the second paste', pasted.length === 0);
    check('does not cancel the native paste gesture', e.prevented === 0 && e.stopped === 0);
  }
  {
    // The chord arrives with an uppercase `key` under Shift, and under caps
    // lock with no Shift at all — the old handler matched both, so both must
    // stay unhandled.
    withClipboard();
    setup();
    const shifted = key('V', { meta: true, shift: true });
    check('Cmd+Shift+V is left alone too', T.handleTerminalKey(shifted) === true);
    const capsLocked = key('V', { meta: true });
    check('caps-locked Cmd+V is left alone too', T.handleTerminalKey(capsLocked) === true);
    await settle();
    check('...and neither pastes explicitly', pasted.length === 0);
    check('...nor cancels the native paste',
      shifted.prevented === 0 && capsLocked.prevented === 0);
  }
  {
    // Ctrl+V was never handled here (it's literal-next in readline/tmux) and
    // must stay that way.
    withClipboard();
    setup();
    const e = key('v', { ctrl: true });
    check('Ctrl+V is untouched', T.handleTerminalKey(e) === true && e.prevented === 0);
    await settle();
    check('...and pastes nothing explicitly', pasted.length === 0);
  }

  // ---- The right-click menu keeps the explicit path -------------------------

  // A menu click is not a paste gesture, so nothing native fires — reading the
  // clipboard ourselves is the only way, and it must still land exactly once.
  console.log('\nThe right-click Paste item still pastes, exactly once:');
  {
    withClipboard();
    clipboardText = 'from the menu';
    setup();
    T.pasteIntoTerminal();
    await settle();
    check('pastes once', pasted.length === 1);
    check('pastes the clipboard text', pasted[0] === 'from the menu');
    check('routes through term.paste so xterm wraps it for bracketed paste',
      pasted.join() === 'from the menu');
  }
  {
    // Over plain http (`--host 0.0.0.0`) there is no navigator.clipboard at
    // all. The menu can't paste there — but nothing may throw, and Cmd+V still
    // works because the native gesture never depended on this path.
    withoutClipboard();
    clipboardText = 'unreachable';
    setup();
    let threw = false;
    try { T.pasteIntoTerminal(); } catch (_) { threw = true; }
    await settle();
    check('no clipboard API → no throw', !threw);
    check('no clipboard API → nothing pasted', pasted.length === 0);
  }
  {
    withClipboard();
    clipboardText = '';
    setup();
    T.pasteIntoTerminal();
    await settle();
    check('an empty clipboard pastes nothing', pasted.length === 0);
  }

  // ---- Copy: we own the gesture because we can always deliver ---------------

  // Unlike paste, copy has a working fallback in every context (writeText, else
  // fallbackCopy's execCommand), so cancelling the browser default is safe.
  console.log('\nCmd/Ctrl+C copies the selection and consumes the event:');
  {
    withClipboard();
    setup({ selection: 'selected text' });
    const e = key('c', { meta: true });
    const result = T.handleTerminalKey(e);
    await settle();
    check('returns false so xterm skips its own handling', result === false);
    check('copies the selection once', copied.join() === 'selected text');
    check('cancels the browser default', e.prevented === 1 && e.stopped === 1);
  }
  {
    withClipboard();
    setup({ selection: 'selected text' });
    const e = key('c', { ctrl: true });
    T.handleTerminalKey(e);
    await settle();
    check('Ctrl+C with a selection copies too', copied.join() === 'selected text');
  }
  {
    // The acceptance criterion that keeps the shell usable: with nothing
    // selected, Ctrl+C must reach the PTY as SIGINT.
    withClipboard();
    setup({ selection: '' });
    const e = key('c', { ctrl: true });
    const result = T.handleTerminalKey(e);
    await settle();
    check('Ctrl+C with no selection falls through to SIGINT', result === true);
    check('...copies nothing', copied.length === 0);
    check('...and is not cancelled', e.prevented === 0 && e.stopped === 0);
  }

  // ---- Find -----------------------------------------------------------------

  console.log('\nCmd+F opens our find prompt instead of the browser find bar:');
  {
    withClipboard();
    setup();
    const e = key('f', { meta: true });
    const result = T.handleTerminalKey(e);
    check('returns false', result === false);
    check('cancels the browser default (its find bar would open over ours)',
      e.prevented === 1 && e.stopped === 1);
    check('opens the find prompt', !!window.document.querySelector('.text-prompt-backdrop'));
  }

  // ---- Shift+Enter (CROW-916) ------------------------------------------------

  // xterm.js emits the same bare \r for Enter and Shift+Enter, so Claude Code
  // submitted on both. The handler rewrites Shift+Enter to CSI-u, which tmux
  // carries to extended-keys apps and downgrades to \r for everything else.
  console.log('\nShift+Enter reaches the PTY as CSI-u, not a bare \\r:');
  {
    withClipboard();
    setup();
    const e = key('Enter', { shift: true });
    const result = T.handleTerminalKey(e);
    check('returns false so xterm skips its own \\r', result === false);
    check('sends exactly the CSI-u sequence', sent.join() === '\x1b[13;2u');
    check('sends it once', sent.length === 1);
    // Without this the keydown's default survives and the keypress phase —
    // which this handler waves through — writes a second \r (#875).
    check('cancels the event', e.prevented === 1 && e.stopped === 1);
  }
  {
    // The criterion that keeps the terminal usable: plain Enter must stay
    // untouched so xterm's own \r still submits.
    withClipboard();
    setup();
    const e = key('Enter');
    const result = T.handleTerminalKey(e);
    check('plain Enter passes through', result === true);
    check('...sending nothing of our own', sent.length === 0);
    check('...and is not cancelled', e.prevented === 0 && e.stopped === 0);
  }
  {
    // Deliberately unhandled: xterm's key table already maps altKey + Enter to
    // ESC CR (`e.altKey ? ESC+CR : CR`), so a branch here would restate the
    // library. Pinned so a future "add Option+Enter for symmetry" has to
    // confront the duplication.
    withClipboard();
    setup();
    const e = key('Enter', { alt: true });
    check('Option+Enter is left to xterm, which sends ESC CR natively',
      T.handleTerminalKey(e) === true && sent.length === 0 && e.prevented === 0);
    const both = key('Enter', { alt: true, shift: true });
    check('Shift+Option+Enter stays on that same native path',
      T.handleTerminalKey(both) === true && sent.length === 0);
  }
  {
    // Ctrl+Enter and Cmd+Enter are the app's/browser's business, not ours.
    withClipboard();
    setup();
    for (const [label, mods] of [['Ctrl', { ctrl: true }], ['Cmd', { meta: true }]]) {
      const e = key('Enter', { ...mods, shift: true });
      check(`${label}+Shift+Enter is untouched`,
        T.handleTerminalKey(e) === true && e.prevented === 0);
    }
    check('...and none of them wrote to the PTY', sent.length === 0);
  }
  {
    withClipboard();
    setup();
    for (const type of ['keyup', 'keypress']) {
      const e = key('Enter', { shift: true, type });
      check(`Shift+Enter on ${type} is ignored (keydown only)`,
        T.handleTerminalKey(e) === true && e.prevented === 0);
    }
    check('...so the sequence is sent exactly once per press', sent.length === 0);
  }

  // ---- Everything else passes through ---------------------------------------

  console.log('\nEverything else reaches the terminal untouched:');
  {
    withClipboard();
    setup({ selection: 'selected text' });
    for (const type of ['keyup', 'keypress']) {
      const e = key('c', { meta: true, type });
      check(`${type} is ignored (keydown only)`,
        T.handleTerminalKey(e) === true && e.prevented === 0);
    }
    await settle();
    check('...so a non-keydown never copies', copied.length === 0);
  }
  {
    withClipboard();
    setup();
    const e = key('v');
    check('an unmodified keystroke passes through',
      T.handleTerminalKey(e) === true && e.prevented === 0);
  }

  // ---- Session switcher (CROW-976) -----------------------------------------

  console.log('\nSession switcher binding in the terminal:');
  {
    withClipboard();
    setup();
    T.uiConfig = { switcherEnabled: true, switcherBinding: 'shift+tab', switcherCaptureInTerminal: true };
    const e = key('Tab', { shift: true });
    const result = T.handleTerminalKey(e);
    check('Shift+Tab is captured when captureInTerminal is true',
      result === false && e.prevented === 1 && sent.length === 0);
  }
  {
    withClipboard();
    setup();
    T.uiConfig = { switcherEnabled: true, switcherBinding: 'shift+tab', switcherCaptureInTerminal: false };
    const e = key('Tab', { shift: true });
    const result = T.handleTerminalKey(e);
    check('Shift+Tab passes through when captureInTerminal is false',
      result === true && e.prevented === 0);
  }

  // CROW-980: the default binding leads with a prefix key, so a bare Tab in the
  // terminal must stay a Tab — completion would be dead otherwise.
  {
    withClipboard();
    setup();
    T.uiConfig = { switcherEnabled: true, switcherBinding: 'esc+tab', switcherCaptureInTerminal: true };
    T.disarmSwitcherPrefix();
    const e = key('Tab');
    const result = T.handleTerminalKey(e);
    check('a bare Tab reaches the terminal under esc+tab',
      result === true && e.prevented === 0);
  }
  {
    withClipboard();
    setup();
    T.uiConfig = { switcherEnabled: true, switcherBinding: 'esc+tab', switcherCaptureInTerminal: true };
    T.armSwitcherPrefix();
    const e = key('Tab');
    const result = T.handleTerminalKey(e);
    check('Tab is captured once Esc armed the prefix',
      result === false && e.prevented === 1 && sent.length === 0);
    T.disarmSwitcherPrefix();
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
}

main();
