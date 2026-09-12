'use strict';
// Crow web UI — Ticket Board: sort/filter/select/start. Extracted from boards.js (CROW-1242).

// #751: apply the active sort. Dates are ISO-8601, so a string compare orders
// them; title is case-insensitive; status uses the PIPELINE index (Backlog→Done)
// with updated-desc as a tiebreak.
function sortIssues(issues) {
  const arr = issues.slice();
  const s = (a, b) => a.localeCompare(b);
  switch (ticketSort) {
    case 'updated_asc': arr.sort((a, b) => s(a.updated_at || '', b.updated_at || '')); break;
    case 'created_desc': arr.sort((a, b) => s(b.created_at || '', a.created_at || '')); break;
    case 'created_asc': arr.sort((a, b) => s(a.created_at || '', b.created_at || '')); break;
    case 'title_asc': arr.sort((a, b) => s((a.title || '').toLowerCase(), (b.title || '').toLowerCase())); break;
    case 'status': arr.sort((a, b) =>
      (PIPELINE.indexOf(a.project_status) - PIPELINE.indexOf(b.project_status))
      || s(b.updated_at || '', a.updated_at || '')); break;
    case 'updated_desc':
    default: arr.sort((a, b) => s(b.updated_at || '', a.updated_at || '')); break;
  }
  return arr;
}

