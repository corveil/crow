'use strict';
// Crow web UI — Chat view, Agent SDK mode. THROWAWAY SPIKE (CROW-1524, ADR 0033).
//
// A third segment in the Terminal | Chat toggle, shown only when crowd runs
// with CROW_AGENT_SDK_SPIKE. It reuses Chat's DOM, composer and renderers but
// swaps the source: instead of tailing the terminal agent's transcript and
// pasting into tmux, messages go to a Claude Agent SDK sidecar that crowd
// supervises for the session (`sdk-chat-input`), and its events come back as
// `sdk-chat-event` pushes (streaming text deltas included) with
// `get-sdk-chat-events` as the cursor-based catch-up. Tool approvals and
// AskUserQuestion are answered from cards, through the SDK's own callback.
//
// It is a separate Claude conversation in the same worktree. The terminal
// agent is untouched.

// null until probed; then whether crowd runs the spike.
let sdkChatEnabled = null;
let sdkChatProbing = false;
let sdkChatModeOn = false;
try { sdkChatModeOn = localStorage.getItem('crow.chat.sdk') === '1'; } catch (_) { /* private mode */ }

// True when the toggle can offer SDK mode.
function sdkChatAvailable() {
  return sdkChatEnabled === true;
}

// Chat is showing the SDK conversation (not the transcript).
function sdkChatShown() {
  return sdkChatAvailable() && sdkChatModeOn;
}

function setSdkChatMode(on) {
  sdkChatModeOn = !!on;
  try { localStorage.setItem('crow.chat.sdk', sdkChatModeOn ? '1' : '0'); } catch (_) { /* ignore */ }
}

// Ask crowd once whether the spike is on; repaint the header when it is.
async function probeSdkChat() {
  if (sdkChatEnabled !== null || sdkChatProbing) return;
  sdkChatProbing = true;
  try {
    const res = await rpc('get-sdk-chat-events', {});
    sdkChatEnabled = !!(res && res.enabled);
  } catch (_) {
    sdkChatEnabled = false; // an older crowd without the method
  } finally {
    sdkChatProbing = false;
  }
  if (!sdkChatEnabled) return;
  const s = typeof sessions !== 'undefined' && sessions.find((x) => x.id === selectedId);
  if (s && typeof renderHeader === 'function') renderHeader(s);
  if (sdkChatModeOn && typeof applyChatView === 'function') applyChatView();
}

// ---------------------------------------------------------------------------
// Pages and pushes
// ---------------------------------------------------------------------------

async function refreshSdkChat(st) {
  const params = { session_id: st.sessionId };
  if (st.cursor != null) params.cursor = st.cursor;
  const res = await rpc('get-sdk-chat-events', params);
  await loadChatMarkdown();
  if (chatState !== st) return;
  applySdkChatPage(st, res || {});
}

// Exposed for web-tests.
function applySdkChatPage(st, res) {
  const log = document.getElementById('chat-log');
  st.supported = res.enabled !== false;
  st.reason = st.supported ? null : 'The Agent SDK spike is off.';
  st.sdkRunning = !!res.running;
  st.sdkSessionId = res.sdk_session_id || st.sdkSessionId || null;
  const reset = res.reset || st.cursor == null;
  if (reset) {
    st.cursor = 0;
    if (log) log.innerHTML = '';
    st.toolNodes = new Map();
    st.sdkCards = new Map();
    st.sdkQuestionTools = new Set();
    st.sdkLive = null;
    st.lastKind = null;
    if (log && !(res.events || []).length) {
      log.appendChild(el('div', 'chat-notice sdk-chat-intro',
        'Agent SDK spike: a message here starts a separate Claude conversation in this worktree, run by crowd '
        + 'through the Claude Agent SDK. The terminal agent is untouched.'));
    }
  }
  const pinned = !log || reset || chatNearBottom(log);
  for (const ev of res.events || []) {
    // A page that was in flight while a push landed repeats that event.
    if (typeof ev.seq === 'number' && ev.seq <= st.cursor) continue;
    applySdkChatEvent(st, ev);
    if (typeof ev.seq === 'number') st.cursor = ev.seq;
  }
  if (typeof res.cursor === 'number') st.cursor = Math.max(st.cursor, res.cursor);
  if (log && pinned) log.scrollTop = log.scrollHeight;
  renderChatStatus(st);
  maybeFocusChatInput(st);
}

