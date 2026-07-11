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

// Connection light in the bottom-left status bar tracks the /rpc control socket
// (CROW-593): green when open, amber while (re)connecting.
let wsConnected = false;
// A remote (non-loopback) web session whose cookie is no longer valid — set when a
// disconnect + /auth/check probe confirms 401 (a crowd restart wiped its in-memory
// sessions). Stops the reconnect loop and flips the status bar to "Log in" (CROW-593).
let sessionDead = false;
function setWsConnected(v) {
  if (wsConnected === v) return;
  wsConnected = v;
  renderStatusBar();
}

function rpcConnect() {
  const p = new Promise((resolve, reject) => {
    let opened = false;
    const ws = new WebSocket(wsURL('/rpc'));
    ws.onopen = () => { opened = true; setWsConnected(true); resolve(ws); };
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
    ws.onclose = () => {
      setWsConnected(false);
      // Fail fast: a socket that closed before opening must reject so `await
      // rpcState.ready` can't hang when the daemon is down (review #8).
      if (!opened) reject(new Error('rpc: socket closed before open'));
      // Reject in-flight rpcs instead of leaving them stuck until the 10s timeout.
      rpcState.pending.forEach((w) => w.reject(new Error('rpc: connection closed')));
      rpcState.pending.clear();
      // A crowd restart wipes its in-memory sessions, so a remote web cookie may now
      // be invalid — probe and, if so, stop reconnecting and surface "Log in" (CROW-593).
      handleAuthOnDisconnect();
      // Reconnect once — and only if this connection is still the active one, so
      // an rpc() opened during the window can't leave a duplicate socket that
      // double-fires `changed` refreshes (review #9). Skipped once the session is dead.
      if (rpcState.ready === p) {
        rpcState.ready = null;
        setTimeout(() => { if (!rpcState.ready && !sessionDead) rpcState.ready = rpcConnect(); }, 1000);
      }
    };
    ws.onerror = () => ws.close();
  });
  return p;
}

