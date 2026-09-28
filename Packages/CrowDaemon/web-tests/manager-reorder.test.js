const vm = require('vm');
const { JSDOM } = require('jsdom');
const { loadClientSource } = require('./load-client');

// CROW-1294: extra Manager rows reorder among themselves. The nav pill is the
// primary (`is_primary_manager`), and the sidebar-ordered switcher follows
// the same Manager order. Jobs / Active stay grouped.
const epilogue = `
;globalThis.__t = {
  setSessions(v){ sessions = v; lastSidebarSig = null; },
  setLoaded(){ sessionsLoaded = true; },
  set selectionMode(v){ selectionMode = v; lastSidebarSig = null; },
  renderSidebar(){ return renderSidebar(); },
  reorderExtraManagers(list, movingId, beforeId){ return reorderExtraManagers(list, movingId, beforeId); },
  applyExtraManagerOrder(list, ids){ return applyExtraManagerOrder(list, ids); },
  switcherSidebarOrdered(list, include){ return switcherSidebarOrdered(list, include); },
  managerDropBeforeId(y, id){ return managerDropBeforeId(y, id); },
  commit(id, beforeId){ commitManagerReorder(id, beforeId); return managerReorderChain; },
  setRpc(fn){ rpc = fn; },
  alerts: [],
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
window.setTimeout = (fn) => { if (typeof fn === 'function') fn(); return 0; };
window.requestAnimationFrame = () => 0;
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
vm.runInContext('alertModal = (msg) => { globalThis.__t.alerts.push(String(msg)); };', ctx);
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run'); process.exit(2); }

let pass = 0, fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};

const PRIMARY = '00000000-0000-0000-0000-000000000000';
const mgr = (id, name, primary) => ({
  id, name, kind: 'manager', status: 'active', is_primary_manager: primary,
});
const INCLUDE = {
  managers: true, jobs: true, reviews: false,
  active: true, paused: false, in_review: false, completed: false, archived: false,
};
const rowNames = () =>
  [...window.document.querySelectorAll('#sidebar .session-row .name')].map((n) => n.textContent);

const base = () => [
  mgr('B', 'Beta', false),
  mgr('P', 'Primary', true),
  { id: 'W', name: 'Work', kind: 'work', status: 'active' },
  mgr('A', 'Alpha', false),
  { id: 'J', name: 'Job', kind: 'job', status: 'active' },
];

function flush() {
  return new Promise((resolve) => setImmediate(resolve));
}

async function main() {
  console.log('CROW-1294 extra Manager reorder:');

  T.setLoaded();
  T.setSessions(base());
  T.renderSidebar();
  const sidebar = window.document.getElementById('sidebar');
  const pill = sidebar.querySelector('.nav-pill[data-session-id]');
  check('pill is the primary, not the first Manager in the array',
    pill && pill.dataset.sessionId === 'P');
  check('extra Managers render in array order above the groups',
    rowNames().join(',') === 'Beta,Alpha,Job,Work');
  const dividers = [...sidebar.querySelectorAll('.divider')].map((n) => n.textContent);
  check('Jobs and Active stay grouped', dividers.join(',') === 'Jobs,Active');
  check('each extra Manager has a drag grip when there are two or more',
    sidebar.querySelectorAll('.mgr-grip').length === 2);
  check('work and job rows are not draggable',
    [...sidebar.querySelectorAll('.session-row')].filter((r) => !r.dataset.extraManager)
      .every((r) => !r.querySelector('.mgr-grip')));
  check('sidebar-ordered switcher lists primary then extras then groups',
    T.switcherSidebarOrdered(base(), INCLUDE).map((s) => s.id).join(',') === 'P,B,A,J,W');

  const moved = T.reorderExtraManagers(base(), 'B', null);
  check('move to end keeps the primary and the other rows in their slots',
    moved.map((s) => s.id).join(',') === 'A,P,W,B,J');
  check('a no-op drop returns the same list', T.reorderExtraManagers(moved, 'B', null) === moved);

  T.setSessions(moved);
  T.renderSidebar();
  check('sidebar paints the new extra order immediately',
    rowNames().join(',') === 'Alpha,Beta,Job,Work');
  check('pill is still the primary after the drop',
    window.document.querySelector('#sidebar .nav-pill[data-session-id]').dataset.sessionId === 'P');
  check('switcher follows the sidebar after the drop',
    T.switcherSidebarOrdered(moved, INCLUDE).map((s) => s.id).join(',') === 'P,A,B,J,W');

  const server = [
    mgr('A', 'Alpha-fresh', false),
    mgr('P', 'Primary', true),
    { id: 'W', name: 'Work', kind: 'work', status: 'active' },
    mgr('B', 'Beta-fresh', false),
  ];
  const merged = T.applyExtraManagerOrder(server, ['B', 'A']);
  check('overlay keeps server fields in the local extra order',
    merged.map((s) => s.name).join(',') === 'Beta-fresh,Primary,Work,Alpha-fresh');
  const withNew = T.applyExtraManagerOrder(server.concat([mgr('C', 'Gamma', false)]), ['B', 'A']);
  check('a Manager the local order has not seen yet lands at the end',
    withNew.filter((s) => s.kind === 'manager' && s.is_primary_manager === false).map((s) => s.id).join(',')
      === 'B,A,C');

  T.setSessions([
    mgr('E', 'Extra', false),
    { id: PRIMARY, name: 'Primary', kind: 'manager', status: 'active' },
  ]);
  T.renderSidebar();
  check('legacy cache without the flag still pills the well-known id',
    window.document.querySelector('#sidebar .nav-pill[data-session-id]').dataset.sessionId === PRIMARY);
  check('a single extra Manager has no grip',
    window.document.querySelectorAll('.mgr-grip').length === 0);

  T.selectionMode = true;
  T.setSessions([mgr('A', 'Alpha', false), mgr('P', 'Primary', true), mgr('B', 'Beta', false)]);
  T.renderSidebar();
  check('selection mode does not offer the grip',
    window.document.querySelectorAll('.mgr-grip').length === 0);
  T.selectionMode = false;

  T.setSessions([mgr('B', 'Beta', false), mgr('P', 'Primary', true), mgr('A', 'Alpha', false)]);
  T.renderSidebar();
  const rows = [...window.document.querySelectorAll('#sidebar .session-row[data-extra-manager]')];
  rows.forEach((row, i) => {
    row.getBoundingClientRect = () => ({
      top: i * 40, height: 40, bottom: (i + 1) * 40, left: 0, right: 80, width: 80,
    });
  });
  check('pointer in the upper half of the next row inserts before it',
    T.managerDropBeforeId(50, 'B') === 'A');
  check('pointer below every other extra appends', T.managerDropBeforeId(200, 'B') === null);

  const calls = [];
  T.setRpc((method, params) => {
    calls.push({ method, params });
    return Promise.resolve({ order: [] });
  });
  // Extras are Beta then Alpha. Moving Alpha to sit before Beta is a real drop.
  T.setSessions([mgr('B', 'Beta', false), mgr('P', 'Primary', true), mgr('A', 'Alpha', false)]);
  const chain = T.commit('A', 'B');
  await flush();
  await chain;
  check('drop calls reorder-manager with before_id',
    calls.length === 1 && calls[0].method === 'reorder-manager'
      && calls[0].params.session_id === 'A' && calls[0].params.before_id === 'B');
  check('optimistic order is already on the sidebar', rowNames().join(',') === 'Alpha,Beta');
  check('pill stayed the primary through the optimistic paint',
    window.document.querySelector('#sidebar .nav-pill[data-session-id]').dataset.sessionId === 'P');

  if (fail) { console.log('\n' + fail + ' failed'); process.exit(1); }
  console.log('\nall ' + pass + ' passed');
}

main().catch((err) => { console.error(err); process.exit(1); });
