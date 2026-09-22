'use strict';
// Crow web UI — Session detail header: status chips, org-goal, PR/quick-actions.
// Extracted from session.js (CROW-1257).

function renderHeader(s) {
  const root = document.getElementById('detail-header');
  root.innerHTML = '';
  if (!s) return;

  const top = el('div', 'detail-top');
  if (sessionCameFromGrid) {
    const back = el('button', 'back-to-grid', '‹ Grid');
    back.type = 'button';
    // Don't teach Esc when the switcher's esc+tab prefix owns that key.
    back.title = switcherOwnsEscapePrefix() ? 'Back to grid' : 'Back to grid (Esc)';
    back.setAttribute('aria-label', 'Back to grid');
    back.onclick = () => returnToGridFromSession();
    top.appendChild(back);
  }
  const nameEl = el('div', 'detail-name', s.name);
  nameEl.title = 'Double-click to rename';
  nameEl.ondblclick = () => renameSession(s.id, s.name);
  top.appendChild(nameEl);
  if (liveFor(s.id).remote_control_active) top.appendChild(rcGlyph());
  const badge = el('span', 'status-badge', s.status);
  badge.style.color = STATUS_COLOR[s.status] || 'var(--text-muted)';
  top.appendChild(badge);
  if (s.is_explore) top.appendChild(el('span', 'explore-badge', 'Exploring'));
  root.appendChild(top);

  if (s.ticket_title) root.appendChild(el('div', 'subtle', s.ticket_title));
  // Org-goal tag (#723) — click to edit/clear. Only rendered when tagged; the
  // menu's "Set org goal…" is the entry point for untagged sessions.
  if (s.org_goal) {
    const goalRow = el('div', 'meta meta-goal');
    goalRow.appendChild(el('span', 'goal-badge', '🎯 ' + s.org_goal));
    goalRow.title = 'Org goal — click to edit';
    goalRow.style.cursor = 'pointer';
    goalRow.onclick = (ev) => { ev.stopPropagation(); setSessionGoal(s.id, s.org_goal); };
    root.appendChild(goalRow);
  }
  // Review sessions: surface the PR author. Prefer the live review request
  // (Reviews board), but fall back to the author persisted on the session at
  // review-creation so it still shows when the board is empty (CROW-593).
  const rev = reviewForSession(s.id);
  const reviewAuthor = (rev && rev.author) || s.review_author;
  if (reviewAuthor) root.appendChild(el('div', 'subtle', 'PR by @' + reviewAuthor));
  // Repo · branch on the left, worktree path pushed to the right (like the desktop).
  if (s.repo || s.branch || s.worktree_path) {
    const metaRow = el('div', 'meta meta-row');
    const left = [];
    if (s.repo) left.push(s.repo);
    if (s.branch) left.push(s.branch);
    if (left.length) metaRow.appendChild(el('span', null, left.join(' · ')));
    if (s.worktree_path) metaRow.appendChild(el('span', 'meta-path', shorten(s.worktree_path)));
    root.appendChild(metaRow);
  }
  root.appendChild(el('div', 'meta', 'Agent: ' + (s.agent_display_name || s.agent_kind || '—')));
  // Clickable agent row for non-manager sessions with a worktree (CROW-627).
  if (s.kind !== 'manager' && s.worktree_path) {
    const agentMeta = root.lastChild;
    agentMeta.classList.add('meta-agent');
    agentMeta.title = 'Switch coding agent (handoff)';
    agentMeta.style.cursor = 'pointer';
    agentMeta.onclick = (ev) => { ev.stopPropagation(); openHandoffAgentMenu(s, agentMeta); };
  }

  // Per-session analytics strip (CROW-722): cost / tokens / tools / active time,
  // mirroring the desktop SessionAnalyticsStrip. Sits between the session context
  // rows and the links/actions row.
  renderSessionAnalyticsStrip(s, root);

  // Links + actions on ONE row (issue/PR/repo chips + inline PR status on the
  // left, action buttons trailing) — matching the desktop detail header.
  const links = (s.links || []).slice();
  if (s.ticket_url && !links.some((l) => l.type === 'ticket')) {
    links.unshift({ label: s.ticket_badge || 'Issue', url: s.ticket_url, type: 'ticket' });
  }
  // Add the app's live PR link when it isn't in the stored links (e.g. derived
  // from the linked issue, not persisted).
  const livePr = liveFor(s.id).pr_link;
  if (livePr && !links.some((l) => l.type === 'pr')) {
    links.push({ label: livePr.label, url: livePr.url, type: 'pr' });
  }
  const pr = liveFor(s.id).pr;

  const headerRow = el('div', 'header-row');
  for (const link of links) {
    // Only render http(s) chips — a prompt-injected link (javascript:/data:)
    // must never become a clickable href (review).
    if (!/^https?:\/\//i.test(link.url || '')) continue;
    const chip = document.createElement('a');
    chip.className = 'link-chip link-' + (link.type || 'custom');
    chip.href = link.url;
    chip.target = '_blank';
    chip.rel = 'noopener';
    chip.textContent = (link.type === 'ticket' && s.ticket_badge) || link.label || link.type || 'link';
    headerRow.appendChild(chip);
  }
  if (pr && pr.has_pr) {
    headerRow.appendChild(prStatusInline(pr, liveFor(s.id).auto_merge_state, s.auto_merge,
                                         liveFor(s.id).auto_rebase_state));
  }

  // Right-aligned action cluster: terminal reload, PR quick-actions, then status
  // transitions + delete.
  const actions = el('div', 'actions-cluster');
  // Terminal reload (CROW-979). `reloadTerminal()` was reachable only from the
  // terminal's right-click menu, which a touch device has no way to open — so on a
  // phone the cheap recovery for a corrupted surface didn't exist and the only way
  // out was leaving the session and coming back. Deliberately OUTSIDE the
  // `kind !== 'manager'` guard below: that guard is why a Manager session shows no
  // buttons at all, and the Manager window is the common CROW-804 stuck-surface
  // case (it has no tabs to hang a control off either, #680).
  const reloadBusy = terminalReloadPending;
  const reload = el('button', 'action-btn action-btn-reload', '');
  // Swap the ↻ glyph for the shared spinner ring rather than spinning the button,
  // so the chrome stays put while it turns (the CROW-797 tickets-refresh fix).
  reload.appendChild(reloadBusy ? el('span', 'action-spinner') : el('span', 'reload-glyph', '↻'));
  reload.appendChild(el('span', null, 'Reload'));
  reload.disabled = reloadBusy || !activeTerminal;
  reload.title = reloadBusy
    ? 'Reloading terminal…'
    : (activeTerminal
        ? 'Reload the terminal — reset the view and reconnect'
        : 'No terminal attached');
  reload.onclick = () => reloadTerminalAction();
  actions.appendChild(reload);
  // Explore opens a Manager and links the Scratch item to it (CROW-1288).
  // Managers otherwise have no status actions (`kind !== 'manager'` below),
  // so this is the control that finishes the item from the session itself.
  // Work sessions linked by `todo work` are out of scope — they already have
  // their own completion buttons.
  const scratch = s.kind === 'manager' ? s.linked_scratch : null;
  if (scratch && scratch.id && scratch.state !== 'done') {
    const text = (scratch.text || '').trim();
    const mark = actionBtn('Mark Scratch Done', 'check', null,
      (ev) => markScratchDoneAction(ev.currentTarget, s));
    mark.title = text
      ? ('Mark this Scratch item done: ' + text)
      : 'Mark the linked Scratch item done';
    actions.appendChild(mark);
  }
  if (pr && pr.has_pr && !pr.is_merged) {
    // Quick-actions dispatch a prompt into the session's managed Claude Code
    // terminal — disable them when there is none (native `canDispatchQuickAction`;
    // CROW-749). `can_dispatch` is absent until the daemon ships it, so treat only
    // an explicit `false` as "no terminal".
    const canDispatch = liveFor(s.id).can_dispatch !== false;
    const qaOpts = { disabled: !canDispatch, title: canDispatch ? '' : 'No managed Claude Code terminal in this session' };
    if (pr.merge === 'conflicting') actions.appendChild(qaButton('Rebase & Fix Conflicts', 'fixConflicts', s.id, 'danger', 'merge', qaOpts));
    if (pr.review === 'changesRequested') {
      // Per-kind split (CROW-757): a reviewer must never modify the branch
      // under review, so review sessions get "Re-review" (re-run the review on
      // the author's latest head; never edits code) instead of "Address Review"
      // (author fixes code + pushes). The daemon also refuses the code-changing
      // actions on review sessions server-side (`dispatchManual` guard).
      if (s.kind === 'review') {
        actions.appendChild(qaButton('Re-review', 'reReview', s.id, 'primary', 'eye', qaOpts));
      } else {
        actions.appendChild(qaButton('Address Review', 'addressChanges', s.id, 'danger', 'pencil', qaOpts));
      }
    }
    if (pr.checks === 'failing') actions.appendChild(qaButton('Fix Checks', 'fixChecks', s.id, 'danger', 'warning', qaOpts));
    if (pr.ready_to_merge) actions.appendChild(qaButton('Merge PR', 'mergePR', s.id, 'primary', 'merge', qaOpts));
  }
  if (s.kind !== 'manager') {
    // Open the primary worktree on the host (native "Open in VS Code" / "Open
    // Terminal"; CROW-749). These launch apps on the daemon host, so they're
    // loopback-gated server-side and only shown to a local-direct session. VS
    // Code additionally needs the `code` CLI installed; both need a worktree.
    if (uiConfig.isLocal && s.worktree_path && uiConfig.vsCodeAvailable) {
      actions.appendChild(actionBtn('Open in VS Code', 'code', null, () => sessionAction('open-in-vscode', s.id)));
    }
    if (uiConfig.isLocal && s.worktree_path) {
      actions.appendChild(actionBtn('Open Terminal', 'terminal', null, () => sessionAction('open-terminal', s.id)));
    }
    // In Review — active + linked ticket + a project-board-capable provider
    // (native `canSetProjectStatus`). In-flight: swap to a spinner until the
    // status transition lands and the re-render drops the button (CROW-749).
    if (s.status === 'active' && s.ticket_url && s.can_set_project_status) {
      actions.appendChild(actionBtn('In Review', 'eye', null, (ev) => markInReviewAction(ev.currentTarget, s.id)));
    }
    if (s.status === 'active' || s.status === 'inReview') {
      actions.appendChild(actionBtn('Mark as Completed', 'check', null, () => sessionAction('complete-session', s.id)));
    }
    if (s.status === 'completed') {
      actions.appendChild(actionBtn('Move to Active', 'uturn', null, () => sessionAction('set-session-active', s.id)));
    }
    actions.appendChild(actionBtn('Delete', 'trash', 'danger', () => deleteSession(s.id, s.name)));
  }
  if (actions.children.length) headerRow.appendChild(actions);
  if (headerRow.children.length) root.appendChild(headerRow);
}

// Per-session analytics strip (CROW-722) — cost / tokens / tools / active time,
// mirroring the desktop SessionAnalyticsStrip. Chips-only: appends nothing when
// there's no analytics (telemetry off, or nothing recorded yet) or for the
// Manager session, so absence is the empty state. Source (live hook aggregate vs.
// end-of-session snapshot) is resolved server-side in list-sessions-live.
function renderSessionAnalyticsStrip(s, root) {
  if (s.kind === 'manager') return;
  const a = liveFor(s.id).analytics;
  if (!a) return;
  const strip = el('div', 'analytics-strip');
  strip.appendChild(statChipEl('Cost', fmtCost(a.totalCost)));
  strip.appendChild(statChipEl('Tokens', fmtCount(a.totalTokens)));
  strip.appendChild(statChipEl('Tools', String(a.toolCallCount)));
  strip.appendChild(statChipEl('Active', fmtTime(a.activeTimeSeconds)));
  if (a.wallClockDurationSeconds != null) {
    strip.appendChild(statChipEl('Duration', fmtTime(a.wallClockDurationSeconds)));
  }
  if (a.linesAdded || a.linesRemoved) {
    strip.appendChild(statChipEl('Lines', '+' + a.linesAdded + ' −' + a.linesRemoved));
  }
  if (a.apiErrorCount > 0) {
    const chip = statChipEl('Errors', String(a.apiErrorCount));
    chip.classList.add('chip-error');
    strip.appendChild(chip);
  }
  root.appendChild(strip);
}

// Inline PR status, mirroring the desktop PRStatusDetail. Same glyph/color
// vocabulary as the sidebar row pill (`prBadgeParts`) — spelled out with labels
// here, glyph-only there (CROW-773).
function prStatusInline(pr, am, autoMergeEnabled, ar) {
  const wrap = el('div', 'pr-status-inline');
  if (pr.is_merged) {
    wrap.appendChild(prStatusPart(PR_MERGED_GLYPH));
    return wrap;
  }
  for (const part of [prChecksGlyph(pr), prReviewGlyph(pr)]) {
    wrap.appendChild(prStatusPart(part));
  }
  if (pr.merge === 'conflicting') {
    wrap.appendChild(prStatusPart(PR_CONFLICT_GLYPH));
  }
  if (pr.has_merge_label) {
    wrap.appendChild(prStatusPart(PR_MERGE_LABEL_GLYPH));
  }
  // Rebase before merge — same ordering rationale as `prBadgeParts`.
  const rebase = prAutoRebaseGlyph(ar);
  if (rebase) wrap.appendChild(prStatusPart(rebase));
  const auto = prAutoMergeGlyph(am, autoMergeEnabled);
  if (auto) wrap.appendChild(prStatusPart(auto));
  return wrap;
}

// One status chip: a monochrome SVG glyph (or geometric char) + its label, both
// tinted `part.color` — the SVG inherits it via currentColor so the checkmark
// matches the text instead of rendering as a black emoji (CROW-802).
function prStatusPart(part) {
  const chip = el('span', 'pr-stat');
  chip.style.color = part.color;
  // The daemon's full sentence, when there is one — the chip label is a
  // two-word summary and the reason is the actionable half (#888).
  if (part.detail) chip.title = part.detail;
  chip.appendChild(part.icon ? icon(part.icon, 12) : el('span', 'pr-stat-glyph', part.glyph));
  chip.appendChild(el('span', 'pr-stat-label', part.label));
  return chip;
}

function qaButton(label, action, id, variant, iconName, opts) {
  const btn = el('button', 'action-btn' + (variant ? ' action-' + variant : ''), '');
  if (iconName) btn.appendChild(icon(iconName));
  btn.appendChild(el('span', null, label));
  btn.onclick = () => quickAction(id, action, label);
  // Disabled state (no managed Claude Code terminal to dispatch into) mirrors
  // native's `canDispatchQuickAction` gate; `.action-btn:disabled` styles it.
  if (opts && opts.disabled) btn.disabled = true;
  if (opts && opts.title) btn.title = opts.title;
  return btn;
}

// Finish the Scratch item this Manager was opened from (CROW-1288).
// `todo-done` is idempotent. The header drops the button as soon as the call
// lands; `refreshSessions` confirms it from `linked_scratch`, and the Scratch
// board refresh updates the sidebar count. A failed call restores the button.
async function markScratchDoneAction(btn, session) {
  const scratch = session && session.linked_scratch;
  if (!btn || btn.disabled || !scratch || !scratch.id) return;
  btn.disabled = true;
  const saved = btn.innerHTML;
  btn.innerHTML = '';
  btn.appendChild(el('span', 'action-spinner'));
  try {
    await rpc('todo-done', { todo_id: scratch.id });
  } catch (e) {
    btn.disabled = false;
    btn.innerHTML = saved;
    alertModal('Mark Scratch Done failed: ' + (e.message || e));
    return;
  }
  session.linked_scratch = null;
  if (selectedId === session.id) renderHeader(session);
  refreshBoard('scratch');
  refreshSessions();
}

// A detail-header action button with a leading icon + click handler.
function actionBtn(label, iconName, variant, onclick) {
  const btn = el('button', 'action-btn' + (variant ? ' action-' + variant : ''), '');
  if (iconName) btn.appendChild(icon(iconName));
  btn.appendChild(el('span', null, label));
  btn.onclick = onclick;
  return btn;
}

// Dispatch a PR quick-action (forwarded to the app's agent terminal). Echo
// "dispatched" ONLY when the prompt actually reached the agent: the daemon
// returns `dispatched:false` + a reason when it silently skips (no managed
// terminal / surface not ready / no PR link), so show that instead of a false
// success. Genuine RPC failures (app/tmux down, bad action) hit the catch (#730).
async function quickAction(id, action, label) {
  try {
    const res = await rpc('quick-action', { session_id: id, action });
    if (res && res.dispatched === false) {
      const reason = res.reason || 'no active agent terminal for this session';
      if (term) term.write('\r\n\x1b[33m[crow] ' + label + " couldn't run — " + reason + '\x1b[0m\r\n');
      return;
    }
    if (term) term.write('\r\n\x1b[33m[crow] dispatched: ' + label + '\x1b[0m\r\n');
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] ' + label + ' failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}
