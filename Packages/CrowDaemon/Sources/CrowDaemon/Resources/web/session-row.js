'use strict';
// Crow web UI — Session row + activity indicator. Extracted from sidebar.js (CROW-1238).

// Sidebar status/activity indicator, mirroring the desktop: for active
// sessions the dot is driven by hook activity (working / needs-attention /
// done); otherwise by session status.
function activityIndicator(s) {
  if (s.status !== 'active') {
    return { color: STATUS_COLOR[s.status] || 'var(--text-muted)' };
  }
  if (s.attention) {
    return { color: 'var(--orange)', pulse: true, label: s.attention === 'question' ? 'Question' : 'Permission' };
  }
  switch (s.activity) {
    case 'working': return { color: 'var(--green)', pulse: true, label: 'Working' };
    case 'waiting': return { color: 'var(--orange)', pulse: true, label: 'Waiting' };
    case 'done': return { color: 'var(--gold)', label: 'Done' };
    default: return { color: 'var(--green)' };
  }
}

function sessionRow(s) {
  const multiSel = selectionMode && selectedSessionIDs.has(s.id);
  const row = el('div', 'session-row status-accent'
    + (!selectionMode && s.id === selectedId ? ' selected' : '')
    + (selectionMode ? ' selecting' : '')
    + (multiSel ? ' multi-selected' : ''));
  row.onclick = selectionMode ? (() => toggleSelect(s.id)) : (() => selectSession(s.id));
  row.oncontextmenu = (e) => showSessionMenu(e, s);
  // Touch devices have no right-click: a long-press opens the same menu at the
  // finger, the standard mobile equivalent (rename/delete were unreachable on
  // mobile otherwise — CROW-593).
  attachLongPress(row, (x, y) => {
    if (selectionMode) return;
    showSessionMenu({ preventDefault() {}, clientX: x, clientY: y }, s);
  });
  const ind = activityIndicator(s);
  // Left accent hue: amber for attention (permission/question), green for done,
  // neutral otherwise (mirrors the desktop rowBackgroundColor logic).
  row.style.borderLeftColor = s.attention ? 'var(--orange)'
    : (s.activity === 'done' ? 'var(--green)' : 'var(--border-subtle)');
  // Full-card background tint by state, matching the desktop rowBackgroundColor
  // (orange tint on attention, green tint when done). Left unset when the row is
  // selected (single or multi) so the gold selected background wins (CROW-593).
  if (!multiSel && !(s.id === selectedId && !selectionMode)) {
    row.style.background = s.attention ? 'rgba(230,145,50,0.14)'
      : (s.activity === 'done' ? 'var(--bg-done)' : '');
  }

  // In multi-select mode a checkbox leads the row; the rest of the content is
  // wrapped so the checkbox sits left of the stacked body (#5 / CROW-593).
  let content = row;
  if (selectionMode) {
    const cb = el('input', 'row-check');
    cb.type = 'checkbox';
    cb.checked = multiSel;
    cb.onclick = (e) => { e.stopPropagation(); toggleSelect(s.id); };
    row.appendChild(cb);
    content = el('div', 'row-body');
    row.appendChild(content);
  }

  const top = el('div', 'row-top');
  const lead = el('div', 'row-lead');
  lead.appendChild(el('span', 'agent', AGENT_GLYPH[s.agent_kind] || '•'));
  lead.appendChild(el('span', 'name', s.name));
  if (liveFor(s.id).remote_control_active) lead.appendChild(rcGlyph());
  top.appendChild(lead);

  const trail = el('div', 'row-trail');
  if (isGridPinned(s.id)) {
    const pinMark = icon('pin', 11);
    pinMark.classList.add('row-pin');
    pinMark.title = 'Pinned to the session grid';
    trail.appendChild(pinMark);
  }
  if (s.locked) trail.appendChild(el('span', 'lock', '🔒'));
  // The auto-merge ⛙ used to live here, untinted and structurally divorced from
  // the PR pill. It now lives IN the pill (see prAutoMergeGlyph), where a color
  // can distinguish "armed" from "Crow gave up" — two ⛙ marks on one row
  // meaning different things would be worse than the bug (#888, CROW-773).
  // Trailing glowing status dot.
  const dot = el('span', 'dot glow' + (ind.pulse ? ' pulse' : ''));
  dot.style.background = ind.color;
  dot.style.color = ind.color; // drives the glow ring (box-shadow: currentColor)
  trail.appendChild(dot);
  top.appendChild(trail);
  content.appendChild(top);

  if (!uiConfig.hideSessionDetails) {
    if (s.ticket_title) content.appendChild(el('div', 'subtle', s.ticket_title));
    if (s.repo) content.appendChild(el('div', 'meta', s.repo + (s.branch ? ' · ' + s.branch : '')));
    // Ticket/review label pills — native `SessionRow` showed these below the
    // repo line, capped at 2, behind the same hideSessionDetails gate (CROW-773).
    if (s.labels && s.labels.length) content.appendChild(labelPills(s.labels, 2));
  }

  const badges = el('div', 'row-badges');
  // Ticket pill — purple once the linked issue is closed, mirroring the
  // merged-PR pill so the row shows issue state at a glance (#792).
  if (s.ticket_badge) {
    const tb = el('span', 'badge', s.ticket_badge);
    if (s.ticket_state === 'closed') {
      tb.classList.add('badge-closed');
      tb.title = 'Issue closed';
      tb.setAttribute('aria-label', s.ticket_badge + ', issue closed');
    }
    badges.appendChild(tb);
  }
  if (s.is_explore) {
    const exp = el('span', 'explore-badge', 'Exploring');
    exp.title = 'Exploration session — read/explain only, no build';
    badges.appendChild(exp);
  }
  // Light org-goal indicator (#723) — glyph only to keep the card compact; the
  // full goal text lives in the tooltip and the detail header.
  if (s.org_goal) {
    const g = el('span', 'badge goal-badge', '🎯');
    g.title = 'Goal: ' + s.org_goal;
    badges.appendChild(g);
  }
  // PR badge — shown whenever a PR link exists (stored, or live from the app
  // when it's only in memory); colored AND glyphed by live status when
  // available. The glyphs mirror the retired native `PRBadge` (CROW-773): a
  // color-only pill can't distinguish failing checks from changes-requested.
  const prLink = (s.links || []).find((l) => l.type === 'pr') || liveFor(s.id).pr_link;
  if (prLink) {
    const pr = liveFor(s.id).pr;
    const color = prBadgeColor(pr);
    const prb = el('span', 'pr-badge', prLink.label || 'PR');
    prb.style.color = color;
    prb.style.borderColor = color;
    const parts = prBadgeParts(pr, liveFor(s.id).auto_merge_state, s.auto_merge,
                               liveFor(s.id).auto_rebase_state);
    for (const part of parts) {
      const ico = part.icon ? icon(part.icon, 10) : el('span', 'pr-ico', part.glyph);
      ico.style.color = part.color;
      prb.appendChild(ico);
    }
    // Glyph + color must not be the only channel — mirrors native PRBadge's
    // `accessibilityDescription` ("#123, Checks pass, Approved").
    const desc = [prLink.label || 'PR', ...parts.map((p) => p.a11yLabel || p.label)].join(', ');
    // The auto-merge part carries a whole sentence — too long for the comma
    // list, but it IS the answer to "why is nothing happening?", so it gets its
    // own tooltip line and rides the aria-label rather than being sighted-only.
    const detail = parts.map((p) => p.detail).filter(Boolean).join(' ');
    prb.title = detail ? desc + '\n' + detail : desc;
    prb.setAttribute('aria-label', detail ? desc + '. ' + detail : desc);
    badges.appendChild(prb);
  }
  // Activity badge (Working/Waiting/Done/…) is redundant on managers — they
  // already show the trailing status dot, and the badge forces a second line.
  if (ind.label && s.kind !== 'manager') {
    const activity = el('span', 'activity-badge', ind.label);
    activity.style.color = ind.color;
    badges.appendChild(activity);
  }
  if (badges.children.length) content.appendChild(badges);

  // Visible actions affordance (tap = same menu as right-click / long-press).
  // The row reserves a right gutter (.session-row padding-right) so this sits in
  // the bottom-right corner clear of the status dot, incl. single-line manager
  // cards. Omitted in multi-select mode, where the checkbox is the action.
  if (!selectionMode) {
    const kebab = el('button', 'row-kebab', '⋮');
    kebab.type = 'button';
    kebab.title = 'Actions';
    kebab.setAttribute('aria-label', 'Session actions');
    kebab.onclick = (e) => {
      e.stopPropagation();
      const r = kebab.getBoundingClientRect();
      showSessionMenu({ preventDefault() {}, clientX: r.right, clientY: r.bottom }, s);
    };
    row.appendChild(kebab);
  }
  return row;
}
