// Crow web UI (M2, CROW-581). A pure client: all state + actions go over the
// daemon's WebSockets — JSON-RPC at /rpc, terminal byte-stream at /terminal.
'use strict';

// ---------------------------------------------------------------------------
// JSON-RPC over a single persistent /rpc WebSocket, correlated by id.
// ---------------------------------------------------------------------------
const rpcState = { nextId: 1, pending: new Map(), ready: null };

function wsURL(path) {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  return proto + '://' + location.host + path;
}

function rpcConnect() {
  return new Promise((resolve) => {
    const ws = new WebSocket(wsURL('/rpc'));
    ws.onopen = () => resolve(ws);
    ws.onmessage = (event) => {
      let msg;
      try { msg = JSON.parse(event.data); } catch (_) { return; }
      // Server-initiated notification (no id): a state-change nudge from the
      // daemon — re-fetch the live surfaces now instead of waiting for the
      // interval poll (CROW-581, M-D).
      if (msg.id == null && msg.method === 'changed') { onServerChanged(); return; }
      const waiter = rpcState.pending.get(msg.id);
      if (!waiter) return;
      rpcState.pending.delete(msg.id);
      if (msg.error) waiter.reject(new Error(msg.error.message || 'rpc error'));
      else waiter.resolve(msg.result || {});
    };
    ws.onclose = () => { rpcState.ready = null; setTimeout(() => { rpcState.ready = rpcConnect(); }, 1000); };
    ws.onerror = () => ws.close();
  });
}

async function rpc(method, params) {
  if (!rpcState.ready) rpcState.ready = rpcConnect();
  const ws = await rpcState.ready;
  const id = rpcState.nextId++;
  return new Promise((resolve, reject) => {
    rpcState.pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params: params || {} }));
    setTimeout(() => { if (rpcState.pending.delete(id)) reject(new Error('rpc timeout: ' + method)); }, 10000);
  });
}

// The daemon pushes a `changed` notification when its state moves (a new/edited
// session, or a board poll). Re-fetch the live surfaces on the next tick;
// bursts coalesce into one refresh, and every fetch is diff-guarded so an
// unchanged payload repaints nothing (CROW-581, M-D). The interval polls below
// remain as a slow fallback (and cover runtime PR/RC, which isn't store-backed
// and so doesn't trigger a nudge).
let changedNudgeScheduled = false;
function onServerChanged() {
  if (changedNudgeScheduled) return;
  changedNudgeScheduled = true;
  setTimeout(() => {
    changedNudgeScheduled = false;
    refreshSessions();
    refreshLive();
    refreshBoard('tickets');
    refreshBoard('reviews');
    if (selectedId) refreshArtifacts(selectedId);
  }, 50);
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let sessions = [];
let selectedId = null;
let terminals = [];
let activeTerminal = null; // { id, name, window }
// Live per-session state (remote-control + PR) from list-sessions-live, keyed
// by session id. Runtime-only — empty when the desktop app isn't running.
let liveById = {};

// Boards (Ticket Board / Reviews / Allowlist), mirroring the desktop's
// full-pane boards. Data is forwarded to the desktop app, so it's empty when
// the app isn't running.
let selectedBoard = null; // 'tickets' | 'reviews' | 'allowlist' | null
const boardData = { tickets: null, reviews: null, allowlist: null };
let ticketFilter = 'All'; // pipeline segment ('All' or a status rawValue); default to All so the board isn't misread as empty when work moves to Done
let allowlistHideGlobal = false;
const allowlistSelection = new Set();
// Session multi-select (#5): toggled by the sidebar checkmark button; holds the
// ids of sessions ticked for a bulk action (delete).
let selectionMode = false;
const selectedSessionIDs = new Set();
const PIPELINE = ['All', 'Backlog', 'Ready', 'In Progress', 'In Review', 'Done'];
// Ticket pipeline status → accent color (mirrors CorveilTheme.TicketStatus.color).
const TICKET_STATUS_COLOR = {
  'Backlog': 'var(--text-muted)',
  'Ready': 'var(--blue)',
  'In Progress': 'var(--orange)',
  'In Review': 'var(--purple)',
  'Done': 'var(--green)',
  'Unknown': 'var(--text-muted)',
};

const STATUS_COLOR = {
  active: 'var(--green)', paused: 'var(--yellow)',
  inReview: 'var(--gold)', completed: 'var(--gold)', archived: 'var(--text-muted)',
};
const AGENT_GLYPH = { 'claude-code': '✦', cursor: '▲', codex: '◆', 'open-code': '◇', opencode: '◇' };

// Sidebar session groups (Managers now live in the nav pill row, not a group).
const GROUPS = [
  { title: 'Jobs', match: (s) => s.status === 'active' && s.kind === 'job' },
  { title: 'Active', match: (s) => s.status === 'active' && s.kind === 'work' },
  { title: 'Reviews', match: (s) => s.kind === 'review' && s.status !== 'completed' && s.status !== 'archived' },
  { title: 'In Review', match: (s) => s.status === 'inReview' && s.kind !== 'manager' },
  { title: 'Completed', match: (s) => (s.status === 'completed' || s.status === 'archived') && s.kind !== 'manager' },
];

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------
async function refreshSessions() {
  try {
    const res = await rpc('list-sessions');
    sessions = res.sessions || [];
    renderSidebar();
  } catch (_) { /* transient — next poll retries */ }
}

// Batched live per-session state (remote-control + PR). Merged into the sidebar
// rows + detail header; empty when the desktop app isn't running.
async function refreshLive() {
  try {
    const res = await rpc('list-sessions-live');
    liveById = res.sessions || {};
  } catch (_) { return; }
  renderSidebar();
  if (selectedId) {
    const s = sessions.find((x) => x.id === selectedId);
    if (s) renderHeader(s);
  }
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
    sessions, liveById, selectedId, selectedBoard,
    selectionMode, [...selectedSessionIDs],
    boardData.tickets && boardData.tickets.counts,
    boardData.tickets && boardData.tickets.done_last_24h,
    boardData.reviews && boardData.reviews.unseen,
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

  const trow = el('div', 'tickets-row');
  trow.appendChild(ticketsCard());
  trow.appendChild(sidebarToolsStack());
  root.appendChild(trow);
  root.appendChild(navPillRow());
  if (selectionMode) root.appendChild(bulkActionBar());

  // Extra (non-primary) manager sessions render as rows, no section header.
  const managers = sessions.filter((s) => s.kind === 'manager');
  for (const m of managers.slice(1)) root.appendChild(sessionRow(m));

  let shown = 0;
  for (const group of GROUPS) {
    const rows = sessions.filter(group.match);
    if (!rows.length) continue;
    root.appendChild(selectionMode ? sectionHeader(group.title, rows) : el('div', 'divider', group.title));
    for (const s of rows) { root.appendChild(sessionRow(s)); shown++; }
  }
  if (!shown && !managers.length) root.appendChild(el('div', 'empty', 'No sessions'));
}

// ---- Multi-select (#5 / CROW-593) ----------------------------------------

function toggleSelect(id) {
  if (selectedSessionIDs.has(id)) selectedSessionIDs.delete(id);
  else selectedSessionIDs.add(id);
  renderSidebar();
}

// Section divider with a per-section select-all/clear toggle (mirrors the
// desktop section header checklist button).
function sectionHeader(title, rows) {
  const head = el('div', 'divider divider-sel');
  head.appendChild(el('span', 'divider-label', title));
  const ids = rows.map((r) => r.id);
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
    const del = el('button', 'bulk-delete', '🗑 (' + selectedSessionIDs.size + ')');
    del.title = 'Delete selected sessions';
    del.onclick = () => bulkDeleteSelected();
    bar.appendChild(del);
  }
  return bar;
}

