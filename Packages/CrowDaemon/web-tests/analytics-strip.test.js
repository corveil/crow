const { JSDOM } = require('jsdom');
const vm = require('vm');
const { loadClientSource } = require('./load-client');

// CROW-1439: the session-header analytics strip (CROW-722) now renders on
// Manager sessions too. A Manager's numbers are its current ISO-week rollup,
// shipped with `weekStartMillis`, which earns the strip a `This week` label so
// it isn't read as a lifetime total. Work-session strips are unchanged.
const epilogue = `
;globalThis.__t = {
  renderHeader(s){ return renderHeader(s); },
  set sessions(v){ sessions = v; },
  set selectedId(v){ selectedId = v; },
  set live(v){ liveById = v; },
};
`;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="app"></div>
     <div id="sidebar"></div>
     <header id="detail-header"></header>
     <div id="tabbar"></div>
     <div id="board"></div>
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
try { vm.runInContext(loadClientSource() + epilogue, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run'); process.exit(2); }

let failed = 0;
function check(name, ok) {
  if (ok) console.log('  ok  ' + name);
  else { failed++; console.log('  FAIL ' + name); }
}

const ID = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';
const BASE = {
  totalCost: 3.5, inputTokens: 100, outputTokens: 50, cacheReadTokens: 0,
  cacheCreationTokens: 0, totalTokens: 150, activeTimeSeconds: 600,
  toolCallCount: 7, linesAdded: 0, linesRemoved: 0, apiErrorCount: 0,
};

function strip() { return window.document.querySelector('#detail-header .analytics-strip'); }
function windowLabel() { return window.document.querySelector('#detail-header .analytics-window'); }
function chipLabels() {
  const s = strip();
  return s ? [...s.querySelectorAll('.score-chip-label')].map((n) => n.textContent.trim()) : [];
}
function render(kind, analytics) {
  T.sessions = [];
  T.selectedId = null;
  T.live = analytics ? { [ID]: { analytics } } : {};
  T.renderHeader({ id: ID, name: kind + ' sess', status: 'active', kind });
}

console.log('Manager sessions render the strip, labeled This week:');
{
  render('manager', Object.assign({ source: 'week', weekStartMillis: Date.UTC(2026, 10, 9), compactionCount: 2 }, BASE));
  check('manager has a strip', !!strip());
  check('manager strip is labeled This week', !!windowLabel() && windowLabel().textContent === 'This week');
  check('label sits first in the strip', !!strip() && strip().firstChild === windowLabel());
  check('manager shows the work-session chips', ['Est. cost', 'Tokens', 'Tools', 'Active'].every((l) => chipLabels().includes(l)));
  check('manager shows its week\'s compactions', chipLabels().includes('Compactions'));
  check('manager has no lifetime Duration chip', !chipLabels().includes('Duration'));

  render('manager', Object.assign({ source: 'week', weekStartMillis: Date.UTC(2026, 10, 9) }, BASE));
  check('no compactions counted → no Compactions chip', !chipLabels().includes('Compactions'));

  render('manager', null);
  check('an empty Manager week renders no strip', !strip());
}

console.log('\nwork sessions are unchanged:');
{
  render('work', Object.assign({ source: 'live', wallClockDurationSeconds: 1200 }, BASE));
  check('work has a strip', !!strip());
  check('work strip has no window label', !windowLabel());
  check('work chips are Est. cost/Tokens/Tools/Active/Duration',
    chipLabels().join('|') === 'Est. cost|Tokens|Tools|Active|Duration');
  render('work', null);
  check('work with no analytics renders no strip', !strip());
}

if (failed) { console.log('\n' + failed + ' failed'); process.exit(1); }
console.log('\nall passed');
