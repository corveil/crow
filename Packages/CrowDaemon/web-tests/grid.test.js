const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

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
  get selectedId(){ return selectedId; },
  set selectedId(v){ selectedId = v; },
  get sessionCameFromGrid(){ return sessionCameFromGrid; },
  set sessionCameFromGrid(v){ sessionCameFromGrid = v; },
  sidebarLeftStack(){ return sidebarLeftStack(); },
  sessionMenuItems: (s) => sessionMenuItems(s),
  renderBoard(){ return renderBoard(); },
  renderHeader: (s) => renderHeader(s),
  selectBoard: (k) => selectBoard(k),
  selectSession: (id, o) => selectSession(id, o),
  handleSessionFromGridEscape: (e) => handleSessionFromGridEscape(e),
  returnToGridFromSession: () => returnToGridFromSession(),
  get uiConfig(){ return uiConfig; },
  set uiConfig(v){ Object.assign(uiConfig, v); },
  parseRoute: (h) => parseRoute(h),
  routeToHash: (r) => routeToHash(r),
  GRID_PINS_KEY: () => GRID_PINS_KEY,
  spySelectSession(sink) {
    selectSession = async function (id, opts) { sink.push({ id, opts: opts || null }); };
  },
  spySelectBoard(sink) {
    selectBoard = function (k) { sink.push(k); selectedBoard = k; selectedId = null; };
  },
  stubPaint(){
    renderSidebar = function(){};
    refreshBoard = async function(){};
    refreshAllowlist = async function(){};
    refreshGridSnapshots = async function(){};
    startGridPolling = function(){};
    stopGridPolling = function(){};
    refreshLive = async function(){};
    refreshArtifacts = async function(){};
    ensureTerminal = function(){};
    fitTerminal = function(){};
    renderTabs = function(){};
  },
};
`;
const appjs = loadClientSource() + epilogue;

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
  <div id="lightbox" hidden><img id="lightbox-img" alt=""></div>
  <div id="session-switcher" class="session-switcher" hidden></div>
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

function escEvent(extra) {
  const e = {
    type: 'keydown', key: 'Escape', altKey: false, ctrlKey: false, metaKey: false,
    repeat: false, defaultPrevented: false, prevented: 0, stopped: 0,
    preventDefault() { e.prevented++; e.defaultPrevented = true; },
    stopPropagation() { e.stopped++; },
  };
  return Object.assign(e, extra || {});
}

console.log('\nCROW-1163 — grid cell click marks fromGrid provenance:');
{
  const T = load();
  const sink = [];
  T.spySelectSession(sink);
  T.sessions = [sess('one', { name: 'alpha' })];
  T.selectedBoard = 'grid';
  T.renderBoard();
  const board = T.document.getElementById('board');
  board.querySelector('.grid-term').onclick();
  check('cell click passes fromGrid', sink.length === 1 && sink[0].id === 'one'
    && sink[0].opts && sink[0].opts.fromGrid === true);
  sink.length = 0;
  board.querySelector('.grid-cell-name').onclick({ stopPropagation() {} });
  check('name click passes fromGrid', sink.length === 1 && sink[0].id === 'one'
    && sink[0].opts && sink[0].opts.fromGrid === true);
}

console.log('\nCROW-1163 — selectSession sets / clears sessionCameFromGrid:');
{
  const T = load();
  T.sessions = [sess('one')];
  // Flag is assigned synchronously, before the first await.
  T.selectSession('one', { fromGrid: true });
  check('fromGrid: true sets the flag', T.sessionCameFromGrid === true);
  T.selectSession('one');
  check('a later selectSession without fromGrid clears it', T.sessionCameFromGrid === false);
  T.sessionCameFromGrid = true;
  T.selectSession('one', { fromRoute: true });
  check('fromRoute does not keep a stale flag', T.sessionCameFromGrid === false);
}

console.log('\nCROW-1163 — ‹ Grid header affordance:');
{
  const T = load();
  const s = sess('one', { name: 'alpha', kind: 'work' });
  T.sessions = [s];
  T.sessionCameFromGrid = false;
  T.selectedId = 'one';
  T.renderHeader(s);
  check('no back control when not from grid',
    !T.document.getElementById('detail-header').querySelector('.back-to-grid'));
  T.sessionCameFromGrid = true;
  T.renderHeader(s);
  const btn = T.document.getElementById('detail-header').querySelector('.back-to-grid');
  check('‹ Grid button renders', !!(btn && btn.textContent === '‹ Grid'));
  check('title teaches Esc', btn && /Esc/.test(btn.title));
  const boards = [];
  T.spySelectBoard(boards);
  T.selectedId = 'one';
  T.selectedBoard = null;
  btn.onclick();
  check('click returns to the grid board', boards.length === 1 && boards[0] === 'grid');
  T.uiConfig = { switcherEnabled: true, switcherBinding: 'esc+tab' };
  T.sessionCameFromGrid = true;
  T.renderHeader(s);
  const btnEscTab = T.document.getElementById('detail-header').querySelector('.back-to-grid');
  check('esc+tab binding does not teach Esc on the control',
    btnEscTab && btnEscTab.title === 'Back to grid');
}

console.log('\nCROW-1163 — Escape → grid only from chrome, never from xterm:');
{
  const T = load();
  T.sessionCameFromGrid = true;
  T.selectedId = 'one';
  T.selectedBoard = null;
  const boards = [];
  T.spySelectBoard(boards);

  const hit = escEvent();
  T.handleSessionFromGridEscape(hit);
  check('Escape from chrome returns to grid', boards[0] === 'grid' && hit.prevented === 1);

  boards.length = 0;
  T.selectedId = 'one';
  T.selectedBoard = null;
  T.sessionCameFromGrid = true;
  const term = T.document.getElementById('terminal');
  const ta = T.document.createElement('textarea');
  term.appendChild(ta);
  ta.focus();
  const fromTerm = escEvent();
  T.handleSessionFromGridEscape(fromTerm);
  check('Escape while xterm focused is ignored', boards.length === 0 && fromTerm.prevented === 0);

  ta.blur();
  T.sessionCameFromGrid = false;
  T.selectedId = 'one';
  T.selectedBoard = null;
  const notFromGrid = escEvent();
  T.handleSessionFromGridEscape(notFromGrid);
  check('Escape is ignored when the session was not opened from the grid',
    boards.length === 0 && notFromGrid.prevented === 0);

  T.sessionCameFromGrid = true;
  T.document.getElementById('lightbox').hidden = false;
  const overlay = escEvent();
  T.handleSessionFromGridEscape(overlay);
  check('Escape is ignored while the lightbox is open',
    boards.length === 0 && overlay.prevented === 0);

  T.document.getElementById('lightbox').hidden = true;
  const menu = T.document.createElement('div');
  menu.className = 'ctx-menu';
  T.document.body.appendChild(menu);
  const menuEsc = escEvent();
  T.handleSessionFromGridEscape(menuEsc);
  check('Escape closes a context menu instead of leaving the session',
    boards.length === 0 && !T.document.querySelector('.ctx-menu') && menuEsc.prevented === 1);

  T.selectedId = 'one';
  T.selectedBoard = null;
  T.sessionCameFromGrid = true;
  T.uiConfig = { switcherEnabled: true, switcherBinding: 'esc+tab' };
  const prefix = escEvent();
  T.handleSessionFromGridEscape(prefix);
  check('esc+tab binding: Escape is not consumed so the prefix can arm',
    boards.length === 0 && prefix.prevented === 0 && prefix.stopped === 0);
  T.uiConfig = { switcherEnabled: false, switcherBinding: 'esc+tab' };
  const disabled = escEvent();
  T.handleSessionFromGridEscape(disabled);
  check('disabled switcher does not keep Escape from the grid',
    boards.length === 1 && boards[0] === 'grid' && disabled.prevented === 1);
}

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