async function rpc(method, params) {
  // Session is dead (cookie invalid): don't spin up doomed reconnects — fail fast so
  // background pollers stop churning and the "Log in" affordance stands (CROW-593).
  if (sessionDead) throw new Error('session expired — log in');
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

// Sidebar-affecting slice of AppConfig (CROW-581). `set-config` doesn't push a
// `changed`, so we load this on boot and re-load it when the Settings modal
// saves (via `window.reloadUIConfig`). Mirrors the desktop's
// `appState.hideSessionDetails`.
const uiConfig = { hideSessionDetails: false, notifications: null, webPasswordSet: false };
async function loadUIConfig() {
  try {
    const res = await rpc('get-config');
    const cfg = JSON.parse((res && res.config) || '{}');
    uiConfig.hideSessionDetails = !!(cfg.sidebar && cfg.sidebar.hideSessionDetails);
    uiConfig.notifications = parseNotificationSettings(cfg.notifications);
    // Presence of the (secret-stripped) webAuth block means a web password is set.
    uiConfig.webPasswordSet = !!cfg.webAuth;
    // First-run gate: pointer absent → show the setup wizard (CROW-605).
    if (res && res.configured === false && !document.getElementById('wizard')) {
      showWizard(res.default_dev_root || '');
    }
  } catch (_) { /* keep defaults */ }
  renderSidebar();
  renderStatusBar();
}
window.reloadUIConfig = loadUIConfig;

// ---------------------------------------------------------------------------
// Notification sounds — mirror the desktop's NotificationManager triggers over
// the state the web already receives. The app plays macOS NSSound on five
// events; a browser can't, so we synthesize the same tones the Settings picker
// auditions (previewSound) and fire them off client-side state transitions
// (CROW-593). Gating mirrors the app exactly:
//   play ⇔ !globalMute && evt.enabled && settings.soundEnabled && evt.soundEnabled
// playing evt.soundName, with the app's 2s per-(session,event) dedup.
// ---------------------------------------------------------------------------

// NotificationEvent.defaultSound (CrowCore) — used when config omits an event
// (e.g. changesRequested/checksFailing, absent from the current config.json).
const DEFAULT_EVENT_SOUND = {
  taskComplete: 'Glass', agentWaiting: 'Funk', reviewRequested: 'Glass',
  changesRequested: 'Funk', checksFailing: 'Sosumi',
};

// NotificationEvent.displayName / .description (CrowCore) — reused for the
// browser-notification title/body so the web matches the desktop wording.
const EVENT_LABEL = {
  taskComplete: 'Task Complete', agentWaiting: 'Agent Waiting',
  reviewRequested: 'Review Requested', changesRequested: 'Changes Requested',
  checksFailing: 'CI Failing',
};
const EVENT_DESC = {
  taskComplete: 'Claude finished responding',
  agentWaiting: 'Claude needs your input or permission',
  reviewRequested: 'Someone requested your review on a PR',
  changesRequested: 'A reviewer requested changes on your PR',
  checksFailing: 'CI checks started failing on your PR',
};

// Crow brandmark (96px) as a data URL, so notifications are visibly ours
// without adding a server asset route — Chrome won't render SVG notification
// icons, and this keeps the whole feature live-reloadable (CROW-593).
const CROW_ICON = 'data:image/png;base64,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';

// Swift encodes `[NotificationEvent: EventNotificationConfig]` as a flat
// [key, value, key, value, …] array (enum keys aren't String/Int). Fold it back
// into an object; tolerate an object form too.
function parseNotificationSettings(n) {
  n = n || {};
  const events = {};
  const es = n.eventSettings;
  if (Array.isArray(es)) {
    for (let i = 0; i + 1 < es.length; i += 2) events[es[i]] = es[i + 1] || {};
  } else if (es && typeof es === 'object') {
    Object.assign(events, es);
  }
  return {
    globalMute: !!n.globalMute,
    soundEnabled: n.soundEnabled !== false, // NotificationSettings default: true
    systemNotificationsEnabled: n.systemNotificationsEnabled !== false, // default: true
    events,
  };
}

// Web Audio tone recipes — kept in sync with settings.js previewSound so an
// event chime is the exact tone the user auditioned in Settings.
const SOUND_TONES = {
  Basso: [{ freq: 147, type: 'sawtooth', dur: 0.22 }],
  Blow: [{ freq: 523, type: 'sine', dur: 0.18 }],
  Bottle: [{ freq: 392, type: 'sine', dur: 0.12 }, { freq: 784, at: 0.08, dur: 0.1 }],
  Frog: [{ freq: 196, type: 'square', dur: 0.1 }, { freq: 294, at: 0.1, type: 'square', dur: 0.12 }],
  Funk: [{ freq: 220, type: 'triangle', dur: 0.14 }, { freq: 330, at: 0.12, type: 'triangle', dur: 0.14 }],
  Glass: [{ freq: 880, type: 'sine', dur: 0.12 }, { freq: 1320, at: 0.06, dur: 0.16 }],
  Hero: [{ freq: 523, type: 'sine', dur: 0.12 }, { freq: 784, at: 0.12, dur: 0.18 }],
  Morse: [{ freq: 660, type: 'square', dur: 0.08 }, { freq: 660, at: 0.14, type: 'square', dur: 0.08 }],
  Ping: [{ freq: 1046, type: 'sine', dur: 0.14 }],
  Pop: [{ freq: 440, type: 'sine', dur: 0.07 }],
  Purr: [{ freq: 165, type: 'triangle', dur: 0.22 }],
  Sosumi: [{ freq: 660, type: 'square', dur: 0.1 }, { freq: 440, at: 0.1, type: 'square', dur: 0.16 }],
  Submarine: [{ freq: 131, type: 'sine', dur: 0.28 }],
  Tink: [{ freq: 1318, type: 'sine', dur: 0.1 }],
  _default: [{ freq: 700, type: 'sine', dur: 0.14 }],
};

const crowSound = (() => {
  let ctx = null;
  function ensure() {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    if (!ctx) { try { ctx = new AC(); } catch (_) { return null; } }
    if (ctx.state === 'suspended') ctx.resume(); // no-op once unlocked
    return ctx;
  }
  function play(name) {
    const c = ensure();
    if (!c) return;
    const recipe = SOUND_TONES[name] || SOUND_TONES._default;
    const now = c.currentTime;
    for (const step of recipe) {
      const osc = c.createOscillator(), gain = c.createGain();
      osc.type = step.type || 'sine';
      osc.frequency.value = step.freq;
      const t0 = now + (step.at || 0), dur = step.dur || 0.12;
      gain.gain.setValueAtTime(0.0001, t0);
      gain.gain.exponentialRampToValueAtTime(0.2, t0 + 0.012);
      gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
      osc.connect(gain); gain.connect(c.destination);
      osc.start(t0); osc.stop(t0 + dur + 0.03);
    }
  }
  return { play, unlock: ensure };
})();

// Web Audio starts suspended until a user gesture (autoplay policy) — unlock on
// the first interaction so event chimes play thereafter.
['pointerdown', 'keydown'].forEach((e) =>
  window.addEventListener(e, () => crowSound.unlock(), { once: true, passive: true }));

// Suppress chimes until the first sessions+live+reviews load settles, so opening
// the page doesn't replay every already-waiting session / existing review.
let _soundArmed = false;
setTimeout(() => { _soundArmed = true; }, 2500);

// Fire an event chime if the notification config allows it, with the app's 2s
// per-(key,event) dedup. `key` is a session/review id so distinct sessions
// don't suppress each other.
const _lastSoundAt = {};
function playEventSound(event, key) {
  const N = uiConfig.notifications;
  if (!N) return;            // config not loaded yet — don't guess the mute state
  if (N.globalMute) return;
  if (!N.soundEnabled) return;
  const cfg = N.events[event] || {};
  if (cfg.enabled === false) return;       // per-event master toggle
  if (cfg.soundEnabled === false) return;  // per-event sound toggle
  const k = (key || '') + '|' + event;
  const now = Date.now();
  if (_lastSoundAt[k] && now - _lastSoundAt[k] < 2000) return;
  _lastSoundAt[k] = now;
  crowSound.play(cfg.soundName || DEFAULT_EVENT_SOUND[event] || 'Glass');
}

// Manual test hook. crowTestSound() plays each event once (staggered);
// crowTestSound('agentWaiting') plays one. Bypasses config/dedup so it's always
// audible — useful to confirm audio works and hear each configured tone.
window.crowTestSound = function (event) {
  const evs = event
    ? [event]
    : ['taskComplete', 'agentWaiting', 'reviewRequested', 'changesRequested', 'checksFailing'];
  evs.forEach((ev, i) => setTimeout(() => {
    const cfg = (uiConfig.notifications && uiConfig.notifications.events[ev]) || {};
    const name = cfg.soundName || DEFAULT_EVENT_SOUND[ev] || 'Glass';
    crowSound.play(name);
    console.log('[crowSound] test', ev, '→', name);
  }, i * 700));
};

// --- Browser notifications (Web Notification API) --------------------------
// The desktop app posts UNUserNotifications; the web equivalent is the browser
// Notification API, which also works inside the Tauri desktop app once the wrapper
// grants notification permission. Fires on the same events as sounds, gated on
// the same config's SYSTEM-notification toggles (systemNotificationsEnabled +
// per-event enabled/systemNotificationEnabled), with the desktop's focus rule
// and a 2s per-(session,event) dedup. Permission is requested only from an
// explicit user action (Settings button) — never auto-prompted (CROW-593).

function inTauri() { return typeof window !== 'undefined' && !!window.__TAURI__; }
// Native notifications via the Tauri plugin (desktop wrapper). WKWebView has no
// Web Notification API, so inside the app we route through Tauri instead of
// `new Notification` (CROW-593 desktop).
function tauriNotify(title, body) {
  try {
    const n = window.__TAURI__ && window.__TAURI__.notification;
    if (n && n.sendNotification) { n.sendNotification({ title, body }); return true; }
  } catch (_) { /* ignore */ }
  return false;
}
function notificationsSupported() {
  return inTauri() || (typeof window !== 'undefined' && 'Notification' in window);
}
// In the desktop app, request native notification permission once up front.
(function requestTauriNotifPermission() {
  if (!inTauri()) return;
  try {
    const n = window.__TAURI__.notification;
    if (n && n.isPermissionGranted && n.requestPermission) {
      n.isPermissionGranted().then((granted) => { if (!granted) n.requestPermission(); }).catch(() => {});
    }
  } catch (_) { /* ignore */ }
})();
function sessionNameFor(id) {
  const s = sessions.find((x) => x.id === id);
  return (s && s.name) || 'Session';
}

const _lastNotifyAt = {};
function showEventNotification(event, key) {
  const N = uiConfig.notifications;
  if (!N) return;                          // config not loaded — don't guess
  if (N.globalMute) return;
  if (!N.systemNotificationsEnabled) return;
  const cfg = N.events[event] || {};
  if (cfg.enabled === false) return;               // per-event master toggle
  if (cfg.systemNotificationEnabled === false) return; // per-event notif toggle
  if (!notificationsSupported()) return;
  if (!inTauri() && Notification.permission !== 'granted') return;

  const isSession = !!sessions.find((x) => x.id === key);
  // Focus-suppression, mirroring NotificationManager (!appFocused || !visible):
  // don't ping about the session you're already looking at.
  if (isSession && document.hasFocus() && selectedId === key) return;

  const k = (key || '') + '|' + event;
  const now = Date.now();
  if (_lastNotifyAt[k] && now - _lastNotifyAt[k] < 2000) return;
  _lastNotifyAt[k] = now;

  const label = EVENT_LABEL[event] || event;
  let body = EVENT_DESC[event] || '';
  if (isSession) {
    body = `${sessionNameFor(key)} — ${body}`;
  } else {
    const r = ((boardData.reviews && boardData.reviews.reviews) || []).find((x) => x.id === key);
    if (r && r.repo) body = `${r.repo} — ${body}`;
  }
  try {
    // In the desktop app, WKWebView lacks the Web Notification API — post via the
    // Tauri plugin instead. (Click-to-focus below stays web-only.)
    if (inTauri()) { tauriNotify(`Crow — ${label}`, body); return; }
    // "Crow — <event>" so the source is unmistakable even where the icon can't
    // render; CROW_ICON is a raster data-URL icon (Chrome ignores SVG icons).
    const n = new Notification(`Crow — ${label}`, {
      body, tag: k, icon: CROW_ICON, badge: CROW_ICON,
    });
    // Clicking focuses the window and returns to where it originated: the
    // session for session events, or the review's session / reviews board.
    n.onclick = () => {
      window.focus();
      try {
        if (isSession) {
          selectSession(key);
        } else {
          const r = ((boardData.reviews && boardData.reviews.reviews) || []).find((x) => x.id === key);
          if (r && r.review_session_id) selectSession(r.review_session_id);
          else selectBoard('reviews');
        }
      } catch (_) { /* nav best-effort */ }
      n.close();
    };
  } catch (_) { /* Notification ctor can throw in restricted contexts */ }
}

// Both channels fire from one call in the detectors below; each self-gates.
function emitEvent(event, key) {
  playEventSound(event, key);
  showEventNotification(event, key);
}

// Manual test hook, mirroring crowTestSound. crowTestNotify() shows one popup
// per event (staggered); crowTestNotify('agentWaiting') shows one. Requests
// permission first if needed. Bypasses config/dedup so it's always visible.
window.crowTestNotify = function (event) {
  if (!notificationsSupported()) { console.warn('[crowNotify] Notification API unavailable'); return; }
  const fire = () => {
    const evs = event
      ? [event]
      : ['taskComplete', 'agentWaiting', 'reviewRequested', 'changesRequested', 'checksFailing'];
    evs.forEach((ev, i) => setTimeout(() => {
      try {
        const n = new Notification(`Crow — ${EVENT_LABEL[ev] || ev} (test)`, {
          body: EVENT_DESC[ev] || '', tag: 'test|' + ev, icon: CROW_ICON,
        });
        n.onclick = () => { window.focus(); n.close(); };
      } catch (_) {}
      console.log('[crowNotify] test', ev);
    }, i * 900));
  };
  if (Notification.permission === 'granted') fire();
  else Notification.requestPermission().then((p) => { if (p === 'granted') fire(); else console.warn('[crowNotify] permission:', p); });
};

// Event detection: diff successive state snapshots. Snapshots always update; the
// arm gate + per-session "first sighting" guard keep load/new-session appearances
// from chiming — only genuine transitions do.
let _prevSessionSnap = null;
function detectSessionSounds() {
  const snap = {};
  for (const s of sessions) {
    const pr = liveFor(s.id).pr || {};
    snap[s.id] = {
      attention: s.attention || '',
      activity: s.activity || '',
      // Mirror the desktop PRStatusTransition kinds (gated on not-merged).
      changes: !pr.is_merged && pr.review === 'changesRequested',
      checks: !pr.is_merged && pr.checks === 'failing',
    };
  }
  const prevSnap = _prevSessionSnap;
  _prevSessionSnap = snap;
  if (!_soundArmed || !prevSnap) return;
  for (const id in snap) {
    const prev = prevSnap[id];
    if (!prev) continue; // first sighting of this session — baseline only
    const cur = snap[id];
    if (cur.attention && !prev.attention) emitEvent('agentWaiting', id);
    if (cur.activity === 'done' && prev.activity !== 'done') emitEvent('taskComplete', id);
    if (cur.changes && !prev.changes) emitEvent('changesRequested', id);
    if (cur.checks && !prev.checks) emitEvent('checksFailing', id);
  }
}

let _prevReviewIDs = null;
function detectReviewSounds() {
  const rs = (boardData.reviews && boardData.reviews.reviews) || [];
  const ids = new Set(rs.map((r) => r.id).filter(Boolean));
  const prev = _prevReviewIDs;
  _prevReviewIDs = ids;
  if (!_soundArmed || !prev) return;
  for (const r of rs) if (r.id && !prev.has(r.id)) emitEvent('reviewRequested', r.id);
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
let sessions = [];
// False until the first successful list-sessions RPC. While false and sessions
// are empty, the sidebar paints skeleton placeholders instead of "No sessions"
// (CROW-613). A localStorage cache can populate `sessions` before that RPC.
let sessionsLoaded = false;
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

// Last-known sidebar layout (sessions + ticket/review badge counts) so first
// paint isn't blank while /rpc connects (CROW-613).
const SIDEBAR_CACHE_KEY = 'crow.sidebar.cache';
// True when boot restored a cache entry (including an empty sessions list) —
// distinguishes "remembered empty" from a cold start that should show skeletons.
let sidebarCacheHit = false;
function clearSidebarCache() {
  try { localStorage.removeItem(SIDEBAR_CACHE_KEY); } catch (_) {}
  sidebarCacheHit = false;
}
function restoreSidebarCache() {
  try {
    const raw = localStorage.getItem(SIDEBAR_CACHE_KEY);
    if (!raw) return;
    const data = JSON.parse(raw);
    if (Array.isArray(data.sessions)) sessions = data.sessions;
    if (data.tickets) boardData.tickets = data.tickets;
    if (data.reviews) boardData.reviews = data.reviews;
    sidebarCacheHit = true;
  } catch (_) { /* corrupt cache — start empty */ }
}
function persistSidebarCache() {
  try {
    localStorage.setItem(SIDEBAR_CACHE_KEY, JSON.stringify({
      sessions,
      tickets: boardData.tickets,
      reviews: boardData.reviews,
    }));
    sidebarCacheHit = true;
  } catch (_) { /* quota / private mode */ }
}
let ticketFilter = 'All'; // pipeline segment ('All' or a status rawValue); default to All so the board isn't misread as empty when work moves to Done
let allowlistHideGlobal = false;
const allowlistSelection = new Set();
// Session multi-select (#5): toggled by the sidebar checkmark button; holds the
// ids of sessions ticked for a bulk action (delete).
let selectionMode = false;
const selectedSessionIDs = new Set();
// Ticket-board multi-select (CROW-660): mirrors the native TicketBoardView
// multi-select. Toggled by the board's Select button; holds the urls of tickets
// ticked for the batch "Start Working (N)" action.
let ticketSelectionMode = false;
const selectedIssueIDs = new Set();
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
    const next = res.sessions || [];
    const changed = JSON.stringify(sessions) !== JSON.stringify(next);
    sessions = next;
    sessionsLoaded = true;
    if (changed) persistSidebarCache();
    detectSessionSounds();
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
  detectSessionSounds();
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
    sessionsLoaded, sidebarCacheHit, sessions, liveById, selectedId, selectedBoard,
    selectionMode, [...selectedSessionIDs],
    uiConfig.hideSessionDetails,
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

  // Cold start only: structured skeleton rows so the left pane isn't blank
  // while list-sessions is in flight. A cached empty workspace keeps the
  // remembered "No sessions" state instead of shimmering (CROW-613).
  if (!sessionsLoaded && !sessions.length && !sidebarCacheHit) {
    root.appendChild(el('div', 'divider', 'Active'));
    for (let i = 0; i < 4; i++) root.appendChild(skeletonRow(i));
    return;
  }

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
  if ((sessionsLoaded || sidebarCacheHit) && !shown && !managers.length) {
    root.appendChild(el('div', 'empty', 'No sessions'));
  }
}

// Placeholder session card matching .session-row geometry so real rows swap in
// without a full re-layout jump (CROW-613).
function skeletonRow(i) {
  const row = el('div', 'session-row skeleton-row');
  row.setAttribute('aria-hidden', 'true');
  // Stagger the shimmer so the column doesn't pulse in lockstep.
  row.style.setProperty('--skel-delay', ((i % 4) * 0.12) + 's');
  const top = el('div', 'row-top');
  top.appendChild(el('span', 'skel skel-agent'));
  top.appendChild(el('span', 'skel skel-name'));
  top.appendChild(el('span', 'skel skel-dot'));
  row.appendChild(top);
  if (!uiConfig.hideSessionDetails) {
    row.appendChild(el('div', 'skel skel-subtle'));
    row.appendChild(el('div', 'skel skel-meta'));
  }
  return row;
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
  if (!await confirmModal('Delete ' + ids.length + ' session' + (ids.length === 1 ? '' : 's')
    + '? This removes their worktrees and terminals.', { okLabel: 'Delete', danger: true })) return;
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
  if (failed) alertModal(failed + ' session(s) could not be deleted.');
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
      // Parity with explicit logout: drop cached session/ticket payloads when
      // the remote web cookie dies (crowd restart) so they don't linger in a
      // shared browser (CROW-613 review).
      clearSidebarCache();
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
    login.onclick = () => { location.href = '/login'; };
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
      // Drop cached session/ticket payloads so a shared browser can't read them
      // after logout of a password-protected remote session (CROW-613 review).
      clearSidebarCache();
      location.reload();  // now unauthenticated → the auth gate serves the login page
    };
    actions.appendChild(out);
  }
}