// `sdk-chat-event` push (rpc.js). Applied only when it is the next event the
// current session expects; a gap is filled by a page fetch.
function onSdkChatEvent(params) {
  const st = chatState;
  if (!params || !st || !st.sdk || params.session_id !== st.sessionId || st.cursor == null) return;
  const ev = params.event || {};
  if (ev.kind === 'delta') {
    if (ev.seq === st.cursor) applySdkChatEvent(st, ev);
    return;
  }
  if (typeof ev.seq !== 'number' || ev.seq <= st.cursor) return; // already have it
  if (ev.seq !== st.cursor + 1) { refreshChat(); return; }
  const log = document.getElementById('chat-log');
  const pinned = log && chatNearBottom(log);
  applySdkChatEvent(st, ev);
  st.cursor = ev.seq;
  if (ev.kind === 'stopped') st.sdkRunning = false;
  else if (ev.kind === 'user') st.sdkRunning = true;
  if (log && pinned) log.scrollTop = log.scrollHeight;
  renderChatStatus(st);
}

// ---------------------------------------------------------------------------
// Events → DOM
// ---------------------------------------------------------------------------

function applySdkChatEvent(st, ev) {
  const log = document.getElementById('chat-log');
  if (!log) return;
  switch (ev.kind) {
    case 'delta':
      appendSdkDelta(st, log, ev.text || '');
      return;
    case 'assistant':
      // The streamed bubble is replaced by the finished, markdown-rendered one.
      if (st.sdkLive) { st.sdkLive.remove(); st.sdkLive = null; }
      appendChatEvent(st, log, ev);
      return;
    case 'tool_call':
      // AskUserQuestion is drawn by its `question` card, not as a tool row.
      if (ev.tool_name === 'AskUserQuestion') { if (ev.tool_id) st.sdkQuestionTools.add(ev.tool_id); return; }
      dropSdkLive(st);
      appendChatEvent(st, log, ev);
      return;
    case 'tool_result':
      if (ev.tool_id && st.sdkQuestionTools.has(ev.tool_id)) return;
      appendChatEvent(st, log, ev);
      return;
    case 'user':
    case 'notice':
      dropSdkLive(st);
      appendChatEvent(st, log, ev);
      if (ev.is_error) log.lastChild.classList.add('error');
      return;
    case 'turn_end': {
      dropSdkLive(st);
      const before = log.lastChild;
      appendChatEvent(st, log, ev);
      const line = log.lastChild;
      if (line !== before && line && typeof ev.cost_usd === 'number') {
        line.textContent += ' · $' + ev.cost_usd.toFixed(ev.cost_usd < 1 ? 3 : 2);
      }
      return;
    }
    case 'ready': {
      const bits = [];
      if (ev.model) bits.push(ev.model);
      if (ev.claude_code_version) bits.push('Claude Code ' + ev.claude_code_version);
      if (ev.permission_mode) bits.push(ev.permission_mode + ' permissions');
      const note = el('div', 'chat-notice sdk-chat-ready',
        'SDK conversation ' + String(ev.sdk_session_id || '').slice(0, 8) + (bits.length ? ' · ' + bits.join(' · ') : ''));
      if (ev.sdk_session_id) note.title = 'Resume it in a terminal: claude --resume ' + ev.sdk_session_id;
      log.appendChild(note);
      return;
    }
    case 'permission':
    case 'question': {
      dropSdkLive(st);
      const card = ev.kind === 'question' ? sdkQuestionCard(st, ev) : sdkApprovalCard(st, ev);
      st.sdkCards.set(ev.request_id, card);
      log.appendChild(card);
      st.lastKind = ev.kind;
      return;
    }
    case 'resolved': {
      const card = st.sdkCards.get(ev.request_id);
      if (card) closeSdkCard(card, ev);
      return;
    }
    case 'error':
      dropSdkLive(st);
      log.appendChild(appendLinkified(el('div', 'chat-notice error'), 'SDK error: ' + (ev.text || '')));
      return;
    case 'stopped':
      dropSdkLive(st);
      log.appendChild(el('div', 'chat-notice',
        'The SDK sidecar stopped' + (ev.status ? ' (exit ' + ev.status + ')' : '') + '. Send a message to resume the conversation.'));
      for (const card of st.sdkCards.values()) {
        if (card.classList.contains('pending')) closeSdkCard(card, { behavior: 'cancelled' });
      }
      st.lastKind = 'turn_end'; // idle
      return;
    default:
  }
}

