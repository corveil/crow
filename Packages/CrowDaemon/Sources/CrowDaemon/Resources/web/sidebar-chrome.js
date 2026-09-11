'use strict';
// Crow web UI — Tickets card, Scratch/Grid/Reviews nav pills, status bar, icon column,
// New Manager, notification panel. Extracted from sidebar.js (CROW-1238).

function scratchPill() {
  const pill = navPill('Scratch', selectedBoard === 'scratch', () => selectBoard('scratch'));
  const count = scratchOpenCount();
  if (count) {
    const badge = el('span', 'pill-badge', String(count));
    badge.title = count + ' open item' + (count === 1 ? '' : 's');
    pill.appendChild(badge);
  }
  return pill;
}

function scratchOpenCount() {
  const todos = (boardData.scratch && boardData.scratch.todos) || [];
  return todos.filter((t) => t.state !== 'done' && t.state !== 'dropped').length;
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

// Left sidebar-top stack (CROW-917 / CROW-1237): the Tickets card over three
// nav-pill rows — Grid · Scorecard, Reviews · Scratch, then the full-width
// Manager pill. Four pills on one row ellipsize at the default sidebar width.
function sidebarLeftStack() {
  const wrap = el('div', 'sidebar-left');
  wrap.appendChild(ticketsCard());

  // Row 1: Grid · Scorecard (each .nav-pills-row is its own non-wrapping flex line).
  const row1 = el('div', 'nav-pills-row');
  row1.appendChild(navPill('Grid', selectedBoard === 'grid', () => selectBoard('grid')));
  row1.appendChild(navPill('Scorecard', selectedBoard === 'scorecard', () => selectBoard('scorecard')));
  wrap.appendChild(row1);

  // Row 2: Reviews · Scratch. Open-count badge stays on Scratch — two labels
  // still fit the left column where four did not (CROW-1237).
  const row2 = el('div', 'nav-pills-row');
  const rev = navPill('Reviews', selectedBoard === 'reviews', () => selectBoard('reviews'));
  const unseen = (boardData.reviews && boardData.reviews.unseen) || 0;
  if (unseen) rev.appendChild(el('span', 'pill-badge', String(unseen)));
  row2.appendChild(rev);
  row2.appendChild(scratchPill());
  wrap.appendChild(row2);

  // Row 3: the primary Manager pill, spanning the full left-column width. Only
  // appended when a primary manager exists — an empty .nav-pills-row still consumes
  // a flex-gap slot, so appending one would leave a stray 6px gap below row 2. (The
  // right icon column no longer divides the left column's height — its buttons are a
  // fixed-size centered stack since CROW-922 — so a Manager-less render can't shrink
  // them below the WCAG floor.)
  const primaryManager = sessions.find((s) => s.kind === 'manager');
  if (primaryManager) {
    const row3 = el('div', 'nav-pills-row');
    const mgr = navPill('Manager', selectedId === primaryManager.id, () => selectSession(primaryManager.id));
    const ind = activityIndicator(primaryManager);
    const dot = el('span', 'pill-dot' + (ind.pulse ? ' pulse' : ''));
    dot.style.background = ind.color;
    mgr.insertBefore(dot, mgr.firstChild);
    if (liveFor(primaryManager.id).remote_control_active) mgr.appendChild(rcGlyph());
    row3.appendChild(mgr);
    wrap.appendChild(row3);
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
