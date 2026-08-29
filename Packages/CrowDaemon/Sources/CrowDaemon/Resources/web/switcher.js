'use strict';
// Crow web UI — Session switcher overlay (CROW-976). Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// Session switcher overlay — macOS-style MRU cycling (CROW-976)
// ---------------------------------------------------------------------------

const sessionMRU = [];
const SWITCHER_PREVIEW_CACHE_MS = 4000;
const SWITCHER_PREVIEW_DEBOUNCE_MS = 150;
// How long a tapped prefix key (the `esc` in `esc+tab`) stays armed. Long
// enough to be typed on a phone keyboard, short enough that a stray Esc can't
// turn a much later Tab into a switcher open.
const SWITCHER_PREFIX_WINDOW_MS = 1500;
const switcherPreviewCache = new Map();
let switcherPreviewTimer = null;
let switcherPreviewSeq = 0;
const switcherState = {
  open: false,
  originId: null,
  index: 0,
  highlightedId: null,
  chord: null,
  modifiersHeld: null,
  previousFocus: null,
  // Epoch ms of the last prefix keypress; 0 when nothing is armed.
  prefixArmedAt: 0,
};

function switcherBindingModifierFromEvent(e) {
  switch (e.key) {
    case 'Shift': return 'shift';
    case 'Control': return 'ctrl';
    case 'Alt': return 'alt';
    case 'Meta': return 'meta';
    default: return null;
  }
}

function switcherBindingModifiersActive() {
  const c = switcherState.chord;
  const h = switcherState.modifiersHeld;
  if (!c || !h) return false;
  if (c.shift && h.shift) return true;
  if (c.ctrl && h.ctrl) return true;
  if (c.alt && h.alt) return true;
  if (c.meta && h.meta) return true;
  return false;
}

function switcherBindingHasModifiers(b) {
  return b.shift || b.ctrl || b.alt || b.meta;
}

function switcherBindingKeysForPart(keyPart) {
  const lower = keyPart.toLowerCase();
  const aliases = {
    tab: ['Tab'],
    enter: ['Enter'],
    escape: ['Escape'],
    esc: ['Escape'],
    space: [' ', 'Space'],
    '`': ['`', 'Backquote'],
    backquote: ['`', 'Backquote'],
    '-': ['-', 'Minus'],
    minus: ['-', 'Minus'],
    '=': ['=', 'Equal'],
    equal: ['=', 'Equal'],
    // The default's key half. Spelled out so it yields one entry rather than
    // the length-1 branch's ['/', '/'] — `switcherCycleKeyLabel` prints keys[0]
    // and a duplicate would read as a typo in the hint line.
    '/': ['/'],
    slash: ['/'],
    left: ['ArrowLeft'],
    right: ['ArrowRight'],
    up: ['ArrowUp'],
    down: ['ArrowDown'],
  };
  if (aliases[lower]) return aliases[lower];
  if (keyPart.length === 1) return [keyPart, keyPart.toUpperCase()];
  return [keyPart.charAt(0).toUpperCase() + keyPart.slice(1)];
}

function switcherCycleKeyLabel() {
  const b = parseSwitcherBinding(uiConfig.switcherBinding);
  if (b.keys.includes('Tab')) return 'Tab';
  if (b.keys.includes(' ') || b.keys.includes('Space')) return 'Space';
  if (b.keys.includes('Backquote') || b.keys.includes('`')) return '`';
  return b.key;
}

function switcherCommitHint() {
  const b = parseSwitcherBinding(uiConfig.switcherBinding);
  const mods = [];
  if (b.shift) mods.push('Shift');
  if (b.ctrl) mods.push('Ctrl');
  if (b.alt) mods.push('Alt');
  if (b.meta) mods.push('Cmd');
  const cycle = switcherCycleKeyLabel();
  // Three commit gestures, one per chord shape: release the held modifier, hit
  // Enter (a prefix chord holds nothing down), or release the key itself.
  const commitHint = switcherBindingHasModifiers(b)
    ? 'release ' + mods.join('+')
    : (b.prefix ? 'Enter' : 'release ' + cycle);
  // `or` rather than a slash separator: the default's cycle key IS `/`, and
  // "/ / ←→" reads as a typo.
  return cycle + ' or ←→ to cycle · ' + commitHint + ' to switch · Esc to cancel';
}