// Streaming text: plain text while it arrives (markdown would re-flow on
// every token), replaced by the rendered bubble when `assistant` lands.
function appendSdkDelta(st, log, text) {
  if (!st.sdkLive) {
    st.sdkLive = el('div', 'chat-msg chat-assistant sdk-streaming');
    st.sdkLive.appendChild(el('div', 'chat-msg-body'));
    log.appendChild(st.sdkLive);
    st.lastKind = 'assistant';
  }
  st.sdkLive.firstChild.textContent += text;
  if (chatNearBottom(log)) log.scrollTop = log.scrollHeight;
}

// A streamed bubble whose `assistant` never came (an interrupt): keep it.
function dropSdkLive(st) {
  if (st.sdkLive) st.sdkLive.classList.remove('sdk-streaming');
  st.sdkLive = null;
}

// ---------------------------------------------------------------------------
// Approval and question cards — answered through the SDK's canUseTool.
// ---------------------------------------------------------------------------

function sdkCardShell(st, ev, title) {
  const card = el('div', 'chat-question sdk-card pending');
  card.setAttribute('role', 'group');
  card.setAttribute('aria-label', title);
  card.dataset.requestId = ev.request_id;
  card.dataset.sessionId = st.sessionId;
  const head = el('div', 'chat-question-head');
  head.appendChild(icon(ev.kind === 'question' ? 'comment' : 'warning', 12));
  head.appendChild(el('span', null, title));
  card.appendChild(head);
  return card;
}

function sdkApprovalCard(st, ev) {
  const card = sdkCardShell(st, ev, 'Allow ' + (ev.tool_name || 'this tool') + '?');
  card.classList.add('sdk-approval');
  const body = el('div', 'chat-question-body');
  if (ev.text) body.appendChild(el('pre', 'chat-tool-full sdk-approval-input', ev.text));
  if (ev.reason) body.appendChild(el('div', 'chat-q-hint', ev.reason));
  card.appendChild(body);
  const actions = el('div', 'chat-question-actions');
  const allow = el('button', 'chat-question-submit', 'Allow');
  allow.type = 'button';
  allow.onclick = () => respondSdkCard(st, card, { behavior: 'allow' });
  const deny = el('button', 'chat-question-submit sdk-deny', 'Deny');
  deny.type = 'button';
  deny.onclick = () => respondSdkCard(st, card, { behavior: 'deny' });
  const note = el('span', 'chat-question-note');
  note.setAttribute('role', 'status');
  actions.appendChild(allow);
  actions.appendChild(deny);
  actions.appendChild(note);
  card.appendChild(actions);
  return card;
}

function sdkQuestionCard(st, ev) {
  const questions = ev.questions || [];
  const card = sdkCardShell(st, ev, questions.length > 1 ? 'The agent has questions' : 'The agent has a question');
  const key = 'sdk:' + st.sessionId + ':' + ev.request_id;
  card.dataset.key = key;
  card._questions = questions;
  const draft = chatQuestionDraft(key, questions);
  const body = el('div', 'chat-question-body');
  questions.forEach((q, i) => body.appendChild(chatQuestionFieldset(card, key, q, i, draft)));
  card.appendChild(body);
  const actions = el('div', 'chat-question-actions');
  const submit = el('button', 'chat-question-submit', 'Submit');
  submit.type = 'button';
  submit.onclick = () => {
    const answers = sdkAnswers(questions, chatQuestionAnswers(questions, chatQuestionDrafts.get(key) || []));
    if (answers) respondSdkCard(st, card, { behavior: 'allow', answers });
  };
  const decline = el('button', 'chat-question-submit sdk-deny', 'Decline');
  decline.type = 'button';
  decline.onclick = () => respondSdkCard(st, card, { behavior: 'deny' });
  const note = el('span', 'chat-question-note');
  note.setAttribute('role', 'status');
  actions.appendChild(submit);
  actions.appendChild(decline);
  actions.appendChild(note);
  card.appendChild(actions);
  updateChatQuestionCard(card);
  return card;
}

