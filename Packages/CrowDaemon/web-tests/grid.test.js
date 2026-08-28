const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-1153 session grid: roster/pin/pagination/layout helpers and the Grid
// nav pill, driven against the real app.js under jsdom. Snapshot painting
// needs xterm.js, which this harness does not load — those paths no-op when
// `Terminal` is missing, which is the same degradation a failed asset fetch
// would hit in production.
const epilogue = `
;globalThis.__t = {
  GRID_PAGE_SIZE: () => GRID_PAGE_SIZE,
  gridColsForCount: (n) => gridColsForCount(n),
  gridRoster: (list, pins) => gridRoster(list, pins),
  gridActivityRank: (s) => gridActivityRank(s),
  isGridPinned: (id) => isGridPinned(id),
  toggleGridPin: (id) => toggleGridPin(id),
  moveGridPin: (id, d) => moveGridPin(id, d),
  get gridPinnedIds(){ return gridPinnedIds; },
  set gridPinnedIds(v){ gridPinnedIds = v; },
  get gridPage(){ return gridPage; },
  set gridPage(v){ gridPage = v; },
  get sessions(){ return sessions; },
  set sessions(v){ sessions = v; },
  get selectedBoard(){ return selectedBoard; },
  set selectedBoard(v){ selectedBoard = v; },
  sidebarLeftStack(){ return sidebarLeftStack(); },
  sessionMenuItems: (s) => sessionMenuItems(s),
  renderBoard(){ return renderBoard(); },
  selectBoard: (k) => selectBoard(k),
  parseRoute: (h) => parseRoute(h),
  routeToHash: (r) => routeToHash(r),
  GRID_PINS_KEY: () => GRID_PINS_KEY,
  stubPaint(){
    renderSidebar = function(){};
    refreshBoard = async function(){};
    refreshAllowlist = async function(){};
    refreshGridSnapshots = async function(){};
    startGridPolling = function(){};
    stopGridPolling = function(){};
  },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

const MARKUP = `<!doctype html><html><body>
  <div id="app">
    <button id="back-to-sidebar"></button>
    <aside id="sidebar"></aside>
    <main id="detail">
      <header id="detail-header"></header>
      <div id="detail-artifacts"></div>
      <div id="tabbar"></div>
      <div id="terminal-wrap"><div id="terminal"></div></div>
      <div id="board"></div>
      <div id="detail-empty"><div class="empty-msg">Select a session</div></div>
    </main>
  </div>
  <div id="statusbar"></div>