// Settings + Select, stacked vertically to the right of the Tickets card
// (outside the box): Settings on top, Select below.
function sidebarToolsStack() {
  const stack = el('div', 'sidebar-tools');
  const gear = el('button', 'tk-tool');
  gear.title = 'Settings';
  gear.appendChild(icon('wrench', 14));
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
  catch (e) { alertModal('New manager failed: ' + (e.message || e)); }
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
  wrench: '<path d="M11.8 2.4a2.8 2.8 0 0 0-3.3 3.7L2.9 11.7a1.3 1.3 0 0 0 1.8 1.8l5.6-5.6a2.8 2.8 0 0 0 3.7-3.3l-1.9 1.9-1.6-.4-.4-1.6z"/>',
  logout: '<path d="M6.5 3.5H3.5v9h3"/><path d="M12.5 8H6.5"/><path d="M10 5.5 12.5 8 10 10.5"/>',
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
  // Touch devices have no right-click: a long-press opens the same menu at the
  // finger, the standard mobile equivalent (rename/delete were unreachable on
  // mobile otherwise — CROW-593).
  attachLongPress(row, (x, y) => {
    if (selectionMode) return;
    showSessionMenu({ preventDefault() {}, clientX: x, clientY: y }, s);
  });
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

  if (!uiConfig.hideSessionDetails) {
    if (s.ticket_title) content.appendChild(el('div', 'subtle', s.ticket_title));
    if (s.repo) content.appendChild(el('div', 'meta', s.repo + (s.branch ? ' · ' + s.branch : '')));
  }

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
  // Activity badge (Working/Waiting/Done/…) is redundant on managers — they
  // already show the trailing status dot, and the badge forces a second line.
  if (ind.label && s.kind !== 'manager') {
    const activity = el('span', 'activity-badge', ind.label);
    activity.style.color = ind.color;
    badges.appendChild(activity);
  }
  if (badges.children.length) content.appendChild(badges);

  // Visible actions affordance (tap = same menu as right-click / long-press).
  // The row reserves a right gutter (.session-row padding-right) so this sits in
  // the bottom-right corner clear of the status dot, incl. single-line manager
  // cards. Omitted in multi-select mode, where the checkbox is the action.
  if (!selectionMode) {
    const kebab = el('button', 'row-kebab', '⋮');
    kebab.type = 'button';
    kebab.title = 'Actions';
    kebab.setAttribute('aria-label', 'Session actions');
    kebab.onclick = (e) => {
      e.stopPropagation();
      const r = kebab.getBoundingClientRect();
      showSessionMenu({ preventDefault() {}, clientX: r.right, clientY: r.bottom }, s);
    };
    row.appendChild(kebab);
  }
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
  if (!menu.childElementCount) return; // nothing actionable for this session
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  setTimeout(() => document.addEventListener('click', closeContextMenu, { once: true }), 0);
}

