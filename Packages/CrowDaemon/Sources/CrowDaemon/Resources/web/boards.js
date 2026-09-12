'use strict';
// Crow web UI — Board kernel: select/refresh/render + shared widgets.
// Extracted from app.js (CROW-1155); scorecard / tickets / reviews / scratch
// split out (CROW-1242).

// ---------------------------------------------------------------------------
// Boards (Ticket Board / Reviews)
// ---------------------------------------------------------------------------
function selectBoard(key) {
  navigate({ view: 'board', board: key });
  selectedBoard = key;
  selectedId = null;
  // Leaving a board (or re-entering) drops any stale selection on it.
  ticketSelectionMode = false;
  selectedIssueIDs.clear();
  reviewSelectionMode = false;
  selectedReviewURLs.clear();
  const app = document.getElementById('app');
  app.classList.add('has-selection', 'board-active');
  app.classList.remove('mobile-show-sidebar', 'route-missing');
  document.getElementById('detail-header').innerHTML = '';
  document.getElementById('tabbar').innerHTML = '';
  renderSidebar();
  renderBoard();       // instant paint (may be stale/empty)…
  if (key === 'grid') return;
  refreshBoard(key); // …then refresh from the app
}

// Fetch one board; only re-render when the data actually changed so polling
// doesn't reset scroll/selection while idle.
async function refreshBoard(key) {
  const method = key === 'tickets' ? 'list-tickets'
    : key === 'reviews' ? 'list-reviews'
    : key === 'scratch' ? 'todo-list'
    : 'get-scorecard';
  let data;
  try { data = await rpc(method); } catch (_) {
    // A failed read leaves us with no fresh word on the daemon's in-flight
    // flag, and a stale `true` never self-clears (CROW-771).
    if (key === 'tickets') clearDaemonRefreshFlag();
    return;
  }
  const changed = JSON.stringify(boardData[key]) !== JSON.stringify(data);
  boardData[key] = data;
  if (changed && (key === 'tickets' || key === 'reviews')) persistSidebarCache();
  if (key === 'reviews') detectReviewSounds();
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
  if (selectedBoard === 'grid') {
    renderSessionGrid(root);
    return;
  }
  leaveGridView();
  root.classList.remove('session-grid-board');
  root.innerHTML = '';
  if (selectedBoard === 'tickets') renderTicketBoard(root);
  else if (selectedBoard === 'reviews') renderReviewBoard(root);
  else if (selectedBoard === 'scorecard') renderScorecard(root);
  else if (selectedBoard === 'scratch') renderScratchBoard(root);
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

// CROW-1030: the commit page for a stamped build SHA on the upstream repo.
// Returns null for anything that would land on a 404 — `dev` (no git at build
// time), an empty/absent stamp, or any non-hex string — so callers render inert
// text instead of a broken link. The 7–40 hex bound matches
// VersionUpdateClient.githubCompareURL, which guards the same stamp Swift-side.
const CROW_UPSTREAM_REPO = 'corveil/crow';
function crowCommitURL(sha) {
  const s = String(sha == null ? '' : sha).trim().toLowerCase();
  if (!/^[0-9a-f]{7,40}$/.test(s)) return null;
  return 'https://github.com/' + CROW_UPSTREAM_REPO + '/commit/' + s;
}

function linkChip(text, url, type) {
  // Non-http(s) urls (javascript:/data: from injected data) render as a plain,
  // non-clickable chip — never an href (review).
  const safe = /^https?:\/\//i.test(url || '');
  const a = document.createElement(safe ? 'a' : 'span');
  a.className = 'link-chip link-' + (type || 'custom');
  if (safe) { a.href = url; a.target = '_blank'; a.rel = 'noopener'; }
  a.textContent = text;
  return a;
}

// `maxVisible` caps how many pills render, with a trailing `+N` for the rest —
// the sidebar row is narrow and passes 2 (native LabelPillsView's cap). Board
// cards omit it and render every label, as before (CROW-773).
function labelPills(labels, maxVisible) {
  const wrap = el('div', 'label-row');
  const all = labels || [];
  const shown = maxVisible != null ? all.slice(0, maxVisible) : all;
  for (const l of shown) {
    const pill = el('span', 'label-pill', l.name);
    if (l.color) { pill.style.borderColor = '#' + l.color; pill.style.color = '#' + l.color; }
    wrap.appendChild(pill);
  }
  if (all.length > shown.length) {
    const more = el('span', 'label-pill label-more', '+' + (all.length - shown.length));
    more.title = all.slice(shown.length).map((l) => l.name).join(', ');
    wrap.appendChild(more);
  }
  return wrap;
}

// An empty board is just an empty list, not an error — `crowd` serves the boards
// off its own IssueTracker (CROW-581 M-C), so a "requires the
// Crow desktop app" hint would be stale post native→web migration (ADR 0010) and
// read as a false error/warning (CROW-907). Just render the caller's context
// message ("No review requests", …). NOTE: this is reachable before the first
// read lands (the pre-refresh paint at selectBoard) — a caller that must not
// conflate "not loaded yet" with "empty" gates the message itself.
function boardEmpty(msg) {
  return el('div', 'board-empty', msg);
}

// Split-button host for a start control. A chevron ctx-item is *not* inside
// `.split-btn` (the menu lives on `document.body`); the opener stashes the
// host on the menu as `_splitBtn` so we still disable both halves.
function startActionHost(el) {
  const split = (el && el.closest && el.closest('.split-btn'))
    || (el && el.closest && el.closest('.ctx-menu') && el.closest('.ctx-menu')._splitBtn)
    || null;
  const buttons = split ? [...split.querySelectorAll('button')] : (el ? [el] : []);
  return { split, buttons };
}

// A spawning action (Start Working / Start Review): disable the button, let the
// new session surface via the sidebar poll.
async function spawnAction(btn, method, params, label) {
  const { buttons } = startActionHost(btn);
  buttons.forEach((b) => { b.disabled = true; });
  const orig = btn.textContent;
  btn.textContent = 'Starting…';
  try {
    await rpc(method, params);
    btn.textContent = 'Started ✓';
  } catch (e) {
    buttons.forEach((b) => { b.disabled = false; });
    btn.textContent = orig;
    alertModal(label + ' failed: ' + (e.message || e));
  }
}

// Split-button for Start Working / Start Exploring (CROW-1149). Primary click
// runs `onPrimary`; the chevron opens a ctx-menu of the same actions. Menu
// rows receive `onClick(row)` — not the primary button — so choosing
// Explore shows Starting… / Started ✓ on that row (review #1152).
function startActionsSplit(primaryLabel, onPrimary, items) {
  const wrap = el('div', 'split-btn');
  const main = el('button', 'action-btn action-primary split-btn-main', primaryLabel);
  main.type = 'button';
  main.onclick = (e) => { e.stopPropagation(); onPrimary(main); };
  const chev = el('button', 'action-btn action-primary split-btn-chevron', '▾');
  chev.type = 'button';
  chev.title = 'More start actions';
  chev.setAttribute('aria-label', 'More start actions');
  chev.setAttribute('aria-haspopup', 'menu');
  chev.onclick = (e) => {
    e.stopPropagation();
    closeContextMenu();
    const menu = el('div', 'ctx-menu');
    menu._splitBtn = wrap;
    for (const item of items) {
      const row = el('div', 'ctx-item', item.label);
      if (item.title) row.title = item.title;
      row.onclick = (ev) => {
        ev.stopPropagation();
        // Keep the menu mounted so the chosen row can show Starting… —
        // closing it first would drop the only element whose label matches
        // the action (the primary still reads Start Working).
        [...menu.querySelectorAll('.ctx-item')].forEach((n) => {
          n.style.pointerEvents = 'none';
        });
        item.onClick(row);
      };
      menu.appendChild(row);
    }
    document.body.appendChild(menu);
    const rect = chev.getBoundingClientRect();
    const x = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8);
    const y = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 8);
    menu.style.left = Math.max(4, x) + 'px';
    menu.style.top = Math.max(4, y) + 'px';
    armContextMenuClose();
  };
  wrap.appendChild(main);
  wrap.appendChild(chev);
  return wrap;
}