function captureSwitcherModifiers(e) {
  const b = parseSwitcherBinding(uiConfig.switcherBinding);
  switcherState.chord = b;
  switcherState.modifiersHeld = {
    shift: b.shift && e.shiftKey,
    ctrl: b.ctrl && e.ctrlKey,
    alt: b.alt && e.altKey,
    meta: b.meta && e.metaKey,
  };
}

function touchSessionMRU(id) {
  if (!id) return;
  const i = sessionMRU.indexOf(id);
  if (i >= 0) sessionMRU.splice(i, 1);
  sessionMRU.unshift(id);
  if (sessionMRU.length > 200) sessionMRU.length = 200;
}

// Chords a coding agent owns inside its own TUI, which the switcher must never
// take from a focused terminal no matter what `captureInTerminal` says
// (CROW-1002). Shift+Tab cycles permission modes in Claude Code, Cursor and
// Codex alike — swallowing it there costs the user a control with no
// alternative binding, to save one keystroke of a control that has three other
// ways in (the sidebar, a click, the configured chord outside the terminal).
//
// crowd rewrites a stored `shift+tab` to the default and refuses to set it, so
// this is the belt to that pair of braces: it holds for a hand-edited
// config.json, and for a browser still holding the pre-migration config it was
// handed before the daemon restarted.
const SWITCHER_TERMINAL_RESERVED = ['shift+tab'];

function switcherBindingIsTerminalReserved(binding) {
  const b = parseSwitcherBinding(binding);
  return SWITCHER_TERMINAL_RESERVED.some((r) => {
    const res = parseSwitcherBinding(r);
    return res.key === b.key && res.shift === b.shift && res.ctrl === b.ctrl
      && res.alt === b.alt && res.meta === b.meta && res.prefix === b.prefix;
  });
}

// Does the configured binding get captured inside a focused terminal? The user
// preference, minus the chords above.
function switcherCapturesInTerminal() {
  if (!uiConfig.switcherCaptureInTerminal) return false;
  return !switcherBindingIsTerminalReserved(uiConfig.switcherBinding);
}

function parseSwitcherBinding(binding) {
  const parts = String(binding || 'cmd+/').toLowerCase().split('+').map((p) => p.trim()).filter(Boolean);
  const keyPart = parts[parts.length - 1] || '/';
  const lead = parts.slice(0, -1);
  const keys = switcherBindingKeysForPart(keyPart);
  return {
    key: keys[0],
    keys,
    shift: lead.includes('shift'),
    ctrl: lead.includes('ctrl'),
    alt: lead.includes('alt'),
    meta: lead.includes('meta') || lead.includes('cmd') || lead.includes('command'),
    // Esc is not a modifier the keyboard reports on a later event, so a leading
    // `esc` is a *prefix*: tap it, then press the key. Everything downstream
    // branches on this instead of trying to read an `escKey` that can't exist.
    prefix: (lead.includes('esc') || lead.includes('escape')) ? 'Escape' : null,
  };
}

// True while a prefix key pressed within the window is still waiting for its
// second keystroke.
function switcherPrefixArmed() {
  if (!switcherState.prefixArmedAt) return false;
  return (Date.now() - switcherState.prefixArmedAt) <= SWITCHER_PREFIX_WINDOW_MS;
}

function armSwitcherPrefix() { switcherState.prefixArmedAt = Date.now(); }
function disarmSwitcherPrefix() { switcherState.prefixArmedAt = 0; }

// Would this keydown *open* the switcher? Same as matching the chord, except a
// prefix binding also needs its prefix armed — otherwise `esc+tab` would fire on
// every bare Tab, which is exactly the collision CROW-980 moved away from.
function switcherBindingOpens(e, binding) {
  if (!eventMatchesSwitcherBinding(e, binding)) return false;
  return parseSwitcherBinding(binding).prefix ? switcherPrefixArmed() : true;
}

