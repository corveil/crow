'use strict';
// Crow web UI — JSON-RPC client, /rpc socket, connection light, version banner, uiConfig. Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// JSON-RPC over a single persistent /rpc WebSocket, correlated by id.
// ---------------------------------------------------------------------------
const rpcState = { nextId: 1, pending: new Map(), ready: null };

// Per-method RPC deadlines, mirroring the CLI's table so the two clients agree
// on how long a verb is allowed to take (`CrowCLILib/Helpers.swift` default 30s,
// plus each command's explicit `timeoutSeconds:`). The flat 10s this replaced
// was shorter than the work for most write verbs — `add-merge-label` alone did a
// label create, a label add, and a full multi-provider board poll — so the modal
// that popped said "failed" about an action that was running fine and usually
// went on to succeed (#931).
//
// KEYS ARE WIRE METHOD NAMES, NOT CLI VERBS. `crow job run` sends `job-run`;
// Settings' "Run now" button sends `run-job` (a distinct handler). Both do the
// same work, so both are listed — keying off the CLI verb alone would leave the
// web button on the default.
const RPC_DEFAULT_TIMEOUT_MS = 30000;
const RPC_TIMEOUTS_MS = {
  // Rebuilds the whole scorecard from the event log.
  'rebuild-scorecard': 180000,
  // Historical backfill (CROW-1075): scan reads hundreds of transcript heads +
  // git remotes; upload is serial network I/O over the selected set.
  'backfill-scan': 180000,
  'backfill-upload': 600000,
  // Shell out to gh/glab/Jira across every configured repo; clone a repo and
  // spawn tmux; run a job's full command.
  'refresh-tickets': 120000,
  'start-review': 120000,
  'batch-start-review': 120000, // no CLI twin; at least as slow as start-review
  'job-run': 120000,
  'run-job': 120000,
  // Board reads and Manager-keystroke writes (the CLI's `boardTimeout`).
  'work-on-issue': 60000,
  'batch-work-on-issues': 60000,
  'create-manager': 60000,
  'quick-action': 60000,
  'list-tickets': 60000,
  'list-reviews': 60000,
  'get-state': 60000,
  'promote-allowlist': 60000,
  'refresh-allowlist': 60000,
  'mark-issue-done': 60000,
  'add-merge-label': 60000,
  // 16 capture-pane snapshots for the session grid (CROW-1153).
  'list-session-terminal-snapshots': 45000,
};
function rpcTimeoutFor(method) {
  const ms = RPC_TIMEOUTS_MS[method];
  return typeof ms === 'number' ? ms : RPC_DEFAULT_TIMEOUT_MS;
}

