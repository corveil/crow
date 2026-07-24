# Coding-agent harness capability matrix

Crow can drive four coding agents ("harnesses") through one adapter protocol,
[`CodingAgent`](../Packages/CrowCore/Sources/CrowCore/Agent/CodingAgent.swift):
**Claude Code**, **Cursor**, **OpenAI Codex**, and **OpenCode** (sst/opencode).
Claude Code is the reference implementation and the default; the other three
ship with deliberate gaps.

This page is the living reference for **what each harness can do and why the
gaps exist**. The *architecture* of the adapter is
[ADR 0014](adr/0014-pluggable-coding-agent-adapter.md); the *rationale for the
gaps* (capability tiers + phased parity) is
[ADR 0015](adr/0015-harness-capability-tiers.md). When you change a harness's
capabilities, update this table in the same PR.

> **Scope.** "Harness" here means a *coding agent* (`CodingAgent` /
> `AgentKind`). Do not confuse it with the *task/code provider* abstraction
> (`TaskBackend` / `CodeBackend` for GitHub / GitLab / Jira / Corveil), which is
> a separate axis governed by [ADR 0005](adr/0005-task-and-code-backend-protocols.md).
> A session pairs one harness with one (or two) providers.

## The matrix

| Dimension | Claude Code | Cursor | Codex | OpenCode |
|---|---|---|---|---|
| Binary token (`launchCommandToken`) | `claude` | `agent` ⚠️ collision risk | `codex` | `opencode` |
| Registered at boot | **always** (default out of the box) | only if binary found | only if binary found | only if binary found |
| Resume / continue | ✅ `--continue` | ❌ no MVP resume | ✅ `resume --last` | ⚠️ `--continue` re-enters TUI, no history |
| Remote control | ✅ native `--rc --name` | ⚠️ faked via `crow send` stdin | ❌ `supportsRemoteControl=false` (experimental `--remote` unwired) | ⚠️ faked via `crow send` stdin |
| Auto-permission | ✅ `--permission-mode auto` | ❌ ignored | ✅ `exec -a never -s workspace-write` (`.job`) | ⚠️ runtime-probed `--auto`, `.job` only |
| Hooks transport | per-worktree `.claude/settings.local.json` | global `~/.cursor/hooks.json` | global `~/.codex/hooks.json` + `config.toml` `notify` bridge (per-worktree deferred — see below) | global JS plugin `~/.config/opencode/plugins/crow-hooks.js` |
| Hook → session scope | ✅ per-session UUID | ❌ `cwd` match | ❌ `cwd` match (per-worktree UUID deferred) | ❌ `cwd` match |
| Hook async delivery | ✅ `PostToolUse*` async | ⚠️ declared, timing unverified | ❌ sync-only (v0.141.0) | ⚠️ names verified, timing unverified |
| MCP (e.g. Jira) | ✅ `jira` MCP server via `~/.claude.json` | ❌ falls back to `acli` | ✅ mirrored from `~/.claude.json` into `config.toml` | ❌ falls back to `acli` |
| Review (`/crow-review-pr`) | ✅ slash-command | ✅ inlined skill body | ✅ native `codex review --base` | ✅ inlined skill body |
| Initial-prompt injection | ✅ `$(cat …-prompt.md)` + deferred paste | ⚠️ job/review only, `.work` launcher not auto-wired | ✅ `.job` (`exec`/TUI) + `.review` (`codex review`) | ✅ run-then-`--continue` |
| Gateway env / trust seed / telemetry | ✅ Claude special-case | ❌ | ⚠️ trust seed only (`[projects."…"]` in `config.toml`) | ❌ |
| Rename passthrough (`/rename`) | ✅ | ✅ | ✅ | ✅ |

Legend: ✅ full · ⚠️ partial / faked / unverified · ❌ not supported.

