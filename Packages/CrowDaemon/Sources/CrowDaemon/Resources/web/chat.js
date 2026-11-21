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
    stopChatSpeech();
    cancelChatFollow(); // Follow never pulls you back off a board or the terminal
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
    stopChatSpeech();
    // Only the switch Follow made reads the backlog; any other switch drops it.
    if (chatFollowArrival !== selectedId) chatFollowArrival = null;
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
  input.addEventListener('paste', onChatPaste);
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
  enableChatFileDrop(view);
  return view;
}

// ---------------------------------------------------------------------------
// Files into the composer (#1390) — parity with the terminal drop (#644/#652,
// terminal.js). A drop anywhere on the view (or an image pasted from the
// clipboard) is uploaded to the session's artifacts dir and its escaped host
// path is inserted at the caret. Never sent: the user adds a prompt and presses
// Enter, and the path reaches the agent through `send` like any typed text.
// The whole view takes the drop, so a near-miss on the log never makes the
// browser open the file and navigate away from Crow.
// ---------------------------------------------------------------------------
function enableChatFileDrop(view) {
  view.addEventListener('dragover', (e) => {
    if (!isFileDrag(e)) return;
    e.preventDefault();
    const ok = chatCanAttach();
    e.dataTransfer.dropEffect = ok ? 'copy' : 'none';
    view.classList.toggle('drop-target', ok);
  });
  view.addEventListener('dragleave', (e) => {
    // Moving between children fires dragleave too; only clear on leaving the view.
    if (e.relatedTarget && view.contains(e.relatedTarget)) return;
    view.classList.remove('drop-target');
  });
  view.addEventListener('drop', (e) => {
    view.classList.remove('drop-target');
    const files = e.dataTransfer && e.dataTransfer.files;
    if (!files || !files.length) return; // not a file drop → leave to the browser
    e.preventDefault();                   // never navigate the app away on a file drop
    attachChatFiles(Array.from(files));
  });
}

// ⌘V of a screenshot: the clipboard carries an image file and no text. A text
// paste (even one that also carries a file, like a Finder copy) stays native.
function onChatPaste(e) {
  const cd = e.clipboardData;
  if (!cd || !cd.files || !cd.files.length) return;
  if (Array.from(cd.types || []).includes('text/plain')) return;
  e.preventDefault();
  attachChatFiles(Array.from(cd.files));
}

// The composer is enabled only once the transcript names a target terminal.
function chatCanAttach() {
  const input = document.getElementById('chat-input');
  return !!(selectedId && chatState && chatState.sessionId === selectedId
    && chatState.terminalId && input && !input.disabled);
}

async function attachChatFiles(files) {
  if (!chatCanAttach()) return;
  const sid = chatState.sessionId;
  const paths = await uploadFilesAsArtifacts(sid, files);
  if (!paths.length) return;
  const text = paths.join(' ');
  const input = document.getElementById('chat-input');
  // Switched sessions mid-upload: the paths belong to the session they were
  // uploaded to, so they land in that session's draft, not this composer.
  if (!input || !chatState || chatState.sessionId !== sid) {
    chatDrafts.set(sid, insertChatText(chatDrafts.get(sid) || '', null, null, text).value);
    return;
  }
  const r = insertChatText(input.value, input.selectionStart, input.selectionEnd, text);
  input.value = r.value;
  try { input.setSelectionRange(r.caret, r.caret); } catch (_) { /* jsdom */ }
  autosizeChatInput(input);
  chatDrafts.set(sid, input.value);
  if (!isCoarsePointer()) {
    try { input.focus({ preventScroll: true }); } catch (_) { input.focus(); }
  }
}

