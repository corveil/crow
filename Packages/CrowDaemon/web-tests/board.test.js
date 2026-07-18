const fs = require('fs');
const vm = require('vm');
const { JSDOM } = require('jsdom');

// Expose the module's const/let state (not vm global props) via an epilogue
// evaluated in app.js's own top-level lexical scope.
const epilogue = `
;globalThis.__t = {
  get boardData(){return boardData;},
  set selectedBoard(v){selectedBoard=v;},
  set ticketSort(v){ticketSort=v;},
  set ticketRepoFilter(v){ticketRepoFilter=v;},
  set ticketFilter(v){ticketFilter=v;},
  set ticketSearch(v){ticketSearch=v;},
  renderBoard(){ return renderBoard(); },
};
`;
const APP_JS = __dirname + '/../Sources/CrowDaemon/Resources/web/app.js';
const appjs = fs.readFileSync(APP_JS, 'utf8') + epilogue;

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
window.setTimeout = () => 0;
window.requestAnimationFrame = () => 0;
// app.js wires load-time handlers on chrome elements our harness omits; return a
// throwaway node for unknown ids so load completes (the real #board is kept).
const realGet = window.document.getElementById.bind(window.document);
window.document.getElementById = (id) => realGet(id) || window.document.createElement('div');

const ctx = dom.getInternalVMContext();
try { vm.runInContext(appjs, ctx, { filename: 'app.js' }); }
catch (e) { console.log('[load warn]', e.message); }
const T = ctx.__t;
if (!T) { console.log('FATAL: epilogue did not run (app.js threw before it)'); process.exit(2); }

const iso = (h) => new Date(Date.now() - h * 3600 * 1000).toISOString();
const payload = {
  done_last_24h: 2,
  counts: { All: 3, 'In Progress': 1, 'In Review': 1, Backlog: 1 },
  issues: [
    { id: 'a', number: 751, title: 'Redesign the Ticket Board', state: 'open',
      url: 'https://github.com/corveil/crow/issues/751', repo: 'corveil/crow',
      project_status: 'In Progress', updated_at: iso(2), created_at: iso(72),
      author: 'dhilgaertner', comments_count: 4, body: 'x'.repeat(300),
      labels: [{ name: 'enhancement', color: 'a2eeef' }, { name: 'web', color: '0e8a16' }],
      pr_number: 800, pr_url: 'https://github.com/corveil/crow/pull/800',
      pr_state: 'open', checks: { state: 'FAILURE', failed: ['build', 'lint'] }, linked_session_id: null },
    { id: 'b', number: 42, title: 'Fix flaky auth test', state: 'open',
      url: 'https://gitlab.example.com/acme/api/-/issues/42', repo: 'acme/api',
      project_status: 'In Review', updated_at: iso(5), created_at: iso(200),
      author: 'jordan', comments_count: 1, body: 'Short.', labels: [{ name: 'bug' }],
      pr_number: 17, pr_url: 'https://gitlab.example.com/acme/api/-/merge_requests/17',
      pr_state: 'draft', checks: { state: 'SUCCESS', failed: [] }, linked_session_id: 'sess-123' },
    { id: 'c', number: 900, title: 'Older payload ticket degrades cleanly', state: 'open',
      url: 'https://github.com/corveil/crow/issues/900', repo: 'corveil/crow',
      project_status: 'Backlog', updated_at: iso(30), labels: [], linked_session_id: null },
  ],
};

const q = (sel) => window.document.querySelectorAll(sel);
const board = window.document.getElementById('board');
let pass = 0, fail = 0;
const check = (name, cond) => { if (cond) { pass++; console.log('  ✓ ' + name); } else { fail++; console.log('  ✗ ' + name); } };
function render() { T.boardData.tickets = payload; T.selectedBoard = 'tickets'; T.renderBoard(); }

