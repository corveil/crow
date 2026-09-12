'use strict';
// Crow web UI — Reviews board: groups, select/start. Extracted from boards.js (CROW-1242).

// -- Review Board --
function renderReviewBoard(root) {
  const d = boardData.reviews;
  const busy = reviewsRefreshing();

  // Filter/sort up front — before the head — so the Select button, the
  // selection pruning, and the list all see the same visible set and no hidden
  // review can be started (same ordering as renderTicketBoard).
  let reviews = ((d && d.reviews) || []).slice()
    .sort((a, b) => (b.requested_at || '').localeCompare(a.requested_at || ''));
  const q = reviewSearch.trim().toLowerCase();
  if (q) reviews = reviews.filter((r) => reviewHaystack(r).includes(q));
  // Only reviews the server would actually act on can be started, so only
  // those are selectable. Prune stale selections against the *visible* set (a
  // refresh or the search may have removed/hidden/linked a review).
  const selectableUrls = new Set(reviews.filter(reviewIsActionable).map((r) => r.url));
  for (const url of [...selectedReviewURLs]) if (!selectableUrls.has(url)) selectedReviewURLs.delete(url);

  const head = el('div', 'board-head');
  const title = el('div', 'board-title', 'Reviews');
  if (busy) title.appendChild(el('span', 'action-spinner'));
  head.appendChild(title);
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.disabled = busy;
  refresh.onclick = () => refreshReviews();
  head.appendChild(refresh);
  // Select / Cancel toggle (CROW-865, mirroring the ticket board and the
  // retired ReviewBoardView). Hidden when nothing is startable.
  if (selectableUrls.size) {
    const sel = el('button', 'action-btn' + (reviewSelectionMode ? ' nav-selecting' : ''),
      reviewSelectionMode ? 'Cancel' : 'Select');
    sel.onclick = () => {
      reviewSelectionMode = !reviewSelectionMode;
      if (!reviewSelectionMode) selectedReviewURLs.clear();
      renderBoard();
    };
    head.appendChild(sel);
  } else if (reviewSelectionMode) {
    reviewSelectionMode = false;
  }
  root.appendChild(head);

  // Batch action bar: shown while selecting with at least one review ticked.
  if (reviewSelectionMode && selectedReviewURLs.size) {
    const bar = el('div', 'bulk-bar');
    const n = selectedReviewURLs.size;
    bar.appendChild(el('span', 'bulk-count', n + ' review' + (n === 1 ? '' : 's') + ' selected'));
    bar.appendChild(el('div', 'bulk-spacer'));
    const start = el('button', 'action-btn action-primary', 'Start Review (' + n + ')');
    start.onclick = () => startReviewSelected(start);
    bar.appendChild(start);
    root.appendChild(bar);
  }

  // #714: search bar; clearing restores the full list.
  root.appendChild(boardFilterInput('review-filter', reviewSearch, 'Filter reviews…', (v) => { reviewSearch = v; }));

  // Four groups, not one flat list (CROW-982, CROW-990). The server assigns
  // every review a `group` and publishes the display order, so the board and
  // `crow list-reviews` can't disagree about which bucket a PR is in — and a
  // future fifth group needs no change here.
  //
  // Empty groups render with a zero count instead of disappearing: a reviewed
  // PR used to vanish outright, and a board that shows nothing at all can't
  // tell you *what* is empty. That silence was half the shock in #953.
  const order = (d && d.group_order)
    || ['in_review', 'not_approved_yet', 'waiting_on_author', 'recently_completed'];
  const counts = (d && d.group_counts) || null;
  const searching = !!q;
  let rendered = 0;
  for (const g of order) {
    const inGroup = reviews.filter((r) => (r.group || 'not_approved_yet') === g);
    // While searching, the counts chip would contradict the visible rows
    // (`group_counts` is unfiltered), and empty groups are just noise — so show
    // only groups with matches and count what's actually on screen. Same
    // fallback when an older daemon sends no counts at all: count the rows
    // rather than claim zero under a group that visibly has cards.
    if (searching && !inGroup.length) continue;
    const total = (searching || !counts) ? inGroup.length : (counts[g] || 0);
    const head = el('div', 'group-head');
    head.appendChild(el('span', 'group-title', reviewGroupTitle(g)));
    head.appendChild(el('span', 'group-count', String(total)));
    root.appendChild(head);
    if (!inGroup.length) {
      root.appendChild(el('div', 'group-empty', reviewGroupEmptyText(g)));
      continue;
    }
    const list = el('div', 'card-list');
    for (const r of inGroup) list.appendChild(reviewCard(r));
    root.appendChild(list);
    rendered += inGroup.length;
  }
  if (searching && !rendered) root.appendChild(boardEmpty('No matching reviews'));

  // #953 direction C: `ignoreReviewLabels` / `excludeReviewRepos` silently hid
  // real `review-requested:@me` PRs during that incident and the board looked
  // empty while GitHub's queue was not. Say so.
  const hidden = (d && d.hidden_by_filters) || 0;
  if (hidden) {
    root.appendChild(el('div', 'board-note',
      hidden + ' hidden by filters (repo/label rules in Settings → Automation)'));
  }
}

