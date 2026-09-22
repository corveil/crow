const { JSDOM } = require('jsdom');
const vm = require('vm');
const { loadClientSource } = require('./load-client');

// CROW-1231: Scratch board capture + row actions. Same jsdom loader as board.test.js.
const epilogue = `
;globalThis.__t = {
  get boardData(){ return boardData; },
  set selectedBoard(v){ selectedBoard = v; },
  get rpc(){ return rpc; },
  set rpc(v){ rpc = v; },
  renderBoard(){ return renderBoard(); },
  sidebarLeftStack(){ return sidebarLeftStack(); },
  scratchOpenCount(){ return scratchOpenCount(); },
};
`;
const appjs = loadClientSource() + epilogue;

const dom = new JSDOM(
  `<!doctype html><html><body>
     <div id="sidebar"></div><div id="board"></div>
     <div id="detail-header"></div><div id="tabbar"></div>
     <div id="app"></div>
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
const promptCalls = [];
window.prompt = (msg) => { promptCalls.push(String(msg)); return 'Corveil'; };
window.__alerts = [];
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run'); process.exit(2); }

let failed = 0;
function check(name, ok) {
  if (ok) console.log('  ok  ' + name);
  else { console.log('  FAIL  ' + name); failed++; }
}

const item = {
  id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  text: 'native scratch list',
  note: 'before a ticket',
  tags: ['crow'],
  priority: 'p2',
  state: 'captured',
  links: [],
};

T.boardData.scratch = { todos: [item] };
T.selectedBoard = 'scratch';
T.renderBoard();
const board = window.document.getElementById('board');
check('board title', board.textContent.includes('Scratch'));
check('capture form', !!board.querySelector('.scratch-capture'));
check('item text', board.textContent.includes('native scratch list'));
check('state chip', board.textContent.includes('captured'));
check('Explore action', board.textContent.includes('Explore'));
check('Ticket action', board.textContent.includes('Ticket'));
check('Work action', board.textContent.includes('Work'));
check('Done action', board.textContent.includes('Done'));
const row = board.querySelector('.scratch-row');
check('item is a board-card', row && row.classList.contains('board-card'));
check('items sit in a spaced list', !!board.querySelector('.scratch-list'));
const footerActions = row && row.querySelector('.card-foot .card-actions');
check('actions sit in that card\'s footer', !!(footerActions &&
  [...footerActions.querySelectorAll('button')].some((b) => b.textContent === 'Explore') &&
  [...footerActions.querySelectorAll('button')].some((b) => b.textContent === 'Done')));
T.boardData.scratch = { todos: [item, { ...item, id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', text: 'second scratch item' }] };
T.renderBoard();
const distinct = [...board.querySelectorAll('.scratch-row')];
check('two items are two distinct cards', distinct.length === 2 &&
  distinct.every((c) => c.classList.contains('board-card') && c.querySelector('.card-foot .card-actions')));
T.boardData.scratch = { todos: [item] };
T.renderBoard();
const capturedTicket = [...board.querySelectorAll('button')].find((b) => b.textContent === 'Ticket');
const capturedWork = [...board.querySelectorAll('button')].find((b) => b.textContent === 'Work');
check('Ticket enabled before a ticket exists', capturedTicket && !capturedTicket.disabled);
check('Work disabled before a ticket exists', capturedWork && capturedWork.disabled);

const ticketed = {
  ...item,
  state: 'ticketed',
  links: [{ type: 'ticket', url: 'https://github.com/corveil/crow/issues/1', label: '#1' }],
};
T.boardData.scratch = { todos: [ticketed] };
T.renderBoard();
const ticketedTicket = [...board.querySelectorAll('button')].find((b) => b.textContent === 'Ticket');
const ticketedWork = [...board.querySelectorAll('button')].find((b) => b.textContent === 'Work');
check('Ticket disabled once a ticket exists', ticketedTicket && ticketedTicket.disabled);
check('Work enabled once a ticket exists', ticketedWork && !ticketedWork.disabled);

const filingItem = {
  ...item,
  id: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
  ticket_requested_at: new Date().toISOString(),
};
T.boardData.scratch = { todos: [filingItem] };
T.renderBoard();
const filingTicket = [...board.querySelectorAll('button')].find((b) => b.textContent === 'Ticket');
check('Ticket disabled while ticket_requested_at is fresh', filingTicket && filingTicket.disabled);
check('fresh dispatch title says filing', /Filing/.test(filingTicket && filingTicket.title || ''));

const staleItem = {
  ...filingItem,
  ticket_requested_at: new Date(Date.now() - 16 * 60 * 1000).toISOString(),
};
T.boardData.scratch = { todos: [staleItem] };
T.renderBoard();
const staleTicket = [...board.querySelectorAll('button')].find((b) => b.textContent === 'Ticket');
check('Ticket enabled again after the dispatch window', staleTicket && !staleTicket.disabled);

T.boardData.scratch = { todos: [item] };
T.renderBoard();

const stack = T.sidebarLeftStack();
const pills = [...stack.querySelectorAll('.nav-pill .pill-label')].map((n) => n.textContent);
check('Scratch is a nav pill', pills.indexOf('Scratch') !== -1);
check('Scratch sits after Scorecard', pills.indexOf('Scorecard') < pills.indexOf('Scratch'));
const rows = [...stack.querySelectorAll('.nav-pills-row')].map((row) =>
  [...row.querySelectorAll('.nav-pill .pill-label')].map((n) => n.textContent));
check('row 1 is Grid · Scorecard', rows[0] && rows[0][0] === 'Grid' && rows[0][1] === 'Scorecard' && rows[0].length === 2);
check('row 2 is Reviews · Scratch', rows[1] && rows[1][0] === 'Reviews' && rows[1][1] === 'Scratch' && rows[1].length === 2);
check('Scratch is not a Tickets-style card', !stack.querySelector('.scratch-card'));
check('open count', T.scratchOpenCount() === 1);
const scratchPill = [...stack.querySelectorAll('.nav-pill')].find((p) => p.querySelector('.pill-label')?.textContent === 'Scratch');
check('open-count badge on the pill', scratchPill && scratchPill.textContent.includes('1'));

item.state = 'done';
T.boardData.scratch = { todos: [item] };
check('done items are not open', T.scratchOpenCount() === 0);

T.renderBoard();
check('hides done by default', !board.textContent.includes('native scratch list') || board.textContent.includes('Nothing open'));
check('empty state does not say idea', !board.textContent.toLowerCase().includes('idea'));
T.boardData.scratch = { todos: [] };
T.renderBoard();
check('blank-board copy does not say idea', !board.textContent.toLowerCase().includes('idea'));
check('capture placeholder', board.querySelector('.scratch-input')?.placeholder === 'Capture to Scratch…');

async function flush() {
  for (let i = 0; i < 12; i++) await Promise.resolve();
}

(async () => {
  vm.runInContext(`
    alertModal = async function (msg) {
      (globalThis.__alerts || (globalThis.__alerts = [])).push(String(msg));
    };
  `, ctx);

  const ticketBtn = () => [...board.querySelectorAll('button')].find((b) => b.textContent === 'Ticket');
  const prevRpc = T.rpc;
  const calls = [];
  item.state = 'captured';
  T.boardData.scratch = { todos: [item] };
  T.renderBoard();

  const requestedAt = new Date().toISOString();
  T.rpc = async (method, params) => {
    calls.push({ method, params });
    if (method === 'todo-ticket') {
      return { ok: true, session_id: 'sess', seeded: true, todo: { ...item, ticket_requested_at: requestedAt } };
    }
    if (method === 'todo-list') {
      return { todos: [{ ...item, ticket_requested_at: requestedAt }] };
    }
    return {};
  };
  promptCalls.length = 0;
  window.__alerts = [];
  ticketBtn().click();
  await flush();
  check('Ticket does not call window.prompt', promptCalls.length === 0);
  check('Ticket does not open a repo dropdown',
    !window.document.querySelector('.text-prompt-backdrop select'));
  check('Ticket does not list repos',
    !calls.some((c) => c.method === 'list-workspace-repos')
    && !calls.some((c) => c.method === 'workspace-list'));
  const ticketCall = calls.find((c) => c.method === 'todo-ticket');
  check('todo-ticket receives only the item id',
    !!(ticketCall && ticketCall.params
      && ticketCall.params.todo_id === item.id
      && !('repo' in ticketCall.params)
      && !('workspace' in ticketCall.params)));
  check('Ticket refreshes the scratch list', calls.some((c) => c.method === 'todo-list'));
  check('Ticket stays disabled after refresh while filing',
    ticketBtn() && ticketBtn().disabled);
  check('Ticket title says filing after refresh',
    /Filing/.test(ticketBtn()?.title || ''));

  const editable = {
    id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    text: 'native scratch list',
    note: 'before a ticket',
    tags: ['crow'],
    priority: 'p2',
    state: 'captured',
    links: [],
  };
  T.boardData.scratch = { todos: [editable] };
  T.renderBoard();
  const title = board.querySelector('.scratch-row .card-title');
  check('title teaches double-click', !!(title && /Double-click/.test(title.title)));

  title.ondblclick({ preventDefault() {}, stopPropagation() {} });
  const editor = title.querySelector('input.scratch-title-input');
  check('dblclick opens an input with the current text',
    !!(editor && editor.value === 'native scratch list'));

  editor.value = 'should not save';
  await editor.onkeydown({ key: 'Escape', preventDefault() {}, stopPropagation() {} });
  check('Escape restores the title and drops the input',
    title.textContent === 'native scratch list' && !title.querySelector('input'));

  let titleCalls = [];
  T.rpc = async (method, params) => {
    titleCalls.push({ method, params });
    return {};
  };

  title.ondblclick({ preventDefault() {}, stopPropagation() {} });
  const blankEditor = title.querySelector('input');
  blankEditor.value = '   ';
  await blankEditor.onblur();
  check('blank blur cancels without RPC',
    titleCalls.length === 0 && title.textContent === 'native scratch list');

  title.ondblclick({ preventDefault() {}, stopPropagation() {} });
  const sameEditor = title.querySelector('input');
  sameEditor.value = 'native scratch list';
  await sameEditor.onblur();
  check('unchanged blur skips RPC',
    titleCalls.length === 0 && title.textContent === 'native scratch list');

  title.ondblclick({ preventDefault() {}, stopPropagation() {} });
  const saveEditor = title.querySelector('input');
  saveEditor.value = '  renamed scratch  ';
  T.rpc = async (method, params) => {
    titleCalls.push({ method, params });
    if (method === 'todo-list') {
      return { todos: [{ ...editable, text: 'renamed scratch' }] };
    }
    return { todo: { ...editable, text: 'renamed scratch' } };
  };
  titleCalls = [];
  await saveEditor.onkeydown({ key: 'Enter', preventDefault() {}, stopPropagation() {} });
  check('Enter calls todo-edit with trimmed text',
    !!(titleCalls[0] && titleCalls[0].method === 'todo-edit'
      && titleCalls[0].params && titleCalls[0].params.todo_id === editable.id
      && titleCalls[0].params.text === 'renamed scratch'));
  check('Enter refreshes the scratch list', titleCalls.some((c) => c.method === 'todo-list'));
  check('board shows the new title',
    board.querySelector('.scratch-row .card-title')?.textContent === 'renamed scratch');

  const raceItem = {
    id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
    text: 'native scratch list',
    note: 'before a ticket',
    tags: ['crow'],
    priority: 'p2',
    state: 'captured',
    links: [],
  };
  T.boardData.scratch = { todos: [raceItem] };
  T.renderBoard();
  const raceTitle = board.querySelector('.scratch-row .card-title');
  raceTitle.ondblclick({ preventDefault() {}, stopPropagation() {} });
  const raceEditor = raceTitle.querySelector('input');
  raceEditor.value = 'during refresh';
  let listResolve;
  T.rpc = async (method) => {
    if (method === 'todo-edit') return { todo: { ...raceItem, text: 'during refresh' } };
    if (method === 'todo-list') return new Promise((resolve) => { listResolve = resolve; });
    return {};
  };
  const saveP = raceEditor.onkeydown({ key: 'Enter', preventDefault() {}, stopPropagation() {} });
  for (let i = 0; i < 20 && raceTitle.textContent !== 'during refresh'; i++) {
    await Promise.resolve();
  }
  check('optimistic title after todo-edit', raceTitle.textContent === 'during refresh');
  raceTitle.ondblclick({ preventDefault() {}, stopPropagation() {} });
  const reedit = raceTitle.querySelector('input.scratch-title-input');
  check('re-edit during refresh seeds the saved text',
    !!(reedit && reedit.value === 'during refresh'));
  await reedit.onkeydown({ key: 'Escape', preventDefault() {}, stopPropagation() {} });
  check('Escape during refresh keeps the saved title',
    raceTitle.textContent === 'during refresh');
  listResolve({ todos: [{ ...raceItem, text: 'during refresh' }] });
  await saveP;
  T.rpc = prevRpc;

  if (failed) { console.log('\n' + failed + ' failed'); process.exit(1); }
  console.log('\nscratch board ok');
})().catch((err) => {
  console.log('FATAL: ' + (err && err.stack || err));
  process.exit(2);
});