// Long-press → context-menu bridge for touch devices. Fires `handler(x, y)` at
// the touch point after ~500ms if the finger hasn't moved (a scroll/drag past a
// small threshold cancels it), then swallows the trailing click so the row
// isn't also selected. Desktop right-click keeps its own oncontextmenu path.
function attachLongPress(node, handler) {
  let timer = null, sx = 0, sy = 0, fired = false;
  const clear = () => { if (timer) { clearTimeout(timer); timer = null; } };
  node.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) { clear(); return; }
    fired = false;
    sx = e.touches[0].clientX;
    sy = e.touches[0].clientY;
    clear();
    timer = setTimeout(() => { fired = true; timer = null; handler(sx, sy); }, 500);
  }, { passive: true });
  node.addEventListener('touchmove', (e) => {
    if (!timer) return;
    const t = e.touches[0];
    if (Math.abs(t.clientX - sx) > 10 || Math.abs(t.clientY - sy) > 10) clear();
  }, { passive: true });
  node.addEventListener('touchend', (e) => {
    clear();
    if (fired) { e.preventDefault(); fired = false; } // swallow the emulated click
  });
  node.addEventListener('touchcancel', clear, { passive: true });
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
    // Maintenance actions (restart manager / reload tmux) live in Settings → About;
    // the manager row menu stays minimal: just rename and delete.
    items.push({ label: 'Rename', action: () => renameSession(s.id, s.name) });
    items.push({ sep: true });
    items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
    return items;
  }
  if (s.kind === 'review') {
    if (hasPR) items.push({ label: 'Add label crow:merge to PR', action: () => sessionAction('add-merge-label', s.id) });
    items.push({ label: 'Switch agent…', action: () => openHandoffAgentMenu(s, null) });
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
  // Mid-session agent switch when credits run out (CROW-627).
  items.push({ label: 'Switch agent…', action: () => openHandoffAgentMenu(s, null) });
  items.push({ sep: true });
  items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
  return items;
}

async function handoffAgent(sessionId, agentKind) {
  try {
    await rpc('handoff-agent', { session_id: sessionId, agent_kind: agentKind });
    await refreshSessions();
    if (selectedId === sessionId) {
      renderHeader(sessions.find((x) => x.id === sessionId));
      await refreshTerminals();
    }
  } catch (e) {
    alertModal('Switch agent failed: ' + (e.message || e));
  }
}

