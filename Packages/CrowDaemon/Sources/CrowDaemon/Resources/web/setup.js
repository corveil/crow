'use strict';
// Crow web UI — First-run setup wizard (CROW-605). Extracted from app.js (CROW-1155).

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
