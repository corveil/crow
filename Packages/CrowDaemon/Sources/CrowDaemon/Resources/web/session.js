'use strict';
// Crow web UI — Session detail: artifacts, header, tabs, actions, modals. Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// Artifacts — per-session generated images (diagrams/screenshots) the agent
// dropped in the scratch dir. crowd lists them; the browser GETs each from the
// sandboxed /artifacts route. A compact strip under the header; click to zoom.
// ---------------------------------------------------------------------------
const artifactsBySession = {};
let artifactsCollapsed = localStorage.getItem('crow.artifacts.collapsed') === '1';

async function refreshArtifacts(id) {
  try {
    const res = await rpc('list-artifacts', { session_id: id });
    artifactsBySession[id] = res.images || [];
  } catch (_) { artifactsBySession[id] = []; }
  if (id === selectedId) renderArtifactsStrip();
}

function renderArtifactsStrip() {
  const root = document.getElementById('detail-artifacts');
  if (!root) return;
  root.innerHTML = '';
  const images = artifactsBySession[selectedId] || [];
  if (!images.length) { root.classList.remove('has-images'); return; }
  root.classList.add('has-images');
  root.classList.toggle('collapsed', artifactsCollapsed);

  // Clickable header — chevron + label + count — toggles the strip.
  const header = el('div', 'artifacts-header');
  header.appendChild(el('span', 'artifacts-chevron', '▸')); // ▸ (CSS rotates when open)
  header.appendChild(el('span', 'artifacts-label', 'Images'));
  header.appendChild(el('span', 'artifacts-count', String(images.length)));
  header.onclick = () => {
    artifactsCollapsed = !artifactsCollapsed;
    localStorage.setItem('crow.artifacts.collapsed', artifactsCollapsed ? '1' : '0');
    root.classList.toggle('collapsed', artifactsCollapsed);
  };
  root.appendChild(header);

  const strip = el('div', 'artifacts-strip');
  for (const img of images) {
    const thumb = el('img', 'artifact-thumb');
    thumb.src = img.url;
    thumb.alt = img.name;
    thumb.title = img.name;
    thumb.loading = 'lazy';
    thumb.onclick = () => openLightbox(img.url, img.name);
    strip.appendChild(thumb);
  }
  root.appendChild(strip);
}

function openLightbox(url, alt) {
  const box = document.getElementById('lightbox');
  const img = document.getElementById('lightbox-img');
  img.src = url;
  img.alt = alt || '';
  box.hidden = false;
}

(function wireLightbox() {
  const box = document.getElementById('lightbox');
  if (box) box.onclick = () => { box.hidden = true; document.getElementById('lightbox-img').src = ''; };
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && box && !box.hidden) { box.hidden = true; document.getElementById('lightbox-img').src = ''; }
  });
})();

// Session-expired scrim Log in (#679): reuses the statusbar login handler (~:820).
(function wireSessionScrim() {
  const btn = document.getElementById('scrim-login');
  if (btn) btn.onclick = () => { location.href = '/login' + (location.hash || ''); };
})();

function shorten(path) {
  return path.replace(/^\/Users\/[^/]+/, '~').replace(/^\/home\/[^/]+/, '~');
}

// The review request matching a review session (by review_session_id), from the
// prefetched reviews board — so the session view can show the PR author.
function reviewForSession(id) {
  const rs = (boardData.reviews && boardData.reviews.reviews) || [];
  return rs.find((r) => r.review_session_id === id) || null;
}

// ---------------------------------------------------------------------------
// Back to grid (CROW-1163)
//
// Escape returns to `#/grid` only when this session view was opened from a
// grid cell (`sessionCameFromGrid`) AND the xterm does not have focus.
// Claude Code (and vim, pagers, …) use Escape to cancel; `handleTerminalKey`
// forwards unhandled keys to the PTY, so a global binding would steal it.
// Capture phase so we see the key *before* the lightbox's bubble listener
// hides itself — otherwise the same Escape would close the overlay *and*
// leave the session. Overlays (Settings, prompts, switcher, context menu)
// get first refusal: we no-op and let their own handlers run.
// ---------------------------------------------------------------------------
function returnToGridFromSession() {
  if (!sessionCameFromGrid || !selectedId || selectedBoard) return false;
  selectBoard('grid');
  return true;
}

