'use strict';
// Crow web UI — PR status glyph vocabulary shared by the sidebar pill and the
// detail header (CROW-773). Extracted from sidebar.js (CROW-1238).

function prBadgeColor(pr) {
  if (!pr || !pr.has_pr) return 'var(--gold)';
  if (pr.is_merged) return 'var(--purple)';
  if (pr.has_blockers) return 'var(--red)';
  if (pr.ready_to_merge) return 'var(--green)';
  return 'var(--gold)';
}

// ---------------------------------------------------------------------------
// PR status glyphs — ONE vocabulary shared by the sidebar row pill
// (`sessionRow`) and the detail header (`prStatusInline`), so the two can never
// disagree about the same PR (CROW-773).
// ---------------------------------------------------------------------------
// `icon` names an entry in ICONS: those glyphs render as monochrome SVGs that
// inherit `currentColor`, so the checkmarks tint with their label instead of
// staying black (Apple emoji ✔/✕/⚠ ignore CSS `color` — CROW-802). The
// in-progress states (checks running / needs review) and the crow:merge tag
// carry an `icon:` too, so they render as crisp SVGs at the same size as the
// check/X instead of the thin unicode ◷ / an emoji 🏷 (CROW-863). Only the
// "none/unknown" geometric glyphs (○/?) stay text — they're already
// color-faithful and read fine faint.
// `label` is the chip text in the detail header AND the sidebar pill's
// aria-label/title; an optional `a11yLabel` overrides the latter when the
// concise chip text would be ambiguous without its (unannounced) glyph
// (CROW-846). Add it only where the two channels must diverge.
const PR_CHECKS_GLYPH = {
  passing: { glyph: '✔', icon: 'check', color: 'var(--green)', label: 'Checks pass' },
  failing: { glyph: '✕', icon: 'close', color: 'var(--red)', label: 'Checks failing' },
  pending: { glyph: '◷', icon: 'clock', color: 'var(--orange)', label: 'Checks running' },
  unknown: { glyph: '?', color: 'var(--text-muted)', label: 'No checks' },
};
const PR_REVIEW_GLYPH = {
  approved: { glyph: '✔', icon: 'check', color: 'var(--green)', label: 'Approved' },
  changesRequested: { glyph: '✕', icon: 'close', color: 'var(--red)', label: 'Changes requested' },
  reviewRequired: { glyph: '◷', icon: 'eye', color: 'var(--orange)', label: 'Needs review' },
  unknown: { glyph: '○', color: 'var(--text-muted)', label: 'No reviews' },
};
const PR_MERGED_GLYPH = { glyph: '✔', icon: 'check', color: 'var(--purple)', label: 'Merged' };
const PR_CONFLICT_GLYPH = { glyph: '⚠', icon: 'warning', color: 'var(--red)', label: 'Conflicts' };
// Chip text drops the redundant "label" (the tag glyph shows it beside the
// text); the aria path keeps it via `a11yLabel` — there the glyph is never
// announced, so the noun is the only signal it's a label (CROW-846).
const PR_MERGE_LABEL_GLYPH = { glyph: '🏷', icon: 'tag', color: 'var(--gold)', label: 'crow:merge', a11yLabel: 'crow:merge label' };
// Auto-merge lifecycle — one FAMILY (the ⛙ merge mark), five COLORS for the
// five outcomes. Before #888 the row drew the same untinted ⛙ whether Crow was
// about to merge the PR or had permanently given up on it, so "armed" and
// "dead" were indistinguishable. Here the mark says "this is about auto-merge"
// and the color says which way it went.
// `detail` is the daemon's full sentence: too long for the chip, so it rides
// the tooltip/aria channel only — the same chip-vs-a11y split as
// PR_MERGE_LABEL_GLYPH (CROW-846).
const PR_AUTOMERGE_GLYPH = {
  enabled: { glyph: '⛙', icon: 'merge', color: 'var(--green)', label: 'Auto-merge on', a11yLabel: 'Auto-merge enabled' },
  merged: { glyph: '⛙', icon: 'merge', color: 'var(--purple)', label: 'Merged by Crow', a11yLabel: 'Merged by Crow' },
  stalled: { glyph: '⛙', icon: 'merge', color: 'var(--orange)', label: 'Auto-merge waiting', a11yLabel: 'Auto-merge waiting to retry' },
  blocked: { glyph: '⛙', icon: 'merge', color: 'var(--red)', label: 'Auto-merge blocked', a11yLabel: 'Auto-merge blocked' },
  off: { glyph: '⛙', icon: 'merge', color: 'var(--text-muted)', label: 'Auto-merge off', a11yLabel: 'Auto-merge watcher is off' },
};