// Titles come from the server's group ids so the two clients agree on naming as
// well as on membership. Unknown ids fall back to the raw id rather than being
// dropped — a board that silently swallows a group is the bug this fixes.
function reviewGroupTitle(g) {
  return ({
    in_review: 'In review',
    not_approved_yet: 'Not approved yet',
    waiting_on_author: 'Waiting on author',
    recently_completed: 'Recently completed · 24h',
  })[g] || g;
}

function reviewGroupEmptyText(g) {
  return ({
    in_review: 'No reviews in progress',
    not_approved_yet: 'Nothing waiting on you',
    waiting_on_author: 'Nothing waiting on an author',
    recently_completed: 'Nothing finished in the last 24h',
  })[g] || 'Empty';
}

function toggleReviewSelect(url) {
  if (selectedReviewURLs.has(url)) selectedReviewURLs.delete(url);
  else selectedReviewURLs.add(url);
  renderBoard();
}

// Batch "Start Review (N)": ONE batch-start-review call with every selected PR.
// The daemon queues the kickoffs on its review serializer and acks immediately
// — each one clones a PR and spawns tmux, well past our rpc deadline — so
// the new sessions surface via the sidebar poll rather than this response
// (CROW-865). Then clear selection and exit selection mode.
async function startReviewSelected(btn) {
  const urls = ((boardData.reviews && boardData.reviews.reviews) || [])
    .filter((r) => reviewIsActionable(r) && selectedReviewURLs.has(r.url))
    .map((r) => r.url);
  if (!urls.length) return;
  btn.disabled = true;
  btn.textContent = 'Starting…';
  let problem = '';
  try {
    const res = await rpc('batch-start-review', { urls });
    const rejected = (res && res.rejected) || [];
    if (rejected.length) problem = rejected.length + ' review(s) could not be started.';
  } catch (e) {
    problem = 'Start Review failed: ' + (e.message || e);
  }
  selectedReviewURLs.clear();
  reviewSelectionMode = false;
  refreshReviews();
  renderBoard();
  if (problem) alertModal(problem);
}

// #714: lowercased searchable text for a review — title, repo, @author, #pr_number.
function reviewHaystack(r) {
  return [r.title, r.repo, '@' + r.author, '#' + r.pr_number].join(' ').toLowerCase();
}

// Whether pressing Start Review / Re-review on this card would actually do
// something (CROW-945). The server computes `kickoff_action` from the same
// decision function `createReviewSession` runs, so the button reflects the
// real verdict rather than the much weaker "does *a* session link to this PR"
// question — which is what left a re-requested PR showing only "Go to Session"
// pointing at a dead round.
//
// It also carries the server's group-level suppressions: a merged PR and a quiet
// Waiting-on-author one both come back `skip` (CROW-997), so the button and the
// batch checkbox disappear together off one field rather than off a second rule
// here that could drift from the payload's grouping.
//
// The action is an estimate: it's computed from the board's head SHA, up to a
// poll stale, while the server decides against a head it fetches itself. So it
// picks the *label* and never suppresses the RPC — the server is the decider.
// Falls back to the old predicate when the field is absent (older daemon).
function reviewIsActionable(r) {
  if (!r.kickoff_action) return !r.review_session_id;
  return r.kickoff_action === 'create' || r.kickoff_action === 're_review';
}