function renderTicketBoard(root) {
  const d = boardData.tickets;
  const allIssues = (d && d.issues) || [];
  // Compose the status pipeline filter (#660) with the #714 search up front so the
  // Select button, selection pruning, and the list all operate on the same visible
  // set — no hidden ticket can be started.
  // Distinct repos for the repo filter (#751). Reset a stale selection so a
  // repo that dropped out of the payload doesn't hide the whole board.
  const repos = [...new Set(allIssues.map((i) => i.repo))].sort();
  if (ticketRepoFilter !== 'All' && !repos.includes(ticketRepoFilter)) ticketRepoFilter = 'All';

  let issues = allIssues.slice();
  if (ticketFilter !== 'All') issues = issues.filter((i) => i.project_status === ticketFilter);
  if (ticketRepoFilter !== 'All') issues = issues.filter((i) => i.repo === ticketRepoFilter);
  const q = ticketSearch.trim().toLowerCase();
  if (q) issues = issues.filter((i) => ticketHaystack(i).includes(q));
  issues = sortIssues(issues);
  // Only tickets without a linked session are startable, so only those are
  // selectable. Prune any stale selections against the *visible* set (refresh,
  // status filter, or search may have removed/hidden/linked issues).
  const selectableUrls = new Set(issues.filter((i) => !i.linked_session_id).map((i) => i.url));
  for (const url of [...selectedIssueIDs]) if (!selectableUrls.has(url)) selectedIssueIDs.delete(url);

  const head = el('div', 'board-head');
  // Spinner nests *inside* the title, where native's `ProgressView()` sat:
  // `.board-title` carries `margin-right: auto`, so a sibling would be shoved
  // to the right edge with the buttons instead (CROW-771).
  const title = el('div', 'board-title', 'Ticket Board');
  if (ticketsRefreshing()) title.appendChild(el('span', 'action-spinner'));
  head.appendChild(title);
  if (d && d.done_last_24h) head.appendChild(el('span', 'done-chip', d.done_last_24h + ' done · 24h'));
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.disabled = ticketsRefreshing();
  refresh.onclick = () => refreshTickets();
  head.appendChild(refresh);
  // Select / Cancel toggle (mirrors the native selectToggleButton). Hidden when
  // there is nothing selectable to start work on.
  if (selectableUrls.size) {
    const sel = el('button', 'action-btn' + (ticketSelectionMode ? ' nav-selecting' : ''),
      ticketSelectionMode ? 'Cancel' : 'Select');
    sel.onclick = () => {
      ticketSelectionMode = !ticketSelectionMode;
      if (!ticketSelectionMode) selectedIssueIDs.clear();
      renderBoard();
    };
    head.appendChild(sel);
  } else if (ticketSelectionMode) {
    ticketSelectionMode = false;
  }
  root.appendChild(head);

  // Batch action bar (mirrors the native batchActionBar): shown while selecting
  // with at least one ticket ticked.
  if (ticketSelectionMode && selectedIssueIDs.size) {
    const bar = el('div', 'bulk-bar');
    const n = selectedIssueIDs.size;
    bar.appendChild(el('span', 'bulk-count', n + ' ticket' + (n === 1 ? '' : 's') + ' selected'));
    bar.appendChild(el('div', 'bulk-spacer'));
    bar.appendChild(startActionsSplit(
      'Start Working (' + n + ')',
      (btn) => startSelected(btn, false),
      [
        { label: 'Start Working (' + n + ')', title: 'Worktree + implement/build prompt',
          onClick: (btn) => startSelected(btn, false) },
        { label: 'Start Exploring (' + n + ')', title: 'Same setup, read/explain-only prompt',
          onClick: (btn) => startSelected(btn, true) },
      ]));
    root.appendChild(bar);
  }

  const counts = (d && d.counts) || {};
  const bar = el('div', 'pipeline');
  for (const seg of PIPELINE) {
    const n = seg === 'All' ? (counts.All || 0) : (counts[seg] || 0);
    const cell = el('div', 'pipe-seg' + (ticketFilter === seg ? ' active' : ''));
    // Category icon + color from the shared maps, so each heading matches the sidebar
    // count for the same status (web reland of #732). 'All' stays label-only.
    if (seg !== 'All' && TICKET_STATUS_ICON[seg]) {
      const ic = icon(TICKET_STATUS_ICON[seg], 14);
      ic.style.color = TICKET_STATUS_COLOR[seg] || 'var(--text-muted)';
      cell.appendChild(ic);
    }
    cell.appendChild(el('span', 'pipe-label', seg));
    cell.appendChild(el('span', 'pipe-count', String(n)));
    cell.onclick = () => { ticketFilter = seg; renderBoard(); };
    bar.appendChild(cell);
  }
  root.appendChild(bar);

  // #751: repo filter + sort controls, composed with the status pipeline above
  // and the search below. Repo selector only appears when multiple repos exist.
  const controls = el('div', 'board-controls');
  if (repos.length > 1) {
    const repoWrap = el('label', 'board-control');
    repoWrap.appendChild(el('span', 'board-control-label', 'Repo'));
    repoWrap.appendChild(boardSelect('ticket-repo',
      [['All', 'All repos'], ...repos.map((r) => [r, r])],
      ticketRepoFilter, (v) => { ticketRepoFilter = v; }));
    controls.appendChild(repoWrap);
  }
  const sortWrap = el('label', 'board-control');
  sortWrap.appendChild(el('span', 'board-control-label', 'Sort'));
  sortWrap.appendChild(boardSelect('ticket-sort', TICKET_SORT_OPTIONS, ticketSort, (v) => { ticketSort = v; }));
  controls.appendChild(sortWrap);
  root.appendChild(controls);

  // #714: search bar below the pipeline (both act as filters). Composed with the
  // status segment above; clearing restores the full status-filtered list.
  root.appendChild(boardFilterInput('ticket-filter', ticketSearch, 'Filter tickets…', (v) => { ticketSearch = v; }));

  if (!issues.length) { root.appendChild(boardEmpty(q ? 'No matching tickets' : 'No tickets in this view')); return; }
  const list = el('div', 'card-list');
  for (const i of issues) list.appendChild(ticketCard(i));
  root.appendChild(list);
}

// #714: lowercased searchable text for a ticket — title, repo, #number, labels,
// author. Labels are {name,color} objects, so map to names (#751 fixes the old
// bug that spread the raw objects and searched "[object Object]").
function ticketHaystack(i) {
  return [i.title, i.repo, '#' + i.number, i.author || '', ...(i.labels || []).map((l) => l.name)]
    .join(' ').toLowerCase();
}

