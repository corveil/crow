'use strict';
// Crow web UI — SPIKE: structured Chat view for agent sessions.
//
// A read-mostly alternative to the xterm/tmux pane: the daemon tails the
// harness's own transcript (`get-session-transcript`, ChatTranscript.swift) and
// we render it as bubbles with native scrolling. The agent keeps running in
// tmux; the composer types into it through the same `send` RPC the CLI uses.
//
//   #/sessions/:id/chat   — the chat view for a session (router.js)

// Sticky across session switches, so a phone that prefers chat stays in chat.
let chatViewActive = false;
try { chatViewActive = localStorage.getItem('crow.chat.view') === '1'; } catch (_) { /* private mode */ }

const CHAT_POLL_MS = 2000;
// Per-session tail state. Reset whenever the selected session changes.
let chatState = null;
let chatPollTimer = null;
let chatSending = false;

function newChatState(sessionId) {
  return {
    sessionId,
    path: null,
    cursor: null,
    terminalId: null,
    supported: true,
    reason: null,
    truncated: false,
    lastKind: null,
    // tool_id → the <details> a later tool_result is appended into.
    toolNodes: new Map(),
    inflight: false,
    // Phase 2: opt-in headless Claude driver (ClaudeStreamDriver.swift).
    driverEnabled: false,
    driver: null,
    driverBusy: false,
  };
}

function setChatViewActive(on) {
  chatViewActive = !!on;
  try { localStorage.setItem('crow.chat.view', chatViewActive ? '1' : '0'); } catch (_) { /* ignore */ }
}

// Header toggle: flip the mode, rewrite the URL, repaint.
function toggleChatView() {
  setChatViewActive(!chatViewActive);
  if (selectedId) {
    navigate({
      view: 'session',
      sessionId: selectedId,
      terminalId: chatViewActive ? null : (activeTerminal ? activeTerminal.id : null),
      chat: chatViewActive,
    });
  }
  applyChatView();
  const s = sessions.find((x) => x.id === selectedId);
  if (s) renderHeader(s);
}

function chatToggleControl() {
  const wrap = el('div', 'view-toggle');
  wrap.setAttribute('role', 'group');
  wrap.setAttribute('aria-label', 'Session view');
  const mk = (label, iconName, on) => {
    const b = el('button', 'view-toggle-btn' + (on ? ' active' : ''), '');
    b.type = 'button';
    b.setAttribute('aria-pressed', on ? 'true' : 'false');
    b.appendChild(icon(iconName, 12));
    b.appendChild(el('span', null, label));
    b.onclick = (ev) => { ev.stopPropagation(); if (!on) toggleChatView(); };
    return b;
  };
  wrap.appendChild(mk('Terminal', 'terminal', !chatViewActive));
  wrap.appendChild(mk('Chat', 'comment', chatViewActive));
  return wrap;
}

// Called from selectSession (after the session is bound) and on toggle.
function applyChatView() {
  const app = document.getElementById('app');
  const on = chatViewActive && !!selectedId && !selectedBoard;
  app.classList.toggle('chat-active', on);
  if (!on) {
    stopChatPoll();
    // The terminal was display:none while chat was up — refit it.
    if (typeof fitTerminal === 'function') setTimeout(fitTerminal, 30);
    return;
  }
  ensureChatDom();
  if (!chatState || chatState.sessionId !== selectedId) {
    chatState = newChatState(selectedId);
    clearChatLog();
  }
  refreshChat();
  startChatPoll();
}

function startChatPoll() {
  if (chatPollTimer) return;
  chatPollTimer = setInterval(() => {
    if (document.hidden) return;
    if (!chatViewActive || !selectedId || selectedBoard) { stopChatPoll(); return; }
    refreshChat();
  }, CHAT_POLL_MS);
}

function stopChatPoll() {
  if (chatPollTimer) clearInterval(chatPollTimer);
  chatPollTimer = null;
}