// A timed-out request keeps its `pending` entry, flagged `settled`, so the
// eventual reply can reach `onLate` instead of being dropped by `onmessage`'s
// `!waiter` guard. That means the map no longer empties itself: sweep on every
// new call. Ten minutes is far past any method's deadline, and the cap bounds a
// pathological run of timeouts.
const RPC_LATE_WINDOW_MS = 600000;
const RPC_MAX_SETTLED = 64;
function gcSettledRPCs() {
  const now = Date.now();
  const settled = [];
  rpcState.pending.forEach((w, id) => {
    if (!w.settled) return;
    if (now - w.settledAt > RPC_LATE_WINDOW_MS) rpcState.pending.delete(id);
    else settled.push(id);
  });
  // Map iteration is insertion order and ids are monotonic, so `settled` is
  // oldest-first — trim from the head, the least likely to still answer.
  for (let i = 0; i < settled.length - RPC_MAX_SETTLED; i++) rpcState.pending.delete(settled[i]);
}

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
      // Automation event push (CROW-768): a moment Crow acted on the user's
      // behalf, which no client can derive from polled state.
      if (msg.id == null && msg.method === 'notify') { onServerNotify(msg.params); return; }
      const waiter = rpcState.pending.get(msg.id);
      if (!waiter) return;
      rpcState.pending.delete(msg.id);
      if (waiter.timer) clearTimeout(waiter.timer);
      const rpcErr = msg.error ? new Error(msg.error.message || 'rpc error') : null;
      // Late: this call's promise already rejected on its timeout, so settling
      // it again is a no-op and the answer would be lost. Hand it to `onLate`
      // instead — that is what lets a caller retract a "still running" advisory
      // once the daemon does answer (#931).
      if (waiter.settled) {
        if (waiter.onLate) {
          try { waiter.onLate(rpcErr ? null : (msg.result || {}), rpcErr); }
          catch (_) { /* a caller's late-handler must not kill the socket pump */ }
        }
        return;
      }
      if (rpcErr) waiter.reject(rpcErr);
      else waiter.resolve(msg.result || {});
    };
    ws.onclose = (event) => {
      setWsConnected(false);
      // CROW-956: 1009 is `messageTooLarge` — crowd's per-message ceiling, not a
      // dead daemon. Both used to arrive here as a bare close, so a `set-config`
      // whose JSON outgrew the frame limit reported the same "connection closed"
      // as a crashed crowd, and the reconnect a second later made the UI look
      // healthy while the save simply never stuck. An absent or unknown code
      // still reads exactly as it did.
      const tooLarge = !!event && event.code === 1009;
      // Fail fast: a socket that closed before opening must reject so `await
      // rpcState.ready` can't hang when the daemon is down (review #8).
      if (!opened) reject(new Error('rpc: socket closed before open'));
      // Reject in-flight rpcs instead of leaving them stuck until their
      // deadline. Entries already settled by a timeout are dropped WITHOUT
      // firing `onLate`: the socket died before the daemon answered, so we
      // genuinely don't know the outcome, and "connection closed" is not an
      // honest replacement for a "still running" advisory the user can already
      // dismiss. Dropping them also keeps the map empty across a reconnect.
      rpcState.pending.forEach((w) => {
        if (w.timer) clearTimeout(w.timer);
        if (w.settled) return;
        if (!tooLarge) { w.reject(new Error('rpc: connection closed')); return; }
        const err = new Error(
          'rpc: ' + w.method
          + ' was too large for the daemon, which closed the connection (1009)');
        // Tagged like the timeout rejection below, so a caller can tell "too
        // big" from "daemon went away" without matching on the message text.
        err.rpcTooLarge = true;
        err.rpcMethod = w.method;
        w.reject(err);
      });
      rpcState.pending.clear();
      // Daemon's gone, so its in-flight refresh flag will never be cleared for
      // us. Drop it here rather than waiting for a board poll that may not run
      // (the interval only polls an *open* board) (CROW-771).
      clearDaemonRefreshFlag();
      // A crowd restart wipes its in-memory sessions, so a remote web cookie may now
      // be invalid — probe and, if so, stop reconnecting and surface "Log in" (CROW-593).
      handleAuthOnDisconnect();
      // Reconnect once — and only if this connection is still the active one, so
      // an rpc() opened during the window can't leave a duplicate socket that
      // double-fires `changed` refreshes (review #9). Skipped once the session is dead.
      // Deliberately NOT skipped after a 1009: that code is per-MESSAGE, not
      // per-connection — the socket is fine for every other request, and staying
      // offline over one oversized payload would take the whole UI down. Nothing
      // re-sends the offending message, so there is no retry loop.
      if (rpcState.ready === p) {
        rpcState.ready = null;
        setTimeout(() => { if (!rpcState.ready && !sessionDead) rpcState.ready = rpcConnect(); }, 1000);
      }
    };
    ws.onerror = () => ws.close();
  });
  return p;
}

// `opts.timeoutMs` overrides the per-method table; `opts.onLate(result, error)`
// fires if the response arrives *after* this call already rejected on timeout —
// exactly once, with one of the two arguments non-null.
async function rpc(method, params, opts) {
  // Session is dead (cookie invalid): don't spin up doomed reconnects — fail fast so
  // background pollers stop churning and the "Log in" affordance stands (CROW-593).
  if (sessionDead) throw new Error('session expired — log in');
  if (!rpcState.ready) rpcState.ready = rpcConnect();
  const ws = await rpcState.ready;
  const id = rpcState.nextId++;
  const o = opts || {};
  const ms = typeof o.timeoutMs === 'number' ? o.timeoutMs : rpcTimeoutFor(method);
  gcSettledRPCs();
  return new Promise((resolve, reject) => {
    const waiter = {
      method, resolve, reject,
      settled: false, settledAt: 0,
      onLate: typeof o.onLate === 'function' ? o.onLate : null,
      timer: 0,
    };
    rpcState.pending.set(id, waiter);
    ws.send(JSON.stringify({ jsonrpc: '2.0', id, method, params: params || {} }));
    waiter.timer = setTimeout(() => {
      const w = rpcState.pending.get(id);
      if (!w || w.settled) return;
      // Keep the entry, flagged — deleting it (as this used to) makes a late
      // reply hit `onmessage`'s `!waiter` guard and vanish, which is why the
      // failure modal could never be taken back down (#931).
      w.settled = true;
      w.settledAt = Date.now();
      const err = new Error(
        'rpc timeout: ' + method + ' (no response in ' + Math.round(ms / 1000) + 's)');
      // Tagged so a caller can tell "we stopped waiting" from "the daemon said
      // no" — the two deserve different words on screen.
      err.rpcTimeout = true;
      err.rpcMethod = method;
      w.reject(err);
    }, ms);
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
    refreshVersionUpdateBanner();
  }, 50);
}

