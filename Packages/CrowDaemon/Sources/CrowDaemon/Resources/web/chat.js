'use strict';
// Crow web UI — Chat view: a structured alternative to the terminal pane.
//
// The daemon tails the harness's own transcript (`get-session-transcript`,
// ChatTranscript.swift) and we render it as bubbles with native scrolling. The
// agent keeps running in tmux; the composer types into it through the same
// `send` RPC the CLI uses. Claude sessions also get a `/` menu
// (`list-chat-commands`) and a context meter. Nothing here runs, and nothing is
// fetched, until a session is switched to Chat.
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
// Whether the last applyChatView showed chat — the terminal only needs a refit
// when we actually leave chat, not on every terminal-mode session switch.
let chatWasShown = false;
// Unsent composer text per session, so switching sessions never carries a
// draft (and a Send) over to the wrong agent.
const chatDrafts = new Map();

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
    agentKind: null,
    // Context meter: the latest `usage` the daemon reported (kept across pages
    // that carry none).
    usage: null,
    // `/` menu entries; null until fetched for this session.
    commands: null,
    commandsLoading: false,
    // Focus the composer as soon as it is enabled (set on session switch).
    wantFocus: false,
    // ↑/↓ prompt recall: this session's user messages, oldest first, with
    // consecutive repeats collapsed; `histPos` is the entry on screen.
    history: [],
    histPos: null,
  };
}

// `crow ui set --chat-view` / Settings → General. Strictly on: the header toggle
// shows only once the config says so.
function chatViewEnabled() {
  return typeof uiConfig !== 'undefined' && uiConfig.chatViewEnabled === true;
}

// Not known to be off: a sticky Chat mode may apply while the config is still
// loading, so an enabled install doesn't flash the terminal first.
function chatViewNotDisabled() {
  return !(typeof uiConfig !== 'undefined' && uiConfig.chatViewEnabled === false);
}

// What the URL and the view should show right now.
function chatViewShown() {
  return chatViewActive && chatViewNotDisabled();
}