function sessionFromGridEscapeBlocked() {
  if (window.settingsIsOpen && window.settingsIsOpen()) return true;
  const box = document.getElementById('lightbox');
  if (box && !box.hidden) return true;
  if (document.querySelector('.text-prompt-backdrop, .modal-dialog-backdrop')) return true;
  const sw = document.getElementById('session-switcher');
  if (sw && !sw.hidden) return true;
  return false;
}

function handleSessionFromGridEscape(e) {
  if (e.type !== 'keydown' || e.key !== 'Escape' || e.defaultPrevented) return;
  if (e.altKey || e.ctrlKey || e.metaKey) return;
  if (e.repeat) return;
  if (!sessionCameFromGrid || !selectedId || selectedBoard) return;
  // Load-bearing: never compete with the agent. xterm's textarea lives inside
  // #terminal; isTerminalFocused is the same check the switcher uses.
  if (isTerminalFocused()) return;
  // A chrome <input> (find, rename prompt is a modal and already blocked
  // above) must keep Escape, not navigate.
  const ae = document.activeElement;
  if (ae && (ae.tagName === 'INPUT' || ae.tagName === 'TEXTAREA' || ae.isContentEditable)) return;
  const menu = document.querySelector('.ctx-menu');
  if (menu) {
    closeContextMenu();
    e.preventDefault();
    e.stopPropagation();
    return;
  }
  if (sessionFromGridEscapeBlocked()) return;
  e.preventDefault();
  e.stopPropagation();
  returnToGridFromSession();
}

document.addEventListener('keydown', handleSessionFromGridEscape, true);

function renderHeader(s) {
  const root = document.getElementById('detail-header');
  root.innerHTML = '';
  if (!s) return;

  const top = el('div', 'detail-top');
  if (sessionCameFromGrid) {
    const back = el('button', 'back-to-grid', '‹ Grid');
    back.type = 'button';
    back.title = 'Back to grid (Esc)';
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

// In-page single-line text prompt. Replaces window.prompt(), which many browsers
// silently no-op — returning null — over the web: after a "prevent additional
// dialogs" opt-out, on assorted mobile browsers, and in some remote/secure
// contexts. window.prompt failing that way meant the rename rpc was never sent
// (CROW-593). Returns the entered string, or null on cancel/Escape/backdrop.
// In-page confirm/alert modal → Promise<boolean> (true = OK/confirm). Replaces
// window.confirm/alert, which render as native chrome (and are jarring inside the
// desktop wrapper). cancelLabel:null makes it an alert (single OK). (CROW-593)
function modalDialog({ title, body, okLabel = 'OK', cancelLabel = 'Cancel', danger = false, token = null } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const backdrop = el('div', 'text-prompt-backdrop modal-dialog-backdrop');
    const card = el('div', 'text-prompt-card');
    if (title) card.appendChild(el('div', 'text-prompt-title', title));
    if (body) card.appendChild(el('div', 'text-prompt-body', body));
    const actions = el('div', 'text-prompt-actions');
    const ok = el('button', 'text-prompt-btn primary' + (danger ? ' danger' : ''), okLabel);
    function finish(v) {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(v);
    }
    backdrop.__finish = finish;
    // Identity for `dismissModalDialog` — lets an async caller retract *its own*
    // dialog and only its own, never one the user opened afterwards (#931).
    backdrop.__token = token;
    function onKey(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(false); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); finish(true); }
    }
    if (cancelLabel != null) {
      const cancel = el('button', 'text-prompt-btn', cancelLabel);
      cancel.onclick = () => finish(false);
      actions.appendChild(cancel);
    }
    ok.onclick = () => finish(true);
    actions.appendChild(ok);
    card.appendChild(actions);
    backdrop.appendChild(card);
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) finish(false); });
    // One dialog at a time: supersede any stray *modalDialog* backdrop still on
    // screen so a double-fired error can't stack two overlapping cards whose text
    // abuts into one concatenated message (CROW-665). Finish (resolve as cancel)
    // each superseded dialog rather than bare-removing it, so its Promise settles
    // and its capture-phase keydown listener detaches — a plain .remove() orphans
    // both (review Yellow). Runs before this backdrop is in the DOM, so it only
    // matches prior dialogs. Scoped to modalDialog's marker class, so a live
    // `textPrompt` (shares `.text-prompt-backdrop`, resolves only via its own
    // handlers) is never touched.
    document.querySelectorAll('.modal-dialog-backdrop')
      .forEach((b) => (b.__finish ? b.__finish(false) : b.remove()));
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    ok.focus();
  });
}
function confirmModal(body, { title = 'Confirm', okLabel = 'OK', danger = false } = {}) {
  return modalDialog({ title, body, okLabel, cancelLabel: 'Cancel', danger });
}
function alertModal(body, { title = 'Crow', token = null } = {}) {
  return modalDialog({ title, body, okLabel: 'OK', cancelLabel: null, token });
}

