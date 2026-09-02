'use strict';
// Crow web UI — Boards: tickets, reviews, scorecard. Extracted from app.js (CROW-1155).

// ---------------------------------------------------------------------------
// Boards (Ticket Board / Reviews)
// ---------------------------------------------------------------------------
function selectBoard(key) {
  navigate({ view: 'board', board: key });
  selectedBoard = key;
  selectedId = null;
  // Leaving a board (or re-entering) drops any stale selection on it.
  ticketSelectionMode = false;
  selectedIssueIDs.clear();
  reviewSelectionMode = false;
  selectedReviewURLs.clear();
  const app = document.getElementById('app');
  app.classList.add('has-selection', 'board-active');
  app.classList.remove('mobile-show-sidebar', 'route-missing');
  document.getElementById('detail-header').innerHTML = '';
  document.getElementById('tabbar').innerHTML = '';
  renderSidebar();
  renderBoard();       // instant paint (may be stale/empty)…
  if (key === 'grid') return;
  refreshBoard(key); // …then refresh from the app
}

// Fetch one board; only re-render when the data actually changed so polling
// doesn't reset scroll/selection while idle.
async function refreshBoard(key) {
  const method = key === 'tickets' ? 'list-tickets'
    : key === 'reviews' ? 'list-reviews'
    : 'get-scorecard';
  let data;
  try { data = await rpc(method); } catch (_) {
    // A failed read leaves us with no fresh word on the daemon's in-flight
    // flag, and a stale `true` never self-clears (CROW-771).
    if (key === 'tickets') clearDaemonRefreshFlag();
    return;
  }
  const changed = JSON.stringify(boardData[key]) !== JSON.stringify(data);
  boardData[key] = data;
  if (changed && (key === 'tickets' || key === 'reviews')) persistSidebarCache();
  if (key === 'reviews') detectReviewSounds();
  if (changed) renderSidebar(); // badge counts
  if (changed && selectedBoard === key) renderBoard();
  // Reviews carry the PR author shown in the session header — re-render it when
  // reviews (re)load so a selected review session picks the author up.
  if (key === 'reviews' && selectedId) {
    const sel = sessions.find((x) => x.id === selectedId);
    if (sel) renderHeader(sel);
  }
}

function renderBoard() {
  const root = document.getElementById('board');
  if (selectedBoard === 'grid') {
    renderSessionGrid(root);
    return;
  }
  leaveGridView();
  root.classList.remove('session-grid-board');
  root.innerHTML = '';
  if (selectedBoard === 'tickets') renderTicketBoard(root);
  else if (selectedBoard === 'reviews') renderReviewBoard(root);
  else if (selectedBoard === 'scorecard') renderScorecard(root);
}

// ===== Scorecard (ADR 0008 web parity, #721) =====
// Private weekly efficiency scorecard. Everything is computed by the one Core
// `ScorecardModel` on the daemon and shipped as a flat `ScorecardDTO` over
// `get-scorecard`; this only renders it, so the numbers have a single source of
// truth.

// Formatters so the web reads the same numbers Core computes.
function fmtCost(cost) {
  if (cost > 0 && cost < 0.01) return '<$0.01';
  return '$' + Number(cost).toFixed(2);
}
function fmtCount(n) {
  n = Number(n);
  if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return String(Math.round(n));
}
function fmtTime(seconds) {
  const s = Math.floor(Number(seconds) || 0);
  if (s >= 3600) return Math.floor(s / 3600) + 'h ' + Math.floor((s % 3600) / 60) + 'm';
  if (s >= 60) return Math.floor(s / 60) + 'm';
  return s + 's';
}
function fmtPct(fraction) {
  const p = Number(fraction) * 100;
  return (p === Math.round(p) ? p.toFixed(0) : p.toFixed(1)) + '%';
}
function scoreWeekLabel(millis) {
  const start = new Date(millis);
  const end = new Date(millis + 6 * 86400 * 1000);
  const fmt = (d) => d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
  return 'Week of ' + fmt(start) + ' – ' + fmt(end);
}
const GRADE_COLORS = { A: '#4ade80', B: '#6ee7b7', C: '#facc15', D: '#fb923c', F: '#f87171' };
function gradeColor(letter) { return GRADE_COLORS[letter] || 'var(--text-muted)'; }
// One coachable sentence per metric — the view-layer copy from the desktop.
const COACHING = {
  compactions: 'Compacting mid-session means the context filled — clear between tasks or split unrelated work.',
  contextPressure: 'Heavy input per prompt suggests bloated context — reset more often or narrow what gets loaded.',
  cacheHitRatio: 'Low cache reuse means context is re-sent as fresh input — steadier sessions cache better.',
  apiErrorRate: 'Frequent API errors burn time and tokens — check connectivity, rate limits, or the agent setup.',
  costPerShipped: 'High spend per shipped session — smaller scoped sessions that finish tend to cost less per outcome.',
};

function scoreCard(children) {
  const c = el('div', 'score-card');
  for (const child of children) if (child) c.appendChild(child);
  return c;
}
function scoreLabel(text) { return el('div', 'score-card-label', text); }

function renderScorecard(root) {
  const head = el('div', 'board-head');
  head.appendChild(el('div', 'board-title', 'Scorecard'));
  const data = boardData.scorecard;
  if (data) {
    const wk = el('div', 'score-weeklabel', scoreWeekLabel(data.currentWeek.weekStartMillis));
    head.appendChild(wk);
  }
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.onclick = () => refreshBoard('scorecard');
  head.appendChild(refresh);
  // Rebuild backfills snapshots from telemetry.db and recomputes the Manager
  // Manager rollups (#745) — only offered when telemetry is actually capturing,
  // since with it off there is no database to rebuild from.
  if (data && data.telemetryCapturing) {
    const rebuild = el('button', 'action-btn', 'Rebuild');
    rebuild.title = 'Rebuild scorecard data from the local telemetry database';
    rebuild.onclick = async () => {
      rebuild.disabled = true;
      rebuild.textContent = 'Rebuilding…';
      try {
        await rpc('rebuild-scorecard');
      } catch (e) {
        // Match the other board actions' failure affordance (alertModal) rather
        // than swallow — a failed rebuild otherwise re-enables silently.
        alertModal('Rebuild scorecard failed: ' + (e.message || e));
      }
      rebuild.disabled = false;
      rebuild.textContent = 'Rebuild';
      refreshBoard('scorecard');
    };
    head.appendChild(rebuild);
  }
  root.appendChild(head);

  const banner = el('div', 'score-banner',
    'Private efficiency scorecard — this week vs. your own trailing 4-week normal. ' +
    'Grade thresholds are starting heuristics under a 4-week calibration period; expect them to move.');
  root.appendChild(banner);

  if (!data) {
    root.appendChild(el('div', 'score-empty', 'Loading…'));
    return;
  }
  root.appendChild(el('div', 'score-capture', captureStatusText(data)));
  const manager = managerWeeks(data);
  // Manager-only data still shows the content pane: the grade card renders
  // "insufficient data" gracefully with zero snapshots, and hiding captured
  // Manager usage behind the empty state would repeat the invisibility this
  // gate is meant to fix (#745) — same condition the desktop view used.
  if (!data.snapshotCount && !manager.length) {
    root.appendChild(scorecardEmpty(data));
    return;
  }

  const wrap = el('div', 'score-wrap');
  const top = el('div', 'score-row');
  top.appendChild(gradeCardEl(data.currentWeek));
  top.appendChild(shippedCardEl(data.currentWeek));
  wrap.appendChild(top);

  wrap.appendChild(combinedCardEl(data.currentWeek));
  wrap.appendChild(baselineCardEl(data));
  wrap.appendChild(displayedStatsEl(data.currentWeek));
  if (manager.length) wrap.appendChild(managerUsageEl(manager));
  if (data.priorWeeks.length) wrap.appendChild(priorWeeksEl(data.priorWeeks));
  if (data.sessions.length) wrap.appendChild(sessionsEl(data.sessions));
  root.appendChild(wrap);
}