async function bulkDeleteSelected() {
  const ids = [...selectedSessionIDs];
  if (!ids.length) return;
  if (!window.confirm('Delete ' + ids.length + ' session' + (ids.length === 1 ? '' : 's')
    + '? This removes their worktrees and terminals.')) return;
  let failed = 0;
  for (const id of ids) {
    try {
      await rpc('delete-session', { session_id: id });
      sessions = sessions.filter((x) => x.id !== id);
      selectedSessionIDs.delete(id);
    } catch (_) { failed++; }
  }
  if (selectedId && !sessions.some((x) => x.id === selectedId)) {
    selectedId = null;
    const app = document.getElementById('app');
    app.classList.remove('has-selection', 'mobile-show-sidebar');
    document.getElementById('detail-header').innerHTML = '';
    document.getElementById('tabbar').innerHTML = '';
  }
  selectionMode = false;
  renderSidebar();
  if (failed) window.alert(failed + ' session(s) could not be deleted.');
}

// Tickets summary card: title + refresh + 5 status mini-counts. Click opens the
// Ticket Board (TicketBoardSidebarRow).
function ticketsCard() {
  const card = el('div', 'tickets-card' + (selectedBoard === 'tickets' ? ' selected' : ''));
  card.onclick = () => selectBoard('tickets');
  const head = el('div', 'tickets-head');
  head.appendChild(el('span', 'tickets-title', 'Tickets'));
  const refresh = el('button', 'tickets-refresh', '↻');
  refresh.title = 'Refresh tickets';
  refresh.onclick = (e) => { e.stopPropagation(); refreshTickets(); };
  head.appendChild(refresh);
  card.appendChild(head);

  const counts = (boardData.tickets && boardData.tickets.counts) || {};
  const done = (boardData.tickets && boardData.tickets.done_last_24h) || 0;
  const mini = [
    ['Backlog', counts.Backlog || 0, 'var(--text-muted)', 'tray'],
    ['Ready', counts.Ready || 0, 'var(--blue)', 'flag'],
    ['In Progress', counts['In Progress'] || 0, 'var(--orange)', 'bolt'],
    ['In Review', counts['In Review'] || 0, 'var(--purple)', 'eye'],
    ['Done · 24h', done, 'var(--green)', 'checkCircle'],
  ];
  const row = el('div', 'tickets-counts');
  for (const [label, n, color, ic] of mini) {
    const cell = el('span', 'tk-count');
    cell.title = label;
    cell.style.color = color;
    cell.appendChild(icon(ic, 12));
    cell.appendChild(el('span', 'tk-n', String(n)));
    row.appendChild(cell);
  }
  card.appendChild(row);
  return card;
}

// Settings + Select, stacked vertically to the right of the Tickets card
// (outside the box): Settings on top, Select below.
function sidebarToolsStack() {
  const stack = el('div', 'sidebar-tools');
  const gear = el('button', 'tk-tool');
  gear.title = 'Settings';
  gear.appendChild(icon('gear', 14));
  gear.onclick = () => { if (window.openSettings) window.openSettings(); };
  stack.appendChild(gear);
  const selBtn = el('button', 'tk-tool' + (selectionMode ? ' nav-selecting' : ''));
  selBtn.title = selectionMode ? 'Cancel selection' : 'Select sessions';
  selBtn.appendChild(icon(selectionMode ? 'close' : 'checkSquare', 14));
  selBtn.onclick = () => { selectionMode = !selectionMode; if (!selectionMode) selectedSessionIDs.clear(); renderSidebar(); };
  stack.appendChild(selBtn);
  return stack;
}

// Reviews / Allowlist / Manager pills + "+" (new manager).
function navPillRow() {
  const row = el('div', 'nav-pills');

  const rev = navPill('Reviews', selectedBoard === 'reviews', () => selectBoard('reviews'));
  const unseen = (boardData.reviews && boardData.reviews.unseen) || 0;
  if (unseen) rev.appendChild(el('span', 'pill-badge', String(unseen)));
  row.appendChild(rev);

  row.appendChild(navPill('Allowlist', selectedBoard === 'allowlist', () => selectBoard('allowlist')));

  const primaryManager = sessions.find((s) => s.kind === 'manager');
  if (primaryManager) {
    const mgr = navPill('Manager', selectedId === primaryManager.id, () => selectSession(primaryManager.id));
    const ind = activityIndicator(primaryManager);
    const dot = el('span', 'pill-dot' + (ind.pulse ? ' pulse' : ''));
    dot.style.background = ind.color;
    mgr.insertBefore(dot, mgr.firstChild);
    if (liveFor(primaryManager.id).remote_control_active) mgr.appendChild(rcGlyph());
    row.appendChild(mgr);
  }

  const plus = el('button', 'nav-plus', '+');
  plus.title = 'New Manager session';
  plus.onclick = () => openNewManagerMenu(plus);
  row.appendChild(plus);
  return row;
}

function navPill(label, active, onClick) {
  const p = el('div', 'nav-pill' + (active ? ' active' : ''));
  p.appendChild(el('span', 'pill-label', label));
  p.onclick = onClick;
  return p;
}

// Gold antenna glyph = remote-control active (driveable from claude.ai).
function rcGlyph() {
  const span = el('span', 'rc-glyph');
  span.title = 'Remote control active — driveable from claude.ai';
  span.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 8a8 8 0 0 0 0 8M8 10.5a4 4 0 0 0 0 3M19 8a8 8 0 0 1 0 8M16 10.5a4 4 0 0 1 0 3"/><circle cx="12" cy="12" r="1.4" fill="currentColor" stroke="none"/></svg>';
  return span;
}

