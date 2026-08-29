const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

const epilogue = `
;globalThis.__t = {
  switcherIncludesSession(s, include){ return switcherIncludesSession(s, include); },
  switcherMruOrdered(list, include){ return switcherMruOrdered(list, include); },
  switcherSidebarOrdered(list, include){ return switcherSidebarOrdered(list, include); },
  eventMatchesSwitcherBinding(e, binding){ return eventMatchesSwitcherBinding(e, binding); },
  switcherBindingOpens(e, binding){ return switcherBindingOpens(e, binding); },
  onSwitcherKeyDown(e){ return onSwitcherKeyDown(e); },
  switcherPrefixArmed(){ return switcherPrefixArmed(); },
  disarmSwitcherPrefix(){ return disarmSwitcherPrefix(); },
  switcherCommitHint(){ return switcherCommitHint(); },
  parseSwitcherBinding(binding){ return parseSwitcherBinding(binding); },
  captureSwitcherModifiers(e){
    captureSwitcherModifiers(e);
    return { chord: switcherState.chord, modifiersHeld: switcherState.modifiersHeld };
  },
  switcherBindingModifiersActive(){ return switcherBindingModifiersActive(); },
  switcherBindingHasModifiers(b){ return switcherBindingHasModifiers(b); },
  switcherBindingIsTerminalReserved(b){ return switcherBindingIsTerminalReserved(b); },
  switcherCapturesInTerminal(){ return switcherCapturesInTerminal(); },
  onSwitcherKeyUp(e){ return onSwitcherKeyUp(e); },
  setModifiersHeld(v){ switcherState.modifiersHeld = v; },
  setChord(v){ switcherState.chord = v; },
  setSwitcherOpen(v){
    switcherState.open = v;
    switcherState.chord = parseSwitcherBinding('tab');
    switcherState.modifiersHeld = { shift: false, ctrl: false, alt: false, meta: false };
  },
  getSwitcherOpen(){ return switcherState.open; },
  touchSessionMRU(id){ return touchSessionMRU(id); },
  switcherClampIndex(entries){ return switcherClampIndex(entries); },
  setIndex(i){ switcherState.index = i; },
  setHighlightedId(id){ switcherState.highlightedId = id; },
  getIndex(){ return switcherState.index; },
  setSessions(v){ sessions = v; },
  // Commit calls selectSession(), which drags in routing, the WebSocket and the
  // DOM. Swap it for a recorder so these tests stay about the key handling.
  stubSelectSession(){
    globalThis.__selected = [];
    selectSession = async (id) => { globalThis.__selected.push(id); };
  },
  getSelected(){ return globalThis.__selected || []; },
  set uiConfig(v){ Object.assign(uiConfig, v); },
};
`;
const appjs = loadClientSource() + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body><div id="session-switcher" hidden></div></body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;
window.WebSocket = function () {
  return { send() {}, close() {},
    set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
};
window.setInterval = () => 0;
window.setTimeout = (fn) => { fn(); return 0; };
window.requestAnimationFrame = () => 0;
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };

const DEFAULT_INCLUDE = {
  managers: false, jobs: false, reviews: true,
  active: true, paused: true, in_review: true, completed: false, archived: false,
};

console.log('CROW-976 session switcher helpers:');

{
  const work = { id: 'w1', kind: 'work', status: 'active' };
  const mgr = { id: 'm1', kind: 'manager', status: 'active' };
  const done = { id: 'd1', kind: 'work', status: 'completed' };
  check('active work included by default', T.switcherIncludesSession(work, DEFAULT_INCLUDE));
  check('manager excluded by default', !T.switcherIncludesSession(mgr, DEFAULT_INCLUDE));
  check('completed excluded by default', !T.switcherIncludesSession(done, DEFAULT_INCLUDE));
}

{
  T.touchSessionMRU('a');
  T.touchSessionMRU('b');
  T.touchSessionMRU('a');
  const list = [
    { id: 'a', kind: 'work', status: 'active' },
    { id: 'b', kind: 'work', status: 'active' },
    { id: 'c', kind: 'work', status: 'active' },
  ];
  const ordered = T.switcherMruOrdered(list, DEFAULT_INCLUDE).map((s) => s.id);
  check('MRU puts most recent first', ordered[0] === 'a');
  check('MRU appends unseen sessions', ordered.includes('c'));
}

{
  const e = { key: 'Tab', shiftKey: true, ctrlKey: false, altKey: false, metaKey: false };
  check('shift+tab binding matches Shift+Tab', T.eventMatchesSwitcherBinding(e, 'shift+tab'));
  check('binding is case-insensitive', T.eventMatchesSwitcherBinding(e, 'Shift+Tab'));
}