function ensureChatDom() {
  let view = document.getElementById('chat-view');
  if (view && view.querySelector('#chat-log')) return view;
  if (!view) {
    view = el('div', null);
    view.id = 'chat-view';
    const wrap = document.getElementById('terminal-wrap');
    if (wrap && wrap.parentNode) wrap.parentNode.insertBefore(view, wrap.nextSibling);
    else document.getElementById('detail').appendChild(view);
  }
  const log = el('div', null);
  log.id = 'chat-log';
  log.setAttribute('role', 'log');
  log.setAttribute('aria-live', 'polite');
  view.appendChild(log);

  const status = el('div', 'chat-status');
  status.id = 'chat-status';
  view.appendChild(status);

  const form = el('form', 'chat-composer');
  form.id = 'chat-composer';
  const input = document.createElement('textarea');
  input.id = 'chat-input';
  input.rows = 1;
  input.placeholder = 'Message the agent…';
  input.setAttribute('aria-label', 'Message the agent');
  input.addEventListener('input', () => autosizeChatInput(input));
  input.addEventListener('keydown', (e) => {
    // Desktop: Enter sends, Shift+Enter is a newline. Touch keyboards have no
    // Shift habit, so there Enter is a newline and the button sends.
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && !isCoarsePointer()) {
      e.preventDefault();
      sendChatMessage();
    }
  });
  const send = el('button', 'chat-send', 'Send');
  send.type = 'submit';
  send.id = 'chat-send';
  form.appendChild(input);
  form.appendChild(send);
  form.onsubmit = (e) => { e.preventDefault(); sendChatMessage(); };
  view.appendChild(form);

  // Sticky-bottom bookkeeping: the user scrolling up releases the pin.
  log.addEventListener('scroll', () => {
    const jump = document.getElementById('chat-jump');
    if (jump) jump.hidden = chatNearBottom(log);
  }, { passive: true });
  const jump = el('button', 'chat-jump', '↓ Latest');
  jump.id = 'chat-jump';
  jump.type = 'button';
  jump.hidden = true;
  jump.onclick = () => { log.scrollTop = log.scrollHeight; jump.hidden = true; };
  view.appendChild(jump);
  return view;
}

function isCoarsePointer() {
  try { return window.matchMedia && window.matchMedia('(pointer: coarse)').matches; } catch (_) { return false; }
}

function autosizeChatInput(input) {
  input.style.height = 'auto';
  input.style.height = Math.min(input.scrollHeight, 160) + 'px';
}

function clearChatLog() {
  const log = document.getElementById('chat-log');
  if (log) log.innerHTML = '';
  renderChatStatus();
}

function chatNearBottom(log) {
  return log.scrollHeight - log.scrollTop - log.clientHeight < 80;
}

async function refreshChat() {
  const st = chatState;
  if (!st || st.inflight) return;
  st.inflight = true;
  try {
    const params = { session_id: st.sessionId };
    if (st.cursor != null) params.cursor = st.cursor;
    if (st.path) params.path = st.path;
    const res = await rpc('get-session-transcript', params);
    if (chatState !== st) return; // session switched mid-flight
    applyChatPage(st, res || {});
  } catch (e) {
    if (chatState !== st) return;
    st.reason = (e && e.message) || 'Could not read the transcript.';
    renderChatStatus();
  } finally {
    st.inflight = false;
  }
}

// Merge one RPC page into the DOM. Exposed (unprefixed) for web-tests.
function applyChatPage(st, res) {
  const log = document.getElementById('chat-log');
  st.supported = res.supported !== false;
  st.reason = res.reason || null;
  st.terminalId = res.terminal_id || st.terminalId;
  st.driverEnabled = !!res.driver_enabled;
  st.driver = res.driver || null;
  if (res.reset) {
    if (log) log.innerHTML = '';
    st.toolNodes = new Map();
    st.lastKind = null;
    st.truncated = !!res.truncated;
  }
  if (res.path) st.path = res.path;
  if (typeof res.cursor === 'number') st.cursor = res.cursor;
  const events = res.events || [];
  if (log && events.length) {
    const pinned = res.reset || chatNearBottom(log);
    if (res.reset && st.truncated) {
      log.appendChild(el('div', 'chat-notice', 'Earlier messages are in the terminal history.'));
    }
    for (const ev of events) appendChatEvent(st, log, ev);
    if (pinned) log.scrollTop = log.scrollHeight;
    else {
      const jump = document.getElementById('chat-jump');
      if (jump) jump.hidden = false;
    }
  }
  renderChatStatus(st);
}

