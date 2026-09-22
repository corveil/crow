'use strict';
// Crow web UI — Scratch board (CROW-1231 / CROW-1233). Extracted from boards.js (CROW-1242).

// ===== Scratch (CROW-1231 / CROW-1233) =====
let scratchShowClosed = false;
// Survives refreshBoard so Ticket cannot re-fire while the Manager is still
// attaching the issue. Cleared once a ticket URL lands. 15m matches the daemon TTL.
const scratchTicketDispatched = new Set();
const TICKET_DISPATCH_TTL_MS = 15 * 60 * 1000;

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
  actions.appendChild(scratchAction('Explore', (btn) => scratchSpawn(btn, 'todo-explore', { todo_id: item.id }, 'Explore')));
  const ticketURL = scratchTicketURL(item);
  const filing = scratchTicketFiling(item);
  const ticket = el('button', 'action-btn', 'Ticket');
  ticket.disabled = !!ticketURL || filing;
  if (ticketURL) ticket.title = 'Already filed';
  else if (filing) ticket.title = 'Filing — waiting for the Manager to attach the issue';
  else ticket.title = 'Open a Manager to file this ticket';
  ticket.onclick = (e) => {
    e.stopPropagation();
    scratchSpawn(ticket, 'todo-ticket', { todo_id: item.id }, 'Ticket');
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
