'use strict';
// Crow web UI — Settings → Workspaces (CROW-1160).
// Workspace list, stacked sub-form, and the backfill-history dialog.
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  function renderWorkspaces(body) {
    S.cfg.defaults = S.cfg.defaults || {};
    S.cfg.workspaces = S.cfg.workspaces || [];

    body.appendChild(S.group('Defaults'));
    body.appendChild(S.selectField('Default provider', S.cfg.defaults, 'provider',
      [['github', 'GitHub'], ['gitlab', 'GitLab']]));
    body.appendChild(S.textField('Branch prefix', S.cfg.defaults, 'branchPrefix', { placeholder: 'feature/' }));

    body.appendChild(S.group('Workspaces'));
    if (!S.cfg.workspaces.length) body.appendChild(el('div', 'st-empty', 'No workspaces configured.'));
    for (const ws of S.cfg.workspaces) {
      body.appendChild(S.listRow(
        ws.name || '(unnamed)',
        (ws.provider || 'github') + (ws.host ? ' · ' + ws.host : '') + (ws.taskProvider ? ' · tasks: ' + ws.taskProvider : ''),
        () => { S.subForm = { kind: 'workspace', draft: S.deepCopy(ws), isNew: false }; S.render(); },
        () => { S.cfg.workspaces = S.cfg.workspaces.filter((x) => x.id !== ws.id); S.markDirty(); S.render(); }));
    }
    const add = el('button', 'st-add', '+ Add workspace');
    add.onclick = () => {
      S.subForm = {
        kind: 'workspace', isNew: true,
        draft: { id: S.uuid(), name: '', provider: 'github', cli: 'gh', alwaysInclude: [], autoReviewRepos: [], excludeReviewRepos: [] },
      };
      S.render();
    };
    body.appendChild(add);
  }

  // ---- Workspace sub-form -------------------------------------------------

  function renderWorkspaceForm(body) {
    const d = S.subForm.draft;
    body.appendChild(S.textField('Name', d, 'name', { placeholder: 'MyOrg' }));
    body.appendChild(S.selectField('Provider', d, 'provider',
      [['github', 'GitHub'], ['gitlab', 'GitLab']], { rerender: true }));
    if (d.provider === 'gitlab') {
      body.appendChild(S.textField('GitLab host', d, 'host', { placeholder: 'gitlab.example.com' }));
    }
    body.appendChild(S.selectField('Task provider', d, 'taskProvider', [
      ['', 'Follow code provider'], ['github', 'GitHub'], ['gitlab', 'GitLab'], ['jira', 'Jira'],
    ], { nullable: true, rerender: true, help: 'Where tickets live, independent of the code host.' }));

    if (d.taskProvider === 'jira') {
      body.appendChild(S.group('Jira'));
      body.appendChild(S.textField('Site', d, 'jiraSite', { placeholder: 'acme.atlassian.net' }));
      body.appendChild(S.textField('Project key', d, 'jiraProjectKey', { placeholder: 'PROPS' }));
      body.appendChild(S.textField('JQL', d, 'jiraJQL', { placeholder: 'assignee = currentUser() AND statusCategory != Done' }));
      d.jiraStatusMap = d.jiraStatusMap || {};
      for (const status of ['Backlog', 'Ready', 'In Progress', 'In Review', 'Done']) {
        body.appendChild(S.textField('Status: ' + status, d.jiraStatusMap, status,
          { placeholder: 'Jira status name for ' + status }));
      }
      body.appendChild(el('div', 'st-help', 'Live "Fetch from Jira" status lookup is available in the desktop app.'));
    }

    body.appendChild(S.group('Repos'));
    body.appendChild(S.listField('Always include', d, 'alwaysInclude', 'One owner/repo per line — always listed in the prompt table.'));
    body.appendChild(S.listField('Auto-review repos', d, 'autoReviewRepos', 'One per line — review requests auto-create a review session.'));
    body.appendChild(S.listField('Exclude from reviews', d, 'excludeReviewRepos', 'One per line — hidden from the review board.'));

    // Review verdict policy (CROW-963). Bound to d.reviewBlockingSeverities:
    // undefined = Crow's default (red + yellow), an array = this workspace's own
    // set. "Use default" DELETES the key rather than storing null or [] — all
    // three round-trip differently. Absent is the default; null would make the
    // whole config undecodable; [] would mean nothing blocks, which the server
    // rejects because it approves every review.
    body.appendChild(S.group('Review verdict'));
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
      S.markDirty();
      S.render();
    };
    body.appendChild(S.field('Blocking severities', policySel,
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
          S.markDirty();
        };
        row.appendChild(cb);
        row.appendChild(el('span', 'st-switch-label', label + ' — ' + meaning));
        body.appendChild(S.field(null, row));
      }
      body.appendChild(policyHint);
    }

    body.appendChild(S.group('Instructions'));
    const ta = el('textarea', 'st-textarea');
    ta.value = d.customInstructions || '';
    ta.oninput = () => { d.customInstructions = ta.value; S.markDirty(); };
    body.appendChild(S.field('Custom instructions', ta, 'Free-text appended to session prompts.'));

    body.appendChild(S.group('AI gateway'));
    if (!S.isLocal) {
      body.appendChild(S.readonlyNote((d.gateway && d.gateway.baseURL
        ? 'AI gateway: ' + d.gateway.baseURL + '. ' : 'No AI gateway set. ')
        + 'Editable only from a local browser (on the machine running crowd).'));
    } else if (S.subForm.isNew) {
      body.appendChild(S.readonlyNote('Save this workspace first, then reopen it to set an AI gateway.'));
    } else {
      // Out-of-band local-only write, matched to the workspace by id — like the
      // desktop editor, not part of Save (`preservingSecrets` restores the stored
      // gateway on set-config, so the blank header the org path leaves is never
      // written back).
      const applyManual = async (g) => {
        await S.postConfig('/config/workspace-gateway',
          Object.assign({ workspaceId: d.id }, g ? { baseURL: g.baseURL, headers: g.customHeaders } : { clear: true }));
        d.gateway = g;
        S.render();
      };
      const manual = S.gatewayEditor(d.gateway || null, applyManual);
      if (S.corveilConnected(S.cfg.corveilConnection)) {
        body.appendChild(S.orgGatewayEditor({
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
            const res = await S.postConfig('/config/workspace-gateway', { workspaceId: d.id, orgId });
            if (res && res.log_sync_enabled) {
              d.uploadSessionLogs = true;
              const ws = (S.cfg.workspaces || []).find((w) => w.id === d.id);
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
    body.appendChild(S.group('Session logs'));
    const hasGateway = !!(d.gateway && (d.gateway.baseURL
      || (d.gateway.customHeaders && Object.keys(d.gateway.customHeaders).length)));
    const slRow = el('label', 'st-switch-row');
    const slCb = el('input', 'st-switch');
    slCb.type = 'checkbox';
    slCb.checked = !!d.uploadSessionLogs;
    slCb.disabled = !hasGateway;
    if (!hasGateway) slRow.title = 'Turn on the AI Gateway for this workspace first — the upload reuses its URL and credential.';
    slCb.onchange = () => { d.uploadSessionLogs = slCb.checked; S.markDirty(); };
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

  T.workspaces = renderWorkspaces;
  T.workspaceForm = renderWorkspaceForm;
})();