function appendChatEvent(st, log, ev) {
  switch (ev.kind) {
    case 'user':
      log.appendChild(chatBubble('user', ev.text));
      break;
    case 'assistant':
      log.appendChild(chatBubble('assistant', ev.text));
      break;
    case 'tool_call': {
      const d = document.createElement('details');
      d.className = 'chat-tool';
      const sum = document.createElement('summary');
      sum.appendChild(el('span', 'chat-tool-name', ev.tool_name || 'tool'));
      sum.appendChild(el('span', 'chat-tool-input', ev.text || ''));
      d.appendChild(sum);
      if (ev.text && ev.text.length > 60) d.appendChild(el('pre', 'chat-tool-full', ev.text));
      log.appendChild(d);
      if (ev.tool_id) st.toolNodes.set(ev.tool_id, d);
      break;
    }
    case 'tool_result': {
      const host = ev.tool_id && st.toolNodes.get(ev.tool_id);
      const pre = el('pre', 'chat-tool-result' + (ev.is_error ? ' error' : ''), ev.text || '(no output)');
      if (host) {
        host.appendChild(pre);
        if (ev.is_error) host.classList.add('error');
        st.toolNodes.delete(ev.tool_id);
      } else {
        // An orphan (a `!` shell command's stdout, or a call before the tail window).
        const d = document.createElement('details');
        d.className = 'chat-tool' + (ev.is_error ? ' error' : '');
        const sum = document.createElement('summary');
        sum.appendChild(el('span', 'chat-tool-name', 'output'));
        sum.appendChild(el('span', 'chat-tool-input', (ev.text || '').split('\n')[0]));
        d.appendChild(sum);
        d.appendChild(pre);
        log.appendChild(d);
      }
      break;
    }
    case 'turn_end':
      if (st.lastKind === 'turn_end') return; // the harness can mark one turn twice
      log.appendChild(el('div', 'chat-turn-end',
        ev.duration_ms ? ('Done · ' + formatChatDuration(ev.duration_ms)) : 'Done'));
      break;
    case 'notice':
      log.appendChild(el('div', 'chat-notice', ev.text || ''));
      break;
    default:
      return;
  }
  st.lastKind = ev.kind;
}

function formatChatDuration(ms) {
  const s = Math.round(ms / 1000);
  if (s < 60) return s + 's';
  return Math.floor(s / 60) + 'm ' + (s % 60) + 's';
}

function chatBubble(role, text) {
  const b = el('div', 'chat-msg chat-' + role);
  renderChatMarkdown(b, text || '');
  return b;
}

