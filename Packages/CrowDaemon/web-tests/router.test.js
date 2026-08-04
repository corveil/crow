const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// CROW-936 behaviour test: hash-based URL routing. Runs the REAL app.js under
// jsdom and drives the router against mocks — same loader shape as
// sidebar-select.test.js / board.test.js.
//
// The point of this suite is the two things that are easy to get wrong and
// impossible to see in a string guard:
//   1. a cold deep link must not decide "not found" before list-sessions lands
//      (`sessions` can be pre-filled from the localStorage sidebar cache, so
//      only `sessionsLoaded` can tell "deleted" from "not loaded yet"); and
//   2. applying a route must not push a *second* history entry, or Back would
//      need two presses per view.
const epilogue = `
;globalThis.__t = {
  parseRoute: (h) => parseRoute(h),
  routeToHash: (r) => routeToHash(r),
  currentRoute: () => currentRoute(),
  navigate: (r, o) => navigate(r, o),
  applyRoute: (r) => applyRoute(r),
  onHashChange: () => onHashChange(),
  showHome: () => showHome(),
  showSessionNotFound: (id) => showSessionNotFound(id),
  switchTerminal: (t) => switchTerminal(t),
  refreshTerminals: () => refreshTerminals(),
  refreshSessions: () => refreshSessions(),
  selectBoard: (k) => selectBoard(k),
  ROUTE_BOARDS: () => ROUTE_BOARDS,
  ROUTE_SETTINGS_TABS: () => ROUTE_SETTINGS_TABS,
  get selectedId() { return selectedId; }, set selectedId(v) { selectedId = v; },
  get selectedBoard() { return selectedBoard; }, set selectedBoard(v) { selectedBoard = v; },
  get sessions() { return sessions; }, set sessions(v) { sessions = v; },
  get sessionsLoaded() { return sessionsLoaded; }, set sessionsLoaded(v) { sessionsLoaded = v; },
  get pendingRoute() { return pendingRoute; }, set pendingRoute(v) { pendingRoute = v; },
  get pendingTerminalId() { return pendingTerminalId; }, set pendingTerminalId(v) { pendingTerminalId = v; },
  get terminals() { return terminals; }, set terminals(v) { terminals = v; },
  get activeTerminal() { return activeTerminal; }, set activeTerminal(v) { activeTerminal = v; },
  // Silence everything that would paint, hit the network, or talk to xterm.
  stub() {
    renderSidebar = function () {};
    renderTabs = function () {};
    renderHeader = function () {};
    renderBoard = function () {};
    renderStatusBar = function () {};
    ensureTerminal = function () {};
    fitTerminal = function () {};
    attachWindow = function () {};
    detectSessionSounds = function () {};
    persistSidebarCache = function () {};
    refreshLive = async function () {};
    refreshArtifacts = async function () {};
    refreshBoard = async function () {};
  },
  spySelectSession(sink) {
    selectSession = async function (id) { sink.push(id); selectedId = id; };
  },
  setRpc(fn) { rpc = fn; },
};
`;

const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

// Mirrors the containers app.js touches in index.html — #detail-empty matters
// here because the not-found state writes into .empty-msg / .empty-sub.
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
      <div id="detail-empty">
        <img class="empty-brand"><div class="empty-msg">Select a session</div>
      </div>
    </main>
  </div>
  <div id="statusbar"></div>