// Pick a different coding agent for an existing work/job session (CROW-627).
// Reuses the list-agents menu pattern from openNewManagerMenu.
async function openHandoffAgentMenu(session, anchorEl) {
  let agents = [];
  try { const r = await rpc('list-agents'); agents = (r && r.agents) || []; } catch (_) { /* app down */ }
  const others = agents.filter((a) => a.kind && a.kind !== session.agent_kind);
  if (!others.length) {
    alertModal('No other coding agents are available. Install Cursor, Codex, or OpenCode to switch.');
    return;
  }
  closeContextMenu();
  const menu = el('div', 'ctx-menu');
  for (const a of others) {
    const item = el('div', 'ctx-item', 'Hand off to ' + (a.name || a.kind));
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); handoffAgent(session.id, a.kind); };
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const rect = (anchorEl && anchorEl.getBoundingClientRect)
    ? anchorEl.getBoundingClientRect()
    : { left: 16, bottom: 80, top: 80 };
  const x = Math.min(rect.left || 16, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min((rect.bottom || 80) + 4, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  setTimeout(() => document.addEventListener('click', closeContextMenu, { once: true }), 0);
}

async function sessionAction(method, id, extra) {
  try { await rpc(method, Object.assign({ session_id: id }, extra || {})); }
  catch (e) { alertModal(method + ' failed: ' + (e.message || e)); }
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
  // Clickable agent row for non-manager sessions with a worktree (CROW-627).
  if (s.kind !== 'manager' && s.worktree_path) {
    const agentMeta = root.lastChild;
    agentMeta.classList.add('meta-agent');
    agentMeta.title = 'Switch coding agent (handoff)';
    agentMeta.style.cursor = 'pointer';
    agentMeta.onclick = (ev) => { ev.stopPropagation(); openHandoffAgentMenu(s, agentMeta); };
  }

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
    // Only render http(s) chips — a prompt-injected link (javascript:/data:)
    // must never become a clickable href (review).
    if (!/^https?:\/\//i.test(link.url || '')) continue;
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

// In-page single-line text prompt. Replaces window.prompt(), which many browsers
// silently no-op — returning null — over the web: after a "prevent additional
// dialogs" opt-out, on assorted mobile browsers, and in some remote/secure
// contexts. window.prompt failing that way meant the rename rpc was never sent
// (CROW-593). Returns the entered string, or null on cancel/Escape/backdrop.
// In-page confirm/alert modal → Promise<boolean> (true = OK/confirm). Replaces
// window.confirm/alert, which render as native chrome (and are jarring inside the
// desktop wrapper). cancelLabel:null makes it an alert (single OK). (CROW-593)
function modalDialog({ title, body, okLabel = 'OK', cancelLabel = 'Cancel', danger = false } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const backdrop = el('div', 'text-prompt-backdrop modal-dialog-backdrop');
    const card = el('div', 'text-prompt-card');
    if (title) card.appendChild(el('div', 'text-prompt-title', title));
    if (body) card.appendChild(el('div', 'text-prompt-body', body));
    const actions = el('div', 'text-prompt-actions');
    const ok = el('button', 'text-prompt-btn primary' + (danger ? ' danger' : ''), okLabel);
    function finish(v) {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(v);
    }
    backdrop.__finish = finish;
    function onKey(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(false); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); finish(true); }
    }
    if (cancelLabel != null) {
      const cancel = el('button', 'text-prompt-btn', cancelLabel);
      cancel.onclick = () => finish(false);
      actions.appendChild(cancel);
    }
    ok.onclick = () => finish(true);
    actions.appendChild(ok);
    card.appendChild(actions);
    backdrop.appendChild(card);
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) finish(false); });
    // One dialog at a time: supersede any stray *modalDialog* backdrop still on
    // screen so a double-fired error can't stack two overlapping cards whose text
    // abuts into one concatenated message (CROW-665). Finish (resolve as cancel)
    // each superseded dialog rather than bare-removing it, so its Promise settles
    // and its capture-phase keydown listener detaches — a plain .remove() orphans
    // both (review Yellow). Runs before this backdrop is in the DOM, so it only
    // matches prior dialogs. Scoped to modalDialog's marker class, so a live
    // `textPrompt` (shares `.text-prompt-backdrop`, resolves only via its own
    // handlers) is never touched.
    document.querySelectorAll('.modal-dialog-backdrop')
      .forEach((b) => (b.__finish ? b.__finish(false) : b.remove()));
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    ok.focus();
  });
}
function confirmModal(body, { title = 'Confirm', okLabel = 'OK', danger = false } = {}) {
  return modalDialog({ title, body, okLabel, cancelLabel: 'Cancel', danger });
}
function alertModal(body, { title = 'Crow' } = {}) {
  return modalDialog({ title, body, okLabel: 'OK', cancelLabel: null });
}

function textPrompt(title, current, { placeholder = '', okLabel = 'Save' } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const backdrop = el('div', 'text-prompt-backdrop');
    const card = el('div', 'text-prompt-card');
    const heading = el('div', 'text-prompt-title', title);
    const input = el('input', 'text-prompt-input');
    input.type = 'text';
    input.value = current || '';
    if (placeholder) input.placeholder = placeholder;
    const actions = el('div', 'text-prompt-actions');
    const cancel = el('button', 'text-prompt-btn', 'Cancel');
    const ok = el('button', 'text-prompt-btn primary', okLabel);
    actions.append(cancel, ok);
    card.append(heading, input, actions);
    backdrop.appendChild(card);

    function finish(value) {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(value);
    }
    function onKey(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(null); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); finish(input.value); }
    }
    cancel.onclick = () => finish(null);
    ok.onclick = () => finish(input.value);
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) finish(null); });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    input.focus();
    input.select();
  });
}

async function renameSession(id, current) {
  const raw = await textPrompt('Rename session', current, { okLabel: 'Rename' });
  const name = raw == null ? null : raw.trim();
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
  if (!await confirmModal('Delete session "' + name + '"? This removes its worktree and terminals.', { okLabel: 'Delete', danger: true })) return;
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
    alertModal('Delete failed: ' + (e.message || e));
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
  // Leaving the ticket board (or re-entering) drops any stale ticket selection.
  ticketSelectionMode = false;
  selectedIssueIDs.clear();
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
  // Non-http(s) urls (javascript:/data: from injected data) render as a plain,
  // non-clickable chip — never an href (review).
  const safe = /^https?:\/\//i.test(url || '');
  const a = document.createElement(safe ? 'a' : 'span');
  a.className = 'link-chip link-' + (type || 'custom');
  if (safe) { a.href = url; a.target = '_blank'; a.rel = 'noopener'; }
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
    alertModal(label + ' failed: ' + (e.message || e));
  }
}

// -- Ticket Board --
function renderTicketBoard(root) {
  const d = boardData.tickets;
  const allIssues = (d && d.issues) || [];
  // Only tickets without a linked session are startable, so only those are
  // selectable. Prune any stale selections (refresh/filter may have removed
  // issues or linked them to a session).
  const selectableUrls = new Set(allIssues.filter((i) => !i.linked_session_id).map((i) => i.url));
  for (const url of [...selectedIssueIDs]) if (!selectableUrls.has(url)) selectedIssueIDs.delete(url);

  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Ticket Board'));
  if (d && d.done_last_24h) head.appendChild(el('span', 'done-chip', d.done_last_24h + ' done · 24h'));
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.onclick = () => refreshTickets();
  head.appendChild(refresh);
  // Select / Cancel toggle (mirrors the native selectToggleButton). Hidden when
  // there is nothing selectable to start work on.
  if (selectableUrls.size) {
    const sel = el('button', 'action-btn' + (ticketSelectionMode ? ' nav-selecting' : ''),
      ticketSelectionMode ? 'Cancel' : 'Select');
    sel.onclick = () => {
      ticketSelectionMode = !ticketSelectionMode;
      if (!ticketSelectionMode) selectedIssueIDs.clear();
      renderBoard();
    };
    head.appendChild(sel);
  } else if (ticketSelectionMode) {
    ticketSelectionMode = false;
  }
  root.appendChild(head);

  // Batch action bar (mirrors the native batchActionBar): shown while selecting
  // with at least one ticket ticked.
  if (ticketSelectionMode && selectedIssueIDs.size) {
    const bar = el('div', 'bulk-bar');
    const n = selectedIssueIDs.size;
    bar.appendChild(el('span', 'bulk-count', n + ' ticket' + (n === 1 ? '' : 's') + ' selected'));
    bar.appendChild(el('div', 'bulk-spacer'));
    const start = el('button', 'action-btn action-primary', 'Start Working (' + n + ')');
    start.onclick = () => startWorkingSelected(start);
    bar.appendChild(start);
    root.appendChild(bar);
  }

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

  let issues = allIssues.slice();
  if (ticketFilter !== 'All') issues = issues.filter((i) => i.project_status === ticketFilter);
  issues.sort((a, b) => (b.updated_at || '').localeCompare(a.updated_at || ''));
  if (!issues.length) { root.appendChild(boardEmpty('No tickets in this view')); return; }
  const list = el('div', 'card-list');
  for (const i of issues) list.appendChild(ticketCard(i));
  root.appendChild(list);
}

