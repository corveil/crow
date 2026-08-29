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
// Depends on globals from the classic client scripts: `el(tag, className, text)` and `rpc()`.
(function () {
  let cfg = null;          // working copy of AppConfig (parsed)
  let devRoot = '';
  let dirty = false;
  let activeTab = 'general';
  let agents = [];         // [{kind, name, default, available, binary}] from list-agents (local, not remote)
  let subForm = null;      // { kind: 'workspace'|'job', draft, isNew }
  let backdrop = null;
  let escHandler = null;
  // Whether THIS connection may manage secrets (web password, AI gateways).
  // Set from GET /auth/context when the modal opens: true for a local-direct
  // browser (loopback, no proxy), false for a proxied/remote session — which
  // sees those settings read-only (CROW-593).
  let isLocal = false;
  // Route to restore when the modal closes (CROW-936) — the view the user was
  // on before Settings opened over it.
  let routeBeforeSettings = null;
  // Login-item state from GET /autostart (CROW-769). Not part of config.json —
  // it's a host-machine registration, so the toggle acts immediately instead of
  // riding the Save button. null when the read failed.
  let autostart = null;

  const TABS = [
    ['general', 'General'],
    ['automation', 'Automation'],
    ['workspaces', 'Workspaces'],
    ['jobs', 'Jobs'],
    ['notifications', 'Notifications'],
    ['webaccess', 'Web access'],
    ['integrations', 'Integrations'],
    ['about', 'About'],
  ];

  const EVENT_LABELS = {
    taskComplete: 'Task Complete', agentWaiting: 'Agent Waiting',
    reviewRequested: 'Review Requested', changesRequested: 'Changes Requested',
    checksFailing: 'CI Failing',
    autoWorkspaceCreated: 'Auto-Workspace Created', autoMergeEnabled: 'Auto-Merge Enabled',
    autoMergeBlocked: 'Auto-Merge Blocked',
    autoRebasePushed: 'Branch Rebased', autoRebaseConflicts: 'Rebase Conflicts',
    autoRebaseStuck: 'Rebase Stuck',
    configReloaded: 'Config Reloaded',
  };
  // One-line "what fires this" hint per event, so the automation entries aren't
  // guesswork (CrowCore NotificationEvent.description).
  const EVENT_HINTS = {
    taskComplete: 'Claude finished responding.',
    agentWaiting: 'Claude needs your input or permission.',
    reviewRequested: 'Someone requested your review on a PR.',
    changesRequested: 'A reviewer requested changes on your PR.',
    checksFailing: 'CI checks started failing on your PR.',
    autoWorkspaceCreated: 'Crow auto-created a workspace for a crow:auto / crow:explore labeled issue.',
    autoMergeEnabled: 'Crow enabled auto-merge on a crow:merge-labeled PR.',
    autoMergeBlocked: "Crow gave up auto-merging a crow:merge PR — e.g. the repo has GitHub's \"Allow auto-merge\" off.",
    autoRebasePushed: 'Crow rebased a PR branch onto its base and force-pushed.',
    autoRebaseConflicts: 'An auto-rebase hit conflicts that need attention.',
    autoRebaseStuck: "An auto-rebase can't proceed — a dirty worktree, or local commits a force-push would destroy.",
    configReloaded: 'Crow picked up a change to config.json.',
  };
  // Canonical NotificationEvent set + defaults (CrowCore NotificationEvent) —
  // the config only stores events the user has touched, so we render all of them
  // and materialize any missing ones with their default sound (CROW-593). The
  // trailing seven are Crow's own automation events (CROW-768, #888, #944).
  const EVENT_ORDER = [
    'taskComplete', 'agentWaiting', 'reviewRequested', 'changesRequested', 'checksFailing',
    'autoWorkspaceCreated', 'autoMergeEnabled', 'autoMergeBlocked', 'autoRebasePushed',
    'autoRebaseConflicts', 'autoRebaseStuck', 'configReloaded',
  ];
  const EVENT_DEFAULT_SOUND = {
    taskComplete: 'Glass', agentWaiting: 'Funk', reviewRequested: 'Glass',
    changesRequested: 'Funk', checksFailing: 'Sosumi',
    autoWorkspaceCreated: 'Hero', autoMergeEnabled: 'Glass', autoMergeBlocked: 'Basso',
    autoRebasePushed: 'Bottle', autoRebaseConflicts: 'Basso', autoRebaseStuck: 'Basso',
    configReloaded: 'Tink',
  };
  const BUILT_IN_SOUNDS = [
    'Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero', 'Morse',
    'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink',
  ];
  // Built-ins plus custom library names, filled from `notifications-get` when
  // Settings opens. Falls back to BUILT_IN_SOUNDS if that RPC fails.
  let availableSounds = BUILT_IN_SOUNDS.slice();
  let customSounds = []; // [{name, file, url}]
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
    if (window.crowSound && typeof window.crowSound.play === 'function') {
      window.crowSound.play(name);
      return;
    }
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

  async function openSettings(tab) {
    // Where to go when Settings closes. Captured before the hash becomes
    // #/settings/* so Close/Esc returns to the session or board underneath
    // rather than dumping the user at home (CROW-936).
    if (!backdrop && typeof currentRoute === 'function') {
      const before = currentRoute();
      routeBeforeSettings = before && before.view !== 'settings' ? before : { view: 'home' };
    }
    let res;
    try { res = await rpc('get-config'); }
    catch (err) {
      alertModal('Could not load settings: ' + (err.message || err));
      // The hash may already read #/settings/* — a deep link or Back put it
      // there and this open is what was meant to honour it. Failing without
      // rewinding leaves the user on the previous view under a Settings URL
      // (review). `replace`: an open that never happened isn't a history entry.
      if (typeof navigate === 'function' && typeof currentRoute === 'function') {
        const now = currentRoute();
        if (now && now.view === 'settings') {
          navigate(routeBeforeSettings || { view: 'home' }, { replace: true });
        }
      }
      routeBeforeSettings = null;
      return;
    }
    try { cfg = JSON.parse(res.config || '{}'); } catch (_) { cfg = {}; }
    devRoot = res.dev_root || '';
    // Local list of available agents for the Default-agent picker (#3 /
    // CROW-593). Best-effort — empty when the app is down/old.
    try { const ar = await rpc('list-agents'); agents = (ar && ar.agents) || []; } catch (_) { agents = []; }
    // Is this connection local-direct? Gates the secret editors (web password,
    // gateways) — editable locally, read-only when proxied/remote (CROW-593).
    try { const cr = await fetch('/auth/context'); isLocal = cr.ok ? !!(await cr.json()).local : false; }
    catch (_) { isLocal = false; }
    // Is crowd registered to start at login? Read-only for everyone; only a
    // local browser may change it (CROW-769).
    try { const ar2 = await fetch('/autostart'); autostart = ar2.ok ? await ar2.json() : null; }
    catch (_) { autostart = null; }
    // Custom sound library (CROW-1147). get-config does not scan the sounds
    // directory, so this is a second read — same payload the CLI `notifications
    // get` prints.
    try {
      const nr = await rpc('notifications-get');
      const n = (nr && nr.notifications) || {};
      availableSounds = Array.isArray(n.available_sounds) && n.available_sounds.length
        ? n.available_sounds : BUILT_IN_SOUNDS.slice();
      customSounds = Array.isArray(n.custom_sounds) ? n.custom_sounds : [];
      if (window.crowSound && window.crowSound.setCustomSounds) {
        window.crowSound.setCustomSounds(customSounds);
      }
    } catch (_) {
      availableSounds = BUILT_IN_SOUNDS.slice();
      customSounds = [];
    }
    dirty = false;
    subForm = null;
    resetCorveilConnectState();
    activeTab = TABS.some(([k]) => k === tab) ? tab : 'general';
    if (typeof navigate === 'function') navigate({ view: 'settings', tab: activeTab });
    render();
  }

  // Move to a tab in an *already open* modal, without re-entering openSettings.
  // Re-entry re-runs get-config, replaces `cfg` and resets `dirty`, so routing
  // Back between tabs through it silently threw away unsaved edits while
  // clicking the same tabs preserved them — same intent, two outcomes, and the
  // destructive one was the one with no prompt (review, CROW-936).
  function setSettingsTab(tab) {
    if (!backdrop) return false;
    activeTab = TABS.some(([k]) => k === tab) ? tab : 'general';
    subForm = null;
    render();
    return true;
  }

  // Returns false when the user cancelled the discard prompt and the modal is
  // therefore still open — the router needs to know so it can put the URL back
  // rather than navigate away from edits it just failed to discard.
  async function closeSettings(force) {
    if (!force && dirty && !(await confirmModal('Discard unsaved changes?', { title: 'Discard changes', okLabel: 'Discard', danger: true }))) return false;
    if (escHandler) { document.removeEventListener('keydown', escHandler); escHandler = null; }
    if (backdrop) { backdrop.remove(); backdrop = null; }
    subForm = null;
    // Return the URL to whatever was open behind the modal. Skipped when the
    // route already moved on — that's applyRoute closing us on the way past,
    // and overwriting its destination would fight it (CROW-936).
    if (typeof navigate === 'function' && typeof currentRoute === 'function') {
      const now = currentRoute();
      if (!now || now.view === 'settings') navigate(routeBeforeSettings || { view: 'home' });
    }
    routeBeforeSettings = null;
    return true;
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
      // Escape backs out of the topmost overlay first (sub-form), then Settings.
      // The sub-form is intentionally *not* backdrop-dismissible (#851), so Esc
      // is its only key-driven close path.
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
      t.onclick = () => {
        activeTab = key;
        render();
        // Each tab is addressable (CROW-936), but `replace` — a tab switch
        // inside an already-open modal is the "UI noise" ADR 0018 says not to
        // turn Back into an undo stack for. Browsing six tabs should not cost
        // six presses to leave. navigate() lives in app.js's top-level scope,
        // the same way this file already reads rpc/el/alertModal.
        if (typeof navigate === 'function') {
          navigate({ view: 'settings', tab: key }, { replace: true });
        }
      };
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
    else if (activeTab === 'integrations') renderIntegrations(body);
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
      const enabled = a.available !== false;
      // Off-PATH agents stay in the list (so users see the harness exists) but
      // are disabled with an inline "(not installed)" suffix + tooltip so it's
      // obvious why they can't be picked (#879). `agentUnavailableHint` lives in
      // app.js, loaded first on the same page.
      const o = el('option', null, a.name + (enabled ? '' : ' (not installed)'));
      o.value = a.kind;
      o.disabled = !enabled;
      if (!enabled && typeof agentUnavailableHint === 'function') o.title = agentUnavailableHint(a);
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

  // The Default agent for new sessions (the fallback the per-action overrides
  // defer to). Bound to cfg.defaultAgentKind. Like agentOverrideField, off-PATH
  // agents render disabled with the "(not installed)" suffix + tooltip so an
  // unlaunchable default can't be picked here (#879) — the generic selectField
  // has no disable support, which is how this picker escaped the first pass and
  // let users persist an unlaunchable defaultAgentKind. No "Use default" option:
  // this IS the default.
  function defaultAgentField(labelText, help) {
    const sel = el('select', 'st-select');
    for (const a of agents) {
      const enabled = a.available !== false;
      const o = el('option', null, a.name + (a.default ? ' (default)' : '') + (enabled ? '' : ' (not installed)'));
      o.value = a.kind;
      o.disabled = !enabled;
      if (!enabled && typeof agentUnavailableHint === 'function') o.title = agentUnavailableHint(a);
      if (cfg.defaultAgentKind === a.kind) o.selected = true;
      sel.appendChild(o);
    }
    sel.onchange = () => { cfg.defaultAgentKind = sel.value; markDirty(); };
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
    cfg.terminal = cfg.terminal || {};

    body.appendChild(group('Development Root'));
    body.appendChild(textField('Path', { path: devRoot }, 'path',
      { readonly: true, help: 'The dev root is fixed for this daemon and managed in the desktop app.' }));

    renderAutostart(body);

    body.appendChild(group('Agent'));
    if (agents.length) {
      // Choose the default agent, like the desktop Settings picker. All known
      // agents are listed; off-PATH ones are disabled (a persisted default that
      // isn't launchable is exactly what the launch gate exists to prevent).
      body.appendChild(defaultAgentField('Default agent',
        'Used for new sessions unless overridden. Uninstalled agents are shown disabled — install the CLI and restart Crow to enable.'));
      // Per-action overrides (coding / reviews / scheduled jobs / Manager),
      // matching the desktop's four pickers. "Use default" clears the override.
      body.appendChild(agentOverrideField('Agent for coding', 'work'));
      body.appendChild(agentOverrideField('Agent for reviews', 'review'));
      body.appendChild(agentOverrideField('Agent for scheduled jobs', 'job'));
      body.appendChild(agentOverrideField('Agent for Manager', 'manager'));
    } else {
      // list-agents returned nothing — the daemon is unreachable, not a
      // one-agent install. Show the stored value read-only rather than an empty
      // dropdown.
      body.appendChild(textField('Default agent', cfg, 'defaultAgentKind',
        { readonly: true, help: 'Agent list unavailable — is crowd running?' }));
    }

    body.appendChild(group('Corveil CLI'));
    // The corveil binary is an absolute local path executed at agent launch, so
    // it stays local-only (CROW-593/665) — editable only from a local browser and
    // read-only when proxied/remote, mirroring the web password & AI gateways.
    // (Scheduled jobs, by contrast, are editable from any authenticated session.)
    // The local editor carries Verify / Reinstall skill with it (CROW-1011);
    // both run the binary on the daemon host, so a remote session gets neither.
    body.appendChild(isLocal
      ? corveilField()
      : textField('Path to corveil binary', cfg.defaults.binaries, 'corveil',
        { readonly: true, help: 'The corveil binary path is editable only from a local browser (on the machine running crowd).' }));

    body.appendChild(group('Sidebar'));
    body.appendChild(toggleField('Hide session details', cfg.sidebar, 'hideSessionDetails',
      'Hides ticket title and repo/branch lines in sidebar rows.'));

    body.appendChild(group('Terminal Scroll'));
    body.appendChild(selectField('Wheel speed — plain shell', cfg.terminal, 'wheelScrollLines', [
      [1, '1 line / notch'], [2, '2 lines / notch'], [3, '3 lines / notch (default)'], [5, '5 lines / notch'], [8, '8 lines / notch'],
    ], { number: true, help: 'Local scrollback lines scrolled per wheel notch on shell/review surfaces.' }));
    body.appendChild(selectField('Wheel speed — agent surfaces', cfg.terminal, 'agentWheelNotches', [
      [1, '1 notch / notch (default)'], [2, '2 notches / notch'], [3, '3 notches / notch'],
    ], { number: true, help: 'Wheel reports forwarded to Claude Code / Cursor per physical notch. Raise if agent scrolling feels too slow.' }));

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

    // Session-log upload tuning (CROW-1070). Global collector behavior only —
    // per-workspace opt-in (and the reused Corveil gateway) live on each workspace
    // under Settings → Workspaces. No credential here.
    cfg.logSync = cfg.logSync || {};
    body.appendChild(group('Session logs'));
    body.appendChild(el('div', 'st-help',
      'Timing and size limits for the session-transcript upload. Opt a workspace in — and configure its AI gateway — under Settings → Workspaces.'));
    body.appendChild(selectField('Quiet period', cfg.logSync, 'quietPeriodMinutes', [
      [5, '5 minutes'], [15, '15 minutes'], [30, '30 minutes (default)'], [60, '1 hour'], [120, '2 hours'],
    ], { number: true, help: 'Wait this long after a session’s last activity before capturing its transcript (a session is uploaded once, when quiescent).' }));
    body.appendChild(selectField('Ledger retention', cfg.logSync, 'retentionDays', [
      [30, '30 days (default)'], [90, '90 days'], [180, '6 months'], [365, '1 year'], [0, 'Forever'],
    ], { number: true, help: 'How long the local upload ledger keeps a record of each session before pruning.' }));
    body.appendChild(textField('Max upload size (bytes)', cfg.logSync, 'maxUploadBytes',
      { number: true, type: 'number', help: 'Per-transcript upload cap (default 8000000). Larger transcripts are truncated and flagged.' }));
  }

  // Path + Verify + Reinstall skill for the Corveil CLI (CROW-1011).
  //
  // Both buttons existed in the retired macOS app and were lost with it; until
  // now this section told people to go use a desktop app that no longer exists.
  // Unlike the rest of General they are actions rather than config fields, so
  // they POST immediately (no Save) to a local-only endpoint — the daemon
  // executes the binary at this path, which is why the caller only builds this
  // for a local browser and renders a read-only field otherwise.
  //
  // The input is built here rather than by `textField` so the buttons can read
  // and watch it directly. That matters: they act on the value CURRENTLY IN THE
  // FIELD, saved or not, which is the point of a Verify button — you check a
  // path before committing it.
  function corveilField() {
    const wrap = el('div', 'st-field');
    wrap.appendChild(el('label', 'st-label', 'Path to corveil binary'));

    const input = el('input', 'st-input');
    input.type = 'text';
    input.placeholder = '/path/to/corveil';
    input.value = cfg.defaults.binaries.corveil || '';
    wrap.appendChild(input);
    wrap.appendChild(el('div', 'st-help',
      'Leave blank to skip. Crow installs the /query-corveil slash command from this binary at launch.'));

    const row = el('div', 'st-row-actions');
    row.style.marginTop = '8px';
    const verify = el('button', 'action-btn', 'Verify');
    verify.type = 'button';
    const reinstall = el('button', 'action-btn', 'Reinstall skill');
    reinstall.type = 'button';
    row.appendChild(verify);
    row.appendChild(reinstall);
    wrap.appendChild(row);

    // One result line for both buttons — they report the same thing about the
    // same binary, and two lines would leave a stale verdict sitting next to a
    // fresh one. The retired desktop app coalesced them for that reason.
    const status = el('div', 'st-perm-status', '');
    status.style.marginTop = '6px';
    wrap.appendChild(status);

    let running = false;
    const reinstallHint = 'Reinstall the bundled /query-corveil skill from this binary — '
      + 'picks up a rebuilt corveil without restarting Crow.';
    // A blank path has nothing to run. Re-evaluated on every keystroke rather
    // than at build time, so typing a path enables the buttons without a save.
    function sync() {
      const empty = !input.value.trim();
      verify.disabled = running || empty;
      reinstall.disabled = running || empty;
      verify.title = empty ? 'Set the Corveil CLI path first.' : '';
      reinstall.title = empty ? 'Set the Corveil CLI path first.' : reinstallHint;
    }

    input.oninput = () => {
      cfg.defaults.binaries.corveil = input.value;
      markDirty();
      sync();
    };

    // Only one action at a time: a slow Verify must not land its answer under a
    // Reinstall clicked after it.
    async function act(button, action, runningLabel, idleLabel) {
      running = true;
      sync();
      button.textContent = runningLabel;
      status.textContent = '';
      try {
        const result = await postConfig('/config/corveil', { action, path: input.value.trim() });
        status.textContent = (result.ok ? '✓ ' : '✗ ') + (result.message || '');
      } catch (err) {
        status.textContent = '✗ ' + (err.message || err);
      }
      button.textContent = idleLabel;
      running = false;
      sync();
    }

    verify.onclick = () => act(verify, 'verify', 'Verifying…', 'Verify');
    reinstall.onclick = () => act(reinstall, 'reinstall-skill', 'Reinstalling…', 'Reinstall skill');

    sync();
    return wrap;
  }

  // "Start Crow at login" (CROW-769). Unlike the rest of General this is not a
  // config field: it registers a launch agent on the machine running crowd, so
  // the toggle POSTs immediately (no Save) and — like the web password and the
  // AI gateways — only a local browser may change it.
  function renderAutostart(body) {
    body.appendChild(group('Autostart'));
    if (!autostart) {
      body.appendChild(readonlyNote('Could not read the autostart status from crowd.'));
      return;
    }
    if (!autostart.supported || !isLocal) {
      body.appendChild(readonlyNote(autostart.supported
        ? autostart.message + ' Autostart is changed only from a local browser (on the machine running crowd).'
        : autostart.message));
      return;
    }

    const row = el('label', 'st-switch-row');
    const input = el('input', 'st-switch');
    input.type = 'checkbox';
    input.checked = !!autostart.enabled;
    input.onchange = async () => {
      input.disabled = true;
      try {
        autostart = await postConfig('/autostart', { enabled: input.checked });
      } catch (err) {
        alertModal('Could not change autostart: ' + (err.message || err));
        input.checked = !input.checked;
      }
      input.disabled = false;
      render();
    };
    row.appendChild(input);
    row.appendChild(el('span', 'st-switch-label', 'Start Crow at login'));
    const f = el('div', 'st-field');
    f.appendChild(row);
    f.appendChild(el('div', 'st-help', autostart.message));
    body.appendChild(f);

    // A plist left pointing at a crowd that has since moved — one click re-points it.
    if (autostart.stale) {
      const fix = el('button', 'action-primary', 'Re-point to this crowd');
      fix.onclick = async () => {
        fix.disabled = true;
        try { autostart = await postConfig('/autostart', { enabled: true }); }
        catch (err) { alertModal('Could not re-point autostart: ' + (err.message || err)); }
        render();
      };
      body.appendChild(field(null, fix));
    }
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
    if (!isLocal) {
      body.appendChild(readonlyNote((cfg.managerGateway && cfg.managerGateway.baseURL
        ? 'Manager gateway: ' + cfg.managerGateway.baseURL + '. '
        : 'No Manager gateway set. ')
        + 'The gateway is editable only from a local browser (on the machine running crowd).'));
    } else {
      // Out-of-band local-only write, like the desktop editor — not part of Save.
      const applyManual = async (g) => {
        await postConfig('/config/manager-gateway', g ? { baseURL: g.baseURL, headers: g.customHeaders } : { clear: true });
        cfg.managerGateway = g;
        render();
      };
      const manual = gatewayEditor(cfg.managerGateway || null, applyManual);
      // Connected → org picker (manual under Advanced); otherwise the raw editor.
      if (corveilConnected(cfg.corveilConnection)) {
        body.appendChild(orgGatewayEditor({
          current: cfg.managerGateway || null,
          postOrg: (orgId) => postConfig('/config/manager-gateway', { orgId }),
          setGateway: (g) => { cfg.managerGateway = g; },
          manual,
        }));
      } else {
        body.appendChild(manual);
      }
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
    body.appendChild(toggleField('Auto-launch workspaces for crow:auto / crow:explore labeled issues', cfg, 'autoCreateWatcherEnabled',
      'The Manager detects assigned issues tagged crow:auto or crow:explore and runs /crow-workspace (or --explore) automatically. Off by default.'));

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
    body.appendChild(toggleField('Re-request review once changes are addressed', cfg.autoRespond, 'autoReRequestReview',
      'Re-adds the reviewers who requested changes once the fix lands, so the PR goes back on their queue instead of stalling.'));
  }

  // ---- Notifications ------------------------------------------------------

  // Custom sound library (CROW-1147). Upload and remove apply immediately —
  // they write the Application Support sounds/ dir, not config.json — so they
  // do not mark the form dirty. Choosing a custom name in a picker still does.
  function customSoundLibrary() {
    const wrap = el('div', 'st-sound-lib');
    if (customSounds.length === 0) {
      wrap.appendChild(el('div', 'st-help', 'No custom sounds yet.'));
    } else {
      for (const sound of customSounds) {
        const row = el('div', 'st-sound-lib-row');
        row.appendChild(el('span', 'st-sound-lib-name', sound.name));
        const preview = el('button', 'action-btn', '▶ Preview');
        preview.type = 'button';
        preview.onclick = () => previewSound(sound.name);
        const del = el('button', 'action-btn', 'Remove');
        del.type = 'button';
        del.onclick = () => removeCustomSound(sound.name);
        row.appendChild(preview);
        row.appendChild(del);
        wrap.appendChild(row);
      }
    }
    const actions = el('div', 'st-sound-row');
    const input = el('input');
    input.type = 'file';
    input.accept = '.wav,.mp3,.aiff,.aif,audio/wav,audio/mpeg,audio/aiff';
    input.style.display = 'none';
    input.onchange = () => {
      const file = input.files && input.files[0];
      input.value = '';
      if (file) uploadCustomSound(file);
    };
    const btn = el('button', 'action-btn', 'Upload sound');
    btn.type = 'button';
    btn.onclick = () => input.click();
    actions.appendChild(btn);
    actions.appendChild(input);
    wrap.appendChild(actions);
    return field('Custom sounds', wrap,
      'WAV, MP3, or AIFF, up to 2 MB. Stored on this machine and playable in the web app. Dropping a file into ~/Library/Application Support/crow/sounds/ also works.');
  }

  async function uploadCustomSound(file) {
    try {
      const res = await fetch('/sounds', {
        method: 'POST',
        headers: { 'X-Filename': encodeURIComponent(file.name) },
        body: file,
        credentials: 'same-origin',
      });
      const body = await res.json().catch(() => ({}));
      if (!res.ok) {
        alertModal(body.error || ('Upload failed (' + res.status + ')'));
        return;
      }
      applySoundLibraryFromUpload(body);
    } catch (err) {
      alertModal('Upload failed: ' + (err.message || err));
    }
  }

  async function removeCustomSound(name) {
    if (!(await confirmModal('Remove “' + name + '”? Events that use it will fall back to a default sound.',
        { title: 'Remove sound', okLabel: 'Remove', danger: true }))) return;
    try {
      const res = await rpc('notifications-remove-sound', { name: name });
      applySoundLibraryFromGet(res && res.notifications);
    } catch (err) {
      alertModal('Remove failed: ' + (err.message || err));
    }
  }

  function applySoundLibraryFromUpload(sound) {
    if (!sound || !sound.name) return;
    customSounds = customSounds.filter((s) => s.name !== sound.name).concat([sound]);
    if (availableSounds.indexOf(sound.name) < 0) availableSounds = availableSounds.concat([sound.name]);
    if (window.crowSound && window.crowSound.setCustomSounds) {
      window.crowSound.setCustomSounds(customSounds);
    }
    render();
  }

  function applySoundLibraryFromGet(n) {
    if (!n) return;
    availableSounds = Array.isArray(n.available_sounds) && n.available_sounds.length
      ? n.available_sounds : BUILT_IN_SOUNDS.slice();
    customSounds = Array.isArray(n.custom_sounds) ? n.custom_sounds : [];
    if (window.crowSound && window.crowSound.setCustomSounds) {
      window.crowSound.setCustomSounds(customSounds);
    }
    render();
  }

  // Sound selector with an inline preview button (Web Audio synth, see
  // previewSound). Bound to conf.soundName like the desktop picker (CROW-593).
  function soundField(conf) {
    const wrap = el('div', 'st-sound-row');
    const sel = el('select', 'st-select');
    const names = availableSounds.slice();
    // Keep a stored custom/missing name selectable so Save doesn't silently
    // rewrite it to the first built-in.
    if (conf.soundName && names.indexOf(conf.soundName) < 0) names.push(conf.soundName);
    for (const s of names) {
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
      'Preview of a built-in is a synthesized approximation; custom sounds play the uploaded file.');
  }

  function renderNotifications(body) {
    cfg.notifications = cfg.notifications || {};
    const n = cfg.notifications;
    body.appendChild(group('Global'));
    body.appendChild(toggleField('Mute everything', n, 'globalMute', 'Suppresses all sounds and system notifications.'));
    body.appendChild(toggleField('Enable sound', n, 'soundEnabled'));
    body.appendChild(toggleField('Enable system notifications', n, 'systemNotificationsEnabled'));
    body.appendChild(browserNotifRow());
    body.appendChild(customSoundLibrary());

    for (const [raw, conf] of ensureAllEvents(n)) {
      body.appendChild(group(EVENT_LABELS[raw] || raw));
      body.appendChild(toggleField('Enabled', conf, 'enabled', EVENT_HINTS[raw]));
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
    const updateStatus = el('div', 'st-about-update', '');
    htext.appendChild(ver);
    htext.appendChild(updateStatus);
    head.append(logo, htext);
    body.appendChild(head);
    body.appendChild(el('div', 'st-help',
      'AI-powered development session manager. crowd is the sole authority; every UI is a client.'));

    cfg.versionUpdate = cfg.versionUpdate || { enabled: true, intervalHours: 1 };

    function renderUpdateStatus(status) {
      updateStatus.textContent = '';
      updateStatus.className = 'st-about-update';
      updateStatus.title = '';
      if (!status || !status.state) return;
      if (status.state === 'up_to_date') {
        updateStatus.textContent = 'Up to date with origin/main.';
        updateStatus.classList.add('st-update-ok');
      } else if (status.state === 'behind') {
        const n = status.behind_by || 0;
        updateStatus.textContent = n + ' commit' + (n === 1 ? '' : 's') + ' behind origin/main.';
        updateStatus.classList.add('st-update-behind');
        if (status.update_command) {
          updateStatus.title = 'Update: ' + status.update_command;
        }
      } else {
        updateStatus.textContent = status.reason || 'Could not check for updates.';
        updateStatus.classList.add('st-update-unknown');
      }
    }

    function loadUpdateStatus() {
      rpc('version-update-get').then((res) => {
        if (res && res.status) renderUpdateStatus(res.status);
      }).catch(() => {
        updateStatus.textContent = 'Update check unavailable.';
        updateStatus.classList.add('st-update-unknown');
      });
    }

    // CROW-1030: the SHA is a link to that commit on corveil/crow. Built as
    // nodes rather than one textContent so the SHA can carry an <a>; the link
    // href uses `gitShaFull` when stamped (the display stays short), and an
    // unlinkable stamp (`dev`, missing, non-hex) renders as plain text.
    function renderVersionLine(v) {
      ver.textContent = '';
      const parts = [];
      parts.push(document.createTextNode('Version ' + (v.version || '?')));
      if (v.gitSha) {
        const url = crowCommitURL(v.gitShaFull || v.gitSha);
        if (url) {
          const a = el('a', 'st-about-sha', v.gitSha);
          a.href = url;
          a.target = '_blank';
          a.rel = 'noopener';
          a.title = 'View this commit on GitHub';
          parts.push(a);
        } else {
          parts.push(document.createTextNode(v.gitSha));
        }
      }
      if (v.buildDate) parts.push(document.createTextNode(v.buildDate));
      parts.forEach((node, i) => {
        if (i > 0) ver.appendChild(document.createTextNode(' · '));
        ver.appendChild(node);
      });
    }

    fetch('/version.json').then((r) => (r.ok ? r.json() : null)).then((v) => {
      if (!v) { ver.textContent = 'Version unavailable'; return; }
      renderVersionLine(v);
    }).catch(() => { ver.textContent = 'Version unavailable'; });

    loadUpdateStatus();

    body.appendChild(group('Updates'));
    body.appendChild(toggleField('Check for upstream updates', cfg.versionUpdate, 'enabled',
      'Compare this build against corveil/crow main on a schedule (at least every hour).'));
    body.appendChild(selectField('Check interval', cfg.versionUpdate, 'intervalHours', [
      [1, '1 hour'], [6, '6 hours'], [12, '12 hours'], [24, '1 day'], [168, '1 week'],
    ], { number: true, help: 'Minimum 1 hour; hourly checks stay within GitHub unauthenticated rate limits.' }));

    const checkRow = el('div', 'st-field');
    const checkBtn = el('button', 'action-btn', 'Check now');
    checkBtn.type = 'button';
    checkBtn.onclick = async () => {
      checkBtn.disabled = true;
      updateStatus.textContent = 'Checking…';
      try {
        const res = await rpc('version-update-check', { force: true });
        renderUpdateStatus(res && res.status);
        if (window.refreshVersionUpdateBanner) window.refreshVersionUpdateBanner(res && res.status);
      } catch (e) {
        updateStatus.textContent = 'Check failed: ' + (e.message || e);
        updateStatus.className = 'st-about-update st-update-unknown';
      } finally {
        checkBtn.disabled = false;
      }
    };
    checkRow.appendChild(el('div', 'st-label', 'Upstream status'));
    checkRow.appendChild(checkBtn);
    body.appendChild(checkRow);

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

    renderMCPTokens(body);

    body.appendChild(group('Remote access'));
    body.appendChild(el('div', 'st-perm-status',
      'Non-local access must go through an HTTPS proxy (Tailscale serve or ngrok) that forwards to crowd on '
      + 'localhost — bind crowd to loopback so the proxy is the only way in. Direct plain-http LAN access is denied.'));
  }

  // MCP bearer tokens (CROW-1004). Sits under Web access because it is the same
  // question — who may reach this daemon from off-box — answered for a different
  // client. Minting is local-only for the same reason the web password is: a remote
  // session must not be able to issue itself the credential that gates remote access.
  function renderMCPTokens(body) {
    cfg.mcpTokens = cfg.mcpTokens || [];
    body.appendChild(group('MCP access tokens'));
    body.appendChild(el('div', 'st-perm-status',
      'Read-only MCP for off-box clients at POST /mcp. Local clients need no token — '
      + 'point them at `crow mcp serve` instead.'));

    if (!cfg.mcpTokens.length) body.appendChild(el('div', 'st-empty', 'No MCP tokens.'));
    for (const token of cfg.mcpTokens) {
      const scopes = (token.scopes || []).join(', ') || 'no scopes';
      const expired = token.expiresAt && new Date(token.expiresAt) <= new Date();
      const expiry = token.expiresAt
        ? (expired ? 'EXPIRED ' : 'expires ') + new Date(token.expiresAt).toLocaleDateString()
        : 'never expires';
      const sub = scopes + ' · ' + expiry
        + (token.prefix ? ' · crow_mcp_' + token.prefix + '…' : '');

      const row = el('div', 'st-row');
      const main = el('div', 'st-row-main');
      main.appendChild(el('div', 'st-row-title', token.name || '(unnamed)'));
      main.appendChild(el('div', 'st-row-sub', sub));
      row.appendChild(main);
      if (isLocal) {
        const actions = el('div', 'st-row-actions');
        const del = iconBtn('trash', 'Revoke', 'danger');
        del.onclick = async () => {
          if (!await confirmModal(
            'Revoke “' + (token.name || 'this token') + '”? Any client using it stops working immediately.',
            { title: 'Revoke token', okLabel: 'Revoke', danger: true })) return;
          del.disabled = true;
          try {
            await postConfig('/config/mcp-tokens', { action: 'revoke', id: token.id });
            cfg.mcpTokens = cfg.mcpTokens.filter((t) => t.id !== token.id);
            render();
          } catch (e) { del.disabled = false; alertModal('Revoke failed: ' + (e.message || e)); }
        };
        actions.appendChild(del);
        row.appendChild(actions);
      }
      body.appendChild(row);
    }

    if (!isLocal) {
      body.appendChild(readonlyNote(
        'MCP tokens can only be minted or revoked from a local browser (on the machine '
        + 'running crowd) — never from a remote session, so a remote client can’t issue '
        + 'itself the credential that gates its own access.'));
      return;
    }

    const msg = el('div', 'st-perm-status', '');
    const nameInput = el('input', 'st-input');
    nameInput.placeholder = 'Name, e.g. grok-bot';

    const scopeSel = el('select', 'st-select');
    for (const [value, label] of [
      ['sessions:read board:read', 'sessions:read + board:read'],
      ['sessions:read', 'sessions:read only'],
      ['board:read', 'board:read only'],
    ]) {
      const opt = el('option', null, label);
      opt.value = value;
      scopeSel.appendChild(opt);
    }

    // Seconds, not a duration string: the HTTP route takes `expiresInSeconds`, and
    // keeping the parsing on the CLI side means one grammar with one owner.
    const EXPIRIES = [
      ['Expires in 90 days', 7776000],
      ['Expires in 30 days', 2592000],
      ['Expires in 1 year', 31536000],
      ['Never expires', 0],
    ];
    const expirySel = el('select', 'st-select');
    for (const [label, value] of EXPIRIES) {
      const opt = el('option', null, label);
      opt.value = String(value);
      expirySel.appendChild(opt);
    }

    const mintBtn = el('button', 'action-btn', 'Mint token');
    mintBtn.type = 'button';
    mintBtn.onclick = async () => {
      const name = nameInput.value.trim();
      if (!name) { msg.textContent = 'Enter a name.'; return; }
      mintBtn.disabled = true; msg.textContent = 'Minting…';
      const scopes = scopeSel.value.split(' ');
      const seconds = Number(expirySel.value);
      const payload = { action: 'mint', name, scopes };
      if (seconds > 0) payload.expiresInSeconds = seconds;
      else payload.noExpiry = true;
      try {
        const result = await postConfig('/config/mcp-tokens', payload);
        // Shown once and never again — only a hash is stored, so there is no
        // "reveal" to come back to. Make that unmissable.
        await alertModal(
          'Copy this token now. It is shown once and cannot be recovered:\n\n' + result.token,
          { title: 'MCP token minted' });
        // Append locally rather than refetching: the shape here must match what
        // `get-config` sends (camelCase), which is what the list above renders.
        cfg.mcpTokens = cfg.mcpTokens.concat([{
          id: result.id,
          name: result.name,
          prefix: result.prefix,
          scopes,
          createdAt: new Date().toISOString(),
          expiresAt: seconds > 0
            ? new Date(Date.now() + seconds * 1000).toISOString()
            : null,
        }]);
        nameInput.value = '';
        msg.textContent = '';
        render();
      } catch (e) {
        msg.textContent = 'Failed: ' + (e.message || e);
        mintBtn.disabled = false;
      }
    };

    const row = el('div', 'st-sound-row');
    row.appendChild(nameInput);
    row.appendChild(scopeSel);
    row.appendChild(expirySel);
    row.appendChild(mintBtn);
    body.appendChild(field('New token', row, 'Shown once. Applies immediately — no Save needed.'));
    body.appendChild(msg);
  }

  // ---- Integrations (CROW-1122) ------------------------------------------
  //
  // The Corveil integration card. The connection is authored ONLY through the
  // local-only OAuth Connect flow (POST /integrations/corveil/connect) and cleared
  // through the local-only POST /config/corveil-connection {clear:true} — never
  // set-config, because the block holds OAuth tokens (SettingsSecrets). So the
  // browser reads connection state from the stripped get-config (cfg.corveilConnection:
  // OAuth token strings blanked, identity / base URL / org metadata kept) and mutates
  // it through those two dedicated endpoints, exactly like the AI gateways and the
  // web password. A proxied/remote session sees it read-only.

  // Connect-flow UI state, module-level so a re-render (Refresh, tab switch,
  // close/reopen) reconstructs the SAME disconnected card instead of dropping a
  // fresh, enabled Connect over a poll that is still in flight (round-2 review).
  // renderCorveilDisconnected derives the button's disabled state and the status
  // copy from these, and the poller drives every change through render() — the
  // card is a pure function of state, so nothing can desync from a stale closure.
  let corveilPolling = false;      // a connect poll is in flight
  let corveilConnectNote = '';     // status line under Connect (opened / timed-out / error)
  let corveilAuthorizeURL = '';    // fallback sign-in link, when Connect returned one
  // Reset the connect-flow state — called when Settings (re)opens so a new modal
  // never inherits a prior attempt's polling flag or copy.
  function resetCorveilConnectState() {
    corveilPolling = false;
    corveilConnectNote = '';
    corveilAuthorizeURL = '';
    resetCorveilOrgState();
  }

  // Org-dropdown state for the gateway editors (corveil/crow#1123), shared by the
  // Manager (Automation tab) and per-workspace (Workspaces tab) pickers — both bind
  // the same connection's memberships. Lazily loaded once through the local-only
  // `corveil-list-orgs` RPC (which caches server-side), then reused across renders.
  // `corveilOrgs === null` means "not fetched yet"; an array (possibly empty) means
  // "fetched". Reset when Settings (re)opens, exactly like the connect-flow state.
  let corveilOrgs = null;          // [{org_id, org_name, provisioned, is_active, role}] | null
  let corveilOrgsLoading = false;  // a list fetch is in flight
  let corveilOrgsError = '';       // last fetch error, shown inline
  function resetCorveilOrgState() {
    corveilOrgs = null;
    corveilOrgsLoading = false;
    corveilOrgsError = '';
  }

  // Fetch the user's Corveil orgs through the local-only provisioning RPC and
  // re-render when done. Guarded so overlapping renders can't stack fetches; the
  // finally-render lets the picker repaint from `corveilOrgs`/`corveilOrgsError`.
  // `force` re-fetches past the server-side cache (the explicit Refresh).
  async function loadCorveilOrgs(force) {
    if (corveilOrgsLoading) return;
    corveilOrgsLoading = true;
    corveilOrgsError = '';
    if (force) render();
    try {
      const res = await rpc('corveil-list-orgs', force ? { refresh: true } : {});
      corveilOrgs = (res && res.orgs) || [];
    } catch (e) {
      corveilOrgs = corveilOrgs || [];
      corveilOrgsError = (e && (e.message || String(e))) || 'could not load organizations';
    } finally {
      corveilOrgsLoading = false;
      render();
    }
  }

  // The org-picker gateway control (corveil/crow#1123). Replaces the raw
  // base-URL+headers editor when a Corveil connection exists: pick an org and Crow
  // provisions its one gateway key (corveil-select-org) and writes the DERIVED
  // gateway — base URL + x-citadel-api-key — through the same local-only POST the
  // manual editor uses, but with { orgId } so the daemon fills in the key secret it
  // never hands the browser. The manual editor stays reachable under "Advanced".
  //
  //   opts.current      — the stored gateway ({baseURL, customHeaders}) or null.
  //   opts.postOrg(id)  — POST the derived gateway ({ orgId: id }); returns a Promise.
  //   opts.setGateway(g)— set the local gateway (cfg.managerGateway / draft.gateway).
  //   opts.manual       — the manual gatewayEditor node (the Advanced fallback).
  function orgGatewayEditor(opts) {
    const wrap = el('div');
    const conn = cfg.corveilConnection || null;

    // Whether the stored gateway looks derived from this connection (its base URL
    // matches and it carries the x-citadel-api-key header). We can't tell WHICH org
    // it came from — the key value is stripped in transport and every org shares the
    // base URL — so we note "set from Corveil" without claiming an org (honest).
    const current = opts.current;
    const derived = !!(current && conn
      && (current.baseURL || '') === (conn.baseURL || '')
      && current.customHeaders
      && Object.keys(current.customHeaders).some((k) => k.toLowerCase() === 'x-citadel-api-key'));
    if (current && current.baseURL) {
      wrap.appendChild(el('div', 'st-perm-status', derived
        ? 'Gateway set from your Corveil connection (' + current.baseURL + ').'
        : 'A manually-entered gateway is set (' + current.baseURL + ').'));
    }

    // Kick the lazy load on first paint; the finally-render repaints with options.
    if (corveilOrgs === null && !corveilOrgsLoading) loadCorveilOrgs(false);

    const msg = el('div', 'st-perm-status', '');
    const sel = el('select', 'st-select');
    const placeholder = el('option', null,
      corveilOrgsLoading ? 'Loading organizations…' : 'Choose an organization…');
    placeholder.value = '';
    sel.appendChild(placeholder);
    for (const org of (corveilOrgs || [])) {
      const bits = [];
      if (org.provisioned) bits.push('key ready');
      if (org.is_active === false) bits.push('inactive');
      const o = el('option', null,
        (org.org_name || org.org_id || '(unnamed org)') + (bits.length ? ' · ' + bits.join(' · ') : ''));
      o.value = org.org_id;
      sel.appendChild(o);
    }
    sel.disabled = corveilOrgsLoading;
    sel.onchange = async () => {
      const orgId = sel.value;
      if (!orgId) return;
      const org = (corveilOrgs || []).find((x) => x.org_id === orgId) || null;
      const label = (org && org.org_name) || orgId;
      sel.disabled = true;
      msg.textContent = 'Provisioning gateway for ' + label + '…';
      try {
        // Mint or reuse the org's one gateway key, then write the derived gateway.
        await rpc('corveil-select-org', { org_id: orgId });
        await opts.postOrg(orgId);
      } catch (e) {
        // The pick itself failed — nothing was stored. Reset the select back to the
        // placeholder so re-picking the SAME org fires `change` again: HTML `change`
        // does not re-fire for an unchanged value, which would otherwise strand this
        // ticket's primary control on the org that just failed.
        msg.textContent = 'Failed: ' + (e && (e.message || e));
        sel.value = '';
        sel.disabled = false;
        return;
      }
      // The gateway is written. Everything past this point is success bookkeeping, so
      // a throw here must NOT report the pick as failed. Mark the org provisioned in
      // place so its "key ready" badge is right on the next paint without a refetch,
      // then show the derived gateway locally — the header value is a secret we don't
      // hold, so blank it, exactly how a stored gateway reads back after stripping.
      if (org) org.provisioned = true;
      opts.setGateway({ baseURL: (conn && conn.baseURL) || '',
        customHeaders: { 'x-citadel-api-key': '' } });
      // Best-effort: refresh the connection so the Integrations tab's per-org key
      // metadata reflects the new key. A failure here leaves the gateway stored and
      // the picker correct, so it must not surface as a failed pick.
      try { await refreshCorveilConnection(); } catch (_) { /* best-effort */ }
      render();
    };
    wrap.appendChild(field('Organization', sel,
      'Pick a Corveil organization — Crow provisions its gateway key and points this gateway at it.'));

    if (corveilOrgsError) {
      wrap.appendChild(el('div', 'st-perm-status', 'Could not load organizations: ' + corveilOrgsError));
    } else if (corveilOrgs && !corveilOrgs.length && !corveilOrgsLoading) {
      wrap.appendChild(el('div', 'st-help', 'No Corveil organizations found for your account.'));
    }
    wrap.appendChild(msg);

    const refresh = el('button', 'action-btn', 'Refresh organizations');
    refresh.type = 'button';
    refresh.disabled = corveilOrgsLoading;
    refresh.onclick = () => loadCorveilOrgs(true);
    wrap.appendChild(field(null, refresh));

    // Manual entry stays available as an advanced fallback. Native <details> keeps
    // it collapsed by default and needs no extra render state.
    const adv = el('details', 'st-advanced-gateway');
    const sum = el('summary', 'st-advanced-summary', 'Enter a gateway manually');
    adv.appendChild(sum);
    adv.appendChild(opts.manual);
    wrap.appendChild(adv);
    return wrap;
  }

  function renderIntegrations(body) {
    body.appendChild(group('Corveil'));
    body.appendChild(el('div', 'st-help',
      'Connect Crow to your Corveil account to provision AI-gateway keys and ship '
      + 'session transcripts to the organizational knowledge graph.'));
    renderCorveilCard(body);
  }

  // Connected = the block is present with a non-empty client id. The block reaches
  // the browser only when a connection is stored, and the client id survives
  // transport (only the OAuth token strings are stripped) — so it is the one
  // always-present, required field that separates "connected" from "not".
  function corveilConnected(conn) {
    return !!(conn && (conn.clientID || '').trim());
  }

  // Re-read ONLY cfg.corveilConnection from a fresh get-config, leaving any unsaved
  // edits on other tabs untouched and never marking the form dirty. The connection
  // lives outside the Save flow (authored via local-only POSTs, restored verbatim on
  // set-config), so this is how the tab reflects a connect/disconnect that completed
  // out of band — the OAuth consent happens in a separate browser window.
  async function refreshCorveilConnection() {
    const res = await rpc('get-config');
    let parsed = {};
    try { parsed = JSON.parse((res && res.config) || '{}'); } catch (_) { parsed = {}; }
    cfg.corveilConnection = parsed.corveilConnection || null;
    return cfg.corveilConnection;
  }

  function renderCorveilCard(body) {
    const conn = cfg.corveilConnection || null;
    const connected = corveilConnected(conn);

    const statusRow = el('div', 'st-corveil-status');
    statusRow.appendChild(el('span', 'st-corveil-dot' + (connected ? ' on' : '')));
    statusRow.appendChild(el('span', 'st-corveil-status-text',
      connected ? corveilIdentityLine(conn) : 'Not connected.'));
    body.appendChild(statusRow);

    if (connected) renderCorveilConnected(body, conn);
    else renderCorveilDisconnected(body, conn);
  }

  function corveilUserText(user) {
    const name = ((user && user.name) || '').trim();
    const email = ((user && user.email) || '').trim();
    if (name && email) return name + ' (' + email + ')';
    return name || email || '';
  }
  function corveilIdentityLine(conn) {
    const t = corveilUserText(conn.connectedUser || {});
    return t ? 'Connected as ' + t : 'Connected to Corveil.';
  }

  // Config dates arrive from get-config encoded by a default Swift JSONEncoder,
  // whose .deferredToDate strategy emits a NUMBER of seconds since the 2001-01-01
  // reference epoch — not unix milliseconds, and not ISO. Handing that straight to
  // `new Date(n)` (which reads a bare number as unix ms) renders every date in
  // January 1970 (CROW-1122 review). Convert the number from the Swift epoch here;
  // also accept an ISO-8601 string defensively (the shape `crow corveil status`
  // emits). Returns a Date, or null when the value is absent or unparseable.
  const SWIFT_REFERENCE_EPOCH_MS = Date.UTC(2001, 0, 1); // 978307200000
  function corveilParseDate(v) {
    if (v == null || v === '') return null;
    const d = typeof v === 'number'
      ? new Date(SWIFT_REFERENCE_EPOCH_MS + v * 1000)
      : new Date(v);
    return isNaN(d.getTime()) ? null : d;
  }

  function corveilOrgSub(org) {
    const parts = [];
    if (org.orgID && org.orgID !== org.orgName) parts.push(org.orgID);
    if ((org.keyPrefix || '').trim()) parts.push('key ' + org.keyPrefix + '…');
    const created = corveilParseDate(org.createdAt);
    if (created) parts.push('provisioned ' + created.toLocaleDateString());
    return parts.join(' · ') || '—';
  }

  function renderCorveilConnected(body, conn) {
    // Identity + base URL, read-only — non-secret fields kept in the stripped
    // config, shown the same way as the read-only dev-root path and gateway views.
    const user = conn.connectedUser || {};
    if (corveilUserText(user)) {
      body.appendChild(textField('Signed in as', { v: corveilUserText(user) }, 'v', { readonly: true }));
    }
    body.appendChild(textField('Base URL', { v: conn.baseURL || '' }, 'v',
      { readonly: true, help: 'The Corveil API endpoint this connection resolves against.' }));

    // Client id + access-token expiry: useful, non-secret connection detail. The
    // token VALUE never reaches the browser (stripped); only its expiry does.
    const detail = [];
    if ((conn.clientID || '').trim()) detail.push('Client ID ' + conn.clientID);
    const exp = corveilParseDate(conn.oauth && conn.oauth.accessTokenExpiresAt);
    if (exp) detail.push('access token expires ' + exp.toLocaleString());
    if (detail.length) body.appendChild(el('div', 'st-perm-status', detail.join(' · ')));

    // Organizations — the per-org gateway-key metadata (never key material; the
    // sk-citadel-… value lives in the generated workspace gateway header, not here).
    body.appendChild(group('Organizations'));
    const orgs = conn.orgKeys || [];
    if (!orgs.length) {
      body.appendChild(el('div', 'st-empty', 'No organizations provisioned yet.'));
    } else {
      for (const org of orgs) {
        const row = el('div', 'st-row');
        const main = el('div', 'st-row-main');
        main.appendChild(el('div', 'st-row-title', org.orgName || org.orgID || '(unnamed org)'));
        main.appendChild(el('div', 'st-row-sub', corveilOrgSub(org)));
        row.appendChild(main);
        body.appendChild(row);
      }
    }

    // Disconnect — local-only, like clearing a gateway.
    body.appendChild(group('Connection'));
    if (!isLocal) {
      body.appendChild(readonlyNote(
        'Disconnecting is available only from a local browser (on the machine running crowd).'));
      return;
    }
    const msg = el('div', 'st-perm-status', '');
    const btn = el('button', 'action-btn action-danger', 'Disconnect');
    btn.type = 'button';
    btn.onclick = async () => {
      if (!await confirmModal(
        'Disconnect from Corveil? Crow stops using this connection. The per-org gateway '
        + 'keys are revoked separately on the Corveil side.',
        { title: 'Disconnect from Corveil', okLabel: 'Disconnect', danger: true })) return;
      btn.disabled = true; msg.textContent = 'Disconnecting…';
      try {
        await postConfig('/config/corveil-connection', { clear: true });
        cfg.corveilConnection = null;
        // Drop the cached memberships too — they belong to the connection just
        // cleared, and a later Connect in this same modal must refetch its own
        // account's orgs rather than paint the previous one's (CROW-1123 review).
        resetCorveilOrgState();
        render();
      } catch (e) {
        msg.textContent = 'Failed: ' + (e.message || e);
        btn.disabled = false;
      }
    };
    body.appendChild(field('Disconnect', btn,
      'Clears the stored connection on this machine. Applies immediately — no Save needed.'));
    body.appendChild(msg);
  }

  function renderCorveilDisconnected(body, conn) {
    // Connect authors OAuth tokens on the daemon host, so — like the web password
    // and AI gateways — it is refused from a proxied/remote session (the POST's own
    // gate). Show a read-only note rather than a dead button.
    if (!isLocal) {
      body.appendChild(readonlyNote(
        'Connect to Corveil from a local browser (on the machine running crowd). '
        + 'The sign-in stores OAuth tokens on that machine, so a remote session can’t start it.'));
      return;
    }

    const msg = el('div', 'st-perm-status', corveilConnectNote);
    const urlInput = el('input', 'st-input');
    urlInput.type = 'text';
    urlInput.placeholder = 'https://app.corveil.example';
    urlInput.value = (conn && conn.baseURL) || '';
    body.appendChild(field('Corveil base URL', urlInput,
      'Your Corveil instance’s URL. Crow self-registers an OAuth client and opens your browser to sign in.'));

    const btn = el('button', 'action-btn action-primary', 'Connect to Corveil');
    btn.type = 'button';
    // Disabled while a poll is in flight, so a re-render (Refresh / tab return /
    // reopen) can never present a second, enabled Connect over a pending sign-in.
    btn.disabled = corveilPolling;
    btn.onclick = async () => {
      const baseURL = urlInput.value.trim();
      if (!baseURL) { corveilConnectNote = 'Enter your Corveil base URL.'; msg.textContent = corveilConnectNote; return; }
      btn.disabled = true;
      corveilConnectNote = 'Opening sign-in…';
      corveilAuthorizeURL = '';
      msg.textContent = corveilConnectNote;
      try {
        const res = await postConfig('/integrations/corveil/connect', { baseURL });
        corveilConnectNote = 'A browser window opened to sign in to Corveil. '
          + 'Complete it there — this updates automatically when you’re done.';
        corveilAuthorizeURL = (res && res.authorizeURL) || '';
        startCorveilConnectPoll();
        // Re-render so the whole card reflects the in-flight poll uniformly
        // (Connect disabled, waiting copy, fallback link) from module state.
        render();
      } catch (e) {
        corveilConnectNote = 'Failed: ' + (e.message || e);
        corveilAuthorizeURL = '';
        msg.textContent = corveilConnectNote;
        btn.disabled = false;
      }
    };
    body.appendChild(field('Connect', btn, 'Applies immediately — no Save needed.'));
    body.appendChild(msg);

    // Auto-open is best-effort on the daemon host; offer the URL as a fallback.
    // Rendered from module state so it survives a re-render while polling.
    if (corveilAuthorizeURL) {
      const fallback = el('div', 'st-perm-status');
      fallback.appendChild(document.createTextNode('Didn’t see a window? '));
      const a = el('a', null, 'Open the sign-in page');
      a.href = corveilAuthorizeURL;
      a.target = '_blank';
      a.rel = 'noopener';
      fallback.appendChild(a);
      body.appendChild(fallback);
    }

    // Manual fallback if the auto-poll window elapses (a slow sign-in). Safe to
    // click during a poll — render() keeps Connect disabled until the poll ends.
    const refresh = el('button', 'action-btn', 'Refresh status');
    refresh.type = 'button';
    refresh.onclick = async () => {
      refresh.disabled = true;
      try { await refreshCorveilConnection(); render(); }
      catch (e) { corveilConnectNote = 'Could not refresh: ' + (e.message || e); msg.textContent = corveilConnectNote; refresh.disabled = false; }
    };
    body.appendChild(field(null, refresh));
  }

  // After Connect, the OAuth consent completes in a separate browser window and the
  // daemon stores the tokens; this tab still holds the pre-connect config. Poll a
  // fresh get-config until the connection appears (or the user leaves), then
  // re-render — into the connected view on success, or back to an enabled Connect
  // (with "still not connected" copy) on timeout. State lives entirely in the module
  // vars above and the card is a pure function of them, so a mid-poll Refresh / tab
  // switch can't leave a stale, stuck button behind.
  function startCorveilConnectPoll() {
    if (corveilPolling) return;
    corveilPolling = true;
    // Bind this poll to the modal instance that started it: a close+reopen replaces
    // `backdrop` with a new element, and this poll must go inert rather than drive
    // (or double up on) the fresh modal — which reset its own state on open.
    const myBackdrop = backdrop;
    let attempts = 0;
    const tick = async () => {
      // Stop if this modal closed/reopened, or the user left the Integrations tab.
      // Clear the transient copy so a later return shows a clean, enabled card.
      if (backdrop !== myBackdrop || activeTab !== 'integrations') {
        if (backdrop === myBackdrop) { corveilPolling = false; corveilConnectNote = ''; corveilAuthorizeURL = ''; }
        return;
      }
      attempts++;
      try {
        if (corveilConnected(await refreshCorveilConnection())) {
          corveilPolling = false;
          corveilConnectNote = '';
          corveilAuthorizeURL = '';
          // Fresh connection → drop any org list cached from a prior one, so the
          // gateway pickers lazily refetch this account's memberships (CROW-1123
          // review). The daemon cache is already connection-keyed; this is the
          // browser-side twin.
          resetCorveilOrgState();
          render();
          return;
        }
      } catch (_) { /* transient — keep polling */ }
      if (attempts >= 24) {
        // Consent + 2FA can outlast the poll window. Drop the flag and re-render:
        // Connect comes back enabled and the copy points at Refresh.
        corveilPolling = false;
        corveilConnectNote = 'Still not connected. Finish the Corveil sign-in, then '
          + 'click Refresh status — or Connect again.';
        corveilAuthorizeURL = '';
        render();
        return;
      }
      setTimeout(tick, 2500);
    };
    setTimeout(tick, 2500);
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
    // Backdrop click is intentionally a no-op for the job/workspace editor: an
    // accidental click off the modal must not silently discard in-progress edits
    // (#851). Close via Cancel / Add-Done / ✕ / Esc only.

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
      ['', 'Follow code provider'], ['github', 'GitHub'], ['gitlab', 'GitLab'], ['jira', 'Jira'],
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

    body.appendChild(group('Repos'));
    body.appendChild(listField('Always include', d, 'alwaysInclude', 'One owner/repo per line — always listed in the prompt table.'));
    body.appendChild(listField('Auto-review repos', d, 'autoReviewRepos', 'One per line — review requests auto-create a review session.'));
    body.appendChild(listField('Exclude from reviews', d, 'excludeReviewRepos', 'One per line — hidden from the review board.'));

    // Review verdict policy (CROW-963). Bound to d.reviewBlockingSeverities:
    // undefined = Crow's default (red + yellow), an array = this workspace's own
    // set. "Use default" DELETES the key rather than storing null or [] — all
    // three round-trip differently. Absent is the default; null would make the
    // whole config undecodable; [] would mean nothing blocks, which the server
    // rejects because it approves every review.
    body.appendChild(group('Review verdict'));
    const SEVERITIES = [
      ['red', 'Red', 'must fix'],
      ['yellow', 'Yellow', 'should fix'],
      ['green', 'Green', 'consider'],
    ];
    const isCustomPolicy = Array.isArray(d.reviewBlockingSeverities);
    const policySel = el('select', 'st-select');
    const policyDefault = el('option', null, 'Use default (Red, Yellow)');
    policyDefault.value = '';
    const policyCustom = el('option', null, 'Custom');
    policyCustom.value = 'custom';
    policySel.appendChild(policyDefault);
    policySel.appendChild(policyCustom);
    policySel.value = isCustomPolicy ? 'custom' : '';
    policySel.onchange = () => {
      if (policySel.value === '') delete d.reviewBlockingSeverities;
      else d.reviewBlockingSeverities = ['red'];
      markDirty();
      render();
    };
    body.appendChild(field('Blocking severities', policySel,
      'Which review findings force Request Changes. Non-blocking findings are still reported in the review body — only the verdict changes. Advisory: the agent posts its own verdict and Crow cannot check it against this setting.'));

    if (isCustomPolicy) {
      const policyHint = el('div', 'st-help', '');
      for (const [key, label, meaning] of SEVERITIES) {
        const row = el('label', 'st-switch-row');
        const cb = el('input', 'st-switch');
        cb.type = 'checkbox';
        cb.checked = d.reviewBlockingSeverities.indexOf(key) !== -1;
        cb.onchange = () => {
          // Rebuilt by walking SEVERITIES so the stored order is always
          // canonical (red, yellow, green), matching the CLI and the renderer.
          const next = SEVERITIES
            .map((s) => s[0])
            .filter((k) => (k === key ? cb.checked : d.reviewBlockingSeverities.indexOf(k) !== -1));
          if (!next.length) {
            // At least one severity must block. The server rejects an empty set
            // too; refusing here stops the form from building a payload that can
            // only fail, and points at the affordance that does what they meant.
            cb.checked = true;
            policyHint.textContent = 'At least one severity must block. Choose "Use default" to go back to Red + Yellow.';
            return;
          }
          d.reviewBlockingSeverities = next;
          policyHint.textContent = '';
          markDirty();
        };
        row.appendChild(cb);
        row.appendChild(el('span', 'st-switch-label', label + ' — ' + meaning));
        body.appendChild(field(null, row));
      }
      body.appendChild(policyHint);
    }

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
      // Out-of-band local-only write, matched to the workspace by id — like the
      // desktop editor, not part of Save (`preservingSecrets` restores the stored
      // gateway on set-config, so the blank header the org path leaves is never
      // written back).
      const applyManual = async (g) => {
        await postConfig('/config/workspace-gateway',
          Object.assign({ workspaceId: d.id }, g ? { baseURL: g.baseURL, headers: g.customHeaders } : { clear: true }));
        d.gateway = g;
        render();
      };
      const manual = gatewayEditor(d.gateway || null, applyManual);
      if (corveilConnected(cfg.corveilConnection)) {
        body.appendChild(orgGatewayEditor({
          current: d.gateway || null,
          // Picking an org derives this workspace's gateway from that org's key AND —
          // because the log upload reuses that same gateway — the daemon auto-enables
          // uploadSessionLogs in the same write (corveil/crow#1124). The POST reports
          // that decision back as `log_sync_enabled`; honor it (the single source of
          // truth, so client and server can't drift) on BOTH the open draft — so the
          // checkbox reads right — and the live cfg.workspaces entry. The cfg entry is
          // load-bearing: the draft only reaches cfg on Done, so a pick-then-Cancel
          // would otherwise leave cfg.uploadSessionLogs false and a later Save
          // (set-config, which the browser wins on for this non-secret field) would
          // clobber the server's opt-in back off.
          postOrg: async (orgId) => {
            const res = await postConfig('/config/workspace-gateway', { workspaceId: d.id, orgId });
            if (res && res.log_sync_enabled) {
              d.uploadSessionLogs = true;
              const ws = (cfg.workspaces || []).find((w) => w.id === d.id);
              if (ws) ws.uploadSessionLogs = true;
            }
            return res;
          },
          setGateway: (g) => { d.gateway = g; },
          manual,
        }));
      } else {
        body.appendChild(manual);
      }
    }

    // Session-log upload opt-in (CROW-1066; sole opt-in since CROW-1070). A plain
    // workspace field, so it round-trips through the normal Save (`set-config`).
    // The upload REUSES this workspace's gateway for BOTH destination and
    // credential, so the checkbox is meaningful only when a gateway is set:
    // disabled with a tooltip otherwise. There is no separate master switch — a
    // ticked box plus a configured gateway is the whole opt-in.
    body.appendChild(group('Session logs'));
    const hasGateway = !!(d.gateway && (d.gateway.baseURL
      || (d.gateway.customHeaders && Object.keys(d.gateway.customHeaders).length)));
    const slRow = el('label', 'st-switch-row');
    const slCb = el('input', 'st-switch');
    slCb.type = 'checkbox';
    slCb.checked = !!d.uploadSessionLogs;
    slCb.disabled = !hasGateway;
    if (!hasGateway) slRow.title = 'Turn on the AI Gateway for this workspace first — the upload reuses its URL and credential.';
    slCb.onchange = () => { d.uploadSessionLogs = slCb.checked; markDirty(); };
    slRow.appendChild(slCb);
    slRow.appendChild(el('span', 'st-switch-label', 'Upload session transcripts to Corveil'));
    const slField = el('div', 'st-field');
    slField.appendChild(slRow);
    slField.appendChild(el('div', 'st-help', hasGateway
      ? 'Uploads this workspace’s coding-session transcripts to Corveil, reusing its AI-gateway URL and credential (no second key or host needed). That’s the only setting required — collector timing and size limits live under Settings → General → Session logs.'
      : 'Turn on the AI Gateway for this workspace above first — the upload reuses its URL and credential.'));
    body.appendChild(slField);

    // Historical backfill (CROW-1075): reconcile the transcripts already on disk
    // (predating the live path, or reaped from the store) and upload the ones you
    // choose. Reuses this workspace's gateway for the upload, so it's gated on one
    // being configured, exactly like the checkbox above.
    const bfField = el('div', 'st-field');
    const bfBtn = el('button', 'action-btn', 'Backfill history…');
    bfBtn.type = 'button';
    bfBtn.disabled = !hasGateway;
    if (!hasGateway) bfBtn.title = 'Turn on the AI Gateway for this workspace first — the upload reuses its URL and credential.';
    bfBtn.onclick = () => openBackfillDialog(d.name);
    bfField.appendChild(bfBtn);
    bfField.appendChild(el('div', 'st-help',
      'Scan the coding-session transcripts already on disk, review the reconstructed workspace / repo / ticket for each, and upload the ones you select — idempotently, through the same path as live sessions.'));
    body.appendChild(bfField);
  }

  // ---- Backfill history dialog (CROW-1075) --------------------------------
  //
  // A self-contained overlay (its own backdrop over the workspace sub-form) that
  // scans the on-disk transcripts, shows the reconstructed workspace/repo/ticket
  // per session with a confidence tier and ledger status, and uploads a selected
  // subset. Mirrors the Allowlist board's filter + multi-select + counted-primary
  // pattern, but stands alone rather than joining Settings' render() cycle so its
  // scan/selection state can't be clobbered by an unrelated repaint.

  function bfHumanBytes(n) {
    if (!n) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB']; let i = 0; let v = n;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i === 0 ? v : v.toFixed(1)) + ' ' + u[i];
  }
  function bfFmtDate(epoch) {
    if (!epoch) return '—';
    try { return new Date(epoch * 1000).toISOString().slice(0, 10); } catch (_) { return '—'; }
  }
  const BF_CONF_LABEL = { high: 'High', medium: 'Repo only', low: 'Orphan' };
  const BF_STATUS_LABEL = { new: 'Not uploaded', uploaded: 'Uploaded', skipped: 'Skipped', failed: 'Failed' };

  function openBackfillDialog(workspaceName) {
    let sessions = [];
    const selected = new Set();
    const filters = { workspace: '', status: '', confidence: '', text: '' };
    let uploading = false;
    let note = '';

    const overlay = el('div', 'settings-backdrop settings-subform-overlay backfill-overlay');
    const modal = el('div', 'settings-modal backfill-modal');
    overlay.appendChild(modal);

    function close() { document.removeEventListener('keydown', onKey); overlay.remove(); }
    function onKey(e) { if (e.key === 'Escape' && !uploading) close(); }
    document.addEventListener('keydown', onKey);

    const head = el('div', 'settings-head');
    head.appendChild(el('div', 'settings-title', 'Backfill history — ' + workspaceName));
    const closeBtn = el('button', 'settings-close', '×');
    closeBtn.onclick = close;
    head.appendChild(closeBtn);
    modal.appendChild(head);

    const body = el('div', 'settings-body');
    const summary = el('div', 'backfill-summary', 'Scanning ~/.claude/projects, ~/.codex/sessions and ~/.cursor/chats…');
    body.appendChild(summary);

    const filterRow = el('div', 'backfill-filters');
    const textInput = el('input', 'st-input backfill-filter-text');
    textInput.type = 'text';
    textInput.placeholder = 'Filter by repo, ticket, slug…';
    textInput.oninput = () => { filters.text = textInput.value.trim().toLowerCase(); refresh(); };
    filterRow.appendChild(textInput);
    const wsSel = el('select', 'st-input backfill-sel');
    wsSel.onchange = () => { filters.workspace = wsSel.value; refresh(); };
    const stSel = el('select', 'st-input backfill-sel');
    stSel.onchange = () => { filters.status = stSel.value; refresh(); };
    const cfSel = el('select', 'st-input backfill-sel');
    cfSel.onchange = () => { filters.confidence = cfSel.value; refresh(); };
    filterRow.appendChild(wsSel);
    filterRow.appendChild(stSel);
    filterRow.appendChild(cfSel);
    body.appendChild(filterRow);

    const tableWrap = el('div', 'backfill-table-wrap');
    tableWrap.appendChild(el('div', 'backfill-empty', 'Scanning…'));
    body.appendChild(tableWrap);
    modal.appendChild(body);

    const foot = el('div', 'settings-foot');
    const noteEl = el('div', 'backfill-note');
    foot.appendChild(noteEl);
    foot.appendChild(el('div', 'settings-foot-spacer'));
    const selAllBtn = el('button', 'action-btn', 'Select all (filtered)');
    selAllBtn.onclick = () => {
      const vis = visibleSessions().filter(bfSelectable);
      const allSel = vis.length > 0 && vis.every((s) => selected.has(s.uid));
      vis.forEach((s) => { if (allSel) selected.delete(s.uid); else selected.add(s.uid); });
      refresh();
    };
    foot.appendChild(selAllBtn);
    const uploadBtn = el('button', 'action-btn action-primary', 'Backfill (0)');
    uploadBtn.onclick = doUpload;
    foot.appendChild(uploadBtn);
    modal.appendChild(foot);

    document.body.appendChild(overlay);

    // A session is selectable when it hasn't already uploaded.
    function bfSelectable(s) { return (s.upload_status || 'new') !== 'uploaded'; }

    function setOptions(sel, opts, value) {
      sel.innerHTML = '';
      opts.forEach(([v, l]) => {
        const o = el('option', null, l); o.value = v;
        if (v === value) o.selected = true;
        sel.appendChild(o);
      });
    }
    function fillSelectOptions() {
      const wss = Array.from(new Set(sessions.map((s) => s.workspace).filter(Boolean))).sort();
      setOptions(wsSel, [['', 'All workspaces']].concat(wss.map((w) => [w, w])), filters.workspace);
      setOptions(stSel, [['', 'Any status'], ['new', 'Not uploaded'], ['uploaded', 'Uploaded'], ['skipped', 'Skipped'], ['failed', 'Failed']], filters.status);
      setOptions(cfSel, [['', 'Any confidence'], ['high', 'High'], ['medium', 'Repo only'], ['low', 'Orphan']], filters.confidence);
    }

    function visibleSessions() {
      return sessions.filter((s) => {
        if (filters.workspace && s.workspace !== filters.workspace) return false;
        if (filters.status && (s.upload_status || 'new') !== filters.status) return false;
        if (filters.confidence && s.confidence !== filters.confidence) return false;
        if (filters.text) {
          const hay = [s.repo_name, s.owner_repo, s.slug, s.workspace, s.worktree_name, String(s.ticket_number || '')].join(' ').toLowerCase();
          if (hay.indexOf(filters.text) === -1) return false;
        }
        return true;
      });
    }

    function ticketCell(s) {
      if (!s.ticket_number) return '—';
      const kind = s.ticket_kind === 'pull_request' ? 'PR' : '#';
      return (s.owner_repo ? '' : '') + kind + s.ticket_number;
    }

    function refresh() {
      fillSelectOptions();
      const vis = visibleSessions();
      tableWrap.innerHTML = '';
      if (!sessions.length) {
        tableWrap.appendChild(el('div', 'backfill-empty', 'No coding-session transcripts found on disk.'));
      } else if (!vis.length) {
        tableWrap.appendChild(el('div', 'backfill-empty', 'No sessions match the current filters.'));
      } else {
        const table = el('table', 'backfill-table');
        const thead = el('thead');
        const hr = el('tr');
        const selectableVis = vis.filter(bfSelectable);
        const allSel = selectableVis.length > 0 && selectableVis.every((s) => selected.has(s.uid));
        const thCheck = el('th', 'backfill-check');
        const hCb = el('input'); hCb.type = 'checkbox'; hCb.checked = allSel; hCb.disabled = uploading || !selectableVis.length;
        hCb.onchange = () => { selectableVis.forEach((s) => { if (hCb.checked) selected.add(s.uid); else selected.delete(s.uid); }); refresh(); };
        thCheck.appendChild(hCb);
        hr.appendChild(thCheck);
        ['Workspace', 'Repo', 'Ticket', 'Date', 'Size', 'Status', 'Confidence'].forEach((h) => hr.appendChild(el('th', null, h)));
        thead.appendChild(hr);
        table.appendChild(thead);

        const tbody = el('tbody');
        vis.forEach((s) => {
          const tr = el('tr', 'backfill-row conf-' + (s.confidence || 'low'));
          const tdc = el('td', 'backfill-check');
          const cb = el('input'); cb.type = 'checkbox';
          cb.checked = selected.has(s.uid);
          cb.disabled = uploading || !bfSelectable(s);
          cb.onchange = () => { if (cb.checked) selected.add(s.uid); else selected.delete(s.uid); updateCount(); };
          tdc.appendChild(cb);
          tr.appendChild(tdc);
          tr.appendChild(el('td', null, s.workspace || '—'));
          tr.appendChild(el('td', 'backfill-repo', s.owner_repo || s.repo_name || '—'));
          tr.appendChild(el('td', null, ticketCell(s)));
          tr.appendChild(el('td', null, bfFmtDate(s.modified_at)));
          tr.appendChild(el('td', null, bfHumanBytes(s.size_bytes)));
          const st = s.upload_status || 'new';
          const tdSt = el('td', 'backfill-status status-' + st, BF_STATUS_LABEL[st] || st);
          if (s._outcome && s._outcome.reason) tdSt.title = s._outcome.reason;
          tr.appendChild(tdSt);
          tr.appendChild(el('td', 'backfill-conf', BF_CONF_LABEL[s.confidence] || s.confidence || '—'));
          tbody.appendChild(tr);
        });
        table.appendChild(tbody);
        tableWrap.appendChild(table);
      }
      updateCount();
      noteEl.textContent = note;
    }

    function updateCount() {
      uploadBtn.textContent = 'Backfill (' + selected.size + ')';
      uploadBtn.disabled = uploading || selected.size === 0;
    }

    function summarize(sm) {
      if (!sm) return '';
      return sm.total + ' on disk · ' + sm.uploaded + ' uploaded · '
        + sm.linkable + ' fully linkable · ' + (sm.repo_only + sm.orphan) + ' repo-only/orphan';
    }

    async function scan() {
      summary.textContent = 'Scanning ~/.claude/projects, ~/.codex/sessions and ~/.cursor/chats…';
      try {
        const res = await rpc('backfill-scan', {});
        sessions = res.sessions || [];
        // Default-select this workspace's high-confidence, not-yet-uploaded rows —
        // the safe "import my history" starting point; everything else is opt-in.
        sessions.forEach((s) => {
          if (s.confidence === 'high' && (s.upload_status || 'new') !== 'uploaded' && s.workspace === workspaceName) {
            selected.add(s.uid);
          }
        });
        summary.textContent = summarize(res.summary);
      } catch (e) {
        summary.textContent = 'Scan failed: ' + ((e && e.message) || e);
        sessions = [];
      }
      refresh();
    }

    async function doUpload() {
      const uids = Array.from(selected);
      if (!uids.length || uploading) return;
      uploading = true;
      uploadBtn.textContent = 'Uploading ' + uids.length + '…';
      uploadBtn.disabled = true;
      note = '';
      refresh();
      try {
        const res = await rpc('backfill-upload', { workspace: workspaceName, sessions: uids });
        // Key results by (uid, harness): a UID shared by a Claude and a Codex row
        // maps each scan row to its own outcome instead of overwriting (CROW-1089).
        const outcomeKey = (o) => (o.uid || '') + ' ' + (o.harness || 'claude');
        const byKey = {};
        (res.results || []).forEach((r) => { byKey[outcomeKey(r)] = r; });
        sessions.forEach((s) => {
          const r = byKey[outcomeKey(s)];
          if (!r) return;
          s.upload_status = (r.result === 'uploaded' || r.result === 'already') ? 'uploaded'
            : (r.result === 'skipped' ? 'skipped' : 'failed');
          s._outcome = r;
        });
        selected.clear();
        const sm = res.summary || {};
        note = 'Uploaded ' + (sm.uploaded || 0) + ' · linked ' + (sm.linked || 0)
          + ' · already ' + (sm.already || 0) + ' · skipped ' + (sm.skipped || 0)
          + ' · failed ' + (sm.failed || 0);
      } catch (e) {
        note = 'Upload failed: ' + ((e && e.message) || e);
      }
      uploading = false;
      refresh();
    }

    scan();
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
  // The router needs to close the modal when Back leaves #/settings/* (CROW-936),
  // and to move between tabs without the destructive re-entry openSettings does.
  window.settingsIsOpen = () => !!backdrop;
  window.settingsActiveTab = () => activeTab;
  window.closeSettings = closeSettings;
  window.setSettingsTab = setSettingsTab;
})();