async function createManager(agentKind) {
  try { await rpc('create-manager', agentKind ? { agent_kind: agentKind } : undefined); }
  catch (e) { window.alert('New manager failed: ' + (e.message || e)); }
}

// New-manager "+" button: fetch the available agents and, when there's more
// than one, pop a context menu to pick which agent to launch (mirrors the
// desktop AgentRegistry menu). With 0/1 agents, just create with the default.
async function openNewManagerMenu(anchorEl) {
  let agents = [];
  try { const r = await rpc('list-agents'); agents = (r && r.agents) || []; } catch (_) { /* app down */ }
  if (agents.length < 2) { createManager(agents[0] && agents[0].kind); return; }
  closeContextMenu();
  const menu = el('div', 'ctx-menu');
  for (const a of agents) {
    const item = el('div', 'ctx-item', (a.name || a.kind) + (a.default ? '   (default)' : ''));
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); createManager(a.kind); };
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const rect = anchorEl.getBoundingClientRect();
  const x = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  setTimeout(() => document.addEventListener('click', closeContextMenu, { once: true }), 0);
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
  pencil: '<path d="M10.5 3 13 5.5l-7 7H3.5V10z"/>',
  warning: '<path d="M8 2.5l6 11H2z"/><path d="M8 6.5v3.2"/><path d="M8 11.6v.2"/>',
  tray: '<path d="M2.5 4.5h11v7h-11z"/><path d="M2.5 9h3l1 1.5h3L13.5 9"/>',
  flag: '<path d="M4 2.5v11"/><path d="M4 3.5h7.5L9.8 6 11.5 8.5H4"/>',
  bolt: '<path d="M9 2 3.5 9H7l-1 5 6.5-7.5H8.5z"/>',
  checkCircle: '<circle cx="8" cy="8" r="5.8"/><path d="M5.6 8.2 7.3 9.9 10.6 6.2"/>',
  checkSquare: '<rect x="2.5" y="2.5" width="11" height="11" rx="2"/><path d="M5.5 8.2 7.2 9.9 10.6 6"/>',
  close: '<path d="M4 4l8 8M12 4l-8 8"/>',
  gear: '<circle cx="8" cy="8" r="2.1"/><path d="M8 1.6v2.1M8 12.3v2.1M1.6 8h2.1M12.3 8h2.1M3.5 3.5l1.5 1.5M11 11l1.5 1.5M12.5 3.5 11 5M5 11l-1.5 1.5"/>',
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
  if (s.locked) trail.appendChild(el('span', 'lock', '🔒'));
  if (s.auto_merge) { const am = el('span', 'automerge', '⛙'); am.title = 'Auto-merge'; trail.appendChild(am); }
  // Trailing glowing status dot.
  const dot = el('span', 'dot glow' + (ind.pulse ? ' pulse' : ''));
  dot.style.background = ind.color;
  dot.style.color = ind.color; // drives the glow ring (box-shadow: currentColor)
  trail.appendChild(dot);
  top.appendChild(trail);
  content.appendChild(top);

  if (s.ticket_title) content.appendChild(el('div', 'subtle', s.ticket_title));
  if (s.repo) content.appendChild(el('div', 'meta', s.repo + (s.branch ? ' · ' + s.branch : '')));

  const badges = el('div', 'row-badges');
  if (s.ticket_badge) badges.appendChild(el('span', 'badge', s.ticket_badge));
  // PR badge — shown whenever a PR link exists (stored, or live from the app
  // when it's only in memory); colored by live status when available.
  const prLink = (s.links || []).find((l) => l.type === 'pr') || liveFor(s.id).pr_link;
  if (prLink) {
    const color = prBadgeColor(liveFor(s.id).pr);
    const prb = el('span', 'pr-badge', prLink.label || 'PR');
    prb.style.color = color;
    prb.style.borderColor = color;
    badges.appendChild(prb);
  }
  if (ind.label) {
    const activity = el('span', 'activity-badge', ind.label);
    activity.style.color = ind.color;
    badges.appendChild(activity);
  }
  if (badges.children.length) content.appendChild(badges);
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
// Session right-click context menu (custom — suppresses the browser default).
// ---------------------------------------------------------------------------
function closeContextMenu() {
  const m = document.querySelector('.ctx-menu');
  if (m) m.remove();
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
  setTimeout(() => document.addEventListener('click', closeContextMenu, { once: true }), 0);
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
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  setTimeout(() => document.addEventListener('click', closeContextMenu, { once: true }), 0);
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
  if (s.ticket_url || prUrl) items.push({ sep: true });
  const hasPR = (s.links || []).some((l) => l.type === 'pr');
  if (s.kind === 'manager') {
    items.push({ label: 'Rename', action: () => renameSession(s.id, s.name) });
    items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
    return items;
  }
  if (s.kind === 'review') {
    if (hasPR) items.push({ label: 'Add label crow:merge to PR', action: () => sessionAction('add-merge-label', s.id) });
    items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
    return items;
  }
  if (s.status === 'active' && s.ticket_url) {
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
  items.push({ sep: true });
  items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
  return items;
}

async function sessionAction(method, id, extra) {
  try { await rpc(method, Object.assign({ session_id: id }, extra || {})); }
  catch (e) { window.alert(method + ' failed: ' + (e.message || e)); }
}

// ---------------------------------------------------------------------------
// Detail + terminal tabs
// ---------------------------------------------------------------------------
async function selectSession(id) {
  selectedId = id;
  selectedBoard = null;
  const app = document.getElementById('app');
  app.classList.add('has-selection');
  app.classList.remove('board-active', 'mobile-show-sidebar'); // leave board, reveal terminal on mobile
  document.getElementById('board').innerHTML = '';
  renderSidebar();
  renderHeader(sessions.find((x) => x.id === id));
  ensureTerminal();
  setTimeout(fitTerminal, 50); // detail pane just became visible (mobile) — refit
  await refreshTerminals();
  refreshLive();
  refreshArtifacts(id);
}

// ---------------------------------------------------------------------------
// Artifacts — per-session generated images (diagrams/screenshots) the agent
// dropped in the scratch dir. crowd lists them; the browser GETs each from the
// sandboxed /artifacts route. A compact strip under the header; click to zoom.
// ---------------------------------------------------------------------------
const artifactsBySession = {};
let artifactsCollapsed = localStorage.getItem('crow.artifacts.collapsed') === '1';

async function refreshArtifacts(id) {
  try {
    const res = await rpc('list-artifacts', { session_id: id });
    artifactsBySession[id] = res.images || [];
  } catch (_) { artifactsBySession[id] = []; }
  if (id === selectedId) renderArtifactsStrip();
}

function renderArtifactsStrip() {
  const root = document.getElementById('detail-artifacts');
  if (!root) return;
  root.innerHTML = '';
  const images = artifactsBySession[selectedId] || [];
  if (!images.length) { root.classList.remove('has-images'); return; }
  root.classList.add('has-images');
  root.classList.toggle('collapsed', artifactsCollapsed);

  // Clickable header — chevron + label + count — toggles the strip.
  const header = el('div', 'artifacts-header');
  header.appendChild(el('span', 'artifacts-chevron', '▸')); // ▸ (CSS rotates when open)
  header.appendChild(el('span', 'artifacts-label', 'Images'));
  header.appendChild(el('span', 'artifacts-count', String(images.length)));
  header.onclick = () => {
    artifactsCollapsed = !artifactsCollapsed;
    localStorage.setItem('crow.artifacts.collapsed', artifactsCollapsed ? '1' : '0');
    root.classList.toggle('collapsed', artifactsCollapsed);
  };
  root.appendChild(header);

  const strip = el('div', 'artifacts-strip');
  for (const img of images) {
    const thumb = el('img', 'artifact-thumb');
    thumb.src = img.url;
    thumb.alt = img.name;
    thumb.title = img.name;
    thumb.loading = 'lazy';
    thumb.onclick = () => openLightbox(img.url, img.name);
    strip.appendChild(thumb);
  }
  root.appendChild(strip);
}

function openLightbox(url, alt) {
  const box = document.getElementById('lightbox');
  const img = document.getElementById('lightbox-img');
  img.src = url;
  img.alt = alt || '';
  box.hidden = false;
}

(function wireLightbox() {
  const box = document.getElementById('lightbox');
  if (box) box.onclick = () => { box.hidden = true; document.getElementById('lightbox-img').src = ''; };
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && box && !box.hidden) { box.hidden = true; document.getElementById('lightbox-img').src = ''; }
  });
})();

