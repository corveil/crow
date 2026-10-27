'use strict';
// Crow web UI — Scratch board (CROW-1231 / CROW-1233). Extracted from boards.js (CROW-1242).

// ===== Scratch (CROW-1231 / CROW-1233) =====
let scratchShowClosed = false;
// Survives refreshBoard so Ticket cannot re-fire while the Manager is still
// attaching the issue. Cleared once a ticket URL lands. 15m matches the daemon TTL.
const scratchTicketDispatched = new Set();
const TICKET_DISPATCH_TTL_MS = 15 * 60 * 1000;

// Agent + Workspace pickers (CROW-1387). Every item carries both, and Explore /
// Ticket launch the Manager with them. Loaded once (Refresh reloads) and seeded
// from the Manager defaults: `agentsByKind.manager ?? defaultAgentKind` and
// `defaults.managerWorkspace`. The capture selection survives re-renders.
let scratchPickers = null;
let scratchPickersLoading = null;
let scratchCaptureAgent = null;
let scratchCaptureWorkspace = null;
// Unsent capture text, so the re-render when the pickers arrive keeps it.
let scratchCaptureDraft = '';

function loadScratchPickers() {
  if (scratchPickers) return Promise.resolve(scratchPickers);
  if (scratchPickersLoading) return scratchPickersLoading;
  scratchPickersLoading = (async () => {
    try {
      const [a, w, g, d] = await Promise.all([
        rpc('list-agents'), rpc('workspace-list'), rpc('agents-get'), rpc('defaults-get'),
      ]);
      const agents = (a && a.agents) || [];
      const workspaces = (w && w.workspaces) || [];
      let defaultAgent = g && g.agents && g.agents.effective && g.agents.effective.manager;
      if (!defaultAgent) { const x = agents.find((ag) => ag.default); defaultAgent = x && x.kind; }
      const fallback = d && d.defaults && d.defaults.manager_workspace;
      const known = workspaces.find((ws) => fallback && ws.name.toLowerCase() === fallback.toLowerCase());
      scratchPickers = { agents, workspaces, defaultAgent: defaultAgent || null, defaultWorkspace: known ? known.name : null };
      if (scratchCaptureAgent === null) scratchCaptureAgent = scratchPickers.defaultAgent;
      if (scratchCaptureWorkspace === null) scratchCaptureWorkspace = scratchPickers.defaultWorkspace;
      return scratchPickers;
    } catch (_) {
      return null; // app down — the capture form falls back to the daemon's defaults
    } finally { scratchPickersLoading = null; }
  })();
  return scratchPickersLoading;
}

function scratchAgentSelect(agents, selected) {
  const sel = el('select', 'scratch-select');
  sel.setAttribute('aria-label', 'Agent');
  sel.title = 'Agent';
  for (const a of agents) {
    const enabled = a.available !== false;
    const opt = el('option', null, (a.name || a.kind) + (enabled ? '' : ' (not installed)'));
    opt.value = a.kind;
    opt.disabled = !enabled;
    if (a.kind === selected) opt.selected = true;
    sel.appendChild(opt);
  }
  return sel;
}

// `placeholder` adds a leading empty option, which a `required` select treats
// as "nothing chosen".
function scratchWorkspaceSelect(workspaces, selected, placeholder) {
  const sel = el('select', 'scratch-select');
  sel.setAttribute('aria-label', 'Workspace');
  sel.title = 'Workspace';
  if (placeholder) {
    const blank = el('option', null, placeholder);
    blank.value = '';
    sel.appendChild(blank);
  }
  for (const ws of workspaces) {
    const opt = el('option', null, ws.name);
    opt.value = ws.name;
    sel.appendChild(opt);
  }
  sel.value = selected || '';
  return sel;
}

