'use strict';
// Crow web UI — Notification sounds, banners, history, detectors, emitEvent. Extracted from app.js (CROW-1155).

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
  // Automation events (CROW-768) — Basso for conflicts so "needs attention" is
  // audibly distinct from the success events beside it.
  autoWorkspaceCreated: 'Hero', autoMergeEnabled: 'Glass',
  autoMergeBlocked: 'Basso',
  autoRebasePushed: 'Bottle', autoRebaseConflicts: 'Basso', autoRebaseStuck: 'Basso',
  configReloaded: 'Tink',
};

// NotificationEvent.displayName / .description (CrowCore) — reused for the
// browser-notification title/body so the web matches the desktop wording.
const EVENT_LABEL = {
  taskComplete: 'Task Complete', agentWaiting: 'Agent Waiting',
  reviewRequested: 'Review Requested', changesRequested: 'Changes Requested',
  checksFailing: 'CI Failing',
  autoWorkspaceCreated: 'Auto-Workspace Created', autoMergeEnabled: 'Auto-Merge Enabled',
  autoMergeBlocked: 'Auto-Merge Blocked',
  autoRebasePushed: 'Branch Rebased', autoRebaseConflicts: 'Rebase Conflicts',
  autoRebaseStuck: 'Rebase Stuck',
  configReloaded: 'Config Reloaded',
};
const EVENT_DESC = {
  taskComplete: 'Claude finished responding',
  agentWaiting: 'Claude needs your input or permission',
  reviewRequested: 'Someone requested your review on a PR',
  changesRequested: 'A reviewer requested changes on your PR',
  checksFailing: 'CI checks started failing on your PR',
  autoWorkspaceCreated: 'Crow auto-created a workspace for an assigned issue',
  autoMergeEnabled: 'Crow enabled auto-merge on a PR',
  autoMergeBlocked: "Crow can't auto-merge a crow:merge PR and has stopped trying",
  autoRebasePushed: 'Crow rebased a PR branch onto its base and pushed',
  autoRebaseConflicts: 'An auto-rebase hit conflicts that need attention',
  autoRebaseStuck: "An auto-rebase can't proceed and needs you",
  configReloaded: 'Crow reloaded its configuration',
};

// NotificationEvent.isAutomationEvent (CrowCore) — the events the daemon pushes
// rather than the client deriving them from polled state (CROW-768).
const AUTOMATION_EVENTS = [
  'autoWorkspaceCreated', 'autoMergeEnabled', 'autoMergeBlocked', 'autoRebasePushed',
  'autoRebaseConflicts', 'autoRebaseStuck', 'configReloaded',
];
// Every event the notification layer knows about, in the Settings tab's order.
const ALL_EVENTS = [
  'taskComplete', 'agentWaiting', 'reviewRequested', 'changesRequested', 'checksFailing',
].concat(AUTOMATION_EVENTS);

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

// Web Audio tone recipes — kept in sync with settings-notifications.js previewSound so an
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
  let customByName = {}; // lowercased name → url
  function ensure() {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    if (!ctx) { try { ctx = new AC(); } catch (_) { return null; } }
    if (ctx.state === 'suspended') ctx.resume(); // no-op once unlocked
    return ctx;
  }
  function playSynth(name) {
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
  function playFile(url, fallbackName) {
    try {
      const audio = new Audio(url);
      audio.onerror = () => playSynth(fallbackName || 'Glass');
      const p = audio.play();
      if (p && p.catch) p.catch(() => playSynth(fallbackName || 'Glass'));
    } catch (_) {
      playSynth(fallbackName || 'Glass');
    }
  }
  function play(name, fallbackName) {
    const url = customByName[String(name || '').toLowerCase()];
    if (url) { playFile(url, fallbackName || 'Glass'); return; }
    // Built-in names synthesize; a missing/deleted custom file falls back
    // to the event default (or Glass) rather than a generic beep.
    if (SOUND_TONES[name]) { playSynth(name); return; }
    playSynth(fallbackName || 'Glass');
  }
  function setCustomSounds(list) {
    customByName = {};
    for (const s of list || []) {
      if (s && s.name && s.url) customByName[String(s.name).toLowerCase()] = s.url;
    }
  }
  return { play, unlock: ensure, setCustomSounds };
})();
window.crowSound = crowSound;

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
  crowSound.play(cfg.soundName || DEFAULT_EVENT_SOUND[event] || 'Glass',
    DEFAULT_EVENT_SOUND[event] || 'Glass');
}