function shorten(path) {
  return path.replace(/^\/Users\/[^/]+/, '~').replace(/^\/home\/[^/]+/, '~');
}

// The review request matching a review session (by review_session_id), from the
// prefetched reviews board — so the session view can show the PR author.
function reviewForSession(id) {
  const rs = (boardData.reviews && boardData.reviews.reviews) || [];
  return rs.find((r) => r.review_session_id === id) || null;
}

function renderHeader(s) {
  const root = document.getElementById('detail-header');
  root.innerHTML = '';
  if (!s) return;

  const top = el('div', 'detail-top');
  const nameEl = el('div', 'detail-name', s.name);
  nameEl.title = 'Double-click to rename';
  nameEl.ondblclick = () => renameSession(s.id, s.name);
  top.appendChild(nameEl);
  if (liveFor(s.id).remote_control_active) top.appendChild(rcGlyph());
  const badge = el('span', 'status-badge', s.status);
  badge.style.color = STATUS_COLOR[s.status] || 'var(--text-muted)';
  top.appendChild(badge);
  root.appendChild(top);

  if (s.ticket_title) root.appendChild(el('div', 'subtle', s.ticket_title));
  // Review sessions: surface the PR author. Prefer the live review request
  // (Reviews board), but fall back to the author persisted on the session at
  // review-creation so it still shows when the board is empty (CROW-593).
  const rev = reviewForSession(s.id);
  const reviewAuthor = (rev && rev.author) || s.review_author;
  if (reviewAuthor) root.appendChild(el('div', 'subtle', 'PR by @' + reviewAuthor));
  // Repo · branch on the left, worktree path pushed to the right (like the desktop).
  if (s.repo || s.branch || s.worktree_path) {
    const metaRow = el('div', 'meta meta-row');
    const left = [];
    if (s.repo) left.push(s.repo);
    if (s.branch) left.push(s.branch);
    if (left.length) metaRow.appendChild(el('span', null, left.join(' · ')));
    if (s.worktree_path) metaRow.appendChild(el('span', 'meta-path', shorten(s.worktree_path)));
    root.appendChild(metaRow);
  }
  root.appendChild(el('div', 'meta', 'Agent: ' + (s.agent_display_name || s.agent_kind || '—')));

  // Links + actions on ONE row (issue/PR/repo chips + inline PR status on the
  // left, action buttons trailing) — matching the desktop detail header.
  const links = (s.links || []).slice();
  if (s.ticket_url && !links.some((l) => l.type === 'ticket')) {
    links.unshift({ label: s.ticket_badge || 'Issue', url: s.ticket_url, type: 'ticket' });
  }
  // Add the app's live PR link when it isn't in the stored links (e.g. derived
  // from the linked issue, not persisted).
  const livePr = liveFor(s.id).pr_link;
  if (livePr && !links.some((l) => l.type === 'pr')) {
    links.push({ label: livePr.label, url: livePr.url, type: 'pr' });
  }
  const pr = liveFor(s.id).pr;

  const headerRow = el('div', 'header-row');
  for (const link of links) {
    const chip = document.createElement('a');
    chip.className = 'link-chip link-' + (link.type || 'custom');
    chip.href = link.url;
    chip.target = '_blank';
    chip.rel = 'noopener';
    chip.textContent = (link.type === 'ticket' && s.ticket_badge) || link.label || link.type || 'link';
    headerRow.appendChild(chip);
  }
  if (pr && pr.has_pr) headerRow.appendChild(prStatusInline(pr));

  // Right-aligned action cluster: PR quick-actions, then status transitions + delete.
  const actions = el('div', 'actions-cluster');
  if (pr && pr.has_pr && !pr.is_merged) {
    if (pr.merge === 'conflicting') actions.appendChild(qaButton('Rebase & Fix Conflicts', 'fixConflicts', s.id, 'danger', 'merge'));
    if (pr.review === 'changesRequested') actions.appendChild(qaButton('Address Review', 'addressChanges', s.id, 'danger', 'pencil'));
    if (pr.checks === 'failing') actions.appendChild(qaButton('Fix Checks', 'fixChecks', s.id, 'danger', 'warning'));
    if (pr.ready_to_merge) actions.appendChild(qaButton('Merge PR', 'mergePR', s.id, 'primary', 'merge'));
  }
  if (s.kind !== 'manager') {
    if (s.status === 'active' && s.ticket_url) {
      actions.appendChild(actionBtn('In Review', 'eye', null, () => sessionAction('mark-in-review', s.id)));
    }
    if (s.status === 'active' || s.status === 'inReview') {
      actions.appendChild(actionBtn('Mark as Completed', 'check', null, () => sessionAction('complete-session', s.id)));
    }
    if (s.status === 'completed') {
      actions.appendChild(actionBtn('Move to Active', 'uturn', null, () => sessionAction('set-session-active', s.id)));
    }
    actions.appendChild(actionBtn('Delete', 'trash', 'danger', () => deleteSession(s.id, s.name)));
  }
  if (actions.children.length) headerRow.appendChild(actions);
  if (headerRow.children.length) root.appendChild(headerRow);
}

