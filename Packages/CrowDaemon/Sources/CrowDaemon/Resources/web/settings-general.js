'use strict';
// Crow web UI — Settings → General (CROW-1160).
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  // ---- General ------------------------------------------------------------

  function renderGeneral(body) {
    S.cfg.defaults = S.cfg.defaults || {};
    S.cfg.defaults.binaries = S.cfg.defaults.binaries || {};
    S.cfg.sidebar = S.cfg.sidebar || {};
    S.cfg.telemetry = S.cfg.telemetry || {};
    S.cfg.cleanup = S.cfg.cleanup || {};
    S.cfg.terminal = S.cfg.terminal || {};

    body.appendChild(S.group('Development Root'));
    body.appendChild(S.textField('Path', { path: S.devRoot }, 'path',
      { readonly: true, help: 'The dev root is fixed for this daemon and managed in the desktop app.' }));

    renderAutostart(body);

    body.appendChild(S.group('Agent'));
    if (S.agents.length) {
      // Choose the default agent, like the desktop Settings picker. All known
      // agents are listed; off-PATH ones are disabled (a persisted default that
      // isn't launchable is exactly what the launch gate exists to prevent).
      body.appendChild(S.defaultAgentField('Default agent',
        'Used for new sessions unless overridden. Uninstalled agents are shown disabled — install the CLI and restart Crow to enable.'));
      // Per-action overrides (coding / reviews / scheduled jobs / Manager),
      // matching the desktop's four pickers. "Use default" clears the override.
      body.appendChild(S.agentOverrideField('Agent for coding', 'work'));
      body.appendChild(S.agentOverrideField('Agent for reviews', 'review'));
      body.appendChild(S.agentOverrideField('Agent for scheduled jobs', 'job'));
      body.appendChild(S.agentOverrideField('Agent for Manager', 'manager'));
    } else {
      // list-agents returned nothing — the daemon is unreachable, not a
      // one-agent install. Show the stored value read-only rather than an empty
      // dropdown.
      body.appendChild(S.textField('Default agent', S.cfg, 'defaultAgentKind',
        { readonly: true, help: 'Agent list unavailable — is crowd running?' }));
    }

    body.appendChild(S.group('Corveil CLI'));
    // The corveil binary is an absolute local path executed at agent launch, so
    // it stays local-only (CROW-593/665) — editable only from a local browser and
    // read-only when proxied/remote, mirroring the web password & AI gateways.
    // (Scheduled jobs, by contrast, are editable from any authenticated session.)
    // The local editor carries Verify / Reinstall skill with it (CROW-1011);
    // both run the binary on the daemon host, so a remote session gets neither.
    body.appendChild(S.isLocal
      ? corveilField()
      : S.textField('Path to corveil binary', S.cfg.defaults.binaries, 'corveil',
        { readonly: true, help: 'The corveil binary path is editable only from a local browser (on the machine running crowd).' }));

    body.appendChild(S.group('Sidebar'));
    body.appendChild(S.toggleField('Hide session details', S.cfg.sidebar, 'hideSessionDetails',
      'Hides ticket title and repo/branch lines in sidebar rows.'));

    body.appendChild(S.group('Terminal Scroll'));
    body.appendChild(S.selectField('Wheel speed — plain shell', S.cfg.terminal, 'wheelScrollLines', [
      [1, '1 line / notch'], [2, '2 lines / notch'], [3, '3 lines / notch (default)'], [5, '5 lines / notch'], [8, '8 lines / notch'],
    ], { number: true, help: 'Local scrollback lines scrolled per wheel notch on shell/review surfaces.' }));
    body.appendChild(S.selectField('Wheel speed — agent surfaces', S.cfg.terminal, 'agentWheelNotches', [
      [1, '1 notch / notch (default)'], [2, '2 notches / notch'], [3, '3 notches / notch'],
    ], { number: true, help: 'Wheel reports forwarded to Claude Code / Cursor per physical notch. Raise if agent scrolling feels too slow.' }));

    body.appendChild(S.group('Telemetry'));
    body.appendChild(S.toggleField('Enable session analytics', S.cfg.telemetry, 'enabled',
      'Collects cost/token/tool metrics via OpenTelemetry. Requires app restart.'));
    body.appendChild(S.textField('OTLP receiver port', S.cfg.telemetry, 'port', { number: true, type: 'number' }));
    body.appendChild(S.selectField('Retention', S.cfg.telemetry, 'retentionDays', [
      [30, '30 days'], [90, '90 days'], [180, '6 months'], [365, '1 year'], [0, 'Forever'],
    ], { number: true }));

    body.appendChild(S.group('Session Cleanup'));
    body.appendChild(S.toggleField('Auto-delete completed sessions', S.cfg.cleanup, 'enabled',
      'Deletes completed/archived sessions after the retention period (incl. worktree + branch). Manager, virtual, and locked sessions are never deleted.'));
    body.appendChild(S.selectField('Retention', S.cfg.cleanup, 'retentionHours', [
      [1, '1 hour'], [4, '4 hours'], [8, '8 hours'], [24, '1 day'], [72, '3 days'], [168, '7 days'], [720, '30 days'],
    ], { number: true }));

    // Session-log upload tuning (CROW-1070). Global collector behavior only —
    // per-workspace opt-in (and the reused Corveil gateway) live on each workspace
    // under Settings → Workspaces. No credential here.
    S.cfg.logSync = S.cfg.logSync || {};
    body.appendChild(S.group('Session logs'));
    body.appendChild(el('div', 'st-help',
      'Timing and size limits for the session-transcript upload. Opt a workspace in — and configure its AI gateway — under Settings → Workspaces.'));
    body.appendChild(S.selectField('Quiet period', S.cfg.logSync, 'quietPeriodMinutes', [
      [5, '5 minutes'], [15, '15 minutes'], [30, '30 minutes (default)'], [60, '1 hour'], [120, '2 hours'],
    ], { number: true, help: 'Wait this long after a session’s last activity before capturing its transcript (a session is uploaded once, when quiescent).' }));
    body.appendChild(S.selectField('Ledger retention', S.cfg.logSync, 'retentionDays', [
      [30, '30 days (default)'], [90, '90 days'], [180, '6 months'], [365, '1 year'], [0, 'Forever'],
    ], { number: true, help: 'How long the local upload ledger keeps a record of each session before pruning.' }));
    body.appendChild(S.textField('Max upload size (bytes)', S.cfg.logSync, 'maxUploadBytes',
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
    input.value = S.cfg.defaults.binaries.corveil || '';
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
      S.cfg.defaults.binaries.corveil = input.value;
      S.markDirty();
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
        const result = await S.postConfig('/config/corveil', { action, path: input.value.trim() });
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
    body.appendChild(S.group('Autostart'));
    if (!S.autostart) {
      body.appendChild(S.readonlyNote('Could not read the autostart status from crowd.'));
      return;
    }
    if (!S.autostart.supported || !S.isLocal) {
      body.appendChild(S.readonlyNote(S.autostart.supported
        ? S.autostart.message + ' Autostart is changed only from a local browser (on the machine running crowd).'
        : S.autostart.message));
      return;
    }

    const row = el('label', 'st-switch-row');
    const input = el('input', 'st-switch');
    input.type = 'checkbox';
    input.checked = !!S.autostart.enabled;
    input.onchange = async () => {
      input.disabled = true;
      try {
        S.autostart = await S.postConfig('/autostart', { enabled: input.checked });
      } catch (err) {
        alertModal('Could not change autostart: ' + (err.message || err));
        input.checked = !input.checked;
      }
      input.disabled = false;
      S.render();
    };
    row.appendChild(input);
    row.appendChild(el('span', 'st-switch-label', 'Start Crow at login'));
    const f = el('div', 'st-field');
    f.appendChild(row);
    f.appendChild(el('div', 'st-help', S.autostart.message));
    body.appendChild(f);

    // A plist left pointing at a crowd that has since moved — one click re-points it.
    if (S.autostart.stale) {
      const fix = el('button', 'action-primary', 'Re-point to this crowd');
      fix.onclick = async () => {
        fix.disabled = true;
        try { S.autostart = await S.postConfig('/autostart', { enabled: true }); }
        catch (err) { alertModal('Could not re-point autostart: ' + (err.message || err)); }
        S.render();
      };
      body.appendChild(S.field(null, fix));
    }
  }

  T.general = renderGeneral;
})();
