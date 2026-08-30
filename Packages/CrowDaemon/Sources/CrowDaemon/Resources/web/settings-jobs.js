'use strict';
// Crow web UI — Settings → Jobs (CROW-1160).
// Job list, stacked sub-form, and schedule editors.
(function () {
  const T = window.CrowSettingsTabs = window.CrowSettingsTabs || {};
  const S = new Proxy({}, {
    get(_, k) { return window.CrowSettings[k]; },
    set(_, k, v) { window.CrowSettings[k] = v; return true; },
  });

  const WEEKDAYS = [[1, 'Sun'], [2, 'Mon'], [3, 'Tue'], [4, 'Wed'], [5, 'Thu'], [6, 'Fri'], [7, 'Sat']];

  // ---- Jobs ---------------------------------------------------------------

  function renderJobs(body) {
    S.cfg.jobs = S.cfg.jobs || [];
    body.appendChild(S.group('Auto-permission mode'));
    body.appendChild(S.toggleField('Run scheduled jobs in auto permission mode', S.cfg, 'jobsAutoPermissionMode',
      'Passes --permission-mode auto so jobs can run crow/gh/git without per-call approval. Takes effect on next run.'));

    body.appendChild(S.group('Jobs'));
    if (!S.cfg.jobs.length) body.appendChild(el('div', 'st-empty', 'No jobs configured.'));
    for (const job of S.cfg.jobs) {
      const row = S.listRow(
        job.name || '(unnamed)',
        jobScope(job) + ' · ' + scheduleSummary(job.schedule) + (job.enabled ? '' : ' · disabled'),
        () => { S.subForm = { kind: 'job', draft: S.deepCopy(job), isNew: false }; S.render(); },
        () => { S.cfg.jobs = S.cfg.jobs.filter((x) => x.id !== job.id); S.markDirty(); S.render(); });
      const dup = S.iconBtn('copy', 'Duplicate');
      dup.onclick = () => {
        const copy = S.deepCopy(job);
        copy.id = S.uuid();
        copy.name = (job.name || 'job') + ' copy';
        copy.enabled = false;
        delete copy.lastRunAt;
        S.cfg.jobs.push(copy);
        S.markDirty();
        S.render();
      };
      row.querySelector('.st-row-actions').insertBefore(dup, row.querySelector('.st-row-actions').firstChild);
      // Run this job on demand (mirrors the desktop's play button). Acts on the
      // persisted job, so nudge the user to save pending edits first (CROW-593).
      const run = S.iconBtn('play', 'Run now');
      run.onclick = async () => {
        if (S.dirty) { S.setRowIcon(run, 'cross'); run.title = 'Save changes first'; setTimeout(() => { S.setRowIcon(run, 'play'); run.title = 'Run now'; }, 1200); return; }
        run.disabled = true; run.title = 'Running…'; S.setRowIcon(run, 'dots');
        try { await rpc('run-job', { job_id: job.id }); run.title = 'Started'; S.setRowIcon(run, 'check'); }
        catch (e) { run.title = 'Failed'; S.setRowIcon(run, 'cross'); }
        setTimeout(() => { run.disabled = false; run.title = 'Run now'; S.setRowIcon(run, 'play'); }, 1500);
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
        S.markDirty();
        S.render();
      };
      row.querySelector('.st-row-actions').insertBefore(enable, row.querySelector('.st-row-actions').firstChild);
      body.appendChild(row);
    }
    const add = el('button', 'st-add', '+ Add job');
    add.onclick = () => {
      S.subForm = {
        kind: 'job', isNew: true,
        draft: { id: S.uuid(), name: '', workspace: '', repo: '', prompts: [''], schedule: { type: 'interval', seconds: 86400 }, enabled: true },
      };
      S.render();
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

  // ---- Job sub-form -------------------------------------------------------

  function renderJobForm(body) {
    const d = S.subForm.draft;
    S.cfg.workspaces = S.cfg.workspaces || [];
    body.appendChild(S.textField('Name', d, 'name', { placeholder: 'Nightly triage' }));
    const wsOptions = [['', '(choose workspace)']].concat(S.cfg.workspaces.map((w) => [w.name, w.name]));
    body.appendChild(S.selectField('Workspace', d, 'workspace', wsOptions));
    body.appendChild(S.textField('Repo', d, 'repo', { placeholder: 'owner/repo' }));

    body.appendChild(S.group('Prompts'));
    d.prompts = d.prompts && d.prompts.length ? d.prompts : [''];
    d.prompts.forEach((_, i) => {
      const row = el('div', 'st-field');
      const ta = el('textarea', 'st-textarea');
      ta.value = d.prompts[i];
      ta.oninput = () => { d.prompts[i] = ta.value; S.markDirty(); };
      row.appendChild(ta);
      if (d.prompts.length > 1) {
        const rm = el('button', 'action-btn action-danger', 'Remove prompt');
        rm.onclick = () => { d.prompts.splice(i, 1); S.markDirty(); S.render(); };
        row.appendChild(rm);
      }
      body.appendChild(row);
    });
    const addPrompt = el('button', 'st-add', '+ Add prompt');
    addPrompt.onclick = () => { d.prompts.push(''); S.markDirty(); S.render(); };
    body.appendChild(addPrompt);

    body.appendChild(S.group('Schedule'));
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
      S.markDirty();
      S.render();
    };
    body.appendChild(S.field('Type', typeSel));
    if (d.schedule.type === 'interval') renderIntervalEditor(body, d.schedule);
    else renderDailyEditor(body, d.schedule);

    body.appendChild(S.group('Status'));
    body.appendChild(S.toggleField('Enabled', d, 'enabled'));
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
      S.markDirty();
    };
    body.appendChild(S.textField('Every', state, 'value', { number: true, type: 'number' }));
    // rebind value onchange to recompute (textField mutates state.value already)
    body.lastChild.querySelector('input').oninput = function () {
      state.value = S.parseIntOr(this.value, state.value); recompute();
    };
    body.appendChild(S.selectField('Unit', state, 'unit',
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
    body.appendChild(S.textField('Hour (0–23)', sched, 'hour', { number: true, type: 'number' }));
    body.appendChild(S.textField('Minute (0–59)', sched, 'minute', { number: true, type: 'number' }));
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
        S.markDirty();
      };
      row.appendChild(cb);
      row.appendChild(el('span', 'st-switch-label', label));
      f.appendChild(row);
    }
    body.appendChild(f);
  }

  T.jobs = renderJobs;
  T.jobForm = renderJobForm;
})();
