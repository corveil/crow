'use strict';
// Crow web UI — Session context menus, long-press, agent handoff, sessionAction.
// Extracted from sidebar.js (CROW-1238).

// ---------------------------------------------------------------------------
// Session right-click context menu (custom — suppresses the browser default).
// ---------------------------------------------------------------------------
// The outside-click closer, held module-level so closeContextMenu can remove it.
// Registered NOT as { once: true } on purpose: a click *inside* a menu that
// stopPropagations (a notification row, "Clear all") never reaches document, so
// a once-listener would stay armed with no menu on screen — and the next
// menu-open's own click would then bubble to it and tear the fresh menu straight
// back down. Tying the listener's lifetime to closeContextMenu instead of to
// "some outside click eventually happens" fixes that for all six menu sites
// (review, CROW-909).
let _ctxMenuCloser = null;
function closeContextMenu() {
  const m = document.querySelector('.ctx-menu');
  if (m) m.remove();
  if (_ctxMenuCloser) {
    document.removeEventListener('click', _ctxMenuCloser);
    _ctxMenuCloser = null;
  }
}
// Arm the outside-click close one tick out (so the opening click itself doesn't
// immediately close the menu). Shared by every menu opener; the deferred arm
// also means a listener still pending from a prior menu fires against an empty
// document before this one registers.
function armContextMenuClose() {
  setTimeout(() => {
    _ctxMenuCloser = closeContextMenu;
    document.addEventListener('click', _ctxMenuCloser);
  }, 0);
}

// Right-click a board card → a small menu to copy its link(s). Pass an array of
// { label, url }; entries with no url are dropped. Reuses ctx-menu styling,
// positioned at the cursor like showSessionMenu.
function showCardMenu(e, items) {
  e.preventDefault();
  closeContextMenu();
  const links = (items || []).filter((it) => it && it.url);
  if (!links.length) return;
  const menu = el('div', 'ctx-menu');
  for (const it of links) {
    const item = el('div', 'ctx-item', it.label);
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); copyToClipboard(it.url); };
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Clipboard with a legacy fallback (execCommand) for non-secure contexts where
// navigator.clipboard is unavailable.
function copyToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(() => fallbackCopy(text));
  } else {
    fallbackCopy(text);
  }
}
function fallbackCopy(text) {
  const ta = document.createElement('textarea');
  ta.value = text;
  ta.style.position = 'fixed';
  ta.style.opacity = '0';
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand('copy'); } catch (_) { /* best effort */ }
  document.body.removeChild(ta);
}

function showSessionMenu(e, s) {
  e.preventDefault();
  closeContextMenu();
  const menu = el('div', 'ctx-menu');
  for (const it of sessionMenuItems(s)) {
    if (it.sep) { menu.appendChild(el('div', 'ctx-sep')); continue; }
    const item = el('div', 'ctx-item' + (it.danger ? ' ctx-danger' : ''), it.label);
    item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); it.action(); };
    menu.appendChild(item);
  }
  if (!menu.childElementCount) return; // nothing actionable for this session
  document.body.appendChild(menu);
  const x = Math.min(e.clientX, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min(e.clientY, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Long-press → context-menu bridge for touch devices. Fires `handler(x, y)` at
// the touch point after ~500ms if the finger hasn't moved (a scroll/drag past a
// small threshold cancels it), then swallows the trailing click so the row
// isn't also selected. Desktop right-click keeps its own oncontextmenu path.
function attachLongPress(node, handler) {
  let timer = null, sx = 0, sy = 0, fired = false;
  const clear = () => { if (timer) { clearTimeout(timer); timer = null; } };
  node.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) { clear(); return; }
    fired = false;
    sx = e.touches[0].clientX;
    sy = e.touches[0].clientY;
    clear();
    timer = setTimeout(() => { fired = true; timer = null; handler(sx, sy); }, 500);
  }, { passive: true });
  node.addEventListener('touchmove', (e) => {
    if (!timer) return;
    const t = e.touches[0];
    if (Math.abs(t.clientX - sx) > 10 || Math.abs(t.clientY - sy) > 10) clear();
  }, { passive: true });
  node.addEventListener('touchend', (e) => {
    clear();
    if (fired) { e.preventDefault(); fired = false; } // swallow the emulated click
  });
  node.addEventListener('touchcancel', clear, { passive: true });
}

// The PR URL for a session, from its stored links or the live PR surface.
function prUrlForSession(s) {
  const link = (s.links || []).find((l) => l.type === 'pr');
  if (link && link.url) return link.url;
  const live = liveFor(s.id).pr_link;
  return live && live.url ? live.url : null;
}

