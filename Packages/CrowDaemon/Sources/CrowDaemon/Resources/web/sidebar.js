'use strict';
// Crow web UI — Shared client state, sidebar grouping/select, PR glyphs, session menus. Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let sessions = [];
// False until the first successful list-sessions RPC. While false and sessions
// are empty, the sidebar paints skeleton placeholders instead of "No sessions"
// (CROW-613). A localStorage cache can populate `sessions` before that RPC.
let sessionsLoaded = false;
let selectedId = null;
let terminals = [];
let activeTerminal = null; // { id, name, window }
// Live per-session state (remote-control + PR) from list-sessions-live, keyed
// by session id. Runtime-only — empty when the desktop app isn't running.
let liveById = {};

// Boards (Ticket Board / Reviews / Allowlist), mirroring the desktop's
// full-pane boards. Served by `crowd` off its own IssueTracker/AllowListService
// (CROW-581 M-C), so they populate whether or not the desktop app is running.
let selectedBoard = null; // 'tickets' | 'reviews' | 'allowlist' | 'scorecard' | 'grid' | null
const boardData = { tickets: null, reviews: null, allowlist: null, scorecard: null };

// Session grid (CROW-1153): an ordered per-browser pin list. Pinned ids lead
// the wall; remaining slots auto-fill with active/in-review sessions. Caps at
// 16 cells per page so a cell stays large enough to read.
const GRID_PAGE_SIZE = 16;
// CROW-1162: 16 xterm paints on an 800 ms cadence contended with the live
// session's fit/reflow. 1500 ms is still a watch wall, just not a main-thread
// storm; the first paint on enter is still immediate (`refreshGridSnapshots`).
const GRID_POLL_MS = 1500;
const GRID_PINS_KEY = 'crow.grid.pins';
let gridPinnedIds = [];
let gridPage = 0;
// True while the open session view was reached by clicking a grid cell
// (CROW-1163). Escape / the ‹ Grid header control return to `#/grid` only
// then — a session opened from the sidebar, a ticket, or a deep link must not
// steal Escape from the agent. Memory-only: a reload of `#/sessions/…` is not
// "from the grid".
let sessionCameFromGrid = false;
let gridPollTimer = null;
let gridTeardownGen = 0;
let gridTeardownTimer = null;
const gridTerms = new Map(); // sessionId → { term, host, lastSnap, cols, rows }

// Last-known sidebar layout (sessions + ticket/review badge counts) so first
// paint isn't blank while /rpc connects (CROW-613).
const SIDEBAR_CACHE_KEY = 'crow.sidebar.cache';
// True when boot restored a cache entry (including an empty sessions list) —
// distinguishes "remembered empty" from a cold start that should show skeletons.
let sidebarCacheHit = false;
function clearSidebarCache() {
  try { localStorage.removeItem(SIDEBAR_CACHE_KEY); } catch (_) {}
  sidebarCacheHit = false;
}
// Drop EVERY localStorage payload that could leak one user's workspace to the
// next on a shared/kiosk browser, at the two auth boundaries (explicit logout,
// cookie death). The notification history holds the same class of data as the
// sidebar cache — session names, server-supplied PR/issue titles and bodies,
// issue URLs — so it has to be purged alongside it (review, CROW-909). One
// helper so a future cached store can't be wired into one auth path and missed
// on the other. NOT called from the boot-catch recovery, which only wants to
// discard a *corrupt* sidebar cache, not a valid history.
function purgeSharedBrowserCaches() {
  clearSidebarCache();
  notifHistory = [];
  try { localStorage.removeItem(NOTIF_HISTORY_KEY); } catch (_) {}
  try { localStorage.removeItem(GRID_PINS_KEY); } catch (_) {}
  gridPinnedIds = [];
}
function restoreSidebarCache() {
  try {
    const raw = localStorage.getItem(SIDEBAR_CACHE_KEY);
    if (!raw) return;
    const data = JSON.parse(raw);
    if (Array.isArray(data.sessions)) sessions = data.sessions;
    if (data.tickets) boardData.tickets = data.tickets;
    if (data.reviews) boardData.reviews = data.reviews;
    // `loading` is runtime-only and never survives a reload meaningfully: a
    // cache written mid-fetch would otherwise boot showing a spinner that only
    // a successful `list-tickets` could clear. Also scrubs legacy caches
    // written before `persistSidebarCache` started stripping it (CROW-771).
    if (boardData.tickets) boardData.tickets.loading = false;
    sidebarCacheHit = true;
  } catch (_) { /* corrupt cache — start empty */ }
}
function persistSidebarCache() {
  try {
    localStorage.setItem(SIDEBAR_CACHE_KEY, JSON.stringify({
      sessions,
      // Strip the runtime-only in-flight flag — a cache written mid-fetch must
      // not resurrect a spinner on the next boot (CROW-771).
      tickets: boardData.tickets && Object.assign({}, boardData.tickets, { loading: false }),
      reviews: boardData.reviews,
    }));
    sidebarCacheHit = true;
  } catch (_) { /* quota / private mode */ }
}
let ticketFilter = 'Backlog'; // pipeline segment ('All' or a status rawValue); default to Backlog so the Tickets view opens on the intake queue (CROW-795). 'All' stays a selectable tab.
let allowlistHideGlobal = false;
let allowlistFilter = ''; // #701: case-insensitive substring filter on entry pattern
let ticketSearch = ''; // #714: case-insensitive substring on ticket text, composed with ticketFilter
let reviewSearch = ''; // #714: case-insensitive substring across review text
const allowlistSelection = new Set();
// Session multi-select (#5): toggled by the sidebar checkmark button; holds the
// ids of sessions ticked for a bulk action (delete).
let selectionMode = false;
const selectedSessionIDs = new Set();
// Ticket-board multi-select (CROW-660): mirrors the native TicketBoardView
// multi-select. Toggled by the board's Select button; holds the urls of tickets
// ticked for the batch "Start Working (N)" action.
let ticketSelectionMode = false;
const selectedIssueIDs = new Set();
// Review-board multi-select (CROW-865): the same pattern, restoring the retired
// ReviewBoardView's batch kickoff. Holds the urls of pending reviews ticked for
// the batch "Start Review (N)" action.
let reviewSelectionMode = false;
const selectedReviewURLs = new Set();
// CROW-751 board controls (session-only, like ticketFilter/ticketSearch above).
let ticketRepoFilter = 'All';     // repo selector; 'All' or a repo slug ("org/repo")
let ticketSort = 'updated_desc';  // one of TICKET_SORT_OPTIONS keys
const expandedIssueURLs = new Set(); // urls whose description excerpt is expanded
// Sort control options (value → label). Replaces the old hardcoded updated-desc.
const TICKET_SORT_OPTIONS = [
  ['updated_desc', 'Updated (newest)'],
  ['updated_asc', 'Updated (oldest)'],
  ['created_desc', 'Created (newest)'],
  ['created_asc', 'Created (oldest)'],
  ['title_asc', 'Title (A–Z)'],
  ['status', 'Status'],
];
const PIPELINE = ['All', 'Backlog', 'Ready', 'In Progress', 'In Review', 'Done'];
// Ticket pipeline status → accent color, keyed by CrowCore TicketStatus.rawValue.
// Paired with TICKET_STATUS_ICON below as the single source of truth for the pipeline
// headings and the sidebar counts, so a category's icon + color can't drift between the
// two (web reland of #732; the SwiftUI TicketStatus.color extension is gone on this branch).
const TICKET_STATUS_COLOR = {
  'Backlog': 'var(--text-muted)',
  'Ready': 'var(--blue)',
  'In Progress': 'var(--orange)',
  'In Review': 'var(--purple)',
  'Done': 'var(--green)',
  'Unknown': 'var(--text-muted)',
};
// Ticket pipeline status → glyph name in ICONS (the SF-symbol equivalents #734 used).
// Same keys as TICKET_STATUS_COLOR, so the pair stays in lockstep.
const TICKET_STATUS_ICON = {
  'Backlog': 'tray',
  'Ready': 'flag',
  'In Progress': 'bolt',
  'In Review': 'eye',
  'Done': 'checkCircle',
  'Unknown': 'help',
};

const STATUS_COLOR = {
  active: 'var(--green)', paused: 'var(--yellow)',
  inReview: 'var(--gold)', completed: 'var(--gold)', archived: 'var(--text-muted)',
};
const AGENT_GLYPH = { 'claude-code': '✦', cursor: '▲', codex: '◆', 'open-code': '◇', opencode: '◇', grok: '⚡', antigravity: '↑', muse: '✶' };

// Sidebar session groups (Managers now live in the nav pill row, not a group).
const GROUPS = [
  { title: 'Jobs', match: (s) => s.status === 'active' && s.kind === 'job' },
  { title: 'Active', match: (s) => s.status === 'active' && s.kind === 'work' },
  { title: 'Reviews', match: (s) => s.kind === 'review' && s.status !== 'completed' && s.status !== 'archived' },
  { title: 'In Review', match: (s) => s.status === 'inReview' && s.kind !== 'manager' },
  { title: 'Completed', match: (s) => (s.status === 'completed' || s.status === 'archived') && s.kind !== 'manager' },
];