// A daemon that isn't capturing is the usual reason a section is empty, so say
// so instead of leaving the user to guess (#745).
function captureStatusText(data) {
  if (!data.telemetryCapturing) {
    return 'Telemetry not capturing — enable it in Settings, then restart crowd';
  }
  return 'Telemetry capturing — ' + data.telemetrySessionCount +
    ' session' + (data.telemetrySessionCount === 1 ? '' : 's') + ' recorded';
}

// Tolerates a daemon predating #767, whose `get-scorecard` has no such field.
function managerWeeks(data) { return data.managerWeeks || []; }

function scorecardEmpty(data) {
  const box = el('div', 'score-empty');
  box.appendChild(el('div', 'score-empty-title', 'No Session Data Yet'));
  const msg = el('div', 'score-empty-msg', (data.telemetryEnabled
    ? 'The scorecard is computed from analytics snapshots written when sessions complete or archive. Telemetry is on — finish a session and it will appear here.'
    : 'The scorecard is computed from analytics snapshots written when sessions complete or archive. Snapshots require Claude Code telemetry, which is off by default.') +
    ' A Manager session never completes, so it is metered in its own section instead — graded on efficiency, but never on outcomes.');
  box.appendChild(msg);
  if (!data.telemetryEnabled) {
    const btn = el('button', 'action-btn action-primary', 'Open Settings');
    btn.onclick = () => { if (window.openSettings) window.openSettings(); };
    box.appendChild(btn);
  }
  return box;
}

function insufficientDataEl(promptCount, minPrompts) {
  const box = el('div', 'score-insufficient');
  box.appendChild(el('div', 'score-insufficient-title', 'Insufficient data'));
  box.appendChild(el('div', 'score-sub',
    promptCount + ' prompt' + (promptCount === 1 ? '' : 's') + ' this week — grading starts at ' + minPrompts + '.'));
  return box;
}

function gradeCardEl(week) {
  const body = [scoreLabel("This Week's Grade")];
  const g = week.grade;
  if (g.graded) {
    const big = el('div', 'score-grade-row');
    const letter = el('span', 'score-grade-letter', g.letter);
    letter.style.color = gradeColor(g.letter);
    big.appendChild(letter);
    big.appendChild(el('span', 'score-grade-num', g.score + '/100'));
    body.push(big);
    if (!g.deductions.length) {
      body.push(el('div', 'score-muted', 'No deductions — clean week.'));
    } else {
      const list = el('div', 'score-deductions');
      for (const d of g.deductions) list.appendChild(deductionRowEl(d));
      body.push(list);
    }
  } else {
    body.push(insufficientDataEl(g.promptCount, boardData.scorecard.minimumGradablePromptCount));
  }
  return scoreCard(body);
}

function deductionRowEl(d) {
  const row = el('div', 'score-deduction');
  const line = el('div', 'score-deduction-line');
  line.appendChild(el('span', 'score-deduction-label', d.label));
  line.appendChild(el('span', 'score-deduction-points', '−' + d.points));
  row.appendChild(line);
  row.appendChild(el('div', 'score-deduction-hint', COACHING[d.metric] || ''));
  return row;
}

function shippedCardEl(week) {
  const body = [scoreLabel('Sessions Shipped')];
  const big = el('div', 'score-big-gold', String(week.sessionsShipped));
  body.push(big);
  if (week.costPerShipped != null) {
    body.push(el('div', 'score-sub', fmtCost(week.costPerShipped) + ' per shipped session'));
  } else {
    body.push(el('div', 'score-muted', 'Insufficient outcomes — nothing shipped this week.'));
  }
  return scoreCard(body);
}

function combinedCardEl(week) {
  const body = [scoreLabel('Combined Score (v2)')];
  const c = week.combined;
  if (c.scored) {
    body.push(el('div', 'score-big-gold', Number(c.value).toFixed(1)));
    body.push(el('div', 'score-decomp',
      c.shippedCount + ' shipped × ' + Number(c.alignmentFactor).toFixed(2) + ' alignment × ' +
      Number(c.efficiencyMultiplier).toFixed(2) + ' efficiency'));
    body.push(el('div', 'score-decomp-sub',
      'efficiency = grade ' + c.gradeScore + '/100 × hygiene ' + Number(c.hygieneFactor).toFixed(2) +
      hygieneDetail(c)));
    body.push(el('div', 'score-muted',
      'Alignment-weighted throughput × efficiency, weekly grain — bad hygiene multiplies the score down and ' +
      "can't be bought back with volume. Same private self-comparison posture and tunable priors as the grade."));
  } else {
    body.push(insufficientDataEl(c.promptCount, boardData.scorecard.minimumGradablePromptCount));
  }
  return scoreCard(body);
}

function hygieneDetail(c) {
  const parts = [];
  if (c.revertCount > 0) parts.push(c.revertCount + ' revert' + (c.revertCount === 1 ? '' : 's'));
  if (c.postMergeFixCount > 0) parts.push(c.postMergeFixCount + ' post-merge fix' + (c.postMergeFixCount === 1 ? '' : 'es'));
  if (c.mergeRate != null && c.mergeRate < 1) parts.push(Math.round(c.mergeRate * 100) + '% merge rate');
  return parts.length ? '  (' + parts.join(', ') + ')' : '';
}

function baselineCardEl(data) {
  const b = data.baseline;
  const body = [scoreLabel('vs. Your Normal (trailing 4-week median)')];
  if (b.weeksAvailable < data.minimumBaselineWeeks) {
    body.push(el('div', 'score-muted',
      'Baseline building — ' + b.weeksAvailable + ' of ' + data.baselineWeekCount + ' weeks of history.'));
    return scoreCard(body);
  }
  const wk = data.currentWeek;
  const rows = el('div', 'score-comparisons');
  const add = (name, current, baseline, higherIsBetter, fmt) => {
    if (baseline == null || current == null) return;
    rows.appendChild(comparisonRowEl(name, current, baseline, higherIsBetter, fmt));
  };
  if (wk.grade.graded) add('Score', wk.grade.score, b.medianScore, true, (v) => v.toFixed(0));
  add('Compactions/active hr', wk.compactionsPerActiveHour, b.medianCompactionsPerActiveHour, false, (v) => v.toFixed(1));
  add('Input tokens/prompt', wk.inputTokensPerPrompt, b.medianInputTokensPerPrompt, false, (v) => fmtCount(Math.round(v)));
  add('Cache hit ratio', wk.cacheHitRatio, b.medianCacheHitRatio, true, (v) => (v * 100).toFixed(0) + '%');
  add('API error rate', wk.apiErrorRate, b.medianApiErrorRate, false, (v) => (v * 100).toFixed(1) + '%');
  add('Cost/shipped', wk.costPerShipped, b.medianCostPerShipped, false, fmtCost);
  if (wk.combined.scored) add('Combined score', wk.combined.value, b.medianCombinedScore, true, (v) => v.toFixed(1));
  body.push(rows);
  return scoreCard(body);
}

function comparisonRowEl(name, current, baseline, higherIsBetter, fmt) {
  const delta = current - baseline;
  const isFlat = Math.abs(delta) < 0.0001;
  const isBetter = higherIsBetter ? delta > 0 : delta < 0;
  const row = el('div', 'score-comparison');
  row.appendChild(el('span', 'score-comparison-name', name));
  row.appendChild(el('span', 'score-comparison-current', fmt(current)));
  const arrow = el('span', 'score-comparison-arrow ' + (isFlat ? 'flat' : isBetter ? 'good' : 'bad'),
    isFlat ? '–' : delta > 0 ? '↑' : '↓');
  row.appendChild(arrow);
  row.appendChild(el('span', 'score-comparison-baseline', fmt(baseline)));
  return row;
}