function renderScratchBoard(root) {
  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Scratch'));
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.onclick = () => { scratchPickers = null; refreshBoard('scratch'); };
  head.appendChild(refresh);
  const toggle = el('button', 'action-btn' + (scratchShowClosed ? ' nav-selecting' : ''),
    scratchShowClosed ? 'Hide done' : 'Show done');
  toggle.onclick = () => { scratchShowClosed = !scratchShowClosed; renderBoard(); };
  head.appendChild(toggle);
  root.appendChild(head);

  const capture = el('form', 'scratch-capture');
  const input = document.createElement('input');
  input.className = 'scratch-input';
  input.placeholder = 'Capture to Scratch…';
  input.autocomplete = 'off';
  input.value = scratchCaptureDraft;
  input.oninput = () => { scratchCaptureDraft = input.value; };
  const submit = el('button', 'action-btn action-primary', 'Capture');
  submit.type = 'submit';
  capture.appendChild(input);
  // Agent + Workspace are required (CROW-1387). Until the pickers load there
  // are none, and the daemon resolves both from its defaults.
  let agentSel = null;
  let wsSel = null;
  if (scratchPickers) {
    agentSel = scratchAgentSelect(scratchPickers.agents, scratchCaptureAgent);
    agentSel.required = true;
    agentSel.onchange = () => { scratchCaptureAgent = agentSel.value; };
    wsSel = scratchWorkspaceSelect(scratchPickers.workspaces, scratchCaptureWorkspace, 'Workspace…');
    wsSel.required = true;
    wsSel.onchange = () => { scratchCaptureWorkspace = wsSel.value; };
    capture.appendChild(agentSel);
    capture.appendChild(wsSel);
  } else {
    loadScratchPickers().then((p) => { if (p && selectedBoard === 'scratch') renderBoard(); });
  }
  capture.appendChild(submit);
  capture.onsubmit = async (e) => {
    e.preventDefault();
    const text = (input.value || '').trim();
    if (!text) return;
    const params = { text: text };
    if (agentSel && agentSel.value) params.agent_kind = agentSel.value;
    if (wsSel) {
      if (!wsSel.value) { alertModal('Pick a workspace for this item.'); return; }
      params.workspace = wsSel.value;
    }
    submit.disabled = true;
    try {
      await rpc('todo-add', params);
      input.value = '';
      scratchCaptureDraft = '';
      await refreshBoard('scratch');
    } catch (err) {
      alertModal('Capture failed: ' + (err.message || err));
    } finally {
      submit.disabled = false;
      input.focus();
    }
  };
  root.appendChild(capture);

  const data = boardData.scratch;
  const todos = (data && data.todos) || [];
  const visible = todos.filter((t) => scratchShowClosed || (t.state !== 'done' && t.state !== 'dropped'));
  if (!visible.length) {
    root.appendChild(el('div', 'board-note',
      todos.length ? 'Nothing open — capture one above, or Show done.' : 'Scratch is empty. Capture one above. Explore opens a Manager to look; Ticket opens one to file.'));
    return;
  }
  const list = el('div', 'scratch-list');
  for (const item of visible) list.appendChild(scratchRow(item));
  root.appendChild(list);
}