// Inline PR status, mirroring the desktop PRStatusDetail.
function prStatusInline(pr) {
  const wrap = el('div', 'pr-status-inline');
  if (pr.is_merged) { wrap.appendChild(prStatusPart('✔ Merged', 'var(--purple)')); return wrap; }
  const checks = {
    passing: ['✔ Checks pass', 'var(--green)'],
    failing: [(pr.failed_checks && pr.failed_checks.length ? '✕ ' + pr.failed_checks.length + ' failing' : '✕ Checks failing'), 'var(--red)'],
    pending: ['◷ Checks running', 'var(--orange)'],
    unknown: ['? No checks', 'var(--text-muted)'],
  }[pr.checks] || ['? No checks', 'var(--text-muted)'];
  wrap.appendChild(prStatusPart(checks[0], checks[1]));
  const review = {
    approved: ['✔ Approved', 'var(--green)'],
    changesRequested: ['✕ Changes requested', 'var(--red)'],
    reviewRequired: ['◷ Needs review', 'var(--orange)'],
    unknown: ['○ No reviews', 'var(--text-muted)'],
  }[pr.review] || ['○ No reviews', 'var(--text-muted)'];
  wrap.appendChild(prStatusPart(review[0], review[1]));
  if (pr.merge === 'conflicting') wrap.appendChild(prStatusPart('⚠ Conflicts', 'var(--red)'));
  return wrap;
}

function prStatusPart(text, color) {
  const part = el('span', 'pr-stat', text);
  part.style.color = color;
  return part;
}

function qaButton(label, action, id, variant, iconName) {
  const btn = el('button', 'action-btn' + (variant ? ' action-' + variant : ''), '');
  if (iconName) btn.appendChild(icon(iconName));
  btn.appendChild(el('span', null, label));
  btn.onclick = () => quickAction(id, action, label);
  return btn;
}

// A detail-header action button with a leading icon + click handler.
function actionBtn(label, iconName, variant, onclick) {
  const btn = el('button', 'action-btn' + (variant ? ' action-' + variant : ''), '');
  if (iconName) btn.appendChild(icon(iconName));
  btn.appendChild(el('span', null, label));
  btn.onclick = onclick;
  return btn;
}

// Dispatch a PR quick-action (forwarded to the app's agent terminal).
async function quickAction(id, action, label) {
  try {
    await rpc('quick-action', { session_id: id, action });
    if (term) term.write('\r\n\x1b[33m[crow] dispatched: ' + label + '\x1b[0m\r\n');
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] ' + label + ' failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}

async function renameSession(id, current) {
  const name = window.prompt('Rename session', current);
  if (!name || name === current) return;
  try {
    await rpc('rename-session', { session_id: id, name });
    const s = sessions.find((x) => x.id === id);
    if (s) { s.name = name; renderSidebar(); if (id === selectedId) renderHeader(s); }
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] rename failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}

async function deleteSession(id, name) {
  if (!window.confirm('Delete session "' + name + '"? This removes its worktree and terminals.')) return;
  try {
    await rpc('delete-session', { session_id: id });
    sessions = sessions.filter((x) => x.id !== id);
    if (selectedId === id) {
      selectedId = null;
      const app = document.getElementById('app');
      app.classList.remove('has-selection');
      app.classList.remove('mobile-show-sidebar');
      document.getElementById('detail-header').innerHTML = '';
      document.getElementById('tabbar').innerHTML = '';
    }
    renderSidebar();
  } catch (e) {
    window.alert('Delete failed: ' + (e.message || e));
  }
}

async function refreshTerminals() {
  try {
    const res = await rpc('list-terminals', { session_id: selectedId });
    terminals = res.terminals || [];
  } catch (_) {
    terminals = [];
  }
  if (!activeTerminal || !terminals.find((t) => t.id === activeTerminal.id)) {
    activeTerminal = terminals[0] || null;
  }
  renderTabs();
  if (activeTerminal) selectWindow(activeTerminal.window);
}

function renderTabs() {
  const bar = document.getElementById('tabbar');
  bar.innerHTML = '';
  for (const t of terminals) {
    const tab = el('div', 'tab' + (activeTerminal && t.id === activeTerminal.id ? ' active' : ''));
    const label = el('span', null, t.name);
    label.onclick = () => switchTerminal(t);
    tab.appendChild(label);
    const close = el('span', 'tab-close', '×');
    close.onclick = (e) => { e.stopPropagation(); closeTerminal(t); };
    tab.appendChild(close);
    bar.appendChild(tab);
  }
  const add = el('div', 'tab add', '+');
  add.onclick = addTerminal;
  add.title = 'New terminal';
  bar.appendChild(add);
}

function switchTerminal(t) {
  activeTerminal = t;
  renderTabs();
  selectWindow(t.window);
  if (term) term.focus();
}

async function addTerminal() {
  if (!selectedId) return;
  try {
    const res = await rpc('new-terminal', { session_id: selectedId });
    await refreshTerminals();
    const created = terminals.find((t) => t.id === res.terminal_id);
    if (created) switchTerminal(created);
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] new-terminal failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}

async function closeTerminal(t) {
  try { await rpc('close-terminal', { session_id: selectedId, terminal_id: t.id }); } catch (_) {}
  if (activeTerminal && activeTerminal.id === t.id) activeTerminal = null;
  await refreshTerminals();
}

// ---------------------------------------------------------------------------
// Boards (Ticket Board / Reviews / Allowlist)
// ---------------------------------------------------------------------------
function selectBoard(key) {
  selectedBoard = key;
  selectedId = null;
  const app = document.getElementById('app');
  app.classList.add('has-selection', 'board-active');
  app.classList.remove('mobile-show-sidebar');
  document.getElementById('detail-header').innerHTML = '';
  document.getElementById('tabbar').innerHTML = '';
  renderSidebar();
  renderBoard();       // instant paint (may be stale/empty)…
  // Allowlist is manual-refresh-only (never polled), so a plain list read
  // returns nothing until the app has scanned. Kick a scan on open so the
  // section populates without the user having to click Refresh (CROW-593).
  if (key === 'allowlist') refreshAllowlist();
  else refreshBoard(key); // …then refresh from the app
}

