const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// CROW-983: the Manager card is metered like a work week — chips, an
// efficiency grade, and per-Manager grouping — while staying visibly out of
// the graded aggregate. #767 shipped the card with no render coverage at all;
// these drive the real `renderScorecard` against a synthetic DTO.
const epilogue = `
;globalThis.__t = {
  get boardData(){return boardData;},
  set selectedBoard(v){selectedBoard=v;},
  renderBoard(){ return renderBoard(); },
  groupManagerWeeks(w){ return groupManagerWeeks(w); },
  gradeBadgeEl(g){ return gradeBadgeEl(g); },
  set liveById(v){liveById=v;},
  renderSessionAnalyticsStrip(s, root){ return renderSessionAnalyticsStrip(s, root); },
  get COST_ESTIMATE_TOOLTIP(){return COST_ESTIMATE_TOOLTIP;},
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

const MONDAY = Date.UTC(2026, 6, 13);
const WEEK = 7 * 86400 * 1000;
const PRIMARY = '00000000-0000-0000-0000-000000000000';
const SECOND = 'bbbbbbbb-0000-0000-0000-000000000002';

const grade = (letter, score, deductions) => ({
  graded: true, score, letter, deductions: deductions || [], promptCount: null,
});

function managerWeek(over) {
  return Object.assign({
    weekStartMillis: MONDAY,
    sessionID: PRIMARY,
    sessionName: 'Manager',
    grade: grade('B', 85, [{ metric: 'cacheHitRatio', points: 5, label: '52% cache hit ratio' }]),
    promptCount: 86,
    totalTokens: 2400000,
    totalCost: 12.4,
    activeTimeSeconds: 15120,
    commitCount: 4,
    toolCallCount: 310,
    compactionsPerActiveHour: 1.5,
    inputTokensPerPrompt: 18200,
    cacheHitRatio: 0.74,
    apiErrorRate: 0.004,
  }, over || {});
}

// A minimal graded side of the DTO so renderScorecard's other cards build.
const emptyGrade = { graded: false, score: null, letter: null, deductions: [], promptCount: 0 };
const week = {
  weekStartMillis: MONDAY, grade: emptyGrade, sessionsShipped: 0, costPerShipped: null,
  sessionCount: 0, totalCost: 0, activeTimeSeconds: 0, commitCount: 0, churnHint: 0,
  combined: { scored: false, value: null, shippedCount: null, alignmentFactor: null,
    efficiencyMultiplier: null, gradeScore: null, hygieneFactor: null, revertCount: null,
    postMergeFixCount: null, mergeRate: null, promptCount: 0 },
  compactionsPerActiveHour: 0, inputTokensPerPrompt: 0, cacheHitRatio: 0, apiErrorRate: 0,
};
const baseline = { weeksAvailable: 0, medianScore: null, medianCompactionsPerActiveHour: null,
  medianInputTokensPerPrompt: null, medianCacheHitRatio: null, medianApiErrorRate: null,
  medianCostPerShipped: null, medianCombinedScore: null };

function payload(managerWeeks) {
  return {
    telemetryEnabled: true, snapshotCount: 0,
    currentWeek: week, priorWeeks: [], baseline, sessions: [],
    managerWeeks: managerWeeks,
    telemetryCapturing: true, telemetrySessionCount: 2, telemetryLastReceivedAtMillis: MONDAY,
    minimumBaselineWeeks: 2, baselineWeekCount: 4, minimumGradablePromptCount: 5,
  };
}

const q = (sel) => window.document.querySelectorAll(sel);
const board = window.document.getElementById('board');
let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };
function render(managerWeeks) {
  T.boardData.scorecard = payload(managerWeeks);
  T.selectedBoard = 'scorecard';
  T.renderBoard();
}
const textOf = (sel) => Array.from(q(sel)).map((n) => n.textContent);

console.log('Single Manager, one week:');
render([managerWeek()]);
const chipLabels = textOf('.score-manager-week-block .score-chip-label');
check('week block rendered', q('.score-manager-week-block').length === 1);
check('chips use the shared chip vocabulary', q('.score-manager-week-block .score-chip').length === 8);
check('active time chip', chipLabels.includes('Active'));
check('cache chip', chipLabels.includes('Cache'));
check('tokens-per-prompt chip', chipLabels.includes('Tok/Prompt'));
check('api errors chip', chipLabels.includes('API Errors'));
check('compactions chip', chipLabels.includes('Compact/hr'));
check('tool calls chip', chipLabels.includes('Tools'));
check('commits chip', chipLabels.includes('Commits'));

const chipValues = textOf('.score-manager-week-block .score-chip-value');
check('active time formatted h/m', chipValues.includes('4h 12m'));
check('cache ratio formatted as a percent', chipValues.includes('74%'));
check('api error rate keeps a decimal', chipValues.includes('0.4%'));
check('tokens/prompt abbreviated', chipValues.includes('18.2K'));
check('compaction rate to one decimal', chipValues.includes('1.5'));

console.log('\nEfficiency grade + the not-in-the-aggregate framing:');
check('efficiency badge rendered', q('.score-manager-week-block .score-badge').length === 1);
check('badge shows the letter', q('.score-manager-week-block .score-badge')[0].textContent === 'B');
check('deductions line rendered', q('.score-manager-week-block .score-session-deductions').length === 1);
check('pill says efficiency only', textOf('.score-ungraded').includes('efficiency only'));
check('explainer names the excluded outcome surfaces',
  Array.from(q('.score-muted')).some((n) =>
    /shipped count/.test(n.textContent) && /baseline/.test(n.textContent)));
// The Manager must never render an outcome surface.
check('no shipped count on a Manager week',
  !/shipped/.test(Array.from(q('.score-manager-week-block')).map((n) => n.textContent).join(' ')));

console.log('\nUngraded (below the prompt floor) Manager week:');
render([managerWeek({
  grade: { graded: false, score: null, letter: null, deductions: [], promptCount: 2 },
})]);
check('badge degrades to an em dash', q('.score-manager-week-block .score-badge')[0].textContent === '—');
check('no deductions line when ungraded', q('.score-manager-week-block .score-session-deductions').length === 0);
check('chips still render when ungraded', q('.score-manager-week-block .score-chip').length === 8);

console.log('\nMultiple Managers:');
render([
  managerWeek({ sessionID: PRIMARY, sessionName: 'Manager' }),
  managerWeek({ sessionID: PRIMARY, sessionName: 'Manager', weekStartMillis: MONDAY - WEEK }),
  managerWeek({ sessionID: SECOND, sessionName: 'Manager 2', totalCost: 3.1 }),
]);
check('one group heading per Manager', q('.score-manager-group').length === 2);
check('group headings name each Manager',
  JSON.stringify(textOf('.score-manager-group')) === JSON.stringify(['Manager', 'Manager 2']));
check('all three week blocks render', q('.score-manager-week-block').length === 3);

console.log('\nSingle Manager stays ungrouped:');
render([managerWeek()]);
check('no group heading for one Manager', q('.score-manager-group').length === 0);

console.log('\nGrouping helper:');
const grouped = T.groupManagerWeeks([
  managerWeek({ sessionID: SECOND, sessionName: 'Manager 2' }),
  managerWeek({ sessionID: PRIMARY, sessionName: 'Manager' }),
  managerWeek({ sessionID: SECOND, sessionName: 'Manager 2', weekStartMillis: MONDAY - WEEK }),
]);
check('groups preserve first-seen order', grouped.map((g) => g.name).join(',') === 'Manager 2,Manager');
check('weeks land in their own group', grouped[0].weeks.length === 2 && grouped[1].weeks.length === 1);
const unnamed = T.groupManagerWeeks([managerWeek({ sessionName: null })]);
check('a deleted Manager falls back to a generic name', unnamed[0].name === 'Manager');

console.log('\nEmpty state:');
// No snapshots AND no Manager weeks is the only path to the empty state. Its
// copy describes the Manager's posture, so it drifts the moment that posture
// changes — CROW-983's review caught it still saying "never graded". Pinned
// here so the next posture change has to update it too.
render([]);
const emptyMsg = Array.from(q('.score-empty-msg')).map((n) => n.textContent).join(' ');
check('empty state rendered', q('.score-empty-msg').length === 1);
check('empty state does not claim the Manager is never graded', !/never graded/.test(emptyMsg));
check('empty state does not call the section ungraded', !/ungraded/.test(emptyMsg));
check('empty state states the efficiency/outcomes split',
  /efficiency/.test(emptyMsg) && /outcome/.test(emptyMsg));

console.log('\nBack-compat with a pre-CROW-983 daemon:');
// managerWeeks absent entirely (pre-#767 daemon) must not throw.
const legacy = payload([]);
delete legacy.managerWeeks;
T.boardData.scorecard = legacy;
T.selectedBoard = 'scorecard';
let threw = false;
try { T.renderBoard(); } catch (e) { threw = true; console.log('  [threw] ' + e.message); }
check('missing managerWeeks does not throw', !threw);
check('no Manager card when there are no Manager weeks', q('.score-manager-week-block').length === 0);

console.log('\nGrade badge wash:');
const badge = T.gradeBadgeEl(grade('B', 85));
check('letter color is the grade token', badge.style.color === 'var(--grade-b)');
check('wash is a color-mix, not a hex alpha glued onto the variable',
  badge.style.background === 'color-mix(in srgb, var(--grade-b) 15%, transparent)');

console.log('\nCost reads as an API list-price estimate (CROW-1440):');
// Claude Code's cost metric is an estimate at API list prices, emitted however
// the session is billed — a subscription session pays nothing per token. No
// surface may label it a plain "Cost", and every bare figure carries `≈`.
const TIP = T.COST_ESTIMATE_TOOLTIP;
check('tooltip names the list-price estimate and the subscription caveat',
  /API list prices/.test(TIP) && /subscription/.test(TIP));
{
  const full = payload([managerWeek()]);
  full.snapshotCount = 1;
  full.currentWeek = Object.assign({}, week, {
    totalCost: 42.5, sessionsShipped: 2, costPerShipped: 21.25,
    grade: grade('C', 75, [{ metric: 'costPerShipped', points: 10, label: '≈$21.25 est. cost per shipped session' }]),
  });
  full.priorWeeks = [Object.assign({}, week, { weekStartMillis: MONDAY - WEEK, totalCost: 9 })];
  full.baseline = Object.assign({}, baseline, { weeksAvailable: 4, medianCostPerShipped: 18 });
  full.sessions = [{ grade: grade('A', 95), endedAtMillis: MONDAY, shipped: true,
    totalCost: 7.25, activeTimeSeconds: 600, wallClockDurationSeconds: null }];
  T.boardData.scorecard = full;
  T.selectedBoard = 'scorecard';
  T.renderBoard();
}
const allLabels = textOf('.score-chip-label');
check('no chip is labeled a plain Cost', !allLabels.some((l) => /^cost$/i.test(l.trim())));
const weekChip = Array.from(q('.score-chip')).find((c) =>
  c.querySelector('.score-chip-label').textContent === 'Est. cost');
check('this-week chip reads Est. cost', !!weekChip);
check('this-week chip carries the tooltip', weekChip && weekChip.title === TIP);
check('this-week chip value', weekChip && weekChip.querySelector('.score-chip-value').textContent === '$42.50');
check('this-week card explains the estimate in visible text (no tooltip on a phone)',
  Array.from(q('.score-muted')).some((n) => /API list prices/.test(n.textContent)));
const managerStat = q('.score-manager-stat')[0];
check('Manager week cost is prefixed ≈', managerStat && managerStat.textContent === '≈$12.40');
check('Manager week cost carries the tooltip', managerStat && managerStat.title === TIP);
const priorCost = q('.score-prior-cost')[0];
check('prior week cost is prefixed ≈', priorCost && priorCost.textContent === '≈$9.00');
check('prior week cost carries the tooltip', priorCost && priorCost.title === TIP);
const sessionCost = Array.from(q('.score-session-stat')).find((n) => n.textContent.startsWith('≈$'));
check('session row cost is prefixed ≈', sessionCost && sessionCost.textContent === '≈$7.25');
check('session row cost carries the tooltip', sessionCost && sessionCost.title === TIP);
const shippedSub = Array.from(q('.score-sub')).find((n) => /per shipped session/.test(n.textContent));
check('shipped card reads as an estimate',
  shippedSub && shippedSub.textContent === '≈$21.25 est. cost per shipped session');
check('shipped card carries the tooltip', shippedSub && shippedSub.title === TIP);
const cmp = Array.from(q('.score-comparison')).find((n) =>
  /cost/i.test(n.querySelector('.score-comparison-name').textContent));
check('baseline row is labeled Est. cost/shipped',
  cmp && cmp.querySelector('.score-comparison-name').textContent === 'Est. cost/shipped');
check('baseline row carries the tooltip', cmp && cmp.title === TIP);
check('no comparison row is named a plain Cost/shipped',
  !textOf('.score-comparison-name').includes('Cost/shipped'));

console.log('\nSession header analytics strip (CROW-1440):');
T.liveById = { s1: { analytics: { totalCost: 23.4, totalTokens: 1200000, toolCallCount: 170,
  activeTimeSeconds: 2100, wallClockDurationSeconds: null, linesAdded: 0, linesRemoved: 0, apiErrorCount: 0 } } };
const stripRoot = window.document.createElement('div');
T.renderSessionAnalyticsStrip({ id: 's1', kind: 'work' }, stripRoot);
const stripLabels = Array.from(stripRoot.querySelectorAll('.score-chip-label')).map((n) => n.textContent);
check('strip has no plain Cost chip', !stripLabels.includes('Cost'));
const stripCost = Array.from(stripRoot.querySelectorAll('.score-chip')).find((c) =>
  c.querySelector('.score-chip-label').textContent === 'Est. cost');
check('strip cost chip reads Est. cost', !!stripCost);
check('strip cost chip carries the tooltip', stripCost && stripCost.title === TIP);
check('strip cost chip value', stripCost && stripCost.querySelector('.score-chip-value').textContent === '$23.40');
const managerRoot = window.document.createElement('div');
T.renderSessionAnalyticsStrip({ id: 's1', kind: 'manager' }, managerRoot);
check('Manager sessions still render no strip', managerRoot.children.length === 0);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