const VERSION_BANNER_DISMISS_KEY = 'crow.updateBannerDismissedSha';
let versionBannerDismissedWithoutSha = false;
let versionBannerDismissedSha = '';

function isDismissedSha(sha) {
  if (!sha) return false;
  if (versionBannerDismissedSha === sha) return true;
  try {
    return localStorage.getItem(VERSION_BANNER_DISMISS_KEY) === sha;
  } catch (_) {
    return false;
  }
}

function syncUpdateBannerLayout(banner) {
  if (!banner || banner.hidden) {
    document.body.classList.remove('update-banner-visible');
    document.documentElement.style.removeProperty('--update-banner-height');
    return;
  }
  document.body.classList.add('update-banner-visible');
  document.documentElement.style.setProperty(
    '--update-banner-height', banner.offsetHeight + 'px');
}

function hideVersionUpdateBanner(banner, text) {
  if (!banner) return;
  if (text) text.textContent = '';
  const compareLink = banner.querySelector('.update-banner-compare-link');
  if (compareLink) {
    compareLink.hidden = true;
    compareLink.removeAttribute('href');
  }
  banner.hidden = true;
  syncUpdateBannerLayout(banner);
}

function renderVersionUpdateBanner(status) {
  const banner = document.getElementById('update-banner');
  if (!banner) return;
  const text = banner.querySelector('.update-banner-text');
  const compareLink = banner.querySelector('.update-banner-compare-link');
  const dismiss = banner.querySelector('.update-banner-dismiss');
  if (!text || !dismiss) return;

  let dismissRemoteSha = '';
  let dismissArmedWithoutSha = false;
  dismiss.onclick = () => {
    hideVersionUpdateBanner(banner, text);
    if (dismissRemoteSha) {
      versionBannerDismissedSha = dismissRemoteSha;
      try {
        localStorage.setItem(VERSION_BANNER_DISMISS_KEY, dismissRemoteSha);
      } catch (_) {}
    } else if (dismissArmedWithoutSha) {
      versionBannerDismissedWithoutSha = true;
    }
  };

  if (!status || status.state !== 'behind') {
    hideVersionUpdateBanner(banner, text);
    return;
  }
  const remoteSha = status.remote_sha || '';
  if (remoteSha) versionBannerDismissedWithoutSha = false;
  if (remoteSha && isDismissedSha(remoteSha)) {
    hideVersionUpdateBanner(banner, text);
    return;
  }
  if (!remoteSha && versionBannerDismissedWithoutSha) {
    hideVersionUpdateBanner(banner, text);
    return;
  }
  const n = status.behind_by || 0;
  dismissRemoteSha = remoteSha;
  dismissArmedWithoutSha = !remoteSha;
  banner.hidden = false;
  const msg = 'A newer Crow build is available — '
    + n + ' commit' + (n === 1 ? '' : 's') + ' behind origin/main.';
  if (text.textContent !== msg) text.textContent = msg;
  if (compareLink) {
    if (status.compare_url && n > 0) {
      compareLink.href = status.compare_url;
      compareLink.hidden = false;
    } else {
      compareLink.hidden = true;
      compareLink.removeAttribute('href');
    }
  }
  syncUpdateBannerLayout(banner);
}

async function refreshVersionUpdateBanner(cachedStatus) {
  try {
    if (cachedStatus) {
      renderVersionUpdateBanner(cachedStatus);
      return;
    }
    const res = await rpc('version-update-get');
    renderVersionUpdateBanner(res && res.status);
  } catch (_) {
    const banner = document.getElementById('update-banner');
    if (banner) {
      hideVersionUpdateBanner(banner, banner.querySelector('.update-banner-text'));
    }
  }
}
window.refreshVersionUpdateBanner = refreshVersionUpdateBanner;