function displayedStatsEl(week) {
  const body = [scoreLabel('This Week (context only — not graded)')];
  const chips = el('div', 'score-chips');
  chips.appendChild(statChipEl('Cost', fmtCost(week.totalCost)));
  chips.appendChild(statChipEl('Active', fmtTime(week.activeTimeSeconds)));
  chips.appendChild(statChipEl('Commits', String(week.commitCount)));
  chips.appendChild(statChipEl('Churn', Number(week.churnHint).toFixed(2)));
  body.push(chips);
  return scoreCard(body);
}

function statChipEl(label, value) {
  const chip = el('div', 'score-chip');
  chip.appendChild(el('span', 'score-chip-label', label));
  chip.appendChild(el('span', 'score-chip-value', value));
  return chip;
}

// Manager usage (#745, #767, CROW-983). A Manager never reaches a terminal
// status, so it produces no snapshot and no OUTCOME surface — no shipped
// count, no cost-per-shipped, no combined score, and it never enters the
// baseline. It does carry an EFFICIENCY grade: that half of the rubric needs
// no outcome, so it is computed from the same raws a work week uses.
//
// Rendered with the same chip vocabulary as the graded weeks so a Manager week
// reads like a work week rather than a footnote — but the card keeps an
// explicit "efficiency only" pill so it can never be mistaken for part of the
// graded aggregate. Grouped per Manager once more than one exists.
function managerUsageEl(weeks) {
  const label = el('div', 'score-card-label');
  label.appendChild(el('span', null, 'Manager Usage'));
  label.appendChild(el('span', 'score-ungraded', 'efficiency only'));
  const body = [label];

  const groups = groupManagerWeeks(weeks);
  for (const group of groups) {
    if (groups.length > 1) {
      body.push(el('div', 'score-manager-group', group.name));
    }
    const list = el('div', 'score-manager');
    for (const w of group.weeks) list.appendChild(managerWeekRowEl(w));
    body.push(list);
  }

  body.push(el('div', 'score-muted',
    'A Manager session never completes, so it is metered here rather than graded on ' +
    'outcomes: its efficiency is scored, but it never enters the shipped count, ' +
    'cost-per-shipped, the combined score, or the baseline.'));
  return scoreCard(body);
}

// Stable grouping by Manager, preserving the DTO's newest-first week order.
// The DTO always resolves sessionID (legacy rollups report the primary), so
// grouping is total; sessionName is absent for a deleted Manager.
function groupManagerWeeks(weeks) {
  const order = [];
  const bySession = new Map();
  for (const w of weeks) {
    const key = w.sessionID || 'manager';
    if (!bySession.has(key)) {
      bySession.set(key, { name: w.sessionName || 'Manager', weeks: [] });
      order.push(key);
    }
    bySession.get(key).weeks.push(w);
  }
  return order.map((k) => bySession.get(k));
}

function managerWeekRowEl(w) {
  const row = el('div', 'score-manager-week-block');

  const head = el('div', 'score-manager-row');
  head.appendChild(el('span', 'score-manager-week', scoreWeekLabel(w.weekStartMillis)));
  head.appendChild(gradeBadgeEl(w.grade));
  head.appendChild(el('span', 'score-manager-prompts',
    w.promptCount + ' prompt' + (w.promptCount === 1 ? '' : 's')));
  head.appendChild(el('span', 'score-manager-stat', fmtCost(w.totalCost)));
  row.appendChild(head);

  // Same chips as a graded week, plus the efficiency raws the grade cites.
  // `.score-chips` wraps, which is what keeps this readable on a narrow phone.
  const chips = el('div', 'score-chips');
  chips.appendChild(statChipEl('Active', fmtTime(w.activeTimeSeconds)));
  chips.appendChild(statChipEl('Tokens', fmtCount(w.totalTokens)));
  chips.appendChild(statChipEl('Tok/Prompt', fmtCount(w.inputTokensPerPrompt)));
  chips.appendChild(statChipEl('Cache', fmtPct(w.cacheHitRatio)));
  chips.appendChild(statChipEl('API Errors', fmtPct(w.apiErrorRate)));
  chips.appendChild(statChipEl('Compact/hr', Number(w.compactionsPerActiveHour).toFixed(1)));
  chips.appendChild(statChipEl('Tools', String(w.toolCallCount)));
  chips.appendChild(statChipEl('Commits', String(w.commitCount)));
  row.appendChild(chips);

  if (w.grade.graded && w.grade.deductions.length) {
    row.appendChild(el('div', 'score-session-deductions',
      w.grade.deductions.map((d) => d.label + ' −' + d.points).join('  ·  ')));
  }
  return row;
}

function priorWeeksEl(weeks) {
  const body = [scoreLabel('Previous Weeks')];
  const list = el('div', 'score-prior');
  for (const w of weeks) {
    const row = el('div', 'score-prior-row');
    row.appendChild(el('span', 'score-prior-week', scoreWeekLabel(w.weekStartMillis)));
    row.appendChild(gradeBadgeEl(w.grade));
    row.appendChild(el('span', 'score-prior-shipped', w.sessionsShipped + ' shipped'));
    row.appendChild(el('span', 'score-prior-combined',
      w.combined.scored ? Number(w.combined.value).toFixed(1) : '—'));
    row.appendChild(el('span', 'score-prior-cost', fmtCost(w.totalCost)));
    list.appendChild(row);
  }
  body.push(list);
  return scoreCard(body);
}

function sessionsEl(rows) {
  const body = [scoreLabel("This Week's Sessions")];
  const list = el('div', 'score-sessions');
  for (const r of rows) list.appendChild(sessionRowEl(r));
  body.push(list);
  return scoreCard(body);
}

function sessionRowEl(r) {
  const row = el('div', 'score-session');
  const line = el('div', 'score-session-line');
  line.appendChild(gradeBadgeEl(r.grade));
  line.appendChild(el('span', 'score-session-date', new Date(r.endedAtMillis).toLocaleDateString()));
  if (r.shipped) line.appendChild(el('span', 'score-shipped-pill', 'Shipped'));
  const spacer = el('span', 'score-session-spacer');
  line.appendChild(spacer);
  line.appendChild(el('span', 'score-session-stat', fmtCost(r.totalCost)));
  line.appendChild(el('span', 'score-session-stat', fmtTime(r.activeTimeSeconds)));
  if (r.wallClockDurationSeconds != null) {
    line.appendChild(el('span', 'score-session-stat muted', '(' + fmtTime(r.wallClockDurationSeconds) + ' wall)'));
  }
  row.appendChild(line);
  if (r.grade.graded && r.grade.deductions.length) {
    row.appendChild(el('div', 'score-session-deductions',
      r.grade.deductions.map((d) => d.label + ' −' + d.points).join('  ·  ')));
  }
  return row;
}

function gradeBadgeEl(grade) {
  if (grade.graded) {
    const badge = el('span', 'score-badge', grade.letter);
    badge.style.color = gradeColor(grade.letter);
    badge.style.background = gradeColor(grade.letter) + '26'; // ~15% alpha
    return badge;
  }
  const badge = el('span', 'score-badge muted', '—');
  badge.title = 'Insufficient data';
  return badge;
}

// -- shared card helpers --
function relTime(iso) {
  if (!iso) return '';
  const then = Date.parse(iso);
  if (isNaN(then)) return '';
  const s = Math.max(0, (Date.now() - then) / 1000);
  if (s < 60) return 'just now';
  const m = s / 60; if (m < 60) return Math.floor(m) + 'm';
  const h = m / 60; if (h < 24) return Math.floor(h) + 'h';
  const d = h / 24; if (d < 30) return Math.floor(d) + 'd';
  const mo = d / 30; if (mo < 12) return Math.floor(mo) + 'mo';
  return Math.floor(mo / 12) + 'y';
}