// Deliberately tiny markdown: fenced code blocks, inline `code`, **bold**.
// Builds DOM nodes (never innerHTML) — transcripts carry attacker-reachable
// text (tool output, PR bodies in review sessions).
function renderChatMarkdown(root, text) {
  const parts = text.split(/```/);
  parts.forEach((part, i) => {
    if (i % 2 === 1) {
      // Drop the language tag on the fence's first line.
      const body = part.replace(/^[^\n]*\n/, '');
      root.appendChild(el('pre', 'chat-code', body.replace(/\n$/, '')));
      return;
    }
    const paras = part.split(/\n{2,}/);
    for (const p of paras) {
      if (!p.trim()) continue;
      const para = el('p', null);
      appendInline(para, p.replace(/^\n+|\n+$/g, ''));
      root.appendChild(para);
    }
  });
}

function appendInline(parent, text) {
  const re = /(`[^`\n]+`|\*\*[^*\n]+\*\*)/g;
  let last = 0;
  let m;
  while ((m = re.exec(text))) {
    if (m.index > last) parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    const tok = m[0];
    if (tok[0] === '`') parent.appendChild(el('code', null, tok.slice(1, -1)));
    else parent.appendChild(el('strong', null, tok.slice(2, -2)));
    last = m.index + tok.length;
  }
  if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
}

function renderChatStatus(stArg) {
  const status = document.getElementById('chat-status');
  if (!status) return;
  const st = stArg || chatState;
  status.className = 'chat-status';
  status.textContent = '';
  const send = document.getElementById('chat-send');
  const input = document.getElementById('chat-input');
  const hasTarget = !!(st && (st.terminalId || chatDriverRunning(st)));
  if (send) send.disabled = !hasTarget || chatSending;
  if (input) {
    input.disabled = !hasTarget;
    input.placeholder = st && chatDriverRunning(st) ? 'Message headless Claude…' : 'Message the agent…';
  }
  if (!st) return;
  renderChatDriver(st, status);
  if (!st.supported || (st.reason && st.cursor == null)) {
    status.appendChild(el('span', null, st.reason || 'Chat view is not available for this session.'));
    status.classList.add('warn');
    return;
  }
  if (st.driver && st.driver.pending && st.driver.pending.length) {
    status.classList.add('busy');
    status.appendChild(el('span', null, 'Waiting for your approval'));
    return;
  }
  // No structured "busy" signal reaches the browser yet, so infer it: anything
  // after the last turn end means the agent is mid-turn.
  if (st.lastKind && st.lastKind !== 'turn_end') {
    status.appendChild(el('span', 'action-spinner'));
    status.appendChild(el('span', null, 'Working…'));
    status.classList.add('busy');
  }
}

async function sendChatMessage() {
  const input = document.getElementById('chat-input');
  const st = chatState;
  if (!input || !st || !st.terminalId || chatSending) return;
  const text = input.value.replace(/\s+$/, '');
  if (!text) return;
  chatSending = true;
  renderChatStatus();
  try {
    if (chatDriverRunning(st)) {
      await rpc('chat-driver-send', { session_id: st.sessionId, text });
    } else {
      // Trailing newline = Enter after the bracketed paste (TmuxInput.sendText).
      await rpc('send', { session_id: st.sessionId, terminal_id: st.terminalId, text: text + '\n' });
    }
    input.value = '';
    autosizeChatInput(input);
    const log = document.getElementById('chat-log');
    if (log) log.scrollTop = log.scrollHeight;
    // The harness writes the user line within a beat; don't wait for the poll.
    setTimeout(refreshChat, 400);
  } catch (e) {
    alertModal('Send failed: ' + ((e && e.message) || e));
  } finally {
    chatSending = false;
    renderChatStatus();
  }
}

// ---------------------------------------------------------------------------
// Phase 2: headless driver controls. Rendered above the status line: a start
// button when crowd has CROW_CHAT_DRIVER=1, then a banner + permission cards
// while the driver runs. Approvals are the one thing the TUI path cannot offer
// here — in tmux, a permission prompt is only answerable in the terminal.
// ---------------------------------------------------------------------------
function chatDriverRunning(st) {
  return !!(st && st.driver && st.driver.running);
}

function renderChatDriver(st, status) {
  let bar = document.getElementById('chat-driver');
  if (!bar) {
    bar = el('div', 'chat-driver');
    bar.id = 'chat-driver';
    if (status.parentNode) status.parentNode.insertBefore(bar, status);
  }
  bar.innerHTML = '';
  bar.hidden = !(st.driverEnabled || st.driver);
  if (bar.hidden) return;
  if (!chatDriverRunning(st)) {
    bar.appendChild(el('span', 'chat-driver-label', 'Experimental: run Claude headless (no TUI) for this session.'));
    const start = el('button', 'chat-driver-btn', st.driverBusy ? 'Starting…' : 'Start headless');
    start.type = 'button';
    start.disabled = st.driverBusy;
    start.onclick = () => chatDriverAction(st, 'chat-driver-start', {});
    bar.appendChild(start);
    return;
  }
  bar.appendChild(el('span', 'chat-driver-label', 'Headless Claude · new conversation'));
  const stop = el('button', 'chat-driver-btn', 'Stop');
  stop.type = 'button';
  stop.onclick = () => chatDriverAction(st, 'chat-driver-stop', {});
  bar.appendChild(stop);
  for (const p of (st.driver.pending || [])) {
    const card = el('div', 'chat-permission');
    const what = el('div', 'chat-permission-what');
    what.appendChild(el('span', 'chat-tool-name', p.tool_name));
    what.appendChild(el('span', 'chat-tool-input', p.summary || ''));
    card.appendChild(what);
    const allow = el('button', 'chat-driver-btn primary', 'Allow');
    allow.type = 'button';
    allow.onclick = () => chatDriverAction(st, 'chat-driver-permission', { request_id: p.request_id, allow: true });
    const deny = el('button', 'chat-driver-btn', 'Deny');
    deny.type = 'button';
    deny.onclick = () => chatDriverAction(st, 'chat-driver-permission', { request_id: p.request_id, allow: false });
    card.appendChild(allow);
    card.appendChild(deny);
    bar.appendChild(card);
  }
}

async function chatDriverAction(st, method, extra) {
  if (st.driverBusy) return;
  st.driverBusy = true;
  renderChatStatus(st);
  try {
    await rpc(method, Object.assign({ session_id: st.sessionId }, extra));
  } catch (e) {
    alertModal('Chat driver: ' + ((e && e.message) || e));
  } finally {
    st.driverBusy = false;
    refreshChat();
  }
}
