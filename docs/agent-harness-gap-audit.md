# Harness capability gap audit

**Status:** Living audit — re-run when upstream CLIs bump major/minor versions.
**Baseline:** the capability matrix + capability-tiers ADR proposed in [#827](https://github.com/corveil/crow/issues/827) (still open at audit time; its matrix table and its verbatim version-pinned "why"s are the checklist below).
**Audit ticket:** [#828](https://github.com/corveil/crow/issues/828).
**Audited:** 2026-07-23.

The Cursor / Codex / OpenCode adapters were written against specific upstream CLI
versions, and several matrix cells were marked ❌ / ⚠️ with a version-pinned reason
("no `--continue` equivalent in MVP", "Codex hooks sync-only as of v0.139.0",
"Review returns `nil` — Phase C"). Those CLIs move fast. This document re-checks
each pinned reason against the **currently installed** upstream binaries and their
docs, and records — per harness × dimension — **still absent** vs **now available**
(upstream flag + min version + link + recommended closing approach).

No runtime code changed in this audit. Closures are tracked as spin-off tickets
(see [§4](#4-spin-off-tickets)).

---

## 1. Versions audited

These are the builds **installed on the audit machine** (each `--version` verbatim
below), probed via `<binary> --help`. They are **not** necessarily latest-upstream —
several trail stable by a minor or two as of the audit date, and a verdict in §2/§3
can already have moved when the installed build is behind. The `Upstream latest`
column records where stable was on 2026-07-23 so a re-runner knows which rows to
re-probe; the OpenCode row is exactly where a stale build bit this audit (see §3c).

| Harness | Binary | Installed (`--version`) | Upstream latest @ 2026-07-23 | Adapter written against |
|---|---|---|---|---|
| Claude Code | `claude` | `2.1.206 (Claude Code)` | `2.1.218` | baseline (mostly ✅) |
| Cursor | `agent` / `cursor-agent` | `2026.07.23-e383d2b` | (rolling; audit build is same-day) | pre-resume/print MVP |
| OpenAI Codex | `codex` | `codex-cli 0.141.0` | `rust-v0.145.0` (2026-07-21) | comments pin `v0.139.0` |
| OpenCode | `opencode` | `1.17.10` | `v1.18.4` (2026-07-20) | CROW-545/547 MVP |

> **Reproducing:** flag/version claims below are cited to each installed CLI's own
> `--help`. Where a claim depends on a version the audit build predates, it is cited
> to the upstream tag instead (e.g. `sst/opencode` `tui.ts@v1.18.4`). Re-run the
> probes after any `codex`/`opencode`/`agent` upgrade; the OpenCode auto-permission
> surface in particular flipped twice across `v1.17`→`v1.18`.


---

## 2. Re-verification of every version-pinned reason (acceptance criterion)

Each row is a pinned "why" enumerated in [#827](https://github.com/corveil/crow/issues/827)
Deliverable 3, re-checked against §1. **Verdict** is `NOW AVAILABLE` (upstream grew
the feature after the adapter was written) or `STILL ABSENT` (pin holds; update only
the stale version reference).

| # | Pinned reason (from #827 tiers ADR seed) | Verdict | Evidence |
|---|---|---|---|
| 1 | Codex review unsupported → `nil` ("Phase C; `/crow-review-pr` is Claude-only") | ✅ **NOW AVAILABLE** | `codex review [--base BRANCH] [--commit SHA] [--uncommitted] [--title]` (TUI entry point) and `codex exec review` (the non-interactive one). Either works from a Crow terminal. |
| 2 | Codex / Cursor no resume ("no `--continue` equivalent in MVP") | ✅ **NOW AVAILABLE (both)** | Codex: `codex resume [SESSION_ID] [--last] [--all]` + `codex fork`. Cursor: `agent --resume [chatId]`, `agent --continue`, `agent resume`, `agent ls`. |
| 3 | Codex `supportsRemoteControl=false` (no RC flag); Cursor/OpenCode fake RC via `crow send` stdin | ⚠️ **PARTIAL** | Codex now has experimental `codex remote-control {start,stop}` (app-server daemon) + `codex --remote <ws://…>` to connect a TUI to a remote app server. OpenCode has `opencode serve` (headless server) + `opencode attach <url>` + `opencode acp` (Agent Client Protocol) + `opencode web`. Both are *native* remote surfaces that could retire the stdin fake, but both are heavier than the current `crow send` paste — see closing approach. |
| 4 | Codex hooks sync-only ("as of v0.139.0; async breaks state detection") | ❌ **STILL ABSENT** | `async: true` is still **parsed but skipped** upstream at HEAD (~`0.146-alpha`), not just 0.141.0 — refresh the pin. [`discovery.rs:480`](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/engine/discovery.rs) logs `"async hooks are not supported yet"` for every event **except `SessionEnd`**, which is kept but downgraded to synchronous (`discovery.rs:503`, `"running async SessionEnd hook synchronously"`). So no fire-and-forget async for the events Crow's state machine needs; `asyncEvents` stays `[]`. [Codex hooks docs](https://developers.openai.com/codex/config-advanced) |
| 5 | Auto-permission only Claude (`--permission-mode auto`) + OpenCode (runtime-probed `--auto`) | ✅ **NOW AVAILABLE (Cursor + Codex)** | Cursor (`cursor-agent --help`): `-f/--force`, `--yolo` (alias), `--approve-mcps`, `--trust`, `--sandbox` (`--auto-review` also present in `--help` — see §3a caveat). Codex: `-a/--ask-for-approval never` + `-s/--sandbox workspace-write` (bounded; the recommended default), or the full-bypass `--dangerously-bypass-approvals-and-sandbox` / `-s danger-full-access` (**not** recommended — §3a/§3b). OpenCode is **not** broken today: `OpenCodeLaunchArgs.runAutoApproveSuffix` probes `--auto` first and **falls back to** `--dangerously-skip-permissions` on the `run` path; only the separate `tuiSupportsAuto` top-level `--auto` probe was dead weight on `v1.17.x`, and `v1.18.0` re-added TUI `--auto` anyway (§3c). |
| 6 | MCP Claude-only (Jira via `~/.claude.json`) | ✅ **NOW AVAILABLE (all three)** | `codex mcp {list,get,add,remove,login,logout}` + `codex mcp-server`; `cursor-agent mcp`; `opencode mcp`. |
| 7 | Non-Claude hooks global-scope, session resolved by `cwd` match (no per-session UUID) | ✅ **NOW AVAILABLE (all three)** | Codex: project `.codex/hooks.json` or inline `[hooks]` in `.codex/config.toml` (trusted-project scoped — see the trust-gate warning in §3b). Cursor: project `.cursor/hooks.json`. OpenCode: project `.opencode/plugins/` (Crow's writer's dir; upstream globs `{plugin,plugins}` per `plugin.ts@v1.18.4:21`, so both spellings load). All three can now carry a per-worktree config with Crow's session UUID baked into the command — the same shape as Claude's `.claude/settings.local.json` — closing the shared-`cwd` collision. |
| 8 | Capability availability gated on binary registration | ✅ **UNCHANGED (by design)** | Not a gap. `AgentRegistry` still registers a kind only if `findBinary()` resolves; that's the intended contract (ADR seed, #827 Deliverable 2). No re-check needed. |

**Net:** of the seven genuine gaps, **rows 1, 2, 5, 6, 7 are now available** upstream,
**row 3 is partial** (native RC exists but is heavier than the working stdin fake),
and **row 4 still holds** (Codex async hooks parsed-but-skipped). Row 8 is not a gap.

---

## 3. Per harness × dimension

Legend: ✅ now available upstream · ⚠️ partial / caveated · ❌ still absent.
Claude Code is the baseline and omitted except where it frames the target shape.

### 3a. Cursor (`agent` 2026.07.23)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ❌ "no `--continue` in MVP" | ✅ | `agent --continue`, `agent --resume [chatId]`, `agent resume`, `agent ls` (landed [CLI Jan 16 2026](https://cursor.com/changelog/cli-jan-16-2026): `/list`→`/resume`) | On `.job`/`.review` restart, replace the bare `agent` fallback in `CursorAgent.autoLaunchCommand` with `agent --continue`, so re-open restores history instead of a cold TUI. |
| Non-interactive / headless | ❌ (TUI only) | ✅ | `-p/--print` with `--output-format text\|json\|stream-json` ([CLI docs](https://cursor.com/docs/cli/using)) | Use `agent -p --output-format stream-json` for unattended `.job`s and for review, so Crow can parse structured completion instead of scraping the TUI. |
| Auto-permission | ❌ ignored | ✅ | `-f/--force`, `--yolo` (alias for `--force`), `--sandbox <enabled\|disabled>`, `--approve-mcps`, `--trust` — all in `cursor-agent --help` (2026.07.23) and the [CLI parameter reference](https://cursor.com/docs/cli/reference/parameters). `--auto-review` ("Smart Auto: a server classifier auto-runs safe tool calls, prompts for the rest") is present in `--help` on this build but **not yet in the web reference** — treat as unverified/unstable until documented. | For `.job` + `autoPermissionMode`, pair `--force --sandbox enabled` — **approval off, sandbox still on** — as the bounded default (the analogue of §3b's `-a never -s workspace-write`). Bare `--force`/`--yolo` (approve *and* no sandbox) is the unbounded posture §3b warns against; don't use it as the default. Do **not** reach for the undocumented `--auto-review` until it's in the reference. `--trust` seeds workspace trust (≈ Claude gateway trust seed) but is headless-mode only per the reference. |
| MCP (e.g. Jira) | ❌ | ✅ | `cursor-agent mcp` subcommand | Reuse the Jira MCP config Crow already writes for Claude; register it via `cursor-agent mcp add`. |
| Hook scope (per-session) | ❌ global `~/.cursor/hooks.json`, cwd-match | ✅ *(caveat)* | project `.cursor/hooks.json` (hooks landed [CLI Jan 16 2026](https://cursor.com/changelog/cli-jan-16-2026)) | Write per-worktree `.cursor/hooks.json` with the Crow session UUID in the command (mirror `ClaudeCodeAgent`). **Caveat:** community reports the CLI only fires a subset of events (`beforeShellExecution`/`afterShellExecution`, session start/end/prompt/stop) — verify event coverage against `CursorSignalSource`'s state machine before ripping out the cwd-match. |
| Prompt injection / launcher auto-wire | ⚠️ launcher not auto-wired; `.work` drops into bare TUI | ✅ | positional prompt already works (`agent "<prompt>"`); print mode gives a clean injection surface | With `-p`/`--print` for jobs and positional prompt for `.work`, `CursorLauncher.generatePrompt` output can finally be fed at launch instead of leaving a bare TUI. |
| Remote control | ⚠️ faked via `crow send` stdin | ⚠️ (no dedicated local RC socket) | — | No change recommended; `crow send` paste remains the simplest driver. `supportsRemoteControl=true` stays correct. |

### 3b. OpenAI Codex (`codex` 0.141.0)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ❌ "no `--continue` in MVP" | ✅ | `codex resume [SESSION_ID\|--last\|--all]`, `codex fork`, `codex exec resume --last` | On `.job`/`.work` restart, replace bare `codex` with `codex resume --last` (or resume by recorded session id) so re-open restores the thread. |
| Review (`/crow-review-pr`) | ❌ `nil` — "Phase C, Claude-only" | ✅ | `codex review [--base BRANCH\|--commit SHA\|--uncommitted] [--title]`; `codex exec review` | Return a real command from the `.review` branch of `autoLaunchCommand`: `codex review --base main` (or the PR base), replacing the `nil` + `⚠️` echo. Inlined-skill brief no longer needed for the review *itself*. |
| Non-interactive / headless + auto-permission | ❌ ignored | ✅ | `codex exec [PROMPT]` (non-interactive); approval knobs `-a/--ask-for-approval never`, `-s/--sandbox {read-only,workspace-write,danger-full-access}`, `--dangerously-bypass-approvals-and-sandbox` | For `.job` + `autoPermissionMode`, dispatch `codex exec "$(cat …prompt)" -a never -s workspace-write` — **approval off, sandbox still bounded** — as the recommended default (matches Claude's `--permission-mode auto`, not a full escape). Do **not** reach for `--dangerously-bypass-approvals-and-sandbox` or `-s danger-full-access`: they disable the workspace sandbox entirely and are only appropriate inside an already-externally-sandboxed runner. Treat the full-bypass variants as not-recommended, not interchangeable with the bounded default. |
| MCP (e.g. Jira) | ❌ | ✅ | `codex mcp {list,add,get,remove,login,logout}`; `codex mcp-server` (Codex as MCP server) | Register the Jira MCP via `codex mcp add`; parity with Claude's `~/.claude.json` MCP. |
| Hook scope (per-session) | ❌ global `~/.codex/hooks.json`, no-op per-session writer, cwd-match | ✅ *(trust caveat)* | project `.codex/hooks.json` **or** inline `[hooks]` in `.codex/config.toml`; loads only in **trusted** projects (hooks stable [v0.124.0, Apr 2026](https://developers.openai.com/codex/config-advanced)) | Make `CodexHookConfigWriter.writeHookConfig` non-nop: write a per-worktree `.codex/hooks.json` carrying `--session <uuid>`, then get the project layer trusted. **⚠️ Do not auto-seed trust with `--dangerously-bypass-hook-trust`:** Codex's trusted-project gate exists precisely so a *cloned* repo's committed `.codex/hooks.json` doesn't execute on checkout. A blanket bypass would run any hostile/compromised repo's committed hooks on Crow session start, for every repo Crow opens. Instead **persist trust for the specific worktree** so only Crow's own written config runs. Also unlike Claude's gitignored `.claude/settings.local.json`, `.codex/hooks.json` is not conventionally gitignored, so a repo may already ship one — **#830 must resolve the merge/overwrite question** (preserve user entries, like the existing global writer does) rather than clobber it. |
| Hook async | ❌ sync-only (pinned v0.139.0) | ❌ **still** (pin refreshed) | `async:true` parsed-but-skipped at HEAD (~`0.146-alpha`), not just v0.141.0 — `discovery.rs:480`. Carve-out: async `SessionEnd` is kept but run synchronously (`discovery.rs:503`); every other event's async hook is skipped. | **Deferred** — the events Crow's state machine relies on have no working async path; keep `asyncEvents` empty. Re-check on a future Codex minor (refresh the pin, note the SessionEnd exception). |
| Remote control | ❌ `supportsRemoteControl=false` | ⚠️ experimental | `codex remote-control {start,stop}` (app-server daemon) + `codex --remote <ws://…>` | Flip `supportsRemoteControl=true` **only** once the experimental app-server path is validated end-to-end; until then the badge stays off. Lower priority than resume/review — the stdin paste isn't available for Codex's TUI the way it is for Cursor/OpenCode, so this is the one harness where native RC actually adds a capability. |
| Notify bridge | via `~/.codex/hooks.json` + `notify` | ⚠️ possibly redundant | first-class hooks now stable | Once per-worktree hooks land, evaluate retiring the `notify`→`CodexNotifyCommand` bridge in favor of a `Stop`/`SessionEnd` hook. **Folded into #830** as a stretch item (see §4). |

### 3c. OpenCode (`opencode` 1.17.10 installed; ≥1.18 for auto-permission — see note)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ✅ **already shipped (#547)** | ✅ | TUI `-c/--continue`, `-s/--session <id>`, `--fork`; same on `opencode run` | **The "no history" caveat is already closed in-repo** — `resumeTUICommand` (`OpenCodeLaunchArgs.swift:118`) returns `opencode --continue` and `firstLaunchChainedCommand` (`:113`) chains `; opencode --continue`; there is no bare-`opencode` resume fallback. Genuine remainder, not "resume with history": (a) **`--session <id>` targeting** — Crow only uses `--continue` (last session), never resumes a *specific* session id, so a stale/interleaved last-session could be reopened; (b) `.work` sessions deliberately launch bare (`OpenCodeAgent.swift:81`, "user types their prompt into the TUI") — resuming them is a product choice, not a missing flag. |
| Auto-permission (probe) | ⚠️ runtime `--help` probe for `--auto`, job-only | ✅ *(surface unstable)* | The `run` path already works today: `OpenCodeLaunchArgs.runAutoApproveSuffix` probes `--auto` first, else `--dangerously-skip-permissions` (present on `opencode run` at `v1.17.10`). The **TUI** `--auto` surface flipped twice across two minors: absent in the `v1.17.x` window (verified `tui.ts@v1.17.10`), then **re-added in `v1.18.0`** (2026-07-14, before this audit) — [`tui.ts@v1.18.4`](https://github.com/sst/opencode/blob/v1.18.4/packages/opencode/src/cli/cmd/tui.ts) exposes `--auto`, `--yolo`, **and** `--dangerously-skip-permissions` (`auto: args.auto \|\| args.yolo \|\| args["dangerously-skip-permissions"]`). | **Do not hard-code a single flag name.** The earlier "retire the probe, hard-code `--dangerously-skip-permissions`" advice was scoped to `v1.17.x`, where TUI `--auto` was gone; upstream re-added it a minor later, so a hard-coded name is *more* brittle than the probe. `runAutoApproveSuffix`'s "try `--auto`, else `--dangerously-skip-permissions`" fallback is the resilient shape — keep it. **Note the blast radius:** `--dangerously-skip-permissions` auto-approves *all* non-denied tool calls (no sandbox knob analogous to Codex's `-s`), so it's a full escape — scope it to `.job` + `autoPermissionMode` only, as the adapter already does. The one true dead-weight is `tuiSupportsAuto`'s top-level `--auto` probe **on `v1.17.x` only**; on ≥`1.18` it matches again. #831 should *narrow* the probe (or make it version-aware), not delete it. |
| MCP (e.g. Jira) | ❌ | ✅ | `opencode mcp` subcommand | Register Jira MCP via `opencode mcp`; parity with Claude. |
| Hook scope (per-session) | ❌ global `~/.config/opencode/plugins/`, cwd-match | ✅ | project `.opencode/plugins/` (project-scoped plugins; project config overrides global). Upstream globs `{plugin,plugins}` ([`plugin.ts@v1.18.4:21`](https://github.com/sst/opencode/blob/v1.18.4/packages/opencode/src/config/plugin.ts#L18-L29)) so either spelling loads — Crow's writer uses `plugins/`. | Install the `crow-hooks.js` plugin into the **worktree's** `.opencode/plugins/` with the session UUID baked in, instead of the global dir. Matches the existing `OpenCodeHookConfigWriter` dir name (`plugins/`, `OpenCodeHookConfigWriter.swift:71`). Closes the shared-cwd collision. |
| Remote control | ⚠️ faked via `crow send` stdin | ⚠️ native option exists | `opencode serve` (headless server) + `opencode attach <url>` + `opencode acp` (Agent Client Protocol) + `opencode web` | No change recommended near-term; `crow send` paste is simpler than standing up a server per session. `supportsRemoteControl=true` stays correct. Note ACP as the strategic option if Crow ever wants structured (non-paste) driving. |
| Review | ✅ inlined skill (already works) | ✅ | `opencode run` + inlined skill; also `opencode github` / `opencode pr <n>` | No change needed. `opencode pr <number>` could simplify PR-checkout for review jobs later. |

> **Version note (auto-permission):** the installed build was `1.17.10`; the analysis
> above is cited to upstream `sst/opencode` tags because the auto-permission surface
> is only correct if you know which side of the `v1.17`→`v1.18` boundary you're on.
> Re-probe against the actually-installed build before implementing #831.

---

## 4. Spin-off tickets

Each closeable gap is grouped by harness (that's the natural implementation unit —
a single adapter + its launcher + hook writer + tests change together).

| Ticket | Scope | Closes |
|---|---|---|
| [#829](https://github.com/corveil/crow/issues/829) — Cursor closures | resume (`--continue`/`--resume`), print-mode jobs/review (`-p`), auto-permission (bounded `--force --sandbox enabled` — **not** bare `--force`/`--yolo`; `--trust` headless-only; **not** the undocumented `--auto-review`), MCP (`cursor-agent mcp`), per-project `.cursor/hooks.json`, auto-wire `CursorLauncher` | §3a rows 1–6 |
| [#830](https://github.com/corveil/crow/issues/830) — Codex closures | resume (`codex resume --last`), review (`codex review`), non-interactive `codex exec` + auto-approve (`-a never -s workspace-write`, bounded — **not** full-bypass), MCP (`codex mcp`), per-project `.codex/hooks.json` (persist per-worktree trust — **not** `--dangerously-bypass-hook-trust`; resolve merge-vs-clobber), retire `notify` bridge, evaluate experimental `remote-control` | §3b rows 1–5, 7, 8 |
| [#831](https://github.com/corveil/crow/issues/831) — OpenCode closures | MCP (`opencode mcp`), per-project `.opencode/plugins/`; **narrow (do not delete) the auto-permission probe** — TUI `--auto` was gone only in `v1.17.x` and returned in `v1.18.0`, so keep `runAutoApproveSuffix`'s fallback and make the probe version-aware. **Resume-with-history is already shipped (#547)** — the only remainder is `--session <id>` targeting + whether `.work` should resume (both optional). | §3c rows 1–4 |

**Deferred (no ticket):**
- **Codex async hooks** (§2 #4 / §3b) — upstream still parses-but-skips `async:true` at HEAD (~`0.146-alpha`), except `SessionEnd` which runs synchronously; nothing to wire for Crow's state events. Re-check on a future Codex minor.
- **Cursor / OpenCode native RC** (§3a, §3c RC rows) — native surfaces exist (`--remote`, `serve`/`attach`/`acp`) but are heavier than the working `crow send` paste; no user-facing capability gained today.

Spin-off tickets are opened against `corveil/crow` and reference this audit + [#828](https://github.com/corveil/crow/issues/828).

---

## 5. Matrix + tiers-ADR reconciliation (pending #827)

[#827](https://github.com/corveil/crow/issues/827)'s `docs/agent-harness-matrix.md` and
the capability-tiers ADR are **not yet merged**, so there is nothing in-repo to edit.
When #827 lands, apply these corrections from §2 so no stale "why" survives:

- **Resume** row: Cursor ❌→✅ (`--continue`/`--resume`), Codex ❌→✅ (`codex resume`), OpenCode ⚠️→✅-with-history.
- **Auto-permission** row: Cursor ❌→✅, Codex ❌→✅; rewrite OpenCode's "runtime-probed `--auto`" to note the `run` path already auto-approves via `runAutoApproveSuffix` and the TUI `--auto` surface is version-dependent (gone in `v1.17.x`, back in `v1.18.0`) — *not* "probe retired".
- **MCP** row: Cursor/Codex/OpenCode ❌→✅.
- **Hook scope** row: all three ❌→✅ (per-project config files now exist); keep the cwd-match note only as the *current adapter behavior*, not an upstream limitation. Add the Codex trust-gate caveat (§3b).
- **Review** row: Codex ❌→✅ (`codex review`).
- **Remote control** row: Codex `false`→"experimental `remote-control`"; leave Cursor/OpenCode ⚠️ (fake) with a note that native surfaces exist.
- **Hook async** row: leave Codex ❌; refresh the pinned version `v0.139.0`→ HEAD (~`0.146-alpha`) and the reason from "no async support" to "async parsed-but-skipped upstream (except `SessionEnd`, run synchronously)".

Until #827 merges, this audit is the authoritative record of what's closeable.