// The auto-merge part for one row, or null when there's nothing to say.
// `am` is the live `auto_merge_state` object (absent on pre-#888 daemons);
// `enabled` is the persisted `session.auto_merge` bool, which is ALL an older
// daemon sends — so it stays the fallback rather than the primary source.
function prAutoMergeGlyph(am, enabled) {
  const base = am && am.phase && PR_AUTOMERGE_GLYPH[am.phase];
  if (base) return am.message ? Object.assign({}, base, { detail: am.message }) : base;
  return enabled ? PR_AUTOMERGE_GLYPH.enabled : null;
}

// Auto-rebase lifecycle (#944) — the ⟲ U-turn mark, two colors. Distinct from
// the ⛙ auto-merge family by ICON, not tint: color is the severity scale and
// both watchers share it, while the mark says which one is speaking.
//
// The reason this exists at all: `prStatusJSON` never ships `mergeStateStatus`,
// so a PR that is BEHIND its base renders as a fully green pill. Before #944 a
// worktree wedged in `out-of-sync-diverged` backed off forever with no surface
// but crowd-automation.log.
//
// No `enabled`/`off` phase on purpose — no PR opts into auto-rebase the way
// `crow:merge` opts into auto-merge, so silence is the default and a chip only
// ever means "Crow tried and couldn't".
const PR_AUTOREBASE_GLYPH = {
  stalled: { glyph: '⟲', icon: 'uturn', color: 'var(--orange)', label: 'Rebase waiting', a11yLabel: 'Auto-rebase waiting to retry' },
  blocked: { glyph: '⟲', icon: 'uturn', color: 'var(--red)', label: 'Rebase stuck', a11yLabel: 'Auto-rebase stuck — needs you' },
};

// The auto-rebase part for one row, or null when there's nothing to say. No
// persisted-bool fallback twin of `prAutoMergeGlyph`'s `session.auto_merge`:
// there is no per-PR auto-rebase opt-in, and an older daemon simply sends no key.
function prAutoRebaseGlyph(ar) {
  const base = ar && ar.phase && PR_AUTOREBASE_GLYPH[ar.phase];
  if (!base) return null;
  return ar.message ? Object.assign({}, base, { detail: ar.message }) : base;
}

function prChecksGlyph(pr) {
  const base = PR_CHECKS_GLYPH[pr.checks] || PR_CHECKS_GLYPH.unknown;
  // Failing checks carry their count when the daemon sent the names.
  if (pr.checks === 'failing' && pr.failed_checks && pr.failed_checks.length) {
    return { ...base, label: pr.failed_checks.length + ' failing' };
  }
  return base;
}

function prReviewGlyph(pr) {
  return PR_REVIEW_GLYPH[pr.review] || PR_REVIEW_GLYPH.unknown;
}

// The ordered glyphs for a session-row PR pill, mirroring native `PRBadge`:
// merged collapses to a single check, otherwise checks + review, plus the
// conflict and crow:merge-label markers the native pill folded into its tint,
// then what Crow's watchers did about it. The two watcher parts go LAST so the
// pill reads left-to-right as "state of the PR, then what Crow did about it",
// with auto-rebase before auto-merge because that is the order the work
// happens in — a branch gets current, then it merges. A merged PR
// short-circuits both, because their state is history.
function prBadgeParts(pr, am, autoMergeEnabled, ar) {
  if (!pr || !pr.has_pr) return [];
  if (pr.is_merged) return [PR_MERGED_GLYPH];
  const parts = [prChecksGlyph(pr), prReviewGlyph(pr)];
  if (pr.merge === 'conflicting') parts.push(PR_CONFLICT_GLYPH);
  if (pr.has_merge_label) parts.push(PR_MERGE_LABEL_GLYPH);
  const rebase = prAutoRebaseGlyph(ar);
  if (rebase) parts.push(rebase);
  const auto = prAutoMergeGlyph(am, autoMergeEnabled);
  if (auto) parts.push(auto);
  return parts;
}
