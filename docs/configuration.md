# Configuration

This page covers where Crow stores data, how workspaces are configured, the on-disk directory layout it expects, and runtime behavior you can tune via environment variables.

## File Locations

All persistent state lives under `~/Library/Application Support/crow/` (see `Packages/CrowPersistence/Sources/CrowPersistence/AppSupportDirectory.swift`). On first run, if a legacy `rm-ai-ide` directory exists in the same parent, its contents are copied over automatically.

| Path                                                                  | Purpose                                                       |
| --------------------------------------------------------------------- | ------------------------------------------------------------- |
| `~/Library/Application Support/crow/devroot`                          | Pointer file containing the development root path            |
| `~/Library/Application Support/crow/store.json`                       | Persisted sessions, worktrees, links, terminals               |
| `~/.local/share/crow/crow.sock`                                       | Unix socket for CLI ↔ server IPC (owned by `crowd` by default) |
| `{devRoot}/.claude/config.json`                                       | Workspace configuration (see below)                          |
| `{devRoot}/.claude/CLAUDE.md`                                         | Manager-tab context with the `crow` CLI reference             |
| `{devRoot}/.claude/settings.local.json`                               | Crow-managed pre-approved permissions, merged on every launch  |
| `{devRoot}/.claude/settings.json`                                     | The user's own file — Crow never reads or writes it            |
| `{devRoot}/.claude/prompts/`                                          | Prompt files used by the `/crow-workspace` skill              |
| `{devRoot}/.claude/skills/crow-workspace/SKILL.md`                    | Workspace setup skill invoked via `/crow-workspace`           |
| `{devRoot}/.claude/skills/crow-workspace/setup.sh`                    | Deterministic setup script called by the skill                |
| `{devRoot}/.claude/skills/crow-review-pr/SKILL.md`                    | PR review skill invoked via `/crow-review-pr`                 |
| `{devRoot}/.claude/skills/crow-batch-workspace/SKILL.md`              | Batch workspace setup skill                                   |
| `{devRoot}/crow-reviews/`                                             | Temporary clones used when reviewing PRs (reserved name)      |

## Workspace Configuration

`{devRoot}/.claude/config.json` describes the workspaces Crow manages and the defaults used when scaffolding new worktrees:

```json
{
  "workspaces": [
    {
      "id": "uuid",
      "name": "Corveil",
      "provider": "github",
      "cli": "gh",
      "host": null,
      "customInstructions": "Always run npm test before committing",
      "reviewBlockingSeverities": ["red"],
      "sessionEnv": {
        "AWS_PROFILE": "dev"
      },
      "gateway": {
        "baseURL": "https://corveil.io",
        "customHeaders": {
          "x-citadel-api-key": "op://Spotlight Prod/Citadel/api_key"
        }
      }
    },
    {
      "id": "uuid",
      "name": "MyGitLab",
      "provider": "gitlab",
      "cli": "glab",
      "host": "gitlab.example.com"
    }
  ],
  "defaults": {
    "provider": "github",
    "cli": "gh",
    "branchPrefix": "feature/",
    "excludeDirs": ["node_modules", ".git", "vendor", "dist", "build", "target"],
    "excludeReviewRepos": ["zarf-dev/zarf", "bmlt-enabled/yap"],
    "excludeTicketRepos": []
  }
}
```

- **`provider`** — `github` or `gitlab`. Determines which CLI and which issue-tracker code path runs.
- **`cli`** — `gh` or `glab`. The binary that Crow shells out to.
- **`host`** — set for self-hosted GitLab; exported as `GITLAB_HOST` when invoking `glab`.
- **`branchPrefix`** — used by the `/crow-workspace` skill when creating new branches.
- **`excludeDirs`** — ignored when scanning repos for git worktrees.
- **`excludeReviewRepos`** — repos to hide from the review board (e.g., `["zarf-dev/zarf"]`). Supports `*` wildcards (e.g., `"zarf-dev/*"`). Matching reviews are filtered out from the board, sidebar badge count, and notifications. Editable in Settings → Automation → Reviews.
- **`excludeTicketRepos`** — repos to hide from the ticket board (e.g., `["zarf-dev/zarf"]`). Supports `*` wildcards (e.g., `"zarf-dev/*"`). Matching issues are filtered out from the board, pipeline counts, and auto-create candidates. Editable in Settings → Automation → Tickets.
- **`customInstructions`** — optional free-text instructions appended to the session prompt as a `## Custom Instructions` section. Use this for workspace-specific conventions, e.g., "Always run `npm test` before committing" or "Use the auth middleware in `src/middleware/auth.ts` as a pattern."
- **`reviewBlockingSeverities`** — which `crow-review-pr` finding severities force `gh pr review --request-changes` for this workspace. Any subset of `["red", "yellow", "green"]`; **absent means Crow's default, `["red", "yellow"]`**, not "nothing blocks". At least one severity is required — a workspace where nothing gates the verdict would approve every review, and with the auto-merge watcher on, merge it — so `crow workspace edit` and the Settings form both reject an empty set; `--clear-review-blocking-severities` removes the key to restore the default. Non-blocking findings are still written into the review body; only the verdict changes. Crow renders the policy into the review skill on every launch path (the copied `SKILL.md` for Claude, the inlined prompt for Cursor/Codex/OpenCode/Grok/Antigravity), but this is **advisory**: the agent invokes `gh pr review` itself, so Crow cannot validate that the posted verdict matches. Editable in Settings → Workspaces → Review verdict.
- **`sessionEnv`** — optional `KEY: VALUE` map exported into every agent launched in this workspace. Read by the `/crow-workspace` skill's setup script as one `KEY=VALUE` per line, split at the first `=` — so neither a key nor a value may contain a newline, a key may not contain `=` (a value may), and a key may not contain whitespace or control characters. `crow workspace` rejects all of these on write; existing config is never re-validated on read. Unlike `gateway`, these values are **not** treated as credentials: they are stored in plain `config.json` and are not stripped from the web Settings payload, so put tokens in a gateway header instead.
- **`gateway`** — optional AI gateway for this workspace's `claude` launches. See [AI Gateway](#ai-gateway) below.
- **`ignoreReviewLabels`** — PR labels that hide a review from the board. Exact match, case-insensitive, no wildcards. Editable in Settings → Automation → Reviews.
- **`binaries`** — absolute-path overrides keyed by tool name, e.g. `{"corveil": "/opt/corveil/bin/corveil"}`. Serves both agent binary discovery (keyed by agent kind: `claude-code`, `codex`, `cursor`, …) and external tool installers. Read at startup only, and each key becomes a symlink at `{devRoot}/.claude/bin/<name>` — so a change needs a `crowd` restart. Settings → General exposes only the `corveil` slot, and only from a local browser.

