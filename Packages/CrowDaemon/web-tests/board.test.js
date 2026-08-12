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
  set ticketRefreshPending(v){ticketRefreshPending=v;},
  set reviewRefreshPending(v){reviewRefreshPending=v;},
  set reviewSearch(v){reviewSearch=v;},
  set reviewSelectionMode(v){reviewSelectionMode=v;},
  get selectedReviewURLs(){return selectedReviewURLs;},
  get rpc(){return rpc;},
  set rpc(v){rpc = v;},
  renderBoard(){ return renderBoard(); },
  ticketsCard(){ return ticketsCard(); },
  ticketsRefreshing(){ return ticketsRefreshing(); },
  get sidebarCacheKey(){return SIDEBAR_CACHE_KEY;},
  clearDaemonRefreshFlag(){ return clearDaemonRefreshFlag(); },
  persistSidebarCache(){ return persistSidebarCache(); },
  restoreSidebarCache(){ return restoreSidebarCache(); },
  // CROW-982: the reviews board must not chime for the viewer's own approvals.
  // _soundArmed is normally set by a 2.5s timer the harness stubs out, so the
  // test arms it directly; emitEvent is a function *declaration*, whose binding
  // is mutable, so it can be swapped for a spy and restored.
  detectReviewSounds(){ return detectReviewSounds(); },
  set soundArmed(v){ _soundArmed = v; },
};
globalThis.__t.setEmitEventSpy = (function(){
  const real = emitEvent;
  return function(fn){ emitEvent = fn || real; };
})();
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
check('View Issue buttons on all 3', [...q('.open-link-btn')].filter((b) => b.textContent === 'View Issue').length === 3);
check('View PR buttons on the 2 with a PR', [...q('.open-link-btn')].filter((b) => b.textContent === 'View PR').length === 2);
check('View Issue href correct', [...q('.open-link-btn')].find((b) => b.textContent === 'View Issue').getAttribute('href') === 'https://github.com/corveil/crow/issues/751');
check('View Issue opens new tab', [...q('.open-link-btn')].find((b) => b.textContent === 'View Issue').getAttribute('target') === '_blank');
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

// -- Refresh in-progress indicator (CROW-771) --
// Two independent sources feed `ticketsRefreshing()`: the daemon's `loading`
// flag on the board payload (covers the automatic poll) and the local
// `ticketRefreshPending` flag (covers the click→first-re-read gap).
console.log('\nRefresh spinner — idle:');
delete payload.loading; T.ticketRefreshPending = false; render();
check('no spinner in board head', q('.board-title .action-spinner').length === 0);
check('Refresh button enabled', [...q('.action-btn')].find((b) => b.textContent === 'Refresh').disabled === false);

console.log('\nRefresh spinner — daemon `loading: true` (automatic refresh):');
payload.loading = true; render();
check('spinner beside the board title', q('.board-title .action-spinner').length === 1);
check('Refresh button disabled', [...q('.action-btn')].find((b) => b.textContent === 'Refresh').disabled === true);

console.log('\nRefresh spinner — local pending flag alone (manual click):');
payload.loading = false; T.ticketRefreshPending = true; render();
check('spinner shown without the daemon flag', q('.board-title .action-spinner').length === 1);
check('Refresh button disabled', [...q('.action-btn')].find((b) => b.textContent === 'Refresh').disabled === true);

console.log('\nRefresh spinner — sidebar Tickets card ↻:');
check('↻ swaps for inner .action-spinner + disabled while refreshing', (() => {
  const b = T.ticketsCard().querySelector('.tickets-refresh');
  return b.className.includes('spinning') && b.disabled === true && /Refreshing/.test(b.title)
    // The spinner turns on an inner node, not the button itself (CROW-797): the ↻
    // glyph is gone and the shared `.action-spinner` ring is present.
    && b.querySelector('.action-spinner') !== null && b.textContent === '';
})());
T.ticketRefreshPending = false;
check('↻ glyph restored, no spinner node when idle', (() => {
  const b = T.ticketsCard().querySelector('.tickets-refresh');
  return !b.className.includes('spinning') && b.disabled === false && b.title === 'Refresh tickets'
    && b.querySelector('.action-spinner') === null && b.textContent === '↻';
})());