function ticketCard(i) {
  const selectable = !i.linked_session_id;
  const selecting = ticketSelectionMode && selectable;
  const isSel = selectedIssueIDs.has(i.url);
  const card = el('div', 'board-card status-accent'
    + (selecting ? ' selecting' : '') + (isSel ? ' selected' : ''));
  card.oncontextmenu = (e) => showCardMenu(e, [
    { label: 'Copy issue link', url: i.url },
    i.pr_url ? { label: 'Copy PR link', url: i.pr_url } : null,
  ]);
  const sc = TICKET_STATUS_COLOR[i.project_status] || 'var(--text-muted)';
  card.style.borderLeftColor = sc;
  // In selection mode a checkbox leads a selectable card and the whole card
  // toggles selection (mirrors the native TicketCard tap-to-select).
  if (selecting) {
    const cb = el('input', 'row-check');
    cb.type = 'checkbox';
    cb.checked = isSel;
    cb.onclick = (e) => { e.stopPropagation(); toggleIssueSelect(i.url); };
    card.appendChild(cb);
    card.onclick = () => toggleIssueSelect(i.url);
  }
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
  } else if (!selecting) {
    const work = el('button', 'action-btn action-primary', 'Start Working');
    work.onclick = () => spawnAction(work, 'work-on-issue', { url: i.url }, 'Start Working');
    foot.appendChild(work);
  }
  card.appendChild(foot);
  return card;
}

function toggleIssueSelect(url) {
  if (selectedIssueIDs.has(url)) selectedIssueIDs.delete(url);
  else selectedIssueIDs.add(url);
  renderBoard();
}

// Batch "Start Working (N)": dispatch work-on-issue for each selected ticket
// (mirrors the native batch action's per-issue dispatch), then clear selection
// and exit selection mode.
async function startWorkingSelected(btn) {
  const urls = ((boardData.tickets && boardData.tickets.issues) || [])
    .filter((i) => !i.linked_session_id && selectedIssueIDs.has(i.url))
    .map((i) => i.url);
  if (!urls.length) return;
  btn.disabled = true;
  btn.textContent = 'Starting…';
  let failed = 0;
  for (const url of urls) {
    try { await rpc('work-on-issue', { url }); selectedIssueIDs.delete(url); }
    catch (_) { failed++; }
  }
  selectedIssueIDs.clear();
  ticketSelectionMode = false;
  refreshTickets();
  renderBoard();
  if (failed) alertModal(failed + ' ticket(s) could not be started.');
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
  clearSel.id = 'allow-clear';
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
      const empty = allowlistSelection.size === 0;
      const promote = document.getElementById('allow-promote');
      if (promote) {
        promote.textContent = 'Promote to Global (' + allowlistSelection.size + ')';
        promote.disabled = empty;
      }
      // Clear was fixed at render time; refresh it here too so ticking the first
      // row from an empty selection enables Clear (review Yellow).
      const clear = document.getElementById('allow-clear');
      if (clear) clear.disabled = empty;
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
    alertModal('Promote failed: ' + (e.message || e));
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
let searchAddon = null;
let termWs = null;

// Terminal font stack: Nerd Fonts → system monospace.
const DEFAULT_TERM_FONT = '"MesloLGS NF", "MesloLGS Nerd Font", "JetBrainsMono Nerd Font", "Hack Nerd Font", "FiraCode Nerd Font", Menlo, Monaco, monospace';

function ensureTerminal() {
  if (term) return;
  fitAddon = new FitAddon.FitAddon();
  const imageAddon = new ImageAddon.ImageAddon({ sixelSupport: true, iipSupport: true, kittySupport: true });
  searchAddon = new SearchAddon.SearchAddon();
  const webLinksAddon = new WebLinksAddon.WebLinksAddon();
  // Config block mirrors CrowTerminal/Resources/xterm/terminal.html.
  term = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: DEFAULT_TERM_FONT,
    theme: { background: '#1e1e1e', foreground: '#d4d4d4' },
    scrollback: 50000,
    allowTransparency: true,
  });
  term.loadAddon(fitAddon);
  term.loadAddon(imageAddon);
  term.loadAddon(searchAddon);
  term.loadAddon(webLinksAddon);
  term.open(document.getElementById('terminal'));
  // WebGL renderer for throughput; must load after open(). Falls back to the
  // default renderer if the GL context is unavailable or gets lost.
  try {
    const webglAddon = new WebglAddon.WebglAddon();
    webglAddon.onContextLoss(() => webglAddon.dispose());
    term.loadAddon(webglAddon);
  } catch (_) { /* WebGL unavailable → canvas/DOM renderer */ }
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
    if (e.metaKey && (e.key === 'f' || e.key === 'F')) {
      textPrompt('Find in terminal', '', { okLabel: 'Find' }).then((q) => {
        if (q && searchAddon) { try { searchAddon.findNext(q); } catch (_) {} }
      });
      return false;
    }
    return true;
  });
  enableTouchScroll(document.getElementById('terminal'));
  enableWheelScroll(document.getElementById('terminal'));
  enableFileDrop(document.getElementById('terminal'));
  window.addEventListener('resize', fitTerminal);
  // Observe the container itself, not just the window: splitter drags / panel
  // collapses resize the surface without firing a window `resize` (#661). Both
  // routes funnel through the coalesced, deduped fitTerminal.
  if (window.ResizeObserver) {
    new ResizeObserver(fitTerminal).observe(document.getElementById('terminal'));
  }
  // The first fit can run with the Menlo fallback before the Nerd Font loads;
  // once its cell metrics settle the grid recomputes, so re-fit (deduped).
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitTerminal);
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

// Let xterm.js own wheel scrolling in the browser: scroll the local 50k-line
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

// Drag-and-drop files into the composer (#644 images, #652 any file). The
// browser can't read a dropped file's filesystem path (and may be a remote
// client), so upload the bytes to crowd, which writes them into the session's
// artifacts dir on the host and returns an absolute path. We then paste that
// (escaped) path into the terminal — parity with a Finder drop into the
// standalone Cursor/Claude Code TUIs, which the agents already consume. No
// trailing newline → the path is inserted, not submitted, so the user can add a
// prompt before pressing Enter. Images additionally surface in the Artifacts
// panel; other files (source, docs, archives, PDFs) are referenced by path only.
function enableFileDrop(node) {
  node.addEventListener('dragover', (e) => {
    // dataTransfer.files is empty during dragover — only .types is populated —
    // so accept any file drag here (all types are handled on drop).
    if (e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files')) {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'copy';
    }
  });
  node.addEventListener('drop', (e) => {
    const files = e.dataTransfer && e.dataTransfer.files;
    if (!files || !files.length) return; // not a file drop → leave to the browser
    e.preventDefault();                   // never navigate the app away on a file drop
    if (selectedId) uploadDroppedFiles(Array.from(files)); // images + non-images alike
  });
}