</body></html>`;

function load(url, seed) {
  const dom = new JSDOM(MARKUP, {
    runScripts: 'outside-only', pretendToBeVisual: true, url: url || 'http://localhost/',
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
  // Stand in for settings.js, which the real page loads *after* app.js.
  if (seed) seed(window);

  const ctx = dom.getInternalVMContext();
  try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
  catch (e) { console.log('[load warn]', e.message); }
  const T = ctx.__t;
  if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }
  T.stub();
  T.window = window;
  T.ctx = ctx;
  return T;
}

// Load app.js *and* the real settings.js into one context, the way index.html
// does. Needed for the Settings-routing assertions: window.openSettings and
// window.setSettingsTab are settings.js's, and stubbing them would assert
// nothing about the behaviour that actually regressed.
function loadWithSettings(url) {
  const T = load(url);
  const settingsSrc = fs.readFileSync(
    __dirname + '/../Sources/CrowDaemon/Resources/web/settings.js', 'utf8');
  try { vm.runInContext(settingsSrc, T.ctx, { filename: 'settings.js' }); }
  catch (e) { console.log('[settings load warn]', e.message); }
  // Offline stand-ins for the four network reads openSettings makes.
  T.getConfigCalls = () => T.ctx.__rpcCalls.filter((m) => m === 'get-config').length;
  vm.runInContext(`
    globalThis.__rpcCalls = [];
    rpc = async function (m) {
      globalThis.__rpcCalls.push(m);
      if (m === 'get-config') return { config: '{}', dev_root: '/tmp' };
      if (m === 'list-agents') return { agents: [] };
      return {};
    };
    fetch = async function () { return { ok: false }; };
  `, T.ctx);
  return T;
}

let pass = 0, fail = 0;
const check = (name, cond) => {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name); }
};
const eq = (name, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want);
  if (!ok) console.log('    got ' + JSON.stringify(got) + ' want ' + JSON.stringify(want));
  check(name, ok);
};
const tick = () => new Promise((r) => setImmediate(r));

const SESSION = { id: 'sess-1', name: 'crow-936', status: 'active', kind: 'work' };

(async () => {
  // -------------------------------------------------------------------------
  console.log('parseRoute — the shapes we publish:');
  {
    const T = load();
    eq('empty hash is home', T.parseRoute(''), { view: 'home' });
    eq('"#/" is home', T.parseRoute('#/'), { view: 'home' });
    eq('session', T.parseRoute('#/sessions/abc'), { view: 'session', sessionId: 'abc' });
    eq('session + terminal', T.parseRoute('#/sessions/abc/t/xyz'),
      { view: 'session', sessionId: 'abc', terminalId: 'xyz' });
    eq('tickets', T.parseRoute('#/tickets'), { view: 'board', board: 'tickets' });
    eq('reviews', T.parseRoute('#/reviews'), { view: 'board', board: 'reviews' });
    // The ticket named only tickets/reviews; the client has four boards.
    eq('allowlist', T.parseRoute('#/allowlist'), { view: 'board', board: 'allowlist' });
    eq('scorecard', T.parseRoute('#/scorecard'), { view: 'board', board: 'scorecard' });
    eq('settings tab', T.parseRoute('#/settings/jobs'), { view: 'settings', tab: 'jobs' });
    eq('bare settings falls back to general', T.parseRoute('#/settings'),
      { view: 'settings', tab: 'general' });
    eq('unknown settings tab degrades, does not 404', T.parseRoute('#/settings/nope'),
      { view: 'settings', tab: 'general' });
    eq('trailing slash tolerated', T.parseRoute('#/sessions/abc/'),
      { view: 'session', sessionId: 'abc' });
    eq('percent-encoded id is decoded', T.parseRoute('#/sessions/a%2Fb'),
      { view: 'session', sessionId: 'a/b' });

    check('unknown top-level is null', T.parseRoute('#/nope') === null);
    check('sessions with no id is null', T.parseRoute('#/sessions') === null);
    check('malformed terminal segment is null', T.parseRoute('#/sessions/a/x/y') === null);
    check('board with extra segment is null', T.parseRoute('#/tickets/extra') === null);
    check('malformed %-escape is null, not a throw', T.parseRoute('#/sessions/%E0%A4%A') === null);
  }

  // -------------------------------------------------------------------------
  console.log('\nrouteToHash round-trips:');
  {
    const T = load();
    const round = (h) => T.routeToHash(T.parseRoute(h));
    eq('home', round('#/'), '#/');
    eq('session', round('#/sessions/abc'), '#/sessions/abc');
    eq('session + terminal', round('#/sessions/abc/t/xyz'), '#/sessions/abc/t/xyz');
    eq('board', round('#/reviews'), '#/reviews');
    eq('settings', round('#/settings/jobs'), '#/settings/jobs');
    eq('id needing escapes survives', round('#/sessions/a%2Fb'), '#/sessions/a%2Fb');
    eq('null route is home', T.routeToHash(null), '#/');
  }

  // -------------------------------------------------------------------------
  console.log('\nnavigate — history entries:');
  {
    const T = load();
    const before = T.window.history.length;
    T.navigate({ view: 'board', board: 'tickets' });
    eq('hash written', T.window.location.hash, '#/tickets');
    check('pushed an entry (Back has somewhere to go)', T.window.history.length > before);

    const after = T.window.history.length;
    T.navigate({ view: 'board', board: 'tickets' });
    check('re-navigating to the same route pushes nothing', T.window.history.length === after);

    T.navigate({ view: 'board', board: 'reviews' }, { replace: true });
    eq('replace still updates the hash', T.window.location.hash, '#/reviews');
    check('replace pushed no entry', T.window.history.length === after);
  }

  // -------------------------------------------------------------------------
  console.log('\nSelecting a board is addressable:');
  {
    const T = load();
    T.selectBoard('scorecard');
    eq('selectedBoard set', T.selectedBoard, 'scorecard');
    eq('URL follows the click', T.window.location.hash, '#/scorecard');
  }

  // -------------------------------------------------------------------------
  console.log('\nCold deep link waits for list-sessions before judging the id:');
  {
    const T = load('http://localhost/#/sessions/sess-1');
    // Boot defers the route to DOMContentLoaded (settings.js has to be loaded
    // before a #/settings/* link can be applied), so let that fire.
    await tick();
    // Boot stashes the route rather than deciding on a possibly-cached list.
    eq('boot deferred the session route', T.pendingRoute,
      { view: 'session', sessionId: 'sess-1' });
    check('nothing selected yet', T.selectedId === null);

    const picked = [];
    T.spySelectSession(picked);
    T.setRpc(async () => ({ sessions: [SESSION] }));
    await T.refreshSessions();
    await tick();
    eq('the deferred route resolved to the session', picked, ['sess-1']);
  }

  // -------------------------------------------------------------------------
  console.log('\nA deep link to a reaped session lands on not-found, not a blank pane:');
  {
    const T = load('http://localhost/#/sessions/ghost');
    await tick(); // let boot stash the route (see above)
    check('route was stashed, not judged early', !!T.pendingRoute);
    T.setRpc(async () => ({ sessions: [SESSION] })); // 'ghost' is not in it
    await T.refreshSessions();
    await tick();
    const app = T.window.document.getElementById('app');
    check('no selection', T.selectedId === null);
    check('has-selection removed, so #detail-empty shows',
      !app.classList.contains('has-selection'));
    check('route-missing set for the mobile override',
      app.classList.contains('route-missing'));
    const msg = T.window.document.querySelector('#detail-empty .empty-msg');
    eq('says what happened', msg && msg.textContent, 'Session not found');
    const sub = T.window.document.querySelector('#detail-empty .empty-sub');
    check('explains why it is normal', !!sub && /deleted/i.test(sub.textContent));
    const back = T.window.document.querySelector('#detail-empty .empty-back');
    check('offers a way out', !!back);
    // #detail-empty is pointer-events:none; the button must opt back in or the
    // only escape from the not-found state is unclickable.
    check('the way out is clickable', !!back && typeof back.onclick === 'function');
  }

  // -------------------------------------------------------------------------
  console.log('\nA session reaped while open degrades live:');
  {
    const T = load();
    T.sessions = [SESSION];
    T.sessionsLoaded = true;
    T.selectedId = 'sess-1';
    T.setRpc(async () => ({ sessions: [] })); // reaper took it
    await T.refreshSessions();
    const msg = T.window.document.querySelector('#detail-empty .empty-msg');
    check('selection dropped', T.selectedId === null);
    eq('not-found rather than an empty header', msg && msg.textContent, 'Session not found');
  }

  // -------------------------------------------------------------------------
  console.log('\nshowHome restores the default empty state:');
  {
    const T = load();
    T.showSessionNotFound('gone');
    T.showHome();
    const app = T.window.document.getElementById('app');
    const msg = T.window.document.querySelector('#detail-empty .empty-msg');
    eq('default copy back', msg && msg.textContent, 'Select a session');
    check('route-missing cleared', !app.classList.contains('route-missing'));
    check('the not-found sub-text is gone',
      !T.window.document.querySelector('#detail-empty .empty-sub'));
    check('the not-found button is gone',
      !T.window.document.querySelector('#detail-empty .empty-back'));
  }

  // -------------------------------------------------------------------------
  console.log('\nTerminal tabs are addressable:');
  {
    const T = load();
    T.selectedId = 'sess-1';
    T.switchTerminal({ id: 'term-2', name: 'shell', window: 2 });
    eq('switching writes the terminal segment', T.window.location.hash,
      '#/sessions/sess-1/t/term-2');
  }

  // -------------------------------------------------------------------------
  console.log('\nrefreshTerminals restores the routed terminal:');
  {
    const T = load();
    T.selectedId = 'sess-1';
    T.setRpc(async () => ({ terminals: [
      { id: 'term-1', name: 'a', window: 1 }, { id: 'term-2', name: 'b', window: 2 },
    ] }));
    T.pendingTerminalId = 'term-2';
    await T.refreshTerminals();
    eq('routed tab wins over terminals[0]', T.activeTerminal && T.activeTerminal.id, 'term-2');
    check('consumed once', T.pendingTerminalId === null);

    // A later background refresh must not re-apply it and yank the user's tab.
    T.activeTerminal = { id: 'term-1', name: 'a', window: 1 };
    await T.refreshTerminals();
    eq('background refresh keeps the current tab',
      T.activeTerminal && T.activeTerminal.id, 'term-1');
  }

  // -------------------------------------------------------------------------
  console.log('\nA stale terminal id falls back and corrects the URL:');
  {
    const T = load('http://localhost/#/sessions/sess-1/t/dead');
    T.selectedId = 'sess-1';
    T.setRpc(async () => ({ terminals: [{ id: 'term-1', name: 'a', window: 1 }] }));
    T.pendingTerminalId = 'dead';
    await T.refreshTerminals();
    eq('fell back to the first tab', T.activeTerminal && T.activeTerminal.id, 'term-1');
    eq('dead /t/… dropped from the URL', T.window.location.hash, '#/sessions/sess-1');
  }

  // -------------------------------------------------------------------------
  console.log('\nBack/Forward apply without pushing duplicates:');
  {
    const T = load();
    // A click: the app writes the hash itself, so the hashchange it provokes
    // must not re-run the selection it already performed.
    T.selectBoard('tickets');
    T.selectedBoard = null; // prove the suppressed pass does not restore it
    T.onHashChange();
    check('our own write is suppressed', T.selectedBoard === null);

    // A real Back: the hash moved underneath us, so the route applies.
    T.window.location.hash = '#/reviews';
    T.onHashChange();
    eq('external hash change is applied', T.selectedBoard, 'reviews');
    check('applying did not push a duplicate entry',
      T.window.location.hash === '#/reviews');
  }

  // -------------------------------------------------------------------------
  console.log('\nApplying a route drives the real selection path:');
  {
    const T = load();
    const picked = [];
    T.spySelectSession(picked);
    T.sessions = [SESSION];
    T.sessionsLoaded = true;
    await T.applyRoute({ view: 'session', sessionId: 'sess-1', terminalId: 'term-9' });
    eq('routed through selectSession, not a parallel path', picked, ['sess-1']);
    eq('terminal handed to refreshTerminals', T.pendingTerminalId, 'term-9');
  }

  // -------------------------------------------------------------------------
  console.log('\nA cold session+terminal link keeps its terminal segment:');
  {
    // Regression: selectSession writes the hash before refreshTerminals has
    // consumed the routed terminal, so navigating without the pending id
    // rewrote #/sessions/x/t/y down to #/sessions/x — leaving the URL
    // disagreeing with the tab that then got restored.
    const T = load('http://localhost/#/sessions/sess-1/t/term-2');
    T.sessions = [SESSION];
    T.sessionsLoaded = true;
    T.setRpc(async () => ({ terminals: [
      { id: 'term-1', name: 'a', window: 1 }, { id: 'term-2', name: 'b', window: 2 },
    ] }));
    await T.applyRoute({ view: 'session', sessionId: 'sess-1', terminalId: 'term-2' });
    await tick();
    eq('URL still names the routed terminal', T.window.location.hash,
      '#/sessions/sess-1/t/term-2');
    eq('and that tab is the active one', T.activeTerminal && T.activeTerminal.id, 'term-2');
  }

  // -------------------------------------------------------------------------
  console.log('\nA cold #/settings/<tab> link opens that tab:');
  {
    const opened = [];
    const T = load('http://localhost/#/settings/jobs', (w) => {
      w.openSettings = async (tab) => { opened.push(tab === undefined ? '(none)' : tab); };
    });
    await tick();
    // Regression: app.js boots before settings.js defines window.openSettings,
    // so applying this route eagerly during app.js evaluation was a silent no-op.
    eq('openSettings called with the routed tab', opened, ['jobs']);
    check('no session route was stashed', T.pendingRoute === null);
  }

  // -------------------------------------------------------------------------
  console.log('\nA cold board link paints without waiting for sessions:');
  {
    const T = load('http://localhost/#/reviews');
    await tick();
    eq('board selected straight away', T.selectedBoard, 'reviews');
  }

  // -------------------------------------------------------------------------
  console.log('\nAn unroutable hash is normalized:');
  {
    const T = load();
    T.window.location.hash = '#/nonsense';
    await T.applyRoute(T.currentRoute());
    eq('rewritten to home', T.window.location.hash, '#/');
  }

  // -------------------------------------------------------------------------
  console.log('\nDrift gates — the router duplicates two lists:');
  {
    const T = load();
    // app.js can't import settings.js's TABS (two classic scripts, no modules),
    // so the tab list is duplicated. If they drift, a real tab silently routes
    // to 'general' instead — cheap to guard, invisible to catch by hand.
    const settingsSrc = fs.readFileSync(
      __dirname + '/../Sources/CrowDaemon/Resources/web/settings.js', 'utf8');
    const block = settingsSrc.match(/const TABS = \[([\s\S]*?)\];/);
    const tabs = block ? [...block[1].matchAll(/\['([a-z]+)',/g)].map((m) => m[1]) : [];
    check('found TABS in settings.js', tabs.length > 0);
    eq('ROUTE_SETTINGS_TABS matches settings.js TABS', T.ROUTE_SETTINGS_TABS(), tabs);

    // Same for boards: selectedBoard's declared union is the source of truth.
    const appSrc = fs.readFileSync(
      __dirname + '/../Sources/CrowDaemon/Resources/web/app.js', 'utf8');
    const decl = appSrc.match(/let selectedBoard = null; \/\/ ([^\n]+)/);
    const boards = decl
      ? decl[1].split('|').map((s) => s.trim().replace(/'/g, '')).filter((s) => s !== 'null')
      : [];
    check('found the selectedBoard union', boards.length > 0);
    eq('ROUTE_BOARDS matches it', T.ROUTE_BOARDS(), boards);
  }

  // -------------------------------------------------------------------------
  console.log('\nSettings routing against the real settings.js:');
  {
    const T = loadWithSettings();
    await T.window.openSettings('workspaces');
    const active = () => {
      const t = T.window.document.querySelector('.settings-tab.active');
      return t && t.textContent;
    };
    eq('opened on the routed tab', active(), 'Workspaces');
    eq('URL follows', T.window.location.hash, '#/settings/workspaces');
    eq('one config read so far', T.getConfigCalls(), 1);

    // The Yellow this replaces: routing to another tab used to go through
    // openSettings, which re-runs get-config, replaces `cfg` and resets
    // `dirty` — so arriving at a tab via Back silently discarded edits that
    // clicking the same tab preserved.
    await T.applyRoute({ view: 'settings', tab: 'automation' });
    eq('moved tab in place', active(), 'Automation');
    eq('no second config read — the working copy survived', T.getConfigCalls(), 1);
    check('modal still open', T.window.settingsIsOpen() === true);

    // Tab clicks stay addressable but must not pile up history entries.
    const before = T.window.history.length;
    const tabs = [...T.window.document.querySelectorAll('.settings-tab')];
    const jobs = tabs.find((t) => t.textContent === 'Jobs');
    jobs.onclick();
    eq('click switched tab', active(), 'Jobs');
    eq('and is addressable', T.window.location.hash, '#/settings/jobs');
    check('but pushed no history entry', T.window.history.length === before);

    // Routing away closes the modal.
    T.sessions = [SESSION];
    T.sessionsLoaded = true;
    await T.applyRoute({ view: 'board', board: 'tickets' });
    check('leaving #/settings/* closed the modal', T.window.settingsIsOpen() === false);
    eq('and applied the destination', T.selectedBoard, 'tickets');
  }

  // -------------------------------------------------------------------------
  console.log('\nBoot defers a session route through applyRoute, not around it:');
  {
    // applyRoute owns the !sessionsLoaded decision; boot must not re-make it
    // with staler information, or a list-sessions that resolves before
    // DOMContentLoaded leaves the route stranded until the 10s poll.
    const T = load('http://localhost/#/sessions/sess-1');
    await tick();
    eq('deferred while sessions were unknown', T.pendingRoute,
      { view: 'session', sessionId: 'sess-1' });

    // The property applyBootRoute now leans on instead of re-deciding: given
    // sessions are already in, applyRoute resolves rather than stranding the
    // route in pendingRoute. Loaded at "/" so boot doesn't drive it too.
    const T2 = load('http://localhost/');
    await tick();
    const picked = [];
    T2.spySelectSession(picked);
    T2.sessions = [SESSION];
    T2.sessionsLoaded = true; // the race the review flagged: already loaded
    await T2.applyRoute({ view: 'session', sessionId: 'sess-1' });
    eq('applies immediately when sessions are already in', picked, ['sess-1']);
    check('and nothing was left pending', T2.pendingRoute === null);
  }

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})();
