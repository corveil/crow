# 0008 — AI-usage efficiency scorecard (rate usage by efficiency + outcomes, not spend)

- **Status:** Proposed
- **Date:** 2026-07-10
- **Deciders:** @dhilgaertner, @dgershman

## Context

Most AI-usage leaderboards rank by raw spend or token count. That is a perverse incentive: it rewards volume, not value. A context-bloated session that compacted five times and shipped nothing "wins" a spend leaderboard; a tight session that closed a P0 in twenty minutes doesn't register. [#648](https://github.com/radiusmethod/crow/issues/648) asks for a rubric that rates AI usage on **efficiency**, **outcomes**, and **alignment** instead, so Crow can surface a healthier signal.

Three metric categories frame the design:

- **A. Efficiency / hygiene** (penalties/normalizers): compaction count, context accumulation (avg input per turn), cache hit ratio, cost-per-outcome, rework.
- **B. Outcomes / throughput** (rewards): sessions shipped (v1's headline), then tickets done, PRs merged, merge rate as attribution data lands.
- **C. Alignment** (weights/flags): does the work ladder up to an org KPI/goal; priority weighting.

### Data feasibility (verified against the code)

Every claim below was traced in the source; this table is the ground truth the rest of the ADR builds on.

| Metric | Data source | Status | Gap |
|---|---|---|---|
| Session cost + tokens (input/output/cacheRead/cacheCreation) | `SessionAnalytics` (`Packages/CrowCore/Sources/CrowCore/Models/SessionAnalytics.swift`), aggregated from OTLP telemetry (`CLAUDE_CODE_ENABLE_TELEMETRY=1`, local receiver in `Packages/CrowTelemetry`) | **Computable today** (in-memory) | Aggregate struct is not persisted — lives on `SessionHookState.analytics`, blank after relaunch until new telemetry arrives. Raw datapoints *are* persisted (`~/Library/Application Support/crow/telemetry.db`, 180-day retention). Telemetry is **off by default** (`AppConfig.telemetry.enabled = false`) and **Claude-Code-only** (Codex/Cursor emit no OTEL). |
| Avg input tokens per turn | `inputTokens / promptCount` from the same struct | **Computable today** (proxy) | "Turn" is proxied by `promptCount` (count of `user_prompt` events); true per-turn records are reconstructable from `telemetry.db` rows but not modeled. |
| Cache hit ratio, API error rate, active time, lines added/removed, commit count, tool calls | `SessionAnalytics` fields (`cacheReadTokens`, `apiErrorCount`/`apiRequestCount`, `activeTimeSeconds`, …) | **Computable today** | Same persistence caveat. Note `totalTokens` includes cache tokens, so it overstates billed I/O. |
| Compaction count per session | `PreCompact`/`PostCompact` hooks are registered (`Packages/CrowClaude/Sources/CrowClaude/ClaudeHookConfigWriter.swift`) and arrive session-resolved at the `hook-event` handler (`Sources/Crow/App/AppDelegate.swift`) | **Needs light plumbing** | Events land only in a 50-entry in-memory ring buffer; nothing counts or persists them. Fix is a counter incremented in the existing handler and persisted with the session analytics snapshot (follow-up 2) — not on `PersistedHookState`, whose documented contract is the color-driving UI subset. No new wiring. |
| Session wall-clock duration | `SessionStart`/`SessionEnd` hooks arrive but no timestamps are derived; `Session` persists only `createdAt`/`updatedAt` | **Needs light plumbing** | Capture start/end timestamps, or persist telemetry's `activeTimeSeconds`. |
| Tickets done | `AppState.doneIssuesLast24h`, computed in `IssueTracker.refresh()` from GitHub `state:closed` + Jira `statusCategory=Done` | **Computable today** (aggregate only) | Single viewer-scoped integer, trailing-24h, recomputed not persisted, no history; GitLab not counted. No attribution from a closed ticket back to the session that closed it. |
| Session outcome flag ("this session shipped") | `IssueTracker.markIssueDone(sessionID:)` + session `status` → `.completed` | **Computable today** | Per-action UI state; usable as a boolean outcome bit per session. |
| PRs merged / merge rate | PR state is per-item (`OPEN`/`MERGED`/`CLOSED`) via `CodeBackend.listMonitoredPRs` | **Needs new capture** | No merged-PR-per-window counter, no author/date analytics. |
| PR → session attribution | `Crow-Session:` commit trailer is written *and* parsed (`IssueTracker.extractCrowSessionUUIDs`) | **Needs new capture** | Parse result is used only as a boolean auto-merge eligibility gate over locally-known sessions; no persisted PR→session store. |
| Rework / revert / re-review churn | — | **Needs new capture** | Confirmed absent; no revert/rework/merge-rate tracking anywhere. |
| Alignment / KPI mapping, priority weighting | Session stores `ticketURL`/`ticketTitle`/`ticketNumber`; `JiraTaskBackend` reads key/summary/status/assignee/labels | **Needs new capture** (greenfield) | No epic/parent/priority/goal concept exists anywhere in the codebase. Jira priority and epic-link are not fetched. |

Two structural realities constrain the design:

1. **Crow is a single-user, local macOS app.** Every throughput query is viewer-scoped (`assignee:@me`); sessions live on one machine. "Per-user" is trivially true, and a multi-person leaderboard implies cross-machine aggregation that does not exist.
2. **Most sessions have zero countable outcomes** at any instant — exploration, in-progress work, review sessions. Any formula that divides or multiplies by outcomes is degenerate at the session grain.

## Decision

Crow rates AI usage with **two separate surfaces — a per-session A–F efficiency grade and a plain throughput count — rolled up weekly on a private, self-comparison scorecard. There is no combined score in v1.** Raw spend is displayed as context, never ranked.

### Scoring model: separate surfaces now, multiplicative later

The **efficiency grade** is a penalty-point deduction from 100 within a single unit, mapped to A–F bands. Every deduction is labeled with its cause, so the grade is a coachable sentence, not a number: *"C — 3 compactions (−15), 12% API error rate (−10)."* Additive arithmetic is fine *inside* the grade because everything is the same unit (penalty points) and each deduction is independently explainable.

The **throughput surface** is a plain count — **sessions shipped** in v1, with ticket/PR counts joining once attribution data exists (follow-ups 5–6) — shown alongside, never multiplied into the grade in v1.

The strawman from #648 — `throughput × efficiency-multiplier × alignment-weight` — is the right **v2** shape, and this ADR names its trigger conditions: adopt it **only after** PR→session attribution (follow-up 5), rework tracking (6), and alignment tagging (8) exist and the headline unit is per-user-per-week. Multiplicative is correct *then* because it makes waste un-buyable with volume — an additive combination lets high throughput mask terrible hygiene, which recreates the raw-spend-leaderboard failure with extra steps. It is wrong *now* because at session grain the throughput factor is usually zero, producing unstable, unexplainable scores.

### Unit, window, surface

- **Unit:** the **session** is the atomic graded unit — it is the natural grain of every verified field. Sessions with fewer than ~5 prompts are shown as *insufficient data*, not graded.
- **Window:** the headline view is a **weekly rollup** (smooths small samples, absorbs session-splitting); per-session grades are the drill-down. The weekly grade **re-aggregates raw numerators and denominators** across the week's sessions (Σ compactions / Σ active hours, Σ input tokens / Σ prompts, …) — it is *not* an average of per-session grades, which would let many short clean sessions dilute one disastrous one and reintroduce the session-splitting incentive.
- **Surface:** a **private scorecard, not a leaderboard**. The comparison baseline is the user's own trailing 4-week median — "this week vs. your normal." A leaderboard of one user is meaningless, and leaderboards maximize gaming incentive for minimum informational value. The intended audience of the grade is **the user themself**; this is a design constraint, and any future team leaderboard proposal must supersede this ADR explicitly rather than quietly repurposing the scorecard as a surveillance instrument.

### v1 metrics (all formulas from verified fields)

| Metric | Formula | Role |
|---|---|---|
| Compaction count | new persisted counter (increment on `PostCompact` — a *completed* compaction — in the existing hook handler; persisted with the analytics snapshot) | graded — heaviest penalty |
| Context pressure | `inputTokens / max(1, promptCount)` | graded |
| Cache hit ratio | `cacheReadTokens / max(1, inputTokens + cacheCreationTokens)` | graded |
| API error rate | `apiErrorCount / max(1, apiRequestCount)` | graded |
| Cost per shipped session | weekly grain only: `Σ totalCost / sessionsShipped`; a week with `sessionsShipped == 0` is **not graded** on this metric (shown as "insufficient outcomes"), never divided by 1 | graded (weekly) |
| Session outcome flag | ticket reached done via `markIssueDone` / status → `.completed` | throughput surface |
| Sessions shipped (week) | count of outcome-flagged sessions in the window, derived from persisted per-session snapshots (follow-up 2) | throughput surface — the weekly headline |
| Churn hint | `linesRemoved / max(1, linesAdded)` | informational only (too weak as a rework proxy to grade) |
| Cost, active time, commits | `totalCost`, `activeTimeSeconds`, `commitCount` | displayed, not graded |

Two definitional notes:

- **Cache hit ratio deliberately reinterprets #648.** The issue framed a high cache-read:output ratio as a bloated-context smell ("should have been split/reset"). This ADR grades the opposite polarity on a different denominator: a high cache-read *share of context* (`cacheRead / (input + cacheCreation)`) means the context being carried is served from prompt cache rather than re-sent as fresh input — the cheap way to carry context. The bloat smell #648 was pointing at is captured by the metrics that measure *how much* context is carried: context pressure and compaction count. Graded polarity: higher hit ratio = better.
- **`doneIssuesLast24h` is not a scorecard input.** It is viewer-scoped, trailing-24h, includes tickets closed outside any Crow session, and is recomputed with no history — it stays as the existing board badge, nothing more. The scorecard's throughput metric is **sessions shipped**, which is session-attributed and computable weekly precisely because follow-up 2 persists per-session snapshots.

### Grade bands are tunable priors, not gospel

Starting heuristics — stored as named constants, revised against real distributions after an explicit **4-week calibration period**:

- Compactions: normalized **per active hour**, 0 = no deduction, scaling penalty above. The authoritative clock for all penalty normalization is telemetry's `activeTimeSeconds`; wall-clock session duration (follow-up 4) is displayed for context but never a penalty denominator (an idle-overnight session shouldn't launder its compactions).
- API error rate: < 2% clean, > 10% heavy deduction.
- Cache hit ratio: > 0.7 good (high cache-read share means context is being reused, not re-sent).
- Context pressure: flag a rising within-session trend rather than an absolute cutoff, once per-turn data exists; until then a per-session average threshold.