// Menu items mirror the desktop sessionContextMenu, gated by kind/status/provider/PR.
function sessionMenuItems(s) {
  const items = [];
  const prUrl = prUrlForSession(s);
  // Copy-link items first — available for any session with an issue and/or PR.
  if (s.ticket_url) items.push({ label: 'Copy issue link', action: () => copyToClipboard(s.ticket_url) });
  if (prUrl) items.push({ label: 'Copy PR link', action: () => copyToClipboard(prUrl) });
  items.push({
    label: isGridPinned(s.id) ? 'Unpin from grid' : 'Pin to grid',
    action: () => toggleGridPin(s.id),
  });
  if (s.ticket_url || prUrl) items.push({ sep: true });
  // Org-goal tagging (#723) — any non-manager session can ladder its work up to
  // an org KPI/goal. Managers are excluded from PR/issue tracking, so no goal.
  if (s.kind !== 'manager') {
    items.push({ label: s.org_goal ? 'Edit org goal…' : 'Set org goal…', action: () => setSessionGoal(s.id, s.org_goal) });
    if (s.org_goal) items.push({ label: 'Clear org goal', action: () => clearSessionGoal(s.id) });
    items.push({ sep: true });
  }
  const hasPR = (s.links || []).some((l) => l.type === 'pr');
  if (s.kind === 'manager') {
    // Maintenance actions (restart manager / reload tmux) live in Settings → About;
    // the manager row menu stays minimal: just rename and delete.
    items.push({ label: 'Rename', action: () => renameSession(s.id, s.name) });
    items.push({ sep: true });
    items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
    return items;
  }
  if (s.kind === 'review') {
    if (hasPR) items.push({ label: 'Add label crow:merge to PR', action: () => sessionAction('add-merge-label', s.id) });
    items.push({ label: 'Switch agent…', action: () => openHandoffAgentMenu(s, null) });
    items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
    return items;
  }
  if (s.status === 'active' && s.ticket_url && s.can_set_project_status) {
    items.push({ label: 'Mark as In Review', action: () => sessionAction('mark-in-review', s.id) });
  }
  if ((s.status === 'active' || s.status === 'inReview') && s.ticket_url) {
    const closes = s.provider === 'github' || s.provider === 'gitlab';
    items.push({ label: closes ? 'Close Issue' : 'Mark Issue Done', action: () => sessionAction('mark-issue-done', s.id) });
  }
  if (s.status === 'active' || s.status === 'inReview') {
    items.push({ label: 'Mark as Completed', action: () => sessionAction('complete-session', s.id) });
  }
  if (hasPR) items.push({ label: 'Add label crow:merge to PR', action: () => sessionAction('add-merge-label', s.id) });
  items.push({ label: s.locked ? 'Unlock' : 'Lock', action: () => sessionAction('set-locked', s.id, { locked: !s.locked }) });
  // Mid-session agent switch when credits run out (CROW-627).
  items.push({ label: 'Switch agent…', action: () => openHandoffAgentMenu(s, null) });
  items.push({ sep: true });
  items.push({ label: 'Delete', danger: true, action: () => deleteSession(s.id, s.name) });
  return items;
}

async function handoffAgent(sessionId, agentKind) {
  try {
    await rpc('handoff-agent', { session_id: sessionId, agent_kind: agentKind });
    await refreshSessions();
    if (selectedId === sessionId) {
      renderHeader(sessions.find((x) => x.id === sessionId));
      await refreshTerminals();
    }
  } catch (e) {
    alertModal('Switch agent failed: ' + (e.message || e));
  }
}