// Fetch one board; only re-render when the data actually changed so polling
// doesn't reset scroll/selection while idle.
async function refreshBoard(key) {
  const method = key === 'tickets' ? 'list-tickets' : key === 'reviews' ? 'list-reviews' : 'list-allowlist';
  let data;
  try { data = await rpc(method); } catch (_) { return; }
  const changed = JSON.stringify(boardData[key]) !== JSON.stringify(data);
  boardData[key] = data;
  if (changed) renderSidebar(); // badge counts
  if (changed && selectedBoard === key) renderBoard();
  // Reviews carry the PR author shown in the session header — re-render it when
  // reviews (re)load so a selected review session picks the author up.
  if (key === 'reviews' && selectedId) {
    const sel = sessions.find((x) => x.id === selectedId);
    if (sel) renderHeader(sel);
  }
}

function renderBoard() {
  const root = document.getElementById('board');
  root.innerHTML = '';
  if (selectedBoard === 'tickets') renderTicketBoard(root);
  else if (selectedBoard === 'reviews') renderReviewBoard(root);
  else if (selectedBoard === 'allowlist') renderAllowlist(root);
}

// -- shared card helpers --
function relTime(iso) {
  if (!iso) return '';
  const then = Date.parse(iso);
  if (isNaN(then)) return '';
  const s = Math.max(0, (Date.now() - then) / 1000);
  if (s < 60) return 'just now';
  const m = s / 60; if (m < 60) return Math.floor(m) + 'm';
  const h = m / 60; if (h < 24) return Math.floor(h) + 'h';
  const d = h / 24; if (d < 30) return Math.floor(d) + 'd';
  const mo = d / 30; if (mo < 12) return Math.floor(mo) + 'mo';
  return Math.floor(mo / 12) + 'y';
}

function linkChip(text, url, type) {
  const a = document.createElement('a');
  a.className = 'link-chip link-' + (type || 'custom');
  a.href = url; a.target = '_blank'; a.rel = 'noopener';
  a.textContent = text;
  return a;
}

function labelPills(labels) {
  const wrap = el('div', 'label-row');
  for (const l of (labels || [])) {
    const pill = el('span', 'label-pill', l.name);
    if (l.color) { pill.style.borderColor = '#' + l.color; pill.style.color = '#' + l.color; }
    wrap.appendChild(pill);
  }
  return wrap;
}

function boardEmpty(msg) {
  const wrap = el('div', 'board-empty');
  wrap.appendChild(el('div', null, msg));
  wrap.appendChild(el('div', 'board-empty-hint', 'Boards require the Crow desktop app to be running.'));
  return wrap;
}

// A spawning action (Start Working / Start Review): disable the button, let the
// new session surface via the sidebar poll.
async function spawnAction(btn, method, params, label) {
  btn.disabled = true;
  const orig = btn.textContent;
  btn.textContent = 'Starting…';
  try {
    await rpc(method, params);
    btn.textContent = 'Started ✓';
  } catch (e) {
    btn.disabled = false;
    btn.textContent = orig;
    window.alert(label + ' failed: ' + (e.message || e));
  }
}

// -- Ticket Board --
function renderTicketBoard(root) {
  const d = boardData.tickets;
  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Ticket Board'));
  if (d && d.done_last_24h) head.appendChild(el('span', 'done-chip', d.done_last_24h + ' done · 24h'));
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.onclick = () => refreshTickets();
  head.appendChild(refresh);
  root.appendChild(head);

  const counts = (d && d.counts) || {};
  const bar = el('div', 'pipeline');
  for (const seg of PIPELINE) {
    const n = seg === 'All' ? (counts.All || 0) : (counts[seg] || 0);
    const cell = el('div', 'pipe-seg' + (ticketFilter === seg ? ' active' : ''));
    cell.appendChild(el('span', 'pipe-label', seg));
    cell.appendChild(el('span', 'pipe-count', String(n)));
    cell.onclick = () => { ticketFilter = seg; renderBoard(); };
    bar.appendChild(cell);
  }
  root.appendChild(bar);

  let issues = ((d && d.issues) || []).slice();
  if (ticketFilter !== 'All') issues = issues.filter((i) => i.project_status === ticketFilter);
  issues.sort((a, b) => (b.updated_at || '').localeCompare(a.updated_at || ''));
  if (!issues.length) { root.appendChild(boardEmpty('No tickets in this view')); return; }
  const list = el('div', 'card-list');
  for (const i of issues) list.appendChild(ticketCard(i));
  root.appendChild(list);
}

function ticketCard(i) {
  const card = el('div', 'board-card status-accent');
  card.oncontextmenu = (e) => showCardMenu(e, [
    { label: 'Copy issue link', url: i.url },
    i.pr_url ? { label: 'Copy PR link', url: i.pr_url } : null,
  ]);
  const sc = TICKET_STATUS_COLOR[i.project_status] || 'var(--text-muted)';
  card.style.borderLeftColor = sc;
  const meta = el('div', 'card-meta');
  meta.appendChild(el('span', 'repo-tag', i.repo));
  meta.appendChild(linkChip('Issue #' + i.number, i.url, 'ticket'));
  if (i.pr_number && i.pr_url) meta.appendChild(linkChip('PR #' + i.pr_number, i.pr_url, 'pr'));
  const t = relTime(i.updated_at);
  if (t) meta.appendChild(el('span', 'card-time', t));
  card.appendChild(meta);
  card.appendChild(el('div', 'card-title', i.title));
  if (i.labels && i.labels.length) card.appendChild(labelPills(i.labels));
  const foot = el('div', 'card-foot');
  const statusPill = el('span', 'status-pill', i.project_status);
  statusPill.style.color = sc;
  statusPill.style.borderColor = sc;
  foot.appendChild(statusPill);
  if (i.linked_session_id) {
    const go = el('button', 'action-btn', 'Go to Session');
    go.onclick = () => selectSession(i.linked_session_id);
    foot.appendChild(go);
  } else {
    const work = el('button', 'action-btn action-primary', 'Start Working');
    work.onclick = () => spawnAction(work, 'work-on-issue', { url: i.url }, 'Start Working');
    foot.appendChild(work);
  }
  card.appendChild(foot);
  return card;
}

