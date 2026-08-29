const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// Sidebar session-row regression tests (CROW-773) — PR-pill status glyphs,
// the crow:merge indicator, and ticket-label pills. Same loader shape as
// board.test.js: run the REAL app.js in a jsdom VM and drive `sessionRow`
// directly, with an epilogue exposing the module-scope state it reads.
const epilogue = `
;globalThis.__t = {
  sessionRow(s){ return sessionRow(s); },
  prStatusInline(pr, am, enabled, ar){ return prStatusInline(pr, am, enabled, ar); },
  set live(v){ liveById = v; },
  set hideDetails(v){ uiConfig.hideSessionDetails = v; },
};
`;
const appjs = loadClientSource() + epilogue;

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
// `autoMergeState` populates the live `auto_merge_state` sibling of `pr` (#888);
// `autoRebaseState` does the same for `auto_rebase_state` (#944).
function render(pr, overrides, autoMergeState, autoRebaseState) {
  const live = pr === undefined ? {} : { 'sess-1': { pr } };
  if (autoMergeState && live['sess-1']) live['sess-1'].auto_merge_state = autoMergeState;
  if (autoRebaseState && live['sess-1']) live['sess-1'].auto_rebase_state = autoRebaseState;
  T.live = live;
  const row = T.sessionRow({ ...SESSION, ...(overrides || {}) });
  return { row, glyphs: [...row.querySelectorAll('.pr-badge .pr-ico')].map((n) => n.textContent) };
}
const badge = (row) => row.querySelector('.pr-badge');
// Every icon child of the pill, in order. Parts with an `icon` render as SVG
// `.ico` spans and only glyph-only parts as `.pr-ico` text — the CROW-802 drift
// the `r.glyphs` assertions below still trip over. The auto-merge part is
// appended last, so its presence is a count delta and its tint is the last
// child's color; both are real structural assertions rather than a restatement
// of the aria-label.
const pillIcons = (row) => [...row.querySelectorAll('.pr-badge .ico, .pr-badge .pr-ico')];
const autoIco = (row) => {
  const icons = pillIcons(row);
  return icons.length ? icons[icons.length - 1] : null;
};
// checks ✔ + review ✔ + 🏷 = three icons before any auto-merge chip.
const GREEN_PR = { has_pr: true, checks: 'passing', review: 'approved', merge: 'mergeable',
  is_merged: false, has_blockers: false, ready_to_merge: true, failed_checks: [], has_merge_label: true };
const GREEN_PR_ICONS = 3;
const hasAutoChip = (row) => pillIcons(row).length === GREEN_PR_ICONS + 1;
// The auto-rebase chip is inserted BEFORE the auto-merge one (#944), so when
// both are present it is the second-to-last icon and `autoIco` keeps meaning
// "the auto-merge chip" for every pre-existing assertion above.
const hasRebaseChip = (row, withAutoMerge) =>
  pillIcons(row).length === GREEN_PR_ICONS + (withAutoMerge ? 2 : 1);
const rebaseIco = (row, withAutoMerge) => {
  const icons = pillIcons(row);
  const i = icons.length - (withAutoMerge ? 2 : 1);
  return i >= 0 ? icons[i] : null;
};

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
// `?.` guards a pre-existing CROW-802 selector drift: ✔/✕/⚠ now render as SVG
// `.ico` spans, not `.pr-ico` text, so `.pr-ico` is null here. Without the
// guard this line *throws* and aborts the whole file mid-run; with it the
// suite runs to completion so later sections (incl. the crow:merge checks
// below) execute and the exit code stops masking their pass/fail. Fixing the
// drift itself (so this assertion passes again) is CROW-802's own ticket.
check('glyph purple', r.row.querySelector('.pr-ico')?.style.color === 'var(--purple)');

console.log('\nConflicting PR adds a ⚠:');
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'conflicting',
  is_merged: false, has_blockers: true, ready_to_merge: false, failed_checks: [] });
check('three glyphs (checks, review, conflict)', r.glyphs.length === 3);
check('third glyph is ⚠', r.glyphs[2] === '⚠');

console.log('\ncrow:merge label vs auto-merge enabled (two independent signals):');
r = render(GREEN_PR);
check('🏷 present when has_merge_label', r.glyphs.includes('🏷'));
check('no ⛙ when auto_merge is false and no verdict', !hasAutoChip(r.row));
r = render({ has_pr: true, checks: 'passing', review: 'approved', merge: 'mergeable',
  is_merged: false, has_blockers: false, ready_to_merge: true, failed_checks: [] });