// Backslash-escape whitespace and shell metacharacters, matching what
// Terminal.app/iTerm insert on a Finder drop (the byte stream the agent TUIs
// already parse). In practice the artifacts path has none of these, so this is
// belt-and-suspenders.
function shellEscapePath(p) {
  return p.replace(/([\s'"\\$`&|;<>()*?!#~\[\]{}])/g, '\\$1');
}

async function uploadDroppedFiles(files) {
  const sid = selectedId;
  const paths = [];
  for (const file of files) {
    try {
      const res = await fetch('/artifacts/' + encodeURIComponent(sid), {
        method: 'POST',
        headers: {
          // Empty for unknown types — the server derives the extension from the
          // filename, so fall back to a generic binary type.
          'Content-Type': file.type || 'application/octet-stream',
          'X-Filename': encodeURIComponent(file.name || 'file'),
        },
        body: file,
        credentials: 'same-origin',
      });
      if (!res.ok) continue;
      const data = await res.json();
      if (data && data.path) paths.push(shellEscapePath(data.path));
    } catch (_) { /* skip this file */ }
  }
  if (paths.length && term) {
    term.focus();
    // Route through xterm's paste so bracketed-paste mode wraps it (same path as
    // pasteIntoTerminal); onData forwards the wrapped bytes to the PTY.
    term.paste(paths.join(' ') + ' ');
  }
}

// Paste the browser clipboard into the terminal (writes to the PTY, same path
// as typing). readText() needs a user gesture — the menu click / Cmd+V is one.
function pasteIntoTerminal() {
  if (!term || !(navigator.clipboard && navigator.clipboard.readText)) return;
  navigator.clipboard.readText().then((text) => {
    // Route through xterm's paste so bracketed-paste mode wraps it when the app
    // enabled it — otherwise hidden newlines in the clipboard auto-execute in the
    // shell (review). onData then forwards the (wrapped) bytes to the PTY.
    if (text) term.paste(text);
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
  items.push({ label: 'Reload terminal', action: reloadTerminal });
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
  if (sessionDead) return; // don't loop after an expired remote cookie (review Yellow)
  termWs = new WebSocket(wsURL('/terminal'));
  termWs.binaryType = 'arraybuffer';
  termWs.onopen = () => {
    // A fresh PTY starts at a default winsize, so force the real size through
    // even if cols/rows match the previous socket, and fit synchronously so the
    // resize reaches the PTY before the scrollback replay (select-window) below.
    lastTermCols = 0;
    lastTermRows = 0;
    applyTermFit();
    if (activeTerminal) selectWindow(activeTerminal.window);
  };
  termWs.onmessage = (event) => {
    if (event.data instanceof ArrayBuffer) term.write(new Uint8Array(event.data));
  };
  termWs.onclose = () => {
    if (sessionDead) return;
    setTimeout(connectTerminalWs, 1000);
  };
  termWs.onerror = () => termWs.close();
}

// Resize path (#661): in a browser the window `resize` event and normal page
// churn (flexbox, scrollbar appearance, devicePixelRatio changes) fire
// constantly, so an unguarded fit()+resize storms tmux with SIGWINCH and the
// grid thrashes into the corruption in the screenshot. Coalesce bursts to one
// fit per animation frame, drop no-op resizes, and never fit a 0×0/detached
// container (degenerate proposeDimensions makes a junk grid). Mirrors the
// desktop surface's applyFit/scheduleFit dedup in
// CrowTerminal/Resources/xterm/terminal.html.
let lastTermCols = 0;
let lastTermRows = 0;
let fitScheduled = false;

function applyTermFit() {
  if (!term || !fitAddon) return;
  const node = document.getElementById('terminal');
  if (!node || !node.isConnected || node.clientWidth < 1 || node.clientHeight < 1) return;
  try { fitAddon.fit(); } catch (_) { return; }
  // Only tell the PTY when the grid actually changed — a same-size resize is a
  // needless SIGWINCH that makes the agent TUI re-reflow and clobber (#637).
  if (term.cols === lastTermCols && term.rows === lastTermRows) return;
  lastTermCols = term.cols;
  lastTermRows = term.rows;
  if (termWs && termWs.readyState === WebSocket.OPEN) {
    termWs.send(JSON.stringify({ type: 'resize', rows: term.rows, cols: term.cols }));
  }
}

// Coalesce a burst of resize/observer events into a single fit per frame. Used
// by the window `resize` listener and the container ResizeObserver; the WS-open
// path calls applyTermFit() directly so the PTY winsize is set synchronously
// before the scrollback replay (select-window).
function fitTerminal() {
  if (fitScheduled) return;
  fitScheduled = true;
  requestAnimationFrame(() => { fitScheduled = false; applyTermFit(); });
}

function selectWindow(win) {
  if (win == null) return;
  if (termWs && termWs.readyState === WebSocket.OPEN) {
    termWs.send(JSON.stringify({ type: 'select-window', window: win }));
  }
}

// Right-click "Reload terminal" (#661): recover a corrupted/thrashed surface
// without a full browser refresh. Reset the xterm buffer to drop the mangled
// grid, then force a clean WebSocket reconnect — the fresh attach re-fits and
// re-selects the window (onopen), so crowd replays the pane's tmux scrollback
// and repaints against a now-stable layout. Same recovery a page reload gives,
// scoped to the terminal surface. Detach the old socket's handlers first so its
// onclose/onerror can't reconnect or close the new socket (they reference the
// module-level termWs, which we're about to reassign).
function reloadTerminal() {
  if (!term) return;
  try { term.reset(); } catch (_) {}
  lastTermCols = 0;
  lastTermRows = 0;
  if (termWs) {
    const old = termWs;
    old.onopen = old.onmessage = old.onclose = old.onerror = null;
    try { old.close(); } catch (_) {}
    termWs = null;
  }
  connectTerminalWs();
}

// ---------------------------------------------------------------------------
// First-run setup wizard (CROW-605) — port of SetupWizardView.
// Shown when get-config reports configured:false (no App Support pointer).
// ---------------------------------------------------------------------------
function wizardUuid() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function showWizard(defaultDevRoot) {
  if (document.getElementById('wizard')) return;
  const state = {
    step: 1,
    devRoot: defaultDevRoot || '',
    workspaces: [],
    adding: false,
    draft: { name: '', provider: 'github', host: '' },
    error: null,
    settingUp: false,
  };

  const overlay = el('div');
  overlay.id = 'wizard';
  document.body.appendChild(overlay);

  function render() {
    overlay.innerHTML = '';
    if (state.settingUp) {
      const card = el('div', 'wizard-card wizard-setting-up');
      card.appendChild(el('div', 'wizard-spinner'));
      card.appendChild(el('div', 'wizard-title', 'Setting up Crow…'));
      card.appendChild(el('div', 'wizard-sub', 'Adopting your dev root — reconnecting shortly.'));
      if (state.error) card.appendChild(el('div', 'wizard-error', state.error));
      overlay.appendChild(card);
      return;
    }

    const card = el('div', 'wizard-card');
    const dots = el('div', 'wizard-dots');
    for (let s = 1; s <= 3; s++) {
      const d = el('span', 'wizard-dot' + (s <= state.step ? ' active' : ''));
      dots.appendChild(d);
    }
    card.appendChild(dots);

    const body = el('div', 'wizard-body');
    if (state.step === 1) renderStep1(body);
    else if (state.step === 2) renderStep2(body);
    else renderStep3(body);
    card.appendChild(body);

    if (state.error) card.appendChild(el('div', 'wizard-error', state.error));

    const foot = el('div', 'wizard-foot');
    if (state.step > 1) {
      const back = el('button', 'action-btn', 'Back');
      back.onclick = () => { state.step -= 1; state.error = null; render(); };
      foot.appendChild(back);
    } else {
      foot.appendChild(el('div'));
    }
    if (state.step < 3) {
      const next = el('button', 'action-btn action-primary', 'Next');
      next.disabled = state.step === 1 && !state.devRoot.trim();
      next.onclick = () => {
        if (state.step === 1 && !state.devRoot.trim()) return;
        state.step += 1;
        state.error = null;
        render();
      };
      foot.appendChild(next);
    } else {
      const go = el('button', 'action-btn action-primary', 'Get Started');
      go.onclick = () => completeSetup();
      foot.appendChild(go);
    }
    card.appendChild(foot);
    overlay.appendChild(card);
  }

  function renderStep1(body) {
    body.appendChild(el('div', 'wizard-title', 'Welcome to Crow'));
    body.appendChild(el('div', 'wizard-sub', 'Where do you want your development workspaces?'));
    const field = el('div', 'wizard-field');
    field.appendChild(el('label', 'wizard-label', 'Dev root'));
    const input = document.createElement('input');
    input.className = 'wizard-input';
    input.type = 'text';
    input.value = state.devRoot;
    input.placeholder = '~/Dev';
    input.oninput = () => {
      state.devRoot = input.value;
      const next = overlay.querySelector('.wizard-foot .action-primary');
      if (next) next.disabled = !state.devRoot.trim();
    };
    field.appendChild(input);
    body.appendChild(field);
  }

  function renderStep2(body) {
    body.appendChild(el('div', 'wizard-title', 'Add Workspace Folders'));
    body.appendChild(el('div', 'wizard-sub',
      'Each workspace is a folder under your dev root containing git repos.'));
    if (!state.workspaces.length && !state.adding) {
      body.appendChild(el('div', 'wizard-empty', 'No workspaces yet — you can add one now or skip.'));
    }
    const list = el('div', 'wizard-list');
    for (const ws of state.workspaces) {
      const row = el('div', 'wizard-row');
      const info = el('div', 'wizard-row-info');
      info.appendChild(el('div', 'wizard-row-name', ws.name));
      info.appendChild(el('div', 'wizard-row-meta',
        ws.provider + (ws.host ? ' · ' + ws.host : '')));
      row.appendChild(info);
      const rm = el('button', 'wizard-row-rm', '×');
      rm.title = 'Remove';
      rm.onclick = () => {
        state.workspaces = state.workspaces.filter((x) => x.id !== ws.id);
        render();
      };
      row.appendChild(rm);
      list.appendChild(row);
    }
    body.appendChild(list);

    if (state.adding) {
      const form = el('div', 'wizard-add-form');
      const nameField = el('div', 'wizard-field');
      nameField.appendChild(el('label', 'wizard-label', 'Name'));
      const nameIn = document.createElement('input');
      nameIn.className = 'wizard-input';
      nameIn.type = 'text';
      nameIn.placeholder = 'MyOrg';
      nameIn.value = state.draft.name;
      nameIn.oninput = () => { state.draft.name = nameIn.value; };
      nameField.appendChild(nameIn);
      form.appendChild(nameField);

      const provField = el('div', 'wizard-field');
      provField.appendChild(el('label', 'wizard-label', 'Provider'));
      const sel = document.createElement('select');
      sel.className = 'wizard-input';
      for (const [v, label] of [['github', 'GitHub'], ['gitlab', 'GitLab']]) {
        const o = document.createElement('option');
        o.value = v; o.textContent = label;
        if (state.draft.provider === v) o.selected = true;
        sel.appendChild(o);
      }
      sel.onchange = () => { state.draft.provider = sel.value; render(); };
      provField.appendChild(sel);
      form.appendChild(provField);

      if (state.draft.provider === 'gitlab') {
        const hostField = el('div', 'wizard-field');
        hostField.appendChild(el('label', 'wizard-label', 'GitLab host'));
        const hostIn = document.createElement('input');
        hostIn.className = 'wizard-input';
        hostIn.type = 'text';
        hostIn.placeholder = 'gitlab.example.com';
        hostIn.value = state.draft.host || '';
        hostIn.oninput = () => { state.draft.host = hostIn.value; };
        hostField.appendChild(hostIn);
        form.appendChild(hostField);
      }

      const actions = el('div', 'wizard-add-actions');
      const cancel = el('button', 'action-btn', 'Cancel');
      cancel.onclick = () => {
        state.adding = false;
        state.draft = { name: '', provider: 'github', host: '' };
        render();
      };
      const add = el('button', 'action-btn action-primary', 'Add');
      add.onclick = () => {
        const name = (state.draft.name || '').trim();
        if (!name) { state.error = 'Workspace name is required.'; render(); return; }
        if (state.workspaces.some((w) => w.name.toLowerCase() === name.toLowerCase())) {
          state.error = 'A workspace with that name already exists.'; render(); return;
        }
        const provider = state.draft.provider || 'github';
        state.workspaces.push({
          id: wizardUuid(),
          name,
          provider,
          cli: provider === 'gitlab' ? 'glab' : 'gh',
          host: provider === 'gitlab' && state.draft.host ? state.draft.host.trim() : undefined,
          alwaysInclude: [],
          autoReviewRepos: [],
          excludeReviewRepos: [],
        });
        state.adding = false;
        state.draft = { name: '', provider: 'github', host: '' };
        state.error = null;
        render();
      };
      actions.appendChild(cancel);
      actions.appendChild(add);
      form.appendChild(actions);
      body.appendChild(form);
      setTimeout(() => nameIn.focus(), 0);
    } else {
      const addBtn = el('button', 'wizard-add', '+ Add workspace');
      addBtn.onclick = () => { state.adding = true; state.error = null; render(); };
      body.appendChild(addBtn);
    }
  }

  function renderStep3(body) {
    body.appendChild(el('div', 'wizard-title', 'Ready to Go'));
    body.appendChild(el('div', 'wizard-sub', 'Confirm your setup and get started.'));
    const summary = el('div', 'wizard-summary');
    summary.appendChild(el('div', 'wizard-summary-row', state.devRoot.trim()));
    if (!state.workspaces.length) {
      summary.appendChild(el('div', 'wizard-summary-meta', 'No workspaces yet — add them later in Settings.'));
    } else {
      for (const ws of state.workspaces) {
        summary.appendChild(el('div', 'wizard-summary-meta',
          ws.name + ' (' + ws.provider + (ws.host ? ' · ' + ws.host : '') + ')'));
      }
    }
    body.appendChild(summary);
  }

  async function completeSetup() {
    const root = state.devRoot.trim();
    if (!root) { state.error = 'Dev root is required.'; state.step = 1; render(); return; }
    state.settingUp = true;
    state.error = null;
    render();
    const config = {
      workspaces: state.workspaces,
      defaults: { provider: 'github', cli: 'gh', branchPrefix: 'feature/' },
    };
    try {
      await rpc('run-setup', { dev_root: root, config: JSON.stringify(config) });
    } catch (e) {
      state.settingUp = false;
      state.error = (e && e.message) || String(e);
      render();
      return;
    }
    // Daemon re-execs → /rpc drops → rpcConnect auto-reconnects. Poll until
    // configured flips true, then tear down the overlay and refresh the board.
    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      try {
        const res = await rpc('get-config');
        if (res && res.configured) {
          overlay.remove();
          refreshSessions();
          refreshBoard('tickets');
          refreshBoard('reviews');
          loadUIConfig();
          return;
        }
      } catch (_) { /* still reconnecting */ }
    }
    state.error = 'Setup saved, but Crow did not come back online. Reload the page.';
    render();
  }

  render();
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

// Paint the left pane immediately — cached last-known layout, or skeleton
// placeholders — before the first /rpc round-trip (CROW-613). A stale-schema
// cache entry must not abort the rest of boot (polls / refreshSessions).
try {
  restoreSidebarCache();
  renderSidebar();
} catch (_) {
  clearSidebarCache();
  sessions = [];
  lastSidebarSig = null;
  try { renderSidebar(); } catch (_) { /* keep going — RPC refresh will paint */ }
}
renderStatusBar();

refreshSessions();
refreshLive();
loadUIConfig();
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
