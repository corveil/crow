'use strict';
// Crow web UI — Session grid (CROW-1153). Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// Session grid (CROW-1153)
//
// A watch wall of up to 16 session cells. Cells are READ-ONLY capture-pane
// snapshots painted into a small xterm.js instance — not live PTY attaches —
// because tmux `window-size latest` would let a tiny cell SIGWINCH the shared
// agent window (ADR 0022). Click a cell to expand into the full session.
// ---------------------------------------------------------------------------
function loadGridPins() {
  try {
    const raw = localStorage.getItem(GRID_PINS_KEY);
    const parsed = raw ? JSON.parse(raw) : [];
    gridPinnedIds = Array.isArray(parsed)
      ? parsed.filter((id) => typeof id === 'string' && id)
      : [];
  } catch (_) {
    gridPinnedIds = [];
  }
}

function persistGridPins() {
  try { localStorage.setItem(GRID_PINS_KEY, JSON.stringify(gridPinnedIds)); }
  catch (_) { /* quota / private mode */ }
}

function isGridPinned(id) { return gridPinnedIds.indexOf(id) !== -1; }

function toggleGridPin(id) {
  if (isGridPinned(id)) gridPinnedIds = gridPinnedIds.filter((x) => x !== id);
  else gridPinnedIds = gridPinnedIds.concat([id]);
  persistGridPins();
  lastSidebarSig = null;
  renderSidebar();
  if (selectedBoard === 'grid') renderBoard();
}

function moveGridPin(id, dir) {
  const i = gridPinnedIds.indexOf(id);
  if (i < 0) return;
  const j = i + dir;
  if (j < 0 || j >= gridPinnedIds.length) return;
  const next = gridPinnedIds.slice();
  const tmp = next[i]; next[i] = next[j]; next[j] = tmp;
  gridPinnedIds = next;
  persistGridPins();
  if (selectedBoard === 'grid') renderBoard();
}

function gridActivityRank(s) {
  if (s.attention) return 0;
  switch (s.activity) {
    case 'working': return 1;
    case 'waiting': return 2;
    case 'done': return 3;
    default: return 4;
  }
}

function gridIsWatchable(s) {
  return s.status === 'active' || s.status === 'inReview';
}

// Pinned first (user order), then auto-fill active/in-review sessions sorted
// by activity. Completed/archived sessions stay off the wall unless pinned.
function gridRoster(list, pins) {
  const src = list || sessions;
  const order = pins || gridPinnedIds;
  const byId = new Map();
  for (const s of src) byId.set(s.id, s);
  const out = [];
  const seen = new Set();
  for (const id of order) {
    const s = byId.get(id);
    if (!s) continue;
    out.push(s);
    seen.add(id);
  }
  const rest = src.filter((s) => !seen.has(s.id) && gridIsWatchable(s));
  rest.sort((a, b) => {
    const ra = gridActivityRank(a) - gridActivityRank(b);
    if (ra) return ra;
    return String(a.name || '').localeCompare(String(b.name || ''));
  });
  return out.concat(rest);
}

function gridColsForCount(n) {
  if (n <= 1) return 1;
  if (n <= 4) return 2;
  if (n <= 9) return 3;
  return 4;
}

function gridVisibleSessions() {
  const roster = gridRoster();
  const pages = Math.max(1, Math.ceil(roster.length / GRID_PAGE_SIZE) || 1);
  if (gridPage > pages - 1) gridPage = pages - 1;
  if (gridPage < 0) gridPage = 0;
  const start = gridPage * GRID_PAGE_SIZE;
  return {
    roster: roster,
    pages: pages,
    visible: roster.slice(start, start + GRID_PAGE_SIZE),
  };
}

function leaveGridView() {
  stopGridPolling();
  const root = document.getElementById('board');
  if (root) delete root.dataset.gridKey;
  // CROW-1162: disposing up to 16 xterm instances is heavy. Do it after the
  // live session attach paints, not on the same turn as `selectSession`.
  scheduleGridTeardown();
}

function cancelGridTeardown() {
  gridTeardownGen += 1;
  if (gridTeardownTimer != null) {
    clearTimeout(gridTeardownTimer);
    gridTeardownTimer = null;
  }
}

function scheduleGridTeardown() {
  const gen = ++gridTeardownGen;
  if (gridTeardownTimer != null) {
    clearTimeout(gridTeardownTimer);
    gridTeardownTimer = null;
  }
  const ids = [...gridTerms.keys()];
  const tearDown = () => {
    gridTeardownTimer = null;
    if (gen !== gridTeardownGen) return;
    if (selectedBoard === 'grid') return;
    for (const id of ids) disposeGridTerm(id);
  };
  if (typeof requestIdleCallback === 'function') {
    requestIdleCallback(tearDown, { timeout: 400 });
  } else {
    gridTeardownTimer = setTimeout(tearDown, 0);
  }
}