// The card's picks (`chatQuestionAnswers`: option indices + Other) → the SDK's
// `answers`: question text → label, labels joined with ", ", or the Other text.
function sdkAnswers(questions, picked) {
  if (!picked) return null;
  const out = {};
  questions.forEach((q, i) => {
    const p = picked[i];
    const parts = (p.selected || []).map((j) => (q.options[j] || {}).label).filter(Boolean);
    if (p.other) parts.push(p.other);
    out[q.question] = parts.join(', ');
  });
  return out;
}

async function respondSdkCard(st, card, answer) {
  if (!card.classList.contains('pending') || card.classList.contains('locked')) return;
  card.classList.add('locked');
  for (const b of card.querySelectorAll('button, input')) b.disabled = true;
  const note = card.querySelector('.chat-question-note');
  if (note) { note.classList.remove('error'); note.textContent = 'Sending…'; }
  try {
    await rpc('sdk-chat-input', Object.assign({ session_id: card.dataset.sessionId, op: 'respond',
      request_id: card.dataset.requestId }, answer));
    if (note && card.classList.contains('pending')) note.textContent = 'Sent. Waiting for the agent…';
  } catch (e) {
    card.classList.remove('locked');
    for (const b of card.querySelectorAll('button, input')) b.disabled = false;
    if (card.dataset.key) updateChatQuestionCard(card);
    if (note) { note.textContent = 'Not sent: ' + ((e && e.message) || e); note.classList.add('error'); }
  }
  renderChatStatus();
}

// The sidecar resolved the request (answered from any browser, or cancelled).
function closeSdkCard(card, ev) {
  const state = ev.behavior === 'allow' ? (card._questions ? 'Answered' : 'Allowed')
    : ev.behavior === 'deny' ? (card._questions ? 'Declined' : 'Denied')
      : 'Cancelled';
  if (card.dataset.key) chatQuestionDrafts.delete(card.dataset.key);
  card.classList.remove('pending', 'locked');
  card.classList.add('answered');
  if (ev.behavior !== 'allow') card.classList.add('declined');
  const head = card.querySelector('.chat-question-head');
  const keep = card.querySelector('.sdk-approval-input');
  card.innerHTML = '';
  if (head) { head.appendChild(el('span', 'chat-question-state', state)); card.appendChild(head); }
  const body = el('div', 'chat-question-body');
  if (keep) body.appendChild(keep);
  for (const q of card._questions || []) {
    const row = el('div', 'chat-q chat-q-done');
    const legend = el('div', 'chat-q-legend');
    if (q.header) legend.appendChild(el('span', 'chat-q-chip', q.header));
    legend.appendChild(el('span', 'chat-q-text', q.question));
    row.appendChild(legend);
    const a = ev.answers && ev.answers[q.question];
    if (a) row.appendChild(el('div', 'chat-q-answer', '→ ' + a));
    body.appendChild(row);
  }
  card.appendChild(body);
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

function sendSdkChatMessage(st, text) {
  return rpc('sdk-chat-input', { session_id: st.sessionId, op: 'message', text });
}

// The status line's Interrupt (while working) and End (while running).
function sdkChatStatusActions(st, status) {
  if (!st.sdkRunning) return;
  const working = st.lastKind && st.lastKind !== 'turn_end' && !chatQuestionPending(st);
  const mk = (label, op, title) => {
    const b = el('button', 'chat-chip sdk-chat-action', label);
    b.type = 'button';
    b.title = title;
    b.onclick = () => rpc('sdk-chat-input', { session_id: st.sessionId, op }).catch((e) =>
      alertModal(label + ' failed: ' + ((e && e.message) || e)));
    status.appendChild(b);
  };
  if (working) mk('Interrupt', 'interrupt', 'Stop the current turn');
  mk('End', 'stop', 'Stop the SDK sidecar. The next message resumes the same conversation.');
}