// Pick a different coding agent for an existing work/job session (CROW-627).
// Reuses the list-agents menu pattern from openNewManagerMenu, including the
// #879 surface-but-disable treatment: off-PATH agents show as disabled rows
// (handing off to one only fails server-side with a raw internal error).
async function openHandoffAgentMenu(session, anchorEl) {
  let agents = [];
  try { const r = await rpc('list-agents'); agents = (r && r.agents) || []; } catch (_) { /* app down */ }
  const others = agents.filter((a) => a.kind && a.kind !== session.agent_kind);
  // Keep the honest empty-state: if no *other* agent is actually installed, say
  // so instead of listing rows that can only fail (#879). Off-PATH others don't
  // count as somewhere you can switch to.
  if (!others.some((a) => a.available !== false)) {
    alertModal('No other coding agents are available. Install Cursor, Codex, OpenCode, Grok Build, or Muse Code to switch.');
    return;
  }
  closeContextMenu();
  const menu = el('div', 'ctx-menu');
  for (const a of others) {
    const enabled = a.available !== false;
    const label = 'Hand off to ' + (a.name || a.kind) + (enabled ? '' : '   (not installed)');
    const item = el('div', 'ctx-item' + (enabled ? '' : ' disabled'), label);
    if (enabled) {
      item.onclick = (ev) => { ev.stopPropagation(); closeContextMenu(); handoffAgent(session.id, a.kind); };
    } else {
      item.title = agentUnavailableHint(a);
      // Info-only: never launch a handoff that can only fail, never close the menu.
      item.onclick = (ev) => { ev.stopPropagation(); };
    }
    menu.appendChild(item);
  }
  document.body.appendChild(menu);
  const rect = (anchorEl && anchorEl.getBoundingClientRect)
    ? anchorEl.getBoundingClientRect()
    : { left: 16, bottom: 80, top: 80 };
  const x = Math.min(rect.left || 16, window.innerWidth - menu.offsetWidth - 8);
  const y = Math.min((rect.bottom || 80) + 4, window.innerHeight - menu.offsetHeight - 8);
  menu.style.left = Math.max(4, x) + 'px';
  menu.style.top = Math.max(4, y) + 'px';
  armContextMenuClose();
}

// Fire a session RPC from the row menu. A verb can succeed and still not have
// done the whole job: the RPC returns `ok:true` plus an additive `warning`
// (e.g. the crow:merge label landed but the auto-merge watcher is off). That's
// not an error — but staying quiet about it is exactly how #888 happened, so
// surface it. Read generically rather than per-verb: any of these verbs may
// grow a warning, and a special case for one is how the next one gets missed.
// Deliberately a modal and NOT quickAction's terminal line — `term` is the
// SELECTED session's surface while this runs from any row's context menu, so a
// terminal write would land in an unrelated session's scrollback.
async function sessionAction(method, id, extra) {
  // Identity for the advisory this call may raise. A fresh object per call, so a
  // late reply can only ever retract the modal *it* put up.
  const token = {};
  let advisoryUp = false;
  try {
    const res = await rpc(method, Object.assign({ session_id: id }, extra || {}), {
      // Fires only when the response beat us back after the deadline. The
      // advisory below promised this window would update; this is that update.
      onLate: (result, error) => {
        if (!advisoryUp) return;
        advisoryUp = false;
        if (error) {
          // We said "still running"; the daemon has now said it failed. The
          // truth changed — replace the advisory rather than stacking on it.
          dismissModalDialog(token);
          alertModal(method + ' failed: ' + (error.message || error));
          return;
        }
        const dismissed = dismissModalDialog(token);
        // An additive `warning` is information the user still needs even if they
        // already closed the advisory (that omission is #888), so it is shown
        // either way. A clean late success just takes the advisory down.
        const warning = result && typeof result.warning === 'string' ? result.warning : '';
        if (warning) alertModal(warning);
        else if (!dismissed) { /* user moved on and it worked — stay quiet */ }
      },
    });
    if (res && typeof res.warning === 'string' && res.warning) alertModal(res.warning);
  } catch (e) {
    if (e && e.rpcTimeout) {
      // NOT "failed": we stopped waiting, the daemon did not stop working.
      // Saying otherwise invites the user to retry an action that is already in
      // flight — which for `add-merge-label` or `complete-session` is a
      // duplicate write, and for all of them is a lie (#931).
      advisoryUp = true;
      alertModal(
        method + ' is taking longer than expected. It is still running on the daemon — '
        + 'this message will update when it finishes.',
        { title: 'Still running', token });
    } else {
      alertModal(method + ' failed: ' + (e.message || e));
    }
  }
}

// "In Review" with an in-flight spinner — mirrors native's ProgressView swap
// while `isMarkingInReview` (CROW-749). On success the status transition pushes
// a re-render that drops the button (status leaves `active`); on error we
// restore the button and surface the failure.
async function markInReviewAction(btn, id) {
  if (!btn || btn.disabled) return;
  btn.disabled = true;
  const saved = btn.innerHTML;
  btn.innerHTML = '';
  btn.appendChild(el('span', 'action-spinner'));
  try {
    const res = await rpc('mark-in-review', { session_id: id });
    // The session moved but the board didn't — e.g. GitLab, or a board with no
    // column mapping to In Review (#876). Not an error, but the button's name
    // promises a board move, so say so rather than looking like a clean success.
    if (res && typeof res.warning === 'string' && res.warning) alertModal(res.warning);
    // Leave the button disabled: the ensuing state push re-renders the header.
  } catch (e) {
    btn.disabled = false;
    btn.innerHTML = saved;
    alertModal('mark-in-review failed: ' + (e.message || e));
  }
}
