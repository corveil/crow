const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

const epilogue = `
;globalThis.__t = {
  switcherIncludesSession(s, include){ return switcherIncludesSession(s, include); },
  switcherMruOrdered(list, include){ return switcherMruOrdered(list, include); },
  switcherSidebarOrdered(list, include){ return switcherSidebarOrdered(list, include); },
  eventMatchesSwitcherBinding(e, binding){ return eventMatchesSwitcherBinding(e, binding); },
  parseSwitcherBinding(binding){ return parseSwitcherBinding(binding); },
  captureSwitcherModifiers(e){
    captureSwitcherModifiers(e);
    return { chord: switcherState.chord, modifiersHeld: switcherState.modifiersHeld };
  },
  switcherBindingModifiersActive(){ return switcherBindingModifiersActive(); },
  setModifiersHeld(v){ switcherState.modifiersHeld = v; },
  setChord(v){ switcherState.chord = v; },
  touchSessionMRU(id){ return touchSessionMRU(id); },
  set uiConfig(v){ Object.assign(uiConfig, v); },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

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
  check('default binding matches Shift+Tab', T.eventMatchesSwitcherBinding(e, 'shift+tab'));
  check('binding is case-insensitive', T.eventMatchesSwitcherBinding(e, 'Shift+Tab'));
}

{
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

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