console.log('\nRefresh spinner — Reviews board:');
T.boardData.reviews = { reviews: [], unseen: 0 };
T.selectedBoard = 'reviews';
T.reviewRefreshPending = true; T.renderBoard();
check('spinner beside the Reviews title', q('.board-title .action-spinner').length === 1);
check('Reviews Refresh disabled', [...q('.action-btn')].find((b) => b.textContent === 'Refresh').disabled === true);
T.reviewRefreshPending = false; T.renderBoard();
check('Reviews idle: no spinner, button enabled',
  q('.board-title .action-spinner').length === 0
  && [...q('.action-btn')].find((b) => b.textContent === 'Refresh').disabled === false);

// -- Reviews multi-select + batch Start Review (CROW-865) --
// Restores the retired ReviewBoardView's batch kickoff on the web board, using
// the ticket board's selection model. r3 already has a review session, so it is
// the non-selectable/dimmed case.
const review = (id, n, title, repo, author, url, hours, sessionID, kickoffAction) => ({
  id, pr_number: n, title, url, repo, author, head_branch: 'feat/' + id, base_branch: 'main',
  is_draft: false, requested_at: iso(hours), labels: [], provider: 'github',
  review_session_id: sessionID || null,
  // Omitted on purpose in the fixtures below: an older daemon doesn't send it,
  // and the client must fall back to the `review_session_id` predicate. The
  // CROW-945 block at the end covers the field being present.
  ...(kickoffAction ? { kickoff_action: kickoffAction } : {}),
});
const reviewsPayload = { unseen: 0, reviews: [
  review('r1', 900, 'Add batch review', 'corveil/crow', 'dhilgaertner', 'https://github.com/corveil/crow/pull/900', 1),
  review('r2', 17, 'Fix flaky auth', 'acme/api', 'jordan', 'https://gitlab.example.com/acme/api/-/merge_requests/17', 3),
  review('r3', 800, 'Redesign the board', 'corveil/crow', 'sam', 'https://github.com/corveil/crow/pull/800', 5, 'sess-r3'),
]};
const btn = (text) => [...q('.action-btn')].find((b) => b.textContent === text);
const countBtn = (text) => [...q('.action-btn')].filter((b) => b.textContent === text).length;
function renderReviews() { T.boardData.reviews = reviewsPayload; T.selectedBoard = 'reviews'; T.renderBoard(); }

console.log('\nReviews board — idle (no select mode):');
T.reviewSearch = ''; T.reviewSelectionMode = false; T.selectedReviewURLs.clear();
renderReviews();
check('3 review cards rendered', q('.board-card').length === 3);
check('Select offered (2 startable)', !!btn('Select'));
check('per-card Start Review on the 2 unlinked', countBtn('Start Review') === 2);
check('linked review offers Go to Session', !!btn('Go to Session'));
check('no checkboxes outside select mode', q('.row-check').length === 0);

console.log('\nReviews board — select mode:');
btn('Select').onclick();
check('toggle now reads Cancel, styled red', !!btn('Cancel') && btn('Cancel').className.includes('nav-selecting'));
check('checkbox only on the 2 selectable rows', q('.row-check').length === 2);
check('linked row dimmed via .not-selectable', (() => {
  const dim = [...q('.board-card.not-selectable')];
  return dim.length === 1 && /Redesign the board/.test(dim[0].textContent) && !dim[0].querySelector('.row-check');
})());
check('per-card Start Review suppressed while selecting', countBtn('Start Review') === 0);
check('Go to Session still rendered on the linked row', !!btn('Go to Session'));
check('no bulk bar until something is ticked', q('.bulk-bar').length === 0);

console.log('\nTicking rows:');
q('.row-check')[0].onclick({ stopPropagation() {} });
check('bulk bar appears', q('.bulk-bar').length === 1);
check('count reads "1 review selected"', /1 review selected/.test(q('.bulk-count')[0].textContent));
check('action reads Start Review (1)', !!btn('Start Review (1)'));
check('ticked card carries .selected', q('.board-card.selected').length === 1);
// The whole card toggles too, not just the checkbox.
[...q('.board-card')].find((c) => c.className.includes('selecting') && !c.className.includes('selected')).onclick();
check('card click toggles → "2 reviews selected"', /2 reviews selected/.test(q('.bulk-count')[0].textContent));
check('action reads Start Review (2)', !!btn('Start Review (2)'));