function ticketCard(i) {
  const selectable = !i.linked_session_id;
  const selecting = ticketSelectionMode && selectable;
  const isSel = selectedIssueIDs.has(i.url);
  const card = el('div', 'board-card status-accent'
    + (selecting ? ' selecting' : '') + (isSel ? ' selected' : ''));
  card.oncontextmenu = (e) => showCardMenu(e, [
    { label: 'Copy issue link', url: i.url },
    i.pr_url ? { label: 'Copy PR link', url: i.pr_url } : null,
  ]);
  const sc = TICKET_STATUS_COLOR[i.project_status] || 'var(--text-muted)';
  card.style.borderLeftColor = sc;
  // In selection mode a checkbox leads a selectable card and the whole card
  // toggles selection (mirrors the native TicketCard tap-to-select).
  if (selecting) {
    const cb = el('input', 'row-check');
    cb.type = 'checkbox';
    cb.checked = isSel;
    cb.onclick = (e) => { e.stopPropagation(); toggleIssueSelect(i.url); };
    card.appendChild(cb);
    card.onclick = () => toggleIssueSelect(i.url);
  }
  const meta = el('div', 'card-meta');
  meta.appendChild(el('span', 'repo-tag', i.repo));
  meta.appendChild(linkChip('Issue #' + i.number, i.url, 'ticket'));
  if (i.pr_number && i.pr_url) meta.appendChild(linkChip('PR #' + i.pr_number, i.pr_url, 'pr'));
  const t = relTime(i.updated_at);
  if (t) meta.appendChild(el('span', 'card-time', t));
  card.appendChild(meta);
  card.appendChild(el('div', 'card-title', i.title));

  // #751: author + created date + comment count sub-line. All fields optional
  // (older payloads / providers omit them), so render only what's present.
  const ct = relTime(i.created_at);
  if (i.author || ct || (i.comments_count != null && i.comments_count > 0)) {
    const byline = el('div', 'card-byline');
    if (i.author) byline.appendChild(el('span', 'byline-author', i.author));
    if (ct) byline.appendChild(el('span', 'byline-created',
      ct === 'just now' ? 'opened just now' : 'opened ' + ct + ' ago'));
    if (i.comments_count != null && i.comments_count > 0) {
      const c = el('span', 'byline-comments');
      c.appendChild(icon('comment', 12));
      c.appendChild(el('span', null, String(i.comments_count)));
      c.title = i.comments_count + ' comment' + (i.comments_count === 1 ? '' : 's');
      byline.appendChild(c);
    }
    card.appendChild(byline);
  }

  // #751: description excerpt (line-clamped) with an expand toggle. The full
  // (server-capped) body is present; CSS clamps it until expanded.
  if (i.body) {
    const expanded = expandedIssueURLs.has(i.url);
    card.appendChild(el('div', 'card-desc' + (expanded ? ' expanded' : ''), i.body));
    if (i.body.length > 140) {
      const toggle = el('button', 'card-desc-toggle', expanded ? 'Show less' : 'Show more');
      toggle.onclick = (e) => {
        e.stopPropagation();
        if (expanded) expandedIssueURLs.delete(i.url); else expandedIssueURLs.add(i.url);
        renderBoard();
      };
      card.appendChild(toggle);
    }
  }

  if (i.labels && i.labels.length) card.appendChild(labelPills(i.labels));
  const foot = el('div', 'card-foot');
  const statusPill = el('span', 'status-pill', i.project_status);
  statusPill.style.color = sc;
  statusPill.style.borderColor = sc;
  foot.appendChild(statusPill);
  // #751: inline PR state + CI checks (present only when a PR is linked).
  if (i.pr_state) foot.appendChild(prStateBadge(i.pr_state));
  if (i.checks && i.checks.state) foot.appendChild(checksBadge(i.checks));

  // #751: right-aligned action cluster — View Issue / View PR always, plus the
  // existing Go to Session / Start Working affordance.
  const actions = el('div', 'card-actions');
  actions.appendChild(openLinkButton('View Issue', i.url));
  if (i.pr_url) actions.appendChild(openLinkButton('View PR', i.pr_url));
  if (i.linked_session_id) {
    if (i.linked_session_is_explore) {
      actions.appendChild(el('span', 'explore-badge', 'Exploring'));
    }
    const go = el('button', 'action-btn', 'Go to Session');
    go.onclick = () => selectSession(i.linked_session_id);
    actions.appendChild(go);
  } else if (!selecting) {
    actions.appendChild(startActionsSplit(
      'Start Working',
      (btn) => spawnAction(btn, 'work-on-issue', { url: i.url }, 'Start Working'),
      [
        { label: 'Start Working', title: 'Worktree + implement/build prompt',
          onClick: (btn) => spawnAction(btn, 'work-on-issue', { url: i.url }, 'Start Working') },
        { label: 'Start Exploring', title: 'Same setup, read/explain-only prompt — no edits, no PR',
          onClick: (btn) => spawnAction(btn, 'work-on-issue', { url: i.url, explore: true }, 'Start Exploring') },
      ]));
  }
  foot.appendChild(actions);
  card.appendChild(foot);
  return card;
}

