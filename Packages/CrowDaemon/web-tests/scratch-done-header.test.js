const { JSDOM } = require('jsdom');
const vm = require('vm');
const { loadClientSource } = require('./load-client');

// CROW-1288: a Manager opened from Scratch shows "Mark Scratch Done" in the
// session header. The payload is `linked_scratch` on list-sessions; the click
// calls `todo-done` and the button leaves once that lands.
// CROW-1293: that same header also shows a red Delete immediately left of
// Reload (and immediately right of Mark Scratch Done when that button is up).
// The click is the row-menu path: confirm, then `delete-session`.
const epilogue = `
;globalThis.__t = {
  renderHeader(s){ return renderHeader(s); },
  get sessions(){ return sessions; },
  set sessions(v){ sessions = v; },
  set selectedId(v){ selectedId = v; },
  set rpc(v){ rpc = v; },
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

const MANAGER = 'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA';
const SCRATCH = 'BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB';

function buttons() {
  return [...window.document.querySelectorAll('#detail-header .actions-cluster > .action-btn')];
}
function labelOf(b) {
  const spans = [...b.querySelectorAll('span')];
  return (spans.length ? spans[spans.length - 1].textContent : b.textContent || '').trim();
}
function labels() {
  return buttons().map(labelOf);
}
function markBtn() {
  return buttons().find((b) => labelOf(b) === 'Mark Scratch Done') || null;
}
function deleteBtn() {
  return buttons().find((b) => labelOf(b) === 'Delete') || null;
}
function dialog() {
  return window.document.querySelector('.modal-dialog-backdrop');
}
function dialogButtons() {
  return [...window.document.querySelectorAll('.modal-dialog-backdrop .text-prompt-btn')];
}
function headerSession(extra) {
  return Object.assign({
    id: MANAGER,
    name: 'from scratch',
    status: 'active',
    kind: 'manager',
  }, extra || {});
}

console.log('Mark Scratch Done is only on a Manager with an open linked Scratch:');
{
  T.sessions = [];
  T.selectedId = null;
  T.renderHeader(headerSession());
  check('plain manager has no Mark Scratch Done', !markBtn());
  check('plain manager is Delete then Reload', labels().join('|') === 'Delete|Reload');
  check('plain manager Delete is red', !!deleteBtn() && deleteBtn().classList.contains('action-danger'));

  T.renderHeader(headerSession({
    linked_scratch: { id: SCRATCH, text: 'look at the top bar', state: 'done' },
  }));
  check('done scratch hides the button', !markBtn());
  check('done scratch is still Delete then Reload', labels().join('|') === 'Delete|Reload');

  T.renderHeader(headerSession({
    kind: 'work',
    linked_scratch: { id: SCRATCH, text: 'look at the top bar', state: 'exploring' },
  }));
  check('a work session ignores linked_scratch', !markBtn());

  T.renderHeader(headerSession({
    linked_scratch: { id: SCRATCH, text: 'look at the top bar', state: 'exploring' },
  }));
  const btn = markBtn();
  check('exploring manager shows the button', !!btn);
  check('tooltip names the item', !!btn && btn.title.includes('look at the top bar'));
  check('order is Mark Scratch Done, Delete, Reload',
    labels().join('|') === 'Mark Scratch Done|Delete|Reload');
}

console.log('\nwork and review headers keep their own Delete after Reload:');
for (const kind of ['work', 'review']) {
  T.sessions = [];
  T.selectedId = null;
  T.renderHeader(headerSession({ kind, status: 'active', name: kind + ' sess' }));
  check(kind + ' starts with Reload', labels()[0] === 'Reload');
  check(kind + ' ends with Delete', labels()[labels().length - 1] === 'Delete');
  check(kind + ' Delete stays danger', !!deleteBtn() && deleteBtn().classList.contains('action-danger'));
  check(kind + ' has no Mark Scratch Done', !markBtn());
  check(kind + ' Delete is not left of Reload', labels().indexOf('Delete') > labels().indexOf('Reload'));
}

function flush() {
  return new Promise((resolve) => setImmediate(resolve));
}

(async () => {
  console.log('\nclick calls todo-done and drops the button:');
  {
    const session = headerSession({
      linked_scratch: { id: SCRATCH, text: 'look at the top bar', state: 'exploring' },
    });
    T.sessions = [session];
    T.selectedId = MANAGER;
    const calls = [];
    T.rpc = (method, params) => {
      calls.push({ method, params });
      if (method === 'list-sessions') {
        return Promise.resolve({ sessions: [headerSession()] });
      }
      if (method === 'todo-list') return Promise.resolve({ todos: [] });
      if (method === 'list-sessions-live') return Promise.resolve({ sessions: {} });
      return Promise.resolve({ todo: { id: SCRATCH, state: 'done' } });
    };
    T.renderHeader(session);
    const btn = markBtn();
    check('button is there before the click', !!btn);
    btn.click();
    check('click disables while the call is in flight', btn.disabled === true);
    for (let i = 0; i < 8; i++) await flush();
    const done = calls.find((c) => c.method === 'todo-done');
    check('todo-done was sent', !!done && done.params && done.params.todo_id === SCRATCH);
    check('button is gone after success', !markBtn());
    check('scratch board was refreshed', calls.some((c) => c.method === 'todo-list'));
  }

  console.log('\na failed todo-done restores the button:');
  {
    const session = headerSession({
      linked_scratch: { id: SCRATCH, text: 'look at the top bar', state: 'exploring' },
    });
    T.sessions = [session];
    T.selectedId = MANAGER;
    T.rpc = () => Promise.reject(new Error('store locked'));
    T.renderHeader(session);
    const btn = markBtn();
    btn.click();
    for (let i = 0; i < 8; i++) await flush();
    const again = markBtn();
    check('button came back', !!again && again.disabled === false);
    check('failure is explained', (window.document.body.textContent || '').includes('Mark Scratch Done failed'));
    const ok = dialogButtons().find((b) => b.textContent === 'OK');
    if (ok) ok.click();
  }

  console.log('\nDelete confirms, then delete-session:');
  {
    const session = headerSession({ name: 'extra manager' });
    T.sessions = [session];
    T.selectedId = MANAGER;
    const calls = [];
    T.rpc = (method, params) => {
      calls.push({ method, params });
      return Promise.resolve({});
    };
    T.renderHeader(session);
    deleteBtn().click();
    const d = dialog();
    check('confirm names the session', !!d && (d.textContent || '').includes('Delete session "extra manager"?'));
    const ok = dialogButtons().find((b) => b.textContent === 'Delete');
    check('confirm Delete is the danger button', !!ok && ok.classList.contains('danger'));
    ok.click();
    for (let i = 0; i < 8; i++) await flush();
    const sent = calls.find((c) => c.method === 'delete-session');
    check('delete-session was sent', !!sent && sent.params && sent.params.session_id === MANAGER);
    check('session left the list', !T.sessions.some((s) => s.id === MANAGER));
    check('dialog closed', !dialog());
  }

  console.log('\nCancel leaves the session:');
  {
    const session = headerSession({ name: 'extra manager' });
    T.sessions = [session];
    T.selectedId = MANAGER;
    const calls = [];
    T.rpc = (method) => { calls.push(method); return Promise.resolve({}); };
    T.renderHeader(session);
    deleteBtn().click();
    dialogButtons().find((b) => b.textContent === 'Cancel').click();
    for (let i = 0; i < 4; i++) await flush();
    check('no delete-session on cancel', !calls.includes('delete-session'));
    check('session remains after cancel', T.sessions.some((s) => s.id === MANAGER));
    check('confirm closed', !dialog());
  }

  console.log('\nprimary Manager rejection is surfaced:');
  {
    const primary = '00000000-0000-0000-0000-000000000000';
    const session = headerSession({
      id: primary,
      name: 'Manager',
      is_primary_manager: true,
    });
    T.sessions = [session];
    T.selectedId = primary;
    T.rpc = (method) => {
      if (method === 'delete-session') return Promise.reject(new Error('Cannot delete manager session'));
      return Promise.resolve({});
    };
    T.renderHeader(session);
    check('primary still offers Delete', labels().join('|') === 'Delete|Reload');
    deleteBtn().click();
    dialogButtons().find((b) => b.textContent === 'Delete').click();
    for (let i = 0; i < 8; i++) await flush();
    check('failure names the daemon message',
      (window.document.body.textContent || '').includes('Delete failed: Cannot delete manager session'));
    check('primary session remains', T.sessions.some((s) => s.id === primary));
  }

  if (failed) {
    console.log('\n' + failed + ' failed');
    process.exit(1);
  }
  console.log('\nall passed');
})().catch((err) => {
  console.error(err);
  process.exit(1);
});