check('no 🏷 when has_merge_label absent', !r.glyphs.includes('🏷'));
r = render(GREEN_PR, { auto_merge: true });
check('🏷 and ⛙ can both show',
  hasAutoChip(r.row) && /crow:merge label/.test(badge(r.row).getAttribute('aria-label')));
// CROW-846: the visible chip dropped the redundant trailing "label", but the
// sidebar pill is glyph-only — its aria-label/title is the sole screen-reader
// channel, so the noun must survive there via PR_MERGE_LABEL_GLYPH.a11yLabel.
// Pin BOTH halves of that split so a later `p.a11yLabel || p.label` → `p.label`
// (or reverting `label` to `'crow:merge label'`) can't silently unwind either.
check('sidebar aria keeps the unambiguous "crow:merge label" noun',
  /crow:merge label/.test(badge(r.row).getAttribute('aria-label')));
const mergeChips = [...T.prStatusInline(GREEN_PR).querySelectorAll('.pr-stat-label')].map((n) => n.textContent);
check('detail chip reads the concise "crow:merge"', mergeChips.includes('crow:merge'));
check('detail chip drops the redundant "crow:merge label"', !mergeChips.includes('crow:merge label'));

// #888 — the whole point: a labeled PR that will never merge must not look like
// a healthy pending one. The ⛙ mark is shared; the TINT carries the verdict.
console.log('\nAuto-merge verdict (#888):');
const BLOCKED = { phase: 'blocked', reason: 'repo-disallows-auto-merge', permanent: true,
  message: 'corveil/corveil has GitHub\'s "Allow auto-merge" setting turned off.' };
r = render(GREEN_PR, {}, BLOCKED);
check('blocked verdict adds a ⛙ to the pill', hasAutoChip(r.row));
check('blocked ⛙ is red', autoIco(r.row).style.color === 'var(--red)');
check('the human sentence rides the pill tooltip', badge(r.row).title.includes(BLOCKED.message));
check('the human sentence is not sighted-only',
  badge(r.row).getAttribute('aria-label').includes(BLOCKED.message));
check('aria still names the blocked state itself',
  /Auto-merge blocked/.test(badge(r.row).getAttribute('aria-label')));

r = render(GREEN_PR, {}, { phase: 'stalled', reason: 'not-in-viewer-prs', permanent: false, message: 'Not in the last fetch.' });
check('stalled verdict is orange, not red', autoIco(r.row).style.color === 'var(--orange)');
r = render(GREEN_PR, {}, { phase: 'off', reason: 'watcher-off', permanent: false, message: 'The watcher is off.' });
check('watcher-off verdict is muted', autoIco(r.row).style.color === 'var(--text-muted)');
r = render(GREEN_PR, {}, { phase: 'enabled', reason: 'already-enabled', permanent: false, message: 'Waiting on GitHub.' });
check('enabled verdict is green', autoIco(r.row).style.color === 'var(--green)');
r = render(GREEN_PR, {}, { phase: 'merged', reason: 'direct-merge', permanent: false, message: 'Crow merged it directly.' });
check('direct-merge verdict is purple', autoIco(r.row).style.color === 'var(--purple)');

// The suppression contract: reasons the pill already renders (conflicts, review
// state) must never be re-reported as an auto-merge verdict, or the two
// surfaces start disagreeing about one PR — the exact thing CROW-773 fixed.
r = render({ ...GREEN_PR, merge: 'conflicting' }, {});
check('a conflicting PR gets no auto-merge chip of its own',
  !/Auto-merge/.test(badge(r.row).getAttribute('aria-label')));

r = render({ ...GREEN_PR, is_merged: true }, {}, BLOCKED);
check('merged PR drops the auto-merge chip',
  pillIcons(r.row).length === 1 && !/Auto-merge/.test(badge(r.row).getAttribute('aria-label')));

r = render(GREEN_PR, { auto_merge: true });
check('older daemon falls back to the persisted auto_merge flag',
  hasAutoChip(r.row) && autoIco(r.row).style.color === 'var(--green)');
r = render(GREEN_PR, { auto_merge: false });
check('no chip at all when there is nothing to report', !hasAutoChip(r.row));

check('the trailing ⛙ is gone — folded into the pill',
  !render(GREEN_PR, { auto_merge: true }).row.querySelector('.automerge'));