// Take down the on-screen modalDialog iff it is the one created with `token`.
// Returns whether it dismissed anything. A no-op when the dialog was already
// dismissed by the user, or superseded by a later one — an async retraction must
// never yank a modal someone is mid-read of. Only ever one modalDialog is
// mounted (modalDialog supersedes its predecessors), so one query suffices.
function dismissModalDialog(token) {
  if (!token) return false;
  const backdrop = document.querySelector('.modal-dialog-backdrop');
  if (!backdrop || backdrop.__token !== token) return false;
  if (backdrop.__finish) backdrop.__finish(false); else backdrop.remove();
  return true;
}

function textPrompt(title, current, { placeholder = '', okLabel = 'Save' } = {}) {
  return new Promise((resolve) => {
    let done = false;
    const backdrop = el('div', 'text-prompt-backdrop');
    const card = el('div', 'text-prompt-card');
    const heading = el('div', 'text-prompt-title', title);
    const input = el('input', 'text-prompt-input');
    input.type = 'text';
    input.value = current || '';
    if (placeholder) input.placeholder = placeholder;
    const actions = el('div', 'text-prompt-actions');
    const cancel = el('button', 'text-prompt-btn', 'Cancel');
    const ok = el('button', 'text-prompt-btn primary', okLabel);
    actions.append(cancel, ok);
    card.append(heading, input, actions);
    backdrop.appendChild(card);

    function finish(value) {
      if (done) return;
      done = true;
      document.removeEventListener('keydown', onKey, true);
      backdrop.remove();
      resolve(value);
    }
    function onKey(e) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); finish(null); }
      else if (e.key === 'Enter') { e.preventDefault(); e.stopPropagation(); finish(input.value); }
    }
    cancel.onclick = () => finish(null);
    ok.onclick = () => finish(input.value);
    backdrop.addEventListener('mousedown', (e) => { if (e.target === backdrop) finish(null); });
    document.addEventListener('keydown', onKey, true);
    document.body.appendChild(backdrop);
    input.focus();
    input.select();
  });
}

async function renameSession(id, current) {
  const raw = await textPrompt('Rename session', current, { okLabel: 'Rename' });
  const name = raw == null ? null : raw.trim();
  if (!name || name === current) return;
  try {
    await rpc('rename-session', { session_id: id, name });
    const s = sessions.find((x) => x.id === id);
    if (s) { s.name = name; renderSidebar(); if (id === selectedId) renderHeader(s); }
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] rename failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}