// CROW-1030: the commit page for a stamped build SHA on the upstream repo.
// Returns null for anything that would land on a 404 — `dev` (no git at build
// time), an empty/absent stamp, or any non-hex string — so callers render inert
// text instead of a broken link. The 7–40 hex bound matches
// VersionUpdateClient.githubCompareURL, which guards the same stamp Swift-side.
const CROW_UPSTREAM_REPO = 'corveil/crow';
function crowCommitURL(sha) {
  const s = String(sha == null ? '' : sha).trim().toLowerCase();
  if (!/^[0-9a-f]{7,40}$/.test(s)) return null;
  return 'https://github.com/' + CROW_UPSTREAM_REPO + '/commit/' + s;
}

function linkChip(text, url, type) {
  // Non-http(s) urls (javascript:/data: from injected data) render as a plain,
  // non-clickable chip — never an href (review).
  const safe = /^https?:\/\//i.test(url || '');
  const a = document.createElement(safe ? 'a' : 'span');
  a.className = 'link-chip link-' + (type || 'custom');
  if (safe) { a.href = url; a.target = '_blank'; a.rel = 'noopener'; }
  a.textContent = text;
  return a;
}

// `maxVisible` caps how many pills render, with a trailing `+N` for the rest —
// the sidebar row is narrow and passes 2 (native LabelPillsView's cap). Board
// cards omit it and render every label, as before (CROW-773).
function labelPills(labels, maxVisible) {
  const wrap = el('div', 'label-row');
  const all = labels || [];
  const shown = maxVisible != null ? all.slice(0, maxVisible) : all;
  for (const l of shown) {
    const pill = el('span', 'label-pill', l.name);
    if (l.color) { pill.style.borderColor = '#' + l.color; pill.style.color = '#' + l.color; }
    wrap.appendChild(pill);
  }
  if (all.length > shown.length) {
    const more = el('span', 'label-pill label-more', '+' + (all.length - shown.length));
    more.title = all.slice(shown.length).map((l) => l.name).join(', ');
    wrap.appendChild(more);
  }
  return wrap;
}

// An empty board is just an empty list, not an error — `crowd` serves the boards
// off its own IssueTracker (CROW-581 M-C), so a "requires the
// Crow desktop app" hint would be stale post native→web migration (ADR 0010) and
// read as a false error/warning (CROW-907). Just render the caller's context
// message ("No review requests", …). NOTE: this is reachable before the first
// read lands (the pre-refresh paint at selectBoard) — a caller that must not
// conflate "not loaded yet" with "empty" gates the message itself.
function boardEmpty(msg) {
  return el('div', 'board-empty', msg);
}

// Split-button host for a start control. A chevron ctx-item is *not* inside
// `.split-btn` (the menu lives on `document.body`); the opener stashes the
// host on the menu as `_splitBtn` so we still disable both halves.
function startActionHost(el) {
  const split = (el && el.closest && el.closest('.split-btn'))
    || (el && el.closest && el.closest('.ctx-menu') && el.closest('.ctx-menu')._splitBtn)
    || null;
  const buttons = split ? [...split.querySelectorAll('button')] : (el ? [el] : []);
  return { split, buttons };
}

// A spawning action (Start Working / Start Review): disable the button, let the
// new session surface via the sidebar poll.
async function spawnAction(btn, method, params, label) {
  const { buttons } = startActionHost(btn);
  buttons.forEach((b) => { b.disabled = true; });
  const orig = btn.textContent;
  btn.textContent = 'Starting…';
  try {
    await rpc(method, params);
    btn.textContent = 'Started ✓';
  } catch (e) {
    buttons.forEach((b) => { b.disabled = false; });
    btn.textContent = orig;
    alertModal(label + ' failed: ' + (e.message || e));
  }
}

// Split-button for Start Working / Start Exploring (CROW-1149). Primary click
// runs `onPrimary`; the chevron opens a ctx-menu of the same actions. Menu
// rows receive `onClick(row)` — not the primary button — so choosing
// Explore shows Starting… / Started ✓ on that row (review #1152).
function startActionsSplit(primaryLabel, onPrimary, items) {
  const wrap = el('div', 'split-btn');
  const main = el('button', 'action-btn action-primary split-btn-main', primaryLabel);
  main.type = 'button';
  main.onclick = (e) => { e.stopPropagation(); onPrimary(main); };
  const chev = el('button', 'action-btn action-primary split-btn-chevron', '▾');
  chev.type = 'button';
  chev.title = 'More start actions';
  chev.setAttribute('aria-label', 'More start actions');
  chev.setAttribute('aria-haspopup', 'menu');
  chev.onclick = (e) => {
    e.stopPropagation();
    closeContextMenu();
    const menu = el('div', 'ctx-menu');
    menu._splitBtn = wrap;
    for (const item of items) {
      const row = el('div', 'ctx-item', item.label);
      if (item.title) row.title = item.title;
      row.onclick = (ev) => {
        ev.stopPropagation();
        // Keep the menu mounted so the chosen row can show Starting… —
        // closing it first would drop the only element whose label matches
        // the action (the primary still reads Start Working).
        [...menu.querySelectorAll('.ctx-item')].forEach((n) => {
          n.style.pointerEvents = 'none';
        });
        item.onClick(row);
      };
      menu.appendChild(row);
    }
    document.body.appendChild(menu);
    const rect = chev.getBoundingClientRect();
    const x = Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8);
    const y = Math.min(rect.bottom + 4, window.innerHeight - menu.offsetHeight - 8);
    menu.style.left = Math.max(4, x) + 'px';
    menu.style.top = Math.max(4, y) + 'px';
    armContextMenuClose();
  };
  wrap.appendChild(main);
  wrap.appendChild(chev);
  return wrap;
}

// -- Ticket Board --
// #714: shared board filter input. The board fully re-renders on each keystroke,
// so restore focus + caret after renderBoard() by re-querying the recreated
// input via its `cls`.
function boardFilterInput(cls, value, placeholder, onValue) {
  const input = document.createElement('input');
  input.type = 'text';
  input.className = 'board-filter ' + cls;
  input.placeholder = placeholder;
  input.value = value;
  input.oninput = () => {
    const selStart = input.selectionStart;
    const selEnd = input.selectionEnd;
    onValue(input.value);
    renderBoard();
    requestAnimationFrame(() => {
      const n = document.querySelector('.' + cls);
      if (n) {
        n.focus();
        const len = n.value.length;
        n.setSelectionRange(Math.min(selStart, len), Math.min(selEnd, len));
      }
    });
  };
  return input;
}

// #751: shared board <select> control (repo filter / sort). Mutates state via
// onValue then fully re-renders, mirroring boardFilterInput's flow. `options`
// is an array of [value, label] pairs.
function boardSelect(cls, options, value, onValue) {
  const sel = document.createElement('select');
  sel.className = 'board-select ' + cls;
  for (const [val, label] of options) {
    const o = document.createElement('option');
    o.value = val;
    o.textContent = label;
    if (val === value) o.selected = true;
    sel.appendChild(o);
  }
  sel.onchange = () => { onValue(sel.value); renderBoard(); };
  return sel;
}

// #751: apply the active sort. Dates are ISO-8601, so a string compare orders
// them; title is case-insensitive; status uses the PIPELINE index (Backlog→Done)
// with updated-desc as a tiebreak.
function sortIssues(issues) {
  const arr = issues.slice();
  const s = (a, b) => a.localeCompare(b);
  switch (ticketSort) {
    case 'updated_asc': arr.sort((a, b) => s(a.updated_at || '', b.updated_at || '')); break;
    case 'created_desc': arr.sort((a, b) => s(b.created_at || '', a.created_at || '')); break;
    case 'created_asc': arr.sort((a, b) => s(a.created_at || '', b.created_at || '')); break;
    case 'title_asc': arr.sort((a, b) => s((a.title || '').toLowerCase(), (b.title || '').toLowerCase())); break;
    case 'status': arr.sort((a, b) =>
      (PIPELINE.indexOf(a.project_status) - PIPELINE.indexOf(b.project_status))
      || s(b.updated_at || '', a.updated_at || '')); break;
    case 'updated_desc':
    default: arr.sort((a, b) => s(b.updated_at || '', a.updated_at || '')); break;
  }
  return arr;
}

