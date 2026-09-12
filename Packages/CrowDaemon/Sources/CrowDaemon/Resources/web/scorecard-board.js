'use strict';
// Crow web UI — Scorecard board (ADR 0008 / #721). Extracted from boards.js (CROW-1242).

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