// The relative-time chip on a review card, labelled with the event it measures.
//
// Each group is answering a different question, and an unlabelled "2h" under
// three of them would be three different facts wearing one hat:
//   Recently completed  → when it merged/closed, or when you approved it
//   Waiting on author   → when you last reviewed it (how long the author has sat on it)
//   otherwise           → when the request last moved
// Falls through to `requested_at` whenever the specific timestamp is missing, so
// a partial payload loses the label rather than the chip.
function reviewCardTime(r) {
  if (r.group === 'recently_completed') {
    // A merged/closed PR carries `completed_at`; an approved-but-still-open one
    // doesn't, and there the approval is what put it here.
    const done = relTime(r.completed_at);
    if (done) return (r.state === 'MERGED' ? 'merged ' : 'closed ') + done;
    const approved = relTime(r.viewer_last_reviewed_at);
    if (approved) return 'approved ' + approved;
  } else if (r.group === 'waiting_on_author') {
    const reviewed = relTime(r.viewer_last_reviewed_at);
    if (reviewed) return 'reviewed ' + reviewed;
  }
  return relTime(r.requested_at);
}

function reviewCard(r) {
  // A review the board doesn't offer a kickoff for isn't selectable either — it
  // renders dimmed and checkbox-less while selecting, as the retired
  // ReviewBoardView did, but keeps its Go to Session button. One field decides
  // both, so a row can never be un-clickable yet batch-startable.
  const selectable = reviewIsActionable(r);
  const selecting = reviewSelectionMode && selectable;
  const isSel = selectedReviewURLs.has(r.url);
  const card = el('div', 'board-card'
    + (selecting ? ' selecting' : '') + (isSel ? ' selected' : '')
    + (reviewSelectionMode && !selectable ? ' not-selectable' : ''));
  card.oncontextmenu = (e) => showCardMenu(e, [{ label: 'Copy PR link', url: r.url }]);
  // In selection mode a checkbox leads a selectable card and the whole card
  // toggles selection (mirrors the ticket board).
  if (selecting) {
    const cb = el('input', 'row-check');
    cb.type = 'checkbox';
    cb.checked = isSel;
    cb.onclick = (e) => { e.stopPropagation(); toggleReviewSelect(r.url); };
    card.appendChild(cb);
    card.onclick = () => toggleReviewSelect(r.url);
  }
  const meta = el('div', 'card-meta');
  meta.appendChild(el('span', 'repo-tag', r.repo));
  const chip = linkChip('#' + r.pr_number, r.url, 'pr');
  // The chip is the only way to open the PR, and in select mode the card
  // beneath it toggles selection — don't do both on one click. Kept local to
  // reviewCard: linkChip is shared with ticketCard, whose behavior is unchanged.
  if (selecting) chip.onclick = (e) => e.stopPropagation();
  meta.appendChild(chip);
  if (r.is_draft) meta.appendChild(el('span', 'draft-badge', 'Draft'));
  // Outside the requested queue, `requested_at` (the PR's `updatedAt`) answers
  // the wrong question: under these headings you want to know when the PR
  // finished, or when you last said something about it — not when the thread
  // was last bumped.
  const stamp = reviewCardTime(r);
  if (stamp) meta.appendChild(el('span', 'card-time', stamp));
  card.appendChild(meta);
  card.appendChild(el('div', 'card-title', r.title));
  const sub = el('div', 'card-sub');
  sub.appendChild(el('span', null, '@' + r.author));
  if (r.head_branch) sub.appendChild(el('span', 'branch-tag', r.head_branch));
  card.appendChild(sub);
  if (r.labels && r.labels.length) card.appendChild(labelPills(r.labels));
  const foot = el('div', 'card-foot');
  // A linked session is still reachable even when a new round is offered —
  // "Re-review" retires that round, so the user should be able to look at it
  // first. Order: the kickoff button leads, Go to Session follows.
  if (!selecting && reviewIsActionable(r)) {
    // Suppressed while selecting — the batch bar owns the kickoff there.
    const reReview = r.kickoff_action === 're_review';
    // Both go through `start-review`: the server runs the kickoff decision and
    // completes the stale round itself, so there is one verb and one rule.
    const label = reReview ? 'Re-review' : 'Start Review';
    const rev = el('button', 'action-btn action-primary', label);
    rev.onclick = () => spawnAction(rev, 'start-review', { url: r.url }, label);
    foot.appendChild(rev);
  }
  if (r.review_session_id) {
    const go = el('button', 'action-btn', 'Go to Session');
    go.onclick = () => selectSession(r.review_session_id);
    foot.appendChild(go);
  }
  // `.card-foot` carries a top margin, so a selectable card in select mode —
  // which has no button at all — would otherwise end in 8px of dead space.
  if (foot.childNodes.length) card.appendChild(foot);
  return card;
}