function renderTicketBoard(root) {
  const d = boardData.tickets;
  const allIssues = (d && d.issues) || [];
  // Compose the status pipeline filter (#660) with the #714 search up front so the
  // Select button, selection pruning, and the list all operate on the same visible
  // set — no hidden ticket can be started.
  // Distinct repos for the repo filter (#751). Reset a stale selection so a
  // repo that dropped out of the payload doesn't hide the whole board.
  const repos = [...new Set(allIssues.map((i) => i.repo))].sort();
  if (ticketRepoFilter !== 'All' && !repos.includes(ticketRepoFilter)) ticketRepoFilter = 'All';

  let issues = allIssues.slice();
  if (ticketFilter !== 'All') issues = issues.filter((i) => i.project_status === ticketFilter);
  if (ticketRepoFilter !== 'All') issues = issues.filter((i) => i.repo === ticketRepoFilter);
  const q = ticketSearch.trim().toLowerCase();
  if (q) issues = issues.filter((i) => ticketHaystack(i).includes(q));
  issues = sortIssues(issues);
  // Only tickets without a linked session are startable, so only those are
  // selectable. Prune any stale selections against the *visible* set (refresh,
  // status filter, or search may have removed/hidden/linked issues).
  const selectableUrls = new Set(issues.filter((i) => !i.linked_session_id).map((i) => i.url));
  for (const url of [...selectedIssueIDs]) if (!selectableUrls.has(url)) selectedIssueIDs.delete(url);

  const head = el('div', 'board-head');
  // Spinner nests *inside* the title, where native's `ProgressView()` sat:
  // `.board-title` carries `margin-right: auto`, so a sibling would be shoved
  // to the right edge with the buttons instead (CROW-771).
  const title = el('div', 'board-title', 'Ticket Board');
  if (ticketsRefreshing()) title.appendChild(el('span', 'action-spinner'));
  head.appendChild(title);
  if (d && d.done_last_24h) head.appendChild(el('span', 'done-chip', d.done_last_24h + ' done · 24h'));
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.disabled = ticketsRefreshing();
  refresh.onclick = () => refreshTickets();
  head.appendChild(refresh);
  // Select / Cancel toggle (mirrors the native selectToggleButton). Hidden when
  // there is nothing selectable to start work on.
  if (selectableUrls.size) {
    const sel = el('button', 'action-btn' + (ticketSelectionMode ? ' nav-selecting' : ''),
      ticketSelectionMode ? 'Cancel' : 'Select');
    sel.onclick = () => {
      ticketSelectionMode = !ticketSelectionMode;
      if (!ticketSelectionMode) selectedIssueIDs.clear();
      renderBoard();
    };
    head.appendChild(sel);
  } else if (ticketSelectionMode) {
    ticketSelectionMode = false;
  }
  root.appendChild(head);

  // Batch action bar (mirrors the native batchActionBar): shown while selecting
  // with at least one ticket ticked.
  if (ticketSelectionMode && selectedIssueIDs.size) {
    const bar = el('div', 'bulk-bar');
    const n = selectedIssueIDs.size;
    bar.appendChild(el('span', 'bulk-count', n + ' ticket' + (n === 1 ? '' : 's') + ' selected'));
    bar.appendChild(el('div', 'bulk-spacer'));
    bar.appendChild(startActionsSplit(
      'Start Working (' + n + ')',
      (btn) => startSelected(btn, false),
      [
        { label: 'Start Working (' + n + ')', title: 'Worktree + implement/build prompt',
          onClick: (btn) => startSelected(btn, false) },
        { label: 'Start Exploring (' + n + ')', title: 'Same setup, read/explain-only prompt',
          onClick: (btn) => startSelected(btn, true) },
      ]));
    root.appendChild(bar);
  }

  const counts = (d && d.counts) || {};
  const bar = el('div', 'pipeline');
  for (const seg of PIPELINE) {
    const n = seg === 'All' ? (counts.All || 0) : (counts[seg] || 0);
    const cell = el('div', 'pipe-seg' + (ticketFilter === seg ? ' active' : ''));
    // Category icon + color from the shared maps, so each heading matches the sidebar
    // count for the same status (web reland of #732). 'All' stays label-only.
    if (seg !== 'All' && TICKET_STATUS_ICON[seg]) {
      const ic = icon(TICKET_STATUS_ICON[seg], 14);
      ic.style.color = TICKET_STATUS_COLOR[seg] || 'var(--text-muted)';
      cell.appendChild(ic);
    }
    cell.appendChild(el('span', 'pipe-label', seg));
    cell.appendChild(el('span', 'pipe-count', String(n)));
    cell.onclick = () => { ticketFilter = seg; renderBoard(); };
    bar.appendChild(cell);
  }
  root.appendChild(bar);

  // #751: repo filter + sort controls, composed with the status pipeline above
  // and the search below. Repo selector only appears when multiple repos exist.
  const controls = el('div', 'board-controls');
  if (repos.length > 1) {
    const repoWrap = el('label', 'board-control');
    repoWrap.appendChild(el('span', 'board-control-label', 'Repo'));
    repoWrap.appendChild(boardSelect('ticket-repo',
      [['All', 'All repos'], ...repos.map((r) => [r, r])],
      ticketRepoFilter, (v) => { ticketRepoFilter = v; }));
    controls.appendChild(repoWrap);
  }
  const sortWrap = el('label', 'board-control');
  sortWrap.appendChild(el('span', 'board-control-label', 'Sort'));
  sortWrap.appendChild(boardSelect('ticket-sort', TICKET_SORT_OPTIONS, ticketSort, (v) => { ticketSort = v; }));
  controls.appendChild(sortWrap);
  root.appendChild(controls);

  // #714: search bar below the pipeline (both act as filters). Composed with the
  // status segment above; clearing restores the full status-filtered list.
  root.appendChild(boardFilterInput('ticket-filter', ticketSearch, 'Filter tickets…', (v) => { ticketSearch = v; }));

  if (!issues.length) { root.appendChild(boardEmpty(q ? 'No matching tickets' : 'No tickets in this view')); return; }
  const list = el('div', 'card-list');
  for (const i of issues) list.appendChild(ticketCard(i));
  root.appendChild(list);
}

// #714: lowercased searchable text for a ticket — title, repo, #number, labels,
// author. Labels are {name,color} objects, so map to names (#751 fixes the old
// bug that spread the raw objects and searched "[object Object]").
function ticketHaystack(i) {
  return [i.title, i.repo, '#' + i.number, i.author || '', ...(i.labels || []).map((l) => l.name)]
    .join(' ').toLowerCase();
}