// Manual test hook. crowTestSound() plays each event once (staggered);
// crowTestSound('agentWaiting') plays one. Bypasses config/dedup so it's always
// audible — useful to confirm audio works and hear each configured tone.
window.crowTestSound = function (event) {
  const evs = event ? [event] : ALL_EVENTS;
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

// Derive the { title, body } for an event, enriched with the session name (for
// session events) or the review's repo (for reviews). A server-supplied
// title/body (automation events) is used verbatim. Shared by the transient
// browser/Tauri banner and the notification center so both read identically
// (CROW-909).
function eventNotificationText(event, key, detail) {
  const isSession = !!sessions.find((x) => x.id === key);
  const title = (detail && detail.title) || EVENT_LABEL[event] || event;
  let body = (detail && detail.body) || '';
  if (!body) {
    body = EVENT_DESC[event] || '';
    if (isSession) {
      body = `${sessionNameFor(key)} — ${body}`;
    } else {
      const r = ((boardData.reviews && boardData.reviews.reviews) || []).find((x) => x.id === key);
      if (r && r.repo) body = `${r.repo} — ${body}`;
    }
  }
  return { title, body };
}

// `detail` (optional) carries a server-supplied { title, body } for automation
// events, whose text is specific (PR number, issue title) rather than derivable
// from EVENT_DESC (CROW-768).
const _lastNotifyAt = {};
function showEventNotification(event, key, detail) {
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
  // don't ping about the session you're already looking at. Automation events
  // are exempt (as they were natively) — an action Crow took on your behalf is
  // worth knowing about even while that session is on screen (CROW-768).
  const isAutomation = AUTOMATION_EVENTS.indexOf(event) !== -1;
  if (!isAutomation && isSession && document.hasFocus() && selectedId === key) return;

  const k = (key || '') + '|' + event;
  const now = Date.now();
  if (_lastNotifyAt[k] && now - _lastNotifyAt[k] < 2000) return;
  _lastNotifyAt[k] = now;

  // A server-supplied title/body already names the PR / issue / session, so it's
  // used verbatim; derived events get the label plus a subject prefix.
  const { title: label, body } = eventNotificationText(event, key, detail);
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
    // Automation events keyed on something other than a session (an issue URL,
    // `config`) have nowhere better to land than the window itself.
    n.onclick = () => {
      window.focus();
      try {
        if (isSession) {
          selectSession(key);
        } else if (!isAutomation) {
          const r = ((boardData.reviews && boardData.reviews.reviews) || []).find((x) => x.id === key);
          if (r && r.review_session_id) selectSession(r.review_session_id);
          else selectBoard('reviews');
        }
      } catch (_) { /* nav best-effort */ }
      n.close();
    };
  } catch (_) { /* Notification ctor can throw in restricted contexts */ }
}

// All three channels fire from one call in the detectors below; each self-gates
// (sound + banner on the full toggle cascade, the history on the master levels).
function emitEvent(event, key, detail) {
  playEventSound(event, key);
  showEventNotification(event, key, detail);
  recordNotification(event, key, detail);
}