console.log('Base render:');
T.ticketSort = 'updated_desc'; T.ticketRepoFilter = 'All'; T.ticketFilter = 'All'; T.ticketSearch = '';
render();
check('3 cards rendered', q('.board-card').length === 3);
check('controls row present', q('.board-controls').length === 1);
check('repo select present (2 repos)', q('select.ticket-repo').length === 1);
check('sort select present', q('select.ticket-sort').length === 1);
check('sort options = 6', q('select.ticket-sort option').length === 6);
check('byline w/ author on enriched cards', /dhilgaertner/.test(board.textContent) && q('.card-byline').length >= 2);
check('created "opened … ago" shown', /opened .* ago/.test(board.textContent));
check('comment count 4 shown', q('.byline-comments').length >= 1 && /4/.test(q('.byline-comments')[0].textContent));
check('description excerpt rendered', q('.card-desc').length >= 1);
check('long body has Show more toggle', [...q('.card-desc-toggle')].some((b) => b.textContent === 'Show more'));
check('short body (#42) still renders a desc', q('.card-desc').length >= 2);
check('Open Issue buttons on all 3', [...q('.open-link-btn')].filter((b) => b.textContent === 'Open Issue').length === 3);
check('Open PR buttons on the 2 with a PR', [...q('.open-link-btn')].filter((b) => b.textContent === 'Open PR').length === 2);
check('Open Issue href correct', [...q('.open-link-btn')].find((b) => b.textContent === 'Open Issue').getAttribute('href') === 'https://github.com/corveil/crow/issues/751');
check('Open Issue opens new tab', [...q('.open-link-btn')].find((b) => b.textContent === 'Open Issue').getAttribute('target') === '_blank');
check('pr-state badges = 2', q('.pr-state-badge').length === 2);
check('draft badge text present', /Draft PR/.test(board.textContent));
check('checks badges = 2', q('.checks-badge').length === 2);
check('failing checks tooltip lists names', [...q('.checks-badge')].some((b) => (b.getAttribute('title') || '').includes('build')));
check('CI failing + passing labels', /CI failing/.test(board.textContent) && /CI passing/.test(board.textContent));
check('#900 (old payload) degrades: no badges/byline/desc', (() => {
  const card = [...q('.board-card')].find((c) => /degrades cleanly/.test(c.textContent));
  return card && !card.querySelector('.pr-state-badge') && !card.querySelector('.card-byline') && !card.querySelector('.card-desc');
})());
check('Go to Session on linked card (#42)', /Go to Session/.test(board.textContent));
check('card-actions wraps buttons on the right', q('.card-actions').length === 3);

console.log('\nSort by title (A–Z):');
T.ticketSort = 'title_asc'; render();
let titles = [...q('.card-title')].map((t) => t.textContent);
check('title order alphabetical', titles.join('|') === [...titles].sort((a, b) => a.localeCompare(b)).join('|'));

console.log('\nSort by created (oldest first):');
T.ticketSort = 'created_asc'; render();
titles = [...q('.card-title')].map((t) => t.textContent);
check('created_asc: #900 (no created_at) first, then #42 (oldest)', titles[0].includes('Older payload') && titles[1].includes('flaky'));

console.log('\nRepo filter → corveil/crow only:');
T.ticketSort = 'updated_desc'; T.ticketRepoFilter = 'corveil/crow'; render();
check('repo filter shows only corveil/crow (2)', q('.board-card').length === 2);
check('acme/api card hidden', !/flaky auth/.test(board.textContent));

console.log('\nStatus pipeline (In Review) composes with the rest:');
T.ticketRepoFilter = 'All'; T.ticketFilter = 'In Review'; render();
check('only In Review card (#42) shown', q('.board-card').length === 1 && /flaky auth/.test(board.textContent));

console.log('\nSearch by author "jordan":');
T.ticketFilter = 'All'; T.ticketSearch = 'jordan'; render();
check('author search matches #42', q('.board-card').length === 1 && /flaky auth/.test(board.textContent));

console.log('\nSearch by label name "enhancement" (haystack bug fixed):');
T.ticketSearch = 'enhancement'; render();
check('label-name search matches #751', q('.board-card').length === 1 && /Redesign/.test(board.textContent));

console.log('\nExpand toggle:');
T.ticketSearch = ''; render();
const toggleBtn = [...q('.card-desc-toggle')].find((b) => b.textContent === 'Show more');
toggleBtn.onclick({ stopPropagation() {} });
check('after toggle, one desc expanded', q('.card-desc.expanded').length === 1);
check('toggle now reads Show less', [...q('.card-desc-toggle')].some((b) => b.textContent === 'Show less'));

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