function ticketCard(i) {
  const selectable = !i.linked_session_id;
  const selecting = ticketSelectionMode && selectable;
  const isSel = selectedIssueIDs.has(i.url);
  const card = el('div', 'board-card status-accent'
    + (selecting ? ' selecting' : '') + (isSel ? ' selected' : ''));
  card.oncontextmenu = (e) => showCardMenu(e, [
    { label: 'Copy issue link', url: i.url },
    i.pr_url ? { label: 'Copy PR link', url: i.pr_url } : null,
  ]);
  const sc = TICKET_STATUS_COLOR[i.project_status] || 'var(--text-muted)';
  card.style.borderLeftColor = sc;
  // In selection mode a checkbox leads a selectable card and the whole card
  // toggles selection (mirrors the native TicketCard tap-to-select).
  if (selecting) {
    const cb = el('input', 'row-check');
    cb.type = 'checkbox';
    cb.checked = isSel;
    cb.onclick = (e) => { e.stopPropagation(); toggleIssueSelect(i.url); };
    card.appendChild(cb);
    card.onclick = () => toggleIssueSelect(i.url);
  }
  const meta = el('div', 'card-meta');
  meta.appendChild(el('span', 'repo-tag', i.repo));
  meta.appendChild(linkChip('Issue #' + i.number, i.url, 'ticket'));
  if (i.pr_number && i.pr_url) meta.appendChild(linkChip('PR #' + i.pr_number, i.pr_url, 'pr'));
  const t = relTime(i.updated_at);
  if (t) meta.appendChild(el('span', 'card-time', t));
  card.appendChild(meta);
  card.appendChild(el('div', 'card-title', i.title));

  // #751: author + created date + comment count sub-line. All fields optional
  // (older payloads / providers omit them), so render only what's present.
  const ct = relTime(i.created_at);
  if (i.author || ct || (i.comments_count != null && i.comments_count > 0)) {
    const byline = el('div', 'card-byline');
    if (i.author) byline.appendChild(el('span', 'byline-author', i.author));
    if (ct) byline.appendChild(el('span', 'byline-created',
      ct === 'just now' ? 'opened just now' : 'opened ' + ct + ' ago'));
    if (i.comments_count != null && i.comments_count > 0) {
      const c = el('span', 'byline-comments');
      c.appendChild(icon('comment', 12));
      c.appendChild(el('span', null, String(i.comments_count)));
      c.title = i.comments_count + ' comment' + (i.comments_count === 1 ? '' : 's');
      byline.appendChild(c);
    }
    card.appendChild(byline);
  }

  // #751: description excerpt (line-clamped) with an expand toggle. The full
  // (server-capped) body is present; CSS clamps it until expanded.
  if (i.body) {
    const expanded = expandedIssueURLs.has(i.url);
    card.appendChild(el('div', 'card-desc' + (expanded ? ' expanded' : ''), i.body));
    if (i.body.length > 140) {
      const toggle = el('button', 'card-desc-toggle', expanded ? 'Show less' : 'Show more');
      toggle.onclick = (e) => {
        e.stopPropagation();
        if (expanded) expandedIssueURLs.delete(i.url); else expandedIssueURLs.add(i.url);
        renderBoard();
      };
      card.appendChild(toggle);
    }
  }

  if (i.labels && i.labels.length) card.appendChild(labelPills(i.labels));
  const foot = el('div', 'card-foot');
  const statusPill = el('span', 'status-pill', i.project_status);
  statusPill.style.color = sc;
  statusPill.style.borderColor = sc;
  foot.appendChild(statusPill);
  // #751: inline PR state + CI checks (present only when a PR is linked).
  if (i.pr_state) foot.appendChild(prStateBadge(i.pr_state));
  if (i.checks && i.checks.state) foot.appendChild(checksBadge(i.checks));

  // #751: right-aligned action cluster — View Issue / View PR always, plus the
  // existing Go to Session / Start Working affordance.
  const actions = el('div', 'card-actions');
  actions.appendChild(openLinkButton('View Issue', i.url));
  if (i.pr_url) actions.appendChild(openLinkButton('View PR', i.pr_url));
  if (i.linked_session_id) {
    if (i.linked_session_is_explore) {
      actions.appendChild(el('span', 'explore-badge', 'Exploring'));
    }
    const go = el('button', 'action-btn', 'Go to Session');
    go.onclick = () => selectSession(i.linked_session_id);
    actions.appendChild(go);
  } else if (!selecting) {
    actions.appendChild(startActionsSplit(
      'Start Working',
      (btn) => spawnAction(btn, 'work-on-issue', { url: i.url }, 'Start Working'),
      [
        { label: 'Start Working', title: 'Worktree + implement/build prompt',
          onClick: (btn) => spawnAction(btn, 'work-on-issue', { url: i.url }, 'Start Working') },
        { label: 'Start Exploring', title: 'Same setup, read/explain-only prompt — no edits, no PR',
          onClick: (btn) => spawnAction(btn, 'work-on-issue', { url: i.url, explore: true }, 'Start Exploring') },
      ]));
  }
  foot.appendChild(actions);
  card.appendChild(foot);
  return card;
}

// #751: an anchor styled as an action button that opens a URL in a new tab
// (same safe-href handling as linkChip). Falls back to a disabled-looking span
// for non-http(s) urls.
function openLinkButton(text, url) {
  const safe = /^https?:\/\//i.test(url || '');
  const a = document.createElement(safe ? 'a' : 'span');
  a.className = 'action-btn open-link-btn';
  if (safe) { a.href = url; a.target = '_blank'; a.rel = 'noopener'; }
  a.textContent = text;
  a.onclick = (e) => e.stopPropagation(); // don't toggle selection in select mode
  return a;
}

// #751: PR state badge — draft / open / merged / closed, colored to match.
function prStateBadge(state) {
  const map = {
    draft: ['Draft PR', 'var(--text-muted)'],
    open: ['PR Open', 'var(--blue)'],
    merged: ['PR Merged', 'var(--purple)'],
    closed: ['PR Closed', 'var(--red)'],
  };
  const [label, color] = map[state] || ['PR ' + state, 'var(--text-muted)'];
  const b = el('span', 'pr-state-badge', label);
  b.style.color = color;
  b.style.borderColor = color;
  return b;
}

// #751: CI checks rollup badge (pass/fail/pending), with failing check names in
// the tooltip. `checks` is { state, failed:[...] }.
function checksBadge(checks) {
  let label, color;
  switch (checks.state) {
    case 'SUCCESS': label = 'CI passing'; color = 'var(--green)'; break;
    case 'FAILURE':
    case 'ERROR': label = 'CI failing'; color = 'var(--red)'; break;
    case 'PENDING':
    case 'EXPECTED': label = 'CI pending'; color = 'var(--orange)'; break;
    default: label = 'CI ' + String(checks.state).toLowerCase(); color = 'var(--text-muted)';
  }
  const b = el('span', 'checks-badge', label);
  b.style.color = color;
  b.style.borderColor = color;
  const failed = checks.failed || [];
  if (failed.length) b.title = 'Failing: ' + failed.join(', ');
  return b;
}

function toggleIssueSelect(url) {
  if (selectedIssueIDs.has(url)) selectedIssueIDs.delete(url);
  else selectedIssueIDs.add(url);
  renderBoard();
}

// Batch "Start Working (N)" / "Start Exploring (N)": ONE batch-work-on-issues
// call with every selected ticket. Explore mode passes `explore: true` so the
// Manager runs `/crow-batch-workspace --explore …` (CROW-1149). Then clear
// selection and exit selection mode.
async function startSelected(btn, explore) {
  const urls = ((boardData.tickets && boardData.tickets.issues) || [])
    .filter((i) => !i.linked_session_id && selectedIssueIDs.has(i.url))
    .map((i) => i.url);
  if (!urls.length) return;
  const { buttons } = startActionHost(btn);
  buttons.forEach((b) => { b.disabled = true; });
  btn.textContent = 'Starting…';
  const label = explore ? 'Start Exploring' : 'Start Working';
  let problem = '';
  try {
    const params = { urls };
    if (explore) params.explore = true;
    const res = await rpc('batch-work-on-issues', params);
    const rejected = (res && res.rejected) || [];
    if (rejected.length) problem = rejected.length + ' ticket(s) could not be started.';
  } catch (e) {
    problem = label + ' failed: ' + (e.message || e);
  }
  selectedIssueIDs.clear();
  ticketSelectionMode = false;
  refreshTickets();
  renderBoard();
  if (problem) alertModal(problem);
}