// --- Notification center: history + unread counter (CROW-909) ---------------
// The sound + banner above are fire-and-forget. The center keeps a history of
// every event that reaches emitEvent — recorded UNGATED (unlike the banner,
// which self-suppresses on focus/mute), so the panel is a faithful log even for
// events whose transient popup you never saw. Per-browser, not per-tab:
// localStorage is shared across every tab on the origin, so a `storage` listener
// keeps the tabs in sync and each mutate re-reads first to compose rather than
// clobber (review). Not server-synced — a shared, cross-device history is a
// larger follow-up.
const NOTIF_HISTORY_KEY = 'crow.notif.history';
const NOTIF_HISTORY_CAP = 100; // keep the last ~100; older entries drop off
let notifHistory = [];         // [{ event, key, title, body, ts, seen, kind, target }]

function restoreNotifHistory() {
  try {
    const raw = localStorage.getItem(NOTIF_HISTORY_KEY);
    // Missing key means "empty", not "no change" — a purge in another tab fires a
    // storage event with newValue === null, and returning early here would leave
    // this tab's in-memory copy intact, which its next seen-marking would then
    // persist straight back, re-creating the key the logout just dropped (review).
    // Safe for the compose path too: recordNotification only reaches here with the
    // key already absent, where in-memory is [] anyway.
    if (!raw) { notifHistory = []; return; }
    const data = JSON.parse(raw);
    // Filter to well-formed entries: a parseable-but-wrong array (`[null, …]`, a
    // foreign schema) would otherwise let a later `e.seen` read throw inside
    // notifUnreadCount → sidebarSignature → every renderSidebar, wedging the
    // whole sidebar until the key is cleared by hand. The `ts` check also keeps a
    // ts-less entry from rendering "Invalid Date" in notifRelTime (review).
    if (Array.isArray(data)) {
      notifHistory = data
        .filter((e) => e && typeof e === 'object' && typeof e.ts === 'number')
        .slice(-NOTIF_HISTORY_CAP);
    }
  } catch (_) { /* corrupt cache — start empty */ }
}
function persistNotifHistory() {
  try { localStorage.setItem(NOTIF_HISTORY_KEY, JSON.stringify(notifHistory)); }
  catch (_) { /* quota / private mode */ }
}
function notifUnreadCount() {
  let n = 0;
  for (const e of notifHistory) if (e && !e.seen) n++;
  return n;
}

// One coalesced sidebar repaint per task, so a detector tick that records k
// events triggers a single innerHTML rebuild rather than k of them (the unread
// count is in sidebarSignature, so the cheap signature short-circuit never
// applies to an append). A microtask, not rAF, so the badge is current before
// the next paint and onServerNotify still repaints within the same turn (review).
let _notifRepaintScheduled = false;
function scheduleNotifRepaint() {
  if (_notifRepaintScheduled) return;
  _notifRepaintScheduled = true;
  Promise.resolve().then(() => {
    _notifRepaintScheduled = false;
    try { renderSidebar(); } catch (_) { /* pre-boot — badge paints on first render */ }
  });
}

// Another tab wrote the shared history (append, mark-seen, clear, or purge on
// logout — restoreNotifHistory treats the removed key as empty). Re-read so this
// tab's badge/panel reflect it instead of drifting, then repaint. Does not fire
// in the tab that made the change, so there's no write→event loop (review).
window.addEventListener('storage', (e) => {
  if (e.key !== NOTIF_HISTORY_KEY) return;
  restoreNotifHistory();
  try { renderSidebar(); } catch (_) { /* pre-boot */ }
});