function eventMatchesSwitcherBinding(e, binding) {
  const b = parseSwitcherBinding(binding);
  if (!!e.shiftKey !== b.shift) return false;
  if (!!e.ctrlKey !== b.ctrl) return false;
  if (!!e.altKey !== b.alt) return false;
  if (!!e.metaKey !== b.meta) return false;
  if (b.keys.includes(e.key)) return true;
  return b.keys.some((k) => k.length === 1 && e.key.length === 1
    && e.key.toLowerCase() === k.toLowerCase());
}

function switcherIncludesSession(s, include) {
  if (s.kind === 'manager' && !include.managers) return false;
  if (s.kind === 'job' && !include.jobs) return false;
  if (s.kind === 'review' && !include.reviews) return false;
  switch (s.status) {
    case 'active': return include.active;
    case 'paused': return include.paused;
    case 'inReview': return include.in_review;
    case 'completed': return include.completed;
    case 'archived': return include.archived;
    default: return true;
  }
}

function switcherSidebarOrdered(list, include) {
  const eligible = list.filter((s) => switcherIncludesSession(s, include));
  const out = [];
  for (const m of eligible.filter((s) => s.kind === 'manager')) out.push(m);
  for (const g of groupSessions(eligible)) {
    for (const row of g.rows) out.push(row);
  }
  return out;
}

function switcherMruOrdered(list, include) {
  const eligible = list.filter((s) => switcherIncludesSession(s, include));
  const byId = new Map(eligible.map((s) => [s.id, s]));
  const out = [];
  for (const id of sessionMRU) {
    const s = byId.get(id);
    if (s) { out.push(s); byId.delete(id); }
  }
  for (const s of eligible) {
    if (byId.has(s.id)) out.push(s);
  }
  return out;
}

function buildSwitcherEntries() {
  const include = uiConfig.switcherInclude;
  return uiConfig.switcherOrder === 'sidebar'
    ? switcherSidebarOrdered(sessions, include)
    : switcherMruOrdered(sessions, include);
}

function switcherCategoryLabel(s) {
  if (s.kind === 'manager') return 'Manager';
  if (s.kind === 'job') return 'Job';
  if (s.kind === 'review') return 'Review';
  return 'Work';
}

function switcherClampIndex(entries) {
  if (!entries.length) return 0;
  const cur = entries[switcherState.index];
  if (cur && switcherState.highlightedId && cur.id === switcherState.highlightedId) {
    return switcherState.index;
  }
  if (switcherState.highlightedId) {
    const hi = entries.findIndex((s) => s.id === switcherState.highlightedId);
    if (hi >= 0) {
      switcherState.index = hi;
      return hi;
    }
  }
  if (switcherState.index >= entries.length) {
    switcherState.index = entries.length - 1;
  }
  if (switcherState.index < 0) switcherState.index = 0;
  return switcherState.index;
}

function switcherAdvance(delta) {
  const entries = buildSwitcherEntries();
  if (!entries.length) return;
  switcherState.index = (switcherState.index + delta + entries.length) % entries.length;
  switcherState.highlightedId = entries[switcherState.index]?.id ?? null;
  renderSwitcherOverlay();
  scheduleSwitcherPreview();
}

function closeSwitcherOverlay() {
  switcherState.open = false;
  switcherState.originId = null;
  switcherState.chord = null;
  switcherState.modifiersHeld = null;
  switcherState.highlightedId = null;
  switcherState.prefixArmedAt = 0;
  if (switcherPreviewTimer) { clearTimeout(switcherPreviewTimer); switcherPreviewTimer = null; }
  const root = document.getElementById('session-switcher');
  if (root) {
    root.hidden = true;
    root.setAttribute('aria-hidden', 'true');
    root.innerHTML = '';
  }
  const prev = switcherState.previousFocus;
  switcherState.previousFocus = null;
  if (prev && typeof prev.focus === 'function') {
    try { prev.focus(); } catch (_) { /* detached node */ }
  }
}