// In-flight refresh state (CROW-771) — restores the native `isLoadingIssues`
// spinner the web dropped in the native→web move (ADR-0010, CROW-593).
//
// Two sources, OR'd together:
//   • `boardData.tickets.loading` — the daemon's own `isLoadingIssues`, already
//     shipped by `list-tickets`. Covers the *automatic* board poll (and any
//     manual refresh outliving the client's rpc deadline), which is what the
//     native every-minute spinner showed.
//   • `ticketRefreshPending` — local, optimistic. Covers the gap between the
//     click and the first board re-read so the button reacts instantly.
//
// The web re-renders by destroy-and-rebuild, so this must live in module state
// the render functions read — DOM-only state would be wiped by `renderBoard()`.
let ticketRefreshPending = false;
let reviewRefreshPending = false;
function ticketsRefreshing() {
  return ticketRefreshPending || !!(boardData.tickets && boardData.tickets.loading);
}
function reviewsRefreshing() { return reviewRefreshPending; }

// The daemon half of the indicator has no `finally` to fall back on: it clears
// only when a *later* `list-tickets` says so. Lose contact mid-fetch — the
// daemon dies between the in-flight nudge and the completion one, or a board
// read starts failing — and nothing would ever clear it, stranding the spinner.
// So every path that loses authority over the flag drops it (CROW-771, review).
function clearDaemonRefreshFlag() {
  if (!boardData.tickets || !boardData.tickets.loading) return;
  boardData.tickets.loading = false;
  paintRefreshState();
}

// Repaint the surfaces that show the indicator. The local flags aren't part of
// `boardData`, so `refreshBoard`'s diff guard can't see them change.
function paintRefreshState() {
  renderSidebar();
  if (selectedBoard === 'tickets' || selectedBoard === 'reviews') renderBoard();
}

async function refreshTickets() {
  if (ticketRefreshPending) return; // coalesce; tracker.refresh() drops concurrent calls anyway
  ticketRefreshPending = true;
  paintRefreshState();
  try {
    try { await rpc('refresh-tickets'); } catch (_) { /* app down, or past the
      120s deadline — the daemon's own `loading` flag covers the rest; never
      leave the spinner on */ }
    // `refresh-tickets` returns before the fetch lands, so keep the settle
    // delay rather than re-reading an unchanged board.
    await new Promise((r) => setTimeout(r, 1200));
    await refreshBoard('tickets');
  } finally {
    ticketRefreshPending = false;
    paintRefreshState();
  }
}

// Reviews have no "re-poll the provider" RPC — Refresh is a daemon re-read, and
// fresh review data arrives via the poll nudge. Show the indicator for exactly
// that re-read (CROW-771).
async function refreshReviews() {
  if (reviewRefreshPending) return;
  reviewRefreshPending = true;
  paintRefreshState();
  try { await refreshBoard('reviews'); }
  finally {
    reviewRefreshPending = false;
    paintRefreshState();
  }
}

// -- Review Board --
function renderReviewBoard(root) {
  const d = boardData.reviews;
  const busy = reviewsRefreshing();

  // Filter/sort up front — before the head — so the Select button, the
  // selection pruning, and the list all see the same visible set and no hidden
  // review can be started (same ordering as renderTicketBoard).
  let reviews = ((d && d.reviews) || []).slice()
    .sort((a, b) => (b.requested_at || '').localeCompare(a.requested_at || ''));
  const q = reviewSearch.trim().toLowerCase();
  if (q) reviews = reviews.filter((r) => reviewHaystack(r).includes(q));
  // Only reviews the server would actually act on can be started, so only
  // those are selectable. Prune stale selections against the *visible* set (a
  // refresh or the search may have removed/hidden/linked a review).
  const selectableUrls = new Set(reviews.filter(reviewIsActionable).map((r) => r.url));
  for (const url of [...selectedReviewURLs]) if (!selectableUrls.has(url)) selectedReviewURLs.delete(url);

  const head = el('div', 'board-head');
  const title = el('div', 'board-title', 'Reviews');
  if (busy) title.appendChild(el('span', 'action-spinner'));
  head.appendChild(title);
  const refresh = el('button', 'action-btn', 'Refresh');
  refresh.disabled = busy;
  refresh.onclick = () => refreshReviews();
  head.appendChild(refresh);
  // Select / Cancel toggle (CROW-865, mirroring the ticket board and the
  // retired ReviewBoardView). Hidden when nothing is startable.
  if (selectableUrls.size) {
    const sel = el('button', 'action-btn' + (reviewSelectionMode ? ' nav-selecting' : ''),
      reviewSelectionMode ? 'Cancel' : 'Select');
    sel.onclick = () => {
      reviewSelectionMode = !reviewSelectionMode;
      if (!reviewSelectionMode) selectedReviewURLs.clear();
      renderBoard();
    };
    head.appendChild(sel);
  } else if (reviewSelectionMode) {
    reviewSelectionMode = false;
  }
  root.appendChild(head);

  // Batch action bar: shown while selecting with at least one review ticked.
  if (reviewSelectionMode && selectedReviewURLs.size) {
    const bar = el('div', 'bulk-bar');
    const n = selectedReviewURLs.size;
    bar.appendChild(el('span', 'bulk-count', n + ' review' + (n === 1 ? '' : 's') + ' selected'));
    bar.appendChild(el('div', 'bulk-spacer'));
    const start = el('button', 'action-btn action-primary', 'Start Review (' + n + ')');
    start.onclick = () => startReviewSelected(start);
    bar.appendChild(start);
    root.appendChild(bar);
  }

  // #714: search bar; clearing restores the full list.
  root.appendChild(boardFilterInput('review-filter', reviewSearch, 'Filter reviews…', (v) => { reviewSearch = v; }));

  // Four groups, not one flat list (CROW-982, CROW-990). The server assigns
  // every review a `group` and publishes the display order, so the board and
  // `crow list-reviews` can't disagree about which bucket a PR is in — and a
  // future fifth group needs no change here.
  //
  // Empty groups render with a zero count instead of disappearing: a reviewed
  // PR used to vanish outright, and a board that shows nothing at all can't
  // tell you *what* is empty. That silence was half the shock in #953.
  const order = (d && d.group_order)
    || ['in_review', 'not_approved_yet', 'waiting_on_author', 'recently_completed'];
  const counts = (d && d.group_counts) || null;
  const searching = !!q;
  let rendered = 0;
  for (const g of order) {
    const inGroup = reviews.filter((r) => (r.group || 'not_approved_yet') === g);
    // While searching, the counts chip would contradict the visible rows
    // (`group_counts` is unfiltered), and empty groups are just noise — so show
    // only groups with matches and count what's actually on screen. Same
    // fallback when an older daemon sends no counts at all: count the rows
    // rather than claim zero under a group that visibly has cards.
    if (searching && !inGroup.length) continue;
    const total = (searching || !counts) ? inGroup.length : (counts[g] || 0);
    const head = el('div', 'group-head');
    head.appendChild(el('span', 'group-title', reviewGroupTitle(g)));
    head.appendChild(el('span', 'group-count', String(total)));
    root.appendChild(head);
    if (!inGroup.length) {
      root.appendChild(el('div', 'group-empty', reviewGroupEmptyText(g)));
      continue;
    }
    const list = el('div', 'card-list');
    for (const r of inGroup) list.appendChild(reviewCard(r));
    root.appendChild(list);
    rendered += inGroup.length;
  }
  if (searching && !rendered) root.appendChild(boardEmpty('No matching reviews'));

  // #953 direction C: `ignoreReviewLabels` / `excludeReviewRepos` silently hid
  // real `review-requested:@me` PRs during that incident and the board looked
  // empty while GitHub's queue was not. Say so.
  const hidden = (d && d.hidden_by_filters) || 0;
  if (hidden) {
    root.appendChild(el('div', 'board-note',
      hidden + ' hidden by filters (repo/label rules in Settings → Automation)'));
  }
}

