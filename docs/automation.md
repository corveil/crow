# Automation

Crow automates the boring parts of moving a ticket from "assigned" to "merged". This page is the single source of truth for what each automation does, how to turn it on or off, and where the toggles live.

## Lifecycle

A fully automated ticket walks through these stages:

1. **Assignment** — an issue is assigned to you. If it carries the `crow:auto` label *and* the **Auto-launch workspaces** toggle is on (off by default — #312), Crow auto-creates a workspace for it (#211).
2. **Workspace** — a git worktree is created, ticket metadata is captured, and the issue is moved to "In Progress" on the project board.
3. **Session** — Claude Code launches in plan mode with the issue context. Worker sessions inherit the configured permission mode; the Manager terminal can launch with `--permission-mode auto` (#189).
4. **PR open** — when Claude pushes the branch and you open a PR, Crow auto-suggests opening one if you forget (#213).
5. **Review** — repos that opt in get a review session auto-started when the PR turns reviewable (#209). The review board lets you batch-start, bulk-delete, and filter sessions (#207, #210, #212, #220, #226, #231).
6. **Status response** — Crow can prompt Claude to fix changes-requested reviews and failing CI runs without you typing anything (#214).
7. **Completion** — the session moves to Completed once the PR is merged or the issue is closed *and* the session shows positive evidence the work was attempted (#182). Session analytics are emitted via Claude Code's OpenTelemetry pipeline (#137).

## Settings → Automation tab

PR #228 split every automation toggle out of General into its own tab. Open **Settings → Automation** to find:

### Reviews

- **Excluded Repos** — comma-separated list of repos to hide from the review board, sidebar badge counts, and review notifications. Supports `*` wildcards: `zarf-dev/*` hides every repo in the org; `bmlt-enabled/yap` hides one. Backed by `defaults.excludeReviewRepos` in `{devRoot}/.claude/config.json`. Per-workspace auto-review opt-ins (#209) are configured separately in **Workspaces → edit workspace**.

### Tickets

- **Excluded Repos** — comma-separated, wildcard-aware list of repos to hide from the ticket board, pipeline counts, and auto-create candidates. Backed by `defaults.excludeTicketRepos`. An issue in an excluded repo will not be considered for auto-create even if it carries the `crow:auto` label.

### Remote Control

- **Enable remote control for new sessions** — when on, new Claude Code sessions launch with `--rc` so you can drive them from claude.ai or the Claude mobile app. Each session's remote name matches its Crow session name. Backed by `remoteControlEnabled`. Off by default.

### Manager Terminal

- **Launch in auto permission mode** — passes `--permission-mode auto` to the Manager's `claude` invocation so orchestration commands (`crow`, `gh`, `git`) run without per-call approval prompts. Default **on**. Requires:
  - Claude Code **2.1.83+**
  - **Max / Team / Enterprise / API** plan
  - **Anthropic** API provider (not Bedrock / Vertex / Foundry)
  - A supported model: **Sonnet 4.6**, **Opus 4.6**, or **Opus 4.7**
  - On Team / Enterprise plans, an admin must enable auto mode in Claude Code admin settings.

  Turn this off if your account reports auto mode as unavailable. Worker sessions and CLI-spawned terminals are unaffected. Takes effect on next app launch — the Manager's stored command is rebuilt on hydration.

### Jira MCP

`acli` cannot set a Jira assignee (at create or after) and its transitions are unreliable, so every ticket Crow filed landed unassigned. The **agent-side** Jira flow (create-with-assignee, assign/reassign, transition, fetch, comment) now routes through the **`jira` MCP server** (`sooperset/mcp-atlassian`, Docker stdio) using the `jira_*` tools. Crow's in-app issue-board polling and auto-complete still use `acli` (that path works); only the agent flow moved.

The `jira` server is configured **globally** in `~/.claude.json`'s top-level `mcpServers` (Docker stdio with `JIRA_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN`), so it is auto-loaded and trusted in **every** Claude Code session — worktrees, the Manager, and cron jobs. Crow therefore injects nothing: there is no per-session `.mcp.json` or `enabledMcpjsonServers` entry to write (CROW-528). The launched agent (and the `/crow-create-ticket`, `/crow-workspace`, `/crow-batch-workspace` skills) call the `jira_*` tools — `jira_get_issue`, `jira_create_issue`, `jira_update_issue`, `jira_transition_issue` (+ `jira_get_transitions`), `jira_add_comment`, `jira_get_user_profile` — instead of `acli`. `gh`/`glab` GitHub/GitLab task paths are untouched.

<a id="atlassian-mcp-headless-auth"></a>
**Headless auth — one-time setup.** The `jira` server authenticates with a **personal API token** via the `JIRA_*` env vars in its `~/.claude.json` entry. Create the token at <https://id.atlassian.com> → Security → API tokens and set `JIRA_URL` (your `https://<site>.atlassian.net`), `JIRA_USERNAME` (account email), and `JIRA_API_TOKEN`. The same global config serves the Manager and cron jobs, so no Crow-side credential is needed for the agent flow.

> **In-app status fetch.** The "Fetch from Jira" button in **Settings → Workspaces** (the #523 status map) calls Jira's REST API *directly from the Crow app process*, which cannot use the MCP. That one feature uses a small **Settings → Automation → Jira (status fetch)** credential (`JIRA_USERNAME` + an `op://`/plaintext API token), stored in `config.json` as `jiraCredential`. It is unrelated to the agent-side MCP.

### Auto-respond

PR #214 added two opt-in toggles that let Crow type a follow-up instruction into a session's Claude Code terminal when a PR signal arrives. Both are off by default — typing into a running terminal unprompted is intrusive.

- **Respond to "changes requested" reviews** — when a PR review requests changes, Crow types an instruction into the linked session's Claude Code terminal asking Claude to read the review and address each comment.
- **Respond to failed CI checks** — when CI checks transition to failure, Crow types an instruction asking Claude to investigate the logs and push a fix.

Both toggles read from `AutoRespondSettings` in `AppConfig`. The session must have an active Claude Code terminal for the instruction to land.

### Auto-launch workspaces

PR #312 gated the existing `crow:auto` label automation behind a single opt-in toggle. Off by default — typing `/crow-workspace` into the Manager terminal without an explicit opt-in is intrusive, and matches the precedent set by `crow:merge` auto-merge (#299).

- **Auto-launch workspaces for `crow:auto` labeled issues** — when on, Crow watches assigned open issues each polling cycle. If one carries the `crow:auto` label, Crow sends `/crow-workspace <issue-url>` to the Manager terminal and strips the label so the trigger is one-shot. While off, the label is intentionally left in place so a later opt-in still picks up the issue. Requires Crow (and the Manager) to be running.

Backed by `AppConfig.autoCreateWatcherEnabled`. Issues in `excludeTicketRepos` are filtered before the toggle is consulted, so they remain ignored regardless of the setting.

### Auto-merge

PR #299 added a single toggle that lets Crow enable GitHub's native auto-merge on Crow-authored PRs carrying the `crow:merge` label. Off by default.

- **Enable `crow:merge` auto-merge for Crow-authored PRs** — when on, Crow watches each session's linked PR. If it sees the `crow:merge` label, the commits include a `Crow-Session: <uuid>` trailer matching a known Crow session, and the PR is not in `CONFLICTING`/`CHANGES_REQUESTED`/draft state, Crow runs `gh pr merge --auto --squash --delete-branch`. GitHub holds the merge server-side until required reviews and checks pass; Crow only enables it once per PR (idempotent via `Session.autoMergeEnabledAt`).

Backed by `AppConfig.autoMergeWatcherEnabled`. Hand-written PRs without the Crow trailer are ignored even when labeled. Crow lazily creates the `crow:merge` label in the repo on first observation so repo owners don't need to pre-seed it.

## Per-PR feature notes

Short descriptions of each shipped automation, in roughly the order they fire during the lifecycle.

### #211 — Auto-create workspace on `crow:auto` label

When an issue assigned to you carries the `crow:auto` label *and* the **Auto-launch workspaces** toggle is on (PR #312, off by default), the issue tracker auto-creates a workspace for it on the next polling cycle (every 60s). It picks the right repo, opens a worktree, captures ticket metadata, and launches Claude Code in plan mode with the issue context. Issues in `excludeTicketRepos` are skipped. While the toggle is off the label is left in place, so flipping it on later still picks up previously-labeled issues.

### #189 — Manager auto permission mode

The Manager terminal launches in `--permission-mode auto` by default so orchestration commands run without prompts. Toggle is at **Settings → Automation → Manager Terminal**. See above for plan / model requirements.

### #182 — Positive-evidence auto-complete

Auto-complete (PR merged / issue closed) no longer fires solely on the GitHub signal. The session must also show positive evidence that work was attempted — at minimum a started Claude Code terminal with non-empty activity. This prevents idle sessions from being marked completed when an unrelated PR lands.

### #213 — Auto-suggest opening a PR

When a session completes its work locally but no PR is linked, Crow surfaces a "Open PR" suggestion on the session detail surface. Clicking it walks Claude Code through `gh pr create` against the session's branch.

### #209 — Auto-start review sessions for opted-in repos

A per-workspace setting (Workspaces → edit workspace → Auto-review). When on, any reviewable PR in that workspace's repos triggers a review session in the background — Crow clones into `{devRoot}/crow-reviews/`, launches Claude Code with the review prompt, and surfaces it on the review board when ready.

### #214 — Auto-respond to PR status changes

See the **Auto-respond** toggles in the Settings tab section above. Crow watches the PR for review-changed and check-failed transitions on the standard 60-second polling cycle.

### #299 — Auto-merge on `crow:merge` label

When a PR linked to an active Crow session carries the `crow:merge` label, the IssueTracker enables GitHub native auto-merge on the next poll. Eligibility is conjunctive: the label must be present, at least one commit on the PR must carry a `Crow-Session: <uuid>` trailer whose UUID matches a session this Crow instance knows about, and the PR must not be a draft / conflicting / changes-requested. The merge method is hard-defaulted to **squash with branch delete** to match the existing `/merge-pr` quick action.

Crow does not babysit the merge — GitHub queues it server-side and fires once required checks settle. Enablement is one-shot per PR: `Session.autoMergeEnabledAt` is persisted on success, and an in-memory dedupe set protects the gap between dispatch and persistence. Trailer-with-unknown-session is treated as not-Crow-authored (defensive: someone copy-pasting our trailer convention into a hand-written commit should not be able to trigger auto-merge).

Audit trail: each enable writes `[Crow] Auto-merge enabled on <pr-url> (session <uuid>, squash)` to the system log and posts a banner notification.

### #137 — Session analytics via OpenTelemetry

Claude Code's OpenTelemetry exporter is wired up so each session emits standard OTLP metrics for token counts, tool-call latency, and turn duration. Configuration follows Claude Code's own env vars (e.g. `CLAUDE_CODE_ENABLE_TELEMETRY`, `OTEL_EXPORTER_OTLP_ENDPOINT`); Crow does not collect telemetry itself.

## Where it lives

| Concern                          | File                                                                                              |
| -------------------------------- | ------------------------------------------------------------------------------------------------- |
| Settings tab UI                  | `Packages/CrowUI/Sources/CrowUI/AutomationSettingsView.swift`                                     |
| Persisted toggles                | `Packages/CrowCore/Sources/CrowCore/Models/AppConfig.swift` (`ConfigDefaults`, `AutoRespondSettings`) |
| Manager auto-permission decision | `Sources/Crow/App/AppDelegate.swift` (Manager command rebuild)                                    |
| Auto-create / auto-respond loop  | `Sources/Crow/App/IssueTracker.swift` (60s polling cycle)                                         |
| Review session auto-start        | `Sources/Crow/App/IssueTracker.swift` + per-workspace flag in `AppConfig`                         |
| Auto-merge watcher (`crow:merge`)| `Sources/Crow/App/IssueTracker.swift` (`applyAutoMerge`, `extractCrowSessionUUIDs`, `crowAuthored`) |

## See also

- [Configuration](configuration.md) — full schema for `{devRoot}/.claude/config.json`, including `excludeReviewRepos`, `excludeTicketRepos`, `remoteControlEnabled`, and `managerAutoPermissionMode`.
- [Getting Started](getting-started.md) — first-launch setup that creates the config file these toggles write to.
- [Troubleshooting](troubleshooting.md) — what to do when an automation does not fire as expected.