// CROW-980: the default is a *sequence*, not a chord — Esc is a prefix key, so
// it can't be read off the Tab event the way Shift can.
console.log('\nCROW-980 esc+tab prefix binding:');
const keyEvent = (key) => ({
  key, type: 'keydown', shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
  prevented: 0, preventDefault(){ this.prevented++; }, stopPropagation(){},
});
{
  const b = T.parseSwitcherBinding('esc+tab');
  check('esc+tab parses esc as a prefix', b.prefix === 'Escape');
  check('esc+tab carries no modifiers', !T.switcherBindingHasModifiers(b));
  check('esc+tab still keys on Tab', b.keys.includes('Tab'));
  check('escape+tab is the same binding', T.parseSwitcherBinding('escape+tab').prefix === 'Escape');
  check('a modifier chord has no prefix', T.parseSwitcherBinding('shift+tab').prefix === null);
}

{
  T.uiConfig = { switcherEnabled: true, switcherBinding: 'esc+tab', switcherCaptureInTerminal: true };
  T.setSwitcherOpen(false);
  T.setSessions([
    { id: 'a', kind: 'work', status: 'active' },
    { id: 'b', kind: 'work', status: 'active' },
  ]);
  T.stubSelectSession();
  T.disarmSwitcherPrefix();

  const bareTab = keyEvent('Tab');
  check('bare Tab does not open the switcher', !T.switcherBindingOpens(bareTab, 'esc+tab'));
  T.onSwitcherKeyDown(bareTab);
  check('bare Tab is left alone for the page', !T.getSwitcherOpen() && bareTab.prevented === 0);

  const esc = keyEvent('Escape');
  T.onSwitcherKeyDown(esc);
  check('Esc arms the prefix', T.switcherPrefixArmed());
  check('Esc is never swallowed', esc.prevented === 0 && !T.getSwitcherOpen());

  check('Tab opens once the prefix is armed', T.switcherBindingOpens(keyEvent('Tab'), 'esc+tab'));
  T.onSwitcherKeyDown(keyEvent('Tab'));
  check('Esc then Tab opens the switcher', T.getSwitcherOpen());
  check('opening consumes the prefix', !T.switcherPrefixArmed());

  // Esc cancels while open (the ticket's reason for picking this chord), and
  // the release of Tab must NOT commit — nothing is being held down.
  T.onSwitcherKeyUp({
    key: 'Tab', shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
    preventDefault(){}, stopPropagation(){},
  });
  check('prefix binding stays open when Tab is released', T.getSwitcherOpen());
  T.onSwitcherKeyDown(keyEvent('Escape'));
  check('Esc cancels the open overlay', !T.getSwitcherOpen());
}

{
  T.uiConfig = { switcherEnabled: true, switcherBinding: 'esc+tab' };
  T.setSwitcherOpen(false);
  T.onSwitcherKeyDown(keyEvent('Escape'));
  T.onSwitcherKeyDown(keyEvent('l'));
  check('an intervening keystroke disarms the prefix', !T.switcherPrefixArmed());
  T.onSwitcherKeyDown(keyEvent('Escape'));
  T.onSwitcherKeyDown(keyEvent('Shift'));
  check('a bare modifier keeps the prefix armed', T.switcherPrefixArmed());
  T.disarmSwitcherPrefix();
}

{
  T.uiConfig = { switcherEnabled: true, switcherBinding: 'esc+tab', switcherCaptureInTerminal: true };
  T.setSwitcherOpen(false);
  T.setSessions([
    { id: 'a', kind: 'work', status: 'active' },
    { id: 'b', kind: 'work', status: 'active' },
  ]);
  T.stubSelectSession();
  T.onSwitcherKeyDown(keyEvent('Escape'));
  T.onSwitcherKeyDown(keyEvent('Tab'));
  check('overlay is open before the commit', T.getSwitcherOpen());
  T.onSwitcherKeyDown(keyEvent('Enter'));
  check('Enter commits a prefix binding', !T.getSwitcherOpen());
  check('Enter selects the highlighted session', T.getSelected().length === 1);
  T.disarmSwitcherPrefix();
}

{
  T.uiConfig = { switcherBinding: 'esc+tab' };
  check('prefix hint asks for Enter', T.switcherCommitHint().includes('Enter to switch'));
  T.uiConfig = { switcherBinding: 'shift+tab' };
  check('modifier hint still asks for a release', T.switcherCommitHint().includes('release Shift'));
}