// Titles come from the server's group ids so the two clients agree on naming as
// well as on membership. Unknown ids fall back to the raw id rather than being
// dropped — a board that silently swallows a group is the bug this fixes.
function reviewGroupTitle(g) {
  return ({
    in_review: 'In review',
    not_approved_yet: 'Not approved yet',
    waiting_on_author: 'Waiting on author',
    recently_completed: 'Recently completed · 24h',
  })[g] || g;
}

function reviewGroupEmptyText(g) {
  return ({
    in_review: 'No reviews in progress',
    not_approved_yet: 'Nothing waiting on you',
    waiting_on_author: 'Nothing waiting on an author',
    recently_completed: 'Nothing finished in the last 24h',
  })[g] || 'Empty';
}

function toggleReviewSelect(url) {
  if (selectedReviewURLs.has(url)) selectedReviewURLs.delete(url);
  else selectedReviewURLs.add(url);
  renderBoard();
}

// Batch "Start Review (N)": ONE batch-start-review call with every selected PR.
// The daemon queues the kickoffs on its review serializer and acks immediately
// — each one clones a PR and spawns tmux, well past our rpc deadline — so
// the new sessions surface via the sidebar poll rather than this response
// (CROW-865). Then clear selection and exit selection mode.
async function startReviewSelected(btn) {
  const urls = ((boardData.reviews && boardData.reviews.reviews) || [])
    .filter((r) => reviewIsActionable(r) && selectedReviewURLs.has(r.url))
    .map((r) => r.url);
  if (!urls.length) return;
  btn.disabled = true;
  btn.textContent = 'Starting…';
  let problem = '';
  try {
    const res = await rpc('batch-start-review', { urls });
    const rejected = (res && res.rejected) || [];
    if (rejected.length) problem = rejected.length + ' review(s) could not be started.';
  } catch (e) {
    problem = 'Start Review failed: ' + (e.message || e);
  }
  selectedReviewURLs.clear();
  reviewSelectionMode = false;
  refreshReviews();
  renderBoard();
  if (problem) alertModal(problem);
}

// #714: lowercased searchable text for a review — title, repo, @author, #pr_number.
function reviewHaystack(r) {
  return [r.title, r.repo, '@' + r.author, '#' + r.pr_number].join(' ').toLowerCase();
}

// Whether pressing Start Review / Re-review on this card would actually do
// something (CROW-945). The server computes `kickoff_action` from the same
// decision function `createReviewSession` runs, so the button reflects the
// real verdict rather than the much weaker "does *a* session link to this PR"
// question — which is what left a re-requested PR showing only "Go to Session"
// pointing at a dead round.
//
// It also carries the server's group-level suppressions: a merged PR and a quiet
// Waiting-on-author one both come back `skip` (CROW-997), so the button and the
// batch checkbox disappear together off one field rather than off a second rule
// here that could drift from the payload's grouping.
//
// The action is an estimate: it's computed from the board's head SHA, up to a
// poll stale, while the server decides against a head it fetches itself. So it
// picks the *label* and never suppresses the RPC — the server is the decider.
// Falls back to the old predicate when the field is absent (older daemon).
function reviewIsActionable(r) {
  if (!r.kickoff_action) return !r.review_session_id;
  return r.kickoff_action === 'create' || r.kickoff_action === 're_review';
}

// The relative-time chip on a review card, labelled with the event it measures.
//
// Each group is answering a different question, and an unlabelled "2h" under
// three of them would be three different facts wearing one hat:
//   Recently completed  → when it merged/closed, or when you approved it
//   Waiting on author   → when you last reviewed it (how long the author has sat on it)
//   otherwise           → when the request last moved
// Falls through to `requested_at` whenever the specific timestamp is missing, so
// a partial payload loses the label rather than the chip.
function reviewCardTime(r) {
  if (r.group === 'recently_completed') {
    // A merged/closed PR carries `completed_at`; an approved-but-still-open one
    // doesn't, and there the approval is what put it here.
    const done = relTime(r.completed_at);
    if (done) return (r.state === 'MERGED' ? 'merged ' : 'closed ') + done;
    const approved = relTime(r.viewer_last_reviewed_at);
    if (approved) return 'approved ' + approved;
  } else if (r.group === 'waiting_on_author') {
    const reviewed = relTime(r.viewer_last_reviewed_at);
    if (reviewed) return 'reviewed ' + reviewed;
  }
  return relTime(r.requested_at);
}

function reviewCard(r) {
  // A review the board doesn't offer a kickoff for isn't selectable either — it
  // renders dimmed and checkbox-less while selecting, as the retired
  // ReviewBoardView did, but keeps its Go to Session button. One field decides
  // both, so a row can never be un-clickable yet batch-startable.
  const selectable = reviewIsActionable(r);
  const selecting = reviewSelectionMode && selectable;
  const isSel = selectedReviewURLs.has(r.url);
  const card = el('div', 'board-card'
    + (selecting ? ' selecting' : '') + (isSel ? ' selected' : '')
    + (reviewSelectionMode && !selectable ? ' not-selectable' : ''));
  card.oncontextmenu = (e) => showCardMenu(e, [{ label: 'Copy PR link', url: r.url }]);
  // In selection mode a checkbox leads a selectable card and the whole card
  // toggles selection (mirrors the ticket board).
  if (selecting) {
    const cb = el('input', 'row-check');
    cb.type = 'checkbox';
    cb.checked = isSel;
    cb.onclick = (e) => { e.stopPropagation(); toggleReviewSelect(r.url); };
    card.appendChild(cb);
    card.onclick = () => toggleReviewSelect(r.url);
  }
  const meta = el('div', 'card-meta');
  meta.appendChild(el('span', 'repo-tag', r.repo));
  const chip = linkChip('#' + r.pr_number, r.url, 'pr');
  // The chip is the only way to open the PR, and in select mode the card
  // beneath it toggles selection — don't do both on one click. Kept local to
  // reviewCard: linkChip is shared with ticketCard, whose behavior is unchanged.
  if (selecting) chip.onclick = (e) => e.stopPropagation();
  meta.appendChild(chip);
  if (r.is_draft) meta.appendChild(el('span', 'draft-badge', 'Draft'));
  // Outside the requested queue, `requested_at` (the PR's `updatedAt`) answers
  // the wrong question: under these headings you want to know when the PR
  // finished, or when you last said something about it — not when the thread
  // was last bumped.
  const stamp = reviewCardTime(r);
  if (stamp) meta.appendChild(el('span', 'card-time', stamp));
  card.appendChild(meta);
  card.appendChild(el('div', 'card-title', r.title));
  const sub = el('div', 'card-sub');
  sub.appendChild(el('span', null, '@' + r.author));
  if (r.head_branch) sub.appendChild(el('span', 'branch-tag', r.head_branch));
  card.appendChild(sub);
  if (r.labels && r.labels.length) card.appendChild(labelPills(r.labels));
  const foot = el('div', 'card-foot');
  // A linked session is still reachable even when a new round is offered —
  // "Re-review" retires that round, so the user should be able to look at it
  // first. Order: the kickoff button leads, Go to Session follows.
  if (!selecting && reviewIsActionable(r)) {
    // Suppressed while selecting — the batch bar owns the kickoff there.
    const reReview = r.kickoff_action === 're_review';
    // Both go through `start-review`: the server runs the kickoff decision and
    // completes the stale round itself, so there is one verb and one rule.
    const label = reReview ? 'Re-review' : 'Start Review';
    const rev = el('button', 'action-btn action-primary', label);
    rev.onclick = () => spawnAction(rev, 'start-review', { url: r.url }, label);
    foot.appendChild(rev);
  }
  if (r.review_session_id) {
    const go = el('button', 'action-btn', 'Go to Session');
    go.onclick = () => selectSession(r.review_session_id);
    foot.appendChild(go);
  }
  // `.card-foot` carries a top margin, so a selectable card in select mode —
  // which has no button at all — would otherwise end in 8px of dead space.
  if (foot.childNodes.length) card.appendChild(foot);
  return card;
}