// Assign sessions to sidebar sections without the duplicate rows that used to
// render for one PR (CROW-877):
//   1. dedup by session id — a payload that repeats an id renders once;
//   2. first-match grouping — each session lands in the FIRST group it matches,
//      not every one, so a `kind:'review'` + `status:'inReview'` session can't
//      appear in both "Reviews" and "In Review";
//   3. collapse same-PR duplicates WITHIN a section, and only among
//      completed/archived rows — a merged PR (its completed work row + completed
//      review clone both land in "Completed") and any pile-up of identical
//      completed `review-<repo>-<pr>` clones become one row.
// Collapsing AFTER assignment, never across sections, is deliberate: a live work
// row in "Active"/"In Review" is never hidden by an open review clone in
// "Reviews", and a collapse survivor can never be a row that matches no group —
// the two failure modes of a pre-assignment collapse. Restricting collapse to
// TERMINAL rows is equally deliberate: two live sessions can legitimately share
// a PR within one section (e.g. a manual "Start Review" racing the auto-review
// clone lands two open reviews in "Reviews"), and hiding either would strand a
// running agent with no way to select or delete it (CROW-877 review).
// Managers carry no PR link and match no GROUP, so they drop out here and are
// rendered by renderSidebar's dedicated managers pass.
function isTerminal(s) {
  return s.status === 'completed' || s.status === 'archived';
}
// Collapse a PR's duplicate rows within one section, keeping one survivor.
// Returns { rows, collapsedIds }: the rows to render, plus the ids folded away
// so the section's select-all can still reach them (they'd otherwise be
// undeletable from the sidebar — CROW-877 review). Only terminal rows collapse,
// so a live session is never hidden. A pair collapses only when at least one
// side is a review CLONE — a merged PR's work row + its completed review clone,
// or a pile-up of completed clones. Two independent work/job sessions that
// happen to share a PR (a follow-up session, or a manual `add-link`) are NEVER
// folded; both render. A work row represents the PR over a review clone.
// Uses the shared `prUrlForSession` (hoisted; defined below) so "does this row
// have a PR" means one thing across the file.
function collapsePRDuplicates(rows) {
  const byPR = new Map();       // PR URL -> index into `out`
  const out = [];
  const collapsedIds = [];
  for (const s of rows) {
    const url = prUrlForSession(s);
    if (!url || !isTerminal(s)) { out.push(s); continue; }
    const idx = byPR.get(url);
    if (idx === undefined) { byPR.set(url, out.length); out.push(s); continue; }
    const prior = out[idx];
    if (prior.kind !== 'review' && s.kind !== 'review') { out.push(s); continue; }  // two non-clones: keep both
    if (prior.kind === 'review' && s.kind !== 'review') {                            // work supersedes a clone
      collapsedIds.push(prior.id);
      out[idx] = s;
    } else {                                                                          // clone folds into the survivor
      collapsedIds.push(s.id);
    }
  }
  return { rows: out, collapsedIds };
}
function groupSessions(list) {
  const seenIds = new Set();
  const buckets = GROUPS.map((g) => ({ title: g.title, assigned: [] }));
  for (const s of list) {
    if (seenIds.has(s.id)) continue;
    seenIds.add(s.id);
    const gi = GROUPS.findIndex((g) => g.match(s));
    if (gi >= 0) buckets[gi].assigned.push(s);
  }
  const out = [];
  for (const b of buckets) {
    if (!b.assigned.length) continue;
    const { rows, collapsedIds } = collapsePRDuplicates(b.assigned);
    // `allIds` = rendered survivors + folded-away ids, so a section's "select
    // all" (and thus bulk-delete) still reaches the hidden collapsed rows.
    out.push({ title: b.title, rows, allIds: rows.map((r) => r.id).concat(collapsedIds) });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------
async function refreshSessions() {
  try {
    const res = await rpc('list-sessions');
    const next = res.sessions || [];
    const changed = JSON.stringify(sessions) !== JSON.stringify(next);
    sessions = next;
    sessionsLoaded = true;
    if (changed) persistSidebarCache();
    detectSessionSounds();
    // A deep link held back until the id could actually be judged (CROW-936).
    if (pendingRoute) {
      const route = pendingRoute;
      pendingRoute = null;
      // Detached from the enclosing try: we're past its catch by now, so a
      // rejection here would surface as an unhandled one rather than being
      // swallowed the way the "transient — next poll retries" intent expects.
      applyRoute(route).catch(() => {});
      return; // applyRoute re-renders via selectSession / showSessionNotFound
    }
    // The retention reaper deletes completed sessions out from under us. Without
    // this the open session just goes blank: renderHeader(undefined) returns
    // early, leaving an empty header, an orphan "+" tab and a frozen terminal.
    if (selectedId && !sessions.some((s) => s.id === selectedId)) {
      showSessionNotFound(selectedId);
      return; // showEmptyDetail renders the sidebar itself
    }
    renderSidebar();
    if (changed && selectedBoard === 'grid') renderBoard();
  } catch (_) { /* transient — next poll retries */ }
}

// Batched live per-session state (remote-control + PR). Merged into the sidebar
// rows + detail header; empty when the desktop app isn't running.
async function refreshLive() {
  try {
    const res = await rpc('list-sessions-live');
    liveById = res.sessions || {};
  } catch (_) { return; }
  detectSessionSounds();
  renderSidebar();
  if (selectedId) {
    const s = sessions.find((x) => x.id === selectedId);
    if (s) renderHeader(s);
  }
  if (selectedBoard === 'grid') updateGridCellHeaders();
}

function liveFor(id) { return liveById[id] || {}; }

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

// Signature of everything the sidebar renders — used to skip rebuilds when the
// poll returns identical data (avoids the repaint/layout jump).
let lastSidebarSig = null;
function sidebarSignature() {
  return JSON.stringify([
    sessionsLoaded, sidebarCacheHit, sessions, liveById, selectedId, selectedBoard,
    selectionMode, [...selectedSessionIDs],
    uiConfig.hideSessionDetails,
    gridPinnedIds,
    boardData.tickets && boardData.tickets.counts,
    boardData.tickets && boardData.tickets.done_last_24h,
    boardData.reviews && boardData.reviews.unseen,
    // The bell's unread badge (CROW-909) — not store-backed, so name it here so
    // an appended notification actually repaints the badge.
    notifUnreadCount(),
    // The ↻ spins off this, and the local half isn't in `boardData` (CROW-771).
    ticketsRefreshing(),
  ]);
}

function renderSidebar() {
  const sig = sidebarSignature();
  if (sig === lastSidebarSig) return; // nothing changed — don't repaint
  lastSidebarSig = sig;
  const root = document.getElementById('sidebar');
  root.innerHTML = '';

  // Brandmark (the desktop's CorveilBrandmark, served at /brand.svg).
  const brand = document.createElement('img');
  brand.id = 'brand-img';
  brand.src = '/brand.svg';
  brand.alt = 'Crow';
  root.appendChild(brand);

  // Two-column sidebar top (CROW-917): a left stack [tickets → Reviews/Allowlist/
  // Scorecard → Manager] over a far-right column of four stacked icon buttons
  // [bell, gear, +, select], grouped and centered in the column (CROW-922).
  const top = el('div', 'sidebar-top');
  top.appendChild(sidebarLeftStack());
  top.appendChild(sidebarIconColumn());
  root.appendChild(top);
  if (selectionMode) root.appendChild(bulkActionBar());

  // Cold start only: structured skeleton rows so the left pane isn't blank
  // while list-sessions is in flight. A cached empty workspace keeps the
  // remembered "No sessions" state instead of shimmering (CROW-613).
  if (!sessionsLoaded && !sessions.length && !sidebarCacheHit) {
    root.appendChild(el('div', 'divider', 'Active'));
    for (let i = 0; i < 4; i++) root.appendChild(skeletonRow(i));
    return;
  }

  // Extra (non-primary) manager sessions render as rows, no section header.
  const managers = sessions.filter((s) => s.kind === 'manager');
  for (const m of managers.slice(1)) root.appendChild(sessionRow(m));

  let shown = 0;
  for (const { title, rows, allIds } of groupSessions(sessions)) {
    root.appendChild(selectionMode ? sectionHeader(title, allIds) : el('div', 'divider', title));
    for (const s of rows) { root.appendChild(sessionRow(s)); shown++; }
  }
  if ((sessionsLoaded || sidebarCacheHit) && !shown && !managers.length) {
    root.appendChild(el('div', 'empty', 'No sessions'));
  }
}

// Placeholder session card matching .session-row geometry so real rows swap in
// without a full re-layout jump (CROW-613).
function skeletonRow(i) {
  const row = el('div', 'session-row skeleton-row');
  row.setAttribute('aria-hidden', 'true');
  // Stagger the shimmer so the column doesn't pulse in lockstep.
  row.style.setProperty('--skel-delay', ((i % 4) * 0.12) + 's');
  const top = el('div', 'row-top');
  top.appendChild(el('span', 'skel skel-agent'));
  top.appendChild(el('span', 'skel skel-name'));
  top.appendChild(el('span', 'skel skel-dot'));
  row.appendChild(top);
  if (!uiConfig.hideSessionDetails) {
    row.appendChild(el('div', 'skel skel-subtle'));
    row.appendChild(el('div', 'skel skel-meta'));
  }
  return row;
}

// ---- Multi-select (#5 / CROW-593) ----------------------------------------

function toggleSelect(id) {
  if (selectedSessionIDs.has(id)) selectedSessionIDs.delete(id);
  else selectedSessionIDs.add(id);
  renderSidebar();
}

// Section divider with a per-section select-all/clear toggle (mirrors the
// desktop section header checklist button). `ids` is the section's full id set
// (survivors + PR-collapsed rows), so "select all" reaches the hidden rows too.
function sectionHeader(title, ids) {
  const head = el('div', 'divider divider-sel');
  head.appendChild(el('span', 'divider-label', title));
  const allSel = ids.length && ids.every((id) => selectedSessionIDs.has(id));
  const btn = el('button', 'divider-selall', allSel ? 'Clear' : 'All');
  btn.title = allSel ? 'Deselect all in section' : 'Select all in section';
  btn.onclick = (e) => {
    e.stopPropagation();
    if (allSel) ids.forEach((id) => selectedSessionIDs.delete(id));
    else ids.forEach((id) => selectedSessionIDs.add(id));
    renderSidebar();
  };
  head.appendChild(btn);
  return head;
}

// "N selected" + cancel + bulk-delete, mirroring the desktop bulkActionBar.
function bulkActionBar() {
  const bar = el('div', 'bulk-bar');
  bar.appendChild(el('span', 'bulk-count', selectedSessionIDs.size + ' selected'));
  bar.appendChild(el('div', 'bulk-spacer'));
  const cancel = el('button', 'bulk-x', '✕');
  cancel.title = 'Cancel selection';
  cancel.onclick = () => { selectionMode = false; selectedSessionIDs.clear(); renderSidebar(); };
  bar.appendChild(cancel);
  if (selectedSessionIDs.size) {
    const del = el('button', 'bulk-delete');
    del.appendChild(icon('trash', 12));
    del.appendChild(el('span', null, '(' + selectedSessionIDs.size + ')'));
    del.title = 'Delete selected sessions';
    del.onclick = () => bulkDeleteSelected();
    bar.appendChild(del);
  }
  return bar;
}

async function bulkDeleteSelected() {
  const ids = [...selectedSessionIDs];
  if (!ids.length) return;
  if (!await confirmModal('Delete ' + ids.length + ' session' + (ids.length === 1 ? '' : 's')
    + '? This removes their worktrees and terminals.', { okLabel: 'Delete', danger: true })) return;
  let failed = 0;
  for (const id of ids) {
    try {
      await rpc('delete-session', { session_id: id });
      sessions = sessions.filter((x) => x.id !== id);
      selectedSessionIDs.delete(id);
    } catch (_) { failed++; }
  }
  if (selectedId && !sessions.some((x) => x.id === selectedId)) {
    // `replace` for the same reason as deleteSession — nothing to go back to.
    navigate({ view: 'home' }, { replace: true });
    showHome();
  }
  selectionMode = false;
  renderSidebar();
  if (failed) alertModal(failed + ' session(s) could not be deleted.');
}

// Tickets summary card: title + refresh + 5 status mini-counts. Click opens the
// Ticket Board (TicketBoardSidebarRow).
function ticketsCard() {
  const card = el('div', 'tickets-card' + (selectedBoard === 'tickets' ? ' selected' : ''));
  card.onclick = () => selectBoard('tickets');
  const head = el('div', 'tickets-head');
  head.appendChild(el('span', 'tickets-title', 'Tickets'));
  const busy = ticketsRefreshing();
  // While refreshing, swap the ↻ glyph for the shared `.action-spinner` ring so
  // the spinner turns inside a stationary button, not the button itself (CROW-797).
  const refresh = el('button', 'tickets-refresh' + (busy ? ' spinning' : ''), busy ? '' : '↻');
  if (busy) refresh.appendChild(el('span', 'action-spinner'));
  refresh.title = busy ? 'Refreshing tickets…' : 'Refresh tickets';
  refresh.disabled = busy;
  refresh.onclick = (e) => { e.stopPropagation(); refreshTickets(); };
  head.appendChild(refresh);
  card.appendChild(head);

  const counts = (boardData.tickets && boardData.tickets.counts) || {};
  const done = (boardData.tickets && boardData.tickets.done_last_24h) || 0;
  // [label, count, statusKey] — color + icon derive from the shared TICKET_STATUS_*
  // maps keyed by statusKey, so the sidebar counts can't drift from the pipeline
  // headings (web reland of #732). Done shows the last-24h count under its own label.
  const mini = [
    ['Backlog', counts.Backlog || 0, 'Backlog'],
    ['Ready', counts.Ready || 0, 'Ready'],
    ['In Progress', counts['In Progress'] || 0, 'In Progress'],
    ['In Review', counts['In Review'] || 0, 'In Review'],
    ['Done · 24h', done, 'Done'],
  ];
  const row = el('div', 'tickets-counts');
  for (const [label, n, statusKey] of mini) {
    const cell = el('span', 'tk-count');
    cell.title = label;
    cell.style.color = TICKET_STATUS_COLOR[statusKey] || 'var(--text-muted)';
    cell.appendChild(icon(TICKET_STATUS_ICON[statusKey], 12));
    cell.appendChild(el('span', 'tk-n', String(n)));
    row.appendChild(cell);
  }
  card.appendChild(row);
  return card;
}

// Whether this is a signed-in *remote* web session: a web password is set and
// we're reached via a non-loopback host — i.e. through the https proxy, which
// required a login. Localhost is always trusted without a session, so no logout
// affordance is shown there (CROW-593).
function signedInOverWeb() {
  const h = (location.hostname || '').toLowerCase();
  const loopback = h === 'localhost' || h === '::1' || h === '' || h.startsWith('127.');
  return uiConfig.webPasswordSet && !loopback;
}

// Whether the current web-session cookie is invalid. Only meaningful for a remote
// (non-loopback) session with a web password — loopback is always authorized, so it
// returns false there. Probes /auth/check, which the auth middleware answers 204 when
// authorized and 401 when not. Returns true ONLY on a definitive 401: a thrown fetch
// means crowd is down (not an auth failure), so we keep reconnecting (CROW-593).
async function sessionExpired() {
  if (!signedInOverWeb()) return false;
  try {
    const res = await fetch('/auth/check', { cache: 'no-store', headers: { Accept: 'application/json' } });
    return res.status === 401;
  } catch (_) {
    return false;
  }
}

let authProbeInFlight = false;
// On a /rpc disconnect, check once whether the session cookie is still valid; if it's
// gone, mark the session dead so the status bar shows "Log in" and reconnects stop.
async function handleAuthOnDisconnect() {
  if (sessionDead || authProbeInFlight) return;
  authProbeInFlight = true;
  try {
    if (await sessionExpired()) {
      sessionDead = true;
      // Parity with explicit logout: drop cached session/ticket payloads AND the
      // notification history when the remote web cookie dies (crowd restart) so
      // they don't linger in a shared browser (CROW-613 review / CROW-909).
      purgeSharedBrowserCaches();
      renderStatusBar();
    }
  } finally {
    authProbeInFlight = false;
  }
}

// Bottom-left status bar: a connection light (the /rpc socket state) plus — on a
// signed-in remote session only — a logout button. Rebuilt on connect/disconnect
// and after config loads (CROW-593).
function renderStatusBar() {
  const bar = document.getElementById('statusbar');
  if (!bar) return;
  bar.classList.toggle('connected', wsConnected && !sessionDead);
  bar.classList.toggle('disconnected', !wsConnected && !sessionDead);
  bar.classList.toggle('session-expired', sessionDead);
  // Full-app scrim (#679): block interaction with #app once the session is
  // definitively dead. Keyed on sessionDead only — never on a transient
  // !wsConnected reconnect ("Connecting…"), which self-heals.
  const scrim = document.getElementById('session-scrim');
  if (scrim) scrim.hidden = !sessionDead;
  const label = bar.querySelector('.conn-label');
  if (label) label.textContent = sessionDead ? 'Session expired' : (wsConnected ? 'Connected' : 'Connecting…');
  const actions = document.getElementById('statusbar-actions');
  if (!actions) return;
  actions.textContent = '';
  // Session died (a crowd restart wiped the cookie's token): offer an explicit login
  // instead of looping on "Connecting…" (CROW-593).
  if (sessionDead) {
    const login = el('button', 'sb-login', 'Log in');
    login.type = 'button';
    login.title = 'Your web session expired — log in again';
    // Carry the current view across the login hop (CROW-936) — login.html
    // hands the fragment back once the password is accepted.
    login.onclick = () => { location.href = '/login' + (location.hash || ''); };
    actions.appendChild(login);
    return;
  }
  if (signedInOverWeb()) {
    const out = el('button', 'sb-logout');
    out.type = 'button';
    out.title = 'Log out';
    out.appendChild(icon('logout', 15));
    out.onclick = async () => {
      if (!await confirmModal('Log out of this web session? You’ll need the web password to sign back in.', { title: 'Log out', okLabel: 'Log out' })) return;
      try { await fetch('/logout', { method: 'POST' }); } catch (_) {}
      // Drop cached session/ticket payloads AND the notification history so a
      // shared browser can't read them after logout of a password-protected
      // remote session (CROW-613 review / CROW-909).
      purgeSharedBrowserCaches();
      location.reload();  // now unauthenticated → the auth gate serves the login page
    };
    actions.appendChild(out);
  }
}

// Far-right sidebar column (CROW-917): the four global icon buttons stacked
// vertically — Notifications bell, Settings gear, "+" new-manager, and the
// Select-sessions toggle. Fixed-size and centered as a block in the column
// (CROW-922), not stretched to divide its height.
function sidebarIconColumn() {
  const col = el('div', 'sidebar-right');
  // Notification center (CROW-909): bell + unread badge, first so it's the most
  // prominent global affordance. Visible in every view (sessions and boards).
  const bell = el('button', 'tk-tool tk-bell');
  const unread = notifUnreadCount();
  bell.title = unread ? unread + ' unread notification' + (unread === 1 ? '' : 's') : 'Notifications';
  bell.setAttribute('aria-label', bell.title);
  bell.appendChild(icon('bell', 14));
  if (unread) bell.appendChild(el('span', 'notif-badge', unread > 99 ? '99+' : String(unread)));
  bell.onclick = () => openNotificationPanel(bell);
  col.appendChild(bell);

  const gear = el('button', 'tk-tool');
  gear.title = 'Settings';
  gear.setAttribute('aria-label', 'Settings');
  gear.appendChild(icon('wrench', 14));
  gear.onclick = () => { if (window.openSettings) window.openSettings(); };
  col.appendChild(gear);

  const plus = el('button', 'nav-plus', '+');
  plus.title = 'New Manager session';
  plus.setAttribute('aria-label', 'New Manager session');
  plus.onclick = () => openNewManagerMenu(plus);
  col.appendChild(plus);

  // Select-sessions toggle (CROW-913 → moved into this column, CROW-917): toggles
  // selectionMode, clears the selection on cancel, reads red (.nav-selecting) active.
  const sel = el('button', 'nav-select' + (selectionMode ? ' nav-selecting' : ''));
  sel.title = selectionMode ? 'Cancel selection' : 'Select sessions';
  sel.setAttribute('aria-label', sel.title);
  sel.appendChild(icon(selectionMode ? 'close' : 'checkSquare', 14));
  sel.onclick = () => { selectionMode = !selectionMode; if (!selectionMode) selectedSessionIDs.clear(); renderSidebar(); };
  col.appendChild(sel);

  return col;
}

// Left sidebar-top stack (CROW-917): the Tickets card over two nav-pill rows —
// row 1 Grid · Reviews · Allowlist · Scorecard, row 2 the full-width Manager pill.
function sidebarLeftStack() {
  const wrap = el('div', 'sidebar-left');
  wrap.appendChild(ticketsCard());

  // Row 1: Grid · Reviews · Allowlist · Scorecard (each its own non-wrapping flex line).
  const row1 = el('div', 'nav-pills-row');
  row1.appendChild(navPill('Grid', selectedBoard === 'grid', () => selectBoard('grid')));
  const rev = navPill('Reviews', selectedBoard === 'reviews', () => selectBoard('reviews'));
  const unseen = (boardData.reviews && boardData.reviews.unseen) || 0;
  if (unseen) rev.appendChild(el('span', 'pill-badge', String(unseen)));
  row1.appendChild(rev);
  row1.appendChild(navPill('Allowlist', selectedBoard === 'allowlist', () => selectBoard('allowlist')));
  row1.appendChild(navPill('Scorecard', selectedBoard === 'scorecard', () => selectBoard('scorecard')));
  wrap.appendChild(row1);

  // Row 2: the primary Manager pill, spanning the full left-column width. Only
  // appended when a primary manager exists — an empty .nav-pills-row still consumes
  // a flex-gap slot, so appending one would leave a stray 6px gap below row 1. (The
  // right icon column no longer divides the left column's height — its buttons are a
  // fixed-size centered stack since CROW-922 — so a Manager-less render can't shrink
  // them below the WCAG floor.)
  const primaryManager = sessions.find((s) => s.kind === 'manager');
  if (primaryManager) {
    const row2 = el('div', 'nav-pills-row');
    const mgr = navPill('Manager', selectedId === primaryManager.id, () => selectSession(primaryManager.id));
    const ind = activityIndicator(primaryManager);
    const dot = el('span', 'pill-dot' + (ind.pulse ? ' pulse' : ''));
    dot.style.background = ind.color;
    mgr.insertBefore(dot, mgr.firstChild);
    if (liveFor(primaryManager.id).remote_control_active) mgr.appendChild(rcGlyph());
    row2.appendChild(mgr);
    wrap.appendChild(row2);
  }

  return wrap;
}

function navPill(label, active, onClick) {
  const p = el('div', 'nav-pill' + (active ? ' active' : ''));
  p.appendChild(el('span', 'pill-label', label));
  p.onclick = onClick;
  return p;
}

// Gold antenna glyph = this session's agent was launched with remote control
// enabled, so it's driveable from claude.ai. (The underlying flag tracks
// terminals started with `--rc`, i.e. RC-enabled — not a live claude.ai drive,
// so the badge means "enabled", not "currently being driven" — CROW-863.)
function rcGlyph() {
  const span = el('span', 'rc-glyph');
  span.title = 'Remote control enabled — driveable from claude.ai';
  span.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 8a8 8 0 0 0 0 8M8 10.5a4 4 0 0 0 0 3M19 8a8 8 0 0 1 0 8M16 10.5a4 4 0 0 1 0 3"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/></svg>';
  return span;
}

async function createManager(agentKind) {
  try { await rpc('create-manager', agentKind ? { agent_kind: agentKind } : undefined); }
  catch (e) { alertModal('New manager failed: ' + (e.message || e)); }
}

// Help copy for an agent whose binary wasn't found on the daemon's PATH at
// boot. Shared by the new-manager menu and the Settings agent selectors so the
// "why is this disabled" hint reads identically (#879). Availability is a
// boot-time snapshot, hence "restart Crow".
function agentUnavailableHint(a) {
  const bin = a.binary ? ' (' + a.binary + ')' : '';
  return (a.name || a.kind) + bin + ' not found on PATH — install it and restart Crow to enable.';
}

// New-manager "+" button: fetch the known agents and, when more than one is
// known, pop a context menu to pick which to launch (mirrors the desktop
// AgentRegistry menu). Off-PATH agents are listed but disabled (greyed, with a
// help tooltip) so a shipped-but-uninstalled harness is discoverable rather than
// invisible (#879) — that discoverability is the point, so the menu shows the
// full roster even when only one agent is actually installed. The instant-create
// path only kicks in when the daemon is down (0 agents) or somehow reports a
// single known agent.
async function openNewManagerMenu(anchorEl) {
  let agents = [];
  try { const r = await rpc('list-agents'); agents = (r && r.agents) || []; } catch (_) { /* app down */ }
  if (agents.length < 2) { createManager(agents[0] && agents[0].kind); return; }
  closeContextMenu();
  const menu = el('div', 'ctx-menu');
  for (const a of agents) {
    const enabled = a.available !== false;
    const label = (a.name || a.kind) + (a.default ? '   (default)' : '') + (enabled ? '' : '   (not installed)');
    const item = el('div', 'ctx-item' + (enabled ? '' : ' disabled'), label);
    if (enabled) {
      item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); createManager(a.kind); };
    } else {
      item.title = agentUnavailableHint(a);
      // Swallow the click so a disabled row never launches (and never closes
      // the menu), keeping it as info-only.
      item.onclick = (ev) => { ev.stopPropagation(); };
    }
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const rect = anchorEl.getBoundingClientRect();
  const x = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Notification center panel (CROW-909): an anchored popover mirroring
// openNewManagerMenu — reuses the .ctx-menu shell (so closeContextMenu closes
// it) with a .notif-panel modifier for the wider, scrollable, two-line layout.
// Opening marks every entry seen (clears the unread badge). Clicking a row
// navigates to its origin; a "Clear all" empties the history.
function openNotificationPanel(anchorEl) {
  // Toggle: a second click on the bell dismisses the open panel.
  if (document.querySelector('.notif-panel')) { closeContextMenu(); return; }
  closeContextMenu();

  // Measure the anchor BEFORE the seen-marking repaint below: renderSidebar
  // rebuilds the tools stack from scratch (root.innerHTML = ''), detaching this
  // very `bell`. A detached node has no layout box, so a later
  // getBoundingClientRect() would read all-zeros and the panel would clamp to
  // the viewport corner instead of under the bell (review).
  const rect = anchorEl.getBoundingClientRect();

  // Opening is "reading" — mark all seen and drop the unread badge. Re-read
  // first so a concurrent tab's newer entries aren't clobbered by writing back
  // our stale in-memory copy (review).
  if (notifUnreadCount()) {
    restoreNotifHistory();
    for (const e of notifHistory) e.seen = true;
    persistNotifHistory();
    renderSidebar();
  }

  const menu = el('div', 'ctx-menu notif-panel');
  const header = el('div', 'notif-header');
  header.appendChild(el('span', 'notif-title', 'Notifications'));
  if (notifHistory.length) {
    const clear = el('button', 'notif-clear', 'Clear all');
    clear.onclick = (ev) => {
      ev.stopPropagation();
      notifHistory = [];
      persistNotifHistory();
      closeContextMenu();
      renderSidebar();
    };
    header.appendChild(clear);
  }
  menu.appendChild(header);

  if (!notifHistory.length) {
    menu.appendChild(el('div', 'notif-empty', 'No notifications yet'));
  } else {
    const list = el('div', 'notif-list');
    // Newest first.
    for (let i = notifHistory.length - 1; i >= 0; i--) {
      const entry = notifHistory[i];
      const navigable = entry.kind === 'session' || entry.kind === 'review' || entry.kind === 'url';
      const item = el('div', 'notif-item' + (navigable ? '' : ' notif-static'));
      const line1 = el('div', 'notif-row1');
      line1.appendChild(el('span', 'notif-item-title', entry.title || EVENT_LABEL[entry.event] || entry.event));
      line1.appendChild(el('span', 'notif-time', notifRelTime(entry.ts)));
      item.appendChild(line1);
      if (entry.body) item.appendChild(el('div', 'notif-item-body', entry.body));
      if (navigable) {
        item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); navigateToNotification(entry); };
      } else {
        item.onclick = (ev) => ev.stopPropagation();
      }
      list.appendChild(item);
    }
    menu.appendChild(list);
  }

  document.body.appendChild(menu);
  const x = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Sidebar status/activity indicator, mirroring the desktop: for active
// sessions the dot is driven by hook activity (working / needs-attention /
// done); otherwise by session status.
// Small inline-SVG icons (monochrome, inherit currentColor so they take each
// button's/cell's color) — the web analog of the desktop's SF Symbols.
const ICONS = {
  eye: '<path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8Z"/><circle cx="8" cy="8" r="1.8"/>',
  check: '<path d="M3 8.5l3.2 3.2L13 4.5"/>',
  uturn: '<path d="M6.5 11H9.5a3 3 0 0 0 0-6H4"/><path d="M6 3 3.5 5.5 6 8"/>',
  trash: '<path d="M3 4.5h10"/><path d="M6.5 4.5V3h3v1.5"/><path d="M4.8 4.5l.6 8.5h5.2l.6-8.5"/>',
  merge: '<circle cx="5" cy="3.5" r="1.4"/><circle cx="5" cy="12.5" r="1.4"/><circle cx="11" cy="5.5" r="1.4"/><path d="M5 5v7"/><path d="M11 7a4 4 0 0 1-4 4H5"/>',
  tag: '<path d="M2.5 4H9L13.5 8 9 12H2.5z"/><circle cx="5" cy="8" r="1"/>',
  clock: '<circle cx="8" cy="8" r="5.5"/><path d="M8 5v3.2l2 1.3"/>',
  pencil: '<path d="M10.5 3 13 5.5l-7 7H3.5V10z"/>',
  warning: '<path d="M8 2.5l6 11H2z"/><path d="M8 6.5v3.2"/><path d="M8 11.6v.2"/>',
  tray: '<path d="M2.5 4.5h11v7h-11z"/><path d="M2.5 9h3l1 1.5h3L13.5 9"/>',
  flag: '<path d="M4 2.5v11"/><path d="M4 3.5h7.5L9.8 6 11.5 8.5H4"/>',
  bolt: '<path d="M9 2 3.5 9H7l-1 5 6.5-7.5H8.5z"/>',
  checkCircle: '<circle cx="8" cy="8" r="5.8"/><path d="M5.6 8.2 7.3 9.9 10.6 6.2"/>',
  checkSquare: '<rect x="2.5" y="2.5" width="11" height="11" rx="2"/><path d="M5.5 8.2 7.2 9.9 10.6 6"/>',
  close: '<path d="M4 4l8 8M12 4l-8 8"/>',
  wrench: '<path d="M11.8 2.4a2.8 2.8 0 0 0-3.3 3.7L2.9 11.7a1.3 1.3 0 0 0 1.8 1.8l5.6-5.6a2.8 2.8 0 0 0 3.7-3.3l-1.9 1.9-1.6-.4-.4-1.6z"/>',
  logout: '<path d="M6.5 3.5H3.5v9h3"/><path d="M12.5 8H6.5"/><path d="M10 5.5 12.5 8 10 10.5"/>',
  help: '<circle cx="8" cy="8" r="5.8"/><path d="M6.3 6.5a1.7 1.7 0 1 1 2.4 1.6c-.5.3-.7.6-.7 1.1v.3"/><path d="M8 11.3v.15"/>',
  code: '<path d="M6 5 2.5 8 6 11"/><path d="M10 5l3.5 3-3.5 3"/>',
  terminal: '<rect x="2" y="3" width="12" height="10" rx="1.5"/><path d="M4.5 6.5 6.5 8l-2 1.5"/><path d="M8 9.5h3"/>',
  comment: '<path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z"/>',
  bell: '<path d="M4.5 7a3.5 3.5 0 0 1 7 0c0 3 1 4 1.5 4.5H3C3.5 11 4.5 10 4.5 7Z"/><path d="M6.6 13a1.6 1.6 0 0 0 2.8 0"/>',
  pin: '<path d="M8 2.2c.7 0 1.3.3 1.7.8.4.5.5 1.1.4 1.7-.2 1.1-1.1 2.1-2.1 3.6v3.2M8 2.2c-.7 0-1.3.3-1.7.8-.4.5-.5 1.1-.4 1.7.2 1.1 1.1 2.1 2.1 3.6"/><path d="M5.4 6.4h5.2"/>',
  grid: '<rect x="2.5" y="2.5" width="4.6" height="4.6" rx=".8"/><rect x="8.9" y="2.5" width="4.6" height="4.6" rx=".8"/><rect x="2.5" y="8.9" width="4.6" height="4.6" rx=".8"/><rect x="8.9" y="8.9" width="4.6" height="4.6" rx=".8"/>',
};
function icon(name, size) {
  const span = el('span', 'ico');
  const s = size || 13;
  span.innerHTML = '<svg width="' + s + '" height="' + s + '" viewBox="0 0 16 16" fill="none" '
    + 'stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">'
    + (ICONS[name] || '') + '</svg>';
  return span;
}

function activityIndicator(s) {
  if (s.status !== 'active') {
    return { color: STATUS_COLOR[s.status] || 'var(--text-muted)' };
  }
  if (s.attention) {
    return { color: 'var(--orange)', pulse: true, label: s.attention === 'question' ? 'Question' : 'Permission' };
  }
  switch (s.activity) {
    case 'working': return { color: 'var(--green)', pulse: true, label: 'Working' };
    case 'waiting': return { color: 'var(--orange)', pulse: true, label: 'Waiting' };
    case 'done': return { color: 'var(--gold)', label: 'Done' };
    default: return { color: 'var(--green)' };
  }
}

function sessionRow(s) {
  const multiSel = selectionMode && selectedSessionIDs.has(s.id);
  const row = el('div', 'session-row status-accent'
    + (!selectionMode && s.id === selectedId ? ' selected' : '')
    + (selectionMode ? ' selecting' : '')
    + (multiSel ? ' multi-selected' : ''));
  row.onclick = selectionMode ? (() => toggleSelect(s.id)) : (() => selectSession(s.id));
  row.oncontextmenu = (e) => showSessionMenu(e, s);
  // Touch devices have no right-click: a long-press opens the same menu at the
  // finger, the standard mobile equivalent (rename/delete were unreachable on
  // mobile otherwise — CROW-593).
  attachLongPress(row, (x, y) => {
    if (selectionMode) return;
    showSessionMenu({ preventDefault() {}, clientX: x, clientY: y }, s);
  });
  const ind = activityIndicator(s);
  // Left accent hue: amber for attention (permission/question), green for done,
  // neutral otherwise (mirrors the desktop rowBackgroundColor logic).
  row.style.borderLeftColor = s.attention ? 'var(--orange)'
    : (s.activity === 'done' ? 'var(--green)' : 'var(--border-subtle)');
  // Full-card background tint by state, matching the desktop rowBackgroundColor
  // (orange tint on attention, green tint when done). Left unset when the row is
  // selected (single or multi) so the gold selected background wins (CROW-593).
  if (!multiSel && !(s.id === selectedId && !selectionMode)) {
    row.style.background = s.attention ? 'rgba(230,145,50,0.14)'
      : (s.activity === 'done' ? 'var(--bg-done)' : '');
  }

  // In multi-select mode a checkbox leads the row; the rest of the content is
  // wrapped so the checkbox sits left of the stacked body (#5 / CROW-593).
  let content = row;
  if (selectionMode) {
    const cb = el('input', 'row-check');
    cb.type = 'checkbox';
    cb.checked = multiSel;
    cb.onclick = (e) => { e.stopPropagation(); toggleSelect(s.id); };
    row.appendChild(cb);
    content = el('div', 'row-body');
    row.appendChild(content);
  }

  const top = el('div', 'row-top');
  const lead = el('div', 'row-lead');
  lead.appendChild(el('span', 'agent', AGENT_GLYPH[s.agent_kind] || '•'));
  lead.appendChild(el('span', 'name', s.name));
  if (liveFor(s.id).remote_control_active) lead.appendChild(rcGlyph());
  top.appendChild(lead);

  const trail = el('div', 'row-trail');
  if (isGridPinned(s.id)) {
    const pinMark = icon('pin', 11);
    pinMark.classList.add('row-pin');
    pinMark.title = 'Pinned to the session grid';
    trail.appendChild(pinMark);
  }
  if (s.locked) trail.appendChild(el('span', 'lock', '🔒'));
  // The auto-merge ⛙ used to live here, untinted and structurally divorced from
  // the PR pill. It now lives IN the pill (see prAutoMergeGlyph), where a color
  // can distinguish "armed" from "Crow gave up" — two ⛙ marks on one row
  // meaning different things would be worse than the bug (#888, CROW-773).
  // Trailing glowing status dot.
  const dot = el('span', 'dot glow' + (ind.pulse ? ' pulse' : ''));
  dot.style.background = ind.color;
  dot.style.color = ind.color; // drives the glow ring (box-shadow: currentColor)
  trail.appendChild(dot);
  top.appendChild(trail);
  content.appendChild(top);

  if (!uiConfig.hideSessionDetails) {
    if (s.ticket_title) content.appendChild(el('div', 'subtle', s.ticket_title));
    if (s.repo) content.appendChild(el('div', 'meta', s.repo + (s.branch ? ' · ' + s.branch : '')));
    // Ticket/review label pills — native `SessionRow` showed these below the
    // repo line, capped at 2, behind the same hideSessionDetails gate (CROW-773).
    if (s.labels && s.labels.length) content.appendChild(labelPills(s.labels, 2));
  }

  const badges = el('div', 'row-badges');
  // Ticket pill — purple once the linked issue is closed, mirroring the
  // merged-PR pill so the row shows issue state at a glance (#792).
  if (s.ticket_badge) {
    const tb = el('span', 'badge', s.ticket_badge);
    if (s.ticket_state === 'closed') {
      tb.classList.add('badge-closed');
      tb.title = 'Issue closed';
      tb.setAttribute('aria-label', s.ticket_badge + ', issue closed');
    }
    badges.appendChild(tb);
  }
  if (s.is_explore) {
    const exp = el('span', 'explore-badge', 'Exploring');
    exp.title = 'Exploration session — read/explain only, no build';
    badges.appendChild(exp);
  }
  // Light org-goal indicator (#723) — glyph only to keep the card compact; the
  // full goal text lives in the tooltip and the detail header.
  if (s.org_goal) {
    const g = el('span', 'badge goal-badge', '🎯');
    g.title = 'Goal: ' + s.org_goal;
    badges.appendChild(g);
  }
  // PR badge — shown whenever a PR link exists (stored, or live from the app
  // when it's only in memory); colored AND glyphed by live status when
  // available. The glyphs mirror the retired native `PRBadge` (CROW-773): a
  // color-only pill can't distinguish failing checks from changes-requested.
  const prLink = (s.links || []).find((l) => l.type === 'pr') || liveFor(s.id).pr_link;
  if (prLink) {
    const pr = liveFor(s.id).pr;
    const color = prBadgeColor(pr);
    const prb = el('span', 'pr-badge', prLink.label || 'PR');
    prb.style.color = color;
    prb.style.borderColor = color;
    const parts = prBadgeParts(pr, liveFor(s.id).auto_merge_state, s.auto_merge,
                               liveFor(s.id).auto_rebase_state);
    for (const part of parts) {
      const ico = part.icon ? icon(part.icon, 10) : el('span', 'pr-ico', part.glyph);
      ico.style.color = part.color;
      prb.appendChild(ico);
    }
    // Glyph + color must not be the only channel — mirrors native PRBadge's
    // `accessibilityDescription` ("#123, Checks pass, Approved").
    const desc = [prLink.label || 'PR', ...parts.map((p) => p.a11yLabel || p.label)].join(', ');
    // The auto-merge part carries a whole sentence — too long for the comma
    // list, but it IS the answer to "why is nothing happening?", so it gets its
    // own tooltip line and rides the aria-label rather than being sighted-only.
    const detail = parts.map((p) => p.detail).filter(Boolean).join(' ');
    prb.title = detail ? desc + '\n' + detail : desc;
    prb.setAttribute('aria-label', detail ? desc + '. ' + detail : desc);
    badges.appendChild(prb);
  }
  // Activity badge (Working/Waiting/Done/…) is redundant on managers — they
  // already show the trailing status dot, and the badge forces a second line.
  if (ind.label && s.kind !== 'manager') {
    const activity = el('span', 'activity-badge', ind.label);
    activity.style.color = ind.color;
    badges.appendChild(activity);
  }
  if (badges.children.length) content.appendChild(badges);

  // Visible actions affordance (tap = same menu as right-click / long-press).
  // The row reserves a right gutter (.session-row padding-right) so this sits in
  // the bottom-right corner clear of the status dot, incl. single-line manager
  // cards. Omitted in multi-select mode, where the checkbox is the action.
  if (!selectionMode) {
    const kebab = el('button', 'row-kebab', '⋮');
    kebab.type = 'button';
    kebab.title = 'Actions';
    kebab.setAttribute('aria-label', 'Session actions');
    kebab.onclick = (e) => {
      e.stopPropagation();
      const r = kebab.getBoundingClientRect();
      showSessionMenu({ preventDefault() {}, clientX: r.right, clientY: r.bottom }, s);
    };
    row.appendChild(kebab);
  }
  return row;
}

function prBadgeColor(pr) {
  if (!pr || !pr.has_pr) return 'var(--gold)';
  if (pr.is_merged) return 'var(--purple)';
  if (pr.has_blockers) return 'var(--red)';
  if (pr.ready_to_merge) return 'var(--green)';
  return 'var(--gold)';
}

// ---------------------------------------------------------------------------
// PR status glyphs — ONE vocabulary shared by the sidebar row pill
// (`sessionRow`) and the detail header (`prStatusInline`), so the two can never
// disagree about the same PR (CROW-773).
// ---------------------------------------------------------------------------
// `icon` names an entry in ICONS: those glyphs render as monochrome SVGs that
// inherit `currentColor`, so the checkmarks tint with their label instead of
// staying black (Apple emoji ✔/✕/⚠ ignore CSS `color` — CROW-802). The
// in-progress states (checks running / needs review) and the crow:merge tag
// carry an `icon:` too, so they render as crisp SVGs at the same size as the
// check/X instead of the thin unicode ◷ / an emoji 🏷 (CROW-863). Only the
// "none/unknown" geometric glyphs (○/?) stay text — they're already
// color-faithful and read fine faint.
// `label` is the chip text in the detail header AND the sidebar pill's
// aria-label/title; an optional `a11yLabel` overrides the latter when the
// concise chip text would be ambiguous without its (unannounced) glyph
// (CROW-846). Add it only where the two channels must diverge.
const PR_CHECKS_GLYPH = {
  passing: { glyph: '✔', icon: 'check', color: 'var(--green)', label: 'Checks pass' },
  failing: { glyph: '✕', icon: 'close', color: 'var(--red)', label: 'Checks failing' },
  pending: { glyph: '◷', icon: 'clock', color: 'var(--orange)', label: 'Checks running' },
  unknown: { glyph: '?', color: 'var(--text-muted)', label: 'No checks' },
};
const PR_REVIEW_GLYPH = {
  approved: { glyph: '✔', icon: 'check', color: 'var(--green)', label: 'Approved' },
  changesRequested: { glyph: '✕', icon: 'close', color: 'var(--red)', label: 'Changes requested' },
  reviewRequired: { glyph: '◷', icon: 'eye', color: 'var(--orange)', label: 'Needs review' },
  unknown: { glyph: '○', color: 'var(--text-muted)', label: 'No reviews' },
};
const PR_MERGED_GLYPH = { glyph: '✔', icon: 'check', color: 'var(--purple)', label: 'Merged' };
const PR_CONFLICT_GLYPH = { glyph: '⚠', icon: 'warning', color: 'var(--red)', label: 'Conflicts' };
// Chip text drops the redundant "label" (the tag glyph shows it beside the
// text); the aria path keeps it via `a11yLabel` — there the glyph is never
// announced, so the noun is the only signal it's a label (CROW-846).
const PR_MERGE_LABEL_GLYPH = { glyph: '🏷', icon: 'tag', color: 'var(--gold)', label: 'crow:merge', a11yLabel: 'crow:merge label' };
// Auto-merge lifecycle — one FAMILY (the ⛙ merge mark), five COLORS for the
// five outcomes. Before #888 the row drew the same untinted ⛙ whether Crow was
// about to merge the PR or had permanently given up on it, so "armed" and
// "dead" were indistinguishable. Here the mark says "this is about auto-merge"
// and the color says which way it went.
// `detail` is the daemon's full sentence: too long for the chip, so it rides
// the tooltip/aria channel only — the same chip-vs-a11y split as
// PR_MERGE_LABEL_GLYPH (CROW-846).
const PR_AUTOMERGE_GLYPH = {
  enabled: { glyph: '⛙', icon: 'merge', color: 'var(--green)', label: 'Auto-merge on', a11yLabel: 'Auto-merge enabled' },
  merged: { glyph: '⛙', icon: 'merge', color: 'var(--purple)', label: 'Merged by Crow', a11yLabel: 'Merged by Crow' },
  stalled: { glyph: '⛙', icon: 'merge', color: 'var(--orange)', label: 'Auto-merge waiting', a11yLabel: 'Auto-merge waiting to retry' },
  blocked: { glyph: '⛙', icon: 'merge', color: 'var(--red)', label: 'Auto-merge blocked', a11yLabel: 'Auto-merge blocked' },
  off: { glyph: '⛙', icon: 'merge', color: 'var(--text-muted)', label: 'Auto-merge off', a11yLabel: 'Auto-merge watcher is off' },
};

// The auto-merge part for one row, or null when there's nothing to say.
// `am` is the live `auto_merge_state` object (absent on pre-#888 daemons);
// `enabled` is the persisted `session.auto_merge` bool, which is ALL an older
// daemon sends — so it stays the fallback rather than the primary source.
function prAutoMergeGlyph(am, enabled) {
  const base = am && am.phase && PR_AUTOMERGE_GLYPH[am.phase];
  if (base) return am.message ? Object.assign({}, base, { detail: am.message }) : base;
  return enabled ? PR_AUTOMERGE_GLYPH.enabled : null;
}

// Auto-rebase lifecycle (#944) — the ⟲ U-turn mark, two colors. Distinct from
// the ⛙ auto-merge family by ICON, not tint: color is the severity scale and
// both watchers share it, while the mark says which one is speaking.
//
// The reason this exists at all: `prStatusJSON` never ships `mergeStateStatus`,
// so a PR that is BEHIND its base renders as a fully green pill. Before #944 a
// worktree wedged in `out-of-sync-diverged` backed off forever with no surface
// but crowd-automation.log.
//
// No `enabled`/`off` phase on purpose — no PR opts into auto-rebase the way
// `crow:merge` opts into auto-merge, so silence is the default and a chip only
// ever means "Crow tried and couldn't".
const PR_AUTOREBASE_GLYPH = {
  stalled: { glyph: '⟲', icon: 'uturn', color: 'var(--orange)', label: 'Rebase waiting', a11yLabel: 'Auto-rebase waiting to retry' },
  blocked: { glyph: '⟲', icon: 'uturn', color: 'var(--red)', label: 'Rebase stuck', a11yLabel: 'Auto-rebase stuck — needs you' },
};

// The auto-rebase part for one row, or null when there's nothing to say. No
// persisted-bool fallback twin of `prAutoMergeGlyph`'s `session.auto_merge`:
// there is no per-PR auto-rebase opt-in, and an older daemon simply sends no key.
function prAutoRebaseGlyph(ar) {
  const base = ar && ar.phase && PR_AUTOREBASE_GLYPH[ar.phase];
  if (!base) return null;
  return ar.message ? Object.assign({}, base, { detail: ar.message }) : base;
}

function prChecksGlyph(pr) {
  const base = PR_CHECKS_GLYPH[pr.checks] || PR_CHECKS_GLYPH.unknown;
  // Failing checks carry their count when the daemon sent the names.
  if (pr.checks === 'failing' && pr.failed_checks && pr.failed_checks.length) {
    return { ...base, label: pr.failed_checks.length + ' failing' };
  }
  return base;
}

function prReviewGlyph(pr) {
  return PR_REVIEW_GLYPH[pr.review] || PR_REVIEW_GLYPH.unknown;
}

// The ordered glyphs for a session-row PR pill, mirroring native `PRBadge`:
// merged collapses to a single check, otherwise checks + review, plus the
// conflict and crow:merge-label markers the native pill folded into its tint,
// then what Crow's watchers did about it. The two watcher parts go LAST so the
// pill reads left-to-right as "state of the PR, then what Crow did about it",
// with auto-rebase before auto-merge because that is the order the work
// happens in — a branch gets current, then it merges. A merged PR
// short-circuits both, because their state is history.
function prBadgeParts(pr, am, autoMergeEnabled, ar) {
  if (!pr || !pr.has_pr) return [];
  if (pr.is_merged) return [PR_MERGED_GLYPH];
  const parts = [prChecksGlyph(pr), prReviewGlyph(pr)];
  if (pr.merge === 'conflicting') parts.push(PR_CONFLICT_GLYPH);
  if (pr.has_merge_label) parts.push(PR_MERGE_LABEL_GLYPH);
  const rebase = prAutoRebaseGlyph(ar);
  if (rebase) parts.push(rebase);
  const auto = prAutoMergeGlyph(am, autoMergeEnabled);
  if (auto) parts.push(auto);
  return parts;
}

// ---------------------------------------------------------------------------
// Session right-click context menu (custom — suppresses the browser default).
// ---------------------------------------------------------------------------
// The outside-click closer, held module-level so closeContextMenu can remove it.
// Registered NOT as { once: true } on purpose: a click *inside* a menu that
// stopPropagations (a notification row, "Clear all") never reaches document, so
// a once-listener would stay armed with no menu on screen — and the next
// menu-open's own click would then bubble to it and tear the fresh menu straight
// back down. Tying the listener's lifetime to closeContextMenu instead of to
// "some outside click eventually happens" fixes that for all six menu sites
// (review, CROW-909).
let _ctxMenuCloser = null;
function closeContextMenu() {
  const m = document.querySelector('.ctx-menu');
  if (m) m.remove();
  if (_ctxMenuCloser) {
    document.removeEventListener('click', _ctxMenuCloser);
    _ctxMenuCloser = null;
  }
}
// Arm the outside-click close one tick out (so the opening click itself doesn't
// immediately close the menu). Shared by every menu opener; the deferred arm
// also means a listener still pending from a prior menu fires against an empty
// document before this one registers.
function armContextMenuClose() {
  setTimeout(() => {
    _ctxMenuCloser = closeContextMenu;
    document.addEventListener('click', _ctxMenuCloser);
  }, 0);
}

// Right-click a board card → a small menu to copy its link(s). Pass an array of
// { label, url }; entries with no url are dropped. Reuses ctx-menu styling,
// positioned at the cursor like showSessionMenu.
function showCardMenu(e, items) {
  e.preventDefault();
  closeContextMenu();
  const links = (items || []).filter((it) => it && it.url);
  if (!links.length) return;
  const menu = el('div', 'ctx-menu');
  for (const it of links) {
    const item = el('div', 'ctx-item', it.label);
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); copyToClipboard(it.url); };
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Clipboard with a legacy fallback (execCommand) for non-secure contexts where
// navigator.clipboard is unavailable.
function copyToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
  } else {
    fallbackCopy(text);
  }
}
function fallbackCopy(text) {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch (_) { /* best effort */ }
  document.body.removeChild(ta);
}