function stopGridPolling() {
  if (gridPollTimer) { clearInterval(gridPollTimer); gridPollTimer = null; }
}

function startGridPolling() {
  if (gridPollTimer) return;
  gridPollTimer = setInterval(() => {
    if (selectedBoard !== 'grid') { stopGridPolling(); return; }
    if (typeof document !== 'undefined' && document.hidden) return;
    refreshGridSnapshots();
  }, GRID_POLL_MS);
}

function disposeGridTerm(id) {
  const pane = gridTerms.get(id);
  if (!pane) return;
  try { if (pane.ro) pane.ro.disconnect(); } catch (_) {}
  try { if (pane.term && pane.term.dispose) pane.term.dispose(); } catch (_) {}
  gridTerms.delete(id);
}

function disposeUnusedGridTerms(keepIds) {
  const keep = new Set(keepIds);
  for (const id of [...gridTerms.keys()]) {
    if (!keep.has(id)) disposeGridTerm(id);
  }
}

function renderSessionGrid(root) {
  cancelGridTeardown();
  root.classList.add('session-grid-board');
  const { visible, pages, roster } = gridVisibleSessions();
  const visIds = visible.map((s) => s.id);
  disposeUnusedGridTerms(visIds);

  const gridKey = visIds.join(',') + '/' + pages + '/' + gridPage + '/' + gridPinnedIds.join(',');
  if (root.dataset.gridKey === gridKey && root.querySelector('.session-grid')) {
    updateGridCellHeaders();
    startGridPolling();
    return;
  }
  root.dataset.gridKey = gridKey;

  // Detach term hosts before wiping so xterm instances survive a rebuild.
  for (const pane of gridTerms.values()) {
    if (pane.host && pane.host.parentElement) pane.host.parentElement.removeChild(pane.host);
  }

  root.innerHTML = '';
  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Session grid'));
  const meta = el('div', 'grid-meta',
    roster.length
      ? (visible.length + ' of ' + roster.length + ' session' + (roster.length === 1 ? '' : 's'))
      : '');
  head.appendChild(meta);
  if (pages > 1) {
    const pager = el('div', 'grid-pager');
    const prev = el('button', 'action-btn', '‹');
    prev.type = 'button';
    prev.title = 'Previous page';
    prev.disabled = gridPage === 0;
    prev.onclick = () => { gridPage -= 1; renderBoard(); };
    const next = el('button', 'action-btn', '›');
    next.type = 'button';
    next.title = 'Next page';
    next.disabled = gridPage >= pages - 1;
    next.onclick = () => { gridPage += 1; renderBoard(); };
    pager.appendChild(prev);
    pager.appendChild(el('span', 'grid-page-label', (gridPage + 1) + ' / ' + pages));
    pager.appendChild(next);
    head.appendChild(pager);
  }
  root.appendChild(head);

  if (!visible.length) {
    root.appendChild(boardEmpty('No sessions to watch. Pin a session from the sidebar menu, or start one.'));
    stopGridPolling();
    return;
  }

  const cols = gridColsForCount(visible.length);
  const rows = Math.max(1, Math.ceil(visible.length / cols));
  const grid = el('div', 'session-grid');
  grid.style.setProperty('--grid-cols', String(cols));
  grid.style.setProperty('--grid-rows', String(rows));
  for (const s of visible) grid.appendChild(gridCell(s));
  root.appendChild(grid);
  startGridPolling();
  refreshGridSnapshots();
}

function gridCell(s) {
  const pinned = isGridPinned(s.id);
  const cell = el('div', 'grid-cell' + (pinned ? ' pinned' : ''));
  cell.dataset.sessionId = s.id;
  const head = gridCellHeader(s);
  cell.appendChild(head);
  const hostWrap = el('div', 'grid-term');
  hostWrap.title = 'Open ' + (s.name || 'session');
  hostWrap.onclick = () => selectSession(s.id, { fromGrid: true });
  const existing = gridTerms.get(s.id);
  if (existing && existing.host) {
    hostWrap.appendChild(existing.host);
  } else {
    const host = el('div', 'grid-term-host');
    hostWrap.appendChild(host);
    mountGridTerm(s.id, host);
  }
  observeGridTerm(s.id, hostWrap);
  cell.appendChild(hostWrap);
  return cell;
}

