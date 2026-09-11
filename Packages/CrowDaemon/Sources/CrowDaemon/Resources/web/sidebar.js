'use strict';
// Crow web UI — Shared client state, sidebar grouping/select, refresh/render, ICONS.
// Extracted from app.js (CROW-1155); chrome / glyphs / rows / menus split out (CROW-1238).

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

// Boards (Ticket Board / Reviews), mirroring the desktop's full-pane boards.
// Served by `crowd` off its own IssueTracker (CROW-581 M-C), so they populate
// whether or not the desktop app is running.
let selectedBoard = null; // 'tickets' | 'reviews' | 'scorecard' | 'grid' | 'scratch' | null
const boardData = { tickets: null, reviews: null, scorecard: null, scratch: null };

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
let ticketSearch = ''; // #714: case-insensitive substring on ticket text, composed with ticketFilter
let reviewSearch = ''; // #714: case-insensitive substring across review text
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
    boardData.scratch && (boardData.scratch.todos || []).length,
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

  // Two-column sidebar top (CROW-917): a left stack [tickets → Reviews/Scorecard
  // → Manager] over a far-right column of four stacked icon buttons
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