// Set or update a session's org-goal tag (#723). Prompts free-text; an empty
// value clears the tag (parity with `crow set-goal --clear`). Updates the local
// session so the sidebar badge + detail header reflect it without a refetch.
async function setSessionGoal(id, current) {
  const raw = await textPrompt(current ? 'Edit org goal' : 'Set org goal', current || '',
    { placeholder: 'e.g. Q3 latency KPI', okLabel: 'Save' });
  if (raw == null) return; // cancelled
  const goal = raw.trim();
  if (goal === (current || '')) return; // unchanged (or empty on an untagged session) — skip the write
  try {
    await applyOrgGoal(id, goal);
  } catch (e) {
    alertModal('Set goal failed: ' + (e.message || e));
  }
}

async function clearSessionGoal(id) {
  try {
    await applyOrgGoal(id, '');
  } catch (e) {
    alertModal('Clear goal failed: ' + (e.message || e));
  }
}

// Shared org-goal mutation: a non-empty `goal` sets it, an empty string clears
// it (RPC gets `{goal}` or `{clear:true}` — never a blank goal, which the
// handler rejects). Reflects the change locally so the sidebar + header update
// without a refetch.
async function applyOrgGoal(id, goal) {
  await rpc('set-goal', goal ? { session_id: id, goal } : { session_id: id, clear: true });
  const s = sessions.find((x) => x.id === id);
  if (s) { s.org_goal = goal || null; renderSidebar(); if (id === selectedId) renderHeader(s); }
}

async function deleteSession(id, name) {
  if (!await confirmModal('Delete session "' + name + '"? This removes its worktree and terminals.', { okLabel: 'Delete', danger: true })) return;
  try {
    await rpc('delete-session', { session_id: id });
    sessions = sessions.filter((x) => x.id !== id);
    if (isGridPinned(id)) {
      gridPinnedIds = gridPinnedIds.filter((x) => x !== id);
      persistGridPins();
    }
    // `replace`: the session is gone, so Back must not offer to return to its
    // not-found card (review).
    if (selectedId === id) { navigate({ view: 'home' }, { replace: true }); showHome(); }
    renderSidebar();
  } catch (e) {
    alertModal('Delete failed: ' + (e.message || e));
  }
}

async function refreshTerminals() {
  try {
    const res = await rpc('list-terminals', { session_id: selectedId });
    terminals = res.terminals || [];
  } catch (_) {
    terminals = [];
  }
  // Rebind to the FRESH row, don't just check the old one is still present.
  // `activeTerminal` is not merely a selection marker: `agent_surface` drives
  // the wheel/mouse routing (ADR-0013) and `window` drives attachWindow, and
  // both can change under a stable id — `agent_surface` starts as the
  // pre-binding fallback and becomes authoritative once the tmux window exists
  // or an adopt re-applies the option. Keeping the stale object left routing on
  // the old value until the user happened to switch tabs.
  //
  // A terminal id from the URL (CROW-936) wins for exactly one pass, so a cold
  // #/sessions/<id>/t/<tid> load restores that tab instead of terminals[0].
  activeTerminal = (pendingTerminalId && terminals.find((t) => t.id === pendingTerminalId))
    || terminals.find((t) => t.id === (activeTerminal && activeTerminal.id))
    || terminals[0] || null;
  pendingTerminalId = null;
  applySurfaceScrollback();
  // CROW-1023: keep re-reading list-terminals while the attached surface is an
  // agent that hasn't latched into the alt buffer yet, so an alt-buffer build's
  // cap-to-0 isn't stranded behind the un-polled first snapshot (review).
  maybePollAltScreenLatch();
  // Whenever the URL names a terminal this session no longer has — a dead id
  // from the link, or a tab that has since been closed — point it at whatever
  // we actually landed on. Running on every pass rather than only the routed one
  // is what covers the second case; note refreshTerminals is not polled, so a
  // tab closed from *another* client is corrected on this client's next action
  // rather than live (review).
  const shown = currentRoute();
  if (selectedId && shown && shown.view === 'session' && shown.sessionId === selectedId
    && shown.terminalId && !terminals.some((t) => t.id === shown.terminalId)) {
    navigate({
      view: 'session',
      sessionId: selectedId,
      terminalId: activeTerminal ? activeTerminal.id : null,
    }, { replace: true });
  }
  renderTabs();
  // CROW-979: this call is what binds `activeTerminal`, and the header's ↻ Reload
  // is disabled until there is one. selectSession renders the header *before*
  // awaiting this, so without a nudge the button would sit disabled until the next
  // 4s refreshLive tick.
  syncTerminalReloadEnabled();
  // Session/tab switches funnel through here too (selectSession → refreshTerminals),
  // changing which window this shared socket shows. attachWindow is a no-op when
  // the window didn't change, so a same-session background refresh stays put.
  // Agent surfaces switch in place (CROW-1035); shells still take the #673 reload.
  if (activeTerminal) attachWindow(activeTerminal.window);
}