async function refreshTickets() {
  try { await rpc('refresh-tickets'); } catch (_) { /* app down — ignore */ }
  setTimeout(() => refreshBoard('tickets'), 1200);
}

// -- Review Board --
function renderReviewBoard(root) {
  const d = boardData.reviews;
  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Reviews'));
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.onclick = () => refreshBoard('reviews');
  head.appendChild(refresh);
  root.appendChild(head);

  const reviews = ((d && d.reviews) || []).slice()
    .sort((a, b) => (b.requested_at || '').localeCompare(a.requested_at || ''));
  if (!reviews.length) { root.appendChild(boardEmpty('No review requests')); return; }
  const list = el('div', 'card-list');
  for (const r of reviews) list.appendChild(reviewCard(r));
  root.appendChild(list);
}

function reviewCard(r) {
  const card = el('div', 'board-card');
  card.oncontextmenu = (e) => showCardMenu(e, [{ label: 'Copy PR link', url: r.url }]);
  const meta = el('div', 'card-meta');
  meta.appendChild(el('span', 'repo-tag', r.repo));
  meta.appendChild(linkChip('#' + r.pr_number, r.url, 'pr'));
  if (r.is_draft) meta.appendChild(el('span', 'draft-badge', 'Draft'));
  const t = relTime(r.requested_at);
  if (t) meta.appendChild(el('span', 'card-time', t));
  card.appendChild(meta);
  card.appendChild(el('div', 'card-title', r.title));
  const sub = el('div', 'card-sub');
  sub.appendChild(el('span', null, '@' + r.author));
  if (r.head_branch) sub.appendChild(el('span', 'branch-tag', r.head_branch));
  card.appendChild(sub);
  if (r.labels && r.labels.length) card.appendChild(labelPills(r.labels));
  const foot = el('div', 'card-foot');
  if (r.review_session_id) {
    const go = el('button', 'action-btn', 'Go to Session');
    go.onclick = () => selectSession(r.review_session_id);
    foot.appendChild(go);
  } else {
    const rev = el('button', 'action-btn action-primary', 'Start Review');
    rev.onclick = () => spawnAction(rev, 'start-review', { url: r.url }, 'Start Review');
    foot.appendChild(rev);
  }
  card.appendChild(foot);
  return card;
}

// -- Allowlist --
function renderAllowlist(root) {
  const d = boardData.allowlist;
  let entries = ((d && d.entries) || []).slice();
  if (allowlistHideGlobal) entries = entries.filter((e) => !e.is_global);
  entries.sort((a, b) => a.pattern.localeCompare(b.pattern));
  // Only worktree-only patterns are promotable to global.
  const promotable = entries.filter((e) => !e.is_global).map((e) => e.pattern);

  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Allowlist'));
  const hide = el('button', 'action-btn' + (allowlistHideGlobal ? ' active' : ''), allowlistHideGlobal ? 'Show Global' : 'Hide Global');
  hide.onclick = () => { allowlistHideGlobal = !allowlistHideGlobal; renderBoard(); };
  head.appendChild(hide);
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.onclick = () => refreshAllowlist();
  head.appendChild(refresh);
  const selectAll = el('button', 'action-btn', 'Select All');
  selectAll.disabled = !promotable.length;
  selectAll.onclick = () => { promotable.forEach((p) => allowlistSelection.add(p)); renderBoard(); };
  head.appendChild(selectAll);
  const clearSel = el('button', 'action-btn', 'Clear');
  clearSel.disabled = allowlistSelection.size === 0;
  clearSel.onclick = () => { allowlistSelection.clear(); renderBoard(); };
  head.appendChild(clearSel);
  const promote = el('button', 'action-btn action-primary', 'Promote to Global (' + allowlistSelection.size + ')');
  promote.id = 'allow-promote';
  promote.disabled = allowlistSelection.size === 0;
  promote.onclick = () => promoteAllowlist([...allowlistSelection]);
  head.appendChild(promote);
  root.appendChild(head);

  if (!entries.length) { root.appendChild(boardEmpty('No allowlist entries')); return; }
  const list = el('div', 'allow-list');
  for (const e of entries) list.appendChild(allowRow(e));
  root.appendChild(list);
}

function allowRow(e) {
  const row = el('div', 'allow-row');
  if (!e.is_global) {
    // Only worktree-only patterns are promotable to global.
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.className = 'allow-check';
    box.checked = allowlistSelection.has(e.pattern);
    box.onchange = () => {
      if (box.checked) allowlistSelection.add(e.pattern); else allowlistSelection.delete(e.pattern);
      const btn = document.getElementById('allow-promote');
      if (btn) {
        btn.textContent = 'Promote to Global (' + allowlistSelection.size + ')';
        btn.disabled = allowlistSelection.size === 0;
      }
    };
    row.appendChild(box);
  } else {
    row.appendChild(el('span', 'allow-check-spacer'));
  }
  const main = el('div', 'allow-main');
  main.appendChild(el('code', 'allow-pattern', e.pattern));
  const badges = el('div', 'allow-badges');
  if (e.is_global) badges.appendChild(el('span', 'allow-badge-global', 'Global'));
  for (const name of (e.worktree_session_names || [])) badges.appendChild(el('span', 'allow-chip', name));
  main.appendChild(badges);
  row.appendChild(main);
  return row;
}

async function promoteAllowlist(patterns) {
  if (!patterns.length) return;
  try {
    await rpc('promote-allowlist', { patterns });
    allowlistSelection.clear();
    await rpc('refresh-allowlist').catch(() => {});
    setTimeout(() => refreshBoard('allowlist'), 800);
  } catch (e) {
    window.alert('Promote failed: ' + (e.message || e));
  }
}

async function refreshAllowlist() {
  try { await rpc('refresh-allowlist'); } catch (_) { /* app down — ignore */ }
  setTimeout(() => refreshBoard('allowlist'), 800);
}

// ---------------------------------------------------------------------------
// Terminal (xterm.js on one /terminal WebSocket; switch windows via control frame)
// ---------------------------------------------------------------------------
let term = null;
let fitAddon = null;
let termWs = null;