console.log('\nCancel:');
btn('Cancel').onclick();
check('selection cleared', T.selectedReviewURLs.size === 0);
check('per-card Start Review restored', countBtn('Start Review') === 2);
check('no checkboxes or bulk bar left', q('.row-check').length === 0 && q('.bulk-bar').length === 0);
check('nothing dimmed outside select mode', q('.board-card.not-selectable').length === 0);

console.log('\nSelection is pruned against the visible set:');
btn('Select').onclick();
q('.row-check')[0].onclick({ stopPropagation() {} });
check('sanity: 1 selected', T.selectedReviewURLs.size === 1);
T.reviewSearch = 'jordan'; T.renderBoard();   // hides r1, the selected one
check('search-hidden review drops out of the selection', T.selectedReviewURLs.size === 0);
T.reviewSearch = ''; T.reviewSelectionMode = false; T.renderBoard();

console.log('\nEvery review already linked:');
T.boardData.reviews = { unseen: 0,
  reviews: reviewsPayload.reviews.map((r) => Object.assign({}, r, { review_session_id: 'sess-x' })) };
T.renderBoard();
check('no Select button when nothing is startable', !btn('Select'));
check('all 3 rows offer Go to Session', countBtn('Go to Session') === 3);

// -- The board offers the next round (CROW-945) --
// Before this, the card was gated purely on "does a non-completed session link
// to this PR", which is a much weaker question than "has this review round been
// answered". A re-requested PR therefore rendered only "Go to Session" pointing
// at the dead round-1 session, and the sole way forward was deleting it by hand.
// The server now sends the verdict from the same decision function
// `createReviewSession` runs, and the card renders it.
console.log('\nReviews board — kickoff_action drives the button (CROW-945):');
T.reviewSelectionMode = false; T.selectedReviewURLs.clear();
T.boardData.reviews = { unseen: 0, reviews: [
  review('k1', 1, 'Fresh request', 'corveil/crow', 'sam', 'https://github.com/corveil/crow/pull/1', 1, null, 'create'),
  review('k2', 2, 'Round 1 answered, author pushed', 'corveil/crow', 'sam', 'https://github.com/corveil/crow/pull/2', 2, 'sess-k2', 're_review'),
  review('k3', 3, 'Covered at this head', 'corveil/crow', 'sam', 'https://github.com/corveil/crow/pull/3', 3, 'sess-k3', 'skip'),
]};
T.renderBoard();
check('create → Start Review', countBtn('Start Review') === 1);
check('re_review → Re-review', !!btn('Re-review'));
check('skip → no kickoff button', countBtn('Start Review') === 1 && countBtn('Re-review') === 1);
// The stale round is still reachable — "Re-review" retires it, so the user
// should be able to read it first.
check('both linked rows keep Go to Session', countBtn('Go to Session') === 2);
check('a re-reviewable row is selectable for batch', (() => {
  T.reviewSelectionMode = true; T.renderBoard();
  const n = q('.row-check').length;
  T.reviewSelectionMode = false; T.renderBoard();
  return n === 2;   // k1 (create) + k2 (re_review); k3 (skip) is not
})());
check('skip row is the only dimmed one in select mode', (() => {
  T.reviewSelectionMode = true; T.renderBoard();
  const dim = [...q('.board-card.not-selectable')];
  const ok = dim.length === 1 && /Covered at this head/.test(dim[0].textContent);
  T.reviewSelectionMode = false; T.renderBoard();
  return ok;
})());
// Re-review goes through `start-review` like everything else: one verb, and the
// server owns the decision (the board's action is computed from a poll-stale
// head, so it picks the label and must never suppress the call).
check('Re-review dispatches start-review', (() => {
  let sent = null;
  const prevRpc = T.rpc;
  T.rpc = async (method, params) => { sent = { method, params }; return {}; };
  btn('Re-review').onclick();
  T.rpc = prevRpc;
  return sent && sent.method === 'start-review' && sent.params.url === 'https://github.com/corveil/crow/pull/2';
})());
T.boardData.reviews = reviewsPayload; T.renderBoard();