// The UI config loaded or changed (boot, Settings save, `crow ui set`). Re-apply
// the view and the header; turning the flag off sends Chat back to the
// terminal, URL included.
function onChatConfigLoaded() {
  if (!selectedId || selectedBoard) return;
  const shown = currentRoute();
  if (!chatViewNotDisabled() && shown && shown.view === 'session' && shown.chat) {
    navigate({ view: 'session', sessionId: selectedId,
      terminalId: activeTerminal ? activeTerminal.id : null }, { replace: true });
  }
  applyChatView();
  const s = sessions.find((x) => x.id === selectedId);
  if (s) renderHeader(s);
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
  if (!chatViewEnabled()) return null;
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
  const on = chatViewShown() && !!selectedId && !selectedBoard;
  app.classList.toggle('chat-active', on);
  if (!on) {
    stopChatPoll();
    closeChatMenu();
    // The terminal was display:none while chat was up — refit it.
    if (chatWasShown && typeof fitTerminal === 'function') setTimeout(fitTerminal, 30);
    chatWasShown = false;
    return;
  }
  const entering = !chatWasShown;
  chatWasShown = true;
  ensureChatDom();
  const switched = !chatState || chatState.sessionId !== selectedId;
  if (switched) {
    const input = document.getElementById('chat-input');
    if (input && chatState) chatDrafts.set(chatState.sessionId, input.value);
    chatState = newChatState(selectedId);
    clearChatLog();
    if (input) {
      input.value = chatDrafts.get(selectedId) || '';
      autosizeChatInput(input);
      closeChatMenu();
    }
  }
  if (switched || entering) {
    chatState.wantFocus = true;
    maybeFocusChatInput(chatState);
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
  input.addEventListener('input', () => { autosizeChatInput(input); updateChatMenu(); });
  input.addEventListener('click', () => updateChatMenu());
  input.addEventListener('blur', () => { setTimeout(closeChatMenu, 150); });
  input.addEventListener('keydown', (e) => {
    if (chatMenuKeydown(e)) return;
    if (chatHistoryKeydown(e, input)) return;
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
  const menu = el('div', 'chat-menu');
  menu.id = 'chat-menu';
  menu.setAttribute('role', 'listbox');
  menu.setAttribute('aria-label', 'Commands and skills');
  menu.hidden = true;
  input.setAttribute('aria-controls', 'chat-menu');
  input.setAttribute('aria-autocomplete', 'list');
  form.appendChild(menu);
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

// Put the caret in the composer after a session switch (or opening Chat) so
// typing can start at once. Desktop only: on a phone it would throw the
// keyboard over the conversation. Never steals focus from another text field,
// a modal, or the session switcher. Retried from applyChatPage, because the
// composer stays disabled until the first transcript page names a target.
function maybeFocusChatInput(st) {
  if (!st || !st.wantFocus || chatState !== st) return;
  const input = document.getElementById('chat-input');
  if (!input || input.disabled) return;
  st.wantFocus = false;
  if (isCoarsePointer()) return;
  const ae = document.activeElement;
  if (ae && ae !== input && ae !== document.body
    && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA' || ae.isContentEditable)) return;
  if (document.querySelector('.text-prompt-backdrop, .modal-dialog-backdrop')) return;
  const sw = document.getElementById('session-switcher');
  if (sw && !sw.hidden) return;
  if (window.settingsIsOpen && window.settingsIsOpen()) return;
  try { input.focus({ preventScroll: true }); } catch (_) { input.focus(); }
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

// ---------------------------------------------------------------------------
// Markdown (markdown-it 14.1.1, vendored at /markdown-it.min.js). Loaded on the
// first Chat open only — the terminal view never fetches it. `html: false`
// escapes any raw HTML in the source (transcripts carry text other people
// wrote: tool output, PR bodies in review sessions), and links are limited to
// http(s)/mailto, matching the header's link chips.
// ---------------------------------------------------------------------------
let chatMd = null;
let chatMdReady = null;

function loadChatMarkdown() {
  if (chatMdReady) return chatMdReady;
  chatMdReady = new Promise((resolve) => {
    if (typeof window.markdownit === 'function') { resolve(); return; }
    const tag = document.createElement('script');
    tag.src = '/markdown-it.min.js';
    tag.onload = () => resolve();
    tag.onerror = () => resolve(); // fall back to the minimal renderer
    document.head.appendChild(tag);
  }).then(() => { chatMd = buildChatMarkdown(); });
  return chatMdReady;
}

function buildChatMarkdown() {
  if (typeof window.markdownit !== 'function') return null;
  const md = window.markdownit({ html: false, linkify: true, breaks: true });
  md.validateLink = (url) => /^(https?:|mailto:)/i.test(String(url).trim());
  const linkOpen = md.renderer.rules.link_open
    || ((tokens, idx, opts, env, self) => self.renderToken(tokens, idx, opts));
  md.renderer.rules.link_open = (tokens, idx, opts, env, self) => {
    tokens[idx].attrSet('target', '_blank');
    tokens[idx].attrSet('rel', 'noopener noreferrer');
    return linkOpen(tokens, idx, opts, env, self);
  };
  // CSP (img-src 'self') blocks remote images anyway; show them as links.
  md.renderer.rules.image = (tokens, idx) => {
    const t = tokens[idx];
    const src = t.attrGet('src') || '';
    const alt = md.utils.escapeHtml(t.content || src);
    if (!md.validateLink(src)) return alt;
    return '<a href="' + md.utils.escapeHtml(src) + '" target="_blank" rel="noopener noreferrer">' + alt + '</a>';
  };
  return md;
}

// Plain text with bare URLs made clickable — for tool output and notices,
// which are not markdown.
function appendLinkified(parent, text) {
  const matches = chatMd && chatMd.linkify.test(text) ? (chatMd.linkify.match(text) || []) : [];
  let last = 0;
  for (const m of matches) {
    if (!/^(https?:|mailto:)/i.test(m.url)) continue;
    if (m.index > last) parent.appendChild(document.createTextNode(text.slice(last, m.index)));
    const a = el('a', null, m.text);
    a.href = m.url;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    parent.appendChild(a);
    last = m.lastIndex;
  }
  if (last < text.length) parent.appendChild(document.createTextNode(text.slice(last)));
  return parent;
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
    await loadChatMarkdown();
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
  if (res.agent_kind) st.agentKind = res.agent_kind;
  if (res.usage) st.usage = res.usage;
  else if (res.reset) st.usage = null;
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
  maybeFocusChatInput(st);
}

function appendChatEvent(st, log, ev) {
  switch (ev.kind) {
    case 'user':
      log.appendChild(chatBubble('user', ev.text));
      pushChatHistory(st, ev.text);
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
      const pre = appendLinkified(el('pre', 'chat-tool-result' + (ev.is_error ? ' error' : '')), ev.text || '(no output)');
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
      log.appendChild(appendLinkified(el('div', 'chat-notice'), ev.text || ''));
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

function renderChatMarkdown(root, text) {
  if (chatMd) {
    root.classList.add('md');
    // Safe as innerHTML: html:false escapes source HTML, validateLink gates hrefs.
    root.innerHTML = chatMd.render(text);
    return;
  }
  renderChatMarkdownFallback(root, text);
}

// Fallback when markdown-it failed to load: fenced code, inline `code`,
// **bold** — built as DOM nodes, never innerHTML.
function renderChatMarkdownFallback(root, text) {
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
  const hasTarget = !!(st && st.terminalId);
  if (send) send.disabled = !hasTarget || chatSending;
  if (input) input.disabled = !hasTarget;
  if (!st) return;
  renderChatMeta(st);
  if (!st.supported || (st.reason && st.cursor == null)) {
    status.appendChild(el('span', null, st.reason || 'Chat view is not available for this session.'));
    status.classList.add('warn');
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
    // Trailing newline = Enter after the bracketed paste (TmuxInput.sendText).
    await rpc('send', { session_id: st.sessionId, terminal_id: st.terminalId, text: text + '\n' });
    input.value = '';
    autosizeChatInput(input);
    closeChatMenu();
    pushChatHistory(st, text);
    st.histPos = null;
    chatDrafts.delete(st.sessionId);
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
// `/` menu (Claude sessions). Typing `/` at the very start of the composer
// opens a filtered list of skills, slash commands and built-ins from
// `list-chat-commands`. Picking one only inserts `/name ` — Claude Code expands
// it when the message arrives through the TUI (`send`). Claude expands one
// skill per message, so the menu only triggers on the leading token.
// ---------------------------------------------------------------------------
const CHAT_MENU_LIMIT = 50;
let chatMenuItems = [];
let chatMenuIndex = 0;

// The `/token` being typed, when the caret is still inside it; else null.
function chatSlashQuery(input) {
  const v = input.value;
  if (!v.startsWith('/')) return null;
  const caret = input.selectionStart == null ? v.length : input.selectionStart;
  const head = v.slice(0, caret);
  if (/\s/.test(head)) return null;
  return head.slice(1);
}

function chatMenuSupported(st) {
  return !!st && st.agentKind === 'claude-code';
}

const CHAT_COMMANDS_RETRY_MS = 30000;

async function loadChatCommands(st) {
  if (st.commands || st.commandsLoading) return;
  // A failed fetch (e.g. a daemon too old to know the RPC) waits before
  // retrying, so the menu's own re-render can't turn into a request loop.
  if (st.commandsFailedAt && Date.now() - st.commandsFailedAt < CHAT_COMMANDS_RETRY_MS) return;
  st.commandsLoading = true;
  try {
    const res = await rpc('list-chat-commands', { session_id: st.sessionId });
    st.commands = (res && res.supported && Array.isArray(res.commands)) ? res.commands : [];
    st.commandsFailedAt = 0;
  } catch (_) {
    st.commands = null;
    st.commandsFailedAt = Date.now();
  } finally {
    st.commandsLoading = false;
  }
  if (chatState === st) updateChatMenu();
}

// Prefix matches first, then substring-in-name, then description matches.
function filterChatCommands(commands, query) {
  const q = (query || '').toLowerCase();
  if (!q) return commands.slice(0, CHAT_MENU_LIMIT);
  const prefix = [], inName = [], inDesc = [];
  for (const c of commands) {
    const n = c.name.toLowerCase();
    if (n.startsWith(q)) prefix.push(c);
    else if (n.includes(q)) inName.push(c);
    else if ((c.description || '').toLowerCase().includes(q)) inDesc.push(c);
  }
  return prefix.concat(inName, inDesc).slice(0, CHAT_MENU_LIMIT);
}

function updateChatMenu() {
  const input = document.getElementById('chat-input');
  const st = chatState;
  if (!input || !chatMenuSupported(st)) { closeChatMenu(); return; }
  const query = chatSlashQuery(input);
  if (query == null) { closeChatMenu(); return; }
  if (!st.commands) {
    loadChatCommands(st);
    if (st.commandsFailedAt && !st.commandsLoading) {
      renderChatMenuMessage('Commands are unavailable right now');
    } else {
      renderChatMenu([], true);
    }
    return;
  }
  const items = filterChatCommands(st.commands, query);
  const prevName = chatMenuItems[chatMenuIndex] && chatMenuItems[chatMenuIndex].name;
  chatMenuItems = items;
  const keep = items.findIndex((c) => c.name === prevName);
  chatMenuIndex = keep >= 0 ? keep : 0;
  renderChatMenu(items, false);
}

function renderChatMenu(items, loading) {
  const menu = document.getElementById('chat-menu');
  const input = document.getElementById('chat-input');
  if (!menu) return;
  menu.innerHTML = '';
  if (loading) {
    menu.appendChild(el('div', 'chat-menu-empty', 'Loading commands…'));
  } else if (!items.length) {
    menu.appendChild(el('div', 'chat-menu-empty', 'No matching skills or commands'));
  }
  items.forEach((c, i) => {
    const opt = el('div', 'chat-menu-item' + (i === chatMenuIndex ? ' active' : ''));
    opt.id = 'chat-menu-opt-' + i;
    opt.setAttribute('role', 'option');
    opt.setAttribute('aria-selected', i === chatMenuIndex ? 'true' : 'false');
    const top = el('div', 'chat-menu-top');
    top.appendChild(el('span', 'chat-menu-name', '/' + c.name));
    top.appendChild(el('span', 'chat-menu-kind', c.kind === 'builtin' ? 'built-in' : c.scope + ' ' + c.kind));
    opt.appendChild(top);
    if (c.description) opt.appendChild(el('div', 'chat-menu-desc', c.description));
    // pointerdown + preventDefault keeps the textarea focused (and the phone
    // keyboard up) through the tap.
    opt.addEventListener('pointerdown', (e) => e.preventDefault());
    opt.addEventListener('mousedown', (e) => e.preventDefault());
    opt.addEventListener('click', () => { chatMenuIndex = i; selectChatMenuItem(); });
    menu.appendChild(opt);
  });
  menu.hidden = false;
  if (input) {
    input.setAttribute('aria-expanded', 'true');
    if (items.length) input.setAttribute('aria-activedescendant', 'chat-menu-opt-' + chatMenuIndex);
  }
  const active = menu.querySelector('.chat-menu-item.active');
  if (active && active.scrollIntoView) active.scrollIntoView({ block: 'nearest' });
}

function renderChatMenuMessage(text) {
  const menu = document.getElementById('chat-menu');
  if (!menu) return;
  chatMenuItems = [];
  menu.innerHTML = '';
  menu.appendChild(el('div', 'chat-menu-empty', text));
  menu.hidden = false;
}

function closeChatMenu() {
  const menu = document.getElementById('chat-menu');
  const input = document.getElementById('chat-input');
  chatMenuItems = [];
  chatMenuIndex = 0;
  if (menu) { menu.hidden = true; menu.innerHTML = ''; }
  if (input) { input.setAttribute('aria-expanded', 'false'); input.removeAttribute('aria-activedescendant'); }
}

function chatMenuOpen() {
  const menu = document.getElementById('chat-menu');
  return !!(menu && !menu.hidden);
}

// Returns true when the key was the menu's to handle.
function chatMenuKeydown(e) {
  if (!chatMenuOpen() || e.isComposing) return false;
  if (e.key === 'Escape') { e.preventDefault(); closeChatMenu(); return true; }
  if (!chatMenuItems.length) return false;
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    const n = chatMenuItems.length;
    chatMenuIndex = (chatMenuIndex + (e.key === 'ArrowDown' ? 1 : n - 1)) % n;
    renderChatMenu(chatMenuItems, false);
    return true;
  }
  if ((e.key === 'Enter' && !e.shiftKey) || e.key === 'Tab') {
    e.preventDefault();
    selectChatMenuItem();
    return true;
  }
  return false;
}

// Replace the leading `/token` with `/name `, keeping anything typed after it.
function selectChatMenuItem() {
  const input = document.getElementById('chat-input');
  const item = chatMenuItems[chatMenuIndex];
  if (!input || !item) return;
  const v = input.value;
  const m = v.match(/^\/\S*/);
  const rest = m ? v.slice(m[0].length).replace(/^\s+/, '') : v;
  const head = '/' + item.name + ' ';
  input.value = head + rest;
  try { input.setSelectionRange(head.length, head.length); } catch (_) { /* jsdom */ }
  closeChatMenu();
  autosizeChatInput(input);
  input.focus();
}

// ---------------------------------------------------------------------------
// Prompt history (↑/↓), after T3 Code's composerPromptHistory: recall only
// starts from an empty composer (or the entry already recalled, unedited), so
// a draft is never overwritten; ↑ needs the caret on the first line and ↓ on
// the last, so multi-line editing keeps normal arrow movement.
// ---------------------------------------------------------------------------
const CHAT_HISTORY_LIMIT = 200;

function pushChatHistory(st, text) {
  const t = String(text || '').trim();
  if (!t) return;
  const h = st.history;
  if (h[h.length - 1] === t) return;
  h.push(t);
  if (h.length > CHAT_HISTORY_LIMIT) h.splice(0, h.length - CHAT_HISTORY_LIMIT);
}

// Returns true when the key was a history step.
function chatHistoryKeydown(e, input) {
  if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return false;
  if (e.shiftKey || e.altKey || e.ctrlKey || e.metaKey || e.isComposing) return false;
  const st = chatState;
  if (!st || !st.history.length) return false;
  const v = input.value;
  const pos = st.histPos && st.histPos.recalled === v ? st.histPos : null;
  if (!pos && v.length > 0) return false; // a draft: leave the arrows alone
  const caret = input.selectionStart == null ? v.length : input.selectionStart;
  const h = st.history;
  let next;
  if (e.key === 'ArrowUp') {
    if (v.slice(0, caret).includes('\n')) return false;
    next = pos ? pos.index - 1 : h.length - 1;
    if (next < 0) { e.preventDefault(); return true; } // oldest: stay put
  } else {
    if (!pos) return false;
    if (v.slice(caret).includes('\n')) return false;
    next = pos.index + 1;
  }
  e.preventDefault();
  if (next >= h.length) {
    st.histPos = null;
    input.value = '';
  } else {
    st.histPos = { index: next, recalled: h[next] };
    input.value = h[next];
  }
  try { input.setSelectionRange(input.value.length, input.value.length); } catch (_) { /* jsdom */ }
  autosizeChatInput(input);
  closeChatMenu();
  return true;
}

// ---------------------------------------------------------------------------
// Context meter: a small row under the composer with the model and a ring of
// how full the context window is. Used tokens are the latest main-conversation
// call's prompt tokens; the window comes from the transcript (Codex) or the
// daemon's model table — and when neither knows it,
// the row shows a token count with no percentage. Tap/hover for detail.
// ---------------------------------------------------------------------------
function formatChatTokens(n) {
  if (n == null || !isFinite(n)) return '0';
  if (n < 1000) return String(Math.round(n));
  if (n < 10000) return (n / 1000).toFixed(1).replace(/\.0$/, '') + 'k';
  if (n < 999500) return Math.round(n / 1000) + 'k';
  return (n / 1e6).toFixed(1).replace(/\.0$/, '') + 'M';
}

// `claude-opus-5-5` → `Opus 5.5`; anything else is shown as-is.
function formatChatModel(model) {
  if (!model) return '';
  const m = String(model).match(/^claude-([a-z]+)-(\d+)-(\d+)(\[1m\])?/i);
  if (!m) return String(model);
  return m[1].charAt(0).toUpperCase() + m[1].slice(1) + ' ' + m[2] + '.' + m[3] + (m[4] ? ' (1M)' : '');
}

function chatUsagePercent(u) {
  if (!u || !u.max_tokens || u.max_tokens <= 0) return null;
  return Math.min(100, (u.used_tokens / u.max_tokens) * 100);
}

// Survives the poll's re-render, so a tapped-open detail stays open.
let chatMeterOpen = false;

// The meter lives in the session header's "Agent:" row (renderHeader calls
// chatHeaderMeter). The header is rebuilt on its own schedule, so the slot is
// recreated there and refilled here whenever a transcript page lands.
function chatHeaderMeter(sessionId) {
  const slot = el('span', 'chat-meta chat-header-meter');
  slot.id = 'chat-header-meter';
  // Clicks here must not open the Agent row's handoff menu.
  slot.addEventListener('click', (e) => e.stopPropagation());
  const st = chatState;
  fillChatMeter(slot, chatViewShown() && st && st.sessionId === sessionId ? st : null);
  return slot;
}

function renderChatMeta(st) {
  const slot = document.getElementById('chat-header-meter');
  if (!slot) return;
  fillChatMeter(slot, chatViewShown() && chatState === st ? st : null);
}

function fillChatMeter(meta, st) {
  const u = st && st.usage;
  meta.innerHTML = '';
  meta.hidden = !u;
  if (!u) return;
  if (u.model) meta.appendChild(el('span', 'chat-meta-model', formatChatModel(u.model)));
  const pct = chatUsagePercent(u);
  const btn = el('button', 'chat-meter' + (pct != null && pct > 90 ? ' over' : '') + (chatMeterOpen ? ' open' : ''), '');
  btn.type = 'button';
  const detail = pct != null
    ? formatChatTokens(u.used_tokens) + ' / ' + formatChatTokens(u.max_tokens) + ' tokens'
    : formatChatTokens(u.used_tokens) + ' tokens used';
  btn.title = 'Context window: ' + detail;
  btn.setAttribute('aria-label', pct != null
    ? 'Context window ' + Math.round(pct) + '% used'
    : 'Context window ' + formatChatTokens(u.used_tokens) + ' tokens used');
  if (pct != null) {
    const r = 7, c = 2 * Math.PI * r;
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    svg.setAttribute('viewBox', '0 0 18 18');
    svg.setAttribute('class', 'chat-meter-ring');
    svg.setAttribute('aria-hidden', 'true');
    const track = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    const fill = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    for (const node of [track, fill]) {
      node.setAttribute('cx', '9'); node.setAttribute('cy', '9'); node.setAttribute('r', String(r));
    }
    track.setAttribute('class', 'track');
    fill.setAttribute('class', 'fill');
    fill.setAttribute('stroke-dasharray', String(c));
    fill.setAttribute('stroke-dashoffset', String(c * (1 - pct / 100)));
    svg.appendChild(track);
    svg.appendChild(fill);
    btn.appendChild(svg);
    btn.appendChild(el('span', 'chat-meter-pct', pct < 10 ? pct.toFixed(1).replace(/\.0$/, '') + '%' : Math.round(pct) + '%'));
  } else {
    btn.appendChild(el('span', 'chat-meter-pct', formatChatTokens(u.used_tokens) + ' tokens'));
  }
  const pop = el('span', 'chat-meter-detail', detail);
  btn.appendChild(pop);
  // Hover shows the detail on desktop (CSS); a tap toggles it on touch.
  btn.setAttribute('aria-expanded', chatMeterOpen ? 'true' : 'false');
  btn.onclick = () => {
    chatMeterOpen = !chatMeterOpen;
    btn.classList.toggle('open', chatMeterOpen);
    btn.setAttribute('aria-expanded', chatMeterOpen ? 'true' : 'false');
  };
  meta.appendChild(btn);
}