function switcherCommit() {
  if (!switcherState.open) return;
  const entries = buildSwitcherEntries();
  const target = entries[switcherState.index];
  closeSwitcherOverlay();
  if (target && target.id !== selectedId) selectSession(target.id);
}

function switcherCancel() {
  if (!switcherState.open) return;
  const origin = switcherState.originId;
  closeSwitcherOverlay();
  if (origin && origin !== selectedId && sessions.some((s) => s.id === origin)) {
    selectSession(origin);
  }
}

function switcherOnBinding(e) {
  if (!uiConfig.switcherEnabled) return;
  const entries = buildSwitcherEntries();
  if (entries.length <= 1) return;
  disarmSwitcherPrefix();
  if (!switcherState.open) {
    switcherState.open = true;
    switcherState.originId = selectedId;
    switcherState.previousFocus = document.activeElement;
    captureSwitcherModifiers(e);
    const cur = entries.findIndex((s) => s.id === selectedId);
    switcherState.index = cur >= 0 ? (cur + 1) % entries.length : 0;
    switcherState.highlightedId = entries[switcherState.index]?.id ?? null;
    if (isTerminalFocused()) document.activeElement.blur();
    renderSwitcherOverlay();
    scheduleSwitcherPreview();
  } else {
    switcherAdvance(1);
  }
  e.preventDefault();
  e.stopPropagation();
}

function renderSwitcherCard(s, highlighted) {
  const card = el('div', 'switcher-card' + (highlighted ? ' highlighted' : ''));
  card.setAttribute('role', 'option');
  card.setAttribute('aria-selected', highlighted ? 'true' : 'false');
  if (highlighted) card.tabIndex = 0;
  card.onclick = (ev) => {
    ev.stopPropagation();
    switcherState.index = buildSwitcherEntries().findIndex((x) => x.id === s.id);
    switcherState.highlightedId = s.id;
    switcherCommit();
  };
  const top = el('div', 'switcher-card-top');
  const cat = el('span', 'switcher-cat', switcherCategoryLabel(s));
  top.appendChild(cat);
  const badge = el('span', 'status-badge', s.status);
  badge.style.color = STATUS_COLOR[s.status] || 'var(--text-muted)';
  top.appendChild(badge);
  if (liveFor(s.id).remote_control_active) top.appendChild(rcGlyph());
  card.appendChild(top);

  const title = el('div', 'switcher-name');
  title.appendChild(el('span', 'agent', AGENT_GLYPH[s.agent_kind] || '•'));
  title.appendChild(el('span', '', s.name));
  card.appendChild(title);

  const ind = activityIndicator(s);
  if (ind.label) {
    const act = el('span', 'switcher-activity', ind.label);
    act.style.color = ind.color;
    card.appendChild(act);
  }

  if (s.ticket_title) card.appendChild(el('div', 'switcher-subtle', s.ticket_title));
  const rev = reviewForSession(s.id);
  if (rev && rev.author) {
    card.appendChild(el('div', 'switcher-subtle', 'PR by @' + rev.author));
  } else if (s.review_author) {
    card.appendChild(el('div', 'switcher-subtle', 'PR by @' + s.review_author));
  }
  if (s.repo) {
    card.appendChild(el('div', 'switcher-meta', s.repo + (s.branch ? ' · ' + s.branch : '')));
  }
  const prLink = (s.links || []).find((l) => l.type === 'pr') || liveFor(s.id).pr_link;
  if (prLink) card.appendChild(el('div', 'switcher-meta', prLink.label || prLink.url));

  if (highlighted) {
    const prev = el('pre', 'switcher-preview');
    prev.textContent = '';
    card.appendChild(prev);
  }
  return card;
}