// Splice `text` over [start, end) (the end of `value` when unknown), with a
// space before it unless it opens the text or follows whitespace, and one after
// it unless whitespace already follows. Returns the new value and the caret.
function insertChatText(value, start, end, text) {
  const s = start == null ? value.length : start;
  const e = end == null ? s : end;
  const before = value.slice(0, s);
  const after = value.slice(e);
  const ins = (before && !/\s$/.test(before) ? ' ' : '') + text + (/^\s/.test(after) ? '' : ' ');
  return { value: before + ins + after, caret: before.length + ins.length };
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
    // A Follow switch whose page failed reads nothing, and the next pending
    // switch is tried, rather than every later one waiting behind it.
    if (chatFollowArrival === st.sessionId) {
      chatFollowArrival = null;
      if (chatFollowQueue.length) tryChatFollow();
    }
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
  // Auto-read (#1489) speaks only replies that arrive on a follow-on poll,
  // never the backlog a reset or first page carries (opening Chat, a switch).
  const live = !res.reset && st.cursor != null;
  // …except the one reply a Follow switch came for (#1507).
  const backlog = [];
  if (res.reset) {
    stopChatSpeech(); // its bubble is about to go
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
    for (const ev of events) {
      const bubble = appendChatEvent(st, log, ev);
      if (live && bubble) queueChatAutoRead(bubble);
      else if (bubble) backlog.push(bubble);
    }
    if (pinned) log.scrollTop = log.scrollHeight;
    else {
      const jump = document.getElementById('chat-jump');
      if (jump) jump.hidden = false;
    }
  }
  if (!live) consumeChatFollowArrival(st, backlog);
  renderChatStatus(st);
  maybeFocusChatInput(st);
}

// Returns the bubble an assistant message made (for auto-read), else null.
function appendChatEvent(st, log, ev) {
  let bubble = null;
  switch (ev.kind) {
    case 'user':
      log.appendChild(chatBubble('user', ev.text));
      pushChatHistory(st, ev.text);
      break;
    case 'assistant':
      bubble = chatBubble('assistant', ev.text);
      log.appendChild(bubble);
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
      if (st.lastKind === 'turn_end') return null; // the harness can mark one turn twice
      log.appendChild(el('div', 'chat-turn-end',
        ev.duration_ms ? ('Done · ' + formatChatDuration(ev.duration_ms)) : 'Done'));
      break;
    case 'notice':
      log.appendChild(appendLinkified(el('div', 'chat-notice'), ev.text || ''));
      break;
    default:
      return null;
  }
  st.lastKind = ev.kind;
  return bubble;
}

function formatChatDuration(ms) {
  const s = Math.round(ms / 1000);
  if (s < 60) return s + 's';
  return Math.floor(s / 60) + 'm ' + (s % 60) + 's';
}

// A message bubble: the rendered markdown in .chat-msg-body, plus a row of
// chips (.chat-msg-actions): Copy hands back the *source* markdown
// (CROW-1392) and Listen reads the rendered text aloud (assistant only,
// #1488). The chips' labels are CSS content (no text nodes) and
// user-select:none, so they never land in a hand-made selection or in
// textContent.
function chatBubble(role, text) {
  const src = text || '';
  const b = el('div', 'chat-msg chat-' + role);
  const body = el('div', 'chat-msg-body');
  renderChatMarkdown(body, src);
  addChatCodeCopy(body);
  b.appendChild(body);
  if (!src) return b;
  const actions = el('div', 'chat-msg-actions');
  actions.appendChild(chatCopyButton('chat-chip chat-copy chat-msg-copy', 'Copy message as markdown', () => src));
  if (role === 'assistant' && chatSpeechSupported()) actions.appendChild(chatListenButton(body));
  b.appendChild(actions);
  // Desktop right-click, like the terminal's menu. Not on touch: Android fires
  // contextmenu for the long press that starts a text selection. Checked per
  // event, so a convertible that switches pointer mid-transcript follows it.
  b.oncontextmenu = (e) => {
    if (isCoarsePointer()) return;
    const sel = chatSelectionIn(b);
    showCardMenu(e, [{ label: 'Copy', url: sel }, { label: 'Copy as markdown', url: src }]);
  };
  return b;
}

// Selected text inside `root`, or '' when the selection is empty or elsewhere.
function chatSelectionIn(root) {
  const sel = window.getSelection && window.getSelection();
  if (!sel || sel.isCollapsed || !sel.rangeCount) return '';
  const range = sel.getRangeAt(0);
  return root.contains(range.commonAncestorContainer) ? sel.toString() : '';
}

function chatCopyButton(className, label, getText) {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = className;
  btn.title = label;
  btn.setAttribute('aria-label', label);
  let timer = 0;
  btn.onclick = (e) => {
    e.preventDefault();
    e.stopPropagation();
    copyToClipboard(getText());
    btn.classList.add('copied');
    btn.setAttribute('aria-label', 'Copied');
    clearTimeout(timer);
    timer = setTimeout(() => {
      btn.classList.remove('copied');
      btn.setAttribute('aria-label', label);
    }, 1500);
  };
  return btn;
}