// Sidebar-affecting slice of AppConfig (CROW-581). `set-config` doesn't push a
// `changed`, so we load this on boot and re-load it when the Settings modal
// saves (via `window.reloadUIConfig`). Mirrors the desktop's
// `appState.hideSessionDetails`.
const uiConfig = { hideSessionDetails: false, notifications: null, webPasswordSet: false, vsCodeAvailable: false, isLocal: false,
  // Session switcher overlay (CROW-976) — defaults mirror AppConfig.SwitcherSettings.
  switcherEnabled: true,
  switcherBinding: 'cmd+/',
  switcherCaptureInTerminal: true,
  switcherOrder: 'mru',
  switcherPreview: true,
  switcherInclude: {
    managers: false, jobs: false, reviews: true,
    active: true, paused: true, in_review: true, completed: false, archived: false,
  },
  // Terminal wheel-scroll sensitivity (CROW-835), consumed by enableWheelScroll.
  // Defaults mirror AppConfig.TerminalSettings: 3 local lines/notch on plain
  // shells, 1 forwarded notch/notch on agent surfaces.
  wheelScrollLines: 3, agentWheelNotches: 1 };
async function loadUIConfig() {
  try {
    const res = await rpc('get-config');
    const cfg = JSON.parse((res && res.config) || '{}');
    uiConfig.hideSessionDetails = !!(cfg.sidebar && cfg.sidebar.hideSessionDetails);
    const sw = cfg.switcher || {};
    uiConfig.switcherEnabled = sw.enabled !== false;
    uiConfig.switcherBinding = (sw.binding && String(sw.binding)) || 'cmd+/';
    uiConfig.switcherCaptureInTerminal = sw.captureInTerminal !== false;
    uiConfig.switcherOrder = (sw.order === 'sidebar') ? 'sidebar' : 'mru';
    uiConfig.switcherPreview = sw.preview !== false;
    const inc = sw.include || {};
    uiConfig.switcherInclude = {
      managers: !!inc.managers,
      jobs: !!inc.jobs,
      reviews: inc.reviews !== false,
      active: inc.active !== false,
      paused: inc.paused !== false,
      in_review: inc.inReview !== false,
      completed: !!inc.completed,
      archived: !!inc.archived,
    };
    // Wheel-scroll sensitivity (CROW-835). Fall back to the defaults for a config
    // that predates the `terminal` block or omits a knob; clamp to a sane floor of
    // 1 so a stray 0 can't wedge the wheel (Math.trunc would never emit a notch).
    const t = cfg.terminal || {};
    uiConfig.wheelScrollLines = Math.max(1, Number(t.wheelScrollLines) || 3);
    uiConfig.agentWheelNotches = Math.max(1, Number(t.agentWheelNotches) || 1);
    uiConfig.notifications = parseNotificationSettings(cfg.notifications);
    try {
      const nr = await rpc('notifications-get');
      const custom = (nr && nr.notifications && nr.notifications.custom_sounds) || [];
      if (window.crowSound && window.crowSound.setCustomSounds) {
        window.crowSound.setCustomSounds(custom);
      }
    } catch (_) { /* custom sounds stay empty; built-in synth still works */ }
    // Presence of the (secret-stripped) webAuth block means a web password is set.
    uiConfig.webPasswordSet = !!cfg.webAuth;
    // Host capability: whether the VS Code `code` CLI is installed. Gates the
    // "Open in VS Code" detail-header button (CROW-749).
    uiConfig.vsCodeAvailable = !!(res && res.vs_code_available);
    // Is this a local-direct connection? The host-action buttons (Open in VS
    // Code / Open Terminal) launch apps on the daemon host and are loopback-gated
    // server-side, so hide them from proxied/remote sessions where they'd only
    // fail — same `/auth/context` signal the Settings secret editors use (CROW-749).
    try {
      const cr = await fetch('/auth/context', { cache: 'no-store' });
      uiConfig.isLocal = cr.ok ? !!(await cr.json()).local : false;
    } catch (_) { uiConfig.isLocal = false; }
    // First-run gate: pointer absent → show the setup wizard (CROW-605).
    if (res && res.configured === false && !document.getElementById('wizard')) {
      showWizard(res.default_dev_root || '');
    }
  } catch (_) { /* keep defaults */ }
  renderSidebar();
  renderStatusBar();
}
window.reloadUIConfig = loadUIConfig;