function renderSwitcherOverlay() {
  const root = document.getElementById('session-switcher');
  if (!root) return;
  const entries = buildSwitcherEntries();
  if (!switcherState.open || entries.length <= 1) {
    closeSwitcherOverlay();
    return;
  }
  switcherClampIndex(entries);
  switcherState.highlightedId = entries[switcherState.index]?.id ?? null;
  root.hidden = false;
  root.setAttribute('aria-hidden', 'false');
  root.innerHTML = '';
  const panel = el('div', 'switcher-panel');
  const strip = el('div', 'switcher-strip');
  strip.setAttribute('role', 'listbox');
  strip.setAttribute('aria-label', 'Sessions');
  const hi = switcherState.index;
  entries.forEach((s, i) => {
    strip.appendChild(renderSwitcherCard(s, i === hi));
  });
  panel.appendChild(strip);
  const hint = el('div', 'switcher-hint', switcherCommitHint());
  panel.appendChild(hint);
  root.appendChild(panel);
  requestAnimationFrame(() => {
    const card = strip.querySelector('.switcher-card.highlighted');
    if (card) {
      card.scrollIntoView({ inline: 'center', block: 'nearest' });
      card.focus();
    }
  });
  fillSwitcherPreview();
}

function scheduleSwitcherPreview() {
  if (!uiConfig.switcherPreview) return;
  if (switcherPreviewTimer) clearTimeout(switcherPreviewTimer);
  switcherPreviewTimer = setTimeout(() => {
    switcherPreviewTimer = null;
    fillSwitcherPreview();
  }, SWITCHER_PREVIEW_DEBOUNCE_MS);
}

async function fillSwitcherPreview() {
  if (!uiConfig.switcherPreview || !switcherState.open) return;
  const entries = buildSwitcherEntries();
  const s = entries[switcherState.index];
  if (!s) return;
  const cached = switcherPreviewCache.get(s.id);
  const now = Date.now();
  if (cached && (now - cached.at) < SWITCHER_PREVIEW_CACHE_MS) {
    setSwitcherPreviewText(cached.text);
    return;
  }
  const seq = ++switcherPreviewSeq;
  try {
    const res = await rpc('get-session-terminal-preview', { session_id: s.id });
    if (seq !== switcherPreviewSeq || !switcherState.open) return;
    const text = (res && res.preview) ? String(res.preview) : '';
    switcherPreviewCache.set(s.id, { text, at: Date.now() });
    setSwitcherPreviewText(text);
  } catch (_) { /* best-effort */ }
}

function setSwitcherPreviewText(text) {
  const pre = document.querySelector('#session-switcher .switcher-card.highlighted .switcher-preview');
  if (pre) pre.textContent = text || '';
}

function isTerminalFocused() {
  const node = document.getElementById('terminal');
  return !!(node && document.activeElement && node.contains(document.activeElement));
}

function onSwitcherKeyDown(e) {
  if (!uiConfig.switcherEnabled) return;
  if (switcherState.open) {
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      switcherCancel();
      return;
    }
    if (e.key === 'Enter') {
      // The commit gesture for a chord that holds nothing down (`esc+tab`).
      // Harmless for the others — they commit on release before Enter matters.
      e.preventDefault();
      e.stopPropagation();
      switcherCommit();
      return;
    }
    if (e.key === 'ArrowRight') {
      e.preventDefault();
      e.stopPropagation();
      switcherAdvance(1);
      return;
    }
    if (e.key === 'ArrowLeft') {
      e.preventDefault();
      e.stopPropagation();
      switcherAdvance(-1);
      return;
    }
    // Cycling once open needs the key alone — re-tapping the prefix for every
    // step would be unusable, so this deliberately skips the armed check.
    if (eventMatchesSwitcherBinding(e, uiConfig.switcherBinding)) {
      e.preventDefault();
      e.stopPropagation();
      switcherAdvance(1);
      return;
    }
    // Swallow everything else so keystrokes don't reach the focused xterm.
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (e.type !== 'keydown') return;
  const chord = parseSwitcherBinding(uiConfig.switcherBinding);
  if (chord.prefix) {
    if (e.key === chord.prefix) {
      // Arm and get out of the way: Esc is never consumed here. It has to stay
      // instant for interrupting an agent, and holding it back on the chance a
      // Tab follows would add latency to every single press.
      armSwitcherPrefix();
      return;
    }
    // Any other key breaks the sequence — except a bare modifier, which a user
    // may well be resting on. Without this, Esc → "ls" → Tab would still open.
    if (!eventMatchesSwitcherBinding(e, uiConfig.switcherBinding)) {
      if (!switcherBindingModifierFromEvent(e)) disarmSwitcherPrefix();
      return;
    }
    if (!switcherPrefixArmed()) return;
  } else if (!eventMatchesSwitcherBinding(e, uiConfig.switcherBinding)) {
    return;
  }
  if (isTerminalFocused() && !switcherCapturesInTerminal()) return;
  if (document.querySelector('.text-prompt-backdrop, .modal-dialog-backdrop, .settings-overlay')) return;
  switcherOnBinding(e);
}

