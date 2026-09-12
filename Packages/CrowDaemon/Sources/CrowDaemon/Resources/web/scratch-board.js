'use strict';
// Crow web UI — Scratch board (CROW-1231 / CROW-1233). Extracted from boards.js (CROW-1242).

// ===== Scratch (CROW-1231 / CROW-1233) =====
let scratchShowClosed = false;

function renderScratchBoard(root) {
  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Scratch'));
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.onclick = () => refreshBoard('scratch');
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
  const submit = el('button', 'action-btn action-primary', 'Capture');
  submit.type = 'submit';
  capture.appendChild(input);
  capture.appendChild(submit);
  capture.onsubmit = async (e) => {
    e.preventDefault();
    const text = (input.value || '').trim();
    if (!text) return;
    submit.disabled = true;
    try {
      await rpc('todo-add', { text: text });
      input.value = '';
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
      todos.length ? 'Nothing open — capture one above, or Show done.' : 'Scratch is empty. Capture one above; Explore opens a Manager without filing a ticket.'));
    return;
  }
  for (const item of visible) root.appendChild(scratchRow(item));
}

function scratchRow(item) {
  const card = el('div', 'issue-card scratch-row');
  const top = el('div', 'card-title-row');
  top.appendChild(el('div', 'card-title', item.text || '(untitled)'));
  card.appendChild(top);
  if (item.note) card.appendChild(el('div', 'card-desc', item.note));

  const chips = el('div', 'scratch-chips');
  chips.appendChild(scratchStateChip(item.state));
  if (item.priority) chips.appendChild(el('span', 'status-pill', item.priority));
  for (const tag of (item.tags || [])) chips.appendChild(el('span', 'label-pill', tag));
  card.appendChild(chips);

  const links = item.links || [];
  if (links.length) {
    const trail = el('div', 'scratch-links');
    for (const link of links) trail.appendChild(scratchLinkBadge(link));
    card.appendChild(trail);
  }

  const foot = el('div', 'card-foot');
  const actions = el('div', 'card-actions');
  const exploring = item.state === 'exploring' || item.state === 'ticketed' || item.state === 'working';
  actions.appendChild(scratchAction('Explore', (btn) => scratchSpawn(btn, 'todo-explore', { todo_id: item.id }, 'Explore')));
  const ticketURL = scratchTicketURL(item);
  const ticket = el('button', 'action-btn', 'Ticket');
  ticket.disabled = !!ticketURL;
  if (ticketURL) ticket.title = 'Already filed';
  ticket.onclick = (e) => { e.stopPropagation(); scratchTicket(ticket, item); };
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
    working: 'var(--gold)',
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

async function scratchTicket(btn, item) {
  let workspace;
  try {
    const listed = await rpc('workspace-list');
    const workspaces = (listed && listed.workspaces) || [];
    if (workspaces.length === 1) workspace = workspaces[0].name;
    else if (workspaces.length > 1) {
      workspace = window.prompt('Workspace to file this ticket in:');
    } else {
      alertModal('Add a workspace in Settings before filing a ticket.');
      return;
    }
  } catch (err) {
    alertModal('Could not list workspaces: ' + (err.message || err));
    return;
  }
  if (!workspace) return;
  spawnAction(btn, 'todo-ticket', { todo_id: item.id, workspace: workspace }, 'Ticket').then(() => refreshBoard('scratch'));
}

async function scratchSpawn(btn, method, params, label) {
  await spawnAction(btn, method, params, label);
  await refreshBoard('scratch');
}