function showSessionMenu(e, s) {
  e.preventDefault();
  closeContextMenu();
  const menu = el('div', 'ctx-menu');
  for (const it of sessionMenuItems(s)) {
    if (it.sep) { menu.appendChild(el('div', 'ctx-sep')); continue; }
    const item = el('div', 'ctx-item' + (it.danger ? ' ctx-danger' : ''), it.label);
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); it.action(); };
    menu.appendChild(item);
  }
  if (!menu.childElementCount) return; // nothing actionable for this session
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Long-press → context-menu bridge for touch devices. Fires `handler(x, y)` at
// the touch point after ~500ms if the finger hasn't moved (a scroll/drag past a
// small threshold cancels it), then swallows the trailing click so the row
// isn't also selected. Desktop right-click keeps its own oncontextmenu path.
function attachLongPress(node, handler) {
  let timer = null, sx = 0, sy = 0, fired = false;
  const clear = () => { if (timer) { clearTimeout(timer); timer = null; } };
  node.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) { clear(); return; }
    fired = false;
    sx = e.touches[0].clientX;
    sy = e.touches[0].clientY;
    clear();
    timer = setTimeout(() => { fired = true; timer = null; handler(sx, sy); }, 500);
  }, { passive: true });
  node.addEventListener('touchmove', (e) => {
    if (!timer) return;
    const t = e.touches[0];
    if (Math.abs(t.clientX - sx) > 10 || Math.abs(t.clientY - sy) > 10) clear();
  }, { passive: true });
  node.addEventListener('touchend', (e) => {
    clear();
    if (fired) { e.preventDefault(); fired = false; } // swallow the emulated click
  });
  node.addEventListener('touchcancel', clear, { passive: true });
}

