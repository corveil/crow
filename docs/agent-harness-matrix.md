# Coding-agent harness capability matrix

Crow can drive several coding agents ("harnesses") through one adapter protocol,
[`CodingAgent`](../Packages/CrowCore/Sources/CrowCore/Agent/CodingAgent.swift):
**Claude Code**, **Cursor**, **OpenAI Codex**, **OpenCode** (sst/opencode), and
the Tier-2 **Antigravity** (Google's `agy` CLI). Claude Code is the reference
implementation and the default; the others ship with deliberate gaps, and
Antigravity ships as **Tier-2 / experimental** (closed-source, Google-auth-
locked — see its section below).

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

| Dimension | Claude Code | Cursor | Codex | OpenCode | Antigravity (Tier-2) |
|---|---|---|---|---|---|
| Binary token (`launchCommandToken`) | `claude` | `agent` ⚠️ collision risk | `codex` | `opencode` | `agy` ✅ low collision |
| Registered at boot | **always** (default out of the box) | only if binary found | only if binary found | only if binary found | only if binary found |
| Resume / continue | ✅ `--continue` | ✅ `--continue` (job/review restart, #829) | ✅ `resume --last` | ⚠️ `--continue` re-enters TUI, no history | ⚠️ `-c` (machine-global most-recent; no per-run id, FR #7) |
| Remote control | ✅ native `--rc --name` | ⚠️ faked via `crow send` stdin | ❌ `supportsRemoteControl=false` (experimental `--remote` unwired) | ⚠️ faked via `crow send` stdin | ⚠️ faked via `crow send` stdin (no native RC) |
| Auto-permission | ✅ `--permission-mode auto` | ✅ `--force --approve-mcps` (parity with Claude auto, #829) | ✅ `-a never -s workspace-write` (`.job`, interactive) | ⚠️ runtime-probed `--auto`, `.job` only | ⚠️ `settings.json` modes only (no verified launch flag; never `--dangerously-skip-permissions`) |
| Hooks transport | per-worktree `.claude/settings.local.json` | per-worktree `.cursor/hooks.json` (#829) | global `~/.codex/hooks.json` + `config.toml` `notify` bridge (per-worktree deferred — see below) | global JS plugin `~/.config/opencode/plugins/crow-hooks.js` | per-worktree `.agents/hooks.json` (#860) |
| Hook → session scope | ✅ per-session UUID | ✅ per-session UUID (#829) | ❌ `cwd` match (per-worktree UUID deferred) | ❌ `cwd` match | ✅ per-session UUID |
| Hook async delivery | ✅ `PostToolUse*` async | ⚠️ declared, timing unverified | ❌ sync-only (v0.141.0) | ⚠️ names verified, timing unverified | ❌ no `async` in Antigravity's schema — all sync |
| MCP (e.g. Jira) | ✅ `jira` MCP server via `~/.claude.json` | ✅ `jira` bridged into `~/.cursor/mcp.json` (#829) | ✅ mirrored from `~/.claude.json` into `config.toml` | ❌ falls back to `acli` | ❌ falls back to `acli` (file bridge deferred) |
| Review (`/crow-review-pr`) | ✅ slash-command | ✅ inlined skill body | ✅ inlined skill body | ✅ inlined skill body | ❌ unsupported in Phase A (`autoLaunchCommand(.review)` → nil) |
| Initial-prompt injection | ✅ `$(cat …-prompt.md)` + deferred paste | ✅ `$(cat …)` job/review; handoff launcher auto-wired (#829); `.work` bare | ✅ `.job` + `.review` (`$(cat …-prompt.md)`) | ✅ run-then-`--continue` | ✅ `-p "$(cat …-job-prompt.md)"` (`.job`); `.work` bare |
| Gateway env / trust seed / telemetry | ✅ Claude special-case | ❌ | ⚠️ trust seed only (`[projects."…"]` in `config.toml`) | ❌ | ❌ |
| Rename passthrough (`/rename`) | ✅ | ✅ | ✅ | ✅ | ❌ unverified on v1.1.7 (opt-out `nil`) |
| Self-host / local models | provider-dependent | provider-dependent | provider-dependent | provider-dependent | ❌ **permanent** — closed-source, Google-Sign-In/GCP-locked (Gemini 3 Pro / Claude Sonnet 4.5 only) |

Legend: ✅ full · ⚠️ partial / faked / unverified · ❌ not supported.

> **The grid is Crow's status, not upstream capability.** A ❌/⚠️ means *Crow
> doesn't wire it up* — the upstream CLI may already support it. The
> [harness capability gap audit](agent-harness-gap-audit.md) ([#828](https://github.com/corveil/crow/issues/828))
> re-checked every gap against current upstream (Cursor `2026.07.23`, Codex
> `0.141.0`, OpenCode `1.17.10`+); several now have an upstream flag and a
> spin-off closure ticket. **Cursor's row landed in [#829](https://github.com/corveil/crow/issues/829)**
> (resume, auto-permission `--force --approve-mcps`, per-worktree hooks, `jira`
> MCP bridge); the
> remaining cells below stay at Crow's real status until their tickets land:
>
> | Gap (grid row) | Now available upstream | Closure ticket |
> |---|---|---|
> | Resume / continue | Codex `resume --last`, OpenCode `--continue` (history caveat already closed by #547) | [#830](https://github.com/corveil/crow/issues/830) / [#831](https://github.com/corveil/crow/issues/831) — Cursor ✅ landed #829 |
> | Auto-permission (Codex) | Codex `-a never -s workspace-write` | #830 — Cursor ✅ landed #829 |
> | MCP | `codex mcp`, `opencode mcp` (Cursor has no `mcp add`; file-based `~/.cursor/mcp.json`) | #830 / #831 — Cursor ✅ landed #829 (file bridge) |
> | Review (Codex) | `codex review --base <branch>` / `codex exec review` | #830 |
> | Hook → session scope | `.codex/hooks.json`, `.opencode/plugins/` (per-worktree UUID) | #830 / #831 — Cursor ✅ landed #829 |
> | Remote control (Codex) | experimental `codex remote-control` / `--remote` | #830 (evaluate) |
>
> Still absent upstream: Codex **async hooks** (parsed-but-skipped, except
> `SessionEnd`). See the gap audit for flags, min versions, and closing approaches.
>
> **[#830](https://github.com/corveil/crow/issues/830) (Codex) landed** — the
> Codex cells above now reflect shipped state: `resume --last`, bounded
> `-a never -s workspace-write` on interactive `.job` launches, MCP mirror from
> `~/.claude.json`, and
> per-worktree **project-trust** seeding (`CodexTrustSeeder`). Review uses the
> **inlined `/crow-review-pr` skill body** (like Cursor/OpenCode), *not* the
> native `codex review --base` subcommand: `codex review` only prints local
> findings and posts no GitHub verdict, so a review driven by it could never
> satisfy Crow's completion contract (`decideReviewCompletions` needs a posted
> verdict) and would be re-kicked on every head-SHA advance. **Deferred within
> #830:** per-worktree `.codex/hooks.json` (would double-fire alongside the
> still-needed global writer — both dispatch to the same session, doubling
> notifications; needs server-side event dedup first), retiring the `notify`
> bridge (tied to that hooks cutover), and flipping `supportsRemoteControl`
> (experimental `codex remote-control` needs end-to-end validation). See the gap
> audit §3b update.

## Notes per dimension

Each note cites the source of truth. Line numbers drift; the symbol names are
stable anchors.

### Binary token & registration

Each harness declares a `launchCommandToken` — the binary name Crow resolves on
`PATH` and the token the `send` RPC watches for to decide whether a
managed-terminal command needs hook/env prep.

- Tokens: `claude`, `agent`, `codex`, `opencode`, `agy`
  (`ClaudeCodeAgent`, `CursorAgent`, `OpenAICodexAgent`, `OpenCodeAgent`,
  `AntigravityAgent`).
- **Cursor's token is `agent`, a generic name.** CI runners (Azure DevOps,
  TeamCity) also ship a binary called `agent`; Crow accepts the false-positive
  risk and lets users pin the real path via `defaults.binaries.cursor`
  (`CursorAgent.swift` launch-token comment, CROW-484).
- **Registration order = default.** `AgentRegistry.register` sets the default to
  the *first* kind registered
  ([`AgentRegistry.swift`](../Packages/CrowCore/Sources/CrowCore/Agent/AgentRegistry.swift)).
  `CrowDaemon.registerAgents` registers **Claude unconditionally first** (and
  available), then Codex / Cursor / OpenCode / Antigravity as *known* regardless
  of `PATH`, marking each **available** only if `findBinary()` resolves
  ([`CrowDaemon.swift`](../Packages/CrowDaemon/Sources/CrowDaemon/CrowDaemon.swift),
  `registerAgents`; #879). Available agents enter the launchable map; a harness
  whose binary is off `PATH` is **shown disabled in the picker** (greyed-out with
  a "not found on `PATH`" tooltip) and kept out of the launchable map, so a
  handoff to it still throws `agentNotRegistered` — surfaced-but-not-launchable,
  see [ADR 0015](adr/0015-harness-capability-tiers.md). Antigravity's `agy` gate is
  also the safe default while its supply-chain provenance is confirmed (Crow
  never installs `agy`; it only resolves what the official installer placed).
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
- **Cursor:** review/job sessions read their prompt file on first launch, then
  resume with `--continue` on restart (`CursorAgent.autoLaunchCommand`, #829);
  `.work` launches bare (deliberate — the user types into the TUI).
- **Codex:** no `--continue` equivalent in the MVP — a restart drops the user
  back into a bare TUI rather than re-running the prompt
  (`OpenAICodexAgent` `.job` branch).
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
- **Cursor:** `--force --approve-mcps` (`CursorLaunchArgs.autoPermissionSuffix`,
  #829) — approval off + auto-approve MCP, **genuine parity** with Claude's auto
  mode (which imposes no sandbox). Applied to `.job`/`.review`, the opt-in work
  coder view, and the Manager. Deliberately **not**: `--sandbox enabled` (it
  blocks network at the syscall level — `.review`'s `gh pr review`, `.job`'s
  `git push`, and the Manager's `crow`-socket / `gh` / sibling `git worktree add`
  all need network the sandbox would kill; `--sandbox` is left unset so Cursor
  honors the user's own config), `--yolo`, the undocumented `--auto-review`, or
  the headless-only `--trust`.
- **Codex:** honored for `.job` sessions on the **interactive** launch —
  `codex -a never -s workspace-write "$(cat …-prompt.md)"` (approval off, sandbox
  still bounded; the analogue of Claude's `--permission-mode auto`, **not** the
  full-bypass `--dangerously-bypass-approvals-and-sandbox` / `-s danger-full-access`,
  #830). It is deliberately **not** headless `codex exec`: `exec` is one-shot, so
  for a multi-prompt job it would exit after the first prompt and `JobScheduler`'s
  typed follow-up prompts would land at the shell (which executes prose). The TUI
  stays alive and consumes typed lines as prompts, like every other agent's job
  path. `.work` doesn't take the knob. `.review` is **human-gated**: it runs the
  inlined skill interactively, so an unattended review (`reviewAutoPermissionMode`
  on) stalls at Codex's first approval prompt until someone approves the `gh`
  call — the same property Cursor's review has. It is *not* wired to headless
  `exec` because `workspace-write` blocks network, so `gh pr review` can't post
  from inside the sandbox; enabling `[sandbox_workspace_write] network_access`
  would lift that but is a **global** Codex setting (it would change the sandbox
  for all of the user's Codex usage, not just Crow's), so it's left out pending
  a per-project scoping story.
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
- **Cursor** — per-worktree `.cursor/hooks.json`, written per session with
  `hook-event --session <UUID>`, resolved by **UUID** (#829,
  `CursorHookConfigWriter`). No global config: Cursor merges global + project and
  runs both, so a global config would double-fire; `removeManagedGlobalConfig`
  migrates users off any a prior Crow installed. Write/remove operate at group
  level and key on a Crow marker, so a user's own hook in the (shared, committed)
  `.cursor/hooks.json` is preserved. An *untracked* file is git-excluded so it
  isn't committed; a repo that already *commits* `.cursor/hooks.json` (where
  exclude has no effect) makes the write skip entirely rather than push a
  machine-local path + dead UUID into the shared repo — that worktree loses
  hook-based state detection (logged; a session-visible warning is a fast-follow).
  This is also what makes the **Manager** hookable — the devRoot isn't
  a registered worktree, so the old `cwd` match could never route it.
- **Codex** — global `$CODEX_HOME/hooks.json` (default `~/.codex/hooks.json`),
  plus a `config.toml` `notify = ["<crow>", "codex-notify"]` line and
  `features.hooks = true`. `cwd`-resolved like Cursor. The `notify` bridge is a
  Tier-2 fallback: `crow codex-notify` translates Codex's post-turn JSON payload
  into a hook event (`CodexNotifyPayload`, `CodexNotify`). Auto-launched
  **`.work`/`.job` worktrees and the Manager devRoot** additionally get
  per-worktree **project-trust** seeded into `config.toml`
  (`[projects."<worktree>"] trust_level = "trusted"`, `CodexTrustSeeder`) so
  Codex's folder-trust gate never blocks an unattended launch. **`.review`
  clones are deliberately not trust-seeded** — their working tree is `gh repo
  clone` output at the PR author's head (attacker-controlled), and trusting it
  would arm a committed `.codex/hooks.json`; they fall back to Codex's folder-
  trust prompt (the human-gated path), and `prepareReviewClone` strips any
  committed `.codex/` as defense-in-depth (#843). Per-worktree
  `.codex/hooks.json` (UUID-scoped) is **deferred** — Codex layers project hooks
  atop the global file, so both would fire and the `hook-event` handler would
  double-count; a clean cutover needs server-side (session,event) dedup or
  dropping the global writer (#830).
- **OpenCode** — no command-hook file at all; Crow installs a global **JS
  plugin** `crow-hooks.js` under `~/.config/opencode/plugins/` that subscribes to
  OpenCode's event bus + `tool.execute.*` / `permission.ask` hooks and pipes a
  `{cwd, …}` JSON payload to `crow hook-event --agent opencode`. `cwd`-resolved
  (`OpenCodeHookConfigWriter`).

Only Claude and Cursor get **per-session UUID scope**; Codex and OpenCode share
the host's global config and are disambiguated by `cwd`. See
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
- **Cursor:** the `jira` MCP is **bridged** — `CursorMCPConfigWriter` copies the
  user's `jira` server from `~/.claude.json` (root `mcpServers` or the default
  project-local `projects[<path>].mcpServers`) into `~/.cursor/mcp.json` (#829).
  Cursor's CLI has **no `cursor-agent mcp add`** on the audited build, so the
  config is file-based, not a CLI call; unattended runs add `--approve-mcps` so
  the bridged server auto-approves, and the `CursorLauncher` prompt instructs the
  `jira_*` MCP tools (with `acli` as a fallback), matching Claude. It runs
  **when a Cursor agent actually launches** (worker auto-launch, Manager,
  handoff, and the brand-new-terminal deferred paste / `crow send` via
  `AgentLaunch`), not at boot — so it fires for Cursor selected via config *or*
  per-session (`handoff-agent`, the Manager picker), and never copies the token
  onto a box that merely has a binary named `agent`.
  The bridged entry is Crow-marked (a top-level `x-crow-managed` list, so the
  server def stays byte-identical to Claude's): a user's own `jira` is never
  clobbered, and the copy is withdrawn only when `~/.claude.json` parses cleanly
  with no `jira` (an unreadable read is left alone). No-op when no Jira MCP is
  configured.
- **Codex, OpenCode:** no MCP wiring — both fall back to the same
  `acli jira workitem view <key> --fields …` prompt line
  (`CodexLauncher`, `OpenCodeLauncher`). The gap is **MCP**, not Jira
  ticket-fetch: every harness can fetch the ticket, just via `acli` rather than
  the `jira` MCP server.

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
- **Cursor:** `agent "$(cat …)"` for job/review (path shell-quoted). The
  interactive TUI takes the positional prompt directly, so no headless `-p` leg
  is needed; `CursorLauncher.launchCommand` feeds the prompt on agent handoff
  (#829). `.work` launches `agent` bare (the user types into the TUI).
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

## Antigravity (Tier-2 / experimental)

Google Antigravity's CLI (binary **`agy`**) is the terminal surface of Google's
agent-first dev platform (IDE + CLI + SDK, launched with Gemini 3). Crow drives
it through the same `CodingAgent` protocol as the others — its adapter
(`CrowAntigravity`) is structurally a **near-clone of `CrowCursor`**: hooks feed
lifecycle events (JSON on stdin, JSON verdict on stdout) so the
`HookConfigWriter`/`StateSignalSource` pair does real work; per-worktree
`.agents/hooks.json` with the session UUID baked in (per-session scope, not
`cwd`); remote control faked via `crow send`; `.review` unsupported in Phase A
(no review dispatch — unlike Codex/Cursor/OpenCode, which inline the skill body).
It ships **Tier-2** ([ADR 0015](adr/0015-harness-capability-tiers.md))
with honest, documented gaps (#860).

**Hooks are its single strongest point — but the schema is Antigravity's own,
not Claude's.** Verified against [`antigravity.google/docs/hooks`](https://antigravity.google/docs/hooks):
`hooks.json` is a map of **named groups** → event configs (`{"crow": {…}}`), not
Claude's `{"hooks": {Event: […]}}`. Tool events (`PostToolUse`) wrap handlers in
`{matcher:"*", hooks:[…]}`; invocation/`Stop` events list handlers directly under
the event key; there is **no `async` field**. Each hook command reads its stdin
event, forwards it to `crow hook-event`, then `printf '{}'`s the stdout verdict
itself (`crow hook-event` is observational) and exits 0 — so a Crow hook can
never block a tool or loop the agent. `Stop` carries `fullyIdle` +
`terminationReason` (`model_stop`/`max_steps_exceeded`/`error`) →
`AntigravitySignalSource` maps **any `Stop`** to `.done` (it does *not* gate on
`fullyIdle`/`terminationReason` — the pinned `AgentHookEvent` doesn't surface
those; refining on them is a version-pinned follow-up); `PreInvocation` →
working; `PostToolUse` → working-heartbeat. **`PreToolUse` is deliberately not
registered** — it demands a strict `{"decision":…}` stdout verdict and a
mis-shaped reply denies every tool call (cmux #5358), so — like Antigravity's own
bundled vibe-island plugin — Crow stays off it. **Consequence — named tool
activity is a Tier-2 gap:** `PostToolUse` stdin carries no tool name (only
`stepIdx`/`error`), and `toolCall.name` lives on `PreToolUse` alone, so Crow can
signal "a tool ran, still working" but not *which* tool. `EngineRouter`'s
`hookToolName` reads `tool_name` or the nested `toolCall.name` (future-proofing a
`PreToolUse` re-enable; a no-op for the currently-registered events). Gaps: no
`--output-format json`/`stream-json` (upstream FRs
#119/#597), no ACP/JSON-RPC (FR #31), no dedicated "awaiting-input" event, and
headless `-p` historically drops stdout on a **non-TTY** — which doesn't bite
Crow because it launches `agy` inside a tmux PTY, so no shim is needed on the
`.job` `-p` path.

**Permanent gap — self-host.** The `agy` binary is **closed-source** and auth is
**Google Sign-In / GCP**, so it runs only against Google's cloud models (Gemini
3 Pro default, Claude Sonnet 4.5) — never an arbitrary self-hosted/local model.
That fails Corveil's self-host axis and is a **fixed** gap, not a phase.

**⚠️ Supply-chain note (the gate this adapter was built behind).** The
`google-antigravity` GitHub org is `is_verified: false` (confirmed via
`gh api orgs/google-antigravity`), was created 2025-11-04, and is **not** one of
Google's canonical orgs (`google`, `google-gemini`); its `antigravity-cli` repo
is README-only (no source, no license) — a community mirror/tracker. Crow's
`findBinary()`/`fallbackCandidates` are therefore **never** wired to that org's
release binaries: resolution is PATH-first (picking up whatever the **official**
`antigravity.google` installer placed), with only conservative standard-bin
fallbacks (`/opt/homebrew/bin/agy`, `/usr/local/bin/agy`, `~/.local/bin/agy`,
`~/.antigravity/bin/agy`). Off-`PATH` `agy` ⇒ silently unregistered (ADR 0014),
the safe default. **The exact official install path must be confirmed before
Antigravity is promoted out of Tier-2.**

## Handoff between harnesses

`crow handoff-agent --session <UUID> --agent <claude-code|cursor|codex|opencode|antigravity>
[--note "…"]` switches a running session to a different harness. It preserves the
Crow session identity, worktree, branch, ticket, and links; it does **not**
transfer chat history ([ADR 0011](adr/0011-agent-handoff-preserves-session-not-chat.md)).
A handoff to a harness whose binary isn't on `PATH` throws
`AgentHandoffError.agentNotRegistered` — since #879 such a harness is registered
as *known-but-unavailable* and kept out of the launchable `agents` map (the web
handoff menu shows it as a disabled row rather than offering it), so
`handoffAgent`'s registry lookup — which precedes its binary check — misses it.
`agentBinaryMissing` is the narrower case where the harness *was* available but
its binary later vanished. Either way, the binary-gating from
[ADR 0015](adr/0015-harness-capability-tiers.md) surfaces here.

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
| Antigravity flags (`agy` hooks events, `-p` non-TTY stdout, `-c`/`--conversation` resume) | `agy` **v1.1.7 (2026-07-26)** | `AntigravityAgent` / `AntigravityHookConfigWriter` | 2026-07-26 — re-probe on upgrade |
| Antigravity structured-stdout (would promote toward first-class parity) | upstream FRs **#119/#597** (`--output-format stream-json`), **#31** (ACP) | `AntigravitySignalSource` | 2026-07-26 — hooks are the only transport until either lands |
| Antigravity bounded auto-permission has no verified interactive launch flag | `agy` **v1.1.7**; headless `-p` ignores `permissions.allow` (issue #548) | `AntigravityLaunchArgs.autoPermissionSuffix` | 2026-07-26 |
| Antigravity official-installer provenance (supply-chain gate) unconfirmed | `google-antigravity` org `is_verified: false`; pin `antigravity.google` | `AntigravityAgent.fallbackCandidates` | 2026-07-26 — confirm before promoting out of Tier-2 |