function ensureTerminal() {
  if (term) return;
  fitAddon = new FitAddon.FitAddon();
  const imageAddon = new ImageAddon.ImageAddon({ sixelSupport: true, iipSupport: true, kittySupport: true });
  // Config block mirrors CrowTerminal/Resources/xterm/terminal.html.
  term = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: '"MesloLGS NF", "MesloLGS Nerd Font", "JetBrainsMono Nerd Font", "Hack Nerd Font", "FiraCode Nerd Font", Menlo, Monaco, monospace',
    theme: { background: '#1e1e1e', foreground: '#d4d4d4' },
    scrollback: 10000,
    allowTransparency: true,
  });
  term.loadAddon(fitAddon);
  term.loadAddon(imageAddon);
  term.open(document.getElementById('terminal'));
  term.onData((data) => {
    if (termWs && termWs.readyState === WebSocket.OPEN) termWs.send(new TextEncoder().encode(data));
  });
  // Cmd/Ctrl+C copies the selection (falling through to SIGINT when nothing is
  // selected so Ctrl+C still interrupts); Cmd+V pastes. Lets the browser own
  // copy/paste instead of tmux's copy-mode.
  term.attachCustomKeyEventHandler((e) => {
    if (e.type !== 'keydown') return true;
    const mod = e.metaKey || e.ctrlKey;
    if (mod && (e.key === 'c' || e.key === 'C') && term.hasSelection()) {
      copyToClipboard(term.getSelection());
      return false;
    }
    if (e.metaKey && (e.key === 'v' || e.key === 'V')) { pasteIntoTerminal(); return false; }
    return true;
  });
  enableTouchScroll(document.getElementById('terminal'));
  enableWheelScroll(document.getElementById('terminal'));
  window.addEventListener('resize', fitTerminal);
  connectTerminalWs();
}

// xterm.js doesn't scroll its scrollback on touch drags — map a one-finger
// vertical swipe to term.scrollLines so the terminal is scrollable on mobile.
function enableTouchScroll(node) {
  let lastY = null;
  node.addEventListener('touchstart', (e) => {
    if (e.touches.length === 1) lastY = e.touches[0].clientY;
  }, { passive: true });
  node.addEventListener('touchmove', (e) => {
    if (lastY == null || e.touches.length !== 1 || !term) return;
    const y = e.touches[0].clientY;
    const cell = (node.clientHeight / (term.rows || 24)) || 18;
    const delta = Math.trunc((lastY - y) / cell);
    if (delta !== 0) { term.scrollLines(delta); lastY = y; }
  }, { passive: true });
  node.addEventListener('touchend', () => { lastY = null; }, { passive: true });
}

// Let xterm.js own wheel scrolling in the browser: scroll the local 10k-line
// scrollback instead of forwarding the wheel to tmux (whose server-global
// `mouse on` would otherwise drop into copy-mode — janky in a browser). A
// fullscreen/alternate-screen app (vim, htop) still gets the wheel.
function enableWheelScroll(node) {
  node.addEventListener('wheel', (e) => {
    if (!term) return;
    const buf = term.buffer && term.buffer.active;
    if (buf && buf.type === 'alternate') return; // let TUIs handle the wheel
    term.scrollLines(e.deltaY > 0 ? 3 : -3);
    e.preventDefault();
    e.stopPropagation();
  }, { capture: true, passive: false });
}

// Paste the browser clipboard into the terminal (writes to the PTY, same path
// as typing). readText() needs a user gesture — the menu click / Cmd+V is one.
function pasteIntoTerminal() {
  if (!(navigator.clipboard && navigator.clipboard.readText)) return;
  navigator.clipboard.readText().then((text) => {
    if (text && termWs && termWs.readyState === WebSocket.OPEN) {
      termWs.send(new TextEncoder().encode(text));
    }
  }).catch(() => { /* denied / empty */ });
}

// Our own right-click menu for the terminal (copy selection / paste / select
// all / clear) — replaces the browser default, which we suppress. Copy appears
// only when there's a selection.
function showTerminalMenu(e) {
  e.preventDefault();
  closeContextMenu();
  if (!term) return;
  const sel = term.getSelection();
  const items = [];
  if (sel) items.push({ label: 'Copy', action: () => copyToClipboard(sel) });
  items.push({ label: 'Paste', action: pasteIntoTerminal });
  items.push({ label: 'Select all', action: () => term.selectAll() });
  items.push({ label: 'Clear', action: () => term.clear() });
  const menu = el('div', 'ctx-menu');
  for (const it of items) {
    const item = el('div', 'ctx-item', it.label);
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); it.action(); };
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  setTimeout(() => document.addEventListener('click', closeContextMenu, { once: true }), 0);
}

function connectTerminalWs() {
  termWs = new WebSocket(wsURL('/terminal'));
  termWs.binaryType = 'arraybuffer';
  termWs.onopen = () => {
    fitTerminal();
    if (activeTerminal) selectWindow(activeTerminal.window);
  };
  termWs.onmessage = (event) => {
    if (event.data instanceof ArrayBuffer) term.write(new Uint8Array(event.data));
  };
  termWs.onclose = () => { setTimeout(connectTerminalWs, 1000); };
  termWs.onerror = () => termWs.close();
}

function fitTerminal() {
  if (!term || !fitAddon) return;
  try { fitAddon.fit(); } catch (_) {}
  if (termWs && termWs.readyState === WebSocket.OPEN) {
    termWs.send(JSON.stringify({ type: 'resize', rows: term.rows, cols: term.cols }));
  }
}

function selectWindow(win) {
  if (win == null) return;
  if (termWs && termWs.readyState === WebSocket.OPEN) {
    termWs.send(JSON.stringify({ type: 'select-window', window: win }));
  }
}

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
document.getElementById('back-to-sidebar').onclick = () => {
  document.getElementById('app').classList.add('mobile-show-sidebar');
};
// Our own terminal context menu (copy/paste/select-all/clear) replaces the
// browser default over the coding pane.
document.getElementById('terminal-wrap').addEventListener('contextmenu', showTerminalMenu);

refreshSessions();
refreshLive();
// Fallback polls — the `changed` push (onServerChanged) drives the common case,
// so these are relaxed. refreshLive stays brisk: runtime PR/RC state isn't
// store-backed and so isn't covered by a nudge (CROW-581, M-D).
setInterval(refreshSessions, 10000);
setInterval(refreshLive, 4000);
// Prefetch ticket/review counts so the sidebar Tickets card + Reviews badge show
// before first open.
refreshBoard('tickets');
refreshBoard('reviews');
// Keep the open ticket/review board fresh (allowlist is manual-refresh only).
// Slow fallback — board changes are push-driven via the daemon's poll nudge.
setInterval(() => {
  if (selectedBoard === 'tickets' || selectedBoard === 'reviews') refreshBoard(selectedBoard);
}, 20000);
// Poll the selected session's images — new files aren't store-backed, so no
// `changed` nudge fires for them; a light 5s scan makes drops appear live.
setInterval(() => { if (selectedId) refreshArtifacts(selectedId); }, 5000);