const blockedChips = [...T.prStatusInline(GREEN_PR, BLOCKED).querySelectorAll('.pr-stat')];
const blockedLabels = blockedChips.map((n) => n.querySelector('.pr-stat-label').textContent);
check('detail chip labels the blocked state', blockedLabels.includes('Auto-merge blocked'));
check('detail chip carries the sentence as a title',
  blockedChips.some((c) => c.title === BLOCKED.message));

// #944 — the auto-rebase verdict. Distinct from auto-merge by ICON (⟲ vs ⛙),
// sharing the severity TINT scale. It exists because `prStatusJSON` never ships
// `mergeStateStatus`: a PR that is BEHIND its base renders as a fully green
// pill, so a worktree wedged in `out-of-sync-diverged` had no surface at all.
console.log('\nAuto-rebase verdict (#944):');
const STUCK = { phase: 'blocked', reason: 'out-of-sync-diverged', permanent: true,
  message: 'Crow has tried to rebase this branch 5 times; reconcile it by hand.' };
r = render(GREEN_PR, {}, undefined, STUCK);
check('stuck verdict adds a ⟲ to the pill', hasRebaseChip(r.row, false));
check('stuck ⟲ is red', rebaseIco(r.row, false).style.color === 'var(--red)');
check('the human sentence rides the pill tooltip', badge(r.row).title.includes(STUCK.message));
check('the human sentence is not sighted-only',
  badge(r.row).getAttribute('aria-label').includes(STUCK.message));
check('aria names the stuck state itself',
  /Auto-rebase stuck/.test(badge(r.row).getAttribute('aria-label')));

r = render(GREEN_PR, {}, undefined,
  { phase: 'stalled', reason: 'dirty-worktree', permanent: false, message: 'Uncommitted changes.' });
check('stalled verdict is orange, not red',
  rebaseIco(r.row, false).style.color === 'var(--orange)');
check('aria distinguishes waiting from stuck',
  /Auto-rebase waiting/.test(badge(r.row).getAttribute('aria-label')));

// Both watchers can speak at once. Order is chronological — get the branch
// current, THEN merge it — which is also what keeps `autoIco` (last icon)
// meaning "auto-merge" for every assertion above.
r = render(GREEN_PR, {}, BLOCKED, STUCK);
check('both chips render together', hasRebaseChip(r.row, true));
check('rebase chip precedes the merge chip',
  rebaseIco(r.row, true).style.color === 'var(--red)'
  && autoIco(r.row).style.color === 'var(--red)'
  && rebaseIco(r.row, true) !== autoIco(r.row));
check('aria names both verdicts', (() => {
  const a = badge(r.row).getAttribute('aria-label');
  return /Auto-rebase stuck/.test(a) && /Auto-merge blocked/.test(a);
})());

r = render({ ...GREEN_PR, is_merged: true }, {}, undefined, STUCK);
check('merged PR drops the auto-rebase chip',
  pillIcons(r.row).length === 1 && !/Auto-rebase/.test(badge(r.row).getAttribute('aria-label')));

// Silence is the default: nothing opts a PR into auto-rebase, so an absent key
// (every pre-#944 daemon, and every healthy PR) must render nothing at all.
r = render(GREEN_PR, {});
check('no ⟲ when the daemon sends no verdict', !/Auto-rebase/.test(badge(r.row).getAttribute('aria-label')));

const stuckChips = [...T.prStatusInline(GREEN_PR, undefined, false, STUCK).querySelectorAll('.pr-stat')];
check('detail chip labels the stuck state',
  stuckChips.map((n) => n.querySelector('.pr-stat-label').textContent).includes('Rebase stuck'));
check('detail chip carries the rebase sentence as a title',
  stuckChips.some((c) => c.title === STUCK.message));

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

console.log('\nExploring badge (CROW-1149):');
r = render({ has_pr: false }, { is_explore: true, ticket_badge: 'Issue #42' });
check('Exploring badge on explore session', [...r.row.querySelectorAll('.explore-badge')].some((b) => b.textContent === 'Exploring'));
r = render({ has_pr: false }, { is_explore: false, ticket_badge: 'Issue #42' });
check('no Exploring badge on a work session', r.row.querySelectorAll('.explore-badge').length === 0);

T.hideDetails = true;
r = render({ has_pr: false }, { labels: LABELS });
check('hidden under hideSessionDetails', !r.row.querySelector('.label-row'));
check('PR pill still shown under hideSessionDetails', !!badge(r.row));
T.hideDetails = false;

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