function renderTabs() {
  const bar = document.getElementById('tabbar');
  bar.innerHTML = '';
  // #680: managers are a single terminal — no tabs, no "+", no "×". Leaving
  // #tabbar empty lets the `#tabbar:empty { display:none }` rule (app.css)
  // collapse it so no empty strip sits above the manager terminal. (This also
  // moots the stale-tab naming bug: a renamed manager session has no tab to go
  // stale, since tabs are labeled from the terminal name, not the session name.)
  const sel = sessions.find((x) => x.id === selectedId);
  if (sel && sel.kind === 'manager') {
    // #680: managers have no tabs. But the Manager window is a common CROW-804
    // "stuck alt-screen / 5000-line" case, and with no tab there'd be no ⚠ or
    // Recreate. Surface a slim warning strip with a Recreate action when the
    // Manager terminal is degraded; otherwise leave #tabbar empty so it stays
    // collapsed. Recreate routes through restartManager (SessionService).
    const degraded = terminals.find((t) => t.scrollback_degraded);
    if (degraded) {
      const strip = el('div', 'degraded-strip');
      strip.appendChild(el('span', 'tab-degraded', '⚠'));
      strip.appendChild(el('span', 'degraded-msg', 'Scrollback degraded — this Manager window can\'t show full history.'));
      const btn = el('span', 'degraded-recreate', 'Recreate');
      btn.title = 'Rebuild this Manager terminal to restore full scroll-up history (restarts the agent).';
      btn.onclick = () => recreateTerminal(degraded);
      strip.appendChild(btn);
      bar.appendChild(strip);
    }
    return;
  }
  for (const t of terminals) {
    const tab = el('div', 'tab' + (activeTerminal && t.id === activeTerminal.id ? ' active' : ''));
    const label = el('span', null, t.name);
    label.onclick = () => switchTerminal(t);
    tab.appendChild(label);
    // CROW-804: this terminal's tmux window is stuck with degraded scrollback
    // (alternate-screen buffer and/or the old 5000-line history-limit) that
    // tmux can't fix in place. Badge it and offer a one-click recreate.
    if (t.scrollback_degraded) {
      const warn = el('span', 'tab-degraded', '⚠');
      warn.title = 'Scrollback degraded — this window can\'t show full history (created before the current config). Click to recreate it and restore scroll-up.';
      warn.onclick = (e) => { e.stopPropagation(); recreateTerminal(t); };
      tab.appendChild(warn);
    }
    const close = el('span', 'tab-close', '×');
    close.onclick = (e) => { e.stopPropagation(); closeTerminal(t); };
    tab.appendChild(close);
    bar.appendChild(tab);
  }
  const add = el('div', 'tab add', '+');
  add.onclick = addTerminal;
  add.title = 'New terminal';
  bar.appendChild(add);
}