// The PR URL for a session, from its stored links or the live PR surface.
function prUrlForSession(s) {
  const link = (s.links || []).find((l) => l.type === 'pr');
  if (link && link.url) return link.url;
  const live = liveFor(s.id).pr_link;
  return live && live.url ? live.url : null;
}

// Menu items mirror the desktop sessionContextMenu, gated by kind/status/provider/PR.
function sessionMenuItems(s) {
  const items = [];
  const prUrl = prUrlForSession(s);
  // Copy-link items first — available for any session with an issue and/or PR.
  if (s.ticket_url) items.push({ label: 'Copy issue link', action: () => copyToClipboard(s.ticket_url) });
  if (prUrl) items.push({ label: 'Copy PR link', action: () => copyToClipboard(prUrl) });
  items.push({
    label: isGridPinned(s.id) ? 'Unpin from grid' : 'Pin to grid',
    action: () => toggleGridPin(s.id),
  });
  if (s.ticket_url || prUrl) items.push({ sep: true });
  // Org-goal tagging (#723) — any non-manager session can ladder its work up to
  // an org KPI/goal. Managers are excluded from PR/issue tracking, so no goal.
  if (s.kind !== 'manager') {
    items.push({ label: s.org_goal ? 'Edit org goal…' : 'Set org goal…', action: () => setSessionGoal(s.id, s.org_goal) });
    if (s.org_goal) items.push({ label: 'Clear org goal', action: () => clearSessionGoal(s.id) });
    items.push({ sep: true });
  }
  const hasPR = (s.links || []).some((l) => l.type === 'pr');
  if (s.kind === 'manager') {
    // Maintenance actions (restart manager / reload tmux) live in Settings → About;
    // the manager row menu stays minimal: just rename and delete.
    items.push({ label: 'Rename', action: () => renameSession(s.id, s.name) });
    items.push({ sep: true });
    items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
    return items;
  }
  if (s.kind === 'review') {
    if (hasPR) items.push({ label: 'Add label crow:merge to PR', action: () => sessionAction('add-merge-label', s.id) });
    items.push({ label: 'Switch agent…', action: () => openHandoffAgentMenu(s, null) });
    items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
    return items;
  }
  if (s.status === 'active' && s.ticket_url && s.can_set_project_status) {
    items.push({ label: 'Mark as In Review', action: () => sessionAction('mark-in-review', s.id) });
  }
  if ((s.status === 'active' || s.status === 'inReview') && s.ticket_url) {
    const closes = s.provider === 'github' || s.provider === 'gitlab';
    items.push({ label: closes ? 'Close Issue' : 'Mark Issue Done', action: () => sessionAction('mark-issue-done', s.id) });
  }
  if (s.status === 'active' || s.status === 'inReview') {
    items.push({ label: 'Mark as Completed', action: () => sessionAction('complete-session', s.id) });
  }
  if (hasPR) items.push({ label: 'Add label crow:merge to PR', action: () => sessionAction('add-merge-label', s.id) });
  items.push({ label: s.locked ? 'Unlock' : 'Lock', action: () => sessionAction('set-locked', s.id, { locked: !s.locked }) });
  // Mid-session agent switch when credits run out (CROW-627).
  items.push({ label: 'Switch agent…', action: () => openHandoffAgentMenu(s, null) });
  items.push({ sep: true });
  items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
  return items;
}