function scratchRow(item) {
  const card = el('div', 'board-card scratch-row');
  const body = el('div', 'scratch-row-body');
  const top = el('div', 'card-title-row');
  const title = el('div', 'card-title', item.text || '(untitled)');
  title.title = 'Double-click to rename';
  title.ondblclick = (e) => {
    e.preventDefault();
    e.stopPropagation();
    startScratchTitleEdit(title, item);
  };
  top.appendChild(title);
  body.appendChild(top);
  if (item.note) body.appendChild(el('div', 'card-desc', item.note));

  const chips = el('div', 'scratch-chips');
  chips.appendChild(scratchStateChip(item.state));
  if (item.workspace) {
    const ws = el('span', 'status-pill scratch-workspace', item.workspace);
    ws.title = 'Workspace';
    chips.appendChild(ws);
  }
  if (item.agent_kind) {
    const agent = el('span', 'status-pill scratch-agent', item.agent_kind);
    agent.title = 'Agent';
    chips.appendChild(agent);
  }
  if (item.priority) chips.appendChild(el('span', 'status-pill', item.priority));
  for (const tag of (item.tags || [])) chips.appendChild(el('span', 'label-pill', tag));
  body.appendChild(chips);

  const links = item.links || [];
  if (links.length) {
    const trail = el('div', 'scratch-links');
    for (const link of links) trail.appendChild(scratchLinkBadge(link));
    body.appendChild(trail);
  }
  card.appendChild(body);

  const foot = el('div', 'card-foot');
  const actions = el('div', 'card-actions');
  const exploring = item.state === 'exploring' || item.state === 'ticketed' || item.state === 'working';
  actions.appendChild(scratchAction('Explore', (btn) => scratchLaunch(btn, item, 'todo-explore', 'Explore')));
  const ticketURL = scratchTicketURL(item);
  const filing = scratchTicketFiling(item);
  const ticket = el('button', 'action-btn', 'Ticket');
  ticket.disabled = !!ticketURL || filing;
  if (ticketURL) ticket.title = 'Already filed';
  else if (filing) ticket.title = 'Filing — waiting for the Manager to attach the issue';
  else ticket.title = 'Open a Manager to file this ticket';
  ticket.onclick = (e) => {
    e.stopPropagation();
    scratchLaunch(ticket, item, 'todo-ticket', 'Ticket');
  };
  actions.appendChild(ticket);
  const work = el('button', 'action-btn', 'Work');
  work.disabled = !ticketURL;
  work.onclick = (e) => { e.stopPropagation(); scratchSpawn(work, 'todo-work', { todo_id: item.id }, 'Work'); };
  actions.appendChild(work);
  if (item.state !== 'done') {
    actions.appendChild(scratchAction('Done', async (btn) => {
      btn.disabled = true;
      try { await rpc('todo-done', { todo_id: item.id }); await refreshBoard('scratch'); }
      catch (err) { btn.disabled = false; alertModal('Done failed: ' + (err.message || err)); }
    }));
  }
  if (exploring && scratchSessionID(item)) {
    const go = el('button', 'action-btn', 'Go to Session');
    go.onclick = () => selectSession(scratchSessionID(item));
    actions.appendChild(go);
  }
  foot.appendChild(actions);
  card.appendChild(foot);
  return card;
}

// CROW-1260: inline title edit via the existing todo-edit RPC. Escape / blank
// / unchanged text cancel; the daemon still rejects a blank `text` if one
// slips through.
function startScratchTitleEdit(titleEl, item) {
  if (titleEl.querySelector('input')) return;
  const original = item.text || '';
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'scratch-title-input';
  input.value = original;
  input.autocomplete = 'off';
  input.setAttribute('aria-label', 'Edit title');
  titleEl.textContent = '';
  titleEl.appendChild(input);
  input.focus();
  input.select();

  let done = false;
  const restore = () => { titleEl.textContent = original || '(untitled)'; };
  const finish = async (save) => {
    if (done) return;
    done = true;
    const next = (input.value || '').trim();
    if (!save || !next || next === original) {
      restore();
      return;
    }
    try {
      await rpc('todo-edit', { todo_id: item.id, text: next });
      item.text = next;
      titleEl.textContent = next;
      await refreshBoard('scratch');
    } catch (err) {
      restore();
      alertModal('Rename failed: ' + (err.message || err));
    }
  };

  input.onkeydown = (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      return finish(true);
    }
    if (e.key === 'Escape') {
      e.preventDefault();
      e.stopPropagation();
      return finish(false);
    }
  };
  input.onblur = () => finish(true);
  input.onclick = (e) => e.stopPropagation();
  input.ondblclick = (e) => e.stopPropagation();
}

function scratchAction(label, onClick) {
  const btn = el('button', 'action-btn', label);
  btn.onclick = (e) => { e.stopPropagation(); onClick(btn); };
  return btn;
}

function scratchStateChip(state) {
  const chip = el('span', 'status-pill', state || 'captured');
  const colors = {
    captured: 'var(--text-muted)',
    exploring: 'var(--blue)',
    ticketed: 'var(--orange)',
    working: 'var(--accent)',
    done: 'var(--green)',
    parked: 'var(--purple)',
    dropped: 'var(--text-muted)',
  };
  const color = colors[state] || 'var(--text-muted)';
  chip.style.color = color;
  chip.style.borderColor = color;
  return chip;
}

function scratchLinkBadge(link) {
  if (link.type === 'session' && link.session_id) {
    const btn = el('button', 'scratch-link', link.label || 'session');
    btn.title = 'Open session';
    btn.onclick = (e) => { e.stopPropagation(); selectSession(link.session_id); };
    return btn;
  }
  if (link.url && /^https?:\/\//i.test(link.url)) {
    return openLinkButton(link.label || link.type, link.url);
  }
  return el('span', 'scratch-link', link.label || link.type);
}

