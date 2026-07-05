'use strict';
// Crow web UI — Settings modal (CROW-581). Full-parity editor over the same
// AppConfig the desktop app edits. The whole config travels as one opaque JSON
// string (get-config / set-config), so we JSON.parse it, mutate leaf values in
// place, and JSON.stringify it back — any Swift encoding shape (incl. the
// enum-keyed notification dict) round-trips untouched. Credentials are stripped
// by the daemon/app and shown read-only here (managed in the desktop app).
//
// Depends on globals from app.js: `el(tag, className, text)` and `rpc()`.
(function () {
  let cfg = null;          // working copy of AppConfig (parsed)
  let devRoot = '';
  let appRunning = false;
  let dirty = false;
  let activeTab = 'general';
  let agents = [];         // [{kind, name, default}] from list-agents (local, not remote)
  let subForm = null;      // { kind: 'workspace'|'job', draft, isNew }
  let backdrop = null;
  let escHandler = null;

  const TABS = [
    ['general', 'General'],
    ['automation', 'Automation'],
    ['workspaces', 'Workspaces'],
    ['jobs', 'Jobs'],
    ['notifications', 'Notifications'],
  ];

  const EVENT_LABELS = {
    taskComplete: 'Task Complete', agentWaiting: 'Agent Waiting',
    reviewRequested: 'Review Requested', changesRequested: 'Changes Requested',
    checksFailing: 'CI Failing',
  };
  const BUILT_IN_SOUNDS = [
    'Basso', 'Blow', 'Bottle', 'Frog', 'Funk', 'Glass', 'Hero', 'Morse',
    'Ping', 'Pop', 'Purr', 'Sosumi', 'Submarine', 'Tink',
  ];
  const WEEKDAYS = [[1, 'Sun'], [2, 'Mon'], [3, 'Tue'], [4, 'Wed'], [5, 'Thu'], [6, 'Fri'], [7, 'Sat']];

  // ---- open / close -------------------------------------------------------

  async function openSettings() {
    let res;
    try { res = await rpc('get-config'); }
    catch (err) { window.alert('Could not load settings: ' + (err.message || err)); return; }
    try { cfg = JSON.parse(res.config || '{}'); } catch (_) { cfg = {}; }
    devRoot = res.dev_root || '';
    appRunning = !!res.app_running;
    // Local list of available agents for the Default-agent picker (#3 /
    // CROW-593). Best-effort — empty when the app is down/old.
    try { const ar = await rpc('list-agents'); agents = (ar && ar.agents) || []; } catch (_) { agents = []; }
    dirty = false;
    subForm = null;
    activeTab = 'general';
    render();
  }

  function closeSettings(force) {
    if (!force && dirty && !window.confirm('Discard unsaved changes?')) return;
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
      btn.textContent = 'Saved ✓';
      setTimeout(() => { if (!dirty && backdrop) render(); }, 700);
    } catch (err) {
      btn.disabled = false;
      btn.textContent = orig;
      window.alert('Save failed: ' + (err.message || err));
    }
  }

  // ---- shell --------------------------------------------------------------

  function render() {
    if (!backdrop) {
      backdrop = el('div', 'settings-backdrop');
      backdrop.onclick = (ev) => { if (ev.target === backdrop) closeSettings(); };
      escHandler = (ev) => { if (ev.key === 'Escape') closeSettings(); };
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
    if (!appRunning) {
      foot.appendChild(el('div', 'settings-appdown',
        'Desktop app unavailable for settings (not running or outdated) — changes save to config.json directly.'));
    }
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

  // An editable chip list bound to a string[] on obj[key] (#7 / CROW-593) —
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
    } else {
      body.appendChild(textField('Default agent', cfg, 'defaultAgentKind',
        { readonly: true, help: 'Only one agent is available. Install another agent CLI (Codex, Cursor, opencode) to choose.' }));
    }

    body.appendChild(group('Corveil CLI'));
    body.appendChild(textField('Path to corveil binary', cfg.defaults.binaries, 'corveil',
      { placeholder: '/path/to/corveil', help: 'Leave blank to skip. Verify/Reinstall are available in the desktop app.' }));

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

    body.appendChild(group('Credentials (desktop app)'));
    body.appendChild(readonlyNote('The Manager AI Gateway and Jira credential are managed in the desktop app and are read-only here. '
      + (cfg.managerGateway && cfg.managerGateway.baseURL ? 'Manager gateway: ' + cfg.managerGateway.baseURL + '. ' : 'No manager gateway set. ')
      + (cfg.jiraCredential && cfg.jiraCredential.username ? 'Jira user: ' + cfg.jiraCredential.username + '.' : 'No Jira credential set.')));

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

  function renderNotifications(body) {
    cfg.notifications = cfg.notifications || {};
    const n = cfg.notifications;
    body.appendChild(group('Global'));
    body.appendChild(toggleField('Mute everything', n, 'globalMute', 'Suppresses all sounds and system notifications.'));
    body.appendChild(toggleField('Enable sound', n, 'soundEnabled'));
    body.appendChild(toggleField('Enable system notifications', n, 'systemNotificationsEnabled'));

    for (const [raw, conf] of eventEntries(n.eventSettings)) {
      body.appendChild(group(EVENT_LABELS[raw] || raw));
      body.appendChild(toggleField('Enabled', conf, 'enabled'));
      body.appendChild(toggleField('Play sound', conf, 'soundEnabled'));
      body.appendChild(toggleField('System notification', conf, 'systemNotificationEnabled'));
      body.appendChild(selectField('Sound', conf, 'soundName', BUILT_IN_SOUNDS.map((s) => [s, s])));
    }
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

  // ---- Workspaces ---------------------------------------------------------

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
      const dup = el('button', 'action-btn', 'Duplicate');
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

  function listRow(title, sub, onEdit, onDelete) {
    const row = el('div', 'st-row');
    const main = el('div', 'st-row-main');
    main.appendChild(el('div', 'st-row-title', title));
    main.appendChild(el('div', 'st-row-sub', sub));
    row.appendChild(main);
    const actions = el('div', 'st-row-actions');
    const edit = el('button', 'action-btn', 'Edit');
    edit.onclick = onEdit;
    actions.appendChild(edit);
    const del = el('button', 'action-btn action-danger', 'Delete');
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
    if (!d.name || !d.name.trim()) { window.alert('Name is required.'); return; }
    if (subForm.kind === 'workspace') {
      d.cli = d.provider === 'gitlab' ? 'glab' : 'gh';
      upsertByID(cfg.workspaces, d);
    } else {
      d.prompts = (d.prompts || []).map((p) => p).filter((p) => p != null && p.trim() !== '');
      if (!d.prompts.length) { window.alert('At least one prompt is required.'); return; }
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

    if (d.gateway) {
      body.appendChild(group('Gateway (desktop app)'));
      body.appendChild(readonlyNote('AI gateway ' + (d.gateway.baseURL || '') + ' is managed in the desktop app and read-only here.'));
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
