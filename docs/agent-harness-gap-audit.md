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

All four binaries resolve on the audit machine's PATH; capability probes below are
against these exact builds (`<binary> --version` / `--help`).

| Harness | Binary | Version at audit | Adapter written against |
|---|---|---|---|
| Claude Code | `claude` | `2.1.206` | baseline (mostly ✅) |
| Cursor | `agent` / `cursor-agent` | `2026.07.23-e383d2b` | pre-resume/print MVP |
| OpenAI Codex | `codex` | `codex-cli 0.141.0` | comments pin `v0.139.0` |
| OpenCode | `opencode` | `1.17.10` | CROW-545/547 MVP |

---

## 2. Re-verification of every version-pinned reason (acceptance criterion)

Each row is a pinned "why" enumerated in [#827](https://github.com/corveil/crow/issues/827)
Deliverable 3, re-checked against §1. **Verdict** is `NOW AVAILABLE` (upstream grew
the feature after the adapter was written) or `STILL ABSENT` (pin holds; update only
the stale version reference).

| # | Pinned reason (from #827 tiers ADR seed) | Verdict | Evidence |
|---|---|---|---|
| 1 | Codex review unsupported → `nil` ("Phase C; `/crow-review-pr` is Claude-only") | ✅ **NOW AVAILABLE** | `codex review [--base BRANCH] [--commit SHA] [--uncommitted] [--title]` runs a review **non-interactively**; also `codex exec review`. |
| 2 | Codex / Cursor no resume ("no `--continue` equivalent in MVP") | ✅ **NOW AVAILABLE (both)** | Codex: `codex resume [SESSION_ID] [--last] [--all]` + `codex fork`. Cursor: `agent --resume [chatId]`, `agent --continue`, `agent resume`, `agent ls`. |
| 3 | Codex `supportsRemoteControl=false` (no RC flag); Cursor/OpenCode fake RC via `crow send` stdin | ⚠️ **PARTIAL** | Codex now has experimental `codex remote-control {start,stop}` (app-server daemon) + `codex --remote <ws://…>` to connect a TUI to a remote app server. OpenCode has `opencode serve` (headless server) + `opencode attach <url>` + `opencode acp` (Agent Client Protocol) + `opencode web`. Both are *native* remote surfaces that could retire the stdin fake, but both are heavier than the current `crow send` paste — see closing approach. |
| 4 | Codex hooks sync-only ("as of v0.139.0; async breaks state detection") | ❌ **STILL ABSENT** | `async: true` is still **parsed but skipped** upstream — Codex ignores async command hooks; only the version reference is stale (now v0.141.0). Concurrency exists (multiple matching hooks launch concurrently) but no fire-and-forget async. Keep `asyncEvents` empty. [Codex hooks docs](https://developers.openai.com/codex/config-advanced) |
| 5 | Auto-permission only Claude (`--permission-mode auto`) + OpenCode (runtime-probed `--auto`) | ✅ **NOW AVAILABLE (Cursor + Codex)** | Cursor: `-f/--force`, `--yolo` (alias), `--auto-review`, `--approve-mcps`, `--trust`. Codex: `-a/--ask-for-approval never`, `-s/--sandbox danger-full-access`, `--dangerously-bypass-approvals-and-sandbox`. OpenCode's `--auto` probe is now stale: 1.17.10 exposes `--dangerously-skip-permissions` on `opencode run` (not a top-level `--auto`). |
| 6 | MCP Claude-only (Jira via `~/.claude.json`) | ✅ **NOW AVAILABLE (all three)** | `codex mcp {list,get,add,remove,login,logout}` + `codex mcp-server`; `cursor-agent mcp`; `opencode mcp`. |
| 7 | Non-Claude hooks global-scope, session resolved by `cwd` match (no per-session UUID) | ✅ **NOW AVAILABLE (all three)** | Codex: project `.codex/hooks.json` or inline `[hooks]` in `.codex/config.toml` (trusted-project scoped). Cursor: project `.cursor/hooks.json`. OpenCode: project `.opencode/plugin/`. All three can now carry a per-worktree config with Crow's session UUID baked into the command — the same shape as Claude's `.claude/settings.local.json` — closing the shared-`cwd` collision. |
| 8 | Capability availability gated on binary registration | ✅ **UNCHANGED (by design)** | Not a gap. `AgentRegistry` still registers a kind only if `findBinary()` resolves; that's the intended contract (ADR seed, #827 Deliverable 2). No re-check needed. |

**Net:** of the seven genuine gaps, **five flip to now-available** (2, 5, 6, 7, and Codex's half of 1/3), **one is partial** (3 — native RC exists but is heavier than the stdin fake), and **one still holds** (4 — Codex async hooks).

---

## 3. Per harness × dimension

Legend: ✅ now available upstream · ⚠️ partial / caveated · ❌ still absent.
Claude Code is the baseline and omitted except where it frames the target shape.

### 3a. Cursor (`agent` 2026.07.23)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ❌ "no `--continue` in MVP" | ✅ | `agent --continue`, `agent --resume [chatId]`, `agent resume`, `agent ls` (landed [CLI Jan 16 2026](https://cursor.com/changelog/cli-jan-16-2026): `/list`→`/resume`) | On `.job`/`.review` restart, replace the bare `agent` fallback in `CursorAgent.autoLaunchCommand` with `agent --continue`, so re-open restores history instead of a cold TUI. |
| Non-interactive / headless | ❌ (TUI only) | ✅ | `-p/--print` with `--output-format text\|json\|stream-json` ([CLI docs](https://cursor.com/docs/cli/using)) | Use `agent -p --output-format stream-json` for unattended `.job`s and for review, so Crow can parse structured completion instead of scraping the TUI. |
| Auto-permission | ❌ ignored | ✅ | `-f/--force`, `--yolo`, `--auto-review`, `--sandbox`, `--approve-mcps`, `--trust` | Honor `autoPermissionMode` for `.job`: append `--force` (or `--auto-review` for a safer classifier). Seeds the trust model too (`--trust` ≈ Claude gateway trust seed). |
| MCP (e.g. Jira) | ❌ | ✅ | `cursor-agent mcp` subcommand | Reuse the Jira MCP config Crow already writes for Claude; register it via `cursor-agent mcp add`. |
| Hook scope (per-session) | ❌ global `~/.cursor/hooks.json`, cwd-match | ✅ *(caveat)* | project `.cursor/hooks.json` (hooks landed [CLI Jan 16 2026](https://cursor.com/changelog/cli-jan-16-2026)) | Write per-worktree `.cursor/hooks.json` with the Crow session UUID in the command (mirror `ClaudeCodeAgent`). **Caveat:** community reports the CLI only fires a subset of events (`beforeShellExecution`/`afterShellExecution`, session start/end/prompt/stop) — verify event coverage against `CursorSignalSource`'s state machine before ripping out the cwd-match. |
| Prompt injection / launcher auto-wire | ⚠️ launcher not auto-wired; `.work` drops into bare TUI | ✅ | positional prompt already works (`agent "<prompt>"`); print mode gives a clean injection surface | With `-p`/`--print` for jobs and positional prompt for `.work`, `CursorLauncher.generatePrompt` output can finally be fed at launch instead of leaving a bare TUI. |
| Remote control | ⚠️ faked via `crow send` stdin | ⚠️ (no dedicated local RC socket) | — | No change recommended; `crow send` paste remains the simplest driver. `supportsRemoteControl=true` stays correct. |

### 3b. OpenAI Codex (`codex` 0.141.0)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ❌ "no `--continue` in MVP" | ✅ | `codex resume [SESSION_ID\|--last\|--all]`, `codex fork`, `codex exec resume --last` | On `.job`/`.work` restart, replace bare `codex` with `codex resume --last` (or resume by recorded session id) so re-open restores the thread. |
| Review (`/crow-review-pr`) | ❌ `nil` — "Phase C, Claude-only" | ✅ | `codex review [--base BRANCH\|--commit SHA\|--uncommitted] [--title]`; `codex exec review` | Return a real command from the `.review` branch of `autoLaunchCommand`: `codex review --base main` (or the PR base), replacing the `nil` + `⚠️` echo. Inlined-skill brief no longer needed for the review *itself*. |
| Non-interactive / headless + auto-permission | ❌ ignored | ✅ | `codex exec [PROMPT]` (non-interactive); approval: `-a/--ask-for-approval never`, `-s/--sandbox danger-full-access`, `--dangerously-bypass-approvals-and-sandbox` | For `.job` + `autoPermissionMode`, dispatch `codex exec "$(cat …prompt)" -a never -s workspace-write` instead of feeding the prompt to the interactive TUI; honors unattended semantics like Claude's `--permission-mode auto`. |
| MCP (e.g. Jira) | ❌ | ✅ | `codex mcp {list,add,get,remove,login,logout}`; `codex mcp-server` (Codex as MCP server) | Register the Jira MCP via `codex mcp add`; parity with Claude's `~/.claude.json` MCP. |
| Hook scope (per-session) | ❌ global `~/.codex/hooks.json`, no-op per-session writer, cwd-match | ✅ | project `.codex/hooks.json` **or** inline `[hooks]` in `.codex/config.toml`; loads only in **trusted** projects (hooks stable [v0.124.0, Apr 2026](https://developers.openai.com/codex/config-advanced)) | Make `CodexHookConfigWriter.writeHookConfig` non-nop: write a per-worktree `.codex/hooks.json` carrying `--session <uuid>`, and trust-seed the worktree (`--dangerously-bypass-hook-trust` on first launch, or persist trust) so the project layer loads. Retains the global writer as fallback. |
| Hook async | ❌ sync-only (pinned v0.139.0) | ❌ **still** | `async:true` parsed-but-skipped as of v0.141.0 | **Deferred** — keep `asyncEvents` empty; re-check on the next Codex minor. |
| Remote control | ❌ `supportsRemoteControl=false` | ⚠️ experimental | `codex remote-control {start,stop}` (app-server daemon) + `codex --remote <ws://…>` | Flip `supportsRemoteControl=true` **only** once the experimental app-server path is validated end-to-end; until then the badge stays off. Lower priority than resume/review — the stdin paste isn't available for Codex's TUI the way it is for Cursor/OpenCode, so this is the one harness where native RC actually adds a capability. |
| Notify bridge | via `~/.codex/hooks.json` + `notify` | ⚠️ possibly redundant | first-class hooks now stable | Once per-worktree hooks land, evaluate retiring the `notify`→`CodexNotifyCommand` bridge in favor of a `Stop`/`SessionEnd` hook. |

### 3c. OpenCode (`opencode` 1.17.10)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ⚠️ TUI re-entry, no history | ✅ | TUI `-c/--continue`, `-s/--session <id>`, `--fork`; same on `opencode run` | Replace the bare-`opencode` resume fallback in `resumeTUICommand` with `opencode --continue` (or `--session <id>`), so re-open restores history rather than a fresh TUI. Removes the "no history" caveat. |
| Auto-permission (drop probe hack) | ⚠️ runtime `--help` probe for `--auto`, job-only | ✅ (flag stable) | `opencode run --dangerously-skip-permissions` (stable in 1.17.x); top-level TUI `--auto` is **gone**, so the current `tuiSupportsAuto` probe never matches on ≥1.17 | Retire the `--help` subprocess probe in `OpenCodeLaunchArgs`: hard-code `--dangerously-skip-permissions` on the headless `run` step (which is where auto-approve already applies), drop `tuiSupportsAuto`. Keeps the main thread free of subprocess probes. |
| MCP (e.g. Jira) | ❌ | ✅ | `opencode mcp` subcommand | Register Jira MCP via `opencode mcp`; parity with Claude. |
| Hook scope (per-session) | ❌ global `~/.config/opencode/plugin/`, cwd-match | ✅ | project `.opencode/plugin/` (project-scoped plugins; project config overrides global) | Install the `crow-hooks.js` plugin into the **worktree's** `.opencode/plugin/` with the session UUID baked in, instead of the global dir. Closes the shared-cwd collision. |
| Remote control | ⚠️ faked via `crow send` stdin | ⚠️ native option exists | `opencode serve` (headless server) + `opencode attach <url>` + `opencode acp` (Agent Client Protocol) + `opencode web` | No change recommended near-term; `crow send` paste is simpler than standing up a server per session. `supportsRemoteControl=true` stays correct. Note ACP as the strategic option if Crow ever wants structured (non-paste) driving. |
| Review | ✅ inlined skill (already works) | ✅ | `opencode run` + inlined skill; also `opencode github` / `opencode pr <n>` | No change needed. `opencode pr <number>` could simplify PR-checkout for review jobs later. |

---

## 4. Spin-off tickets

Each closeable gap is grouped by harness (that's the natural implementation unit —
a single adapter + its launcher + hook writer + tests change together).

| Ticket | Scope | Closes |
|---|---|---|
| [#829](https://github.com/corveil/crow/issues/829) — Cursor closures | resume (`--continue`/`--resume`), print-mode jobs/review (`-p`), auto-permission (`--force`/`--auto-review`/`--trust`), MCP (`cursor-agent mcp`), per-project `.cursor/hooks.json`, auto-wire `CursorLauncher` | §3a rows 1–6 |
| [#830](https://github.com/corveil/crow/issues/830) — Codex closures | resume (`codex resume --last`), review (`codex review`), non-interactive `codex exec` + auto-approve (`-a never`/`--dangerously-bypass…`), MCP (`codex mcp`), per-project `.codex/hooks.json` (trust-seeded); evaluate experimental `remote-control` | §3b rows 1–5, 7 |
| [#831](https://github.com/corveil/crow/issues/831) — OpenCode closures | TUI resume with history (`--continue`/`--session`), retire `--help` auto-probe (stable `--dangerously-skip-permissions`), MCP (`opencode mcp`), per-project `.opencode/plugin/` | §3c rows 1–4 |

**Deferred (no ticket):**
- **Codex async hooks** (§2 #4 / §3b) — upstream still parses-but-skips `async:true`; nothing to wire. Re-check on next Codex minor.
- **Cursor / OpenCode native RC** (§3a, §3c RC rows) — native surfaces exist (`--remote`, `serve`/`attach`/`acp`) but are heavier than the working `crow send` paste; no user-facing capability gained today.

Spin-off tickets are opened against `corveil/crow` and reference this audit + [#828](https://github.com/corveil/crow/issues/828).

---

## 5. Matrix + tiers-ADR reconciliation (pending #827)

[#827](https://github.com/corveil/crow/issues/827)'s `docs/agent-harness-matrix.md` and
the capability-tiers ADR are **not yet merged**, so there is nothing in-repo to edit.
When #827 lands, apply these corrections from §2 so no stale "why" survives:

- **Resume** row: Cursor ❌→✅ (`--continue`/`--resume`), Codex ❌→✅ (`codex resume`), OpenCode ⚠️→✅-with-history.
- **Auto-permission** row: Cursor ❌→✅, Codex ❌→✅; rewrite OpenCode's "runtime-probed `--auto`" to "`run --dangerously-skip-permissions` (probe retired)".
- **MCP** row: Cursor/Codex/OpenCode ❌→✅.
- **Hook scope** row: all three ❌→✅ (per-project config files now exist); keep the cwd-match note only as the *current adapter behavior*, not an upstream limitation.
- **Review** row: Codex ❌→✅ (`codex review`).
- **Remote control** row: Codex `false`→"experimental `remote-control`"; leave Cursor/OpenCode ⚠️ (fake) with a note that native surfaces exist.
- **Hook async** row: leave Codex ❌; update the pinned version `v0.139.0`→`v0.141.0` and the reason from "no async support" to "async parsed-but-skipped upstream".

Until #827 merges, this audit is the authoritative record of what's closeable.