// #751: an anchor styled as an action button that opens a URL in a new tab
// (same safe-href handling as linkChip). Falls back to a disabled-looking span
// for non-http(s) urls.
function openLinkButton(text, url) {
  const safe = /^https?:\/\//i.test(url || '');
  const a = document.createElement(safe ? 'a' : 'span');
  a.className = 'action-btn open-link-btn';
  if (safe) { a.href = url; a.target = '_blank'; a.rel = 'noopener'; }
  a.textContent = text;
  a.onclick = (e) => e.stopPropagation(); // don't toggle selection in select mode
  return a;
}

// #751: PR state badge — draft / open / merged / closed, colored to match.
function prStateBadge(state) {
  const map = {
    draft: ['Draft PR', 'var(--text-muted)'],
    open: ['PR Open', 'var(--blue)'],
    merged: ['PR Merged', 'var(--purple)'],
    closed: ['PR Closed', 'var(--red)'],
  };
  const [label, color] = map[state] || ['PR ' + state, 'var(--text-muted)'];
  const b = el('span', 'pr-state-badge', label);
  b.style.color = color;
  b.style.borderColor = color;
  return b;
}

// #751: CI checks rollup badge (pass/fail/pending), with failing check names in
// the tooltip. `checks` is { state, failed:[...] }.
function checksBadge(checks) {
  let label, color;
  switch (checks.state) {
    case 'SUCCESS': label = 'CI passing'; color = 'var(--green)'; break;
    case 'FAILURE':
    case 'ERROR': label = 'CI failing'; color = 'var(--red)'; break;
    case 'PENDING':
    case 'EXPECTED': label = 'CI pending'; color = 'var(--orange)'; break;
    default: label = 'CI ' + String(checks.state).toLowerCase(); color = 'var(--text-muted)';
  }
  const b = el('span', 'checks-badge', label);
  b.style.color = color;
  b.style.borderColor = color;
  const failed = checks.failed || [];
  if (failed.length) b.title = 'Failing: ' + failed.join(', ');
  return b;
}

function toggleIssueSelect(url) {
  if (selectedIssueIDs.has(url)) selectedIssueIDs.delete(url);
  else selectedIssueIDs.add(url);
  renderBoard();
}

// Batch "Start Working (N)" / "Start Exploring (N)": ONE batch-work-on-issues
// call with every selected ticket. Explore mode passes `explore: true` so the
// Manager runs `/crow-batch-workspace --explore …` (CROW-1149). Then clear
// selection and exit selection mode.
async function startSelected(btn, explore) {
  const urls = ((boardData.tickets && boardData.tickets.issues) || [])
    .filter((i) => !i.linked_session_id && selectedIssueIDs.has(i.url))
    .map((i) => i.url);
  if (!urls.length) return;
  const { buttons } = startActionHost(btn);
  buttons.forEach((b) => { b.disabled = true; });
  btn.textContent = 'Starting…';
  const label = explore ? 'Start Exploring' : 'Start Working';
  let problem = '';
  try {
    const params = { urls };
    if (explore) params.explore = true;
    const res = await rpc('batch-work-on-issues', params);
    const rejected = (res && res.rejected) || [];
    if (rejected.length) problem = rejected.length + ' ticket(s) could not be started.';
  } catch (e) {
    problem = label + ' failed: ' + (e.message || e);
  }
  selectedIssueIDs.clear();
  ticketSelectionMode = false;
  refreshTickets();
  renderBoard();
  if (problem) alertModal(problem);
}