// ---------------------------------------------------------------------------
// Listen (#1488): read an assistant bubble aloud with the browser's Web Speech
// API: on the device, with no server, key or cost. One bubble speaks at a
// time, and switching session or view, or leaving Chat, cancels it
// (applyChatView). No `voice` is set, so the system default speaks; that
// honours the enhanced / premium voices a user downloaded on iOS and macOS,
// and means the asynchronously loaded voice list (`voiceschanged`) can't race
// us. Spoken notifications (notifications.js crowVoice) share the one
// speechSynthesis queue: a notification line waits behind a reply, and Stop
// cancels anything queued.
// ---------------------------------------------------------------------------
// Chrome's Google voices silently stop a single utterance after ~15s, so a
// reply is queued as chunks of at most this many characters (~12s of speech).
const CHAT_SPEECH_CHUNK = 200;
// The playing reply: { btn, utterances, auto }. The utterances are held so Chrome
// can't garbage-collect one mid-queue and drop its `end` event.
let chatSpeech = null;
// Auto-read (#1489, below): the per-browser toggle, and the Listen chips of
// replies waiting their turn, oldest first.
const CHAT_AUTO_READ_KEY = 'crow.chat.autoRead';
let chatAutoRead = false;
try { chatAutoRead = localStorage.getItem(CHAT_AUTO_READ_KEY) === '1'; } catch (_) { /* private mode */ }
const chatAutoReadQueue = [];
// A speech call has run inside a user gesture in this page (the iOS unlock).
let chatSpeechUnlocked = false;

function chatSpeechSupported() {
  return 'speechSynthesis' in window && !!window.speechSynthesis
    && typeof window.SpeechSynthesisUtterance === 'function';
}

const CHAT_SPEECH_BLOCK = /^(P|DIV|LI|UL|OL|H[1-6]|BLOCKQUOTE|TABLE|THEAD|TBODY|TR|HR|DL|DT|DD)$/;

// The rendered body as speakable paragraphs: no markdown symbols (markdown-it
// already consumed them), code blocks replaced by "Code block.", a bare URL
// read as its host, and table cells separated by a pause.
function chatSpeakableText(body) {
  const parts = [];
  let cur = '';
  const flush = () => {
    const t = cur.replace(/\s+/g, ' ').replace(/(,\s*)+$/, '').trim();
    if (t) parts.push(t);
    cur = '';
  };
  const walk = (node) => {
    for (const n of node.childNodes) {
      if (n.nodeType === 3) { cur += n.nodeValue; continue; }
      if (n.nodeType !== 1 || n.tagName === 'BUTTON') continue;
      if (n.tagName === 'PRE' || n.classList.contains('chat-code-block')) {
        flush();
        parts.push('Code block.');
      } else if (n.tagName === 'BR') {
        flush();
      } else if (n.tagName === 'A' && /^(https?:\/\/|www\.)/i.test(n.textContent.trim())) {
        let host = '';
        try { host = new URL(n.href).hostname.replace(/^www\./, ''); } catch (_) { /* not a URL */ }
        cur += host ? 'link to ' + host : 'link';
      } else if (n.tagName === 'TD' || n.tagName === 'TH') {
        walk(n);
        cur += ', ';
      } else if (CHAT_SPEECH_BLOCK.test(n.tagName)) {
        flush();
        walk(n);
        flush();
      } else {
        walk(n);
      }
    }
  };
  walk(body);
  flush();
  return parts;
}