function switchTerminal(t) {
  // The terminal segment is written here and nowhere else: opening a session
  // leaves the URL at #/sessions/<id>, which reloads onto terminals[0] — the
  // same tab — so nothing is lost and clicking a session doesn't bury the
  // history under an id the user never chose. Guarded on selectedId because
  // routeToHash falls through to '#/' without one, which would navigate a tab
  // switch to home.
  if (selectedId) navigate({ view: 'session', sessionId: selectedId, terminalId: t.id });
  activeTerminal = t;
  applySurfaceScrollback();
  // CROW-1023: a tab switch is a bind of `activeTerminal` just like a
  // refreshTerminals pass, so it must (dis)arm the alt-buffer latch poll too —
  // otherwise switching away from a still-starting Claude tab and back (e.g.
  // opening a shell while it launches) reapplies the stale `false` row and never
  // re-reads, re-stranding the cap-to-0 (review). Leaving disarms; returning to
  // a still-unlatched tab gets a fresh budget (disarm nulls the tracked id).
  maybePollAltScreenLatch();
  renderTabs();
  // Window change is attachWindow's job. Shells still take the #673 full
  // reload (reset + fresh socket) so a surface another client reshaped
  // self-heals. Agent TUIs switch in place — the reload's new PTY (24×80
  // then SIGWINCH) is what jumps Claude's caret and doubles Cursor chrome
  // (CROW-1035). Re-clicking the active tab is a no-op (win === attachedWindow).
  attachWindow(t.window);
  if (term) term.focus();
}

async function addTerminal() {
  if (!selectedId) return;
  try {
    const res = await rpc('new-terminal', { session_id: selectedId });
    await refreshTerminals();
    const created = terminals.find((t) => t.id === res.terminal_id);
    if (created) switchTerminal(created);
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] new-terminal failed: ' + (e.message || e) + '\x1b[0m\r\n');
  }
}

async function closeTerminal(t) {
  try { await rpc('close-terminal', { session_id: selectedId, terminal_id: t.id }); } catch (_) {}
  if (activeTerminal && activeTerminal.id === t.id) activeTerminal = null;
  await refreshTerminals();
}

// CROW-804: heal a terminal whose tmux window has degraded scrollback. Recreate
// kills the window and rebuilds it under the current config, relaunching the
// agent (`claude --continue`) — so confirm first, since it interrupts whatever
// is running in the pane.
async function recreateTerminal(t) {
  const ok = await confirmModal(
    'This rebuilds “' + (t.name || 'terminal') + '” to restore full scroll-up history. '
    + 'The agent running in it will be restarted (and resumed where the agent supports it).',
    { title: 'Recreate terminal', okLabel: 'Recreate', danger: true });
  if (!ok) return;
  try {
    await rpc('recreate-terminal', { session_id: selectedId, terminal_id: t.id });
  } catch (e) {
    if (term) term.write('\r\n\x1b[31m[crow] recreate-terminal failed: ' + (e.message || e) + '\x1b[0m\r\n');
    // Register-then-kill means a failed heal leaves the old window live and
    // still degraded — refresh so the ⚠ / Recreate affordance re-renders for a
    // retry instead of vanishing on a half-applied state.
    await refreshTerminals();
    return;
  }
  await refreshTerminals();
  // Recreate binds a FRESH tmux window, but `new-window` (no -a) reuses the
  // index just freed by killWindow — so the new index usually EQUALS the old
  // one. Even after re-pointing at the refreshed row, attachWindow's
  // `win === attachedWindow` guard would then skip the reload and leave the
  // surface on the dead pane (the stale-*index* case; the stale-*object* case
  // was fixed earlier). Clear attachedWindow so the reattach can't short-circuit,
  // then switch onto the refreshed row — for the primary Manager its id changes,
  // so fall back to the activeTerminal refreshTerminals already swapped in.
  const refreshed = terminals.find((x) => x.id === t.id) || activeTerminal;
  attachedWindow = null;
  if (refreshed) switchTerminal(refreshed);
}