function onSwitcherKeyUp(e) {
  if (!switcherState.open || !switcherState.chord || !switcherState.modifiersHeld) return;
  const mod = switcherBindingModifierFromEvent(e);
  if (mod && switcherState.chord[mod]) {
    e.preventDefault();
    e.stopPropagation();
    switcherState.modifiersHeld[mod] = false;
    if (!switcherBindingModifiersActive()) switcherCommit();
    return;
  }
  // A prefix chord releases the prefix long before the overlay opens, so
  // committing on release would close it on the very keystroke that opened it.
  // It stays open and waits for Enter (or a click) instead.
  if (!switcherBindingHasModifiers(switcherState.chord)
      && !switcherState.chord.prefix
      && eventMatchesSwitcherBinding(e, uiConfig.switcherBinding)) {
    e.preventDefault();
    e.stopPropagation();
    switcherCommit();
  }
}

document.addEventListener('keydown', onSwitcherKeyDown, true);
document.addEventListener('keyup', onSwitcherKeyUp, true);

// `opts.fromRoute` marks a call that is *applying* a URL rather than initiating
// one. The distinction is load-bearing: when applying, the URL is authoritative,
// and synthesizing a terminal it didn't ask for turns navigate() into a push —
// breaking the invariant ADR 0018 rests on. Concretely it walled Back inside a
// session: every visit leaves #/sessions/A then #/sessions/A/t/T in history, and
// applying the bare entry re-pushed /t/T, truncating the forward entry so Back
// could never move past it (review).
async function selectSession(id, opts) {
  const fromRoute = !!(opts && opts.fromRoute);
  touchSessionMRU(id);
  // Synchronous, before the first await: applyRoute relies on the hash being
  // settled by the time anything else can observe it. A pending terminal is
  // carried either way (it came *from* the URL). The active one is carried only
  // for a click, so re-selecting the row you're on keeps its /t/<id> instead of
  // dropping it while that tab stays open.
  const routedTerminal = pendingTerminalId
    || (fromRoute ? null : (id === selectedId && activeTerminal ? activeTerminal.id : null));
  navigate({ view: 'session', sessionId: id, terminalId: routedTerminal });
  // A bare #/sessions/<id> asked for no particular tab, so snap to terminals[0]
  // rather than leaving the previous one on screen — otherwise Back leaves the
  // URL bare while T2 is shown, and reloading that same URL would land on T1.
  if (fromRoute && !pendingTerminalId) activeTerminal = null;
  selectedId = id;
  selectedBoard = null;
  const app = document.getElementById('app');
  app.classList.add('has-selection');
  app.classList.remove('board-active', 'mobile-show-sidebar', 'route-missing'); // leave board, reveal terminal on mobile
  document.getElementById('board').innerHTML = '';
  document.getElementById('board').classList.remove('session-grid-board');
  leaveGridView();
  renderSidebar();
  renderHeader(sessions.find((x) => x.id === id));
  ensureTerminal();
  setTimeout(fitTerminal, 50); // detail pane just became visible (mobile) — refit
  await refreshTerminals();
  refreshLive();
  refreshArtifacts(id);
}