The `defaults` block is also editable from the CLI with `crow defaults get|set` — see the [CLI reference](cli-reference.md#crow-defaults-get--set). The three list fields are edited incrementally there (`--add-…` / `--remove-…` / `--clear-…`) rather than by replacement, and `--binary` is local-only.

Everything above except `gateway` is editable from the CLI with [`crow workspace`](cli-reference.md#workspace-commands) as well as Settings → Workspaces; the gateway is local-only and lives behind [`crow gateway`](cli-reference.md#gateway-commands).

For the full set of automation toggles backed by this config, see [automation.md](automation.md).

## Agent Selection

Crow can drive five coding agents. Which one a session launches is resolved from `config.json`
(all keys optional; existing configs decode unchanged):

```json
{
  "defaultAgentKind": "claude-code",
  "agentsByKind": {
    "work": "opencode",
    "review": "claude-code"
  },
  "defaults": {
    "binaries": {
      "opencode": "/Users/me/.opencode/bin/opencode",
      "cursor": "/opt/homebrew/bin/agent"
    }
  }
}
```

- **`defaultAgentKind`** — the agent used for newly created sessions when no override applies. One of `claude-code`, `codex`, `cursor`, `opencode`, `antigravity`, `grok`, `muse`. Defaults to `claude-code`.
- **`agentsByKind`** — per-session-kind overrides, keyed by session kind (`work`, `review`, `job`, `manager`). When a key is present, sessions of that kind use the mapped agent; when absent they fall back to `defaultAgentKind`. Resolution: `agentsByKind[<kind>] ?? defaultAgentKind ?? claude-code`. A session persists the resolved kind and can be overridden per-session at creation time (Create-Session picker or the `crow new-session --agent` / RPC `agent_kind` param). Mid-session switches use `crow handoff-agent` / the web “Switch agent…” control (CROW-627 / [ADR 0009](adr/0009-agent-handoff-preserves-session-not-chat.md)) — session identity and worktree stay; chat history does not transfer.
- **`defaults.binaries.<kind>`** — absolute-path override for an agent's CLI binary, keyed by agent kind (`claude-code`, `codex`, `cursor`, `opencode`, `antigravity`, `grok`, `muse`). Consulted before Crow walks `PATH`, so it pins discovery for non-standard installs (nvm/Volta/asdf) or when a token collides with another binary (e.g. Cursor's CLI resolves as `cursor-agent`, with a legacy `agent` alias that collides with grok-build; `grok` collides with `superagent-ai/grok-cli`; `muse` collides with Muse Sequencer). The same map also accepts **`crow`** — pins the Crow CLI used by `/crow-workspace`'s `setup.sh` when it runs outside a Crow terminal (e.g. from Cursor or Codex, which inherit a minimal `PATH`). Crow also symlinks every configured entry into `{devRoot}/.claude/bin/<name>` (CROW-487); `setup.sh` consults that farm before walking `PATH`.
- **`defaults.mirrorClaudeMCPToCodex`** — boolean, default `true`. When true, Crow mirrors the root-level `mcpServers` from `~/.claude.json` into Codex's `~/.codex/config.toml` (`[mcp_servers.*]`) on daemon boot, so Codex sessions get the same MCP tools (e.g. `jira`) a Claude session inherits ([#830](https://github.com/corveil/crow/issues/830)). This copies each server's `env` values — often **API tokens** — into a second on-disk file (written `0600`). Set to `false` to opt out if you deliberately keep credentials in one place. The mirror is append-only (it never overwrites a server you've hand-tuned in `config.toml`) and HTTP servers whose auth lives in `headers` are skipped rather than mirrored auth-less.

| Kind | Display name | CLI binary | Remote control | Notes |
| --- | --- | --- | --- | --- |
| `claude-code` | Claude Code | `claude` | yes (`--rc --name`) | Always registered; the default. Supports OTEL telemetry and the AI gateway. |
| `codex` | OpenAI Codex | `codex` | yes (via `crow send`) | Registered when the binary resolves. Global `config.toml` in `~/.codex` (`jira` MCP mirrored there from `~/.claude.json`); per-worktree `.codex/hooks.json`. Native `codex remote-control` stays unwired — the badge rides the `crow send` paste path (CROW-1001). |
| `cursor` | Cursor | `cursor-agent` | yes (via `crow send`) | Registered when the binary resolves and passes the identity probe (the legacy `agent` alias collides with grok-build). Per-worktree `.cursor/hooks.json` (#829); any global `~/.cursor` config a prior Crow installed is migrated off. |
| `opencode` | OpenCode | `opencode` | yes (via `crow send`) | Registered when the binary resolves. Per-worktree state-bridge plugin `.opencode/plugins/crow-hooks.js` with the session UUID baked in (the global `~/.config/opencode/plugins/` plugin is a self-suppressing fallback); `jira` MCP mirrored from `~/.claude.json` into `opencode.json` (CROW-831). Unattended `job`/`review` dispatch runs `opencode run "$(cat …)"; opencode --continue` so the initial prompt is consumed headlessly and the TUI stays open for follow-up input; auto-approve flags are probed from `opencode run --help` / `opencode --help` only for auto-permission jobs. |

| `antigravity` | Antigravity | `agy` | yes (via `crow send`) | Registered when the binary resolves. Tier-2 / experimental ([#860](https://github.com/corveil/crow/issues/860)) — closed-source, Google-auth-locked, hooks-only state detection. |
| `grok` | Grok Build | `grok` | yes (via `crow send`) | Registered when the binary resolves and passes the identity probe (`grok` collides with `superagent-ai/grok-cli`). |
| `muse` | Muse Code | `muse` | yes (via `crow send`) | Registered when the binary resolves and passes the identity probe (`muse` collides with Muse Sequencer). Tier-2 / experimental ([#1033](https://github.com/corveil/crow/issues/1033)) — closed-source, Meta-auth-locked. Bounded auto-perm is `--disable-approval` (never `--yolo`). |

Codex, Cursor, OpenCode, Antigravity, Grok, and Muse are registered only when their CLI binary is found (via `defaults.binaries.<kind>`, then `PATH`, then known install locations) and — for collision-prone tokens (`grok`, `muse`, Cursor's legacy `agent`) — passes the identity probe. Off-PATH / failed-probe agents still **surface disabled** in the pickers (#879). Claude Code is always available.

Configure the default and per-kind overrides in **Settings → General**, or from the CLI with `crow agents list` / `crow agents set` (see [cli-reference.md](cli-reference.md#agent-commands)). Note that both surfaces only offer the agents this daemon registered **at startup**, so a newly installed agent needs a `crowd` restart before it can be selected.

## AI Gateway

A workspace can route its Claude Code sessions through a proxy/gateway (e.g. an internal LLM gateway) instead of the vanilla Anthropic API, with its own API key. This replaces setting `ANTHROPIC_BASE_URL` / `ANTHROPIC_CUSTOM_HEADERS` globally in your shell — which would force *every* `claude` on the machine through one gateway — with a per-workspace setting Crow manages.

> **Using a Corveil gateway?** The hand-entered `x-citadel-api-key` gateway below is the **manual** path — it still works and is the right tool for any non-Corveil proxy. But for Corveil, the recommended path is the first-class **[Corveil connection](#corveil-connection-first-class)**: connect once (OAuth), pick an org, and Crow provisions and injects the gateway key for you. If you already have manual `x-citadel-api-key` gateways, [migrate them](#migrating-manual-gateways-to-the-connection) with `crow corveil detect-gateways` / `link-gateway`. See [ADR 0020](adr/0020-first-class-corveil-integration.md).

```jsonc
"gateway": {
  "baseURL": "https://corveil.io",
  "customHeaders": {
    // op:// reference — resolved at launch via the 1Password CLI; kept out of config.json
    "x-citadel-api-key": "op://Spotlight Prod/Citadel/api_key"
    // or a plaintext value (stored in config.json — see the security note)
    // "x-citadel-api-key": "Bearer sk-citadel-…"
  }
}
```

- **`baseURL`** — exported as `ANTHROPIC_BASE_URL` for the session's `claude` launches.
- **`customHeaders`** — a `Name: Value` map exported as `ANTHROPIC_CUSTOM_HEADERS` (newline-separated). Both fields must be set together; a `baseURL` with no headers (or vice versa) is rejected when the config is loaded.

> **Also reused for session-log upload (CROW-1070):** when a workspace opts in to Corveil transcript upload (the Settings → Workspaces "Upload session transcripts to Corveil" checkbox / `crow workspace edit --upload-session-logs true`), the collector reuses **this same gateway** — POSTing to `{baseURL}/api/crow-sessions/{id}/artifacts` with the gateway's `x-citadel-api-key`. No second key or host is needed, and because the gateway config is local-only (see [Gateways & Secrets](cli-reference.md#gateways--secrets)) the upload destination can never be a browser-writable field. See [session-log-collector.md](session-log-collector.md).

When a session resolves to a workspace with a `gateway`, Crow injects these vars two ways so they apply on the initial launch *and* survive manual `claude` re-runs:

1. **Launch line** — the `claude` invocation is prefixed with the env-var assignments, overriding any global `~/.zshrc` export for that launch. (When a workspace has multiple headers, the header value can't go on the line — an embedded newline would submit the command early — so it's carried by `settings.local.json` and the launch line instead `unset`s any inherited `ANTHROPIC_CUSTOM_HEADERS` so the gateway's `baseURL` is never paired with stale global headers.)
2. **`settings.local.json`** — the resolved values are written to the worktree's `.claude/settings.local.json` `env` block (gitignored, mode `0600`), which Claude Code reads on every run.

When no workspace claims the session — or the one that does has **no** `gateway` — Crow instead prefixes the launch with `unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS` so a global shell export, or a sibling workspace's gateway, can't bleed into it. Edit a workspace's gateway in **Settings → Workspaces**.

> **Precedence note:** the launch-line assignment is what reliably overrides a value exported by your shell for the initial launch. Whether Claude Code's `settings.local.json` `env` block *alone* overrides an inherited shell variable (e.g. an `ANTHROPIC_BASE_URL` still left in `~/.zshrc`) is not something Crow controls — so the intended end state is to delete the global `~/.zshrc` exports once per-workspace gateways are configured, leaving `config.json` the single source of truth.

> **Applied at launch:** the gateway env is resolved and written when the agent **starts** (or is handed off to another agent). A session that was already running when you edited a gateway keeps the environment it launched with — relaunch it, or hand it off, to pick up the change.

### Which gateway applies

Crow resolves a session's workspace two ways, in order:

1. **By worktree location** — work and job worktrees live at `{devRoot}/{workspace}/{repo}-{n}-{slug}`, so the folder directly under the dev root names the workspace. Matched case-insensitively. Crow-owned dev-root directories are skipped rather than looked up, so `crow-reviews` is reserved and cannot be a workspace name.
2. **By repo** — review sessions clone to `{devRoot}/crow-reviews/{repo}-pr-{N}`, which sits outside any workspace folder, so there's no path to read a workspace from. Crow instead takes the PR's `owner/repo` and finds the workspace that claims it: a slug matching `alwaysInclude` or `autoReviewRepos` (the same `org/*` glob syntax those lists use elsewhere). Before CROW-891 this step didn't exist, so **every** review silently ran with `ANTHROPIC_*` unset regardless of its workspace's gateway.

Notes on the repo lookup:

- **`excludeReviewRepos` is not consulted.** It controls what the review board *shows*, not which workspace a repo belongs to — a repo you've hidden from the board still gets its workspace's gateway when you review it manually.
- **Ambiguity is deterministic.** If two workspaces claim the same repo, one naming it exactly (`acme/widget`) beats one matching only through a glob (`acme/*`); among equals, the earlier workspace in `config.json` wins.
- **A `"*"` pattern claims everything**, making that workspace the fallback owner for any repo no other workspace names.
- **No match means unset, not inherit.** A PR in a repo no workspace claims runs against the vanilla Anthropic API and logs `No workspace claims repo …`. The Manager's gateway is never inherited by other sessions — see [Manager gateway](#manager-gateway).

Both membership lists are editable from **Settings → Workspaces** or with `crow workspace edit --workspace NAME --always-include acme/widget --auto-review-repo 'acme/*'` (note those flags replace the whole list rather than appending — see [cli-reference.md](cli-reference.md#workspace-commands)). So a review that resolved to no gateway is usually fixed by adding its repo to the owning workspace.

Because the two lookups are independent, a repo cloned under one workspace's folder but claimed by *another* workspace's membership list resolves **differently depending on session kind** — a work session by path, a review of that repo's PR by slug. That is intended (the slug fallback exists precisely because review clones have no workspace folder), but it means "reviews fail and work sessions don't" can be a workspace-binding symptom rather than an agent one. To see which applied, either read the launch line in the daemon log:

```
[SessionService] Gateway for session <uuid>: workspace 'Corveil' (matched by repo_slug)
    -> https://gw.example.com, headers: x-citadel-api-key
```

or ask before launching, with `crow get-session --session <uuid>` — its `workspace_name` / `workspace_match` fields report the same decision (see [cli-reference.md](cli-reference.md#crow-get-session)). Header **names** appear in the log line; values never do.

### Secret storage

A header value can be either:

- **An `op://` reference** (recommended) — resolved at session launch via the 1Password CLI (`op read`). The secret is **never written to `config.json`**. Requires `op` installed and signed in; a failed lookup drops that header and logs a redacted warning (the gateway then rejects the request rather than silently falling back to the vanilla API).
- **A plaintext value** — stored as-is in `config.json` (mode `0600`). Convenient for local dev, but **anyone with read access to the file can see the key**. The Settings UI shows a warning. Prefer an `op://` reference for production keys.

Either way, the value must not carry **literal surrounding quotes** — a `"` or `'` at both ends. Values are stored and transmitted verbatim, so the quotes become part of the credential and the gateway rejects the request, which the agent reports only as "API error". Worse, quotes around an `op://` reference stop it from being recognized as one, so it is never resolved and the literal string is sent instead. Every write path now rejects this shape.

A value stored *before* that check still launches — Crow warns rather than editing a credential it can't verify. Look for:

```
[GatewayResolver] Header 'x-citadel-api-key' has a value wrapped in quote characters; …
```

Re-set it with `crow gateway set` (no inner quotes) to clear the warning.

`op://` keeps secrets out of `config.json` — but note it does **not** mean "no secret on disk." The *resolved* value is written into the worktree's `.claude/settings.local.json` `env` block (so manual re-runs inherit it) and cached there for the worktree's lifetime. That file is gitignored and written `0600` (owner-only), the same protection `config.json` gets. Resolved secret values are never logged.

Since CROW-891 this also applies to **review clones**, which contain code from the PR's author. The file is still `0600` and Crow never executes the clone, but the resolved header now lives inside a directory of untrusted code — so an agent in a review session can read it if a hostile PR talks it into doing so. If that matters for your gateway key, exclude those repos from the workspace's `alwaysInclude`/`autoReviewRepos` so reviews on them resolve to no gateway.

### Manager gateway

The Manager session sits at the dev root and isn't bound to a single workspace, so it has its **own** top-level gateway rather than inheriting any one workspace's:

```jsonc
{
  "managerGateway": {
    "baseURL": "https://corveil.io",
    "customHeaders": { "x-citadel-api-key": "op://Spotlight Prod/Citadel/api_key" }
  }
}
```

Same shape, same secret-storage rules, same two-way injection (written to `{devRoot}/.claude/settings.local.json`). Configure it under **Settings → Automation → Manager AI Gateway**. Takes effect on the next app launch.

## Corveil connection (first-class)

For a **Corveil** gateway, the recommended path is not a hand-entered `x-citadel-api-key` header but a first-class OAuth **connection** (CROW-1117, [ADR 0020](adr/0020-first-class-corveil-integration.md)). You **Connect** once under **Settings → Integrations → Corveil**; Crow self-registers with Corveil's authorization server (Dynamic Client Registration + PKCE, a `127.0.0.1` loopback callback), stores the resulting tokens in a top-level `corveilConnection` block, and keeps the access token fresh in the background (CROW-1125). From there the gateway editors show an **org dropdown** instead of a raw base-URL + header form: pick an org and Crow mints (or reuses) **one** `sk-citadel-…` gateway key for it and injects the derived gateway automatically.

```jsonc
{
  "corveilConnection": {
    "baseURL": "https://corveil.example",
    "clientID": "…",                    // from Dynamic Client Registration
    "connectedUser": { "id": "…", "email": "…", "name": "…" },
    "orgKeys": [                          // metadata only — never key material
      { "orgID": "org1", "orgName": "Acme", "keyID": "key1", "keyPrefix": "sk-citadel-AbC" }
    ]
    // oauth tokens + per-org key secrets live here too, stripped before any browser sees them
  }
}
```

- **The connection is the source of truth; the gateway is *generated* from it.** When a workspace (or the Manager) is bound to an org, the effective `WorkspaceGateway` is `baseURL` + `x-citadel-api-key: <that org's key>` — so [gateway resolution](#which-gateway-applies) and the [session-log collector](session-log-collector.md) consume it as an ordinary gateway, no special-casing.
- **One key per org, reused.** Every workspace bound to the same org shares its one key. The backend rotates the key on each mint, so Crow reuses the stored value and only re-mints on an explicit rotate.
- **Local-only, like every other credential.** The whole `corveilConnection` surface — Connect, org selection, and the migration verbs below — is authored only over the local Unix socket / a local-direct browser POST; a remote web session gets a read-only view (tokens and key values stripped). See [Gateways & Secrets](cli-reference.md#gateways--secrets).
- Drive it from the CLI with `crow corveil connect` / `status` / `list-orgs` / `select-org` (see the [CLI reference](cli-reference.md#the-corveil-connection)).

### Migrating manual gateways to the connection

If you configured Corveil the old way — a `gateway` with a hand-entered `x-citadel-api-key` header — you can bring that key under the connection without disrupting the running session (CROW-1126):

```bash
crow corveil detect-gateways                          # list manual x-citadel-api-key gateways, classified
crow corveil link-gateway --workspace Acme --org org1 # adopt one workspace's key into the connection
crow corveil link-gateway --manager --org org1        # …or the Manager gateway
```

- **`detect-gateways`** scans the Manager and every workspace gateway for the `x-citadel-api-key` header and classifies each: **`managed`** (already equals the connection's derived gateway for a provisioned org), **`linkable`** (a plaintext key on the connection's base URL — adopt it), or **`manual`** (not linkable yet, with a `reason`: no connection, an `op://` value, or a base URL that doesn't match the connection). Key material is never printed — only a redacted prefix.
- **`link-gateway`** *adopts* the target's existing plaintext key as the named org's key in the connection. It is **non-disruptive** (the running key is unchanged) and **offline** — because the Corveil backend has no key→org lookup, you supply the org. The adopted key is stored with **no key id** (it was entered by hand, not minted by Crow), which is also the upgrade path: a later `crow corveil select-org --org <id>` mints a real, revocable managed key in its place. Only a gateway on the **connection's own base URL** is adopted (`op://` references are not); and if the org already has a *provisioned* key, `link-gateway` refuses rather than orphan it — retire it with `crow corveil deselect-org --org <id>` first (that revokes it on Corveil), then link.

## Jira MCP

For workspaces with `taskProvider: "jira"`, Crow drives the **agent-side** Jira flow (create-with-assignee, assign/reassign, transition, fetch, comment) through the **`jira` MCP server** (`sooperset/mcp-atlassian`, Docker stdio) using the `jira_*` tools instead of `acli`. `acli` cannot set an assignee at create time, so every ticket it filed landed unassigned; the MCP `jira_create_issue` tool sets the assignee in one step. (Crow's in-app issue-board polling and auto-complete still use `acli` — only the agent flow moved.)

The `jira` server lives **globally** in `~/.claude.json`'s top-level `mcpServers`, so it is auto-loaded and trusted in every Claude Code session. Crow injects **nothing** — no per-session `.mcp.json` and no `enabledMcpjsonServers` entry (CROW-528):

```jsonc
// ~/.claude.json (user-global) — not written by Crow
{ "mcpServers": { "jira": {
    "type": "stdio",
    "command": "docker",
    "args": ["run","-i","--rm","-e","JIRA_URL","-e","JIRA_USERNAME","-e","JIRA_API_TOKEN",
             "ghcr.io/sooperset/mcp-atlassian:latest","--transport","stdio"],
    "env": { "JIRA_URL": "https://<site>.atlassian.net",
             "JIRA_USERNAME": "you@example.com",
             "JIRA_API_TOKEN": "${JIRA_API_KEY}" } } } }
```

- **Auth** is a **personal API token** (from <https://id.atlassian.com>) passed to the container via the `JIRA_*` env vars. The same global config serves worktree sessions, the Manager, and cron jobs.
- **`gh`/`glab` GitHub/GitLab task paths are unaffected.**

> **In-app status fetch.** The "Fetch from Jira" status-map button (below) is the one Jira feature that runs in the **crowd process**, which can't use the MCP. It uses a separate small credential under **Settings → Automation → Jira (status fetch)**, stored top-level in `config.json` as `jiraCredential` (`username` + an `op://`/plaintext `tokenRef`, same secret rules as gateway keys). Crow builds `Authorization: Basic base64(username:token)` on demand to call Jira's REST API directly; it is never written to a launched session.

### Jira status mapping

Jira workflow **status names are configurable per project**, so a project that renames a status (e.g. "In Development" instead of "In Progress") would otherwise make Crow's transitions silently fail. Each Jira workspace can map Crow's pipeline states to that project's concrete Jira status names via the per-workspace **`jiraStatusMap`** field:

```jsonc
{
  "workspaces": [
    {
      "name": "MyOrg",
      "taskProvider": "jira",
      "jiraProjectKey": "PROPS",
      "jiraStatusMap": {
        // Crow pipeline state (TicketStatus raw value) → this project's Jira status name
        "Ready": "To Do",
        "In Progress": "In Development",
        "In Review": "Code Review"
      }
    }
  ]
}
```

- **Keys** are Crow's pipeline states: `Backlog`, `Ready`, `In Progress`, `In Review`, `Done`. **Values** are the exact Jira workflow status names for that project (case- and spelling-sensitive).
- **A missing or blank entry falls back to the built-in default:** `Ready` → `To Do`; every other state uses its own name verbatim (`In Progress`, `In Review`, `Done`, `Backlog`). An entirely unset `jiraStatusMap` keeps today's behavior.
- Both status surfaces consult the map: the in-app **"Mark in review"** transition (`acli`) and the **agent-side** `jira` MCP flow — the `/crow-workspace` skill reads `jiraStatusMap` from `config.json`, then resolves the mapped status name to a `transition_id` via `jira_get_transitions` before calling `jira_transition_issue`.

Edit it under **Settings → Workspaces → (a Jira workspace) → Jira Status Mapping**. Each pipeline state gets a field whose placeholder is the current default — leave it blank to keep the default. If a **Jira (status fetch)** credential is configured (Settings → Automation), **Fetch from Jira** populates per-row dropdowns from the project's live workflow (`GET /rest/api/3/project/{key}/statuses`); otherwise the fields are free-text.

## Manager Terminal

The Manager tab runs Claude Code at the dev root and drives workspace orchestration. Its behavior is controlled by these top-level keys in `{devRoot}/.claude/config.json`:

- **`managerAutoPermissionMode`** (default: `true`) — passes `--permission-mode auto` to the Manager's `claude` launch so it can run `crow`, `gh`, and `git` commands without per-call approval. Requires Claude Code **v2.1.83+**, a **Max / Team / Enterprise / API** plan, the **Anthropic** API provider (not Bedrock / Vertex / Foundry), and a supported model (**Sonnet 4.6**, **Opus 4.6**, or **Opus 4.7**). On Team/Enterprise plans an admin must enable auto mode in Claude Code admin settings. Turn this off via **Settings → Automation → Manager Terminal** if your account reports auto mode as unavailable. Worker sessions and CLI-spawned terminals are unaffected by this setting.
- **`remoteControlEnabled`** (default: `false`) — launches new Claude Code sessions with `--rc` so you can control them from claude.ai or the Claude mobile app.
- **`managerGateway`** — optional AI gateway for the Manager's `claude` launch, with its own API key. See [Manager gateway](#manager-gateway).

Changes take effect on next app launch — the Manager's stored command is rebuilt on hydration, or on demand with `crow restart-manager`. `crow automation set --manager-auto-permission-mode …` returns `"manager_restart_required": true` on a real change to say so.

## Automation

The twelve booleans behind **Settings → Automation**, editable there or from the CLI (`crow automation get|set` — see the [CLI reference](cli-reference.md#automation-commands)). Eight are top-level keys in `{devRoot}/.claude/config.json`; four live under `autoRespond`.

| Key                                          | Default | Applies to                                                       |
| -------------------------------------------- | ------- | ---------------------------------------------------------------- |
| `remoteControlEnabled`                       | `false` | Newly launched sessions (adds `--rc`)                            |
| `managerAutoPermissionMode`                  | `true`  | The Manager terminal, on rebuild — see above                     |
| `reviewAutoPermissionMode`                   | `true`  | Newly launched review sessions                                    |
| `coderViewAutoPermissionMode`                | `false` | Newly launched work coder views                                   |
| `jobsAutoPermissionMode`                     | `true`  | The next scheduled job run (Settings renders it on the Jobs tab) |
| `attributionTrailers`                        | `true`  | Newly created worktrees (installs the commit-trailer hook)       |
| `autoCreateWatcherEnabled`                   | `false` | The `crow:auto` / `crow:explore` issue watcher                    |
| `autoMergeWatcherEnabled`                    | `false` | The `crow:merge` PR watcher                                       |
| `autoRespond.respondToChangesRequested`      | `true`  | Changes-requested reviews                                         |
| `autoRespond.respondToFailedChecks`          | `false` | Failed CI checks                                                  |
| `autoRespond.autoRebaseAndResolveConflicts`  | `false` | Conflicted PRs (rebase + `--force-with-lease` push)              |
| `autoRespond.autoReRequestReview`            | `true`  | Changes-requested PRs whose fix has landed (re-adds the reviewers) |

**Live — no `crowd` restart.** The daemon re-reads `config.json` rather than holding a snapshot: `applyConfigToAppState` runs each board tick, the watcher gates are closures that reload config on every call, and `AutoRespondCoordinator` takes a settings closure. So a change is picked up within about a minute. The "applies to" column is about *scope*, not latency — a permission-mode change reaches the next session you launch, not the ones already running.

Six of the twelve default to **on**, which is why `crow automation set` takes explicit `true`/`false` values rather than bare flags: a bare-flag design could never turn one off.

**Hand-editing note.** `autoRebaseAndResolveConflicts` replaced a pre-CROW-551 top-level `autoRebaseWatcherEnabled`. That legacy key is still honored on read as a one-way opt-in (a stored `true` forces the new field on) but is dropped on the next write, so an opt-out through Settings or the CLI sticks. If you are editing the file by hand, delete the legacy key rather than setting it to `false`.

The Automation tab also carries three board-filter lists (`defaults.excludeReviewRepos`, `defaults.ignoreReviewLabels`, `defaults.excludeTicketRepos`). Those live in the `defaults` block above and are written by `crow defaults set`; `crow automation get` echoes them read-only alongside the derived `effective_exclude_review_repos`. The tab's `managerGateway` and `jiraCredential` blocks are documented elsewhere on this page.

## Telemetry, Cleanup & UI

Three top-level blocks in `{devRoot}/.claude/config.json`, editable from **Settings → General** or from the CLI (`crow telemetry`, `crow cleanup`, `crow ui` — see the [CLI reference](cli-reference.md#settings-commands)). Their take-effect semantics differ, which is the part worth knowing before you script them.

**`telemetry`** — session analytics via Claude Code's OpenTelemetry exporter.

| Key             | Default | Range          | Description                                                     |
| --------------- | ------- | -------------- | --------------------------------------------------------------- |
| `enabled`       | `false` | boolean        | Runs the OTLP HTTP receiver                                     |
| `port`          | `4318`  | 1024–65535     | Receiver port                                                    |
| `retentionDays` | `180`   | ≥ 0            | Days of telemetry to keep; `0` disables pruning (keep forever)   |

**Requires a `crowd` restart.** `enabled` and `port` are read once at startup, and the port is baked into every agent launch's `OTEL_EXPORTER_OTLP_ENDPOINT`, so a running daemon cannot adopt a change. `retentionDays` drives a prune that runs once at startup, so it also applies at the next start. `crow telemetry set` returns `"restart_required": true` when `enabled` or `port` actually changed.

**`cleanup`** — automatic deletion of finished sessions.

| Key              | Default | Range   | Description                                            |
| ---------------- | ------- | ------- | ------------------------------------------------------ |
| `enabled`        | `false` | boolean | Arms auto-cleanup                                      |
| `retentionHours` | `24`    | ≥ 1     | Hours to keep completed/archived sessions before deletion |

**Live — no restart.** The board poll re-reads config from disk every cycle, so a change is picked up within about a minute. Deletion includes the session's worktree and branch; Manager, virtual, and locked sessions are never eligible. The `≥ 1` floor is enforced because the cutoff is `now - retentionHours`: `0` would delete a session the moment it completes, and a negative value would push the cutoff into the future and sweep every completed and archived session at once.

**`sidebar`** — view preferences (the `ui` CLI group's first block).

| Key                  | Default | Range   | Description                                              |
| -------------------- | ------- | ------- | -------------------------------------------------------- |
| `hideSessionDetails` | `false` | boolean | Hides ticket title and repo/branch lines in sidebar rows |

**Live in the browser — no restart, no reload.** The daemon watches `config.json`'s mtime and pushes a `configReloaded` event on change, so connected clients re-read the view-affecting slice within a couple of seconds regardless of who wrote it (Settings modal, `crow ui set`, or a hand edit).
## Notifications

The `notifications` block in `{devRoot}/.claude/config.json` controls when Crow chimes and posts a system notification. Edit it from **Settings → Notifications**, from the CLI with [`crow notifications get|set`](cli-reference.md#notification-commands), or by hand.

Notifications cascade — one fires only if `globalMute` is off, the matching global category toggle is on, **and** the per-event toggle is on.

```json
{
  "notifications": {
    "globalMute": false,
    "soundEnabled": true,
    "systemNotificationsEnabled": true,
    "eventSettings": [
      "checksFailing",
      {
        "enabled": true,
        "soundEnabled": true,
        "systemNotificationEnabled": true,
        "soundName": "Sosumi"
      }
    ]
  }
}
```

- **`globalMute`** (default: `false`) — master mute; suppresses every sound and system notification.
- **`soundEnabled`** (default: `true`) — global sound-playback toggle.
- **`systemNotificationsEnabled`** (default: `true`) — global system-notification toggle.
- **`eventSettings`** — per-event overrides, holding only the events you've actually changed. Any event you omit follows the current defaults, so leaving events out is the way to stay on Crow's defaults as they evolve. Neither Crow nor `crow notifications set` will backfill the rest.

The twelve events are `taskComplete`, `agentWaiting`, `reviewRequested`, `changesRequested`, `checksFailing`, `autoWorkspaceCreated`, `autoMergeEnabled`, `autoMergeBlocked`, `autoRebasePushed`, `autoRebaseConflicts`, `autoRebaseStuck`, and `configReloaded`. The 14 built-in sounds are `Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`, `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, and `Tink`. Custom sounds live as files in `~/Library/Application Support/crow/sounds/` (`.wav` / `.mp3` / `.aiff`, 2 MB); their names appear in `available_sounds` next to the built-ins. Per-event `soundName` stores that name as a reference — never the file bytes. A missing custom file falls back to a default at playback. Add via Settings → Notifications → Upload sound, `crow notifications add-sound <path>`, or by dropping a file into that directory.

Three things to know before hand-editing:

- **`eventSettings` must be the flat alternating array shown above** — event name, settings object, event name, settings object, … — and *not* a JSON object. That falls out of how Swift encodes a dictionary keyed by an enum, and the decoder accepts only that form. Writing `"eventSettings": {"checksFailing": {…}}` fails with `Expected to decode Array<Any> but found a dictionary`, which takes the **whole** `config.json` down with it: Crow falls back to defaults on every read, and writes refuse until you fix the file. If you'd rather read it as an object, use `crow notifications get`, which presents it that way.
- **An omitted `soundName` inside an event entry becomes `Glass`, not that event's default.** Decoding an entry can't see which event keys it, so there is no per-event fallback at that level. Writing `{"enabled": false}` for `checksFailing` silently changes its sound from Sosumi to Glass; same for `autoRebaseConflicts` / `autoRebaseStuck` / `autoMergeBlocked` (Basso), `agentWaiting`/`changesRequested` (Funk), `autoWorkspaceCreated` (Hero), `autoRebasePushed` (Bottle), `configReloaded` (Tink). Either spell `soundName` out in a partial entry, or edit through `crow notifications set`, which always writes a complete entry seeded from the event's real default.
- **The global key is `systemNotificationsEnabled` (plural); the per-event key is `systemNotificationEnabled` (singular).** The CLI flags mirror the same split.

Every other key you leave out — of `notifications` or of an individual event entry — falls back to its documented default rather than failing the load, so a partial hand edit won't break config parsing.

## Directory Structure

Crow expects repositories organized under workspace folders:

```
~/Dev/                             # Development root
├── Corveil/                       # Workspace (GitHub)
│   ├── acme-api/                   # Main repo checkout
│   ├── acme-api-134-sensor/        # Worktree for issue #134
│   └── acme-api-209-review/        # Worktree for issue #209
└── MyGitLab/                      # Workspace (GitLab)
    ├── my-project/
    └── overrides/
```

Worktrees are created **at the same level as the main repo**, not in a `worktrees/` subdirectory. The path convention is `{devRoot}/{workspace}/{repo}-{ticketNumber}-{slug}`.

## Environment Variables

| Variable              | Purpose                                                                                            | Default                        |
| --------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------ |
| `CROW_SOCKET`         | Override the Unix socket path for CLI ↔ server IPC (also the `crowd` bind path)                    | `~/.local/share/crow/crow.sock` |
| `TMPDIR`              | Temporary file directory (used by the terminal subsystem)                                          | System default                 |
| `GITLAB_HOST`         | GitLab instance hostname (set automatically per workspace from `host` in `config.json`)            | —                              |
| `CROW_HOOK_DEBUG`     | Set to `1` to enable `[hook-event]` debug logging                                                  | unset                          |

## Session Lifecycle

| State       | Trigger                                                                    | Sidebar indicator                                             |
| ----------- | -------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `active`    | Created via `/crow-workspace` or `crow new-session`                        | Green dot (or gray / yellow / blue during terminal init)      |
| `inReview`  | PR opened or manually marked in review                                     | Gold eye icon                                                 |
| `completed` | PR merged or issue closed (auto-detected), or manual "Mark as Completed"   | Gold checkmark                                                |
| `archived`  | Manual                                                                     | Gray archive icon                                             |
| `paused`    | Manual                                                                     | Yellow indicator                                              |

## Terminal Readiness

`TerminalReadiness` (`Packages/CrowCore/Sources/CrowCore/Models/Enums.swift:41`) tracks how far each managed terminal has progressed through startup. The sidebar dot in `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/sidebar.js` reflects the current state:

1. **Gray dot (`uninitialized`)** — `XTermSurfaceView` exists but `createSurface()` has not been called yet.
2. **Yellow dot (`surfaceCreated`)** — the xterm.js surface exists and the shell process (`PTYProcess`) is spawning.
3. **Blue dot (`shellReady`)** — Shell prompt detected (probe file appeared).
4. **Green dot (`claudeLaunched`)** — `claude --continue` has been sent. The dot shows:
   - Solid green when Claude is idle
   - Pulsing green when Claude is working
   - Pulsing orange when Claude is awaiting input

A loading overlay shows "Waiting for terminal..." or "Shell starting..." until `shellReady` is reached.

## Safe Deletion

Deleting a session whose worktree is on a protected branch (`main`, `master`, `develop`) only removes the session metadata — the repo folder and branch are preserved. The delete confirmation dialog reflects this by showing "Remove Session" instead of "Delete Everything".