function gridCellHeader(s) {
  const pinned = isGridPinned(s.id);
  const ind = activityIndicator(s);
  const head = el('div', 'grid-cell-head');
  const nameBtn = el('button', 'grid-cell-name', s.name || 'session');
  nameBtn.type = 'button';
  nameBtn.title = s.name || 'Open session';
  nameBtn.onclick = (e) => { e.stopPropagation(); selectSession(s.id, { fromGrid: true }); };
  const dot = el('span', 'grid-cell-dot' + (ind.pulse ? ' pulse' : ''));
  dot.style.background = ind.color;
  const badge = el('span', 'grid-cell-badge', ind.label || s.status || '');
  badge.style.color = ind.color;
  const actions = el('div', 'grid-cell-actions');
  if (pinned) {
    const left = el('button', 'grid-cell-btn', '‹');
    left.type = 'button';
    left.title = 'Move earlier';
    left.onclick = (e) => { e.stopPropagation(); moveGridPin(s.id, -1); };
    const right = el('button', 'grid-cell-btn', '›');
    right.type = 'button';
    right.title = 'Move later';
    right.onclick = (e) => { e.stopPropagation(); moveGridPin(s.id, 1); };
    actions.appendChild(left);
    actions.appendChild(right);
  }
  const pinBtn = el('button', 'grid-cell-btn' + (pinned ? ' on' : ''), '');
  pinBtn.type = 'button';
  pinBtn.title = pinned ? 'Unpin from grid' : 'Pin to grid';
  pinBtn.appendChild(icon('pin', 12));
  pinBtn.onclick = (e) => { e.stopPropagation(); toggleGridPin(s.id); };
  actions.appendChild(pinBtn);
  head.appendChild(dot);
  head.appendChild(nameBtn);
  if (badge.textContent) head.appendChild(badge);
  head.appendChild(actions);
  return head;
}

function updateGridCellHeaders() {
  const root = document.getElementById('board');
  if (!root) return;
  for (const cell of root.querySelectorAll('.grid-cell')) {
    const s = sessions.find((x) => x.id === cell.dataset.sessionId);
    if (!s) continue;
    const old = cell.querySelector('.grid-cell-head');
    const next = gridCellHeader(s);
    if (old) cell.replaceChild(next, old);
  }
}

function mountGridTerm(sessionId, host) {
  if (typeof Terminal !== 'function') {
    gridTerms.set(sessionId, { term: null, host: host, lastSnap: '', cols: 0, rows: 0, lastScale: NaN });
    return;
  }
  const term = new Terminal({
    cursorBlink: false,
    disableStdin: true,
    fontSize: 11,
    fontFamily: DEFAULT_TERM_FONT,
    theme: { background: '#1e1e1e', foreground: '#d4d4d4' },
    scrollback: 0,
    allowTransparency: true,
  });
  term.open(host);
  gridTerms.set(sessionId, { term: term, host: host, lastSnap: '', cols: 0, rows: 0, lastScale: NaN });
}

function observeGridTerm(sessionId, wrap) {
  const pane = gridTerms.get(sessionId);
  if (!pane || !window.ResizeObserver) return;
  try { if (pane.ro) pane.ro.disconnect(); } catch (_) {}
  pane.ro = new ResizeObserver(() => {
    if (pane.scaleScheduled) return;
    pane.scaleScheduled = true;
    requestAnimationFrame(() => {
      pane.scaleScheduled = false;
      scaleGridTerm(sessionId);
    });
  });
  pane.ro.observe(wrap);
}

function scaleGridTerm(sessionId) {
  const pane = gridTerms.get(sessionId);
  if (!pane || !pane.term || !pane.host) return;
  const cell = pane.host.parentElement;
  const screen = pane.host.querySelector('.xterm') || pane.term.element;
  if (!cell || !screen) return;
  const cw = cell.clientWidth || 1;
  const ch = cell.clientHeight || 1;
  const tw = screen.offsetWidth || pane.term.element.offsetWidth || 1;
  const th = screen.offsetHeight || pane.term.element.offsetHeight || 1;
  const s = Math.min(cw / tw, ch / th);
  if (pane.lastScale === s) return;
  pane.lastScale = s;
  screen.style.transformOrigin = 'top left';
  screen.style.transform = 'scale(' + s + ')';
}

async function refreshGridSnapshots() {
  if (selectedBoard !== 'grid') return;
  const { visible } = gridVisibleSessions();
  if (!visible.length) return;
  const ids = visible.map((s) => s.id);
  let res;
  try {
    res = await rpc('list-session-terminal-snapshots', { session_ids: ids });
  } catch (_) { return; }
  if (selectedBoard !== 'grid') return;
  const snaps = (res && res.snapshots) || {};
  for (const id of ids) {
    const row = snaps[id];
    if (!row || typeof row.snapshot !== 'string') continue;
    paintGridSnapshot(id, row);
  }
}

function paintGridSnapshot(id, row) {
  const pane = gridTerms.get(id);
  if (!pane) return;
  if (row.snapshot === pane.lastSnap) return;
  pane.lastSnap = row.snapshot;
  const cols = Math.max(1, Number(row.cols) || 80);
  const rows = Math.max(1, Number(row.rows) || 24);
  if (pane.term) {
    try {
      if (pane.term.cols !== cols || pane.term.rows !== rows) {
        pane.term.resize(cols, rows);
        pane.lastScale = NaN;
      }
      pane.term.write(row.snapshot);
    } catch (_) { /* xterm not ready */ }
    scaleGridTerm(id);
  }
}