// Paragraphs → utterance texts of at most `max` characters: a short paragraph
// is one chunk, a long one is packed sentence by sentence, and a run-on
// sentence is cut at a space.
function chatSpeechChunks(parts, max) {
  max = max || CHAT_SPEECH_CHUNK;
  const chunks = [];
  for (const p of parts) {
    if (p.length <= max) { chunks.push(p); continue; }
    const sentences = p.match(/[^.!?]*[.!?]+["'”’)\]]*\s*|[^.!?]+$/g) || [p];
    let cur = '';
    for (let s of sentences) {
      s = s.trim();
      while (s.length > max) {
        if (cur) { chunks.push(cur); cur = ''; }
        let cut = s.lastIndexOf(' ', max);
        if (cut <= 0) cut = max;
        chunks.push(s.slice(0, cut).trim());
        s = s.slice(cut).trim();
      }
      if (!s) continue;
      if (cur && cur.length + 1 + s.length > max) { chunks.push(cur); cur = s; }
      else cur = cur ? cur + ' ' + s : s;
    }
    if (cur) chunks.push(cur);
  }
  return chunks;
}

function chatListenButton(body) {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'chat-chip chat-msg-listen';
  setChatListenState(btn, false);
  btn.onclick = (e) => {
    e.preventDefault();
    e.stopPropagation();
    toggleChatSpeech(btn, body);
  };
  return btn;
}

function setChatListenState(btn, on) {
  btn.classList.toggle('speaking', on);
  btn.setAttribute('aria-pressed', on ? 'true' : 'false');
  const label = on ? 'Stop reading' : 'Read message aloud';
  btn.title = label;
  btn.setAttribute('aria-label', label);
}

// Tap to speak, tap again to stop; tapping another bubble's Listen switches
// to it. All chunks are queued inside the tap, which is what unlocks audio on
// iOS. Either way the auto-read queue is dropped (stopChatSpeech).
function toggleChatSpeech(btn, body) {
  const wasMine = !!chatSpeech && chatSpeech.btn === btn;
  stopChatSpeech();
  chatSpeechUnlocked = true;
  // Stop drops the pending Follow switches too (#1507); Follow stays on.
  if (wasMine) { cancelChatFollow(); return; }
  startChatSpeech(btn, body);
}

// Speak one bubble: `btn` is its Listen chip, which reads Stop while it plays.
// Returns false when there was nothing to say.
function startChatSpeech(btn, body) {
  if (!chatSpeechSupported()) return false;
  const chunks = chatSpeechChunks(chatSpeakableText(body));
  if (!chunks.length) return false;
  const synth = window.speechSynthesis;
  const run = { btn, utterances: [] };
  try {
    for (const c of chunks) run.utterances.push(new window.SpeechSynthesisUtterance(c));
  } catch (_) { return false; }
  // The run ends without a cancel when its last chunk ends (then the next
  // auto-read reply starts), or when someone else cancelled the queue (a
  // notification Preview cancels, then speaks; its `interrupted` / `canceled`
  // events reach us *after* its new line is queued, so cancelling again here
  // would silence it). Any other failure drops the chunks still queued.
  const end = (finished) => {
    if (chatSpeech !== run) return;
    chatSpeech = null;
    setChatListenState(btn, false);
    if (finished) playNextChatAutoRead();
    else chatAutoReadQueue.length = 0;
    // Nothing left to read here: a pending Follow switch may go (#1507).
    if (!chatSpeech && chatFollowQueue.length) tryChatFollow();
  };
  for (const u of run.utterances) {
    u.onerror = (e) => {
      const why = e && e.error;
      if (why === 'interrupted' || why === 'canceled') end(false);
      else if (chatSpeech === run) stopChatSpeech();
    };
  }
  run.utterances[run.utterances.length - 1].onend = () => end(true);
  chatSpeech = run;
  setChatListenState(btn, true);
  try {
    if (synth.paused) synth.resume(); // Chrome can wedge paused after sleep
    for (const u of run.utterances) synth.speak(u);
  } catch (_) { stopChatSpeech(); return false; }
  return true;
}

// Stop the reply being read, if any, and drop the auto-read queue. Cancels
// only when a reply of ours is playing, so a session switch never cancels a
// notification line that isn't ours.
function stopChatSpeech() {
  chatAutoReadQueue.length = 0;
  const run = chatSpeech;
  if (!run) return;
  chatSpeech = null;
  setChatListenState(run.btn, false);
  try { window.speechSynthesis.cancel(); } catch (_) { /* gone */ }
}
window.addEventListener('pagehide', stopChatSpeech);

// ---------------------------------------------------------------------------
// Auto-read (#1489): a per-browser toggle in the session header that speaks
// each new assistant reply as the transcript poll delivers it, through the
// same pipeline as Listen. Off by default; a private window or blocked storage
// just means off.
//
// - Only replies that arrive while it is on are read: never the backlog of a
//   reset page (opening Chat, switching session).
// - A reply that arrives while another plays (auto-read or Listen) waits in
//   chatAutoReadQueue and starts when the playing one ends.
// - Stop on the playing reply stops it and drops the queue: the replies
//   already on screen stay quiet, and the next reply to arrive is read.
//   Listen on another bubble, switching session or view, and leaving Chat
//   drop it the same way (stopChatSpeech).
// - iOS speaks only after one speech call inside a tap. Turning auto-read on
//   is such a tap, and so is Listen; after a reload with auto-read already on,
//   the first tap anywhere does it (unlockChatSpeech).
// ---------------------------------------------------------------------------

function setChatAutoRead(on) {
  chatAutoRead = !!on;
  try { localStorage.setItem(CHAT_AUTO_READ_KEY, chatAutoRead ? '1' : '0'); } catch (_) { /* ignore */ }
  if (chatAutoRead) unlockChatSpeech();
  // Turning it off silences what it was reading; a Listen the user started
  // keeps playing. Follow has nothing to read for, so its switches go too.
  else {
    if (chatSpeech && chatSpeech.auto) stopChatSpeech();
    else chatAutoReadQueue.length = 0;
    cancelChatFollow();
  }
  const btn = document.getElementById('chat-auto-read');
  if (btn) setChatAutoReadState(btn);
  const follow = document.getElementById('chat-follow');
  if (follow) setChatFollowState(follow);
}

// A new reply landed on a live poll: speak it now, or after the one playing.
// Not before the page is unlocked: iOS can ignore a gesture-less speak()
// without an `end` or `error`, which would leave the run (and its Stop chip)
// stuck and every later reply queued behind it. A reply that lands before the
// first tap stays quiet; the next one after it is read.
function queueChatAutoRead(bubble) {
  if (!chatAutoRead || !chatSpeechUnlocked || !chatSpeechSupported()) return;
  const btn = bubble.querySelector('.chat-msg-listen');
  if (!btn) return;
  chatAutoReadQueue.push(btn);
  if (!chatSpeech) playNextChatAutoRead();
}

function playNextChatAutoRead() {
  while (chatAutoReadQueue.length && !chatSpeech) {
    const btn = chatAutoReadQueue.shift();
    const body = btn.closest('.chat-msg') && btn.closest('.chat-msg').querySelector('.chat-msg-body');
    if (body && btn.isConnected && startChatSpeech(btn, body)) chatSpeech.auto = true;
  }
}

// iOS Safari ignores speak() until one call has run inside a user gesture. A
// silent utterance spoken in the tap unlocks the page for the poll's later,
// gesture-less calls.
function unlockChatSpeech() {
  if (chatSpeechUnlocked || !chatSpeechSupported()) return;
  chatSpeechUnlocked = true;
  try {
    const u = new window.SpeechSynthesisUtterance(' ');
    u.volume = 0;
    window.speechSynthesis.speak(u);
  } catch (_) { /* nothing to unlock */ }
}
// Auto-read left on from an earlier visit: the first tap anywhere unlocks.
for (const type of ['click', 'touchend', 'keydown']) {
  document.addEventListener(type, () => { if (chatAutoRead) unlockChatSpeech(); }, { capture: true, passive: true });
}

// The header toggle, beside Terminal | Chat. Shown in Chat only, and only in a
// browser that can speak.
function chatAutoReadControl() {
  if (!chatViewEnabled() || !chatViewActive || !chatSpeechSupported()) return null;
  const btn = el('button', 'chat-auto-read', '');
  btn.type = 'button';
  btn.id = 'chat-auto-read';
  btn.appendChild(icon('speaker', 12));
  btn.appendChild(el('span', 'chat-auto-read-label', 'Auto-read'));
  setChatAutoReadState(btn);
  btn.onclick = (ev) => { ev.stopPropagation(); setChatAutoRead(!chatAutoRead); };
  return btn;
}

function setChatAutoReadState(btn) {
  btn.classList.toggle('active', chatAutoRead);
  btn.setAttribute('aria-pressed', chatAutoRead ? 'true' : 'false');
  const label = chatAutoRead ? 'Auto-read is on: new replies are read aloud' : 'Read new replies aloud';
  btn.title = label;
  btn.setAttribute('aria-label', label);
}

// ---------------------------------------------------------------------------
// Follow (#1507): a per-browser toggle beside Auto-read. When another session
// finishes (`taskComplete`) or needs you (`agentWaiting`), switch to it in Chat
// and read its latest reply, since auto-read only hears the selected session's
// transcript poll. Off by default; takes effect only while Auto-read is on.
//
// - Trigger: emitEvent (notifications.js) calls chatFollowEvent for every
//   event; only those two, for a session other than the selected one, while
//   the page shows a session's Chat. Never from a board, the grid or Terminal.
// - Wait: a reply playing (auto-read or Listen), or queued, holds the switch
//   until it ends. Several sessions finishing meanwhile are followed one at a
//   time, oldest first, each once (chatFollowQueue).
// - Read on arrival: the switch sets chatFollowArrival to the target, and the
//   first page for it (the backlog page auto-read otherwise skips) queues its
//   latest assistant reply. That one-shot is the only exception to "never read
//   what is already there": manual switches, reloads, opening Chat and a
//   notification click still read nothing.
// - Guards: no switch while the composer holds a draft, a send is in flight,
//   the tab is hidden, a dialog / Settings / the switcher is open, or within
//   CHAT_FOLLOW_IDLE_MS of a key, tap, click or scroll in the page (or of
//   coming back to the tab). The switch is retried when the guard clears.
// - Stop on the playing reply drops the pending switches (Follow stays on);
//   so do Follow off, Auto-read off, and leaving Chat (applyChatView, plus the
//   exits that bypass it: selectBoard, showEmptyDetail, session expiry).
// ---------------------------------------------------------------------------
const CHAT_FOLLOW_KEY = 'crow.chat.follow';
// No switch within this long of the user touching the page.
const CHAT_FOLLOW_IDLE_MS = 5000;
// How often a held switch is retried.
const CHAT_FOLLOW_RETRY_MS = 1500;
// The first try waits a little longer than the spoken notification's coalesce
// window (VOICE_COALESCE_MS, 700ms), so "crow 1078 is done" is queued in the
// browser's speech queue before the reply and is heard first.
const CHAT_FOLLOW_SETTLE_MS = 900;
let chatFollow = false;
try { chatFollow = localStorage.getItem(CHAT_FOLLOW_KEY) === '1'; } catch (_) { /* private mode */ }
const chatFollowQueue = [];
// The session a Follow switch went to whose first page hasn't landed yet.
let chatFollowArrival = null;
let chatFollowTimer = null;
let chatLastInteractionAt = 0;

for (const type of ['pointerdown', 'keydown', 'wheel', 'touchstart']) {
  document.addEventListener(type, () => { chatLastInteractionAt = Date.now(); }, { capture: true, passive: true });
}
// Coming back to the tab counts too: a switch held while it was hidden waits
// until the user has had a moment to see where they are.
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) chatLastInteractionAt = Date.now();
});

