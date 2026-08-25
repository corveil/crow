# Coding-agent harness capability matrix

Crow can drive several coding agents ("harnesses") through one adapter protocol,
[`CodingAgent`](../Packages/CrowCore/Sources/CrowCore/Agent/CodingAgent.swift):
**Claude Code**, **Cursor**, **OpenAI Codex**, **OpenCode** (sst/opencode),
**Grok Build** (xai-org/grok-build), the Tier-2 **Antigravity** (Google's
`agy` CLI), and the Tier-2 **Muse Code** (Meta's `muse` CLI). Claude Code is the reference implementation and the default; the
others ship with deliberate gaps, and Antigravity / Muse ship as **Tier-2 /
experimental** (closed-source, vendor-auth-locked — see their sections below).

This page is the living reference for **what each harness can do and why the
gaps exist**. The *architecture* of the adapter is
[ADR 0014](adr/0014-pluggable-coding-agent-adapter.md); the *rationale for the
gaps* (capability tiers + phased parity) is
[ADR 0015](adr/0015-harness-capability-tiers.md). When you change a harness's
capabilities, update this table in the same PR.

> **Scope.** "Harness" here means a *coding agent* (`CodingAgent` /
> `AgentKind`). Do not confuse it with the *task/code provider* abstraction
> (`TaskBackend` / `CodeBackend` for GitHub / GitLab / Jira), which is
> a separate axis governed by [ADR 0005](adr/0005-task-and-code-backend-protocols.md).
> A session pairs one harness with one (or two) providers.
>
> The **MCP** row below is likewise about a harness *consuming* MCP servers the
> user configured. `crowd` also *serves* a read-only MCP surface of its own
> ([docs/mcp.md](mcp.md), [ADR 0019](adr/0019-read-only-mcp-server.md)) — the
> opposite direction on the same wire, and not a harness capability.

## The matrix

| Dimension | Claude Code | Cursor | Codex | OpenCode | Grok Build | Antigravity (Tier-2) | Muse Code (Tier-2) |
|---|---|---|---|---|---|---|---|
| Binary token (`launchCommandToken`) | `claude` | `cursor-agent` ✅ (alias `agent` ⚠️ collides with grok-build) — identity-probed | `codex` | `opencode` | `grok` ⚠️ collision (`grok-cli`) — identity-probed | `agy` ✅ low collision | `muse` ⚠️ collision (Muse Sequencer) — identity-probed |
| Registered at boot | **always** (default out of the box) | only if binary found | only if binary found | only if binary found | only if binary found | only if binary found | only if binary found |
| Resume / continue | ✅ `--continue` | ✅ `--continue` (job/review restart, #829) | ✅ `resume --last` | ⚠️ `--continue` re-enters TUI, no history | ✅ `-c`/`-r` (run-then-`-c`; job/review restart) | ⚠️ `-c` (machine-global most-recent; no per-run id, FR #7) | ⚠️ `muse resume` after `muse exec --prompt-file` (workspace-scoped; `--session-id` unused — needs-eval) |
| Remote control | ✅ native `--rc --name` | ⚠️ faked via `crow send` paste | ⚠️ faked via `crow send` paste (native `remote-control` unwired — see below) | ⚠️ faked via `crow send` paste | ⚠️ faked via `crow send` paste (native ACP `grok agent serve` deferred) | ⚠️ faked via `crow send` paste (no native RC) | ⚠️ faked via `crow send` paste (no native RC) |
| Auto-permission | ✅ `--permission-mode auto` | ✅ `--force --approve-mcps` (parity with Claude auto, #829) | ✅ `-a never -s workspace-write` (`.job`, interactive) | ⚠️ runtime-probed `--auto`, `.job` only | ✅ `--always-approve` + hard `--deny` (`rm -rf /` literals) on `.work`/`.job` when Crow Auto is on (CROW-1037); reviews stay human-gated | ⚠️ `settings.json` modes only (no verified launch flag; never `--dangerously-skip-permissions`) | ⚠️ `--disable-approval` (sandbox stays; **never** `--yolo` / `--disable-sandbox`) on `.job`/`.review`/Manager when auto-perm is on |
| Hooks transport | per-worktree `.claude/settings.local.json` | per-worktree `.cursor/hooks.json` (#829) | per-worktree `.codex/hooks.json` (CROW-1060; `config.toml` `[features] hooks = true` enables the subsystem) | per-worktree `.opencode/plugins/crow-hooks.js` (CROW-831; global `~/.config/opencode/plugins/` fallback self-suppresses) | per-worktree `.grok/hooks/crow.json` | per-worktree `.agents/hooks.json` (#860) | per-worktree `.muse/hooks.json` (Claude-compatible schema; **needs-eval** — JSON shape not confirmed against a real binary) |
| Hook → session scope | ✅ per-session UUID | ✅ per-session UUID (#829) | ✅ per-session UUID (CROW-1060; notify bridge retired) | ✅ per-session UUID (CROW-831) | ✅ per-session UUID | ✅ per-session UUID | ✅ per-session UUID (baked into the command) |
| Hook async delivery | ✅ `PostToolUse*` async | ⚠️ declared, timing unverified | ✅ `PostToolUse` async, **gated on `codex ≥ 0.148.0`** (older → sync; CROW-999/1060) — timing safe by construction (CROW-1065) | ⚠️ names verified, timing unverified | ❌ sync-only (async support unverified) | ❌ no `async` in Antigravity's schema — all sync | ❌ sync-only (async field unverified; declaring one risks a parse failure) |
| MCP (e.g. Jira) | ✅ `jira` MCP server via `~/.claude.json` | ✅ `jira` bridged into `~/.cursor/mcp.json` (#829) | ✅ mirrored from `~/.claude.json` into `config.toml` | ✅ mirrored from `~/.claude.json` into `opencode.json` (CROW-831) | ❌ falls back to `acli` (Jira MCP bridge deferred; Grok *does* read Claude/Cursor MCP configs) | ❌ falls back to `acli` (file bridge deferred) | ❌ falls back to `acli` (file bridge deferred; Muse reads `mcp_servers` in `~/.config/muse/settings.json`) |
| Review (`/crow-review-pr`) | ✅ slash-command | ✅ inlined skill body | ✅ inlined skill body | ✅ inlined skill body | ✅ inlined skill body (human-gated) | ✅ inlined skill body (#902) | ✅ inlined skill body (#1033); strip-not-trust |
| Initial-prompt injection | ✅ prompt-file contents as argv + deferred paste | ✅ job/review, `--`-separated (CROW-968); handoff launcher auto-wired (#829); `.work` bare | ✅ `.job` + `.review` (prompt-file contents as argv) | ✅ run-then-`--continue` | ✅ run-then-`-c` (`.job`/`.review`); `.work` bare | ✅ `-p "$prompt"` (`.job`/`.review`, #902); `.work` bare | ✅ `muse exec --prompt-file` then `muse resume` (`.job`/`.review`); `.work` bare TUI |
| Gateway env / trust seed / telemetry | ✅ Claude special-case | ⚠️ trust seed only (`--trust`, per-launch, every kind) | ⚠️ trust seed only (`[projects."…"]` in `config.toml`) | ❌ | ⚠️ trust seed only (`[folders."…"]` in `~/.grok/trusted_folders.toml`) | ❌ | ⚠️ trust seed only (`--trust-workspace`, per-launch, withheld from `.review`) |
| Rename passthrough (`/rename`) | ✅ | ✅ | ✅ | ✅ | ✅ (alias `/title`) | ❌ unverified on v1.1.7 (opt-out `nil`) | ❌ unverified (documented slash set has no `/rename`; opt-out `nil`) |
| Interactive TUI uses alt screen (`smcup`) | ✅ Claude Code requests it | ❌ inline renderer — unified 50k scrollback like a shell (CROW-1010) | ❌ **verified** inline (`alternate_on=0`, 0.141.0, CROW-1001) | ❌ unverified; inherits inline default | ❌ unverified; inherits inline default | ❌ unverified; inherits inline default | ❌ unverified; inherits inline default |
| Self-host / local models | provider-dependent | provider-dependent | provider-dependent | provider-dependent | ✅ `config.toml` `[model.*]` → any OpenAI/Anthropic-compatible or local (Ollama) endpoint | ❌ **permanent** — closed-source, Google-Sign-In/GCP-locked (Gemini 3 Pro / Claude Sonnet 4.5 only) | ❌ **permanent** — closed-source, Meta-auth-locked (browser sign-in or `META_API_KEY`; default model Muse Spark 1.2) |

Legend: ✅ full · ⚠️ partial / faked / unverified · ❌ not supported.

> **The grid is Crow's status, not upstream capability.** A ❌/⚠️ means *Crow
> doesn't wire it up* — the upstream CLI may already support it. The
> [harness capability gap audit](agent-harness-gap-audit.md) ([#828](https://github.com/corveil/crow/issues/828))
> re-checked every gap against current upstream (Cursor `2026.07.23`, Codex
> `0.141.0`, OpenCode `1.17.10`+); several now have an upstream flag and a
> spin-off closure ticket. **Cursor's row landed in [#829](https://github.com/corveil/crow/issues/829)**
> (resume, auto-permission `--force --approve-mcps`, per-worktree hooks, `jira`
> MCP bridge), **Codex's in [#830](https://github.com/corveil/crow/issues/830)**,
> and **OpenCode's in [#831](https://github.com/corveil/crow/issues/831)** (MCP
> mirror + per-worktree `.opencode/plugins/` UUID hooks); any cell still ❌/⚠️
> stays at Crow's real status until its ticket lands:
>
> | Gap (grid row) | Now available upstream | Closure ticket |
> |---|---|---|
> | Resume / continue | Codex `resume --last`, OpenCode `--continue` (history caveat already closed by #547) | #830 ✅ / #831 ✅ landed — Cursor ✅ landed #829 |
> | Auto-permission (Codex) | Codex `-a never -s workspace-write` | #830 ✅ landed — Cursor ✅ landed #829 |
> | MCP | `codex mcp`, `opencode mcp` (Cursor has no `mcp add`; file-based `~/.cursor/mcp.json`) | #830 ✅ / #831 ✅ landed — Cursor ✅ landed #829 (file bridge) |
> | Review (Codex) | `codex review --base <branch>` / `codex exec review` | #830 ✅ landed |
> | Hook → session scope | `.codex/hooks.json`, `.opencode/plugins/` (per-worktree UUID) | #830 ✅ / #831 ✅ landed — Cursor ✅ landed #829 |
> | Remote control (Codex) | experimental `codex remote-control` / `--remote` | ✅ **closed [CROW-1001](https://github.com/corveil/crow/issues/1001)** — badge flipped on the `crow send` path; native RC pinned as non-viable |
>
> Codex **async hooks** are no longer absent upstream: they landed in
> `0.148.0` and Crow now emits them behind a version probe
> ([CROW-999](https://github.com/corveil/crow/issues/999)). See the gap audit
> for flags, min versions, and closing approaches.
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
> verdict) and would be re-kicked on every head-SHA advance. **Closed by
> [CROW-1060](https://github.com/corveil/crow/issues/1060):** the two
> hook-scope deferrals from #830 landed together — Codex now writes per-worktree
> `.codex/hooks.json` with `--session <uuid>` baked in (the same good tier as
> Cursor/Grok/Muse), the retired global `~/.codex/hooks.json` writer is stripped
> once at daemon boot (`removeManagedGlobalConfig`, so no double-fire during
> migration), and the `notify`→`CodexNotifyCommand` bridge is gone (the
> per-worktree `Stop` hook drives `.done` on its own). The third deferral —
> flipping `supportsRemoteControl` — was **closed by
> [CROW-1001](https://github.com/corveil/crow/issues/1001)**, though not on the
> premise #830 recorded: the flag is `true` because the shared `crow send` paste
> path drives the Codex TUI (verified end-to-end on 0.141.0), *not* because
> native `codex remote-control` was validated. That path is pinned non-viable —
> see the Remote control note below. See the gap audit §3b update.
>
> **[#831](https://github.com/corveil/crow/issues/831) (OpenCode) landed** — the
> OpenCode cells above now reflect shipped state. Hooks moved off the host-global
> plugin: `OpenCodeHookConfigWriter` writes a **per-worktree**
> `<worktree>/.opencode/plugins/crow-hooks.js` with `--session <uuid>` baked in
> (per-session UUID scope, not `cwd`), and the global
> `~/.config/opencode/plugins/crow-hooks.js` installed at boot is a
> self-suppressing fallback — its plugin body returns no hooks whenever a
> per-project `crow-hooks.js` exists, so the two never double-fire. MCP is wired:
> `OpenCodeMCPConfigWriter` mirrors the user's `jira` server from `~/.claude.json`
> into `<configHome>/opencode.json` (`mcp.jira`) at daemon boot from
> `LaunchScaffold`, the file-based analogue of Codex's `config.toml` mirror. The
> remaining OpenCode gaps are unchanged: `.work` still launches bare (a product
> choice, not a missing flag), and native RC stays a `crow send` paste.

## Notes per dimension

Each note cites the source of truth. Line numbers drift; the symbol names are
stable anchors.

### Binary token & registration

Each harness declares a `launchCommandToken` — the binary name Crow resolves on
`PATH` and the token the `send` RPC watches for to decide whether a
managed-terminal command needs hook/env prep.

- Tokens: `claude`, `cursor-agent`, `codex`, `opencode`, `grok`, `agy`, `muse`
  (`ClaudeCodeAgent`, `CursorAgent`, `OpenAICodexAgent`, `OpenCodeAgent`,
  `GrokAgent`, `AntigravityAgent`, `MuseAgent`).
- **Cursor ships two names for one executable**, and Crow prefers the
  unambiguous `cursor-agent`; the generic `agent` is kept as an
  `alternateLaunchCommandTokens` alias for older installs. The generic name
  genuinely collides: CI runners (Azure DevOps, TeamCity) ship an `agent`, and —
  observed in the field — **xAI's grok-build installs `~/.grok/bin/agent`**
  (mirrored into `~/.local/bin/agent`). On a box with grok-build ahead of Cursor
  on PATH, `agent` resolved to grok-build, so Crow built a Cursor command and ran
  Grok's binary, which died on the first flag it lacks
  (`error: unexpected argument '--force' found`) — CROW-989, the risk CROW-484
  accepted actually firing. Four defenses now:
  - **Preferred-name-first PATH walk.** `resolveBinary()` is *token-major*: every
    PATH entry is searched for `cursor-agent` before any is searched for `agent`
    (`BinaryTokenResolver.firstOnPath`), so resolution depends on the name rather
    than on install order. Reordering PATH cannot change the selection.
  - **Identity probe** on a bare `agent` match, the CROW-911 seam Grok already
    used. `cursor-agent --help` is matched against `CursorAgent.identityMarkers`
    (`--approve-mcps`, `--trust`, `CURSOR_API_KEY`, `CURSOR_API_ENDPOINT` — the
    flags this adapter actually passes, so the probe answers exactly the question
    the launch depends on). A grok-build `agent` carries none of them and is
    reported unavailable, naming the resolved path, instead of launching and
    failing on flag parsing. `defaults.binaries.cursor` still pins and bypasses
    the probe.
  - **Multi-candidate walk** (CROW-1058, closing the residual CROW-989 left
    open). Discovery no longer judges a token by its first sample:
    `resolveBinaryCandidates()` returns **every** PATH hit across
    `binaryTokens` (still token-major) plus every executable
    `fallbackCandidates` entry, and `AgentDiscovery.evaluate` probes down that
    list until one verifies. A machine whose *only* `cursor-agent` sits behind
    grok-build's `agent` on PATH now registers Cursor instead of greying it out.
    Cost is unchanged for a healthy install — the preferred name is sampled
    first, so the loop exits after one spawn.
  - **Verified-path pin at launch** (CROW-1058). Registration records the path
    that passed the probe in `VerifiedBinaries`, and every launch path reads
    `launchBinary()` rather than `findBinary()`. This is the half of the field
    report that discovery alone could not explain: `findBinary()` re-walked PATH
    on *every* launch and could return a different `agent` than the one boot had
    identified, so a session configured as Cursor exec'd grok-build even with
    `cursor-agent` installed and the boot probe passing. `launchBinary()` is
    pin → verified path → (for an agent that declares an alias) the unambiguous
    preferred name only — so no Cursor launch text can name a `…/bin/agent`
    under any resolution outcome. Its last-resort fallback is the bare
    `cursor-agent` token, which cannot be grok-build: worst case is an honest
    `command not found`, never the wrong agent. Alias-free agents (every other
    harness) are unaffected by the narrowing but still get the pin, which matters
    now that discovery may probe past a first candidate.
- **Grok's token is `grok`, which collides** with the community
  `superagent-ai/grok-cli` (also installs `grok`). Registration **identity-probes**
  a bare PATH/fallback match — `grok --help` (then `--version`), matched against
  grok-build-specific flag markers in `GrokAgent.identityMarkers` — and shows
  Grok Build **disabled** when the resolved binary is the foreign `grok-cli`
  (`GrokAgent.verifyBinaryIdentity`, CROW-911). The decision is the pure
  `AgentDiscovery.evaluate` (resolve → probe a non-override match), which
  `CrowDaemon.registerAgents` wraps with registry writes + logging. An explicit
  `defaults.binaries.grok` pin is authoritative and **skips the probe**;
  `BinaryOverrides` keys on `AgentKind.rawValue` = `"grok"`. Cursor and Grok share
  one implementation of the bounded subprocess race (`BinaryIdentityProbe`,
  CROW-989) rather than each carrying a copy.
- **Muse's token is `muse`, which collides** with the Muse Sequencer
  (`muse-sequencer.github.io`) and any other same-named tool. Registration
  **identity-probes** a bare PATH/fallback match — `muse --help` (then
  `--version`), matched against Muse Code flag markers in
  `MuseAgent.identityMarkers` (`--disable-approval`, `--trust-workspace`,
  `--sandbox-network`, `--prompt-file`) — and shows Muse Code **disabled** when
  the resolved binary is a foreign `muse`. An explicit `defaults.binaries.muse`
  pin is authoritative and **skips the probe**. Crow never downloads `muse`
  itself: the official installer (`curl -fsSL https://dev.meta.ai/install.sh`)
  writes `~/.local/bin/muse`; Crow only resolves what that installer placed.
  ⚠️ **Trust-boundary delta:** `crowd` now *executes* the PATH-resolved binary
  (an unvetted third-party one) at boot to probe it — inherent to identity
  probing, on the user's own PATH, output only substring-matched (never logged
  or evaluated); the probe is hard-bounded so a hanging binary can't stall boot
  (`BinaryIdentityProbe.run`).
- **Registration order = default.** `AgentRegistry.register` sets the default to
  the *first* kind registered
  ([`AgentRegistry.swift`](../Packages/CrowCore/Sources/CrowCore/Agent/AgentRegistry.swift)).
  `CrowDaemon.registerAgents` registers **Claude unconditionally first** (and
  available), then Codex / Cursor / OpenCode / Antigravity / Grok / Muse as *known* regardless
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
- **Codex:** review/job sessions read their prompt file on first launch, then
  resume with `codex resume --last` on restart; `.work` also relaunches with
  `codex resume --last` rather than dropping into a bare TUI
  (`OpenAICodexAgent.autoLaunchCommand`, #830 — the earlier MVP no-resume pin is
  retired).
- **OpenCode:** review/job sessions run headless `opencode run "$prompt"` on
  first launch, then chain `; opencode --continue` to reopen the same session in
  the TUI on restart (`resumeTUICommand` / `firstLaunchChainedCommand`,
  `OpenCodeLaunchArgs`, #547); `.work` launches bare (a deliberate product
  choice — the user types into the TUI — not a missing resume flag).

### Remote control

`supportsRemoteControl` drives whether the remote-control badge is shown for a
harness's sessions
([`CodingAgent.swift`](../Packages/CrowCore/Sources/CrowCore/Agent/CodingAgent.swift)).
It is **only** a badge input: `crow send` never consults it, so the flag
describes what the UI claims, not what Crow can do.

> **Two different gates, worth knowing before reading a badge.** Work / job /
> review sessions light the badge on `rcEnabled && agent.supportsRemoteControl`
> (`SessionService.launchAgent`), but the **Manager** lights it on the literal
> `" --rc"` appearing in its built command (`ensureManagerSession`, CROW-433).
> So on every harness whose `true` is the `crow send` fake — Cursor, Codex,
> OpenCode, Grok, Antigravity — a Manager shows no badge while that harness's
> ordinary sessions do, even though `crow send` drives both identically. That
> asymmetry predates CROW-1001 and is unchanged by it. Muse joins the same set.

- **Claude:** `true`, backed by real `--rc --name` flags
  (`ClaudeLaunchArgs.argsSuffix`). `--name` labels the session in claude.ai's
  Remote Control panel.
- **Cursor, OpenCode, Grok, Antigravity & Muse:** `true`, but there is **no RC
  flag** — remote driving is `crow send` pasting into the interactive TUI (the
  agent-agnostic path: the `send` RPC handler in `EngineRouter.swift` →
  `TerminalRouter.send`). The badge reflects that Crow *can* drive them, not
  that the agent has a native RC protocol.
- **Codex was `false` on a premise that turned out to be wrong.** The reason
  recorded here and in ADR 0015 was that "Codex's TUI isn't stdin-drivable the
  way `crow send` fakes RC for the others." Two things were off. First,
  `crow send` never touches stdin: `TerminalRouter.send` → `TmuxBackend.sendText`
  is tmux `load-buffer` → `paste-buffer` → `send-keys Enter`, a **paste into the
  pane**, so a TUI that refuses stdin is not thereby undrivable. Second, Codex
  accepts it. Verified end-to-end against `codex-cli 0.141.0` in a live tmux
  pane (CROW-1001): the pasted payload lands in the composer verbatim and the
  trailing Enter submits it. So Codex sessions were **already** drivable from
  Crow's web UI — `crow send` never consulted `supportsRemoteControl`, which
  only feeds the badge and `remoteControlActiveTerminals` — and the flag was a
  false negative. It is now `true`, on the same footing as the four harnesses
  above.

  The grid row above says "paste", not "stdin", for **every** harness for the
  same reason: the stdin framing is what made this cell wrong for four releases.
  A reader who believes `crow send` writes stdin will keep asking whether a
  given TUI reads stdin, which is not the question.

  Native `codex remote-control` is **not** the reason, and stays unwired. Three
  blockers, any one of them disqualifying:

  1. **Wrong install channel.** `codex remote-control start` refuses on the npm
     build: *"managed standalone Codex install not found at
     `~/.codex/packages/standalone/current/codex` … requires the standalone
     install managed by the Codex installer, because the daemon starts and
     updates app-server from that fixed path."* Crow resolves `codex` by PATH
     walk plus homebrew / `/usr/local/bin` / `~/.local/bin` fallbacks — all npm
     shaped. Every install would need a second Codex, obtained a different way.
  2. **Machine-global singleton, no per-session scoping.** `codex app-server
     daemon` is *the* local daemon on a fixed control socket
     (`~/.codex/app-server-control/app-server-control.sock`); `start` / `restart`
     / `stop` take no port, socket-path, or instance flag. Crow runs N
     concurrent Codex sessions, one per worktree, so one daemon cannot be
     addressed per session — the same defect class the Codex hooks `cwd` match
     had before CROW-1060 gave them per-session UUID scope, moved onto the drive
     path.
  3. **Opposite direction.** `codex --remote <ws://…>` connects a *local* TUI to
     a *remote* app server. Crow's badge claims the converse: this local agent
     is drivable from Crow's remote web UI. Crow already **is** the remote
     surface (browser → `crowd` → tmux), so `--remote` would stand up a second,
     parallel remote surface in front of the same agent, outside Crow's session
     model — and mobile pairing commonly still wants Codex Desktop as a bridge.

  This puts Codex exactly where the gap audit already put Cursor and OpenCode:
  a native RC surface exists, it is heavier than the paste that works, and it
  buys no user-facing capability today.

  **Probed on the installed `codex-cli 0.141.0`, while stable was `0.147.0`** —
  so the three blockers age differently. (3) is architectural and survives any
  version bump; (1) and (2) are 0.141.0 facts and are the sort of thing
  `0.147.0`'s added `remote-control pair` subcommand could move, so re-probe
  them before citing this against a newer build. The badge does not depend on
  any of it: it rests on the `crow send` paste path, so a Codex that fixed (1)
  and (2) would change *how* Crow could honor a `true` badge, not whether it
  should be `true`.

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
  honors the user's own config), `--yolo`, and the undocumented `--auto-review`.
  Note `--yolo` is skipped only because it is a pure **alias** for `--force`
  (`agent --help`: "Alias for --force (Run Everything)"), not because Crow declines
  Run Everything — `--force` *is* Run Everything, and it is what review sessions
  run under. (`--trust` **is** emitted — but as a per-launch workspace-**trust
  seed**, not an auto-permission flag; see "Gateway env / trust seed / telemetry"
  below. It went interactive in Cursor CLI 2026.07.20, reversing the earlier
  headless-only omission, #890, and covers `.review` too as of CROW-954.)
- **Codex:** honored for `.job` sessions on the **interactive** launch —
  `codex -a never -s workspace-write "$prompt"` (approval off, sandbox
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
- **Grok:** `--always-approve` + hard `--deny` (`GrokLaunchArgs.autoPermissionSuffix`,
  CROW-1037) on `.work` (coder-view Auto) and `.job` (jobs Auto). Grok's
  `--permission-mode auto` is a *classifier* that still gates `gh pr create` even
  when the ticket asked for it — that is **not** Claude's auto, so Crow Auto maps
  to the bypass (`--always-approve` / `--yolo` / `--permission-mode
  bypassPermissions`) instead. Deny still wins over always-approve, so the
  `rm -rf /` literals stay. Reviews stay human-gated. Auto off is still bare
  `grok`. The exit-2 fallback drops the flags if upstream renames
  `--always-approve`.
- **Muse:** `--disable-approval` (`MuseLaunchArgs.autoPermissionSuffix`) —
  skip approval prompts, **keep the OS sandbox** (Seatbelt on macOS, bubblewrap
  on Linux). Applied to `.job` / `.review` / Manager when the caller asks.
  Deliberately **not**: `--yolo` (disables approval *and* the sandbox *and*
  trusts the workspace), `--disable-sandbox` (lifts filesystem confinement and
  forces full network). `--trust-workspace` is a *separate* per-launch trust
  seed, withheld from `.review`. `--sandbox-network` is left at Muse's default
  (`proxy-only`); `--disable-approval` should also skip the first-connection
  network prompt — **needs-eval** against a real binary.

### Hooks transport & session scope

All harnesses report lifecycle events by shelling out to `crow hook-event`, but
**where the hook config lives** and **how the session is resolved** differ.

> **`cwd` outranks the baked UUID (#915).** A linked worktree's `.git` is a file
> pointing at the main clone, and project-root resolution follows it — so a
> worktree session loads the **main clone's** `.claude/settings.local.json` in
> addition to its own, and *both* hook blocks fire. A baked `--session <UUID>`
> therefore says which file the command was written into, not which session is
> running. The handler resolves the payload's `cwd` against registered worktrees
> first; a *live* UUID that doesn't own that directory is an inherited copy and
> is **dropped**, since the session that owns the cwd reports the same event from
> its own block. A UUID is still honored when it owns the cwd, when no worktree
> matches (an agent that `cd`s away), when it is the Manager (matched by
> constant, never by path), and when it is not live — that last one is #897's
> stale uuid, which is re-routed by `cwd` rather than discarded.
>
> The inherited block is also removed *at launch*:
> `ClaudeHookRepair.reconcileMainClone` resolves the main clone through the
> gitdir chain and strips its Crow entries unless a live session owns that
> directory, in which case it repairs them in place. That is the half the daemon
> cannot do — a dangling binary fails in `/bin/sh` before `crow` ever runs.

- **Claude** — per-worktree `.claude/settings.local.json`, written per session
  with `hook-event --session <UUID>`, so the session is resolved by **UUID**
  ([`ClaudeHookConfigWriter`](../Packages/CrowClaude/Sources/CrowClaude/ClaudeHookConfigWriter.swift)),
  subject to the `cwd` precedence above.
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
- **Codex** — per-worktree `<worktree>/.codex/hooks.json` with the session UUID
  baked into every command (`hook-event --session <uuid> --agent codex`), the
  same UUID-scoped good tier as Cursor/Grok/Muse (CROW-1060). `config.toml`
  carries `[features] hooks = true` (enables the hook subsystem so the project
  file loads); the deprecated `codex_hooks` key and the legacy `notify` bridge
  line are stripped at boot. The old global `$CODEX_HOME/hooks.json` writer is
  retired — its managed entries are cleaned once at daemon boot
  (`removeManagedGlobalConfig`, mirroring Cursor/Antigravity), because Codex
  layers project hooks atop the global file and running both would double-count.
  The `notify`→`CodexNotifyCommand` bridge is gone: the per-worktree `Stop` hook
  drives `.done` on its own (`CodexSignalSource`). Write/remove follow the
  Cursor/Muse protections — a git-tracked or non-Crow-owned `.codex/hooks.json`
  is left untouched (a user may ship one; it isn't conventionally gitignored),
  an untracked Crow write is git-excluded. Auto-launched **`.work`/`.job`
  worktrees and the Manager devRoot** additionally get per-worktree
  **project-trust** seeded into `config.toml` (`[projects."<worktree>"]
  trust_level = "trusted"`, `CodexTrustSeeder`) so Codex's folder-trust gate
  never blocks an unattended launch — and so the project hooks actually load
  (project hooks run only in trusted folders). **`.review` clones are
  deliberately not trust-seeded** — their working tree is `gh repo clone` output
  at the PR author's head (attacker-controlled), and trusting it would arm a
  committed `.codex/hooks.json`; they fall back to Codex's folder-trust prompt
  (the human-gated path), and `prepareReviewClone` strips any committed
  `.codex/` as defense-in-depth (#843). One consequence: a review clone's
  Crow-written `.codex/hooks.json` won't fire (the clone stays untrusted), so
  Codex review state detection is human-gated — matching the review posture.
- **OpenCode** — a **JS plugin** `crow-hooks.js` that subscribes to OpenCode's
  event bus (`session.status` for the busy/idle edges — see
  [Hook async delivery](#hook-async-delivery)) + `tool.execute.*` /
  `permission.ask` hooks and pipes a `{cwd, …}` JSON payload to
  `crow hook-event --agent opencode`. Written **per-worktree** into
  `<worktree>/.opencode/plugins/crow-hooks.js` with the session UUID baked in, so
  the session is resolved by **UUID** — `hook-event --session <uuid>`, exact, no
  `cwd` match (`OpenCodeHookConfigWriter`, CROW-831). The global
  `~/.config/opencode/plugins/crow-hooks.js` Crow installs at boot is a
  **fallback only**: it carries no UUID and **self-suppresses** (its plugin body
  returns no hooks) whenever a per-project `crow-hooks.js` exists, so the two
  never double-fire.
- **Grok** — per-worktree `.grok/hooks/crow.json`, written per session with
  `hook-event --session <UUID>`, resolved by **UUID** (#859,
  `GrokHookConfigWriter`). Grok's hook schema is byte-compatible with Claude's
  (`{ "hooks": { "<Event>": [ { "hooks": [ { "type": "command", … } ] } ] } }`,
  verified against `xai-grok-hooks`), and it discovers a *directory* of
  `*.json`, so `crow.json` is a dedicated Crow-owned file overwritten wholesale
  (a user's own `*.json` in the dir is preserved). **Trust caveat:** project
  hooks *require folder trust* (`~/.grok/trusted_folders.toml`) on a release
  build — `GrokTrustSeeder` seeds it for `.work`/`.job` worktrees, never
  `.review` clones. The review-clone strip must cover not just `.grok/` but the
  compat sources Grok also loads by default —
  `.claude/settings.json`/`settings.local.json`, `.cursor/hooks.json`, and the
  project MCP sources `.cursor/mcp.json` + `.grok/config.toml` + **repo-root
  `.mcp.json`** (Grok scans `.mcp.json` from repo root down to cwd). For a
  `.review` clone those are
  **attacker-controlled RCE**, not just double-fire noise, so
  `stripGrokConfigFromReviewClone` neutralizes the *full* discovered surface at
  clone creation (`prepareReviewClone`) **and on every launch path** — every
  launch routes through the shared `prepareWorktreeForAgentLaunch` gate (grep its
  call sites, don't count: today `launchAgent`, `handoffAgent`, `pasteDeferredLaunch`,
  `createManagerTerminal`, and the `send` RPC), so a new path can't open Grok in a
  review clone without stripping. It removes `.grok/`, `.cursor/`, **both**
  `.claude/settings.json`
  **and** `settings.local.json`, and repo-root `.mcp.json`. `settings.json` is a
  compat RCE source too, so it must be stripped on every path (r12): at creation
  the strip runs before `prepareReviewClone` re-writes a bundled-safe one, and on
  the re-strip paths a hostile one restored by `git restore`/`gh pr checkout` is
  removed and left absent (the one-shot creation overwrite can't reach it). The
  review skill lives in `.claude/skills/` (never read by Grok, which inlines it
  into the prompt) and is left in place (#861). Side effect of the re-strip: a
  Grok review clone that reached any launch path then has *no*
  `.claude/settings.json`, so handing that session back to Claude Code (whose
  handoff arm only writes the gateway env) runs the Claude review without Crow's
  bundled permissions — it prompt-gates under default-on `reviewAutoPermissionMode`
  rather than auto-approving. Fail-safe (more restrictive), not a hole. On a local/dev
  Grok build folder-trust is inert (everything trusted), and on release trust
  cascades from a trusted parent, so the strip — not trust-skipping — is the
  durable guard. **Deferred / re-check:** the *global* `~/.claude`/`~/.cursor`
  double-fire (user-controlled config, no Crow session UUID, not RCE), and the
  Grok-**Manager** devRoot case (`writeManagerHookConfig`). The *project*
  handed-off-worktree double-count is **closed** — `stripPriorCompatHooksForGrokHandoff`
  strips the prior agent's compat hooks on handoff and the warm-adopt path writes
  the session's own agent config (#861 r9-r10). Also residual: the Crow-written
  review *inputs* (`.crow-review-prompt.md`, the `.claude/skills/` skill body) are
  one-shot at clone creation, so the same restore vector (`git restore`/`gh pr
  checkout`) can hand a restored session an attacker-authored prompt/skill —
  prompt injection, not RCE, and shared by every review adapter; re-applying them
  on the restart/handoff paths needs the review context those paths don't carry
  (#861 r12 Green).

- **Muse** — per-worktree `.muse/hooks.json`, written per session with
  `hook-event --session <UUID>`, resolved by **UUID** (#1033,
  `MuseHookConfigWriter`). Event names are documented
  (`SessionStart` / `UserPromptSubmit` / `PreToolUse` / `PermissionRequest` /
  `PostToolUse` / `Stop` plus LLM/compact/subagent events). The on-disk JSON
  **shape** is a needs-eval pin: Crow writes a Claude-compatible
  `{ "hooks": { "<Event>": […] } }` document because the names match Claude
  and Muse already Claude-compat-loads `CLAUDE.md` / `.claude/skills`. `PreToolUse`
  is deliberately not registered (stdout verdict unverified; Antigravity's
  lesson). User/project hooks also require `muse hooks trust <key>` before they
  run; `--trust-workspace` *loads* them. Whether load implies run is
  **needs-eval** — state detection may stay dark until a real binary confirms.
  A git-tracked or user-owned `.muse/hooks.json` is left untouched.

Every harness now gets **per-session UUID scope** — Claude, Cursor, Codex, Grok,
Antigravity, Muse, and (since CROW-831) OpenCode, whose per-worktree
`.opencode/plugins/crow-hooks.js` carries the baked UUID while the host-global
plugin is a self-suppressing fallback. Codex joined the UUID-scoped tier in
CROW-1060. See [ADR 0015](adr/0015-harness-capability-tiers.md).

### Hook async delivery

- **Claude:** `PostToolUse` / `PostToolUseFailure` fire async; `PreToolUse` is
  intentionally *not* async so it is *accepted* by the daemon before the
  following `PermissionRequest` (`ClaudeHookConfigWriter.asyncEvents`).
- **Codex:** `PostToolUse` fires async **when the installed `codex` is ≥
  0.148.0**, decided once at boot by `CodexVersionProbe`. The daemon re-registers
  Codex with `CodexHookConfigWriter(asyncHooksSupported:)` after the probe, so the
  per-worktree writer emits `async` with the accurate verdict (CROW-999/1060).
  Below that pin every hook is registered synchronously, because a pre-0.148 Codex
  does not downgrade an `async: true` entry — it *skips* it, taking Crow's state
  detection with it.
  The gate is fail-closed (no binary, a hung probe, an unreadable banner → sync)
  and rejects pre-releases of the pin, since async landed mid-alpha
  (`0.148.0-alpha.9`) and an earlier alpha of the same release would still drop
  the hooks. `PreToolUse` stays sync for the same reason it does on Claude — see
  the apply-order caveat below. *Async **timing** was re-checked once the stable
  shipped (`0.148.0` on 2026-08-18; npm `latest` = `0.149.0` on 2026-08-20, so
  the gate now passes on real installs) — **CROW-1065**. The verdict is **safe by
  construction**, not one wall-clock trace: `PostToolUse` is the sole async event,
  and `CodexSignalSource` gives it exactly one mutation — `lastToolActivity`
  (`isActive: false`). That field is excluded from `SessionHookState.persistedSnapshot`
  (no on-disk card-color write) and has no display reader today, while every
  completion-driving field (`activityState → .done`, the notification badge, the
  stop timestamp) is owned by the **sync** `Stop`. So a straggler `PostToolUse`
  whose fire-and-forget `hook-event` lands after `Stop` (the widened #903 window)
  re-populates only reader-less, non-persisted in-memory state — it cannot
  un-complete a `.job`/`.work` turn, delay completion, corrupt the persisted
  sidebar color, or fire a second completion (the retired `notify` bridge is
  stripped and the global config removed, so `PostToolUse` registers once). Pinned
  by `lateAsyncPostToolUseAfterStopStaysDone` / `postToolUseLeavesCompletionFieldsUntouched`
  in `CodexSignalSourceTests`. A literal 0.148.0+ TUI observation remains a nice-to-have
  human re-check, but it can only confirm the ordering the structural argument
  already proves harmless for all orderings.*
- **Cursor:** declares `PostToolUse` / `Notification` async, but the timing is
  "one of the three things to confirm empirically" (`CursorSignalSource`).
- **OpenCode:** event *names* are verified, and the "done" signal is now the
  **canonical `session.status`** rather than the deprecated `session.idle`
  (CROW-1000). Timing measured on **opencode 1.18.5** via headless
  `opencode run`: upstream's `SessionStatus.set` publishes
  `session.status {idle}` and then `session.idle` from the same call — 246 µs
  apart — so the plugin latches on the first `session.status` and ignores the
  compat event, keeping one `Stop` per turn. `session.status` is published on
  *every* status write (three consecutive `busy` events in one observed turn),
  so the plugin acts on transitions only. `busy` now maps to `UserPromptSubmit`,
  which is what closed the real gap: in a live end-to-end run the turn-start
  edge landed **6.65 s before** the first `PreToolUse`, a window the card
  previously spent on a stale `.done`. `retry` is folded into `busy` and never
  reads as done. ⚠️ **Still open:** the probe was headless, so the *interactive
  TUI* claim CROW-545 originally asked about is inferred (same server bus), not
  measured — a TUI job session is the remaining human re-check.
- **OpenCode child sessions are dropped from the card** (CROW-1082; gap
  confirmed 2026-08-13, opencode 1.18.5). The bus is per-server, and
  `session.status` / `session.idle` carry only a `sessionID` with no parent
  link, so a **subagent's** status would otherwise map onto the one Crow session
  UUID like the parent's — a run that delegated to a subagent emitted
  `SessionStart` (child `session.created`), then `Stop` when the **child** went
  idle **1.9 s before the parent finished**, parking the card on `.done`
  mid-turn. `session.created` is the one event exposing the parent link
  (`info.parentID`), so the plugin records every child session's id there and
  then **ignores that id's `session.status` / `session.idle`** — only the
  **root** session (no `parentID`) drives the card, and a child no longer
  re-announces via `SessionStart`. Scoped to the premature-`.done` failure: a
  child's tool hooks still map to working state, which is correct because the
  parent *is* working.

> **Apply-order caveat (#903).** Since `crow hook-event` became fire-and-forget,
> `PreToolUse` being non-async only guarantees the daemon *accepts* it ahead of
> `PermissionRequest` — it no longer guarantees the two are *applied* in that
> order. The daemon fans each hook-event connection onto an independently
> scheduled `MainActor` task, so a `PreToolUse`/`PermissionRequest` (or
> `PostToolUse`/`PreToolUse`) inversion can show the wrong card state. The two
> directions differ: a `.waiting` strand while the agent is *working* self-heals
> on the next event, but a `PreToolUse` applied *after* `PermissionRequest` wipes
> the permission badge to `.working` while the agent is *parked at the prompt* —
> and there is no next event until the user answers, so it does **not** self-heal.
> Claude's only backstop is a separate `Notification(permission_prompt)` re-raising
> the badge, read verbatim from the payload (never synthesized); a build that
> doesn't emit it leaves the card `.working` for the whole prompt. Claude-specific
> (Cursor keeps a `PermissionRequest` case for parity but doesn't emit it). The
> reorder window is a few milliseconds; the durable fix is per-session server-side
> sequencing of hook-event application, tracked as the daemon-side follow-up to
> #903. A pure client-side signal-source guard can't resolve it — the event
> carries no ordering key and `PermissionRequest` carries no verified tool
> identity to match against — so none is attempted.

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
  onto a box that merely has a binary named `agent` — doubly so since CROW-989,
  where such a binary must also pass the identity probe to register as Cursor.
  The bridged entry is Crow-marked (a top-level `x-crow-managed` list, so the
  server def stays byte-identical to Claude's): a user's own `jira` is never
  clobbered, and the copy is withdrawn only when `~/.claude.json` parses cleanly
  with no `jira` (an unreadable read is left alone). No-op when no Jira MCP is
  configured.
- **Codex:** the `jira` MCP is **mirrored** — `CodexMCPWriter` copies the user's
  `mcpServers` from `~/.claude.json` into Codex's `<codexHome>/config.toml`
  (`[mcp_servers.*]`), installed at daemon boot from `LaunchScaffold` and gated by
  `defaults.mirrorClaudeMCPToCodex` (default on; #830). Append-only — a server
  hand-tuned in `config.toml` is never overwritten.
- **OpenCode:** the `jira` MCP is **mirrored** too — `OpenCodeMCPConfigWriter`
  copies the user's `jira` server from `~/.claude.json` into
  `<configHome>/opencode.json` (`mcp.jira`), installed at daemon boot from
  `LaunchScaffold` (CROW-831), the file-based analogue of Codex's `config.toml`
  mirror. It un-mirrors when the source `jira` disappears and skips user-authored
  entries via a `0600` provenance sidecar.
- **Grok, Antigravity, Muse:** no MCP bridge yet — all three fall back to the
  same `acli jira workitem view <key> --fields …` prompt line. The gap is
  **MCP**, not Jira ticket-fetch: every harness can fetch the ticket, just via
  `acli` rather than the `jira` MCP server.

### Review (`/crow-review-pr`)

`SessionService.buildReviewPrompt` branches on `agentKind`:

- **Claude** gets the terse slash-command form `/crow-review-pr <URL>`; the
  bundled `.claude/skills/crow-review-pr/SKILL.md` supplies the instructions.
- **Cursor, OpenCode & Antigravity** have no slash-command engine, so Crow
  **inlines the whole skill body** into the prompt file (`cursorReviewPrompt`,
  #431; Antigravity wired the same way, #902).
- **Codex** inlines the skill body too (`buildReviewPrompt` `.codex` arm, #830):
  the native `codex review` subcommand only prints local findings and posts no
  GitHub verdict, so it can't satisfy `decideReviewCompletions`. Runs
  interactively and is human-gated (see the auto-permission note).
- **Grok** has no slash-command engine either, so `buildReviewPrompt` inlines
  the whole skill body for `.grok` (the same `cursorReviewPrompt` arm as
  Cursor/OpenCode/Codex, #861). A bare `/crow-review-pr <URL>` would never expand
  → never post `gh pr review` → never satisfy `decideReviewCompletions`
  (`buildReviewPromptGrokBranchInlinesSkillBody` guards the regression).
- **Muse** inlines the skill body the same way (`buildReviewPrompt` `.muse`
  arm, #1033). Review clones are **strip-not-trust**: Crow withholds
  `--trust-workspace` (so project hooks/skills/rules do not load) and strips
  `.muse/` plus `.agents/` on every launch path. `.agents/memory/` is
  load-bearing — Muse injects committed project memory even in an untrusted
  workspace. Auto-perm is `--disable-approval` (sandbox stays), never `--yolo`.

The inlined body is **frontmatter-stripped** (`MarkdownFrontmatter.stripped`,
CROW-968). The SKILL file opens with a `---` YAML block because Claude Code's
skill engine requires `name`/`description`; inlined, that made the prompt's first
byte a `-`, which Cursor's commander-based `agent` parsed as a flag —
`error: unknown option '---` — killing every review before it started. The strip
applies **only** to the inlined prompt: the `.claude/skills/crow-review-pr/SKILL.md`
copy written into the review clone keeps its frontmatter, or Claude wouldn't load
the skill at all. `prepareReviewClone` renders the workspace verdict policy into
one body and forks it two ways, so the strip has to sit on the inlined side of
that fork (in `cursorReviewPrompt`), not upstream of it.

### Initial-prompt injection

Review/job sessions get a pre-written prompt file (`.crow-review-prompt.md` /
`.crow-job-prompt.md`) inlined via shell substitution on first launch. A preflight
in `launchAgent` refuses to dispatch if that file is missing, for **every**
harness (CROW-439) — it's gated on the prompt-file convention, not on agent kind.

- **Claude:** the prompt file's contents as the final argv, dispatched through the
  deferred `#408` paste path (stash in `pendingLaunchCommands`, paste on
  `.shellReady`).
- **Cursor:** `agent … -- "$prompt"` for job/review (path shell-quoted). The
  interactive TUI takes the positional prompt directly, so no headless `-p` leg
  is needed; `CursorLauncher.launchCommand` feeds the prompt on agent handoff
  (#829). `.work` launches `agent` bare (the user types into the TUI).
- **Codex:** `.job` + `.review` feed the prompt file (`.crow-job-prompt.md` /
  `.crow-review-prompt.md`) as the initial argv via
  `ShellLaunchArgs.evalPromptLaunch` — review inlines the `/crow-review-pr` skill
  body and runs interactively/human-gated, *not* `nil` (#830). `.work` launches
  bare; restarts resume with `codex resume --last`
  (`OpenAICodexAgent.autoLaunchCommand`).
- **OpenCode:** **run-then-`--continue`** — headless `opencode run "$prompt"`
  consumes the prompt reliably, then `; opencode --continue` opens the TUI with a
  fresh stdin so `crow send` keeps working (#547).
- **Grok:** **run-then-`-c`** — headless `grok --prompt-file <path>` consumes the
  prompt (any prompt arg forces headless), then `; grok -c` resumes the same
  session in the TUI with a fresh stdin. Uses `--prompt-file` (not `-p "$prompt"`)
  so a large inlined review-skill body never becomes a giant argv or rides a
  subshell (#861). `.job`/`.review` only; `.work` launches `grok` bare.
- **Antigravity:** `agy -p "$prompt"` for job/review (path shell-quoted); the
  tmux PTY means the non-TTY `-p` stdout-drop doesn't bite. Restart resumes with
  `-c`. `.work` launches `agy` bare (#902).
- **Muse:** **exec-then-`resume`** — headless `muse exec --prompt-file <path>`
  consumes the prompt (any prompt arg is headless-only), then `; muse resume`
  reopens the workspace session in the TUI with a fresh stdin. Uses
  `--prompt-file` (not a `$(cat …)` subshell) so a large inlined review-skill
  body never becomes a giant argv. `.job`/`.review` only; `.work` launches
  `muse --trust-workspace` bare. `muse resume` without a session id is assumed
  workspace-scoped most-recent (same heuristic as Antigravity's `-c`) —
  **needs-eval** against a real binary. `muse exec --session-id` exists but
  is unused: Crow does not capture the exec session id.

`ShellLaunchArgs.evalPromptLaunch` builds every one of these except Grok's, whose
prompt is read from a path and so never becomes argv. Its `endOfOptions` flag adds
a literal `--` before the prompt so a body starting with `-` arrives as an operand
instead of an option (CROW-968). It is **opt-in per harness, deliberately not a
global default** — `--` is a convention, not a guarantee, and a parser that treated
a bare `--` as a prompt word would corrupt every launch on that harness. Enabled
today for **Cursor only** (both `CursorAgent.autoLaunchCommand` and
`CursorLauncher.launchCommand`), verified against the installed binary:
`agent --list-models --bogus` errors, `agent --list-models -- --bogus` parses
clean. Check the CLI before enabling it anywhere else.

### Gateway env / trust seed / telemetry

Three capabilities the protocol doesn't abstract — historically Claude-specific
and gated on Claude identity (`if …kind == .claudeCode`). Trust seeding now has
bounded per-harness analogues (Cursor's `--trust`, Codex's `config.toml`); the
AI-gateway env and telemetry legs remain Claude-only (gating is exhaustive except
the two Manager gateway writes noted below):

- **Trust seeding** — `ClaudeTrustSeeder.seedTrust` pre-trusts the worktree in
  `~/.claude.json` so the "Do you trust the files in this folder?" dialog never
  blocks an auto-launched session (CROW-600). Runs at **four** call sites:
  `SessionService.launchAgent`, `handoffAgent`, and the two Manager paths.
- **Trust seeding (Cursor)** — the per-launch analogue of the Claude seed:
  `CursorLaunchArgs.trustSuffix` appends `--trust` to **every** Crow-driven launch
  (auto-launch, Manager, and the handoff one-shot), so no worktree blocks on
  Cursor's folder-trust dialog (CROW-890). **`.review` included as of CROW-954**,
  reversing the original carve-out. The carve-out assumed the dialog would act as
  review's human gate; both halves of that assumption were wrong. Review launches
  already carry `--force --approve-mcps` (`reviewAutoPermissionMode` defaults on),
  so the only available answer at the prompt is "trust", after which nothing is
  gated anyway — and `--force` does **not** suppress the prompt (the CROW-890 note
  left this "unverified"; observed on `agent 2026.08.04`, a review session stops on
  "Workspace Trust Required" and waits for a keypress, which is exactly the
  unattended-dispatch failure the seed exists to prevent). The clone's real defense
  is `stripCursorConfigFromReviewClone`, promoted to run on **every** launch path
  via `prepareWorktreeForAgentLaunch` — the same **strip-not-trust** posture Grok
  and Antigravity reviews already use, and consistent with Claude, whose
  `shouldSeedFolderTrust` has always returned `true` for `.review`. **Interactive
  since Cursor CLI 2026.07.20**
  ([changelog](https://cursor.com/docs/cli/changelog)); verified against `agent
  2026.08.04` — `agent --trust` under a pty with no `--print` writes
  `~/.cursor/projects/<slug>/.workspace-trusted` with `"trustMethod": "cli-flag"`,
  the same marker the dialog writes on accept. Its `--help` also drops the
  "(headless mode only)" qualifier the
  [param reference](https://cursor.com/docs/cli/reference/parameters) still
  carries. **Workspace trust only** — not `--yolo`; auto-permission stays in the
  separate `--force --approve-mcps`.
- **AI-gateway env** — two mechanisms for the workspace's `ANTHROPIC_BASE_URL` /
  `ANTHROPIC_CUSTOM_HEADERS` (CROW-402): `ClaudeHookConfigWriter.writeGatewayEnv`
  writes the env block into `settings.local.json` (Claude-gated at `launchAgent`
  and `handoffAgent`), and `ClaudeLaunchArgs.gatewayEnvPrefix` adds the
  launch-line `export …` prefix (at `launchAgent`, plus `managerCommand`'s
  no-registered-agent fallback). All four `settings.local.json` writes — worker
  `launchAgent` / `handoffAgent` and the **two** Manager writes
  (`createManagerTerminal` + the hydrate path's `writeManagerGatewayEnv`) — are
  **Claude-gated**: a Claude target gets the resolved env; a **compat-loading**
  target (Grok/Codex — `readsClaudeCompatSettings`) gets `resolved: nil`, which
  actively **clears** the block; and Cursor/OpenCode/Antigravity are left
  **untouched** (no write, no clear) because they never read the file, so a clear
  there would be pure rewrite churn (#861 r18). This is not
  cosmetic — the `ANTHROPIC_CUSTOM_HEADERS` can carry an `Authorization: Bearer`,
  and Grok/Codex **compat-load `.claude/settings.local.json`** (the very reason
  the review-clone strip deletes it), so an unconditional write would leak a
  corporate gateway credential into a different vendor's process env on a
  Claude→Grok handoff or a Grok Manager (#861 review r17, Yellow 2). Which
  workspace's gateway applies is resolved
  by worktree path, falling back to the PR's `owner/repo` for review clones,
  which live outside any workspace folder (CROW-891) — see
  [configuration.md](configuration.md#which-gateway-applies).
- **OTEL telemetry env** — `AgentLaunch.prepareAgentLaunchText` prepends the
  `OTEL_*` exporter vars, gated on `agent.kind == .claudeCode` (Codex has no OTLP
  equivalent).

These are the residual Claude-identity switches called out in
[ADR 0014](adr/0014-pluggable-coding-agent-adapter.md).

### Rename passthrough

Every harness except Antigravity overrides `sessionRenameSlashCommand` to return
`"/rename <name>\n"`,
sent after a Crow rename so the agent's own session title stays in sync
(CROW-629). The protocol default is `nil` so a *future* harness can't inherit a
spurious `/rename` paste.

**Delivery is gated on the RC badge for non-Manager sessions**, which is why
CROW-1001 changed behaviour here as a side effect. `agentRenameTargets` sends to
command-bearing terminals for a Manager, but for work / job / review sessions it
falls through to `remoteControlRenameTargets` — i.e. `remoteControlActiveTerminals`.
While Codex's `supportsRemoteControl` was `false` its worker terminals never
entered that set, so a renamed Codex work session forwarded **nothing**, despite
this row reading ✅ and `OpenAICodexAgent.sessionRenameSlashCommand` returning a
real command. With the flag `true` (and `remoteControlEnabled` on) the paste now
lands, making the ✅ true for Codex workers rather than only for its Manager. The
same gate still applies to Cursor / OpenCode / Grok, and only ever targets
agent-launched terminals — `remoteControlActiveTerminals` is populated in
`launchAgent`, so a plain Shell tab can't receive a `/rename` paste.

## Antigravity (Tier-2 / experimental)

Google Antigravity's CLI (binary **`agy`**) is the terminal surface of Google's
agent-first dev platform (IDE + CLI + SDK, launched with Gemini 3). Crow drives
it through the same `CodingAgent` protocol as the others — its adapter
(`CrowAntigravity`) is structurally a **near-clone of `CrowCursor`**: hooks feed
lifecycle events (JSON on stdin, JSON verdict on stdout) so the
`HookConfigWriter`/`StateSignalSource` pair does real work; per-worktree
`.agents/hooks.json` with the session UUID baked in (per-session scope, not
`cwd`); remote control faked via `crow send`; `.review` dispatches the inlined
`crow-review-pr` SKILL body via `-p` (#902), like Codex/Cursor/OpenCode — its
review clone's committed config (`.agents/` **and**, defensively, the
Gemini-derived `.gemini/` — #902 r7) is stripped at creation
(`prepareReviewClone`) **and on every launch path** (`prepareWorktreeForAgentLaunch`
— the one gate `launchAgent`, `pasteDeferredLaunch`, `createManagerTerminal`, the
`send` RPC, and handoff route through), so a hostile PR head's hooks/MCP servers
can't fire when `agy` loads the clone. The launch-path strip is load-bearing, not
redundant: `agy` has no trust gate behind it, and a warm `crowd` restart or `crow
send "agy -c"` reopens the clone after the review skill's `gh pr checkout` may have
restored a committed layer from the head (#902 review r2/r3). Because the strip is
the *only* defense, it removes the whole plausibly-discovered surface rather than
the native dir alone — the same posture `stripGrokConfigFromReviewClone` takes.
It ships **Tier-2** ([ADR 0015](adr/0015-harness-capability-tiers.md))
with honest, documented gaps (#860). **Review-approval posture is unverified**
(#902 end-to-end pass pending): `agy` review inherits `.job`'s launch shape but
has no bounded auto-permission flag (`autoPermissionSuffix` is `""` on v1.1.7)
and no confirmed non-interactive posture, so — unlike `.job` — a review that
stalls on an approval gate would leave the Reviews board waiting with no signal.
Tracked in the auto-permission pinned-gaps row below; re-check on the manual pass.
**Review-on-Antigravity is opt-in and experimental**: it is never a default — it
requires an explicit `crow agents set --review antigravity` (or Settings → Agents
→ Review = Antigravity) *and* `agy` on `PATH`. Two premises behind its only
defense remain unverified on v1.1.7 — the strip-list exhaustiveness and whether
`agy` re-reads config per-event (the in-session restore window). Both are pinned
below and the **manual pass that confirms them is a precondition for treating the
capability as production-ready**, not just for promoting Antigravity out of
Tier-2. Until then it ships as an experimental opt-in on a Tier-2 harness.

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

## Muse Code (Tier-2 / experimental)

Meta Muse Code's CLI (binary **`muse`**) is the terminal surface of Meta's
coding agent, built on Muse Spark 1.2. Crow drives it through the same
`CodingAgent` protocol as the others — its adapter (`CrowMuse`) is structurally
a **near-clone of `CrowGrok`**: hooks feed lifecycle events so the
`HookConfigWriter`/`StateSignalSource` pair does real work; per-worktree
`.muse/hooks.json` with the session UUID baked in; remote control faked via
`crow send`; `.job`/`.review` dispatch via `muse exec --prompt-file` then
`muse resume`; `.review` uses the inlined `crow-review-pr` SKILL body. It ships
**Tier-2** ([ADR 0015](adr/0015-harness-capability-tiers.md)) with honest,
documented gaps (#1033).

**Bounded auto-permission is `--disable-approval`.** Official permissions
docs: that flag skips approval prompts and **keeps the OS sandbox**. `--yolo`
disables approval *and* the sandbox *and* trusts the workspace; `--disable-sandbox`
lifts filesystem confinement. Crow never emits either. `--trust-workspace` is a
separate per-launch trust seed (Cursor `--trust` analogue), applied on `.work` /
`.job` / Manager and **withheld from `.review`**.

**Review is strip-not-trust.** The clone is an attacker-controlled `gh` checkout.
Withholding `--trust-workspace` means project skills, rules, and hooks do not
load. Project **memory** under `.agents/memory/` is injected even in an
untrusted workspace, so `stripMuseConfigFromReviewClone` removes `.muse/` **and**
`.agents/` at creation (`prepareReviewClone`) **and on every launch path**
(`prepareWorktreeForAgentLaunch`).

**Subagent worktree fan-out is a Crow risk, not a flag we pass.**
`--subagent-worktree-isolation` makes Muse create its own git worktrees per
child, outside Crow's session tree. Crow does **not** emit the flag. Default
is children share the lead's workspace. A user who enables isolation in
`~/.config/muse/settings.json` can still leak worktrees — documented
**wire-worthy** follow-up if a disable/isolate path appears.

**Permanent gap — self-host.** The `muse` binary is **closed-source** and auth
is **Meta browser sign-in or `META_API_KEY`**, so it runs only against Meta's
cloud models (default `muse-spark-1.2`) — never an arbitrary self-hosted/local
model. That fails Corveil's self-host axis and is a **fixed** gap, not a phase.

**⚠️ Supply-chain / probe note.** Crow never installs `muse`. Resolution is
PATH-first (picking up whatever the official `https://dev.meta.ai/install.sh`
installer placed at `~/.local/bin/muse`), plus conservative standard-bin
fallbacks. A bare `muse` is identity-probed because the name collides with the
Muse Sequencer. This adapter was wired against official docs dated 2026-08-14,
**not** a local `muse --help` — the installer is Meta-auth-gated. Every flag
is a version-pinned re-check target; confirm against a real binary before
promoting Muse out of Tier-2.

## Handoff between harnesses

`crow handoff-agent --session <UUID> --agent <claude-code|cursor|codex|opencode|grok|antigravity|muse>
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
| Codex honors `async: true` (below the pin it *skips* the entry, breaking state detection) | Codex **≥ 0.148.0** (gate lives in `CodexVersionProbe.minimumAsyncHookVersion`) | `CodexVersionProbe` / `CodexHookConfigWriter.asyncEvents` | 2026-08-20 (CROW-1065) — **closed**. Upstream `discovery.rs` on `rust-v0.148.0` computes `runs_async = async && event != SessionEnd` (the "not supported yet" skip is gone). `0.148.0` shipped **stable** on 2026-08-18 (npm `latest` = `0.149.0` on 2026-08-20), so the gate now passes on real installs — earlier the reason held (2026-08-13, CROW-999) but `0.148.0` was still pre-release. Async **timing** is now resolved **by construction**: `PostToolUse` is the only async event and its sole mutation (`lastToolActivity`) is persistence-excluded + reader-less, while completion is owned by the sync `Stop` — so no straggler-after-`Stop` ordering is observable on the card (proof over all orderings; pinned by `lateAsyncPostToolUseAfterStopStaysDone`). A live 0.148.0+ TUI trace stays a nice-to-have human re-check |
| Codex `config.toml` hook key renamed `codex_hooks` → `hooks` | Codex **v0.139.0+** | `CodexHookConfigWriter.installGlobalTomlConfig` | 2026-07-24 |
| Codex reuses Claude's hook engine (`ClaudeHooksEngine`, byte-compatible schemas) | verified against **codex 0.123.0** | `CodexSignalSource` | 2026-07-24 |
| Claude background-recap subagent must not elevate state | Claude Code **≥ 2.1.108** (`awaySummaryEnabled`) | `ClaudeHookSignalSource` | 2026-07-24 |
| Cursor `PostToolUse` / `Notification` async timing unconfirmed | — (empirical) | `CursorSignalSource` | 2026-07-24 |
| Cursor interactive `--trust` (workspace-trust seed) — reverses the earlier headless-only omission; now emitted on **every** kind incl. `.review` | **min: Cursor CLI ≥ 2026.07.20** (changelog: interactive); verified `agent 2026.08.04` (`--help` drops "headless mode only"; pty run with no `--print` writes `.workspace-trusted` / `"trustMethod": "cli-flag"`) | `CursorLaunchArgs.trustSuffix` | 2026-08-10 (CROW-954) — emitted on every path. The `.review` carve-out is **removed**: `--force` was observed NOT to suppress the trust dialog (the CROW-890 "unverified" note, now settled), so the carve-out stranded unattended reviews on a prompt that gated nothing — review already runs `--force --approve-mcps`. Review clones are now defended by the launch-path `.cursor/` strip (`shouldStripCursorReviewClone`) instead. Pre-2026.07.20 CLI out of support; probed 2026.07.23 that the parser ignores a mode-gated flag (`--output-format json --version` exits 0), so older builds no-op `--trust` rather than reject. Re-probe if `--help` ever restores the headless-only qualifier |
| OpenCode "done" signal is `session.status {idle}`, not the deprecated `session.idle` | opencode **1.18.5** (probed; `session.status` present) | `OpenCodeHookConfigWriter` | 2026-08-13 (CROW-1000) — upstream publishes **both** at turn end (`session/status.ts` `set` → Status then Idle, 246 µs apart), so the plugin latches on the first `session.status` and drops the compat event; older builds keep the `session.idle` fallback. `session.status` fires on every status write, not only on changes, so transitions are deduped per `sessionID`. ⚠️ Probed via headless `opencode run`, **not** the interactive TUI — the TUI pass is the open human re-check, as is a build ≥ **1.18.16** (the version the ticket cites for the deprecation docs). Re-probe if upstream stops emitting `session.idle` (fallback becomes dead code) or adds a fourth `SessionStatus` type |
| OpenCode subagent child sessions carry no parent link on `session.status`/`session.idle` — only `session.created`'s `info.parentID` does | opencode **1.18.5** (child idle measured 1.9 s before parent finish) | `OpenCodeHookConfigWriter` | 2026-08-20 (CROW-1082) — plugin records every child id from `session.created` and drops that id's status/idle so only the **root** session moves the card; a child no longer emits `SessionStart` either. Scoped to premature `.done`; child tool hooks still map to working (parent is working). Re-probe if upstream stops populating `info.parentID` on `session.created`, or starts stamping a parent id onto `session.status`/`session.idle` (the guard could then key off that directly) |
| Antigravity flags (`agy` hooks events, `-p` non-TTY stdout, `-c`/`--conversation` resume) | `agy` **v1.1.7 (2026-07-26)** | `AntigravityAgent` / `AntigravityHookConfigWriter` | 2026-07-26 — re-probe on upgrade |
| Antigravity structured-stdout (would promote toward first-class parity) | upstream FRs **#119/#597** (`--output-format stream-json`), **#31** (ACP) | `AntigravitySignalSource` | 2026-07-26 — hooks are the only transport until either lands |
| Antigravity bounded auto-permission has no verified interactive launch flag | `agy` **v1.1.7**; headless `-p` ignores `permissions.allow` (issue #548) | `AntigravityLaunchArgs.autoPermissionSuffix` | 2026-07-26 |
| Antigravity official-installer provenance (supply-chain gate) unconfirmed | `google-antigravity` org `is_verified: false`; pin `antigravity.google` | `AntigravityAgent.fallbackCandidates` | 2026-07-26 — confirm before promoting out of Tier-2 |
| Antigravity review-clone strip list exhaustiveness: is any project-scope config `agy` reads **outside** `.agents/` + `.gemini/` still uncovered? | `agy` **v1.1.7**; Crow's MCP bridge is deferred (no writer to confirm the read path), and `AntigravityLaunchArgs` notes approval posture is governed by `settings.json` modes | `stripAntigravityConfigFromReviewClone` | 2026-07-28 (#902 r7) — the strip now removes `.agents/` **and** `.gemini/` **defensively** (a project `.gemini/settings.json` could carry `mcpServers`/`always-proceed`; `GEMINI_CONFIG_HOME` default `~/.gemini/config` is only the *user*-scope home). So the question is no longer "is the strip sufficient" but "is the strip **list exhaustive**" — confirm no other project-scope surface on the manual pass before promoting out of Tier-2 |
| Antigravity hook re-read timing: does `agy` read `.agents/hooks.json` **once at process start**, or per-event? | `agy` **v1.1.7** — unverified; assumed start-only | `prepareWorktreeForAgentLaunch` (launch-time strip) | 2026-07-28 (#902) — the launch-time strip mitigates a hook restored *between* launches. If `agy` re-reads per-event, a mid-session restore (SKILL's `gh pr checkout` fast-forwards → silently restores `.agents/`) would fire unmitigated, since no strip re-runs mid-session and there is no trust gate behind it. Confirm on the manual pass before promoting out of Tier-2 |
| **Entire Grok flag set** — hooks event names, `-p`/`--single`, `-c`/`-r`, `--allow`/`--deny`, `--permission-mode`, `--trust`, `/rename` | `xai-org/grok-build` **@ 2026-07-25** (periodic mirror of xAI's monorepo, **PRs closed** → churn likely) | `GrokAgent` / `GrokLaunchArgs` / `GrokHookConfigWriter` / `GrokSignalSource` | 2026-07-26 — verified against repo source (`crates/codegen/xai-grok-*`), not blog posts |
| Grok session-log layout + directory-name encoding — `<$GROK_HOME or ~/.grok>/sessions/<url-encoded-cwd>/<uuid>/chat_history.jsonl`, dir name = abs cwd percent-encoded over the RFC 3986 **unreserved** set (`/`→`%2F`, dashes preserved — *not* `NON_ALPHANUMERIC`, which would escape them) | `xai-org/grok-build` (same closed upstream mirror → churn likely); layout captured on a real tree in **#1090 (2026-08-21)** | `GrokAgent.logSources` / `GrokSessionDir` / `GrokHome` · `BackfillScanner.reconstructGrok` | 2026-08-24 (CROW-1098) — a mismatched encoding silently collects nothing (never misattributes); re-confirm the dash-preserving scheme on a Grok version bump |
| Grok `grok` binary collides with community `superagent-ai/grok-cli` | **Identity probe** at registration (`grok --help`/`--version` vs grok-build flag markers) greys out the foreign `grok`; explicit `defaults.binaries.grok` pin bypasses it. Decision is pure `AgentDiscovery.evaluate`; probe markers (`--prompt-file`, `--prompt-json`, `--permission-mode`, `--always-approve`) are the same upstream flag set as the row above — re-verify together | `GrokAgent.identityMarkers` / `verifyBinaryIdentity` · `AgentDiscovery.evaluate` | 2026-07-26 (CROW-911) |
| Cursor's legacy `agent` alias collides with grok-build's `~/.grok/bin/agent` (fired in the field) | Prefer the unambiguous **`cursor-agent`** via a token-major PATH walk (order-independent), plus the same **identity probe** on a bare `agent` match. Markers (`--approve-mcps`, `--trust`, `CURSOR_API_KEY`, `CURSOR_API_ENDPOINT`) are the flags this adapter passes — re-verify with `CursorLaunchArgs` on each Cursor CLI baseline bump. CROW-1058 then closed the two gaps that let it fire again: discovery **probes every** candidate instead of stopping at the first (so a genuine `cursor-agent` behind grok-build's `agent` still registers), and launch reads the **verified path** (`launchBinary()` / `VerifiedBinaries`) instead of re-walking PATH — with the unverified fallback narrowed to the unambiguous `cursor-agent`, never the alias | `CursorAgent.identityMarkers` / `verifyBinaryIdentity` · `BinaryTokenResolver` · `BinaryIdentityProbe` · `VerifiedBinaries` / `launchBinary()` | 2026-08-19 (CROW-1058) — Cursor CLI baseline `2026.08.04-aaa8809` |
| Grok **`--permission-mode auto` now exists** — the #859 probe reported it absent; current docs show it *and* `--always-approve`. Crow Auto maps to `--always-approve` + `--deny` on `.work`/`.job` (CROW-1037): Grok's classifier `auto` still gates `gh pr create`, which is not Claude-equivalent. Reviews stay human-gated. Re-probe `--always-approve`/`--yolo` with the rest of the flag set | Grok mirror **@ 2026-07-25** | `GrokLaunchArgs.autoPermissionSuffix` | 2026-08-15 (CROW-1037; was 2026-07-26) |
| Grok `Stop` / `Notification` fire on the transitions Crow's state machine needs — **confirm empirically** | — (empirical, #859) | `GrokSignalSource` | 2026-07-26 |
| Grok double-fire: only the **global** `~/.claude`/`~/.cursor` hook configs Grok also discovers (its compat scanning) firing alongside `.grok/hooks/crow.json` — dedup deferred (genuinely user-controlled config, no Crow session UUID, not RCE; unlike Codex's *Crow-written* global double-fire, which CROW-1060 closed by dropping the global writer — Crow can't delete configs the user owns). *Project* compat sources are handled: stripped on `.review` clones (`stripGrokConfigFromReviewClone`, RCE) and neutralized on `.work`/`.job` handoff + warm-adopt (`stripPriorCompatHooksForGrokHandoff` + session-own adopt write, #861 r9-r10). The Grok-**Manager** devRoot case stays a documented limitation (`writeManagerHookConfig`). | — (empirical, #859) | `GrokHookConfigWriter` / `SessionService` | 2026-07-27 |
| **Entire Muse flag set** — `exec` / `--prompt-file` / `resume` / `--session-id` / `--disable-approval` / `--yolo` / `--disable-sandbox` / `--trust-workspace` / `--sandbox-network` / `--subagent-worktree-isolation` / hook event names | Official docs **2026-08-14** (https://dev.meta.ai/docs/muse-code/); **no local `muse --help`** (installer is Meta-auth-gated) | `MuseAgent` / `MuseLaunchArgs` / `MuseHookConfigWriter` / `MuseSignalSource` | 2026-08-14 (#1033) — **needs-eval** against a real binary before promoting out of Tier-2 |
| Muse `muse` binary collides with Muse Sequencer | **Identity probe** at registration (`muse --help`/`--version` vs Muse Code flag markers) greys out a foreign `muse`; explicit `defaults.binaries.muse` pin bypasses it | `MuseAgent.identityMarkers` / `verifyBinaryIdentity` | 2026-08-14 (#1033) |
| Muse hook JSON schema is unverified (event *names* documented; on-disk shape is a Claude-compatible guess) | Official extending docs 2026-08-14 list events + `muse hooks trust <key>` but not the file format | `MuseHookConfigWriter` | 2026-08-14 — **needs-eval**; a rejected shape would break launch, so a git-tracked / user-owned `.muse/hooks.json` is left untouched. Confirm with `muse hooks validate` |
| Muse `muse hooks trust <key>` vs `--trust-workspace`: does workspace trust *run* project hooks, or only *load* them? | Official docs 2026-08-14: trust-workspace "loads" skills/rules/hooks; user/project hooks "must" be trusted by key | `MuseHookConfigWriter` / `MuseLaunchArgs.trustSuffix` | 2026-08-14 — **needs-eval**; state detection may stay dark until confirmed |
| Muse session-log layout + cwd-attribution key — `<${XDG_DATA_HOME:-~/.local/share}/muse>/sessions/<YYYY>/<MM>/<DD>/<id>/session.jsonl`, cwd on the line-1 `runtime.session.metadata` record at `payload.record.workspace_root` | Meta dev cookbook (store path, read 2026-08-24) + `superbasedapp/observer` `internal/adapter/muse/doc.go` (the `workspace_root` key, 2026-08-06); **no live `session.jsonl`** verified (installer Meta-auth-gated) | `MuseAgent.logSources` / `MuseHome` · `TranscriptHeadReader.absorb` · `BackfillScanner.reconstructMuse` | 2026-08-24 (CROW-1106) — **operator opted to wire against 3rd-party evidence** rather than wait for the #1099 gate; a wrong key/path silently collects nothing (never misattributes). Confirm `workspace_root` (and the `subagent/` child-session shape) on a real journal when Muse becomes installable |
| Muse `muse resume` without a session id is workspace-scoped most-recent (the exec-then-resume heuristic) | Official docs: `muse resume` opens the interactive UI; `muse exec --session-id` is the headless continue; `/resume --last` is a slash command | `MuseLaunchArgs.resumeTUICommand` | 2026-08-14 — **needs-eval**; `--session-id` capture is **wire-worthy** if bare `resume` is not last-session |
| Muse `--subagent-worktree-isolation` creates git worktrees outside Crow's session tree | Official extending docs 2026-08-14; Crow never passes the flag; a user `settings.json` opt-in still can | `MuseLaunchArgs` (deliberately omitted) | 2026-08-14 — **wire-worthy** if a disable/isolate path appears; default is children share the lead workspace |
| Muse review-clone strip list exhaustiveness: is any project-scope config `muse` reads **outside** `.muse/` + `.agents/` still uncovered? | Official docs: project hooks `.muse/hooks.json`; skills `.agents/skills` + `.claude/skills` + `.codex/skills` (skills load only after trust); memory `.agents/memory/` (loads **even untrusted**) | `stripMuseConfigFromReviewClone` | 2026-08-14 — strip covers `.muse/` + `.agents/` (memory). `.claude/skills` / `.codex/skills` load only after trust, which review withholds. Confirm no other untrusted-read surface before promoting out of Tier-2 |
