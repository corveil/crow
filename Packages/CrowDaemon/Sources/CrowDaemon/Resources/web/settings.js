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
// Tab bodies live in settings-*.js (CROW-1160) and register on window.CrowSettingsTabs.
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
      if (window.CrowSettingsTabs && window.CrowSettingsTabs.applySoundLibraryFromGet) {
        window.CrowSettingsTabs.applySoundLibraryFromGet(n);
      }
    } catch (_) {
      if (window.CrowSettingsTabs && window.CrowSettingsTabs.applySoundLibraryFromGet) {
        window.CrowSettingsTabs.applySoundLibraryFromGet({});
      }
    }
    dirty = false;
    subForm = null;
    if (window.CrowSettingsTabs && window.CrowSettingsTabs.resetCorveilConnectState) {
      window.CrowSettingsTabs.resetCorveilConnectState();
    }
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
    const tabs = window.CrowSettingsTabs || {};
    const fn = tabs[activeTab];
    if (typeof fn === 'function') fn(body);
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
    const tabs = window.CrowSettingsTabs || {};
    if (subForm.kind === 'workspace') {
      if (typeof tabs.workspaceForm === 'function') tabs.workspaceForm(body);
    } else if (typeof tabs.jobForm === 'function') {
      tabs.jobForm(body);
    }
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

  // ---- utils --------------------------------------------------------------

  function deepCopy(o) { return JSON.parse(JSON.stringify(o)); }
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = (Math.random() * 16) | 0;
      return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    });
  }

  // Live getters so tab scripts (loaded first, own IIFE) read the same
  // working copy this shell mutates. Function values close over these lets.
  window.CrowSettings = {
    get cfg() { return cfg; }, set cfg(v) { cfg = v; },
    get dirty() { return dirty; }, set dirty(v) { dirty = v; },
    get isLocal() { return isLocal; },
    get subForm() { return subForm; }, set subForm(v) { subForm = v; },
    get autostart() { return autostart; }, set autostart(v) { autostart = v; },
    get agents() { return agents; },
    get devRoot() { return devRoot; },
    get backdrop() { return backdrop; },
    get activeTab() { return activeTab; },
    markDirty, render, group, field, toggleField, textField, selectField,
    agentOverrideField, defaultAgentField, listField, readonlyNote,
    postConfig, parseHeaderLines, headerLines, gatewayEditor, parseIntOr,
    iconBtn, setRowIcon, listRow, deepCopy, uuid,
    get corveilConnected() { return (window.CrowSettingsTabs || {}).corveilConnected; },
    get orgGatewayEditor() { return (window.CrowSettingsTabs || {}).orgGatewayEditor; },
  };

  window.openSettings = openSettings;
  // The router needs to close the modal when Back leaves #/settings/* (CROW-936),
  // and to move between tabs without the destructive re-entry openSettings does.
  window.settingsIsOpen = () => !!backdrop;
  window.settingsActiveTab = () => activeTab;
  window.closeSettings = closeSettings;
  window.setSettingsTab = setSettingsTab;
})();