function scratchSessionID(item) {
  const links = item.links || [];
  for (let i = links.length - 1; i >= 0; i--) {
    if (links[i].type === 'session' && links[i].session_id) return links[i].session_id;
  }
  return null;
}

function scratchTicketURL(item) {
  const links = item.links || [];
  for (let i = links.length - 1; i >= 0; i--) {
    if (links[i].type === 'ticket' && links[i].url) return links[i].url;
  }
  return null;
}

function scratchTicketFiling(item) {
  if (scratchTicketURL(item)) {
    scratchTicketDispatched.delete(item.id);
    return false;
  }
  if (scratchTicketDispatched.has(item.id)) return true;
  const raw = item.ticket_requested_at;
  if (!raw) return false;
  const at = Date.parse(raw);
  if (Number.isNaN(at)) return true;
  return (Date.now() - at) < TICKET_DISPATCH_TTL_MS;
}

async function scratchSpawn(btn, method, params, label) {
  const ok = await spawnAction(btn, method, params, label);
  if (ok && method === 'todo-ticket' && params && params.todo_id) {
    scratchTicketDispatched.add(params.todo_id);
  }
  await refreshBoard('scratch');
}

// Explore / Ticket (CROW-1387): confirm the Agent + Workspace the Manager
// launches with, filled in from the item. A choice that differs from the item
// is sent as a one-launch override; the item itself is not changed.
async function scratchLaunch(btn, item, method, label) {
  const pickers = await loadScratchPickers();
  if (!pickers) { scratchSpawn(btn, method, { todo_id: item.id }, label); return; }
  const choice = await scratchLaunchDialog(item, pickers, label);
  if (!choice) return;
  const params = { todo_id: item.id };
  if (choice.agent && choice.agent !== item.agent_kind) params.agent_kind = choice.agent;
  if (choice.workspace && choice.workspace !== item.workspace) params.workspace = choice.workspace;
  scratchSpawn(btn, method, params, label);
}

function scratchLaunchDialog(item, pickers, label) {
  return new Promise((resolve) => {
    const backdrop = el('div', 'text-prompt-backdrop modal-dialog-backdrop');
    const card = el('div', 'text-prompt-card new-manager-card scratch-launch-card');
    card.appendChild(el('div', 'text-prompt-title', label + ' in a new Manager'));

    const agentSel = scratchAgentSelect(pickers.agents, item.agent_kind || pickers.defaultAgent);
    agentSel.className = 'text-prompt-input';
    // An item captured before workspaces were recorded launches untagged, as
    // it always did, unless a workspace is picked here.
    const wsSel = scratchWorkspaceSelect(
      pickers.workspaces, item.workspace || '', item.workspace ? null : 'None (cross-workspace)');
    wsSel.className = 'text-prompt-input';
    const field = (text, control) => {
      const row = el('label', 'new-manager-field');
      row.appendChild(el('span', 'new-manager-label', text));
      row.appendChild(control);
      return row;
    };
    card.appendChild(field('Agent', agentSel));
    card.appendChild(field('Workspace', wsSel));
    card.appendChild(el('div', 'new-manager-hint',
      'The Manager is tagged with this workspace for good. If the item already has a live Manager, the brief goes there instead.'));

    const actions = el('div', 'text-prompt-actions');
    const cancel = el('button', 'text-prompt-btn', 'Cancel');
    const ok = el('button', 'text-prompt-btn primary', label);
    actions.append(cancel, ok);
    card.appendChild(actions);
    backdrop.appendChild(card);

    let done = false;
    function finish(value) {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(value);
    }
    function submit() { finish({ agent: agentSel.value || null, workspace: wsSel.value || null }); }
    function onKey(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(null); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); submit(); }
    }
    cancel.onclick = () => finish(null);
    ok.onclick = submit;
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) finish(null); });
    // `.modal-dialog-backdrop` so a later modalDialog supersedes this one.
    backdrop.__finish = () => finish(null);
    document.querySelectorAll('.modal-dialog-backdrop')
      .forEach((b) => (b.__finish ? b.__finish(false) : b.remove()));
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    ok.focus();
  });
}
