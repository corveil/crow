const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// Sidebar session-row regression tests (CROW-773) — PR-pill status glyphs,
// the crow:merge indicator, and ticket-label pills. Same loader shape as
// board.test.js: run the REAL app.js in a jsdom VM and drive `sessionRow`
// directly, with an epilogue exposing the module-scope state it reads.
const epilogue = `
;globalThis.__t = {
  sessionRow(s){ return sessionRow(s); },
  set live(v){ liveById = v; },
  set hideDetails(v){ uiConfig.hideSessionDetails = v; },
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

const SESSION = {
  id: 'sess-1', name: 'crow-773', status: 'active', kind: 'work',
  agent_kind: 'claude-code', activity: 'idle', repo: 'corveil/crow', branch: 'feature/x',
  links: [{ label: '#800', url: 'https://github.com/corveil/crow/pull/800', type: 'pr' }],
};

// Render a row with the given live `pr` entry, returning { row, glyphs }.
function render(pr, overrides) {
  T.live = pr === undefined ? {} : { 'sess-1': { pr } };
  const row = T.sessionRow({ ...SESSION, ...(overrides || {}) });
  return { row, glyphs: [...row.querySelectorAll('.pr-badge .pr-ico')].map((n) => n.textContent) };
}
const badge = (row) => row.querySelector('.pr-badge');

console.log('Failing checks + changes requested:');
let r = render({ has_pr: true, checks: 'failing', review: 'changesRequested', merge: 'MERGEABLE',
  is_merged: false, has_blockers: true, ready_to_merge: false, failed_checks: ['build', 'lint'] });
check('two glyphs rendered', r.glyphs.length === 2);
check('both are ✕', r.glyphs.join('') === '✕✕');
check('glyphs are red', [...r.row.querySelectorAll('.pr-ico')].every((n) => n.style.color === 'var(--red)'));
check('pill itself is red', badge(r.row).style.color === 'var(--red)');
check('aria-label names the failing count and review', (() => {
  const a = badge(r.row).getAttribute('aria-label');
  return /#800/.test(a) && /2 failing/.test(a) && /Changes requested/.test(a);
})());

console.log('\nPassing checks + approved:');
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'mergeable',
  is_merged: false, has_blockers: false, ready_to_merge: true, failed_checks: [] });
check('two ✔ glyphs', r.glyphs.join('') === '✔✔');
check('glyphs green', [...r.row.querySelectorAll('.pr-ico')].every((n) => n.style.color === 'var(--green)'));
check('pill green', badge(r.row).style.color === 'var(--green)');

console.log('\nPending checks + review required:');
r = render({ has_pr: true, checks: 'pending', review: 'reviewRequired', merge: 'unknown',
  is_merged: false, has_blockers: false, ready_to_merge: false, failed_checks: [] });
check('two ◷ glyphs', r.glyphs.join('') === '◷◷');
check('glyphs orange', [...r.row.querySelectorAll('.pr-ico')].every((n) => n.style.color === 'var(--orange)'));

console.log('\nMerged PR collapses to a single purple check:');
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'merged',
  is_merged: true, has_blockers: false, ready_to_merge: false, failed_checks: [] });
check('exactly one glyph', r.glyphs.length === 1);
check('glyph is ✔', r.glyphs[0] === '✔');
check('glyph purple', r.row.querySelector('.pr-ico').style.color === 'var(--purple)');

console.log('\nConflicting PR adds a ⚠:');
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'conflicting',
  is_merged: false, has_blockers: true, ready_to_merge: false, failed_checks: [] });
check('three glyphs (checks, review, conflict)', r.glyphs.length === 3);
check('third glyph is ⚠', r.glyphs[2] === '⚠');

console.log('\ncrow:merge label vs auto-merge enabled (two independent signals):');
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'mergeable',
  is_merged: false, has_blockers: false, ready_to_merge: true, failed_checks: [], has_merge_label: true });
check('🏷 present when has_merge_label', r.glyphs.includes('🏷'));
check('no ⛙ when auto_merge is false', !r.row.querySelector('.automerge'));
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'mergeable',
  is_merged: false, has_blockers: false, ready_to_merge: true, failed_checks: [] });
check('no 🏷 when has_merge_label absent', !r.glyphs.includes('🏷'));
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'mergeable',
  is_merged: false, has_blockers: false, ready_to_merge: true, failed_checks: [], has_merge_label: true },
  { auto_merge: true });
check('🏷 and ⛙ can both show', r.glyphs.includes('🏷') && !!r.row.querySelector('.automerge'));

console.log('\nGraceful degradation (older daemon payload / no PR status):');
r = render(undefined);
check('pill still rendered from the link', !!badge(r.row) && /#800/.test(badge(r.row).textContent));
check('no glyphs without live PR state', r.glyphs.length === 0);
r = render({ has_pr: false });
check('has_pr:false renders no glyphs', r.glyphs.length === 0);
check('has_pr:false pill is gold', badge(r.row).style.color === 'var(--gold)');
r = render({ has_pr: true, is_merged: false, has_blockers: false, ready_to_merge: false });
check('missing checks/review fall back to ? and ○', r.glyphs.join('') === '?○');

console.log('\nSession label pills:');
const LABELS = [{ name: 'bug', color: 'd73a4a' }, { name: 'web' }, { name: 'p1' }, { name: 'infra' }];
T.hideDetails = false;
r = render({ has_pr: false }, { labels: LABELS });
let pills = [...r.row.querySelectorAll('.label-pill')];
check('capped at 2 + a "+N" pill', pills.length === 3);
check('first two label names shown', pills[0].textContent === 'bug' && pills[1].textContent === 'web');
check('overflow pill reads +2', pills[2].textContent === '+2');
check('overflow pill lists the rest in its title', pills[2].getAttribute('title') === 'p1, infra');
// jsdom normalizes a hex color to rgb(); the second pill has no color and
// keeps the stylesheet default, so an empty inline color proves it wasn't set.
check('color applied when provided', pills[0].style.color === 'rgb(215, 58, 74)');
check('no inline color when the label has none', pills[1].style.color === '');
r = render({ has_pr: false }, { labels: [{ name: 'bug' }] });
check('no "+N" when nothing is hidden', r.row.querySelectorAll('.label-pill').length === 1);
r = render({ has_pr: false }, {});
check('no label row when the session has no labels', !r.row.querySelector('.label-row'));

T.hideDetails = true;
r = render({ has_pr: false }, { labels: LABELS });
check('hidden under hideSessionDetails', !r.row.querySelector('.label-row'));
check('PR pill still shown under hideSessionDetails', !!badge(r.row));
T.hideDetails = false;

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