function chatFollowEnabled() {
  return chatFollow && chatAutoRead && chatViewEnabled() && chatSpeechSupported();
}

// The page shows a session's Chat (not a board, the grid or Terminal).
function chatFollowInChat() {
  return !!selectedId && !selectedBoard && chatViewShown();
}

// emitEvent hook: every notification event for every session passes here.
function chatFollowEvent(event, key) {
  if (event !== 'taskComplete' && event !== 'agentWaiting') return;
  // Before the first tap after a reload speech can't start, so a switch
  // would land on a reply that stays quiet: leave the user where they are.
  if (!chatFollowEnabled() || !chatSpeechUnlocked || !chatFollowInChat()) return;
  if (!key || key === selectedId) return; // auto-read already hears this one
  if (typeof sessions !== 'undefined' && !sessions.some((s) => s.id === key)) return;
  if (!chatFollowQueue.includes(key)) chatFollowQueue.push(key);
  scheduleChatFollow(CHAT_FOLLOW_SETTLE_MS);
}

function scheduleChatFollow(ms) {
  if (chatFollowTimer) return;
  chatFollowTimer = setTimeout(() => { chatFollowTimer = null; tryChatFollow(); }, ms);
}

function cancelChatFollow() {
  chatFollowQueue.length = 0;
  chatFollowArrival = null;
  if (chatFollowTimer) { clearTimeout(chatFollowTimer); chatFollowTimer = null; }
}