> **The grid is Crow's status, not upstream capability.** A ❌/⚠️ means *Crow
> doesn't wire it up* — the upstream CLI may already support it. The
> [harness capability gap audit](agent-harness-gap-audit.md) ([#828](https://github.com/corveil/crow/issues/828))
> re-checked every gap against current upstream (Cursor `2026.07.23`, Codex
> `0.141.0`, OpenCode `1.17.10`+); several now have an upstream flag and a
> spin-off closure ticket. **The cells below stay at Crow's real status until
> those tickets land:**
>
> | Gap (grid row) | Now available upstream | Closure ticket |
> |---|---|---|
> | Resume / continue | Cursor `--resume`/`--continue`, Codex `resume --last`, OpenCode `--continue` (history caveat already closed by #547) | [#829](https://github.com/corveil/crow/issues/829) / [#830](https://github.com/corveil/crow/issues/830) / [#831](https://github.com/corveil/crow/issues/831) |
> | Auto-permission (Cursor, Codex) | Cursor `--force --sandbox enabled`; Codex `-a never -s workspace-write` | #829 / #830 |
> | MCP | `cursor-agent mcp`, `codex mcp`, `opencode mcp` | #829 / #830 / #831 |
> | Review (Codex) | `codex review --base <branch>` / `codex exec review` | #830 |
> | Hook → session scope | project `.cursor/hooks.json`, `.codex/hooks.json`, `.opencode/plugins/` (per-worktree UUID) | #829 / #830 / #831 |
> | Remote control (Codex) | experimental `codex remote-control` / `--remote` | #830 (evaluate) |
>
> Still absent upstream: Codex **async hooks** (parsed-but-skipped, except
> `SessionEnd`). See the gap audit for flags, min versions, and closing approaches.
>
> **[#830](https://github.com/corveil/crow/issues/830) (Codex) landed** — the
> Codex cells above now reflect shipped state: `resume --last`, native
> `codex review --base`, bounded `exec -a never -s workspace-write`, MCP mirror
> from `~/.claude.json`, and per-worktree **project-trust** seeding
> (`CodexTrustSeeder`). **Deferred within #830:** per-worktree `.codex/hooks.json`
> (would double-fire alongside the still-needed global writer — both dispatch to
> the same session, doubling notifications; needs server-side event dedup first),
> retiring the `notify` bridge (tied to that hooks cutover), and flipping
> `supportsRemoteControl` (experimental `codex remote-control` needs end-to-end
> validation). See the gap audit §3b update.

## Notes per dimension

Each note cites the source of truth. Line numbers drift; the symbol names are
stable anchors.

### Binary token & registration

Each harness declares a `launchCommandToken` — the binary name Crow resolves on
`PATH` and the token the `send` RPC watches for to decide whether a
managed-terminal command needs hook/env prep.

- Tokens: `claude`, `agent`, `codex`, `opencode`
  (`ClaudeCodeAgent`, `CursorAgent`, `OpenAICodexAgent`, `OpenCodeAgent`).
- **Cursor's token is `agent`, a generic name.** CI runners (Azure DevOps,
  TeamCity) also ship a binary called `agent`; Crow accepts the false-positive
  risk and lets users pin the real path via `defaults.binaries.cursor`
  (`CursorAgent.swift` launch-token comment, CROW-484).
- **Registration order = default.** `AgentRegistry.register` sets the default to
  the *first* kind registered
  ([`AgentRegistry.swift`](../Packages/CrowCore/Sources/CrowCore/Agent/AgentRegistry.swift)).
  `CrowDaemon.registerAgents` registers **Claude unconditionally first**, then
  Codex / Cursor / OpenCode **only if `findBinary()` resolves**
  ([`CrowDaemon.swift`](../Packages/CrowDaemon/Sources/CrowDaemon/CrowDaemon.swift),
  `registerAgents`). So a harness whose binary is off `PATH` is silently absent
  from the picker and from `handoff-agent` — see
  [ADR 0015](adr/0015-harness-capability-tiers.md).
- `findBinary()` resolves in three tiers: explicit `defaults.binaries.<kind>`
  override → `PATH` walk → hardcoded `fallbackCandidates`
  (`CodingAgent` default impl; `BinaryOverrides`, CROW-484).
- **Registration order ≠ new-session default.** First-registered only sets the
  *registry's* fallback (`AgentRegistry.defaultAgent`). The harness a new session
  launches with is config-driven: `AppState.agentKind(for:) =
  agentsByKind[sessionKind.rawValue] ?? defaultAgentKind`, both user-settable in
  Settings → "Default agent" + per-session-kind overrides (CROW-421 / CROW-433).
  `defaultAgentKind` ships as `.claudeCode`, so Claude is the *out-of-the-box*
  default; set it to Cursor and every new session uses Cursor.

### Resume / continue

- **Claude:** work sessions relaunch with `--continue`; review/job sessions read
  their prompt file on first launch, then fall through to `--continue` on
  restart (`ClaudeCodeAgent.autoLaunchCommand`, CROW-224 / CROW-317).
- **Cursor & Codex:** no `--continue` equivalent in the MVP — a restart drops
  the user back into a bare TUI rather than re-running the prompt
  (`CursorAgent` / `OpenAICodexAgent` `.job` branches).
- **OpenCode:** `--continue` re-enters the TUI (`resumeTUICommand`,
  `OpenCodeLaunchArgs`) but does not replay conversation history; `.work`
  launches bare ("MVP doesn't auto-resume").

### Remote control

`supportsRemoteControl` drives whether the remote-control badge is shown for a
harness's sessions
([`CodingAgent.swift`](../Packages/CrowCore/Sources/CrowCore/Agent/CodingAgent.swift)).

- **Claude:** `true`, backed by real `--rc --name` flags
  (`ClaudeLaunchArgs.argsSuffix`). `--name` labels the session in claude.ai's
  Remote Control panel.
- **Cursor & OpenCode:** `true`, but there is **no RC flag** — remote driving is
  `crow send` typing into the interactive TUI (the agent-agnostic stdin path: the
  `send` RPC handler in `EngineRouter.swift` → `TerminalRouter.send`). The badge
  reflects that Crow *can* drive them, not that the agent has a native RC
  protocol.
- **Codex:** `false` — the badge stays off pending end-to-end validation of
  Codex's **experimental** `codex remote-control` / `--remote` app-server path
  (`OpenAICodexAgent`). Unlike Cursor/OpenCode, Codex's TUI isn't stdin-drivable
  the way `crow send` fakes RC for the others, so native RC is the one place
  where flipping this would add real capability — hence "evaluate," not "wire it
  now" (#830).

### Auto-permission

- **Claude:** `--permission-mode auto` (`ClaudeLaunchArgs`), the same knob the
  Manager uses ([ADR 0004](adr/0004-manager-auto-permission-mode.md)).
- **Cursor:** the `autoPermissionMode` argument is accepted and ignored — no
  flag is emitted.
- **Codex:** honored for `.job` sessions via the non-interactive runner —
  `codex exec -a never -s workspace-write` (approval off, sandbox still bounded;
  the analogue of Claude's `--permission-mode auto`, **not** the full-bypass
  `--dangerously-bypass-approvals-and-sandbox` / `-s danger-full-access`, #830).
  Interactive jobs and `.work`/`.review` don't take the knob.
- **OpenCode:** `autoPermissionMode` is honored for `.job` sessions only, via
  **runtime-probed** flags. `OpenCodeLaunchArgs` runs two independently-cached
  probes: the interactive TUI's `--auto` (probed with `opencode --help`, **no**
  fallback) and the headless-`run` auto-approve (probed with `opencode run
  --help`: `--auto`, else `--dangerously-skip-permissions`). Each flag is omitted
  when its probe doesn't advertise it (#547). Reviews never auto-approve.

### Hooks transport & session scope

All harnesses report lifecycle events by shelling out to `crow hook-event`, but
**where the hook config lives** and **how the session is resolved** differ.

- **Claude** — per-worktree `.claude/settings.local.json`, written per session
  with `hook-event --session <UUID>`, so the session is resolved by **UUID**
  ([`ClaudeHookConfigWriter`](../Packages/CrowClaude/Sources/CrowClaude/ClaudeHookConfigWriter.swift)).
- **Cursor** — global `~/.cursor/hooks.json` (override `CURSOR_CONFIG_DIR`).
  Commands carry `--agent cursor` with **no `--session`**; the server resolves
  the session by matching `cwd` in the payload against registered worktrees
  (`CursorHookConfigWriter`). Per-project `.cursor/hooks.json` is deferred.
- **Codex** — global `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`),
  plus a `config.toml` `notify = ["<crow>", "codex-notify"]` line and
  `features.hooks = true`. `cwd`-resolved like Cursor. The `notify` bridge is a
  Tier-2 fallback: `crow codex-notify` translates Codex's post-turn JSON payload
  into a hook event (`CodexNotifyPayload`, `CodexNotify`). Auto-launched sessions
  additionally get per-worktree **project-trust** seeded into `config.toml`
  (`[projects."<worktree>"] trust_level = "trusted"`, `CodexTrustSeeder`) so
  Codex's folder-trust gate never blocks an unattended launch. Per-worktree
  `.codex/hooks.json` (UUID-scoped) is **deferred** — Codex layers project hooks
  atop the global file, so both would fire and the `hook-event` handler would
  double-count; a clean cutover needs server-side (session,event) dedup or
  dropping the global writer (#830).
- **OpenCode** — no command-hook file at all; Crow installs a global **JS
  plugin** `crow-hooks.js` under `~/.config/opencode/plugins/` that subscribes to
  OpenCode's event bus + `tool.execute.*` / `permission.ask` hooks and pipes a
  `{cwd, …}` JSON payload to `crow hook-event --agent opencode`. `cwd`-resolved
  (`OpenCodeHookConfigWriter`).

Only Claude gets **per-session UUID scope**; the other three share the host's
global config and are disambiguated by `cwd`. See
[ADR 0015](adr/0015-harness-capability-tiers.md).

### Hook async delivery

- **Claude:** `PostToolUse` / `PostToolUseFailure` fire async; `PreToolUse` is
  intentionally *not* async so it arrives before `PermissionRequest` and keeps
  state-machine ordering reliable (`ClaudeHookConfigWriter.asyncEvents`).
- **Codex:** **sync-only as of v0.139.0** — declaring `async = true` makes Codex
  silently skip the entry on startup, breaking Crow's state detection;
  `asyncEvents` is deliberately empty (`CodexHookConfigWriter`). *(version-pinned
  re-check target — see below.)*
- **Cursor:** declares `PostToolUse` / `Notification` async, but the timing is
  "one of the three things to confirm empirically" (`CursorSignalSource`).
- **OpenCode:** event *names* are verified; the *timing/semantics* (esp. whether
  `session.idle` is the right "done" signal for interactive TUI sessions) are an
  open empirical question (CROW-545, `OpenCodeHookConfigWriter`).

### MCP (Jira and beyond)

- **Claude:** the initial prompt tells the agent to fetch Jira work items via the
  **`jira` MCP server** (`jira_get_issue`, `jira_*` tools), not `acli`
  (`ClaudeLauncher`, CROW-522). MCP server config lives in Claude Code's own
  `~/.claude.json` (which `ClaudeTrustSeeder` merges into for trust). This is the
  cross-backend prompt-routing case from
  [ADR 0005](adr/0005-task-and-code-backend-protocols.md) (Jira task + GitHub
  code): the ticket is fetched via MCP while the PR is still opened with `gh`.
- **Cursor, Codex, OpenCode:** none have MCP wiring — all three fall back to the
  same `acli jira workitem view <key> --fields …` prompt line
  (`CursorLauncher`, `CodexLauncher`, `OpenCodeLauncher`). The gap is **MCP**,
  not Jira ticket-fetch: every harness can fetch the ticket, just via `acli`
  rather than the `jira` MCP server.

### Review (`/crow-review-pr`)

`SessionService.buildReviewPrompt` branches on `agentKind`:

- **Claude** gets the terse slash-command form `/crow-review-pr <URL>`; the
  bundled `.claude/skills/crow-review-pr/SKILL.md` supplies the instructions.
- **Cursor & OpenCode** have no slash-command engine, so Crow **inlines the whole
  skill body** into the prompt file (`cursorReviewPrompt`, #431).
- **Codex** returns `nil` from `autoLaunchCommand(.review)`:
  *"Review-on-Codex isn't supported in Phase C — the `/crow-review-pr` skill is
  Claude-only."* Crow logs the skip and pastes a `⚠️` echo
  (`OpenAICodexAgent`).

### Initial-prompt injection

Review/job sessions get a pre-written prompt file (`.crow-review-prompt.md` /
`.crow-job-prompt.md`) inlined via shell substitution on first launch. A preflight
in `launchAgent` refuses to dispatch if that file is missing, for **every**
harness (CROW-439) — it's gated on the prompt-file convention, not on agent kind.

- **Claude:** `$(cat …-prompt.md)`, dispatched through the deferred `#408`
  paste path (stash in `pendingLaunchCommands`, paste on `.shellReady`).
- **Cursor:** `agent "$(cat …)"`. `CursorLauncher` (the workspace-skill prompt
  generator) is written but **not yet auto-wired** — Phase-C MVP launches
  `agent` bare for `.work`.
- **Codex:** job only; review returns `nil`.
- **OpenCode:** **run-then-`--continue`** — headless `opencode run "$(cat …)"`
  consumes the prompt reliably, then `; opencode --continue` opens the TUI with a
  fresh stdin so `crow send` keeps working (#547).

### Gateway env / trust seed / telemetry

Three Claude-specific capabilities the protocol doesn't abstract key on Claude
identity (`if …kind == .claudeCode`), because no other harness has an analogue
(gating is exhaustive except the two Manager gateway writes noted below):

- **Trust seeding** — `ClaudeTrustSeeder.seedTrust` pre-trusts the worktree in
  `~/.claude.json` so the "Do you trust the files in this folder?" dialog never
  blocks an auto-launched session (CROW-600). Runs at **four** call sites:
  `SessionService.launchAgent`, `handoffAgent`, and the two Manager paths.
- **AI-gateway env** — two mechanisms for the workspace's `ANTHROPIC_BASE_URL` /
  `ANTHROPIC_CUSTOM_HEADERS` (CROW-402): `ClaudeHookConfigWriter.writeGatewayEnv`
  writes the env block into `settings.local.json` (Claude-gated at `launchAgent`
  and `handoffAgent`), and `ClaudeLaunchArgs.gatewayEnvPrefix` adds the
  launch-line `export …` prefix (at `launchAgent`, plus `managerCommand`'s
  no-registered-agent fallback). The **two** Manager
  gateway writes — `createManagerTerminal` and the hydrate path's
  `writeManagerGatewayEnv` — are **unconditional** (harmless: a non-Claude agent
  ignores `settings.local.json`).
- **OTEL telemetry env** — `AgentLaunch.prepareAgentLaunchText` prepends the
  `OTEL_*` exporter vars, gated on `agent.kind == .claudeCode` (Codex has no OTLP
  equivalent).

These are the residual Claude-identity switches called out in
[ADR 0014](adr/0014-pluggable-coding-agent-adapter.md).

### Rename passthrough

All four override `sessionRenameSlashCommand` to return `"/rename <name>\n"`,
sent after a Crow rename so the agent's own session title stays in sync
(CROW-629). The protocol default is `nil` so a *future* harness can't inherit a
spurious `/rename` paste.

## Handoff between harnesses

`crow handoff-agent --session <UUID> --agent <claude-code|cursor|codex|opencode>
[--note "…"]` switches a running session to a different harness. It preserves the
Crow session identity, worktree, branch, ticket, and links; it does **not**
transfer chat history ([ADR 0011](adr/0011-agent-handoff-preserves-session-not-chat.md)).
A handoff to a harness whose binary isn't on `PATH` throws
`AgentHandoffError.agentNotRegistered` — such a harness was never registered at
boot (`registerAgents` gates on `findBinary()`), and `handoffAgent`'s registry
lookup precedes its binary check. `agentBinaryMissing` is the narrower case where
the harness *was* registered but its binary later vanished. Either way, the
binary-gating from [ADR 0015](adr/0015-harness-capability-tiers.md) surfaces here.

## Version-pinned reasons — re-check targets

Several gaps are pinned to a specific upstream version. Each is a standing
**re-check target**: when the harness ships a new release, confirm the reason
still holds and update this page + [ADR 0015](adr/0015-harness-capability-tiers.md).
This list is the seed for a follow-up capability audit — now performed in
[`agent-harness-gap-audit.md`](agent-harness-gap-audit.md) ([#828](https://github.com/corveil/crow/issues/828)),
which re-checks these pins **and** the capability gaps in ADR 0015's Decision list
against current upstream CLIs.

| Reason | Pin | Source | Last verified |
|---|---|---|---|
| Codex hooks are sync-only (async → silent skip → broken state detection) | Codex **v0.139.0** | `CodexHookConfigWriter.asyncEvents` | 2026-07-24 — **still holds** at codex `~0.146-alpha` (`discovery.rs:480` skips async for every event **except `SessionEnd`**, run synchronously); see [gap audit §2 #4](agent-harness-gap-audit.md) |
| Codex `config.toml` hook key renamed `codex_hooks` → `hooks` | Codex **v0.139.0+** | `CodexHookConfigWriter.installGlobalTomlConfig` | 2026-07-24 |
| Codex reuses Claude's hook engine (`ClaudeHooksEngine`, byte-compatible schemas) | verified against **codex 0.123.0** | `CodexSignalSource` | 2026-07-24 |
| Claude background-recap subagent must not elevate state | Claude Code **≥ 2.1.108** (`awaySummaryEnabled`) | `ClaudeHookSignalSource` | 2026-07-24 |
| Cursor `PostToolUse` / `Notification` async timing unconfirmed | — (empirical) | `CursorSignalSource` | 2026-07-24 |
| OpenCode `session.idle` "done" semantics unconfirmed for TUI | — (CROW-545) | `OpenCodeHookConfigWriter` | 2026-07-24 |