async function handoffAgent(sessionId, agentKind) {
  try {
    await rpc('handoff-agent', { session_id: sessionId, agent_kind: agentKind });
    await refreshSessions();
    if (selectedId === sessionId) {
      renderHeader(sessions.find((x) => x.id === sessionId));
      await refreshTerminals();
    }
  } catch (e) {
    alertModal('Switch agent failed: ' + (e.message || e));
  }
}

// Pick a different coding agent for an existing work/job session (CROW-627).
// Reuses the list-agents menu pattern from openNewManagerMenu, including the
// #879 surface-but-disable treatment: off-PATH agents show as disabled rows
// (handing off to one only fails server-side with a raw internal error).
async function openHandoffAgentMenu(session, anchorEl) {
  let agents = [];
  try { const r = await rpc('list-agents'); agents = (r && r.agents) || []; } catch (_) { /* app down */ }
  const others = agents.filter((a) => a.kind && a.kind !== session.agent_kind);
  // Keep the honest empty-state: if no *other* agent is actually installed, say
  // so instead of listing rows that can only fail (#879). Off-PATH others don't
  // count as somewhere you can switch to.
  if (!others.some((a) => a.available !== false)) {
    alertModal('No other coding agents are available. Install Cursor, Codex, OpenCode, Grok Build, or Muse Code to switch.');
    return;
  }
  closeContextMenu();
  const menu = el('div', 'ctx-menu');
  for (const a of others) {
    const enabled = a.available !== false;
    const label = 'Hand off to ' + (a.name || a.kind) + (enabled ? '' : '   (not installed)');
    const item = el('div', 'ctx-item' + (enabled ? '' : ' disabled'), label);
    if (enabled) {
      item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); handoffAgent(session.id, a.kind); };
    } else {
      item.title = agentUnavailableHint(a);
      // Info-only: never launch a handoff that can only fail, never close the menu.
      item.onclick = (ev) => { ev.stopPropagation(); };
    }
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const rect = (anchorEl && anchorEl.getBoundingClientRect)
    ? anchorEl.getBoundingClientRect()
    : { left: 16, bottom: 80, top: 80 };
  const x = Math.min(rect.left || 16, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min((rect.bottom || 80) + 4, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Fire a session RPC from the row menu. A verb can succeed and still not have
// done the whole job: the RPC returns `ok:true` plus an additive `warning`
// (e.g. the crow:merge label landed but the auto-merge watcher is off). That's
// not an error — but staying quiet about it is exactly how #888 happened, so
// surface it. Read generically rather than per-verb: any of these verbs may
// grow a warning, and a special case for one is how the next one gets missed.
// Deliberately a modal and NOT quickAction's terminal line — `term` is the
// SELECTED session's surface while this runs from any row's context menu, so a
// terminal write would land in an unrelated session's scrollback.
async function sessionAction(method, id, extra) {
  // Identity for the advisory this call may raise. A fresh object per call, so a
  // late reply can only ever retract the modal *it* put up.
  const token = {};
  let advisoryUp = false;
  try {
    const res = await rpc(method, Object.assign({ session_id: id }, extra || {}), {
      // Fires only when the response beat us back after the deadline. The
      // advisory below promised this window would update; this is that update.
      onLate: (result, error) => {
        if (!advisoryUp) return;
        advisoryUp = false;
        if (error) {
          // We said "still running"; the daemon has now said it failed. The
          // truth changed — replace the advisory rather than stacking on it.
          dismissModalDialog(token);
          alertModal(method + ' failed: ' + (error.message || error));
          return;
        }
        const dismissed = dismissModalDialog(token);
        // An additive `warning` is information the user still needs even if they
        // already closed the advisory (that omission is #888), so it is shown
        // either way. A clean late success just takes the advisory down.
        const warning = result && typeof result.warning === 'string' ? result.warning : '';
        if (warning) alertModal(warning);
        else if (!dismissed) { /* user moved on and it worked — stay quiet */ }
      },
    });
    if (res && typeof res.warning === 'string' && res.warning) alertModal(res.warning);
  } catch (e) {
    if (e && e.rpcTimeout) {
      // NOT "failed": we stopped waiting, the daemon did not stop working.
      // Saying otherwise invites the user to retry an action that is already in
      // flight — which for `add-merge-label` or `complete-session` is a
      // duplicate write, and for all of them is a lie (#931).
      advisoryUp = true;
      alertModal(
        method + ' is taking longer than expected. It is still running on the daemon — '
        + 'this message will update when it finishes.',
        { title: 'Still running', token });
    } else {
      alertModal(method + ' failed: ' + (e.message || e));
    }
  }
}

// "In Review" with an in-flight spinner — mirrors native's ProgressView swap
// while `isMarkingInReview` (CROW-749). On success the status transition pushes
// a re-render that drops the button (status leaves `active`); on error we
// restore the button and surface the failure.
async function markInReviewAction(btn, id) {
  if (!btn || btn.disabled) return;
  btn.disabled = true;
  const saved = btn.innerHTML;
  btn.innerHTML = '';
  btn.appendChild(el('span', 'action-spinner'));
  try {
    const res = await rpc('mark-in-review', { session_id: id });
    // The session moved but the board didn't — e.g. GitLab, or a board with no
    // column mapping to In Review (#876). Not an error, but the button's name
    // promises a board move, so say so rather than looking like a clean success.
    if (res && typeof res.warning === 'string' && res.warning) alertModal(res.warning);
    // Leave the button disabled: the ensuing state push re-renders the header.
  } catch (e) {
    btn.disabled = false;
    btn.innerHTML = saved;
    alertModal('mark-in-review failed: ' + (e.message || e));
  }
}

// ---------------------------------------------------------------------------
// Detail + terminal tabs
// ---------------------------------------------------------------------------

// Drop any session/board selection and show #detail-empty carrying `msg`.
// One implementation behind three callers that used to open-code it: the
// router's home and not-found states, and the post-delete cleanup that
// deleteSession and bulkDeleteSelected each had their own near-identical copy of.
//
// Removing `has-selection` is what reveals #detail-empty and hides the terminal
// (`#app:not(.has-selection) #terminal-wrap { visibility: hidden }`, app.css) —
// no separate hiding logic needed.
function showEmptyDetail(msg, opts) {
  const o = opts || {};
  selectedId = null;
  selectedBoard = null;
  terminals = [];
  activeTerminal = null;
  // CROW-979: the ↻ that was spinning belonged to the session we just dropped, and
  // its `onopen` may never come (the socket is being torn down with it). Clearing
  // after `selectedId` is already null makes the repaint a no-op — the header is
  // emptied below regardless — but leaves no stale flag for the next selection.
  clearTerminalReloadPending();
  const app = document.getElementById('app');
  app.classList.remove('has-selection', 'board-active', 'mobile-show-sidebar');
  // On narrow screens `#app:not(.has-selection) #detail` is display:none, which
  // would hide the not-found message entirely — this class re-shows it.
  app.classList.toggle('route-missing', !!o.missing);
  document.getElementById('detail-header').innerHTML = '';
  document.getElementById('tabbar').innerHTML = '';
  document.getElementById('board').innerHTML = '';
  document.getElementById('board').classList.remove('session-grid-board');
  leaveGridView();

  const empty = document.getElementById('detail-empty');
  if (empty) {
    const label = empty.querySelector('.empty-msg');
    if (label) label.textContent = msg || 'Select a session';
    let sub = empty.querySelector('.empty-sub');
    if (o.detail) {
      if (!sub) { sub = el('div', 'empty-sub'); empty.appendChild(sub); }
      sub.textContent = o.detail;
    } else if (sub) { sub.remove(); }
    let back = empty.querySelector('.empty-back');
    if (o.missing) {
      if (!back) {
        back = el('button', 'empty-back', 'Back to sessions');
        back.type = 'button';
        // navigate() suppresses the hashchange for its own write, so drive the
        // view directly rather than waiting for a round-trip that won't come.
        back.onclick = () => { navigate({ view: 'home' }); showHome(); };
        empty.appendChild(back);
      }
    } else if (back) { back.remove(); }
  }
  renderSidebar();
}

function showHome() { showEmptyDetail('Select a session'); }

// A URL naming a session that isn't there. Crow's retention reaper deletes
// completed sessions (worktree and branch included), so a dead link is the
// normal case for any URL that's been sitting in a chat log — it gets a real
// message rather than the blank pane an unguarded selectedId used to leave.
//
// The id is echoed back only when it actually looks like one. It reaches here
// straight from the fragment, and this card is precisely what a *shared, stale*
// link lands on — the one place a reader is primed to believe an explanation. An
// unbounded echo let a crafted link render arbitrary prose inside Crow's own
// chrome (content spoofing, CWE-451) and, since `.empty-sub` caps width but not
// height, push the "Back to sessions" button — the card's only recovery
// affordance — off screen. Sessions are UUIDs, so requiring that shape costs
// nothing; anything else is simply not repeated, and is still visible in the
// address bar for diagnosis (review).
const SESSION_ID_SHAPE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function showSessionNotFound(id) {
  showEmptyDetail('Session not found', {
    missing: true,
    detail: 'It may have been deleted — Crow removes completed sessions automatically.'
      + (SESSION_ID_SHAPE.test(String(id || '')) ? ' (' + id + ')' : ''),
  });
}