// -- shared board filter widgets --
// #714: shared board filter input. The board fully re-renders on each keystroke,
// so restore focus + caret after renderBoard() by re-querying the recreated
// input via its `cls`.
function boardFilterInput(cls, value, placeholder, onValue) {
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'board-filter ' + cls;
  input.placeholder = placeholder;
  input.value = value;
  input.oninput = () => {
    const selStart = input.selectionStart;
    const selEnd = input.selectionEnd;
    onValue(input.value);
    renderBoard();
    requestAnimationFrame(() => {
      const n = document.querySelector('.' + cls);
      if (n) {
        n.focus();
        const len = n.value.length;
        n.setSelectionRange(Math.min(selStart, len), Math.min(selEnd, len));
      }
    });
  };
  return input;
}

// #751: shared board <select> control (repo filter / sort). Mutates state via
// onValue then fully re-renders, mirroring boardFilterInput's flow. `options`
// is an array of [value, label] pairs.
function boardSelect(cls, options, value, onValue) {
  const sel = document.createElement('select');
  sel.className = 'board-select ' + cls;
  for (const [val, label] of options) {
    const o = document.createElement('option');
    o.value = val;
    o.textContent = label;
    if (val === value) o.selected = true;
    sel.appendChild(o);
  }
  sel.onchange = () => { onValue(sel.value); renderBoard(); };
  return sel;
}