</body></html>`;

function load() {
  const dom = new JSDOM(MARKUP, {
    runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/',
  });
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
  T.window = window;
  T.document = window.document;
  T.stubPaint();
  return T;
}

let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };
const eq = (name, a, b) => check(name, JSON.stringify(a) === JSON.stringify(b));

const sess = (id, extra) => Object.assign({
  id, name: id, status: 'active', kind: 'work', activity: 'idle',
}, extra || {});

console.log('gridColsForCount — 1 / 2×2 / 3×3 / 4×4:');
{
  const T = load();
  check('0 → 1 col (empty still lays out)', T.gridColsForCount(0) === 1);
  check('1 → 1', T.gridColsForCount(1) === 1);
  check('2 → 2', T.gridColsForCount(2) === 2);
  check('4 → 2', T.gridColsForCount(4) === 2);
  check('5 → 3', T.gridColsForCount(5) === 3);
  check('9 → 3', T.gridColsForCount(9) === 3);
  check('10 → 4', T.gridColsForCount(10) === 4);
  check('16 → 4', T.gridColsForCount(16) === 4);
}

console.log('\ngridRoster — pins lead, then active auto-fill:');
{
  const T = load();
  const list = [
    sess('a', { activity: 'idle', name: 'alpha' }),
    sess('b', { activity: 'working', name: 'bravo' }),
    sess('c', { status: 'completed', name: 'charlie' }),
    sess('d', { status: 'archived', name: 'delta' }),
    sess('e', { activity: 'waiting', name: 'echo' }),
  ];
  const roster = T.gridRoster(list, ['c', 'missing']);
  eq('pinned completed session is included first', roster.map((s) => s.id), ['c', 'b', 'e', 'a']);
  check('missing pin is skipped', roster.every((s) => s.id !== 'missing'));
  check('archived unpinned is excluded', roster.every((s) => s.id !== 'd'));
}

console.log('\ngridRoster — activity sort of the auto-fill tail:');
{
  const T = load();
  const list = [
    sess('idle', { activity: 'idle', name: 'z' }),
    sess('work', { activity: 'working', name: 'z' }),
    sess('wait', { activity: 'waiting', name: 'z' }),
    sess('attn', { activity: 'idle', attention: 'question', name: 'z' }),
    sess('done', { activity: 'done', name: 'z' }),
  ];
  eq('attention, working, waiting, done, idle',
    T.gridRoster(list, []).map((s) => s.id),
    ['attn', 'work', 'wait', 'done', 'idle']);
}

console.log('\npin persistence:');
{
  const T = load();
  T.gridPinnedIds = [];
  T.toggleGridPin('s1');
  T.toggleGridPin('s2');
  check('pin appends', T.isGridPinned('s1') && T.isGridPinned('s2'));
  eq('order is insertion order', T.gridPinnedIds, ['s1', 's2']);
  T.moveGridPin('s2', -1);
  eq('move earlier swaps', T.gridPinnedIds, ['s2', 's1']);
  T.toggleGridPin('s2');
  check('unpin removes', !T.isGridPinned('s2') && T.isGridPinned('s1'));
  const stored = JSON.parse(T.window.localStorage.getItem(T.GRID_PINS_KEY()));
  eq('localStorage matches', stored, ['s1']);
}

console.log('\npage size:');
{
  const T = load();
  check('page size is 16', T.GRID_PAGE_SIZE() === 16);
}

console.log('\nnav pill:');
{
  const T = load();
  const stack = T.sidebarLeftStack();
  const pills = [...stack.querySelectorAll('.nav-pill .pill-label')].map((n) => n.textContent);
  check('Grid is a nav pill', pills.indexOf('Grid') !== -1);
  check('Grid sits before Reviews', pills.indexOf('Grid') < pills.indexOf('Reviews'));
}

console.log('\ncontext menu Pin to grid:');
{
  const T = load();
  T.gridPinnedIds = [];
  const items = T.sessionMenuItems(sess('x'));
  check('unpinned session offers Pin to grid', items.some((it) => it.label === 'Pin to grid'));
  T.gridPinnedIds = ['x'];
  const items2 = T.sessionMenuItems(sess('x'));
  check('pinned session offers Unpin from grid', items2.some((it) => it.label === 'Unpin from grid'));
}

console.log('\nroute:');
{
  const T = load();
  eq('parse #/grid', T.parseRoute('#/grid'), { view: 'board', board: 'grid' });
  eq('hash for grid', T.routeToHash({ view: 'board', board: 'grid' }), '#/grid');
}

console.log('\nrender empty grid:');
{
  const T = load();
  T.sessions = [];
  T.gridPinnedIds = [];
  T.selectedBoard = 'grid';
  T.renderBoard();
  const board = T.document.getElementById('board');
  check('board takes the grid class', board.className.indexOf('session-grid-board') !== -1);
  check('empty state copy mentions pin', /Pin a session/.test(board.textContent));
}

console.log('\nrender populated grid cells:');
{
  const T = load();
  T.sessions = [sess('one', { name: 'alpha', activity: 'working' }), sess('two', { name: 'bravo' })];
  T.gridPinnedIds = ['one'];
  T.selectedBoard = 'grid';
  T.renderBoard();
  const board = T.document.getElementById('board');
  const cells = board.querySelectorAll('.grid-cell');
  check('two cells', cells.length === 2);
  check('pinned cell marked', cells[0].className.indexOf('pinned') !== -1);
  check('cell header shows the name', cells[0].querySelector('.grid-cell-name').textContent === 'alpha');
  check('cell is keyed by session id', cells[0].dataset.sessionId === 'one');
  const grid = board.querySelector('.session-grid');
  check('2 sessions → 2 columns', grid && grid.style.getPropertyValue('--grid-cols') === '2');
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
