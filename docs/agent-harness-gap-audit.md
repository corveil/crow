# Harness capability gap audit

**Status:** Living audit — re-run when upstream CLIs bump major/minor versions.
**Baseline:** the capability matrix + capability-tiers ADR proposed in [#827](https://github.com/corveil/crow/issues/827) (still open at audit time; its matrix table and its verbatim version-pinned "why"s are the checklist below).
**Audit ticket:** [#828](https://github.com/corveil/crow/issues/828).
**Audited:** 2026-07-23. **Codex RC row re-probed:** 2026-08-13 against installed `codex-cli 0.141.0` ([CROW-1001](https://github.com/corveil/crow/issues/1001) — §2 #3 / §3b Remote control). **Codex hook-async row re-checked:** 2026-08-13 against upstream `main` ([CROW-999](https://github.com/corveil/crow/issues/999) — §2 #4 / §3b Hook async).

> **Re-check 2026-08-13 ([CROW-999](https://github.com/corveil/crow/issues/999)):**
> **row 4 (Codex hook async) has flipped to available** and is now wired behind
> a version gate. The version snapshot below is the 2026-07-23 audit's and is
> left as recorded: since then Codex shipped `0.147.0` stable (which still
> skips async hooks) and `0.148.0` — the release that honors them — is **still
> pre-release** (`alpha.14` on 2026-08-13), so the gate is inert on every stable
> install today. Rows 4 (§2), "Hook async" (§3b), and §4 carry the updated
> verdicts; every other row still reflects the original audit or the CROW-1001
> re-probe above.

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
| OpenAI Codex | `codex` | `codex-cli 0.141.0` | `rust-v0.145.0` (2026-07-21); **`0.147.0` @ 2026-08-13** (the 0.141.0 TUI advertises the upgrade) | comments pin `v0.139.0` |
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
| 3 | Codex `supportsRemoteControl=false` (no RC flag); Cursor/OpenCode fake RC via `crow send` stdin | ✅ **RESOLVED — but the pinned reason was wrong** (CROW-1001) | The premise ("Codex's TUI isn't stdin-drivable") failed on two counts. `crow send` does not use stdin: `TerminalRouter.send` → `TmuxBackend.sendText` is tmux `load-buffer` → `paste-buffer` → `send-keys Enter`, a paste into the pane. And Codex accepts it — verified end-to-end in a live pane on `codex-cli 0.141.0`: payload lands in the composer verbatim, trailing Enter submits. `supportsRemoteControl` is now `true` for Codex, matching Cursor/OpenCode/Grok/Antigravity. **Native RC is separately non-viable** and stays unwired: `codex remote-control start` refuses on an npm install (demands the managed standalone at `~/.codex/packages/standalone/current/codex`); `codex app-server daemon` is a machine-global singleton on a fixed socket (`~/.codex/app-server-control/app-server-control.sock`) with no port/instance flag, so N per-worktree sessions can't be addressed; and `--remote` points a *local* TUI at a *remote* app server, the reverse of Crow's direction. OpenCode's `serve`/`attach`/`acp` remain in the same "heavier than the paste that works" bucket. See §3b. |
| 4 | Codex hooks sync-only ("as of v0.139.0; async breaks state detection") | ✅ **NOW AVAILABLE** (re-checked 2026-08-13, CROW-999) | `async: true` was parsed-but-skipped through `0.147.0` (stable), and is **honored from `0.148.0`**. [`discovery.rs` on `main`](https://github.com/openai/codex/blob/main/codex-rs/hooks/src/engine/discovery.rs) dropped the `"async hooks are not supported yet"` skip and now computes `runs_async = async && event != SessionEnd`, feeding `HookExecutionMode::Async`. `SessionEnd` is the one carve-out — kept but downgraded to sync with a warning, which costs Crow nothing since it registers no `SessionEnd` hook. Crow now emits `async` for `PostToolUse` behind `CodexVersionProbe` (`>= 0.148.0`, pre-releases rejected). [Codex hooks docs](https://learn.chatgpt.com/docs/hooks) |
| 5 | Auto-permission only Claude (`--permission-mode auto`) + OpenCode (runtime-probed `--auto`) | ✅ **NOW AVAILABLE (Cursor + Codex)** | Cursor (`cursor-agent --help`): `-f/--force`, `--yolo` (alias), `--approve-mcps`, `--trust`, `--sandbox` (`--auto-review` also present in `--help` — see §3a caveat). Codex: `-a/--ask-for-approval never` + `-s/--sandbox workspace-write` (bounded; the recommended default), or the full-bypass `--dangerously-bypass-approvals-and-sandbox` / `-s danger-full-access` (**not** recommended — §3a/§3b). OpenCode is **not** broken today: `OpenCodeLaunchArgs.runAutoApproveSuffix` probes `--auto` first and **falls back to** `--dangerously-skip-permissions` on the `run` path; only the separate `tuiSupportsAuto` top-level `--auto` probe was dead weight on `v1.17.x`, and `v1.18.0` re-added TUI `--auto` anyway (§3c). |
| 6 | MCP Claude-only (Jira via `~/.claude.json`) | ✅ **NOW AVAILABLE (all three)** | `codex mcp {list,get,add,remove,login,logout}` + `codex mcp-server`; `cursor-agent mcp`; `opencode mcp`. |
| 7 | Non-Claude hooks global-scope, session resolved by `cwd` match (no per-session UUID) | ✅ **NOW AVAILABLE (all three)** | Codex: project `.codex/hooks.json` or inline `[hooks]` in `.codex/config.toml` (trusted-project scoped — see the trust-gate warning in §3b). Cursor: project `.cursor/hooks.json`. OpenCode: project `.opencode/plugins/` (Crow's writer's dir; upstream globs `{plugin,plugins}` per `plugin.ts@v1.18.4:21`, so both spellings load). All three can now carry a per-worktree config with Crow's session UUID baked into the command — the same shape as Claude's `.claude/settings.local.json` — closing the shared-`cwd` collision. |
| 8 | Capability availability gated on binary registration | ✅ **UNCHANGED (by design)** | Not a gap. Since #879 every known kind is registered so the pickers can *surface* it, but off-PATH kinds are flagged unavailable and kept out of the launchable `agents` map — capability availability is still gated on `findBinary()` (the launch gate is unchanged), the picker just shows a disabled row instead of hiding it. Surface-but-disable per [ADR 0014](adr/0014-pluggable-coding-agent-adapter.md); ADR seed, #827 Deliverable 2. No re-check needed. |

**Net:** all seven genuine gaps are now closed. Rows 1, 2, 5, 6, 7 gained an
upstream flag; **row 4** closed on the 2026-08-13 re-check (Codex `0.148.0`
honors async hooks; wired behind a version probe in
[CROW-999](https://github.com/corveil/crow/issues/999)); and **row 3** was
retired as *incorrectly premised* rather than closed by an upstream bump —
`crow send` never used stdin, and Codex's composer accepts the tmux paste
([CROW-1001](https://github.com/corveil/crow/issues/1001)). Native RC on
Cursor / Codex / OpenCode stays unwired by choice, not by absence (§4). Row 8
is not a gap.

---

## 3. Per harness × dimension

Legend: ✅ now available upstream · ⚠️ partial / caveated · ❌ still absent.
Claude Code is the baseline and omitted except where it frames the target shape.

### 3a. Cursor (`agent` 2026.07.23)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ❌ "no `--continue` in MVP" | ✅ | `agent --continue`, `agent --resume [chatId]`, `agent resume`, `agent ls` (landed [CLI Jan 16 2026](https://cursor.com/changelog/cli-jan-16-2026): `/list`→`/resume`) | On `.job`/`.review` restart, replace the bare `agent` fallback in `CursorAgent.autoLaunchCommand` with `agent --continue`, so re-open restores history instead of a cold TUI. |
| Non-interactive / headless | ❌ (TUI only) | ✅ | `-p/--print` with `--output-format text\|json\|stream-json` ([CLI docs](https://cursor.com/docs/cli/using)) | Use `agent -p --output-format stream-json` for unattended `.job`s and for review, so Crow can parse structured completion instead of scraping the TUI. **Landed #829 — deviates:** Cursor's interactive TUI accepts the positional prompt directly (unlike OpenCode's batch `run`, which *must* chain `--continue`), so unattended dispatch = positional prompt + auto-permission flags in **one** interactive session (full hook coverage + `crow send`). `-p --output-format stream-json` was **not** adopted — Crow has no stdout consumer (Cursor state is hook-derived, see Hook scope row) and `-p` has reduced hook coverage, so it would add a redundant leg + terminal noise. |
| Auto-permission | ❌ ignored | ✅ | `-f/--force`, `--yolo` (alias for `--force`), `--sandbox <enabled\|disabled>`, `--approve-mcps`, `--trust` — all in `cursor-agent --help` (2026.07.23) and the [CLI parameter reference](https://cursor.com/docs/cli/reference/parameters). `--auto-review` ("Smart Auto: a server classifier auto-runs safe tool calls, prompts for the rest") is present in `--help` on this build but **not yet in the web reference** — treat as unverified/unstable until documented. | For `.job` + `autoPermissionMode`, pair `--force --sandbox enabled` — **approval off, sandbox still on** — as the bounded default (the analogue of §3b's `-a never -s workspace-write`). Bare `--force`/`--yolo` (approve *and* no sandbox) is the unbounded posture §3b warns against; don't use it as the default. Do **not** reach for the undocumented `--auto-review` until it's in the reference. `--trust` seeds workspace trust (≈ Claude gateway trust seed) but is headless-mode only per the reference. **Landed #829:** shipped `--force --approve-mcps` (genuine parity with Claude's `--permission-mode auto`, which has no sandbox). `--sandbox enabled` was evaluated and **dropped in review** — it blocks network at the syscall level ([Cursor 2.5](https://cursor.com/changelog/2-5)), which would silently break `.review` (`gh pr review`), `.job` (`git push`), and the **Manager** (out-of-workspace `crow`-socket / `gh` / sibling `git worktree add`); `--sandbox` is left unset so Cursor honors the user's own config. `--trust` **omitted** (headless-only; interactive TUI — residual gap: a fresh worktree may prompt), `--yolo` and `--auto-review` not used. **Update (2026-07-28, #890):** `--trust` went interactive in Cursor CLI 2026.07.20 (verified `agent 2026.07.23`, whose `--help` drops the "headless mode only" qualifier the param reference still carries) and is now wired as a per-launch workspace-**trust seed** (`CursorLaunchArgs.trustSuffix`, applied on auto-launch + Manager + handoff, **except `.review` clones** — which keep the folder-trust gate, mirroring the Codex `session.kind != .review` guard, CROW-890 review Red 1) — the fresh-worktree residual above is **closed**; still bounded to workspace trust, not `--yolo`. |
| MCP (e.g. Jira) | ❌ | ✅ | file-based `mcp.json` (the `mcp` subcommand is `login`/`list`/`list-tools`/`enable`/`disable` only — **no `add`** on 2026.07.23) | ~~register via `cursor-agent mcp add`~~ (no such subcommand). **Landed #829:** `CursorMCPConfigWriter` bridges the user's `jira` server from `~/.claude.json` (root `mcpServers` or default project-local `projects[<path>].mcpServers`) into `~/.cursor/mcp.json`, keyed on an `x-crow-managed` marker so a user's own entry is never clobbered; unattended runs add `--approve-mcps`. |
| Hook scope (per-session) | ❌ global `~/.cursor/hooks.json`, cwd-match | ✅ *(caveat)* | project `.cursor/hooks.json` (hooks landed [CLI Jan 16 2026](https://cursor.com/changelog/cli-jan-16-2026)) | Write per-worktree `.cursor/hooks.json` with the Crow session UUID in the command (mirror `ClaudeCodeAgent`). **Caveat:** community reports the CLI only fires a subset of events (`beforeShellExecution`/`afterShellExecution`, session start/end/prompt/stop) — verify event coverage against `CursorSignalSource`'s state machine before ripping out the cwd-match. |
| Prompt injection / launcher auto-wire | ⚠️ launcher not auto-wired; `.work` drops into bare TUI | ✅ | positional prompt already works (`agent "<prompt>"`); print mode gives a clean injection surface | With `-p`/`--print` for jobs and positional prompt for `.work`, `CursorLauncher.generatePrompt` output can finally be fed at launch instead of leaving a bare TUI. |
| Remote control | ⚠️ faked via `crow send` paste | ⚠️ (no dedicated local RC socket) | — | No change recommended; `crow send` paste remains the simplest driver. `supportsRemoteControl=true` stays correct. |

### 3b. OpenAI Codex (`codex` 0.141.0)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ❌ "no `--continue` in MVP" | ✅ | `codex resume [SESSION_ID\|--last\|--all]`, `codex fork`, `codex exec resume --last` | On `.job`/`.work` restart, replace bare `codex` with `codex resume --last` (or resume by recorded session id) so re-open restores the thread. |
| Review (`/crow-review-pr`) | ❌ `nil` — "Phase C, Claude-only" | ✅ | `codex review [--base BRANCH\|--commit SHA\|--uncommitted] [--title]`; `codex exec review` | Return a real command from the `.review` branch of `autoLaunchCommand`: `codex review --base main` (or the PR base), replacing the `nil` + `⚠️` echo. Inlined-skill brief no longer needed for the review *itself*. |
| Non-interactive / headless + auto-permission | ❌ ignored | ✅ | `codex exec [PROMPT]` (non-interactive); approval knobs `-a/--ask-for-approval never`, `-s/--sandbox {read-only,workspace-write,danger-full-access}`, `--dangerously-bypass-approvals-and-sandbox` | For `.job` + `autoPermissionMode`, dispatch `codex exec "$(cat …prompt)" -a never -s workspace-write` — **approval off, sandbox still bounded** — as the recommended default (matches Claude's `--permission-mode auto`, not a full escape). Do **not** reach for `--dangerously-bypass-approvals-and-sandbox` or `-s danger-full-access`: they disable the workspace sandbox entirely and are only appropriate inside an already-externally-sandboxed runner. Treat the full-bypass variants as not-recommended, not interchangeable with the bounded default. |
| MCP (e.g. Jira) | ❌ | ✅ | `codex mcp {list,add,get,remove,login,logout}`; `codex mcp-server` (Codex as MCP server) | Register the Jira MCP via `codex mcp add`; parity with Claude's `~/.claude.json` MCP. |
| Hook scope (per-session) | ❌ global `~/.codex/hooks.json`, no-op per-session writer, cwd-match | ✅ *(trust caveat)* | project `.codex/hooks.json` **or** inline `[hooks]` in `.codex/config.toml`; loads only in **trusted** projects (hooks stable [v0.124.0, Apr 2026](https://developers.openai.com/codex/config-advanced)) | **Landed ([CROW-1060](https://github.com/corveil/crow/issues/1060)).** `CodexHookConfigWriter.writeHookConfig` now writes a per-worktree `.codex/hooks.json` carrying `--session <uuid> --agent codex`; the retired global writer's entries are stripped once at daemon boot (`removeManagedGlobalConfig`) so global + project don't double-fire during migration, and `[features] hooks = true` in `config.toml` enables the subsystem. Trust is persisted per worktree (`CodexTrustSeeder`) — **not** `--dangerously-bypass-hook-trust` — so only Crow's own written config runs; `.review` clones are left untrusted (their hooks don't fire, human-gated). Since `.codex/hooks.json` isn't conventionally gitignored, write/remove follow the Cursor/Muse merge protections (git-tracked / non-Crow-owned files left untouched; untracked Crow writes git-excluded). |
| Hook async | ❌ sync-only (pinned v0.139.0) | ✅ **from 0.148.0** (re-checked 2026-08-13) | Skipped through `0.147.0` stable; `discovery.rs` on `main` now computes `runs_async = async && event != SessionEnd` → `HookExecutionMode::Async`. Carve-out: async `SessionEnd` is kept but run synchronously with a warning — irrelevant to Crow, which registers no `SessionEnd` hook. | **Landed (CROW-999; carried through the per-worktree cutover in CROW-1060).** `CodexVersionProbe` reads `codex --version` once at boot; the daemon re-registers Codex with `CodexHookConfigWriter(asyncHooksSupported:)` so its per-worktree writer emits `async` for `PostToolUse` only at `>= 0.148.0`. Fail-closed on every uncertain answer, and pre-releases of the pin are rejected because async landed at `0.148.0-alpha.9` — an earlier alpha would still skip the hooks. `PreToolUse` stays sync (#903 apply-order). |
| Remote control | ❌ `supportsRemoteControl=false` | ✅ *(via `crow send`, not native)* | `codex remote-control {start,stop}` (app-server daemon) + `codex --remote <ws://…>` | **Closed by [CROW-1001](https://github.com/corveil/crow/issues/1001), on the paste path — not this row's flag.** The "stdin paste isn't available for Codex's TUI" claim this row rested on is false: `crow send` is a tmux `paste-buffer`, not stdin, and Codex's composer takes it (verified live, 0.141.0 — text appears verbatim, trailing Enter submits). `supportsRemoteControl` flipped to `true`; `crow send` never gated on it anyway, so this fixed a false-negative badge rather than adding a drive path. **Native RC stays unwired, and should stay that way until three things change:** (1) `codex remote-control start` errors *"managed standalone Codex install not found at `~/.codex/packages/standalone/current/codex` … requires the standalone install managed by the Codex installer"* — Crow resolves `codex` via PATH + homebrew/`/usr/local/bin`/`~/.local/bin` fallbacks, all npm-shaped, so every install would need a second differently-obtained Codex; (2) `codex app-server daemon {start,restart,stop}` expose no port, socket-path, or instance flag and bind one fixed control socket `~/.codex/app-server-control/app-server-control.sock`, so Crow's N concurrent per-worktree sessions cannot be addressed individually — the hooks `cwd`-collision defect relocated to the drive path; (3) `--remote` attaches a *local* TUI to a *remote* app server, which is backwards for Crow — Crow already **is** the remote surface (browser → `crowd` → tmux), so this would add a second parallel one outside its session model. Re-check only if upstream adds a per-instance socket **and** drops the standalone-install requirement. **Probed on the installed `0.141.0`, not `0.147.0` stable** — blocker (3) is architectural and version-independent, but (1) and (2) are pinned to 0.141.0 and are precisely what `0.147.0`'s added `pair` subcommand might move; re-probe them before citing this row against a newer build. |
| Notify bridge | via `~/.codex/hooks.json` + `notify` | ✅ retired | first-class per-worktree hooks now the sole signal path | **Retired ([CROW-1060](https://github.com/corveil/crow/issues/1060)).** With per-worktree hooks carrying a `Stop` event (which `CodexSignalSource` maps to `.done`), the `notify`→`CodexNotifyCommand` bridge is fully redundant. `CodexNotifyCommand`, `CodexNotifyPayload`, and the `crow codex-notify` verb are removed; the `notify = ["<crow>", "codex-notify"]` line is stripped from `config.toml` at boot. |

### 3c. OpenCode (`opencode` 1.17.10 installed; ≥1.18 for auto-permission — see note)

| Dimension | Before (adapter) | Now | Upstream flag / min version | Closing approach |
|---|---|---|---|---|
| Resume / continue | ✅ **already shipped (#547)** | ✅ | TUI `-c/--continue`, `-s/--session <id>`, `--fork`; same on `opencode run` | **The "no history" caveat is already closed in-repo** — `resumeTUICommand` (`OpenCodeLaunchArgs.swift:118`) returns `opencode --continue` and `firstLaunchChainedCommand` (`:113`) chains `; opencode --continue`; there is no bare-`opencode` resume fallback. Genuine remainder, not "resume with history": (a) **`--session <id>` targeting** — Crow only uses `--continue` (last session), never resumes a *specific* session id, so a stale/interleaved last-session could be reopened; (b) `.work` sessions deliberately launch bare (`OpenCodeAgent.swift:81`, "user types their prompt into the TUI") — resuming them is a product choice, not a missing flag. |
| Auto-permission (probe) | ⚠️ runtime `--help` probe for `--auto`, job-only | ✅ *(surface unstable)* | The `run` path already works today: `OpenCodeLaunchArgs.runAutoApproveSuffix` probes `--auto` first, else `--dangerously-skip-permissions` (present on `opencode run` at `v1.17.10`). The **TUI** `--auto` surface flipped twice across two minors: absent in the `v1.17.x` window (verified `tui.ts@v1.17.10`), then **re-added in `v1.18.0`** (2026-07-14, before this audit) — [`tui.ts@v1.18.4`](https://github.com/sst/opencode/blob/v1.18.4/packages/opencode/src/cli/cmd/tui.ts) exposes `--auto`, `--yolo`, **and** `--dangerously-skip-permissions` (`auto: args.auto \|\| args.yolo \|\| args["dangerously-skip-permissions"]`). | **Do not hard-code a single flag name.** The earlier "retire the probe, hard-code `--dangerously-skip-permissions`" advice was scoped to `v1.17.x`, where TUI `--auto` was gone; upstream re-added it a minor later, so a hard-coded name is *more* brittle than the probe. `runAutoApproveSuffix`'s "try `--auto`, else `--dangerously-skip-permissions`" fallback is the resilient shape — keep it. **Note the blast radius:** `--dangerously-skip-permissions` auto-approves *all* non-denied tool calls (no sandbox knob analogous to Codex's `-s`), so it's a full escape — scope it to `.job` + `autoPermissionMode` only, as the adapter already does. The one true dead-weight is `tuiSupportsAuto`'s top-level `--auto` probe **on `v1.17.x` only**; on ≥`1.18` it matches again. #831 should *narrow* the probe (or make it version-aware), not delete it. |
| MCP (e.g. Jira) | ❌ | ✅ | `opencode mcp` subcommand | Register Jira MCP via `opencode mcp`; parity with Claude. |
| Hook scope (per-session) | ❌ global `~/.config/opencode/plugins/`, cwd-match | ✅ | project `.opencode/plugins/` (project-scoped plugins; project config overrides global). Upstream globs `{plugin,plugins}` ([`plugin.ts@v1.18.4:21`](https://github.com/sst/opencode/blob/v1.18.4/packages/opencode/src/config/plugin.ts#L18-L29)) so either spelling loads — Crow's writer uses `plugins/`. | Install the `crow-hooks.js` plugin into the **worktree's** `.opencode/plugins/` with the session UUID baked in, instead of the global dir. Matches the existing `OpenCodeHookConfigWriter` dir name (`plugins/`, `OpenCodeHookConfigWriter.swift:71`). Closes the shared-cwd collision. |
| Remote control | ⚠️ faked via `crow send` paste | ⚠️ native option exists | `opencode serve` (headless server) + `opencode attach <url>` + `opencode acp` (Agent Client Protocol) + `opencode web` | No change recommended near-term; `crow send` paste is simpler than standing up a server per session. `supportsRemoteControl=true` stays correct. Note ACP as the strategic option if Crow ever wants structured (non-paste) driving. |
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
| [#829](https://github.com/corveil/crow/issues/829) — Cursor closures | resume (`--continue`/`--resume`), interactive positional-prompt jobs/review (not `-p` — see §3a), auto-permission `--force --approve-mcps` (parity with Claude auto; `--sandbox enabled` dropped in review — blocks network; `--trust` headless-only; **not** `--yolo`/`--auto-review`), MCP file bridge (**no** `cursor-agent mcp add`), per-project `.cursor/hooks.json`, auto-wire `CursorLauncher` | §3a rows 1–6 |
| [#830](https://github.com/corveil/crow/issues/830) — Codex closures | resume (`codex resume --last`), review (`codex review`), non-interactive `codex exec` + auto-approve (`-a never -s workspace-write`, bounded — **not** full-bypass), MCP (`codex mcp`), per-project `.codex/hooks.json` (persist per-worktree trust — **not** `--dangerously-bypass-hook-trust`; resolve merge-vs-clobber), retire `notify` bridge (hook-scope cutover + `notify` retirement → split out as [CROW-1060](https://github.com/corveil/crow/issues/1060), closed), evaluate experimental `remote-control` (→ split out as [CROW-1001](https://github.com/corveil/crow/issues/1001), closed) | §3b rows 1–5, 7, 8 |
| [#831](https://github.com/corveil/crow/issues/831) — OpenCode closures | MCP (`opencode mcp`), per-project `.opencode/plugins/`; **narrow (do not delete) the auto-permission probe** — TUI `--auto` was gone only in `v1.17.x` and returned in `v1.18.0`, so keep `runAutoApproveSuffix`'s fallback and make the probe version-aware. **Resume-with-history is already shipped (#547)** — the only remainder is `--session <id>` targeting + whether `.work` should resume (both optional). | §3c rows 1–4 |

**Deferred (no ticket):**
- **Cursor / Codex / OpenCode native RC** (§3a, §3b, §3c RC rows) — native surfaces exist (`--remote`, `remote-control`, `serve`/`attach`/`acp`) but are heavier than the working `crow send` paste; no user-facing capability gained today. Codex joined this bucket in [CROW-1001](https://github.com/corveil/crow/issues/1001), which also disqualified its path on three concrete grounds (standalone-install requirement, singleton daemon socket, reversed direction) rather than leaving it "experimental, evaluate later".

**Closed since:**
- **Codex async hooks** (§2 #4 / §3b) — upstream shipped them in `0.148.0`; wired behind a version probe in [CROW-999](https://github.com/corveil/crow/issues/999) and carried through the per-worktree cutover in [CROW-1060](https://github.com/corveil/crow/issues/1060). The async **timing** re-check is now **done** ([CROW-1065](https://github.com/corveil/crow/issues/1065)): `0.148.0` shipped **stable** on 2026-08-18 (npm `latest` = `0.149.0` on 2026-08-20), so the gate passes on real installs, and the state-card correctness for `.job`/`.work` is safe **by construction** — `PostToolUse` is the only async event and its sole mutation (`lastToolActivity`) is persistence-excluded + reader-less, while completion is owned by the sync `Stop`, so no straggler-after-`Stop` ordering is observable (pinned by `lateAsyncPostToolUseAfterStopStaysDone` in `CodexSignalSourceTests`; a live 0.148.0+ TUI trace is a nice-to-have human re-check). (The old "no double-count against the `notify` bridge" caveat is moot — CROW-1060 retired that bridge.)
- **OpenCode per-project plugins + MCP mirror** (§3c #3 / #4) — **landed ([CROW-831](https://github.com/corveil/crow/issues/831)).** `OpenCodeHookConfigWriter.writeHookConfig` now writes a per-worktree `<worktree>/.opencode/plugins/crow-hooks.js` with the session UUID baked in (`hook-event --session <uuid>`, exact — no `cwd` match), and the boot-installed global `~/.config/opencode/plugins/crow-hooks.js` is a **self-suppressing fallback** — its plugin body returns no hooks whenever a per-project `crow-hooks.js` exists, so global + project don't double-fire. `OpenCodeMCPConfigWriter` mirrors the user's `jira` server from `~/.claude.json` into `<configHome>/opencode.json` (`mcp.jira`) at daemon boot from `LaunchScaffold` — the file-based analogue of Codex's `config.toml` mirror. Per §3c the auto-permission probe was **narrowed, not deleted**; the residual OpenCode items (`--session <id>` targeting, whether `.work` should resume) stay optional/product choices.

> **#830 resolution (landed).** §3b rows 1–4 shipped: `.work`/`.job`-restart →
> `codex resume --last` (cwd-scoped by default; opens a fresh TUI when no thread
> matches, so no fallback is needed); `.job` + auto-permission → the **interactive**
> `codex -a never -s workspace-write "$(cat …-prompt.md)"` (bounded — **not**
> the full-bypass variants; *not* headless `codex exec`, which is one-shot and
> would drop a multi-prompt job's typed follow-ups into the shell); MCP mirrored
> from `~/.claude.json` into `[mcp_servers.*]` (`CodexMCPWriter`, append-only,
> gated by `defaults.mirrorClaudeMCPToCodex`). **Review** (row 2) landed *not* as the
> native `codex review --base` but via the **inlined `/crow-review-pr` skill**
> (same as Cursor/OpenCode): `codex review` prints local findings and posts no
> GitHub verdict, so a review driven by it can never satisfy
> `decideReviewCompletions` (which closes a review only on a *posted* verdict)
> and would be re-kicked on every head-SHA advance. The §3b **hook-scope** row's
> *trust* half shipped as `CodexTrustSeeder` — it persists `[projects."<worktree>"]
> trust_level = "trusted"` for the `.work`/`.job` worktrees Crow branches off a
> trusted base and the Manager devRoot (the bounded alternative the row demands,
> **not** `--dangerously-bypass-hook-trust`), which unblocks unattended
> auto-launch. `.review` clones are **not** trusted — their tree is external
> PR-head content, so trusting it would arm committed `.codex/hooks.json`; they
> use Codex's folder-trust prompt and `prepareReviewClone` strips any committed
> `.codex/` (#843 review round 5).
> **Deferred within #830, now closed by [CROW-1060](https://github.com/corveil/crow/issues/1060)** (rows 7 partial, 8):
> writing per-worktree `.codex/hooks.json` was held back because Codex layers
> project hooks *on top of* the still-needed global `~/.codex/hooks.json`, so both
> would fire for the same action and the `hook-event` handler would double-count
> (duplicate notifications, ring-buffer entries). CROW-1060 took the "drop the
> global writer" cutover: `CodexHookConfigWriter.writeHookConfig` writes the
> per-worktree file with `--session <uuid>` baked in, `removeManagedGlobalConfig`
> strips the managed global entries once at daemon boot (so there is no
> double-fire window during migration), and the `notify`→`CodexNotifyCommand`
> bridge is **retired** — the per-worktree `Stop` hook drives `.done` on its own,
> so a server-side (session,event) dedup was not needed. `supportsRemoteControl`
> was separately flipped `true` (CROW-1001, below).

> **CROW-1001 resolution (landed).** The RC deferral above is closed, with its
> premise corrected. #830 left `supportsRemoteControl` at `false` "pending
> end-to-end `codex remote-control` validation", on §3b's reasoning that Codex
> was the one harness where native RC would add real capability *because the
> stdin paste wasn't available for its TUI*. That reasoning does not survive
> contact with the code or the binary. `crow send` is not stdin — it is
> `TerminalRouter.send` → `TmuxBackend.sendText`, i.e. tmux `load-buffer` →
> `paste-buffer` → `send-keys Enter` — and Codex's composer accepts it: verified
> in a live pane on `codex-cli 0.141.0`, pasted text appears verbatim and the
> trailing Enter submits. Nor did anything gate on the flag: `TerminalRouter.send`
> is agent-agnostic, so Codex sessions were already drivable from the web UI
> while the badge claimed they weren't. `supportsRemoteControl` is now `true`,
> on the same basis as Cursor/OpenCode/Grok/Antigravity, and no `--rc` is
> emitted (Codex has none; a test pins that `remoteControlEnabled` leaves every
> session kind's launch text byte-identical).
>
> The native path was validated too, and **failed** — recorded as a concrete pin
> rather than another "evaluate": `codex remote-control start` refuses on the npm
> build Crow resolves (wants the managed standalone at
> `~/.codex/packages/standalone/current/codex`), `codex app-server daemon` is a
> machine-global singleton on one fixed control socket with no per-instance flag
> (unusable for N per-worktree sessions), and `--remote` runs the wrong
> direction — it attaches a local TUI to a remote app server, whereas Crow *is*
> the remote surface. See §3b's Remote control row for the re-check condition.
>
> **Version caveat, stated plainly.** The probe ran on the **installed** build,
> `codex-cli 0.141.0`; stable was `0.147.0` on the probe date, and CROW-1001's
> description cites `0.147.0` shipping a documented `remote-control
> {start,stop,pair}` (0.141.0 has `{start,stop}` only). The three blockers are
> therefore not equally durable. Blocker 3 — **wrong direction** — is
> architectural: it follows from what `--remote` *is*, and no version bump
> changes it short of Codex adding an inbound drive protocol. Blockers 1 and 2 —
> the standalone-install requirement and the singleton control socket — are
> version-specific and are exactly what a `pair` subcommand might move, so they
> are pinned to 0.141.0 and should be re-probed on 0.147.0+ rather than treated
> as settled. **None of this gates the flag**, which rests on the `crow send`
> paste path, not on native RC; a future Codex that fixes 1 and 2 would make
> native RC an *optional upgrade* to how a `true` badge is honored, not a
> correction to whether it should be `true`.
>
> Two side observations from the same probe, worth recording since they cost
> nothing to check: the live pane reported `alternate_on=0`, so Codex's
> `usesAlternateScreen = false` is now **verified** rather than inherited from
> the inline default (the matrix cell said "unverified"); and 0.141.0 gates a
> fresh directory behind **two** interactive prompts — folder trust, then a
> hook-trust prompt (*"6 hooks are new or changed"*, listing Crow's global
> `~/.codex/hooks.json` entries). `CodexTrustSeeder` addresses the first. Whether
> the second blocks unattended auto-launch is untested here and is not this
> ticket's scope, but it is the natural next probe if a `.job` on Codex ever
> stalls at startup.

Spin-off tickets are opened against `corveil/crow` and reference this audit + [#828](https://github.com/corveil/crow/issues/828).

---

## 5. Matrix + tiers-ADR reconciliation (#827 merged as [#833](https://github.com/corveil/crow/pull/833))

#827's deliverables landed on `main` in [#833](https://github.com/corveil/crow/pull/833):
[`docs/agent-harness-matrix.md`](agent-harness-matrix.md), [ADR 0014](adr/0014-pluggable-coding-agent-adapter.md)
(adapter), and [ADR 0015](adr/0015-harness-capability-tiers.md) (capability tiers).
This audit's corrections have now been applied to those docs — see the commit that
rebased this branch onto #833.

**Framing that matters:** the matrix grid and ADR 0015's Decision list describe
**Crow's own adapter behavior** ("what Crow wires up"), *not* raw upstream
capability. `cursor-agent --resume` existing upstream does **not** make Crow's
Resume cell ✅ — Crow still launches a bare TUI on restart until #829 lands. So the
reconciliation **annotates the documented *why*** (the reason a gap exists) where
upstream has closed it, and leaves each grid cell at Crow's real status until the
spin-off ticket ships the wiring. Concretely, applied to #833's docs:

- **Matrix — [re-check-targets table](agent-harness-matrix.md#version-pinned-reasons--re-check-targets):**
  linked this audit as the follow-up it seeds, and refreshed the Codex sync-only
  pin (still holds at `~0.146-alpha`, with the `SessionEnd`-runs-synchronously
  carve-out from §2 #4).
- **Matrix — new "Upstream closures" note:** per-dimension, records which grid
  gaps now have an upstream flag + the tracking ticket (Resume → #829/#830/#831,
  Auto-permission → #829/#830, MCP → all three, Review → #830, Hook scope → all
  three, Codex RC → experimental), while stating the grid stays at Crow's status
  until those land.
- **ADR 0015 — Consequences:** pointed the "seed for a follow-up capability audit"
  bullet at this completed audit.

The per-dimension closure detail (flag, min version, closing approach, security
caveats) lives in §3 above; the matrix note just cross-links it so the two docs
can't drift.
