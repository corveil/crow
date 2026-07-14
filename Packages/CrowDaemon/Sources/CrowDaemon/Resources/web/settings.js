'use strict';
// Crow web UI — Settings modal (CROW-581). Full-parity editor over the same
// AppConfig the desktop app edits. The whole config travels as one opaque JSON
// string (get-config / set-config), so we JSON.parse it, mutate leaf values in
// place, and JSON.stringify it back — any Swift encoding shape (incl. the
// enum-keyed notification dict) round-trips untouched. Credential VALUES are
// stripped in transport; secrets (the web password and AI gateways) are edited
// via local-only POSTs (SecretRoutes) and shown read-only from a remote/proxied
// session (CROW-593).
//
// Depends on globals from app.js: `el(tag, className, text)` and `rpc()`.
(function () {
  let cfg = null;          // working copy of AppConfig (parsed)
  let devRoot = '';
  let dirty = false;
  let activeTab = 'general';
  let agents = [];         // [{kind, name, default}] from list-agents (local, not remote)
  let subForm = null;      // { kind: 'workspace'|'job', draft, isNew }
  let backdrop = null;
  let escHandler = null;
  // Whether THIS connection may manage secrets (web password, AI gateways).
  // Set from GET /auth/context when the modal opens: true for a local-direct
  // browser (loopback, no proxy), false for a proxied/remote session — which
  // sees those settings read-only (CROW-593).
  let isLocal = false;

  const TABS = [
    ['general', 'General'],
    ['automation', 'Automation'],
    ['workspaces', 'Workspaces'],
    ['jobs', 'Jobs'],
    ['notifications', 'Notifications'],
    ['webaccess', 'Web access'],
    ['about', 'About'],
  ];

  const EVENT_LABELS = {
    taskComplete: 'Task Complete', agentWaiting: 'Agent Waiting',
    reviewRequested: 'Review Requested', changesRequested: 'Changes Requested',
    checksFailing: 'CI Failing',
  };
  // Canonical NotificationEvent set + defaults (CrowCore NotificationEvent) —
  // the config only stores events the user has touched, so we render all five
  // and materialize any missing ones with their default sound (CROW-593).
  const EVENT_ORDER = ['taskComplete', 'agentWaiting', 'reviewRequested', 'changesRequested', 'checksFailing'];
  const EVENT_DEFAULT_SOUND = {
    taskComplete: 'Glass', agentWaiting: 'Funk', reviewRequested: 'Glass',
    changesRequested: 'Funk', checksFailing: 'Sosumi',
  };
  const BUILT_IN_SOUNDS = [
    'Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero', 'Morse',
    'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink',
  ];
  // The app plays macOS system sounds (NSSound) that don't exist in a browser,
  // so the web preview synthesizes a short distinct tone per name via Web Audio
  // — an approximation, no bundled assets (CROW-593). Each recipe is a list of
  // { freq, at?, dur?, type? } oscillator steps.
  const SOUND_TONES = {
    Basso:     [{ freq: 147, type: 'sawtooth', dur: 0.22 }],
    Blow:      [{ freq: 523, type: 'sine', dur: 0.18 }],
    Bottle:    [{ freq: 392, type: 'sine', dur: 0.12 }, { freq: 784, at: 0.08, dur: 0.1 }],
    Frog:      [{ freq: 196, type: 'square', dur: 0.1 }, { freq: 294, at: 0.1, type: 'square', dur: 0.12 }],
    Funk:      [{ freq: 220, type: 'triangle', dur: 0.14 }, { freq: 330, at: 0.12, type: 'triangle', dur: 0.14 }],
    Glass:     [{ freq: 880, type: 'sine', dur: 0.12 }, { freq: 1320, at: 0.06, dur: 0.16 }],
    Hero:      [{ freq: 523, type: 'sine', dur: 0.12 }, { freq: 784, at: 0.12, dur: 0.18 }],
    Morse:     [{ freq: 660, type: 'square', dur: 0.08 }, { freq: 660, at: 0.14, type: 'square', dur: 0.08 }],
    Ping:      [{ freq: 1046, type: 'sine', dur: 0.14 }],
    Pop:       [{ freq: 440, type: 'sine', dur: 0.07 }],
    Purr:      [{ freq: 165, type: 'triangle', dur: 0.22 }],
    Sosumi:    [{ freq: 660, type: 'square', dur: 0.1 }, { freq: 440, at: 0.1, type: 'square', dur: 0.16 }],
    Submarine: [{ freq: 131, type: 'sine', dur: 0.28 }],
    Tink:      [{ freq: 1318, type: 'sine', dur: 0.1 }],
    _default:  [{ freq: 700, type: 'sine', dur: 0.14 }],
  };
  let _audioCtx = null;
  function previewSound(name) {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    try {
      _audioCtx = _audioCtx || new AC();
      const ctx = _audioCtx;
      if (ctx.state === 'suspended') ctx.resume(); // unlocked by the click gesture
      const recipe = SOUND_TONES[name] || SOUND_TONES._default;
      const now = ctx.currentTime;
      for (const step of recipe) {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = step.type || 'sine';
        osc.frequency.value = step.freq;
        const t0 = now + (step.at || 0);
        const dur = step.dur || 0.12;
        gain.gain.setValueAtTime(0.0001, t0);
        gain.gain.exponentialRampToValueAtTime(0.2, t0 + 0.012);
        gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(t0);
        osc.stop(t0 + dur + 0.03);
      }
    } catch (_) { /* Web Audio unavailable */ }
  }
  const WEEKDAYS = [[1, 'Sun'], [2, 'Mon'], [3, 'Tue'], [4, 'Wed'], [5, 'Thu'], [6, 'Fri'], [7, 'Sat']];

  // ---- open / close -------------------------------------------------------

  async function openSettings() {
    let res;
    try { res = await rpc('get-config'); }
    catch (err) { alertModal('Could not load settings: ' + (err.message || err)); return; }
    try { cfg = JSON.parse(res.config || '{}'); } catch (_) { cfg = {}; }
    devRoot = res.dev_root || '';
    // Local list of available agents for the Default-agent picker (#3 /
    // CROW-593). Best-effort — empty when the app is down/old.
    try { const ar = await rpc('list-agents'); agents = (ar && ar.agents) || []; } catch (_) { agents = []; }
    // Is this connection local-direct? Gates the secret editors (web password,
    // gateways) — editable locally, read-only when proxied/remote (CROW-593).
    try { const cr = await fetch('/auth/context'); isLocal = cr.ok ? !!(await cr.json()).local : false; }
    catch (_) { isLocal = false; }
    dirty = false;
    subForm = null;
    activeTab = 'general';
    render();
  }

  async function closeSettings(force) {
    if (!force && dirty && !(await confirmModal('Discard unsaved changes?', { title: 'Discard changes', okLabel: 'Discard', danger: true }))) return;
    if (escHandler) { document.removeEventListener('keydown', escHandler); escHandler = null; }
    if (backdrop) { backdrop.remove(); backdrop = null; }
    subForm = null;
  }

  function markDirty() {
    dirty = true;
    const b = backdrop && backdrop.querySelector('.settings-foot .action-primary');
    if (b) b.disabled = false;
  }

  async function save(btn) {
    btn.disabled = true;
    const orig = btn.textContent;
    btn.textContent = 'Saving…';
    try {
      const res = await rpc('set-config', { config: JSON.stringify(cfg) });
      if (res && res.config) { try { cfg = JSON.parse(res.config); } catch (_) { /* keep working copy */ } }
      dirty = false;
      // set-config doesn't push a `changed`, so nudge the sidebar to re-read
      // config-driven view options (e.g. Hide session details) immediately.
      if (window.reloadUIConfig) window.reloadUIConfig();
      btn.textContent = 'Saved ✓';
      setTimeout(() => { if (!dirty && backdrop) render(); }, 700);
    } catch (err) {
      btn.disabled = false;
      btn.textContent = orig;
      alertModal('Save failed: ' + (err.message || err));
    }
  }

  // ---- shell --------------------------------------------------------------

  function render() {
    if (!backdrop) {
      backdrop = el('div', 'settings-backdrop');
      backdrop.onclick = (ev) => { if (ev.target === backdrop) closeSettings(); };
      // Escape backs out of the topmost overlay first (sub-form), then Settings —
      // matching backdrop-click behavior (review Yellow).
      escHandler = (ev) => {
        if (ev.key !== 'Escape') return;
        if (subForm) { subForm = null; render(); return; }
        closeSettings();
      };
      document.addEventListener('keydown', escHandler);
      document.body.appendChild(backdrop);
    }
    backdrop.innerHTML = '';

    const modal = el('div', 'settings-modal');
    const head = el('div', 'settings-head');
    head.appendChild(el('div', 'settings-title', 'Settings'));
    const close = el('button', 'settings-close', '×');
    close.onclick = () => closeSettings();
    head.appendChild(close);
    modal.appendChild(head);

    const tabs = el('div', 'settings-tabs');
    for (const [key, label] of TABS) {
      const t = el('button', 'settings-tab' + (key === activeTab ? ' active' : ''), label);
      t.onclick = () => { activeTab = key; render(); };
      tabs.appendChild(t);
    }
    modal.appendChild(tabs);

    const body = el('div', 'settings-body');
    renderTab(body);
    modal.appendChild(body);

    const foot = el('div', 'settings-foot');
    foot.appendChild(el('div', 'settings-foot-spacer'));
    const closeBtn = el('button', 'action-btn', 'Close');
    closeBtn.onclick = () => closeSettings();
    foot.appendChild(closeBtn);
    const saveBtn = el('button', 'action-btn action-primary', 'Save');
    saveBtn.disabled = !dirty;
    saveBtn.onclick = () => save(saveBtn);
    foot.appendChild(saveBtn);
    modal.appendChild(foot);

    backdrop.appendChild(modal);

    // Job/workspace editors open as a stacked child modal on top of the main
    // settings modal, instead of replacing its content in place (#7 / CROW-593).
    if (subForm) backdrop.appendChild(renderSubFormOverlay());
  }

  function renderTab(body) {
    if (activeTab === 'general') renderGeneral(body);
    else if (activeTab === 'automation') renderAutomation(body);
    else if (activeTab === 'workspaces') renderWorkspaces(body);
    else if (activeTab === 'jobs') renderJobs(body);
    else if (activeTab === 'notifications') renderNotifications(body);
    else if (activeTab === 'webaccess') renderWebAccess(body);
    else if (activeTab === 'about') renderAbout(body);
  }

  // ---- control builders ---------------------------------------------------

  function group(text) { return el('div', 'st-group', text); }

  function field(labelText, control, help) {
    const f = el('div', 'st-field');
    if (labelText) f.appendChild(el('label', 'st-label', labelText));
    f.appendChild(control);
    if (help) f.appendChild(el('div', 'st-help', help));
    return f;
  }

  function toggleField(labelText, obj, key, help) {
    const row = el('label', 'st-switch-row');
    const input = el('input', 'st-switch');
    input.type = 'checkbox';
    input.checked = !!obj[key];
    input.onchange = () => { obj[key] = input.checked; markDirty(); };
    row.appendChild(input);
    row.appendChild(el('span', 'st-switch-label', labelText));
    const f = el('div', 'st-field');
    f.appendChild(row);
    if (help) f.appendChild(el('div', 'st-help', help));
    return f;
  }

  function textField(labelText, obj, key, opts) {
    opts = opts || {};
    const input = el('input', 'st-input');
    input.type = opts.type || 'text';
    input.value = obj[key] == null ? '' : String(obj[key]);
    if (opts.placeholder) input.placeholder = opts.placeholder;
    if (opts.readonly) { input.readOnly = true; input.classList.add('st-readonly'); }
    else input.oninput = () => {
      if (opts.number) obj[key] = parseIntOr(input.value, obj[key]);
      else obj[key] = input.value;
      markDirty();
    };
    return field(labelText, input, opts.help);
  }

  function selectField(labelText, obj, key, options, opts) {
    opts = opts || {};
    const sel = el('select', 'st-select');
    for (const [val, lab] of options) {
      const o = el('option', null, lab);
      o.value = String(val);
      if (String(obj[key] == null ? '' : obj[key]) === String(val)) o.selected = true;
      sel.appendChild(o);
    }
    sel.onchange = () => {
      const raw = sel.value;
      obj[key] = opts.number ? parseIntOr(raw, obj[key]) : (opts.nullable && raw === '' ? null : raw);
      markDirty();
      if (opts.rerender) render();
    };
    return field(labelText, sel, opts.help);
  }

  // Per-action agent override (coding / reviews / jobs / Manager), mirroring the
  // desktop's four pickers. Bound to cfg.agentsByKind[actionKey]. "Use default"
  // DELETES the key rather than setting null — `[String: AgentKind]` can't
  // decode a null value on the Swift side (CROW-593).
  function agentOverrideField(labelText, actionKey, help) {
    cfg.agentsByKind = cfg.agentsByKind || {};
    const sel = el('select', 'st-select');
    const def = el('option', null, 'Use default');
    def.value = '';
    if (cfg.agentsByKind[actionKey] == null) def.selected = true;
    sel.appendChild(def);
    for (const a of agents) {
      const o = el('option', null, a.name);
      o.value = a.kind;
      if (cfg.agentsByKind[actionKey] === a.kind) o.selected = true;
      sel.appendChild(o);
    }
    sel.onchange = () => {
      if (sel.value === '') delete cfg.agentsByKind[actionKey];
      else cfg.agentsByKind[actionKey] = sel.value;
      markDirty();
    };
    return field(labelText, sel, help);
  }
  // matches the desktop's token chips instead of a newline textarea. Enter or
  // comma adds a chip; × or Backspace-on-empty removes one.
  function listField(labelText, obj, key, help) {
    obj[key] = obj[key] || [];
    const box = el('div', 'st-chips');
    function paint(focusInput) {
      box.innerHTML = '';
      for (const val of obj[key]) {
        const chip = el('span', 'st-chip', val);
        const x = el('button', 'st-chip-x', '×');
        x.type = 'button';
        x.onclick = () => { obj[key] = obj[key].filter((v) => v !== val); markDirty(); paint(true); };
        chip.appendChild(x);
        box.appendChild(chip);
      }
      const input = el('input', 'st-chip-input');
      input.placeholder = obj[key].length ? '' : 'Add…';
      input.onkeydown = (ev) => {
        if (ev.key === 'Enter' || ev.key === ',') {
          ev.preventDefault();
          const v = input.value.trim();
          if (v && !obj[key].includes(v)) { obj[key].push(v); markDirty(); paint(true); }
          else { input.value = ''; }
        } else if (ev.key === 'Backspace' && !input.value && obj[key].length) {
          obj[key].pop(); markDirty(); paint(true);
        }
      };
      input.onblur = () => {
        const v = input.value.trim();
        if (v && !obj[key].includes(v)) { obj[key].push(v); markDirty(); paint(false); }
      };
      box.appendChild(input);
      if (focusInput) input.focus();
    }
    paint(false);
    return field(labelText, box, help);
  }

  function readonlyNote(text) { return el('div', 'st-note', text); }

  // POST a secret-config change to a local-only daemon endpoint (web password,
  // AI gateways). Resolves with the parsed JSON, throws with the server's error
  // message on failure (CROW-593).
  async function postConfig(path, body) {
    const r = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    });
    if (!r.ok) {
      let m = 'HTTP ' + r.status;
      try { const j = await r.json(); if (j && j.error) m = j.error; } catch (_) {}
      throw new Error(m);
    }
    return r.json().catch(() => ({}));
  }

  // "Name: value" lines <-> header map, matching the desktop app's editor.
  function parseHeaderLines(text) {
    const out = {};
    (text || '').split('\n').forEach((line) => {
      const i = line.indexOf(':');
      if (i < 0) return;
      const k = line.slice(0, i).trim();
      if (k) out[k] = line.slice(i + 1).trim();
    });
    return out;
  }
  function headerLines(headers) {
    return Object.keys(headers || {}).map((k) => k + ': ' + headers[k]).join('\n');
  }

  // Editable AI-gateway control (base URL + auth headers), used for the Manager
  // and per-workspace gateways. `current` is the stored gateway
  // ({baseURL, customHeaders}) or null; `apply(gatewayOrNull)` performs the POST
  // and returns a Promise. Header VALUES are never sent to the browser (the
  // daemon strips them), so a set gateway shows its header names with blank
  // values — re-enter a value to change it. Only rendered on a local connection.
  function gatewayEditor(current, apply) {
    const wrap = el('div');
    const url = el('input', 'st-input');
    url.type = 'text';
    url.placeholder = 'https://gateway.example.com';
    url.value = (current && current.baseURL) || '';
    wrap.appendChild(field('Base URL', url, 'The AI-gateway endpoint (an Anthropic-compatible proxy).'));

    const ta = el('textarea', 'st-textarea');
    ta.placeholder = 'X-Api-Key: sk-…\nAnother-Header: value';
    ta.value = current ? headerLines(current.customHeaders || {}) : '';
    wrap.appendChild(field('Auth headers', ta,
      'One per line as "Name: value". Stored on the machine running crowd; re-enter values to change them.'));

    const msg = el('div', 'st-perm-status', '');
    const rowc = el('div', 'st-sound-row');
    const saveBtn = el('button', 'action-btn', current ? 'Update gateway' : 'Set gateway');
    saveBtn.type = 'button';
    saveBtn.onclick = async () => {
      const baseURL = url.value.trim();
      const headers = parseHeaderLines(ta.value);
      const hasURL = !!baseURL, hasHeaders = Object.keys(headers).length > 0;
      if (hasURL !== hasHeaders) {
        msg.textContent = 'Set both a base URL and at least one header, or clear both.';
        return;
      }
      saveBtn.disabled = true; msg.textContent = 'Saving…';
      try { await apply(hasURL ? { baseURL, customHeaders: headers } : null); }
      catch (e) { msg.textContent = 'Failed: ' + (e.message || e); saveBtn.disabled = false; }
    };
    rowc.appendChild(saveBtn);
    if (current) {
      const clearBtn = el('button', 'action-btn', 'Clear gateway');
      clearBtn.type = 'button';
      clearBtn.onclick = async () => {
        if (!await confirmModal('Clear this AI gateway?', { title: 'Clear gateway', okLabel: 'Clear', danger: true })) return;
        clearBtn.disabled = true; msg.textContent = 'Clearing…';
        try { await apply(null); } catch (e) { msg.textContent = 'Failed: ' + (e.message || e); clearBtn.disabled = false; }
      };
      rowc.appendChild(clearBtn);
    }
    wrap.appendChild(rowc);
    wrap.appendChild(msg);
    return wrap;
  }

  function parseIntOr(v, fallback) { const n = parseInt(v, 10); return isNaN(n) ? fallback : n; }

  // ---- General ------------------------------------------------------------

  function renderGeneral(body) {
    cfg.defaults = cfg.defaults || {};
    cfg.defaults.binaries = cfg.defaults.binaries || {};
    cfg.sidebar = cfg.sidebar || {};
    cfg.telemetry = cfg.telemetry || {};
    cfg.cleanup = cfg.cleanup || {};

    body.appendChild(group('Development Root'));
    body.appendChild(textField('Path', { path: devRoot }, 'path',
      { readonly: true, help: 'The dev root is fixed for this daemon and managed in the desktop app.' }));

    body.appendChild(group('Agent'));
    if (agents.length >= 2) {
      // Choose the default agent, like the desktop Settings picker. The options
      // are the locally-available (registered) agents; the launcher gates any
      // other value back to the default (CROW-593).
      body.appendChild(selectField('Default agent', cfg, 'defaultAgentKind',
        agents.map((a) => [a.kind, a.name + (a.default ? ' (default)' : '')]),
        { help: 'Used for new sessions unless overridden. Install more agent CLIs to add options.' }));
      // Per-action overrides (coding / reviews / scheduled jobs / Manager),
      // matching the desktop's four pickers. "Use default" clears the override.
      body.appendChild(agentOverrideField('Agent for coding', 'work'));
      body.appendChild(agentOverrideField('Agent for reviews', 'review'));
      body.appendChild(agentOverrideField('Agent for scheduled jobs', 'job'));
      body.appendChild(agentOverrideField('Agent for Manager', 'manager'));
    } else {
      body.appendChild(textField('Default agent', cfg, 'defaultAgentKind',
        { readonly: true, help: 'Only one agent is available. Install another agent CLI (Codex, Cursor, opencode) to choose.' }));
    }

    body.appendChild(group('Corveil CLI'));
    // The corveil binary is an absolute local path executed at agent launch, so
    // it stays local-only (CROW-593/665) — editable only from a local browser and
    // read-only when proxied/remote, mirroring the web password & AI gateways.
    // (Scheduled jobs, by contrast, are editable from any authenticated session.)
    body.appendChild(textField('Path to corveil binary', cfg.defaults.binaries, 'corveil',
      isLocal
        ? { placeholder: '/path/to/corveil', help: 'Leave blank to skip. Verify/Reinstall are available in the desktop app.' }
        : { readonly: true, help: 'The corveil binary path is editable only from a local browser (on the machine running crowd).' }));

    body.appendChild(group('Sidebar'));
    body.appendChild(toggleField('Hide session details', cfg.sidebar, 'hideSessionDetails',
      'Hides ticket title and repo/branch lines in sidebar rows.'));

    body.appendChild(group('Telemetry'));
    body.appendChild(toggleField('Enable session analytics', cfg.telemetry, 'enabled',
      'Collects cost/token/tool metrics via OpenTelemetry. Requires app restart.'));
    body.appendChild(textField('OTLP receiver port', cfg.telemetry, 'port', { number: true, type: 'number' }));
    body.appendChild(selectField('Retention', cfg.telemetry, 'retentionDays', [
      [30, '30 days'], [90, '90 days'], [180, '6 months'], [365, '1 year'], [0, 'Forever'],
    ], { number: true }));

    body.appendChild(group('Session Cleanup'));
    body.appendChild(toggleField('Auto-delete completed sessions', cfg.cleanup, 'enabled',
      'Deletes completed/archived sessions after the retention period (incl. worktree + branch). Manager, virtual, and locked sessions are never deleted.'));
    body.appendChild(selectField('Retention', cfg.cleanup, 'retentionHours', [
      [1, '1 hour'], [4, '4 hours'], [8, '8 hours'], [24, '1 day'], [72, '3 days'], [168, '7 days'], [720, '30 days'],
    ], { number: true }));
  }

  // ---- Automation ---------------------------------------------------------

  function renderAutomation(body) {
    cfg.defaults = cfg.defaults || {};
    cfg.autoRespond = cfg.autoRespond || {};

    body.appendChild(group('Reviews'));
    body.appendChild(listField('Excluded repos', cfg.defaults, 'excludeReviewRepos',
      'One per line. Repos to hide from the review board. Supports wildcards (e.g. owner/*).'));
    body.appendChild(listField('Ignored labels', cfg.defaults, 'ignoreReviewLabels',
      'One per line. Labels to ignore from the review board (e.g. dependencies, renovate).'));

    body.appendChild(group('Tickets'));
    body.appendChild(listField('Excluded repos', cfg.defaults, 'excludeTicketRepos',
      'One per line. Repos to hide from the ticket board. Supports wildcards.'));

    body.appendChild(group('Permission modes'));
    body.appendChild(toggleField('Enable remote control for new sessions', cfg, 'remoteControlEnabled',
      'New Claude Code sessions start with --rc so you can drive them from claude.ai or the mobile app.'));
    body.appendChild(toggleField('Manager Terminal: launch in auto permission mode', cfg, 'managerAutoPermissionMode',
      'Passes --permission-mode auto so the Manager can run crow/gh/git without per-call approval. Takes effect on next app launch.'));
    body.appendChild(toggleField('Coder Views: launch new coder views in auto permission mode', cfg, 'coderViewAutoPermissionMode',
      'Passes --permission-mode auto so new work coder views start in auto-accept instead of plan mode. Off by default.'));
    body.appendChild(toggleField('Code Reviews: launch in auto permission mode', cfg, 'reviewAutoPermissionMode',
      'Passes --permission-mode auto so a kicked-off code review runs its review flow unattended instead of coming up in plan mode. On by default.'));

    body.appendChild(group('Manager AI gateway'));
    if (isLocal) {
      body.appendChild(gatewayEditor(cfg.managerGateway || null, async (g) => {
        await postConfig('/config/manager-gateway', g ? { baseURL: g.baseURL, headers: g.customHeaders } : { clear: true });
        cfg.managerGateway = g;
        render();
      }));
    } else {
      body.appendChild(readonlyNote((cfg.managerGateway && cfg.managerGateway.baseURL
        ? 'Manager gateway: ' + cfg.managerGateway.baseURL + '. '
        : 'No Manager gateway set. ')
        + 'The gateway is editable only from a local browser (on the machine running crowd).'));
    }
    // Jira credential stays read-only on the web — its token is an op:// ref
    // managed outside the browser.
    body.appendChild(readonlyNote(cfg.jiraCredential && cfg.jiraCredential.username
      ? 'Jira user: ' + cfg.jiraCredential.username + ' (credential managed outside the web UI).'
      : 'No Jira credential set.'));

    body.appendChild(group('Attribution'));
    body.appendChild(toggleField('Add Crow-Session trailer to commits', cfg, 'attributionTrailers',
      'Writes a per-worktree settings.local.json adding a Crow-Session: <uuid> trailer. New worktrees only.'));

    body.appendChild(group('Auto-launch workspaces'));
    body.appendChild(toggleField('Auto-launch workspaces for crow:auto labeled issues', cfg, 'autoCreateWatcherEnabled',
      'The Manager detects assigned issues tagged crow:auto and runs /crow-workspace automatically. Off by default.'));

    body.appendChild(group('Auto-merge'));
    body.appendChild(toggleField('Enable crow:merge auto-merge for Crow-authored PRs', cfg, 'autoMergeWatcherEnabled',
      'A crow:merge label on a Crow-authored PR enables GitHub native auto-merge (squash + delete branch). Off by default.'));

    body.appendChild(group('Auto-respond'));
    body.appendChild(toggleField("Respond to 'changes requested' reviews", cfg.autoRespond, 'respondToChangesRequested',
      'Types a "read the review and address it" prompt into the session terminal.'));
    body.appendChild(toggleField('Respond to failed CI checks', cfg.autoRespond, 'respondToFailedChecks',
      'Types a "read the CI logs and fix it" prompt into the session terminal. Off by default.'));
    body.appendChild(toggleField('Auto-rebase onto base and resolve conflicts', cfg.autoRespond, 'autoRebaseAndResolveConflicts',
      'Rebases a behind/conflicting Crow-authored PR onto base and force-pushes (--force-with-lease). Off by default.'));
  }

  // ---- Notifications ------------------------------------------------------

  // Sound selector with an inline preview button (Web Audio synth, see
  // previewSound). Bound to conf.soundName like the desktop picker (CROW-593).
  function soundField(conf) {
    const wrap = el('div', 'st-sound-row');
    const sel = el('select', 'st-select');
    for (const s of BUILT_IN_SOUNDS) {
      const o = el('option', null, s);
      o.value = s;
      if (conf.soundName === s) o.selected = true;
      sel.appendChild(o);
    }
    sel.onchange = () => { conf.soundName = sel.value; markDirty(); };
    const btn = el('button', 'action-btn', '▶ Preview');
    btn.type = 'button';
    btn.onclick = () => previewSound(sel.value);
    wrap.appendChild(sel);
    wrap.appendChild(btn);
    return field('Sound', wrap,
      'Preview is a synthesized approximation; the desktop app plays the actual macOS system sound.');
  }

  function renderNotifications(body) {
    cfg.notifications = cfg.notifications || {};
    const n = cfg.notifications;
    body.appendChild(group('Global'));
    body.appendChild(toggleField('Mute everything', n, 'globalMute', 'Suppresses all sounds and system notifications.'));
    body.appendChild(toggleField('Enable sound', n, 'soundEnabled'));
    body.appendChild(toggleField('Enable system notifications', n, 'systemNotificationsEnabled'));
    body.appendChild(browserNotifRow());

    for (const [raw, conf] of ensureAllEvents(n)) {
      body.appendChild(group(EVENT_LABELS[raw] || raw));
      body.appendChild(toggleField('Enabled', conf, 'enabled'));
      body.appendChild(toggleField('Play sound', conf, 'soundEnabled'));
      body.appendChild(toggleField('System notification', conf, 'systemNotificationEnabled'));
      body.appendChild(soundField(conf));
    }
  }

  // Browser-notification permission control. The Notification API needs an
  // explicit grant; surface the live state + a button to request it (used by
  // app.js's showEventNotification). Also covers the Tauri webview
  // (CROW-593).
  function browserNotifRow() {
    const supported = typeof window !== 'undefined' && 'Notification' in window;
    const wrap = el('div', 'st-sound-row');
    const btn = el('button', 'action-btn', 'Enable browser notifications');
    btn.type = 'button';
    const status = el('span', 'st-perm-status', '');
    function refresh() {
      if (!supported) { status.textContent = 'Not supported in this browser'; btn.disabled = true; btn.textContent = 'Unavailable'; return; }
      // The Notification API only works in a secure context (HTTPS or
      // localhost). Over plain http:// on a LAN IP, Chrome reports 'denied' and
      // won't prompt — surface that as the real cause, not a user block.
      if (typeof window !== 'undefined' && window.isSecureContext === false) {
        status.textContent = 'Needs HTTPS or a localhost URL — this origin (' + location.host + ') is insecure';
        btn.disabled = true; btn.textContent = 'Unavailable (insecure origin)';
        return;
      }
      const p = Notification.permission;
      status.textContent = 'Permission: ' + p;
      btn.disabled = p === 'granted' || p === 'denied';
      btn.textContent = p === 'granted' ? 'Enabled'
        : p === 'denied' ? 'Blocked — re-enable via the site lock icon → Notifications'
        : 'Enable browser notifications';
    }
    btn.onclick = () => { if (supported) Notification.requestPermission().then(refresh); };
    refresh();
    wrap.appendChild(btn);
    wrap.appendChild(status);
    return field('Browser notifications', wrap,
      'Grant the browser permission to show desktop popups when a session finishes or needs attention. Also applies inside the Tauri desktop app.');
  }

  // eventSettings may be a Swift enum-keyed dict (encoded as [k, v, k, v, ...])
  // or a plain object; return [rawValue, configRef] pairs whose config objects
  // are live references into cfg (so edits round-trip on re-stringify).
  function eventEntries(es) {
    const out = [];
    if (Array.isArray(es)) {
      for (let i = 0; i + 1 < es.length; i += 2) out.push([es[i], es[i + 1]]);
    } else if (es && typeof es === 'object') {
      for (const k of Object.keys(es)) out.push([k, es[k]]);
    }
    return out;
  }

  // Return live [rawValue, configRef] pairs for ALL five canonical events in a
  // stable order, materializing any the config omits with their default sound.
  // New entries are pushed into eventSettings (in its existing array/object
  // shape) so they persist on save without marking the form dirty on open.
  function ensureAllEvents(n) {
    const existing = {};
    for (const [raw, conf] of eventEntries(n.eventSettings)) existing[raw] = conf;
    if (n.eventSettings == null) n.eventSettings = []; // default to Swift array form
    const asObject = !Array.isArray(n.eventSettings);
    for (const raw of EVENT_ORDER) {
      if (existing[raw]) continue;
      const conf = {
        enabled: true, soundEnabled: true, systemNotificationEnabled: true,
        soundName: EVENT_DEFAULT_SOUND[raw] || 'Glass',
      };
      existing[raw] = conf;
      if (asObject) n.eventSettings[raw] = conf;
      else n.eventSettings.push(raw, conf);
    }
    return EVENT_ORDER.map((raw) => [raw, existing[raw]]);
  }

  // ---- Workspaces ---------------------------------------------------------

  // ---- Web access (CROW-593) ---------------------------------------------

  function renderAbout(body) {
    const head = el('div', 'st-about-head');
    const logo = el('img', 'st-about-logo');
    logo.src = '/brand.svg';
    logo.alt = 'Crow';
    const htext = el('div');
    htext.appendChild(el('div', 'st-about-name', 'Crow'));
    const ver = el('div', 'st-about-ver', 'Loading version…');
    htext.appendChild(ver);
    head.append(logo, htext);
    body.appendChild(head);
    body.appendChild(el('div', 'st-help',
      'AI-powered development session manager. crowd is the sole authority; every UI is a client.'));

    fetch('/version.json').then((r) => (r.ok ? r.json() : null)).then((v) => {
      if (!v) { ver.textContent = 'Version unavailable'; return; }
      const parts = ['Version ' + (v.version || '?')];
      if (v.gitSha) parts.push(v.gitSha);
      if (v.buildDate) parts.push(v.buildDate);
      ver.textContent = parts.join(' · ');
    }).catch(() => { ver.textContent = 'Version unavailable'; });

    // Maintenance actions — the desktop app's old Restart/Reload menu items,
    // now reachable from any browser (CROW-593).
    function actBtn(label, labelText, help, run) {
      const b = el('button', 'action-btn', label);
      b.type = 'button';
      b.onclick = run;
      body.appendChild(field(labelText, b, help));
    }

    body.appendChild(group('Maintenance'));
    actBtn('Restart Manager', 'Manager',
      'Relaunches the Manager’s Claude Code session.', async () => {
        if (await confirmModal('Restart the Manager? Its Claude Code session will relaunch.',
          { title: 'Restart Manager', okLabel: 'Restart' })) {
          try { await rpc('restart-manager', {}); }
          catch (e) { alertModal('Restart failed: ' + (e.message || e)); }
        }
      });
    actBtn('Reload tmux config', 'tmux config',
      'Re-applies the bundled tmux config without restarting the server.', async () => {
        try { await rpc('reload-tmux-config', {}); alertModal('tmux config reloaded.'); }
        catch (e) { alertModal('Reload failed: ' + (e.message || e)); }
      });
    actBtn('Reload tmux (restart server)', 'tmux server',
      'Kills and restarts the tmux server — terminals across every session are recreated.', async () => {
        if (await confirmModal('Restart the tmux server? Terminals across every session are recreated.',
          { title: 'Reload tmux', okLabel: 'Restart tmux', danger: true })) {
          try { await rpc('restart-tmux-server', {}); }
          catch (e) { alertModal('Restart failed: ' + (e.message || e)); }
        }
      });
  }

  function renderWebAccess(body) {
    const isSet = !!cfg.webAuth;
    body.appendChild(group('Web access password'));
    body.appendChild(el('div', 'st-perm-status', isSet
      ? 'A web password is set — non-local (proxied) access requires logging in.'
      : 'No web password set — non-local access is disabled until one is set.'));

    if (!isLocal) {
      body.appendChild(readonlyNote(
        'The web password can only be set, changed, or removed from a local browser '
        + '(on the machine running crowd) — never from a remote session, so a remote '
        + 'client can’t change the password that gates its own access.'));
    } else {
      const msg = el('div', 'st-perm-status', '');
      const row = el('div', 'st-sound-row');
      const input = el('input', 'st-input');
      input.type = 'password';
      input.placeholder = isSet ? 'New password' : 'Password';
      input.autocomplete = 'new-password';
      const setBtn = el('button', 'action-btn', isSet ? 'Change password' : 'Set password');
      setBtn.type = 'button';
      setBtn.onclick = async () => {
        if (!input.value) { msg.textContent = 'Enter a password.'; return; }
        setBtn.disabled = true; msg.textContent = 'Saving…';
        try {
          await postConfig('/config/web-password', { password: input.value });
          cfg.webAuth = { hashB64: '', saltB64: '', iterations: 0 }; // reflect "set" locally
          input.value = '';
          render();
        } catch (e) { msg.textContent = 'Failed: ' + (e.message || e); setBtn.disabled = false; }
      };
      row.appendChild(input); row.appendChild(setBtn);
      body.appendChild(field('Password', row,
        'Required for non-local (proxied) access. Applies immediately — no Save needed.'));
      body.appendChild(msg);

      if (isSet) {
        const rmBtn = el('button', 'action-btn', 'Remove password');
        rmBtn.type = 'button';
        rmBtn.onclick = async () => {
          if (!await confirmModal('Remove the web password? Non-local access will be disabled.', { title: 'Remove password', okLabel: 'Remove', danger: true })) return;
          rmBtn.disabled = true;
          try { await postConfig('/config/web-password', { clear: true }); cfg.webAuth = null; render(); }
          catch (_) { rmBtn.disabled = false; }
        };
        body.appendChild(field('Remove', rmBtn, 'Deletes the web password; non-local access is then disabled.'));
      }
    }

    const outBtn = el('button', 'action-btn', 'Log out');
    outBtn.type = 'button';
    outBtn.onclick = async () => {
      try { await fetch('/logout', { method: 'POST' }); } catch (_) {}
      location.reload();
    };
    body.appendChild(field('Session', outBtn, 'Ends this browser’s login session on this device.'));

    body.appendChild(group('Remote access'));
    body.appendChild(el('div', 'st-perm-status',
      'Non-local access must go through an HTTPS proxy (Tailscale serve or ngrok) that forwards to crowd on '
      + 'localhost — bind crowd to loopback so the proxy is the only way in. Direct plain-http LAN access is denied.'));
  }

  function renderWorkspaces(body) {
    cfg.defaults = cfg.defaults || {};
    cfg.workspaces = cfg.workspaces || [];

    body.appendChild(group('Defaults'));
    body.appendChild(selectField('Default provider', cfg.defaults, 'provider',
      [['github', 'GitHub'], ['gitlab', 'GitLab']]));
    body.appendChild(textField('Branch prefix', cfg.defaults, 'branchPrefix', { placeholder: 'feature/' }));

    body.appendChild(group('Workspaces'));
    if (!cfg.workspaces.length) body.appendChild(el('div', 'st-empty', 'No workspaces configured.'));
    for (const ws of cfg.workspaces) {
      body.appendChild(listRow(
        ws.name || '(unnamed)',
        (ws.provider || 'github') + (ws.host ? ' · ' + ws.host : '') + (ws.taskProvider ? ' · tasks: ' + ws.taskProvider : ''),
        () => { subForm = { kind: 'workspace', draft: deepCopy(ws), isNew: false }; render(); },
        () => { cfg.workspaces = cfg.workspaces.filter((x) => x.id !== ws.id); markDirty(); render(); }));
    }
    const add = el('button', 'st-add', '+ Add workspace');
    add.onclick = () => {
      subForm = {
        kind: 'workspace', isNew: true,
        draft: { id: uuid(), name: '', provider: 'github', cli: 'gh', alwaysInclude: [], autoReviewRepos: [], excludeReviewRepos: [] },
      };
      render();
    };
    body.appendChild(add);
  }

  // ---- Jobs ---------------------------------------------------------------

  function renderJobs(body) {
    cfg.jobs = cfg.jobs || [];
    body.appendChild(group('Auto-permission mode'));
    body.appendChild(toggleField('Run scheduled jobs in auto permission mode', cfg, 'jobsAutoPermissionMode',
      'Passes --permission-mode auto so jobs can run crow/gh/git without per-call approval. Takes effect on next run.'));

    body.appendChild(group('Jobs'));
    if (!cfg.jobs.length) body.appendChild(el('div', 'st-empty', 'No jobs configured.'));
    for (const job of cfg.jobs) {
      const row = listRow(
        job.name || '(unnamed)',
        jobScope(job) + ' · ' + scheduleSummary(job.schedule) + (job.enabled ? '' : ' · disabled'),
        () => { subForm = { kind: 'job', draft: deepCopy(job), isNew: false }; render(); },
        () => { cfg.jobs = cfg.jobs.filter((x) => x.id !== job.id); markDirty(); render(); });
      const dup = iconBtn('copy', 'Duplicate');
      dup.onclick = () => {
        const copy = deepCopy(job);
        copy.id = uuid();
        copy.name = (job.name || 'job') + ' copy';
        copy.enabled = false;
        delete copy.lastRunAt;
        cfg.jobs.push(copy);
        markDirty();
        render();
      };
      row.querySelector('.st-row-actions').insertBefore(dup, row.querySelector('.st-row-actions').firstChild);
      // Run this job on demand (mirrors the desktop's play button). Acts on the
      // persisted job, so nudge the user to save pending edits first (CROW-593).
      const run = iconBtn('play', 'Run now');
      run.onclick = async () => {
        if (dirty) { setRowIcon(run, 'cross'); run.title = 'Save changes first'; setTimeout(() => { setRowIcon(run, 'play'); run.title = 'Run now'; }, 1200); return; }
        run.disabled = true; run.title = 'Running…'; setRowIcon(run, 'dots');
        try { await rpc('run-job', { job_id: job.id }); run.title = 'Started'; setRowIcon(run, 'check'); }
        catch (e) { run.title = 'Failed'; setRowIcon(run, 'cross'); }
        setTimeout(() => { run.disabled = false; run.title = 'Run now'; setRowIcon(run, 'play'); }, 1500);
      };
      row.querySelector('.st-row-actions').insertBefore(run, row.querySelector('.st-row-actions').firstChild);
      // Inline enable/disable (CROW-615) — same dirty/save path as Duplicate/Delete.
      const enable = el('input', 'st-switch st-row-switch');
      enable.type = 'checkbox';
      enable.checked = !!job.enabled;
      enable.title = job.enabled ? 'Disable job' : 'Enable job';
      enable.setAttribute('aria-label', enable.title);
      enable.onchange = () => {
        job.enabled = enable.checked;
        markDirty();
        render();
      };
      row.querySelector('.st-row-actions').insertBefore(enable, row.querySelector('.st-row-actions').firstChild);
      body.appendChild(row);
    }
    const add = el('button', 'st-add', '+ Add job');
    add.onclick = () => {
      subForm = {
        kind: 'job', isNew: true,
        draft: { id: uuid(), name: '', workspace: '', repo: '', prompts: [''], schedule: { type: 'interval', seconds: 86400 }, enabled: true },
      };
      render();
    };
    body.appendChild(add);
  }

  function jobScope(job) {
    if ((job.repo || '').includes('/')) return job.repo;
    return job.workspace ? job.workspace + '/' + (job.repo || '') : (job.repo || '');
  }
  function scheduleSummary(s) {
    if (!s) return '';
    if (s.type === 'interval') {
      const sec = s.seconds || 0;
      if (sec % 86400 === 0) return 'every ' + (sec / 86400) + 'd';
      if (sec % 3600 === 0) return 'every ' + (sec / 3600) + 'h';
      return 'every ' + Math.max(1, Math.round(sec / 60)) + 'm';
    }
    const t = pad2(s.hour || 0) + ':' + pad2(s.minute || 0);
    const days = (s.weekdays || []).length
      ? s.weekdays.map((d) => (WEEKDAYS.find((w) => w[0] === d) || [0, '?'])[1]).join(',') + ' at ' + t
      : 'daily at ' + t;
    return days;
  }
  function pad2(n) { return String(n).padStart(2, '0'); }

  // ---- list-row + sub-form scaffolding -----------------------------------

  // Compact row-action icon buttons (CROW-593): a stroked 16px glyph + a hover
  // tooltip (title) in place of a text label. Same visual language as app.js.
  const ROW_ICONS = {
    play: '<path d="M5 3.4 12.6 8 5 12.6z"/>',
    copy: '<rect x="5.5" y="5.5" width="8" height="8" rx="1.2"/><path d="M3.5 10.5A1 1 0 0 1 2.5 9.5v-6a1 1 0 0 1 1-1h6a1 1 0 0 1 1 1"/>',
    pencil: '<path d="M10.5 3 13 5.5l-7 7H3.5V10z"/>',
    trash: '<path d="M3 4.5h10"/><path d="M6.5 4.5V3h3v1.5"/><path d="M4.8 4.5l.6 8.5h5.2l.6-8.5"/>',
    check: '<path d="M3 8.5l3.2 3.2L13 4.5"/>',
    cross: '<path d="M4 4l8 8M12 4l-8 8"/>',
    dots: '<circle cx="4" cy="8" r="0.9"/><circle cx="8" cy="8" r="0.9"/><circle cx="12" cy="8" r="0.9"/>',
  };
  function rowIconSVG(name) {
    return '<svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" '
      + 'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">' + (ROW_ICONS[name] || '') + '</svg>';
  }
  function setRowIcon(btn, name) { btn.innerHTML = rowIconSVG(name); }
  function iconBtn(name, title, extraClass) {
    const b = el('button', 'st-icon-btn' + (extraClass ? ' ' + extraClass : ''));
    b.type = 'button';
    b.title = title;
    b.setAttribute('aria-label', title);
    b.innerHTML = rowIconSVG(name);
    return b;
  }

  function listRow(title, sub, onEdit, onDelete) {
    const row = el('div', 'st-row');
    const main = el('div', 'st-row-main');
    main.appendChild(el('div', 'st-row-title', title));
    main.appendChild(el('div', 'st-row-sub', sub));
    row.appendChild(main);
    const actions = el('div', 'st-row-actions');
    const edit = iconBtn('pencil', 'Edit');
    edit.onclick = onEdit;
    actions.appendChild(edit);
    const del = iconBtn('trash', 'Delete', 'danger');
    del.onclick = onDelete;
    actions.appendChild(del);
    row.appendChild(actions);
    return row;
  }

  function subFormTitle() {
    const noun = subForm.kind === 'workspace' ? 'workspace' : 'job';
    return (subForm.isNew ? 'New ' : 'Edit ') + noun;
  }

  // A stacked child modal (own backdrop, higher z-index) for the job/workspace
  // editor, layered over the main settings modal (#7 / CROW-593). Its body is a
  // real `.settings-body` flex child so tall forms scroll instead of clipping.
  function renderSubFormOverlay() {
    const overlay = el('div', 'settings-backdrop settings-subform-overlay');
    overlay.onclick = (ev) => { if (ev.target === overlay) { subForm = null; render(); } };

    const modal = el('div', 'settings-modal');
    const head = el('div', 'settings-head');
    head.appendChild(el('div', 'settings-title', subFormTitle()));
    const close = el('button', 'settings-close', '×');
    close.onclick = () => { subForm = null; render(); };
    head.appendChild(close);
    modal.appendChild(head);

    const body = el('div', 'settings-body');
    if (subForm.kind === 'workspace') renderWorkspaceForm(body);
    else renderJobForm(body);
    modal.appendChild(body);

    const foot = el('div', 'settings-foot');
    foot.appendChild(el('div', 'settings-foot-spacer'));
    const cancel = el('button', 'action-btn', 'Cancel');
    cancel.onclick = () => { subForm = null; render(); };
    foot.appendChild(cancel);
    const done = el('button', 'action-btn action-primary', subForm.isNew ? 'Add' : 'Done');
    done.onclick = () => commitSubForm();
    foot.appendChild(done);
    modal.appendChild(foot);

    overlay.appendChild(modal);
    return overlay;
  }

  function commitSubForm() {
    const d = subForm.draft;
    if (!d.name || !d.name.trim()) { alertModal('Name is required.'); return; }
    if (subForm.kind === 'workspace') {
      d.cli = d.provider === 'gitlab' ? 'glab' : 'gh';
      upsertByID(cfg.workspaces, d);
    } else {
      d.prompts = (d.prompts || []).map((p) => p).filter((p) => p != null && p.trim() !== '');
      if (!d.prompts.length) { alertModal('At least one prompt is required.'); return; }
      upsertByID(cfg.jobs, d);
    }
    markDirty();
    subForm = null;
    render();
  }

  function upsertByID(arr, item) {
    const idx = arr.findIndex((x) => x.id === item.id);
    if (idx >= 0) arr[idx] = item; else arr.push(item);
  }

  // ---- Workspace sub-form -------------------------------------------------

  function renderWorkspaceForm(body) {
    const d = subForm.draft;
    body.appendChild(textField('Name', d, 'name', { placeholder: 'MyOrg' }));
    body.appendChild(selectField('Provider', d, 'provider',
      [['github', 'GitHub'], ['gitlab', 'GitLab']], { rerender: true }));
    if (d.provider === 'gitlab') {
      body.appendChild(textField('GitLab host', d, 'host', { placeholder: 'gitlab.example.com' }));
    }
    body.appendChild(selectField('Task provider', d, 'taskProvider', [
      ['', 'Follow code provider'], ['github', 'GitHub'], ['gitlab', 'GitLab'], ['jira', 'Jira'], ['corveil', 'Corveil'],
    ], { nullable: true, rerender: true, help: 'Where tickets live, independent of the code host.' }));

    if (d.taskProvider === 'jira') {
      body.appendChild(group('Jira'));
      body.appendChild(textField('Site', d, 'jiraSite', { placeholder: 'acme.atlassian.net' }));
      body.appendChild(textField('Project key', d, 'jiraProjectKey', { placeholder: 'PROPS' }));
      body.appendChild(textField('JQL', d, 'jiraJQL', { placeholder: 'assignee = currentUser() AND statusCategory != Done' }));
      d.jiraStatusMap = d.jiraStatusMap || {};
      for (const status of ['Backlog', 'Ready', 'In Progress', 'In Review', 'Done']) {
        body.appendChild(textField('Status: ' + status, d.jiraStatusMap, status,
          { placeholder: 'Jira status name for ' + status }));
      }
      body.appendChild(el('div', 'st-help', 'Live "Fetch from Jira" status lookup is available in the desktop app.'));
    }
    if (d.taskProvider === 'corveil') {
      body.appendChild(textField('Corveil host', d, 'corveilHost', { placeholder: 'corveil.acme.io (blank = corveil.io)' }));
    }

    body.appendChild(group('Repos'));
    body.appendChild(listField('Always include', d, 'alwaysInclude', 'One owner/repo per line — always listed in the prompt table.'));
    body.appendChild(listField('Auto-review repos', d, 'autoReviewRepos', 'One per line — review requests auto-create a review session.'));
    body.appendChild(listField('Exclude from reviews', d, 'excludeReviewRepos', 'One per line — hidden from the review board.'));

    body.appendChild(group('Instructions'));
    const ta = el('textarea', 'st-textarea');
    ta.value = d.customInstructions || '';
    ta.oninput = () => { d.customInstructions = ta.value; markDirty(); };
    body.appendChild(field('Custom instructions', ta, 'Free-text appended to session prompts.'));

    body.appendChild(group('AI gateway'));
    if (!isLocal) {
      body.appendChild(readonlyNote((d.gateway && d.gateway.baseURL
        ? 'AI gateway: ' + d.gateway.baseURL + '. ' : 'No AI gateway set. ')
        + 'Editable only from a local browser (on the machine running crowd).'));
    } else if (subForm.isNew) {
      body.appendChild(readonlyNote('Save this workspace first, then reopen it to set an AI gateway.'));
    } else {
      body.appendChild(gatewayEditor(d.gateway || null, async (g) => {
        await postConfig('/config/workspace-gateway',
          Object.assign({ workspaceId: d.id }, g ? { baseURL: g.baseURL, headers: g.customHeaders } : { clear: true }));
        d.gateway = g;
        render();
      }));
    }
  }

  // ---- Job sub-form -------------------------------------------------------

  function renderJobForm(body) {
    const d = subForm.draft;
    cfg.workspaces = cfg.workspaces || [];
    body.appendChild(textField('Name', d, 'name', { placeholder: 'Nightly triage' }));
    const wsOptions = [['', '(choose workspace)']].concat(cfg.workspaces.map((w) => [w.name, w.name]));
    body.appendChild(selectField('Workspace', d, 'workspace', wsOptions));
    body.appendChild(textField('Repo', d, 'repo', { placeholder: 'owner/repo' }));

    body.appendChild(group('Prompts'));
    d.prompts = d.prompts && d.prompts.length ? d.prompts : [''];
    d.prompts.forEach((_, i) => {
      const row = el('div', 'st-field');
      const ta = el('textarea', 'st-textarea');
      ta.value = d.prompts[i];
      ta.oninput = () => { d.prompts[i] = ta.value; markDirty(); };
      row.appendChild(ta);
      if (d.prompts.length > 1) {
        const rm = el('button', 'action-btn action-danger', 'Remove prompt');
        rm.onclick = () => { d.prompts.splice(i, 1); markDirty(); render(); };
        row.appendChild(rm);
      }
      body.appendChild(row);
    });
    const addPrompt = el('button', 'st-add', '+ Add prompt');
    addPrompt.onclick = () => { d.prompts.push(''); markDirty(); render(); };
    body.appendChild(addPrompt);

    body.appendChild(group('Schedule'));
    d.schedule = d.schedule || { type: 'interval', seconds: 86400 };
    // Switching type replaces the schedule with a clean, fully-populated default
    // for that variant, so we never send Swift a half-filled shape (e.g. an
    // interval missing `seconds`, which fails to decode).
    const typeSel = el('select', 'st-select');
    for (const [val, lab] of [['interval', 'Every N …'], ['dailyAt', 'Daily at …']]) {
      const o = el('option', null, lab);
      o.value = val;
      if (d.schedule.type === val) o.selected = true;
      typeSel.appendChild(o);
    }
    typeSel.onchange = () => {
      d.schedule = typeSel.value === 'dailyAt'
        ? { type: 'dailyAt', hour: 9, minute: 0, weekdays: [] }
        : { type: 'interval', seconds: 86400 };
      markDirty();
      render();
    };
    body.appendChild(field('Type', typeSel));
    if (d.schedule.type === 'interval') renderIntervalEditor(body, d.schedule);
    else renderDailyEditor(body, d.schedule);

    body.appendChild(group('Status'));
    body.appendChild(toggleField('Enabled', d, 'enabled'));
  }

  function renderIntervalEditor(body, sched) {
    if (sched.seconds == null) sched.seconds = 86400;
    const sec = sched.seconds || 86400;
    let unit = 'minutes', value = Math.max(1, Math.round(sec / 60));
    if (sec % 86400 === 0) { unit = 'days'; value = sec / 86400; }
    else if (sec % 3600 === 0) { unit = 'hours'; value = sec / 3600; }
    const state = { value, unit };
    const recompute = () => {
      const mult = state.unit === 'days' ? 86400 : state.unit === 'hours' ? 3600 : 60;
      sched.seconds = Math.max(1, state.value) * mult;
      // interval schedules carry no hour/minute/weekdays.
      delete sched.hour; delete sched.minute; delete sched.weekdays;
      markDirty();
    };
    body.appendChild(textField('Every', state, 'value', { number: true, type: 'number' }));
    // rebind value onchange to recompute (textField mutates state.value already)
    body.lastChild.querySelector('input').oninput = function () {
      state.value = parseIntOr(this.value, state.value); recompute();
    };
    body.appendChild(selectField('Unit', state, 'unit',
      [['minutes', 'minutes'], ['hours', 'hours'], ['days', 'days']]));
    body.lastChild.querySelector('select').onchange = function () {
      state.unit = this.value; recompute();
    };
  }

  function renderDailyEditor(body, sched) {
    if (sched.hour == null) sched.hour = 9;
    if (sched.minute == null) sched.minute = 0;
    sched.weekdays = sched.weekdays || [];
    delete sched.seconds;
    body.appendChild(textField('Hour (0–23)', sched, 'hour', { number: true, type: 'number' }));
    body.appendChild(textField('Minute (0–59)', sched, 'minute', { number: true, type: 'number' }));
    const f = el('div', 'st-field');
    f.appendChild(el('label', 'st-label', 'Weekdays (none = every day)'));
    for (const [num, label] of WEEKDAYS) {
      const row = el('label', 'st-switch-row');
      const cb = el('input', 'st-switch');
      cb.type = 'checkbox';
      cb.checked = sched.weekdays.includes(num);
      cb.onchange = () => {
        if (cb.checked) { if (!sched.weekdays.includes(num)) sched.weekdays.push(num); }
        else sched.weekdays = sched.weekdays.filter((x) => x !== num);
        sched.weekdays.sort((a, b) => a - b);
        markDirty();
      };
      row.appendChild(cb);
      row.appendChild(el('span', 'st-switch-label', label));
      f.appendChild(row);
    }
    body.appendChild(f);
  }

  // ---- utils --------------------------------------------------------------

  function deepCopy(o) { return JSON.parse(JSON.stringify(o)); }
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    });
  }

  window.openSettings = openSettings;
})();