// Classify the click-through target at append time (event type is stable),
// while leaving the live lookup (review→session, session existence) to click
// time where the state is fresh. Mirrors the routing in showEventNotification's
// Notification.onclick (CROW-909).
function classifyNotification(event, key) {
  if (sessions.find((x) => x.id === key)) return { kind: 'session', target: key };
  if (AUTOMATION_EVENTS.indexOf(event) === -1) return { kind: 'review', target: key };
  // Automation keyed by an issue URL opens externally; `config`/other → no target.
  if (typeof key === 'string' && /^https?:\/\//.test(key)) return { kind: 'url', target: key };
  return { kind: 'none', target: null };
}

// Append one event to the history and bump the unread counter. Gated on only the
// MASTER levels — globalMute and the per-event `enabled` toggle — so a user who
// muted everything, or switched this event category off in Settings, doesn't get
// a growing badge they can't opt out of. The per-event sound/system SUB-toggles
// and the focus-suppression rule are deliberately NOT applied: the center is a
// passive log, not an interruption, so it keeps events whose transient banner you
// chose not to see live. A 2s per-(key,event) dedup mirrors the sound/banner
// channels, where repeated pushes / a flapping poll produced duplicate popups
// (review).
const _lastRecordAt = {};
function recordNotification(event, key, detail) {
  const N = uiConfig.notifications;
  if (!N) return;                          // config not loaded — mirror the sibling channels
  if (N.globalMute) return;                // master mute silences the log too
  const cfg = N.events[event] || {};
  if (cfg.enabled === false) return;       // event category switched off entirely
  const k = (key || '') + '|' + event;
  const now = Date.now();
  if (_lastRecordAt[k] && now - _lastRecordAt[k] < 2000) return;
  _lastRecordAt[k] = now;
  // Re-read the shared store first so a concurrent tab's entries compose with
  // this append instead of being overwritten by our stale in-memory copy.
  restoreNotifHistory();
  const { title, body } = eventNotificationText(event, key, detail);
  const { kind, target } = classifyNotification(event, key);
  notifHistory.push({ event, key: key || '', title, body, ts: now, seen: false, kind, target });
  if (notifHistory.length > NOTIF_HISTORY_CAP) {
    notifHistory = notifHistory.slice(-NOTIF_HISTORY_CAP);
  }
  persistNotifHistory();
  scheduleNotifRepaint();
}

// Relative "5m ago" timestamp for panel rows, from epoch ms; falls back to a
// locale date past a week so old entries stay legible. NOT named `relTime` — a
// pre-existing `relTime(iso)` (the card helper, #594) takes an ISO string, and
// in a classic <script> the later top-level declaration would win for BOTH, so
// every call would resolve to one of them. Distinct name, distinct input unit
// (review, CROW-909).
function notifRelTime(ts) {
  const s = Math.max(0, Math.floor((Date.now() - ts) / 1000));
  if (s < 45) return 'just now';
  const m = Math.floor(s / 60);
  if (m < 60) return m + 'm ago';
  const h = Math.floor(m / 60);
  if (h < 24) return h + 'h ago';
  const d = Math.floor(h / 24);
  if (d < 7) return d + 'd ago';
  try { return new Date(ts).toLocaleDateString(); } catch (_) { return ''; }
}

// Route a history entry to its origin, reusing the live state so a review whose
// session started after the event still lands on that session (CROW-909).
function navigateToNotification(entry) {
  try {
    if (entry.kind === 'session') {
      if (sessions.find((x) => x.id === entry.target)) selectSession(entry.target);
    } else if (entry.kind === 'review') {
      const r = ((boardData.reviews && boardData.reviews.reviews) || []).find((x) => x.id === entry.target);
      if (r && r.review_session_id) selectSession(r.review_session_id);
      else selectBoard('reviews');
    } else if (entry.kind === 'url') {
      // Re-test the scheme at click time — `entry.target` came from localStorage,
      // which same-origin script could have tampered with or an older build could
      // have written under looser rules. classifyNotification already rejects
      // javascript:/data: at record time; this is cheap defense-in-depth (review).
      if (typeof entry.target === 'string' && /^https?:\/\//.test(entry.target)) {
        window.open(entry.target, '_blank', 'noopener');
      }
    }
    // kind 'none' (config reload, non-URL automation) has no in-app target.
  } catch (_) { /* nav best-effort */ }
}

// Server-pushed automation event (CROW-768). The daemon fires these at the point
// a watcher acts — auto-workspace, auto-merge, auto-rebase, config reload — since
// none of them are visible in the state the client polls. Gating (global mute,
// per-event toggles, dedup) is the detectors' gating; the arm window applies too,
// so a frame landing mid-boot can't chime over a page load.
async function onServerNotify(params) {
  if (!params || typeof params.event !== 'string') return;
  if (ALL_EVENTS.indexOf(params.event) === -1) return; // unknown/newer event — ignore
  // config.json moved on disk (Settings save, `crow ui set`, `crow notifications
  // set`, hand edit) — re-read the view-affecting slice so an external write
  // repaints without a reload. `uiConfig` is cached at boot and `set-config`
  // pushes no `changed`, so this frame is the only signal the web gets.
  //
  // Ahead of the arm gate (CROW-814): a CLI write is not a user gesture, so
  // waiting for _soundArmed would strand the sidebar on stale config. Awaited
  // rather than fire-and-forget (CROW-813): a mute that just landed has to
  // silence the very notification announcing it.
  if (params.event === 'configReloaded') {
    try { await loadUIConfig(); } catch (_) { /* keep the cached config */ }
  }
  if (!_soundArmed) return;
  // Defensive: the daemon always sends strings, but never hand a non-string to
  // the Notification API. A missing key just weakens dedup, so tolerate it.
  const key = typeof params.key === 'string' ? params.key : '';
  const title = typeof params.title === 'string' ? params.title : '';
  const body = typeof params.body === 'string' ? params.body : '';
  emitEvent(params.event, key, { title, body });
}

// Manual test hook, mirroring crowTestSound. crowTestNotify() shows one popup
// per event (staggered); crowTestNotify('agentWaiting') shows one. Requests
// permission first if needed. Bypasses config/dedup so it's always visible.
window.crowTestNotify = function (event) {
  if (!notificationsSupported()) { console.warn('[crowNotify] Notification API unavailable'); return; }
  const fire = () => {
    const evs = event ? [event] : ALL_EVENTS;
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

// Manual test hook for the notification center (CROW-909). Unlike crowTestSound
// / crowTestNotify — which call crowSound.play / new Notification directly and
// so never touch the history — this drives the real emitEvent path, so it moves
// the bell's unread badge and appends a row. crowTestEvent() fires taskComplete
// against the first session; crowTestEvent('reviewRequested', '<id>') targets a
// specific key. Subject to the same config gating as a real event.
window.crowTestEvent = function (event, key) {
  const ev = event || 'taskComplete';
  const k = key || (sessions[0] && sessions[0].id) || 'test';
  emitEvent(ev, k);
  console.log('[crowEvent] test', ev, '→', k, '· unread now', notifUnreadCount());
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
  // Only reviews someone is actually *asking you for* can be a new request.
  // Since CROW-982 the payload also carries groups a review enters when work
  // **leaves** your queue — your own verdict landing (Waiting on author), or the
  // PR finishing (Recently completed) — and chiming `reviewRequested` for those
  // would announce work arriving at the moment it departed.
  //
  // Which groups qualify comes from the server (`group_announces_new_request`)
  // rather than a group id spelled out here: naming the excluded group inline
  // meant CROW-990's fourth group opted itself into the chime by default. An
  // older daemon sends no map, so fall back to the one exclusion it knew about.
  const announces = (boardData.reviews && boardData.reviews.group_announces_new_request) || null;
  const rs = ((boardData.reviews && boardData.reviews.reviews) || [])
    .filter((r) => (announces ? announces[r.group] !== false : r.group !== 'approved_recently'));
  const ids = new Set(rs.map((r) => r.id).filter(Boolean));
  const prev = _prevReviewIDs;
  _prevReviewIDs = ids;
  if (!_soundArmed || !prev) return;
  for (const r of rs) if (r.id && !prev.has(r.id)) emitEvent('reviewRequested', r.id);
}