// CROW-1002: the default moved to cmd+/ and Shift+Tab became a chord the
// switcher never takes from a focused terminal.
console.log('\nCROW-1002 cmd+/ default and the reserved chord:');
{
  const b = T.parseSwitcherBinding('cmd+/');
  check('cmd+/ parses meta', b.meta && !b.shift && !b.ctrl && !b.alt);
  check('cmd+/ has no prefix', b.prefix === null);
  check('cmd+/ keys on the slash', b.key === '/' && b.keys.length === 1);
  check('command+/ is the same binding', T.parseSwitcherBinding('command+/').meta);
  check('meta+/ is the same binding', T.parseSwitcherBinding('meta+/').meta);

  const hit = { key: '/', shiftKey: false, ctrlKey: false, altKey: false, metaKey: true };
  check('cmd+/ matches a Cmd+/ event', T.eventMatchesSwitcherBinding(hit, 'cmd+/'));
  const bare = { key: '/', shiftKey: false, ctrlKey: false, altKey: false, metaKey: false };
  check('a bare / is not the binding', !T.eventMatchesSwitcherBinding(bare, 'cmd+/'));
  // Cmd is held, so this commits on release like a macOS app switcher — no
  // prefix to arm and no Enter needed.
  check('cmd+/ commits on release', T.switcherBindingHasModifiers(b));

  T.uiConfig = { switcherBinding: 'cmd+/' };
  check('cmd+/ hint asks for a Cmd release', T.switcherCommitHint().includes('release Cmd'));
  check('cmd+/ hint names the slash once',
    T.switcherCommitHint().startsWith('/ or ←→ to cycle'));
}

{
  check('shift+tab is reserved for the terminal',
    T.switcherBindingIsTerminalReserved('shift+tab'));
  check('reservation is case-insensitive',
    T.switcherBindingIsTerminalReserved('Shift+Tab'));
  check('the default is not reserved', !T.switcherBindingIsTerminalReserved('cmd+/'));
  check('esc+tab is not reserved', !T.switcherBindingIsTerminalReserved('esc+tab'));
  // A bare `tab` is a different chord — reserving it would be wrong, and the
  // prefix/modifier fields are what keep the three apart.
  check('a bare tab is not reserved', !T.switcherBindingIsTerminalReserved('tab'));

  T.uiConfig = { switcherBinding: 'shift+tab', switcherCaptureInTerminal: true };
  check('a reserved chord is never captured in the terminal',
    !T.switcherCapturesInTerminal());
  T.uiConfig = { switcherBinding: 'cmd+/', switcherCaptureInTerminal: true };
  check('the default is captured in the terminal', T.switcherCapturesInTerminal());
  T.uiConfig = { switcherBinding: 'cmd+/', switcherCaptureInTerminal: false };
  check('the preference still turns capture off', !T.switcherCapturesInTerminal());
  T.uiConfig = { switcherCaptureInTerminal: true };
}

{
  // Set the binding explicitly rather than inheriting whatever the block above
  // left behind — captureSwitcherModifiers reads it off uiConfig.
  T.uiConfig = { switcherBinding: 'shift+tab' };
  const cap = T.captureSwitcherModifiers({
    key: 'Tab', shiftKey: true, ctrlKey: false, altKey: false, metaKey: false,
  });
  check('capture records shift from binding', cap.chord.shift && cap.modifiersHeld.shift);
  T.setChord(T.parseSwitcherBinding('ctrl+`'));
  T.setModifiersHeld({ shift: false, ctrl: true, alt: false, meta: false });
  check('ctrl binding active while ctrl held', T.switcherBindingModifiersActive());
  T.setModifiersHeld({ shift: false, ctrl: false, alt: false, meta: false });
  check('ctrl binding inactive after release', !T.switcherBindingModifiersActive());
}

{
  const backquote = { key: 'Backquote', shiftKey: false, ctrlKey: true, altKey: false, metaKey: false };
  check('ctrl+` matches Backquote key event', T.eventMatchesSwitcherBinding(backquote, 'ctrl+`'));
  const grave = { key: '`', shiftKey: false, ctrlKey: true, altKey: false, metaKey: false };
  check('ctrl+` matches grave accent key event', T.eventMatchesSwitcherBinding(grave, 'ctrl+`'));
  const parsed = T.parseSwitcherBinding('ctrl+`');
  check('ctrl+` parses Backquote aliases', parsed.keys.includes('Backquote') && parsed.keys.includes('`'));
}

{
  T.uiConfig = { switcherBinding: 'tab' };
  T.setSwitcherOpen(true);
  const noop = () => {};
  T.onSwitcherKeyUp({
    key: 'Tab', shiftKey: false, ctrlKey: false, altKey: false, metaKey: false,
    preventDefault: noop, stopPropagation: noop,
  });
  check('modifier-less binding commits on key release', !T.getSwitcherOpen());
}

{
  const entries = [
    { id: 'a', kind: 'work', status: 'active' },
    { id: 'b', kind: 'work', status: 'active' },
    { id: 'd', kind: 'work', status: 'active' },
  ];
  T.setIndex(4);
  T.setHighlightedId('d');
  T.switcherClampIndex(entries);
  check('index clamps when list shrinks', T.getIndex() === 2);
  T.setIndex(1);
  T.setHighlightedId('a');
  T.switcherClampIndex([{ id: 'b', kind: 'work', status: 'active' }]);
  check('index falls back when highlighted session filtered out', T.getIndex() === 0);
  T.setIndex(3);
  T.setHighlightedId('d');
  T.switcherClampIndex(entries);
  check('index tracks highlighted session after shrink', T.getIndex() === 2);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