// The daemon half of the flag has no `finally` to fall back on — it clears only
// when a later `list-tickets` says so. These cover the paths where that never
// comes, which would otherwise strand the spinner (AC3; PR #784 review).
console.log('\nStale `loading` never strands the spinner:');
T.selectedBoard = 'tickets';
T.boardData.tickets = Object.assign({}, payload, { loading: true });
check('sanity: daemon flag alone marks it refreshing', T.ticketsRefreshing() === true);
T.clearDaemonRefreshFlag();
check('clearing the daemon flag stops the indicator', T.ticketsRefreshing() === false);
check('clear is idempotent when already false', (() => { T.clearDaemonRefreshFlag(); return T.ticketsRefreshing() === false; })());

console.log('\nSidebar cache never resurrects a spinner across a reload:');
T.boardData.tickets = Object.assign({}, payload, { loading: true });
T.persistSidebarCache();                       // cache written mid-fetch
check('persisted payload has loading stripped',
  JSON.parse(window.localStorage.getItem(T.sidebarCacheKey) || '{}').tickets.loading === false);
T.boardData.tickets = { counts: {}, issues: [] };
T.restoreSidebarCache();                       // …and read back on the next boot
check('restored payload is not refreshing', T.ticketsRefreshing() === false);
check('restore kept the rest of the payload', T.boardData.tickets.issues.length === 3);

// A legacy cache written before the strip landed must also be scrubbed.
window.localStorage.setItem(T.sidebarCacheKey, JSON.stringify({
  sessions: [], tickets: Object.assign({}, payload, { loading: true }), reviews: { reviews: [] },
}));
T.restoreSidebarCache();
check('legacy cache with loading:true is scrubbed on restore', T.ticketsRefreshing() === false);

// ---------------------------------------------------------------------------
// Reviews board — three groups (CROW-982)
//
// The board used to be one flat list, so approving a PR made it vanish outright
// (GitHub clears the review request on submit). The server now assigns each
// review a `group` and publishes the order + counts; the board must render
// every group — including empty ones, so a quiet board still says *what* is
// quiet, which was half the shock in #953.
// ---------------------------------------------------------------------------
const grouped = (id, n, group, extra) => Object.assign(
  review(id, n, 'PR ' + n, 'corveil/crow', 'sam', 'https://github.com/corveil/crow/pull/' + n, 2),
  { group }, extra || {});

const groupTitles = () => [...q('.group-title')].map((e) => e.textContent);
const groupCounts = () => [...q('.group-count')].map((e) => e.textContent);
const cardsUnder = (title) => {
  // Walk forward from the header to the next .card-list sibling.
  const head = [...q('.group-head')].find((h) => h.textContent.includes(title));
  if (!head) return [];
  let n = head.nextSibling;
  while (n && !(n.className || '').includes('card-list')) {
    if ((n.className || '').includes('group-head')) return [];
    n = n.nextSibling;
  }
  return n ? [...n.querySelectorAll('.board-card')] : [];
};

console.log('\nReviews board — three groups (CROW-982):');
T.reviewSearch = ''; T.reviewSelectionMode = false; T.selectedReviewURLs.clear();
T.boardData.reviews = {
  unseen: 0,
  group_order: ['in_review', 'not_approved_yet', 'approved_recently'],
  group_counts: { in_review: 1, not_approved_yet: 1, approved_recently: 1 },
  hidden_by_filters: 0,
  reviews: [
    grouped('g1', 101, 'in_review', { review_session_id: 'sess-1', kickoff_action: 'skip' }),
    grouped('g2', 102, 'not_approved_yet', { kickoff_action: 'create' }),
    grouped('g3', 103, 'approved_recently', {
      kickoff_action: 'create',
      viewer_last_review_state: 'APPROVED',
      viewer_last_reviewed_at: iso(2),
    }),
  ],
};
T.selectedBoard = 'reviews'; T.renderBoard();
check('all three groups render, in server order',
  JSON.stringify(groupTitles()) === JSON.stringify(['In review', 'Not approved yet', 'Approved recently · 24h']));
check('counts come from the server payload',
  JSON.stringify(groupCounts()) === JSON.stringify(['1', '1', '1']));
