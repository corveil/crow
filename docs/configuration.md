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
| `{devRoot}/crow-reviews/`                                             | Temporary clones used when reviewing PRs                      |

## Workspace Configuration

`{devRoot}/.claude/config.json` describes the workspaces Crow manages and the defaults used when scaffolding new worktrees:

```json
{
  "workspaces": [
    {
      "id": "uuid",
      "name": "RadiusMethod",
      "provider": "github",
      "cli": "gh",
      "host": null,
      "customInstructions": "Always run npm test before committing",
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
- **`gateway`** — optional AI gateway for this workspace's `claude` launches. See [AI Gateway](#ai-gateway) below.

For the full set of automation toggles backed by this config, see [automation.md](automation.md).

## Agent Selection

Crow can drive four coding agents. Which one a session launches is resolved from `config.json`
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

- **`defaultAgentKind`** — the agent used for newly created sessions when no override applies. One of `claude-code`, `codex`, `cursor`, `opencode`. Defaults to `claude-code`.
- **`agentsByKind`** — per-session-kind overrides, keyed by session kind (`work`, `review`, `job`, `manager`). When a key is present, sessions of that kind use the mapped agent; when absent they fall back to `defaultAgentKind`. Resolution: `agentsByKind[<kind>] ?? defaultAgentKind ?? claude-code`. A session persists the resolved kind and can be overridden per-session at creation time (Create-Session picker or the `crow new-session --agent` / RPC `agent_kind` param). Mid-session switches use `crow handoff-agent` / the web “Switch agent…” control (CROW-627 / [ADR 0009](adr/0009-agent-handoff-preserves-session-not-chat.md)) — session identity and worktree stay; chat history does not transfer.
- **`defaults.binaries.<kind>`** — absolute-path override for an agent's CLI binary, keyed by agent kind (`claude-code`, `codex`, `cursor`, `opencode`). Consulted before Crow walks `PATH`, so it pins discovery for non-standard installs (nvm/Volta/asdf) or when a token collides with another binary (e.g. Cursor's CLI is named `agent`). The same map also accepts **`crow`** — pins the Crow CLI used by `/crow-workspace`'s `setup.sh` when it runs outside a Crow terminal (e.g. from Cursor or Codex, which inherit a minimal `PATH`). Crow also symlinks every configured entry into `{devRoot}/.claude/bin/<name>` (CROW-487); `setup.sh` consults that farm before walking `PATH`.

| Kind | Display name | CLI binary | Remote control | Notes |
| --- | --- | --- | --- | --- |
| `claude-code` | Claude Code | `claude` | yes (`--rc --name`) | Always registered; the default. Supports OTEL telemetry and the AI gateway. |
| `codex` | OpenAI Codex | `codex` | no | Registered when the binary resolves. Global config in `~/.codex`. |
| `cursor` | Cursor | `agent` | yes (via `crow send`) | Registered when the binary resolves. Global hooks in `~/.cursor`. |
| `opencode` | OpenCode | `opencode` | yes (via `crow send`) | Registered when the binary resolves. Global state-bridge plugin in `~/.config/opencode/plugins/`. Unattended `job`/`review` dispatch runs `opencode run "$(cat …)"; opencode --continue` so the initial prompt is consumed headlessly and the TUI stays open for follow-up input; auto-approve flags are probed from `opencode run --help` / `opencode --help` only for auto-permission jobs. |

Codex, Cursor, and OpenCode are registered only when their CLI binary is found (via `defaults.binaries.<kind>`, then `PATH`, then known install locations) — otherwise they silently stay out of the agent pickers. Claude Code is always available. Configure the default and per-kind overrides in **Settings → Agents**.

## AI Gateway

A workspace can route its Claude Code sessions through a proxy/gateway (e.g. an internal LLM gateway) instead of the vanilla Anthropic API, with its own API key. This replaces setting `ANTHROPIC_BASE_URL` / `ANTHROPIC_CUSTOM_HEADERS` globally in your shell — which would force *every* `claude` on the machine through one gateway — with a per-workspace setting Crow manages.

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

- **`baseURL`** — exported as `ANTHROPIC_BASE_URL` for the workspace's `claude` launches.
- **`customHeaders`** — a `Name: Value` map exported as `ANTHROPIC_CUSTOM_HEADERS` (newline-separated). Both fields must be set together; a `baseURL` with no headers (or vice versa) is rejected when the config is loaded.

When a workspace has a `gateway`, Crow injects these vars two ways so they apply on the initial launch *and* survive manual `claude` re-runs:

1. **Launch line** — the `claude` invocation is prefixed with the env-var assignments, overriding any global `~/.zshrc` export for that launch. (When a workspace has multiple headers, the header value can't go on the line — an embedded newline would submit the command early — so it's carried by `settings.local.json` and the launch line instead `unset`s any inherited `ANTHROPIC_CUSTOM_HEADERS` so the gateway's `baseURL` is never paired with stale global headers.)
2. **`settings.local.json`** — the resolved values are written to the worktree's `.claude/settings.local.json` `env` block (gitignored, mode `0600`), which Claude Code reads on every run.

When a workspace has **no** `gateway`, Crow instead prefixes the launch with `unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS` so a global shell export — or a sibling workspace's gateway — can't bleed into it. Edit a workspace's gateway in **Settings → Workspaces**.

> **Precedence note:** the launch-line assignment is what reliably overrides a value exported by your shell for the initial launch. Whether Claude Code's `settings.local.json` `env` block *alone* overrides an inherited shell variable (e.g. an `ANTHROPIC_BASE_URL` still left in `~/.zshrc`) is not something Crow controls — so the intended end state is to delete the global `~/.zshrc` exports once per-workspace gateways are configured, leaving `config.json` the single source of truth.

### Secret storage

A header value can be either:

- **An `op://` reference** (recommended) — resolved at session launch via the 1Password CLI (`op read`). The secret is **never written to `config.json`**. Requires `op` installed and signed in; a failed lookup drops that header and logs a redacted warning (the gateway then rejects the request rather than silently falling back to the vanilla API).
- **A plaintext value** — stored as-is in `config.json` (mode `0600`). Convenient for local dev, but **anyone with read access to the file can see the key**. The Settings UI shows a warning. Prefer an `op://` reference for production keys.

`op://` keeps secrets out of `config.json` — but note it does **not** mean "no secret on disk." The *resolved* value is written into the worktree's `.claude/settings.local.json` `env` block (so manual re-runs inherit it) and cached there for the worktree's lifetime. That file is gitignored and written `0600` (owner-only), the same protection `config.json` gets. Resolved secret values are never logged.

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

Changes take effect on next app launch — the Manager's stored command is rebuilt on hydration.

## Directory Structure

Crow expects repositories organized under workspace folders:

```
~/Dev/                             # Development root
├── RadiusMethod/                  # Workspace (GitHub)
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

`TerminalReadiness` (`Packages/CrowCore/Sources/CrowCore/Models/Enums.swift:41`) tracks how far each managed terminal has progressed through startup. The sidebar dot in `Packages/CrowDaemon/Sources/CrowDaemon/Resources/web/app.js` reflects the current state:

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