// Why a switch must wait right now, or null when it may go ahead.
function chatFollowHold() {
  if (chatSpeech || chatAutoReadQueue.length) return 'speaking';
  if (chatFollowArrival) return 'arriving';
  if (document.hidden) return 'hidden';
  if (chatSending) return 'sending';
  const input = document.getElementById('chat-input');
  if (input && input.value && input.value.trim()) return 'draft';
  if (Date.now() - chatLastInteractionAt < CHAT_FOLLOW_IDLE_MS) return 'interaction';
  // Something on top of the session: a prompt or modal, Settings, the switcher.
  if (document.querySelector('.text-prompt-backdrop, .modal-dialog-backdrop')) return 'modal';
  if (window.settingsIsOpen && window.settingsIsOpen()) return 'modal';
  const sw = document.getElementById('session-switcher');
  if (sw && !sw.hidden) return 'modal';
  return null;
}

// Switch to the oldest pending session, or schedule a retry if something
// holds it. Called on a timer, and when a reply finishes playing.
function tryChatFollow() {
  if (!chatFollowEnabled() || !chatFollowInChat()) { cancelChatFollow(); return; }
  while (chatFollowQueue.length) {
    if (chatFollowHold()) { scheduleChatFollow(CHAT_FOLLOW_RETRY_MS); return; }
    const id = chatFollowQueue.shift();
    if (id === selectedId) continue; // the user went there already
    if (typeof sessions !== 'undefined' && !sessions.some((s) => s.id === id)) continue;
    chatFollowArrival = id;
    selectSession(id);
    // Watchdog for the rest of the queue: the first page normally pumps it
    // (consumeChatFollowArrival, or refreshChat's catch), but a page that never
    // lands for this switch (a manual switch drops the arrival, and the late
    // page is discarded) must not orphan it. While the arrival is pending the
    // retry just holds; once it clears, the next session is followed after the
    // usual guards (a manual switch is itself an interaction).
    if (chatFollowQueue.length) scheduleChatFollow(CHAT_FOLLOW_RETRY_MS);
    return;
  }
}