check('each PR lands in exactly one group', q('.board-card').length === 3);
check('in-review card is under In review', /PR 101/.test((cardsUnder('In review')[0] || {}).textContent || ''));
check('approved card is under Approved recently',
  /PR 103/.test((cardsUnder('Approved recently')[0] || {}).textContent || ''));
check('approved card shows when it was approved, not the PR bump',
  /approved /.test(cardsUnder('Approved recently')[0].textContent));

console.log('\nEmpty groups render with a zero count instead of disappearing:');
T.boardData.reviews = {
  unseen: 0,
  group_order: ['in_review', 'not_approved_yet', 'approved_recently'],
  group_counts: { in_review: 0, not_approved_yet: 0, approved_recently: 0 },
  hidden_by_filters: 0,
  reviews: [],
};
T.renderBoard();
check('three headers still present with nothing to show', q('.group-head').length === 3);
check('every count reads 0', JSON.stringify(groupCounts()) === JSON.stringify(['0', '0', '0']));
check('each empty group says what is empty', q('.group-empty').length === 3);

console.log('\nHidden-by-filters is surfaced (#953 direction C):');
T.boardData.reviews = {
  unseen: 0,
  group_order: ['in_review', 'not_approved_yet', 'approved_recently'],
  group_counts: { in_review: 0, not_approved_yet: 0, approved_recently: 0 },
  hidden_by_filters: 12,
  reviews: [],
};
T.renderBoard();
check('the hidden count is stated', /12 hidden by filters/.test((q('.board-note')[0] || {}).textContent || ''));
T.boardData.reviews.hidden_by_filters = 0;
T.renderBoard();
check('no note when nothing is hidden', q('.board-note').length === 0);

console.log('\nSearching scopes to matching groups and counts the visible rows:');
T.boardData.reviews = {
  unseen: 0,
  group_order: ['in_review', 'not_approved_yet', 'approved_recently'],
  group_counts: { in_review: 1, not_approved_yet: 1, approved_recently: 1 },
  hidden_by_filters: 0,
  reviews: [
    grouped('g1', 101, 'in_review', { review_session_id: 'sess-1', kickoff_action: 'skip' }),
    grouped('g2', 102, 'not_approved_yet', { kickoff_action: 'create' }),
    grouped('g3', 103, 'approved_recently', { kickoff_action: 'create' }),
  ],
};
T.reviewSearch = '102';
T.renderBoard();
check('only the matching group is shown', JSON.stringify(groupTitles()) === JSON.stringify(['Not approved yet']));
check('its count reflects the visible rows, not the unfiltered total', groupCounts()[0] === '1');
T.reviewSearch = 'nothing-matches-this';
T.renderBoard();
check('a search with no hits falls back to the empty-board message', q('.board-empty').length === 1);
T.reviewSearch = '';

console.log('\nAn older daemon that sends no groups still renders every review:');
T.boardData.reviews = reviewsPayload;   // no group / group_counts / group_order
T.renderBoard();
check('ungrouped reviews default into Not approved yet', cardsUnder('Not approved yet').length === 3);
check('count falls back to the rendered rows rather than claiming zero',
  groupCounts()[groupTitles().indexOf('Not approved yet')] === '3');

console.log('\nApproving something never chimes "review requested":');
T.soundArmed = true;
T.boardData.reviews = {
  unseen: 0,
  reviews: [grouped('g2', 102, 'not_approved_yet', { kickoff_action: 'create' })],
};
T.detectReviewSounds();                       // arm the baseline
const emitted = [];
T.setEmitEventSpy((name, key) => emitted.push([name, key]));
T.boardData.reviews = {
  unseen: 0,
  reviews: [
    grouped('g2', 102, 'not_approved_yet', { kickoff_action: 'create' }),
    grouped('g3', 103, 'approved_recently', { kickoff_action: 'create' }),
    grouped('g4', 104, 'not_approved_yet', { kickoff_action: 'create' }),
  ],
};
T.detectReviewSounds();
check('a genuinely new request chimes', emitted.some(([n, k]) => n === 'reviewRequested' && k === 'g4'));
check('the approved tail does not', !emitted.some(([, k]) => k === 'g3'));
T.setEmitEventSpy(null);

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