// In-flight refresh state (CROW-771) — restores the native `isLoadingIssues`
// spinner the web dropped in the native→web move (ADR-0010, CROW-593).
//
// Two sources, OR'd together:
//   • `boardData.tickets.loading` — the daemon's own `isLoadingIssues`, already
//     shipped by `list-tickets`. Covers the *automatic* board poll (and any
//     manual refresh outliving the client's rpc deadline), which is what the
//     native every-minute spinner showed.
//   • `ticketRefreshPending` — local, optimistic. Covers the gap between the
//     click and the first board re-read so the button reacts instantly.
//
// The web re-renders by destroy-and-rebuild, so this must live in module state
// the render functions read — DOM-only state would be wiped by `renderBoard()`.
let ticketRefreshPending = false;
let reviewRefreshPending = false;
function ticketsRefreshing() {
  return ticketRefreshPending || !!(boardData.tickets && boardData.tickets.loading);
}
function reviewsRefreshing() { return reviewRefreshPending; }

// The daemon half of the indicator has no `finally` to fall back on: it clears
// only when a *later* `list-tickets` says so. Lose contact mid-fetch — the
// daemon dies between the in-flight nudge and the completion one, or a board
// read starts failing — and nothing would ever clear it, stranding the spinner.
// So every path that loses authority over the flag drops it (CROW-771, review).
function clearDaemonRefreshFlag() {
  if (!boardData.tickets || !boardData.tickets.loading) return;
  boardData.tickets.loading = false;
  paintRefreshState();
}

// Repaint the surfaces that show the indicator. The local flags aren't part of
// `boardData`, so `refreshBoard`'s diff guard can't see them change.
function paintRefreshState() {
  renderSidebar();
  if (selectedBoard === 'tickets' || selectedBoard === 'reviews') renderBoard();
}

async function refreshTickets() {
  if (ticketRefreshPending) return; // coalesce; tracker.refresh() drops concurrent calls anyway
  ticketRefreshPending = true;
  paintRefreshState();
  try {
    try { await rpc('refresh-tickets'); } catch (_) { /* app down, or past the
      120s deadline — the daemon's own `loading` flag covers the rest; never
      leave the spinner on */ }
    // `refresh-tickets` returns before the fetch lands, so keep the settle
    // delay rather than re-reading an unchanged board.
    await new Promise((r) => setTimeout(r, 1200));
    await refreshBoard('tickets');
  } finally {
    ticketRefreshPending = false;
    paintRefreshState();
  }
}

// Reviews have no "re-poll the provider" RPC — Refresh is a daemon re-read, and
// fresh review data arrives via the poll nudge. Show the indicator for exactly
// that re-read (CROW-771).
async function refreshReviews() {
  if (reviewRefreshPending) return;
  reviewRefreshPending = true;
  paintRefreshState();
  try { await refreshBoard('reviews'); }
  finally {
    reviewRefreshPending = false;
    paintRefreshState();
  }
}