The calibration period is binding: if real data says a threshold punishes legitimately hard sessions, the threshold moves.

### Anti-gaming guardrails (design-level)

- The headline is **weekly**, and compaction/context penalties are normalized **per active hour** — never per session (splitting one long session into three short ones doesn't reset the denominator) and never per outcome (the ADR's own zero-outcome argument applies to penalties too). Outcomes enter the grade only through the weekly cost-per-outcome metric.
- The **minimum-sample floor** (< ~5 prompts → ungraded) prevents farming A-grades with trivial sessions.
- **Cost-per-outcome is computed only at weekly grain**, so outcome-free sessions neither score nor dodge.
- **No combined number exists in v1** — there is nothing to farm.

Deferred guardrails (explicit non-goals until their data exists): trivial-PR farming detection (needs PR size + rework data), revert/merged-vs-closed-rate signals, alignment-tag misuse.

## Rollout & follow-ups

**v1 = follow-ups 1–4 plus a read-only scorecard** computing/presenting the table above. Everything else is deferred, in dependency order:

| # | Follow-up ticket | Scope | Blocks |
|---|---|---|---|
| 1 | Fix telemetry aggregation-temporality handling | Handle delta vs. cumulative **at ingest**: `OTLPSum.aggregationTemporality` is parsed but dropped — the metrics table has no temporality column, so a query-time check in `sumMetric` is impossible with the current schema. Either normalize cumulative datapoints to deltas on insert, or persist a temporality column and account for it in aggregation. **Prerequisite for trusting any token/cost metric; grades ship behind this fix.** | v1 |
| 2 | Persist a `SessionAnalytics` snapshot at session end | Durable per-session record so weekly rollups and the 4-week baseline survive relaunch (today the aggregate is in-memory; only raw rows persist). | v1 |
| 3 | Persist a per-session compaction counter | Increment on `PostCompact` (completed compactions only — a failed/aborted compaction isn't graded waste) in the existing hook handler; persist with the session analytics snapshot from ticket 2, not on `PersistedHookState` (its documented contract is the color-driving UI subset and should stay that way). | v1 (depends on 2) |
| 4 | Persist session wall-clock duration | Capture `SessionStart`/`SessionEnd` timestamps on the session model. | v1 |
| 5 | PR→session attribution store | Persist `extractCrowSessionUUIDs` results; merged-PR-per-window counts per session (today the trailer parse is a discard-after-use auto-merge gate). | v2, 6 |
| 6 | Rework / merge-rate metrics | Revert detection, merged-vs-closed PR rate, post-merge-fix tracking. | v2 |
| 7 | Per-turn analytics reader | Model turns from `telemetry.db` raw rows instead of `promptCount` proxies; enables within-session context-trend detection. | — |
| 8 | Alignment / KPI mapping | Extend `JiraTaskBackend` to read priority + epic/parent; org-goal tagging on sessions; alignment weight. Greenfield. | v2 |
| 9 | GitLab throughput parity | Include GitLab in done-ticket counting. | — |
| 10 | Cross-machine aggregation + team surface | Prerequisite for any leaderboard; out of scope here. | — |
| 11 | Combined multiplicative score (v2) | `alignment-weighted throughput × efficiency multiplier`, per-user-per-week. | blocked on 5, 6, 8 |

No prototype ships with this ADR: the smallest useful one requires persisting the compaction counter (a write-path model change, follow-up 3), which exceeds the read-only bar for a design PR.

## Consequences

- **Goodhart risk is inherent.** Any graded metric will be optimized; the compaction penalty may discourage legitimately long, hard sessions. The tunable-priors + calibration-period framing is the mitigation, and it is binding, not decorative.
- **No task-difficulty normalization.** A hard ticket grades worse than an easy one at session grain; weekly aggregation only partially washes this out. Fairness improves with alignment/priority data (follow-up 8).
- **Claude-Code-only, opt-in.** Grades cover only sessions running Claude Code with telemetry enabled (off by default). Sessions on other agent backends are invisible.
- **"Done" ≠ value** until alignment weighting exists; closing low-value tickets counts the same as closing important ones in v1.
- **Data trust gates the launch.** Token sums may double-count until the temporality fix (follow-up 1) lands.
- **Cold start.** The self-comparison baseline needs ~4 weeks of history before "vs. your normal" means anything.
- **What we gain:** a coachable, gaming-resistant signal built almost entirely on data Crow already captures, with a clearly staged path to the richer combined score once attribution, rework, and alignment data exist.

## Alternatives considered

- **Multiplicative combined score now** (the #648 strawman). Rejected for v1 — divides/multiplies by outcomes that are usually zero at session grain, producing unstable, unexplainable scores; adopted as the named v2 shape instead.
- **Additive score with penalties.** Rejected — mixes incommensurable units (dollars, tickets, compactions) under arbitrary weights, invites endless weight-tuning debates, and lets volume mask bad hygiene.
- **Raw-spend leaderboard.** Rejected — the perverse incentive this ADR exists to avoid.
- **Per-session combined score.** Rejected — same zero-outcome degeneracy as multiplicative-now, at the grain where it is worst.
- **Team leaderboard as the primary surface.** Rejected — meaningless for a single-user app, maximally gameable, and blocked on cross-machine aggregation (follow-up 10).

## References

- Ticket: [#648](https://github.com/radiusmethod/crow/issues/648)
- PR: [#657](https://github.com/corveil/crow/pull/657)
- Related ADRs: [0005](./0005-task-and-code-backend-protocols.md) (backend protocols the throughput/alignment follow-ups build on)
- Code (verified for the feasibility table):
  - `Packages/CrowCore/Sources/CrowCore/Models/SessionAnalytics.swift`
  - `Packages/CrowCore/Sources/CrowCore/AppState.swift` (`SessionHookState`, `PersistedHookState`, `doneIssuesLast24h`)
  - `Packages/CrowTelemetry/Sources/CrowTelemetry/` (`OTLPReceiver.swift`, `Storage/TelemetryDatabase.swift`)
  - `Packages/CrowClaude/Sources/CrowClaude/ClaudeHookConfigWriter.swift`, `ClaudeCodeAgent.swift`
  - `Sources/Crow/App/AppDelegate.swift` (hook-event handler), `Sources/Crow/App/IssueTracker.swift` (done counting, `Crow-Session:` trailer parse)
