const { JSDOM } = require('jsdom');
const vm = require('vm');
const { loadClientSource } = require('./load-client');

// CROW-1288: a Manager opened from Scratch shows "Mark Scratch Done" in the
// session header. The payload is `linked_scratch` on list-sessions; the click
// calls `todo-done` and the button leaves once that lands.
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
  return [...window.document.querySelectorAll('#detail-header .actions-cluster .action-btn')];
}
function markBtn() {
  return buttons().find((b) => (b.textContent || '').includes('Mark Scratch Done')) || null;
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
  check('plain manager has no button', !markBtn());
  check('plain manager still has Reload', buttons().some((b) => (b.textContent || '').includes('Reload')));

  T.renderHeader(headerSession({
    linked_scratch: { id: SCRATCH, text: 'look at the top bar', state: 'done' },
  }));
  check('done scratch hides the button', !markBtn());

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
