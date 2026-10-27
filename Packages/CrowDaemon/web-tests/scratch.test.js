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
  resetScratchPickers(){ scratchPickers = null; scratchPickersLoading = null; scratchCaptureAgent = null; scratchCaptureWorkspace = null; },
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
  const exploreBtn = () => [...board.querySelectorAll('button')].find((b) => b.textContent === 'Explore');
  const prevRpc = T.rpc;
  const calls = [];
  // CROW-1387: items carry an agent + workspace; the pickers load from these.
  item.state = 'captured';
  item.agent_kind = 'cursor';
  item.workspace = 'Corveil';
  const pickerReplies = {
    'list-agents': { agents: [
      { kind: 'claude-code', name: 'Claude Code', available: true, default: true },
      { kind: 'cursor', name: 'Cursor', available: true },
    ] },
    'workspace-list': { workspaces: [{ name: 'Corveil' }, { name: 'Acme' }] },
    'agents-get': { agents: { effective: { manager: 'claude-code' } } },
    'defaults-get': { defaults: { manager_workspace: 'acme' } },
  };
  T.resetScratchPickers();
  T.boardData.scratch = { todos: [item] };

  const requestedAt = new Date().toISOString();
  T.rpc = async (method, params) => {
    calls.push({ method, params });
    if (pickerReplies[method]) return pickerReplies[method];
    if (method === 'todo-ticket' || method === 'todo-explore') {
      return { ok: true, session_id: 'sess', seeded: true, todo: { ...item, ticket_requested_at: requestedAt } };
    }
    if (method === 'todo-list') {
      return { todos: [{ ...item, ticket_requested_at: requestedAt }] };
    }
    return {};
  };
  T.renderBoard();
  await flush();

  // Capture form: Agent + Workspace, required, filled in from the defaults.
  const capSelects = [...board.querySelectorAll('.scratch-capture select')];
  check('capture form has agent + workspace pickers', capSelects.length === 2);
  check('capture pickers are required', capSelects.every((sel) => sel.required));
  check('capture agent defaults to the Manager agent', capSelects[0] && capSelects[0].value === 'claude-code');
  check('capture workspace defaults to defaults.managerWorkspace (canonical)',
    capSelects[1] && capSelects[1].value === 'Acme');
  board.querySelector('.scratch-input').value = 'with pickers';
  calls.length = 0;
  await board.querySelector('.scratch-capture').onsubmit({ preventDefault() {} });
  const addCall = calls.find((c) => c.method === 'todo-add');
  check('capture sends agent_kind + workspace',
    !!(addCall && addCall.params.agent_kind === 'claude-code' && addCall.params.workspace === 'Acme'));
  T.boardData.scratch = { todos: [item] };
  T.renderBoard();

  promptCalls.length = 0;
  window.__alerts = [];
  calls.length = 0;
  ticketBtn().click();
  await flush();
  check('Ticket does not call window.prompt', promptCalls.length === 0);
  const dialog = window.document.querySelector('.scratch-launch-card');
  check('Ticket opens the Agent + Workspace dialog', !!dialog);
  const dlgSelects = dialog ? [...dialog.querySelectorAll('select')] : [];
  check('dialog agent is filled in from the item', dlgSelects[0] && dlgSelects[0].value === 'cursor');
  check('dialog workspace is filled in from the item', dlgSelects[1] && dlgSelects[1].value === 'Corveil');
  check('Ticket does not list repos', !calls.some((c) => c.method === 'list-workspace-repos'));
  check('nothing launches before the dialog is confirmed', !calls.some((c) => c.method === 'todo-ticket'));
  [...dialog.querySelectorAll('button')].find((b) => b.textContent === 'Ticket').click();
  await flush();
  const ticketCall = calls.find((c) => c.method === 'todo-ticket');
  check('todo-ticket receives only the item id when nothing changed',
    !!(ticketCall && ticketCall.params
      && ticketCall.params.todo_id === item.id
      && !('repo' in ticketCall.params)
      && !('workspace' in ticketCall.params)
      && !('agent_kind' in ticketCall.params)));
  check('Ticket refreshes the scratch list', calls.some((c) => c.method === 'todo-list'));
  check('Ticket stays disabled after refresh while filing',
    ticketBtn() && ticketBtn().disabled);
  check('Ticket title says filing after refresh',
    /Filing/.test(ticketBtn()?.title || ''));

  // Explore with a changed workspace sends it as a one-launch override.
  calls.length = 0;
  exploreBtn().click();
  await flush();
  const exDialog = window.document.querySelector('.scratch-launch-card');
  const exSelects = exDialog ? [...exDialog.querySelectorAll('select')] : [];
  if (exSelects[1]) exSelects[1].value = 'Acme';
  if (exDialog) [...exDialog.querySelectorAll('button')].find((b) => b.textContent === 'Explore').click();
  await flush();
  const exploreCall = calls.find((c) => c.method === 'todo-explore');
  check('Explore sends a changed workspace as an override',
    !!(exploreCall && exploreCall.params.workspace === 'Acme' && !('agent_kind' in exploreCall.params)));

  // Cancel launches nothing.
  T.renderBoard();
  calls.length = 0;
  exploreBtn().click();
  await flush();
  const cancelDialog = window.document.querySelector('.scratch-launch-card');
  if (cancelDialog) [...cancelDialog.querySelectorAll('button')].find((b) => b.textContent === 'Cancel').click();
  await flush();
  check('Cancel launches nothing', !calls.some((c) => c.method === 'todo-explore'));
  check('Cancel closes the dialog', !window.document.querySelector('.scratch-launch-card'));

  // CROW-1386: a legacy item (no workspace) starts on the default; with no
  // default, the launch button stays disabled until a workspace is picked.
  const legacy = { ...item, id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', workspace: undefined, agent_kind: undefined };
  T.boardData.scratch = { todos: [legacy] };
  T.renderBoard();
  exploreBtn().click();
  await flush();
  let legacyDialog = window.document.querySelector('.scratch-launch-card');
  let legacySel = legacyDialog && legacyDialog.querySelectorAll('select')[1];
  check('legacy item starts on the default workspace', legacySel && legacySel.value === 'Acme');
  check('no None (cross-workspace) option',
    !!legacySel && ![...legacySel.options].some((o) => /None/.test(o.textContent)));
  [...legacyDialog.querySelectorAll('button')].find((b) => b.textContent === 'Cancel').click();
  await flush();

  pickerReplies['defaults-get'] = { defaults: {} };
  T.resetScratchPickers();
  T.renderBoard();
  await flush();
  exploreBtn().click();
  await flush();
  legacyDialog = window.document.querySelector('.scratch-launch-card');
  legacySel = legacyDialog && legacyDialog.querySelectorAll('select')[1];
  const legacyOk = legacyDialog && [...legacyDialog.querySelectorAll('button')].find((b) => b.textContent === 'Explore');
  check('no default: placeholder chosen and launch disabled',
    legacySel && legacySel.value === '' && legacyOk && legacyOk.disabled);
  legacySel.value = 'Corveil';
  legacySel.dispatchEvent(new window.Event('change'));
  check('picking a workspace enables launch', legacyOk && !legacyOk.disabled);
  [...legacyDialog.querySelectorAll('button')].find((b) => b.textContent === 'Cancel').click();
  await flush();

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
