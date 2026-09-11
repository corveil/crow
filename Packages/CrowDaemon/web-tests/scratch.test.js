const { JSDOM } = require('jsdom');
const vm = require('vm');
const { loadClientSource } = require('./load-client');

// CROW-1231: Scratch board capture + row actions. Same jsdom loader as board.test.js.
const epilogue = `
;globalThis.__t = {
  get boardData(){ return boardData; },
  set selectedBoard(v){ selectedBoard = v; },
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
window.prompt = () => 'Corveil';
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

T.boardData.scratch = { todos: [item] };
T.renderBoard();

const stack = T.sidebarLeftStack();
const pills = [...stack.querySelectorAll('.nav-pill .pill-label')].map((n) => n.textContent);
check('Scratch is a nav pill', pills.indexOf('Scratch') !== -1);
check('Scratch sits after Scorecard', pills.indexOf('Scorecard') < pills.indexOf('Scratch'));
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

if (failed) { console.log('\n' + failed + ' failed'); process.exit(1); }
console.log('\nscratch board ok');
