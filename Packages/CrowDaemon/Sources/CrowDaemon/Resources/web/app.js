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

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let sessions = [];
let selectedId = null;
let terminals = [];
let activeTerminal = null; // { id, name, window }

const STATUS_COLOR = {
  active: 'var(--green)', paused: 'var(--yellow)',
  inReview: 'var(--gold)', completed: 'var(--gold)', archived: 'var(--text-muted)',
};
const AGENT_GLYPH = { 'claude-code': '✦', cursor: '▲', codex: '◆', 'open-code': '◇' };

// Sidebar groups, mirroring AppState's computed groupings. Managers first, as
// in the desktop app.
const GROUPS = [
  { title: 'Managers', match: (s) => s.kind === 'manager' },
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

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function renderSidebar() {
  const root = document.getElementById('sidebar');
  root.innerHTML = '';
  root.appendChild(el('div', 'brand', 'CROW'));
  let shown = 0;
  for (const group of GROUPS) {
    const rows = sessions.filter(group.match);
    if (!rows.length) continue;
    root.appendChild(el('div', 'divider', group.title));
    for (const s of rows) { root.appendChild(sessionRow(s)); shown++; }
  }
  if (!shown) root.appendChild(el('div', 'empty', 'No sessions'));
}

function sessionRow(s) {
  const row = el('div', 'session-row' + (s.id === selectedId ? ' selected' : ''));
  row.onclick = () => selectSession(s.id);

  const top = el('div', 'row-top');
  const dot = el('span', 'dot');
  dot.style.background = STATUS_COLOR[s.status] || 'var(--text-muted)';
  top.appendChild(dot);
  top.appendChild(el('span', 'agent', AGENT_GLYPH[s.agent_kind] || '•'));
  top.appendChild(el('span', 'name', s.name));
  if (s.locked) top.appendChild(el('span', 'lock', '🔒'));
  row.appendChild(top);

  if (s.ticket_title) row.appendChild(el('div', 'subtle', s.ticket_title));
  if (s.repo) row.appendChild(el('div', 'meta', s.repo + (s.branch ? ' · ' + s.branch : '')));
  if (s.ticket_badge) row.appendChild(el('span', 'badge', s.ticket_badge));
  return row;
}

// ---------------------------------------------------------------------------
// Detail + terminal tabs
// ---------------------------------------------------------------------------
async function selectSession(id) {
  selectedId = id;
  document.getElementById('app').classList.add('has-selection');
  renderSidebar();
  renderHeader(sessions.find((x) => x.id === id));
  ensureTerminal();
  await refreshTerminals();
}

function shorten(path) {
  return path.replace(/^\/Users\/[^/]+/, '~').replace(/^\/home\/[^/]+/, '~');
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
  const badge = el('span', 'status-badge', s.status);
  badge.style.color = STATUS_COLOR[s.status] || 'var(--text-muted)';
  top.appendChild(badge);
  root.appendChild(top);

  if (s.ticket_title) root.appendChild(el('div', 'subtle', s.ticket_title));
  const bits = [];
  if (s.repo) bits.push(s.repo);
  if (s.branch) bits.push(s.branch);
  if (s.worktree_path) bits.push(shorten(s.worktree_path));
  if (bits.length) root.appendChild(el('div', 'meta', bits.join(' · ')));
  root.appendChild(el('div', 'meta', 'Agent: ' + (s.agent_display_name || s.agent_kind || '—')));

  // Links row: issue / PR / repo chips, opening in a new tab.
  const links = (s.links || []).slice();
  // Ensure an issue chip from the ticket even when no explicit link is stored.
  if (s.ticket_url && !links.some((l) => l.type === 'ticket')) {
    links.unshift({ label: s.ticket_badge || 'Issue', url: s.ticket_url, type: 'ticket' });
  }
  if (links.length) {
    const row = el('div', 'links-row');
    for (const link of links) {
      const chip = document.createElement('a');
      chip.className = 'link-chip link-' + (link.type || 'custom');
      chip.href = link.url;
      chip.target = '_blank';
      chip.rel = 'noopener';
      chip.textContent = link.label || link.type || 'link';
      row.appendChild(chip);
    }
    root.appendChild(row);
  }

  // Status actions (forwarded to the desktop app when it's running).
  const actions = el('div', 'actions-row');
  for (const [label, value] of [['In Review', 'inReview'], ['Active', 'active'], ['Completed', 'completed']]) {
    if (s.status === value) continue;
    const btn = el('button', 'action-btn', label);
    btn.onclick = () => setStatus(s.id, value);
    actions.appendChild(btn);
  }
  root.appendChild(actions);
}

// Write-actions. Optimistically update local state, then let the store-reload
// poll reconcile with the app's authoritative state.
async function setStatus(id, status) {
  try {
    await rpc('set-status', { session_id: id, status });
    const s = sessions.find((x) => x.id === id);
    if (s) { s.status = status; renderSidebar(); if (id === selectedId) renderHeader(s); }
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] set-status failed: ' + (e.message || e) + '\x1b[0m\r\n');
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
  window.addEventListener('resize', fitTerminal);
  connectTerminalWs();
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
refreshSessions();
setInterval(refreshSessions, 3000);
