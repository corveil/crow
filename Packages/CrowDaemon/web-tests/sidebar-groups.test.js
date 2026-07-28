const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// Sidebar grouping/dedup regression tests (CROW-877). Runs the REAL app.js in a
// jsdom VM and drives `groupSessions` directly — the pure section-assignment
// helper behind renderSidebar. Same loader shape as row.test.js / board.test.js.
const epilogue = `
;globalThis.__t = {
  groupSessions(list){ return groupSessions(list); },
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

// Map the grouped output to { title -> [ids] } for concise assertions.
function groupsOf(list) {
  const out = {};
  for (const g of T.groupSessions(list)) out[g.title] = g.rows.map((s) => s.id);
  return out;
}
// Flat count of every rendered row across all sections.
function rowCount(list) {
  return T.groupSessions(list).reduce((n, g) => n + g.rows.length, 0);
}
// The select-all id set for a section (survivors + PR-collapsed rows).
function allIdsFor(list, title) {
  const g = T.groupSessions(list).find((x) => x.title === title);
  return g ? g.allIds : [];
}

const PR = (n) => `https://github.com/corveil/crow/pull/${n}`;
const prLink = (n) => [{ label: `PR #${n}`, url: PR(n), type: 'pr' }];

console.log('CROW-877 sidebar grouping:');

// 1. First-match: a review session that is also inReview lands only in Reviews.
{
  const s = { id: 'r1', kind: 'review', status: 'inReview', links: prLink(1) };
  const g = groupsOf([s]);
  check('review+inReview appears only in Reviews (first-match)',
    (g['Reviews'] || []).includes('r1') && !(g['In Review'] || []).includes('r1'));
  check('review+inReview renders exactly one row total', rowCount([s]) === 1);
}

// 2. A live work session is NEVER hidden by an open review clone for the same
//    PR. Collapse runs within a section, not across, so an active work row in
//    "Active" and its open review clone in "Reviews" both survive (CROW-877
//    review, Red 1 — a pre-assignment collapse dropped the developer's live row).
{
  const work = { id: 'w2', kind: 'work', status: 'active', links: prLink(2) };
  const rev = { id: 'v2', kind: 'review', status: 'active', links: prLink(2) };
  const g = groupsOf([work, rev]);
  check('active work row stays in Active', (g['Active'] || []).includes('w2'));
  check('open review clone stays in Reviews', (g['Reviews'] || []).includes('v2'));
  check('a live work session is never hidden by its open review', rowCount([work, rev]) === 2);
}

// 2b. A survivor is never a row that matches no group. A `paused` work row
//     matches no GROUP; collapsing it in would drop the completed review that
//     WOULD render, printing "No sessions" while sessions exist (CROW-877
//     review, Red 2). Within-section collapse can't do this.
{
  const work = { id: 'w2b', kind: 'work', status: 'paused', links: prLink(12) };
  const rev = { id: 'v2b', kind: 'review', status: 'completed', links: prLink(12) };
  const g = groupsOf([work, rev]);
  check('completed review still renders when the other row matches no group',
    (g['Completed'] || []).includes('v2b'));
  check('no-group work row does not suppress a renderable review', rowCount([work, rev]) === 1);
}

// 3. Once the review closes, the work row represents the PR.
{
  const work = { id: 'w3', kind: 'work', status: 'completed', links: prLink(3) };
  const rev = { id: 'v3', kind: 'review', status: 'completed', links: prLink(3) };
  const g = groupsOf([work, rev]);
  check('closed review yields to the work row in Completed',
    (g['Completed'] || []).includes('w3') && !(g['Completed'] || []).includes('v3'));
  check('merged PR renders one Completed row', rowCount([work, rev]) === 1);
}

// 4. Pile-up of identical completed review clones collapses to one row.
{
  const clones = [1, 2, 3].map((i) => ({ id: `c${i}`, kind: 'review', status: 'completed', links: prLink(4) }));
  check('N completed review clones for one PR collapse to a single row', rowCount(clones) === 1);
}

// 5. Duplicate session ids render once.
{
  const dup = [
    { id: 'd5', kind: 'work', status: 'active' },
    { id: 'd5', kind: 'work', status: 'active' },
  ];
  check('duplicate ids dedup to one row', rowCount(dup) === 1);
}

// 6. Distinct PRs are never collapsed together.
{
  const a = { id: 'a6', kind: 'review', status: 'active', links: prLink(6) };
  const b = { id: 'b6', kind: 'review', status: 'active', links: prLink(7) };
  check('different PRs stay as separate rows', rowCount([a, b]) === 2);
}

// 7. Sessions without a PR link are never collapsed and keep their section.
{
  const a = { id: 'n7', kind: 'work', status: 'active' };
  const b = { id: 'm7', kind: 'work', status: 'active' };
  const g = groupsOf([a, b]);
  check('PR-less work rows both render in Active',
    (g['Active'] || []).length === 2);
}

// 8. Managers drop out of the grouped output (rendered separately by renderSidebar).
{
  const mgr = { id: 'mg8', kind: 'manager', status: 'inReview' };
  check('manager sessions are excluded from all groups', rowCount([mgr]) === 0);
}

// 9. Two LIVE sessions for one PR in the same section are never collapsed — a
//    manual "Start Review" racing the auto-review clone lands two open reviews
//    in "Reviews", and hiding either would strand a running agent (CROW-877
//    review, Yellow 1). Collapse is gated to terminal rows only.
{
  const r1 = { id: 'live1', kind: 'review', status: 'active', links: prLink(9) };
  const r2 = { id: 'live2', kind: 'review', status: 'inReview', links: prLink(9) };
  const g = groupsOf([r1, r2]);
  check('two open reviews for one PR both stay in Reviews',
    (g['Reviews'] || []).includes('live1') && (g['Reviews'] || []).includes('live2'));
  check('a live session is never collapsed away', rowCount([r1, r2]) === 2);
}

// 10. Two independent WORK/JOB sessions sharing a PR are never collapsed — only
//     a review-clone pair folds. Two completed work sessions on one PR (a
//     follow-up session, or a manual `add-link`) would otherwise silently lose
//     one, worktree and branch stranded on disk (CROW-877 review, Yellow 2).
{
  const w1 = { id: 'ww1', kind: 'work', status: 'completed', links: prLink(10) };
  const w2 = { id: 'ww2', kind: 'work', status: 'archived', links: prLink(10) };
  const g = groupsOf([w1, w2]);
  check('two work rows for one PR both render (not a clone pair)',
    (g['Completed'] || []).includes('ww1') && (g['Completed'] || []).includes('ww2'));
  check('work+work sharing a PR is never collapsed', rowCount([w1, w2]) === 2);
}

// 11. A collapsed review clone stays reachable for bulk-delete: the section's
//     select-all id set (`allIds`) includes the folded-away clone even though it
//     renders no row (CROW-877 review, Yellow 3).
{
  const work = { id: 'w11', kind: 'work', status: 'completed', links: prLink(11) };
  const clone = { id: 'c11', kind: 'review', status: 'completed', links: prLink(11) };
  check('merged PR renders only the work row', rowCount([work, clone]) === 1);
  const ids = allIdsFor([work, clone], 'Completed');
  check('select-all still reaches the collapsed review clone',
    ids.includes('w11') && ids.includes('c11'));
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
