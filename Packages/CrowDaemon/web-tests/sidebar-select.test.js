const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-917 behaviour test: the Select-sessions toggle lives in the far-right
// sidebar icon column (`sidebarIconColumn`), stacked under bell/gear/+. Runs the
// REAL app.js under jsdom and drives the `.nav-select` button — a string guard
// proves only that the code moved files; this proves the behaviour survived the
// move (toggles `selectionMode`, and clears `selectedSessionIDs` on cancel). Same
// loader shape as board.test.js / sidebar-groups.test.js. renderSidebar is
// neutered so the click exercises just the handler, not a full re-render.
const epilogue = `
;globalThis.__t = {
  get selectionMode(){ return selectionMode; },
  set selectionMode(v){ selectionMode = v; },
  get selectedSessionIDs(){ return selectedSessionIDs; },
  sidebarIconColumn(){ return sidebarIconColumn(); },
  neuterRender(){ renderSidebar = function(){}; },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="sidebar"></div><div id="board"></div><div id="header"></div>
   </body></html>`,
  { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' }
);
const { window } = dom;
window.WebSocket = function () {
  return { send() {}, close() {},
    set onopen(v) {}, set onmessage(v) {}, set onclose(v) {}, set onerror(v) {} };
};
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
const selBtn = () => T.sidebarIconColumn().querySelector('.nav-select');

T.neuterRender();

console.log('\nSelect toggle — idle → active:');
T.selectionMode = false;
T.selectedSessionIDs.clear();
let sel = selBtn();
check('.nav-select renders in the sidebar icon column', !!sel);
check('idle: not red (no nav-selecting)', !sel.className.includes('nav-selecting'));
check('idle: title + aria-label = "Select sessions"',
  sel.title === 'Select sessions' && sel.getAttribute('aria-label') === 'Select sessions');
sel.onclick();
check('click enters selection mode', T.selectionMode === true);

console.log('\nSelect toggle — active → cancel clears the selection:');
T.selectionMode = true;
T.selectedSessionIDs.add('sess-1');
T.selectedSessionIDs.add('sess-2');
sel = selBtn();
check('active: reads red (.nav-selecting) and "Cancel selection"',
  sel.className.includes('nav-selecting') && sel.title === 'Cancel selection');
sel.onclick();
check('cancel exits selection mode', T.selectionMode === false);
check('cancel CLEARS selectedSessionIDs (drop the .clear() and this fails)',
  T.selectedSessionIDs.size === 0);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