// applyChatPage: the first page for a session Follow switched to. Queue its
// latest assistant reply (if any) once, then let the next pending switch go.
function consumeChatFollowArrival(st, bubbles) {
  if (chatFollowArrival !== st.sessionId) return;
  chatFollowArrival = null;
  if (bubbles.length) queueChatAutoRead(bubbles[bubbles.length - 1]);
  if (chatFollowQueue.length) tryChatFollow();
}

function setChatFollow(on) {
  chatFollow = !!on;
  try { localStorage.setItem(CHAT_FOLLOW_KEY, chatFollow ? '1' : '0'); } catch (_) { /* ignore */ }
  if (!chatFollow) cancelChatFollow();
  // Turning it on is a tap, so it unlocks speech like Auto-read does.
  else if (chatAutoRead) unlockChatSpeech();
  const btn = document.getElementById('chat-follow');
  if (btn) setChatFollowState(btn);
}

// The header toggle, right after Auto-read, under the same conditions.
function chatFollowControl() {
  if (!chatViewEnabled() || !chatViewActive || !chatSpeechSupported()) return null;
  const btn = el('button', 'chat-auto-read chat-follow', '');
  btn.type = 'button';
  btn.id = 'chat-follow';
  btn.appendChild(icon('follow', 12));
  btn.appendChild(el('span', 'chat-auto-read-label', 'Follow'));
  setChatFollowState(btn);
  btn.onclick = (ev) => { ev.stopPropagation(); setChatFollow(!chatFollow); };
  return btn;
}

function setChatFollowState(btn) {
  btn.classList.toggle('active', chatFollow);
  // On, but idle until Auto-read is on too.
  btn.classList.toggle('dormant', chatFollow && !chatAutoRead);
  btn.setAttribute('aria-pressed', chatFollow ? 'true' : 'false');
  let label;
  if (!chatFollow) label = 'Switch to a session when it finishes or needs you, and read its reply';
  else if (!chatAutoRead) label = 'Follow is on, but waits for Auto-read';
  else label = 'Follow is on: switches to a session when it finishes or needs you, and reads its reply';
  btn.title = label;
  btn.setAttribute('aria-label', label);
}

// Wrap each code block (markdown-it's <pre><code>, or the fallback's
// pre.chat-code) so it gets its own Copy, which copies just the block's
// contents — the rendered text is the fence body, minus fences and the
// language tag. The trailing newline is dropped so a pasted shell line
// doesn't run on its own.
function addChatCodeCopy(root) {
  for (const pre of [...root.querySelectorAll('pre')]) {
    const wrap = el('div', 'chat-code-block');
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(pre);
    wrap.appendChild(chatCopyButton('chat-chip chat-copy chat-code-copy', 'Copy code',
      () => pre.textContent.replace(/\n$/, '')));
  }
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
    // `raw`: send the text as typed. Without it, `send` rewrites a literal
    // `\n` / `\t` (the `crow send` convention) and pasted code changes (#1437).
    // A failed delivery rejects, so the text stays in the composer.
    await rpc('send', { session_id: st.sessionId, terminal_id: st.terminalId, text: text + '\n', raw: true });
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
