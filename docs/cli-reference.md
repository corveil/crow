# `crow` CLI Reference

The `crow` CLI communicates over a Unix socket at `~/.local/share/crow/crow.sock` (override with `CROW_SOCKET`). A server must be listening on it for RPC commands to succeed — the `crowd` daemon owns this socket. `crow setup` and `crow autostart` are the only subcommands that work with nothing listening.

All commands print JSON to stdout on success. Session and terminal identifiers are full UUIDs (e.g. `a1b2c3d4-e5f6-7890-abcd-ef1234567890`) — short names are not accepted.

Every subcommand source lives in `Packages/CrowCLI/Sources/CrowCLILib/Commands/`.

This page is the guide: what each verb is for, what it returns, and where it bites. For the exhaustive machine-generated surface — every subcommand and every flag, straight from the commands themselves — see [`cli.md`](cli.md). A test fails the build if a verb documented there is missing here (CROW-808).

---

## Setup

### `crow setup`

First-time setup wizard. Checks for runtime dependencies (`git`, `gh`, `claude`), prompts for a development root and workspaces, then writes `~/Library/Application Support/crow/devroot` and scaffolds `{devRoot}/.claude/`.

```bash
crow setup
crow setup --dev-root ~/Dev
```

| Flag         | Required | Description                                 |
| ------------ | -------- | ------------------------------------------- |
| `--dev-root` | no       | Skip the interactive dev-root prompt        |

This is one of two subcommands that do not require a running daemon (see `crow autostart`).

---

## Autostart

### `crow autostart install | uninstall | status`

Registers `crowd` to start at login — a launchd LaunchAgent at `~/Library/LaunchAgents/com.corveil.crowd.plist`, logging to `~/Library/Logs/crow/crowd.log`. Runs locally instead of over the socket, so it works with the daemon down (which is the point). macOS only for now; on other platforms it reports `supported: false` rather than pretending to register anything. The same control lives at Settings → General → Autostart for a local browser.

```bash
crow autostart install
crow autostart install --host 0.0.0.0 --port 8080 --dev-root ~/Dev
crow autostart status --json
crow autostart uninstall
```

Bare `crow autostart` is `status`. `install` is idempotent and re-points the login item at the current `crowd` on every run, so an upgrade never leaves a stale plist. When a `crowd` is already running, `install` writes the login item and leaves launchd alone — it takes effect at next login rather than spawning a duplicate the single-instance guard would refuse.

| Flag         | Applies to        | Description                                                              |
| ------------ | ----------------- | ------------------------------------------------------------------------ |
| `--binary`   | install, status   | Path to `crowd` (default: next to this `crow`, then `PATH`)              |
| `--host`     | install           | Bind host passed to `crowd`                                              |
| `--port`     | install           | HTTP port passed to `crowd`                                              |
| `--dev-root` | install           | Development root passed to `crowd`                                       |
| `--socket`   | install           | Unix socket path passed to `crowd`                                       |
| `--json`     | all               | Print the status object instead of the human summary                     |

The status object reports `enabled` (registered at login), `running` (a `crowd` is answering right now), `loaded` (launchd knows it in this session), and `stale` (the registration points at a different binary than `--binary` / the resolved one).

---

## Session Commands

### `crow new-session`

Create a new session.

```bash
crow new-session --name "feature-name"
```

| Flag     | Required | Description   |
| -------- | -------- | ------------- |
| `--name` | yes      | Session name  |

Returns `{"session_id": "<uuid>", "name": "..."}`.

### `crow rename-session`

```bash
crow rename-session --session <uuid> "new-name"
```

| Arg / Flag  | Required | Description     |
| ----------- | -------- | --------------- |
| `--session` | yes      | Session UUID    |
| *(positional)* `NAME` | yes | New name |

### `crow select-session`

Make the given session the active session in the web UI.

```bash
crow select-session --session <uuid>
```

### `crow list-sessions`

Print all sessions.

```bash
crow list-sessions
```

### `crow get-session`

```bash
crow get-session --session <uuid>
```

Returns full session details: id, name, status, agent, ticket metadata, timestamps, lock state, and org-goal/alignment fields. (Worktrees, terminals and links have their own verbs — `crow list-worktrees`, `crow list-terminals`, `crow list-links`.)

It also reports which gateway the session launches with, so a rejected credential can be traced without starting a session:

| Field              | Meaning                                                                       |
| ------------------ | ----------------------------------------------------------------------------- |
| `workspace_id`     | The workspace claiming this session, or `null`                                 |
| `workspace_name`   | Its name, or `null`                                                            |
| `workspace_match`  | How it was claimed: `worktree_path`, `repo_slug`, or `manager`                 |
| `gateway_set`      | Whether that workspace has a gateway configured                                |
| `gateway_base_url` | The gateway's base URL, or `null`                                              |

These are the **redacted** subset — a set flag and the non-secret base URL, never header names or values, because `get-session` is readable by a remote `/rpc` client. Headers live in `crow gateway get`, which is local-only.

`workspace_match` distinguishes the two lookups: work and job sessions match by worktree path, while review clones (which live under `crow-reviews/`) match by the PR's `owner/repo`. Those can land on **different workspaces for the same repo**, so a work session and a review of that repo's PR may use different gateways — see [configuration.md](configuration.md#which-gateway-applies). A `null` `workspace_name` with `gateway_set: false` means nothing claimed the session at all; a non-null name with `gateway_set: false` means the workspace claimed it and has no gateway.

### `crow set-status`

```bash
crow set-status --session <uuid> active
crow set-status --session <uuid> paused
crow set-status --session <uuid> inReview
crow set-status --session <uuid> completed
crow set-status --session <uuid> archived
```

| Arg / Flag                | Required | Description                                             |
| ------------------------- | -------- | ------------------------------------------------------- |
| `--session`               | yes      | Session UUID                                            |
| *(positional)* `STATUS`   | yes      | `active`, `paused`, `inReview`, `completed`, `archived` |

### `crow set-locked`

Lock a session so the retention reaper leaves it alone. Cleanup deletes completed/archived sessions once they age past the `retention_hours` set under [Settings Commands](#settings-commands) — locking exempts a session from that, and unlocking returns it to the pool. Independent of status: a locked session still moves through `active` → `completed` normally, it just never gets swept.

```bash
crow set-locked --session <uuid> true
crow set-locked --session <uuid> false
crow set-pinned --session <uuid> true   # deprecated alias, still accepted
```

| Arg / Flag              | Required | Description                |
| ----------------------- | -------- | -------------------------- |
| `--session`             | yes      | Session UUID               |
| *(positional)* `LOCKED` | yes      | `true` or `false`          |

`crow set-pinned` is a deprecated alias kept working for existing scripts (the field was renamed in CROW-573). It is hidden from `crow --help` and takes the same arguments — prefer `set-locked`.

### Session lifecycle verbs

The session row/menu actions from the web UI, as CLI verbs. Each maps 1:1 onto the RPC method of the same name, so the CLI and the browser drive a session through its lifecycle by exactly the same path. All five take only `--session`.

Preconditions are enforced server-side, because the browser enforces them by hiding menu items and a CLI has no equivalent affordance. They are **not** gated on the session's current status, though — the UI's active/inReview/completed conditions decide which menu items to draw, not what's legal, so `crow complete-session` is safe to run twice.

| Command | Effect | Requires |
| ------- | ------ | -------- |
| `crow mark-in-review`     | Moves the linked ticket to In Review on the provider's board, then session status → `inReview` | A linked ticket + a resolvable provider |
| `crow complete-session`   | Session status → `completed` | — |
| `crow set-session-active` | Session status → `active`    | — |
| `crow mark-issue-done`    | Closes the linked issue on the provider, then completes the session | A linked ticket + a resolvable provider |
| `crow add-merge-label`    | Adds the `crow:merge` label to the session's PR (warns when the watcher can't act on it) | A linked PR + a backend supporting auto-merge labels |

The three provider-side verbs report real outcomes: an unmet precondition (no ticket, no PR, no provider, provider lacks the capability, unparseable repo slug) **and** a failed provider call both exit non-zero with the reason. They never print a success receipt for an action that didn't happen — and when an action *did* happen but can't have its intended effect, the receipt carries a `warning` rather than a bare all-clear.

```bash
crow mark-in-review --session <uuid>
crow complete-session --session <uuid>
crow set-session-active --session <uuid>
crow mark-issue-done --session <uuid>
crow add-merge-label --session <uuid>
```

| Flag        | Required | Description  |
| ----------- | -------- | ------------ |
| `--session` | yes      | Session UUID |

The three status verbs return `{"session_id": "…", "status": "…"}`; `mark-issue-done` and `add-merge-label` return `{"ok": true, "session_id": "…"}`.

`mark-in-review` transitions the board **before** it writes the session status, so a failed transition exits non-zero and leaves the session where it was — there is no half-done state to reconcile. When the provider has no In Review status to move *to*, that is not a failure: nothing was ever going to move, so the session transition still happens and the receipt carries a `warning`. That covers GitLab (no project-board status at all) and any GitHub board whose column isn't named "In Review" or "Review".

```json
{
  "session_id": "3f2a…",
  "status": "inReview",
  "warning": "Session moved to In Review, but the ticket did not: no In Review status is available for https://gitlab.com/acme/api/-/issues/7."
}
```

`add-merge-label` additionally returns a `warning` string when the label landed but auto-merge won't follow — the watcher is off, or Crow has already given up on that PR (e.g. the repo has GitHub's **Allow auto-merge** setting disabled). `ok` stays `true`, because the label really is on the PR; the key is omitted entirely when there's nothing to warn about, so `jq -e .warning` is a reliable test (#888).

```json
{
  "ok": true,
  "session_id": "3f2a…",
  "warning": "The label was added, but Crow's auto-merge watcher is off, so nothing will merge this PR. Turn it on in Settings → Automation, or run `crow automation set --auto-merge-watcher-enabled true`."
}
```

Manager sessions are rejected by all five — they stay always-active and never move through the review/complete lifecycle, matching the web UI, which never offers these actions for a Manager.

**`complete-session` and `set-session-active` write Crow's own session status.** To move the *provider's* board for those, use [`crow transition-ticket`](#crow-transition-ticket). `mark-in-review` and `mark-issue-done` move the board themselves.

### `crow handoff-agent`

Switch a session to a different coding agent mid-flight (e.g. when credits run out). Preserves session identity, worktree, branch, and ticket context. Tears down the managed agent terminal and launches the target agent with a handoff prompt. Conversation history does **not** transfer across agents — see [ADR 0009](adr/0009-agent-handoff-preserves-session-not-chat.md).

```bash
crow handoff-agent --session <uuid> --agent cursor
crow handoff-agent --session <uuid> --agent claude-code --note "Hit credit limit; continue from failing tests"
```

| Flag / Arg    | Required | Description                                              |
| ------------- | -------- | -------------------------------------------------------- |
| `--session`   | yes      | Session UUID                                             |
| `--agent`     | yes      | Target kind: `claude-code`, `cursor`, `codex`, `opencode`, `grok`, `antigravity`, `muse` |
| `--note`      | no       | Optional resume note for the incoming agent              |

Returns `{"session_id":"…","agent_kind":"…","terminal_id":"…"}`. Manager sessions are not supported — change the Manager agent in Settings and restart instead.

### `crow delete-session`

```bash
crow delete-session --session <uuid>
```

Deletes the session metadata. Sessions on protected branches (main/master/develop) preserve the repo folder and branch — see [Configuration › Safe Deletion](configuration.md#safe-deletion).

---

## Metadata Commands

### `crow set-ticket`

Attach ticket metadata (URL, title, number, priority) to a session. At least one of `--url`, `--title`, `--number`, or `--priority` must be provided.

```bash
crow set-ticket --session <uuid> --url "https://github.com/org/repo/issues/123" --title "Fix bug" --number 123
crow set-ticket --session <uuid> --priority high
```

| Flag         | Required | Description    |
| ------------ | -------- | -------------- |
| `--session`  | yes      | Session UUID   |
| `--url`      | no¹      | Ticket URL     |
| `--title`    | no¹      | Ticket title   |
| `--number`   | no¹      | Ticket number  |
| `--priority` | no¹      | Ticket priority: `highest`, `high`, `medium`, `low`, or `lowest` (case-insensitive). Feeds the session's alignment weight (ADR 0008 follow-up 8). |

¹ At least one of `--url`, `--title`, `--number`, `--priority` is required.

### `crow set-goal`

Set or clear the org-goal tag on a session — the org goal/KPI the session's work ladders up to (ADR 0008 follow-up 8). The tag feeds the session's alignment weight, read back via `crow get-session` (`org_goal`, `ticket_priority`, `alignment_weight`). Exactly one of `--goal` or `--clear` is required.

```bash
crow set-goal --session <uuid> --goal "Q3 latency KPI"
crow set-goal --session <uuid> --clear
```

| Flag        | Required | Description                                  |
| ----------- | -------- | -------------------------------------------- |
| `--session` | yes      | Session UUID                                 |
| `--goal`    | no²      | Org goal/KPI tag (free text, non-blank)      |
| `--clear`   | no²      | Clear the tag (back to neutral weight)       |

² Exactly one of `--goal`, `--clear` is required.

### `crow add-link`

Add a link (issue, PR, repo, or custom) to a session.

```bash
crow add-link --session <uuid> --label "Issue #123" --url "https://..." --type ticket
```

| Flag        | Required | Description                                        |
| ----------- | -------- | -------------------------------------------------- |
| `--session` | yes      | Session UUID                                       |
| `--label`   | yes      | Display label                                      |
| `--url`     | yes      | Target URL                                         |
| `--type`    | no       | `ticket`, `pr`, `repo`, or `custom` (default: `custom`) |

### `crow list-links`

```bash
crow list-links --session <uuid>
```

Returns each link's `id`, `label`, `url`, and `type` — the `id` is what `edit-link` / `remove-link` take.

### `crow remove-link`

Detach a link from a session, identified by its link ID (from `list-links`) or its URL.

```bash
crow remove-link --session <uuid> --id <link-uuid>
crow remove-link --session <uuid> --url "https://..."
```

| Flag        | Required | Description                                  |
| ----------- | -------- | -------------------------------------------- |
| `--session` | yes      | Session UUID                                 |
| `--id`      | one of   | Link UUID (from `list-links`)                |
| `--url`     | one of   | Link URL (alternative to `--id`)             |

Provide at least one of `--id` / `--url`. Returns `{"removed": N}`.

### `crow edit-link`

Update a link's label, URL, or type in place. The link is selected by `--id` or its current `--url`; only the fields you pass change. Because `--url` selects the link, the *new* URL is set via `--new-url`.

```bash
crow edit-link --session <uuid> --id <link-uuid> --label "PR #42" --type pr
crow edit-link --session <uuid> --url "https://old..." --new-url "https://new..."
```

| Flag        | Required | Description                                        |
| ----------- | -------- | -------------------------------------------------- |
| `--session` | yes      | Session UUID                                        |
| `--id`      | one of   | Link UUID to edit (from `list-links`)              |
| `--url`     | one of   | Current link URL to match (alternative to `--id`)  |
| `--label`   | no       | New display label                                  |
| `--new-url` | no       | New target URL                                     |
| `--type`    | no       | New type: `ticket`, `pr`, `repo`, or `custom`      |

Provide at least one selector (`--id` / `--url`) and at least one field to change (`--label` / `--new-url` / `--type`). Returns `{"updated": N}`.

### `crow transition-ticket`

Move the session's linked ticket to a pipeline status on the *provider's* board, without touching Crow's own session status. Use it to move a board independently of the [session lifecycle verbs](#session-lifecycle-verbs) — for the In Progress transition at session start (what `setup.sh` calls), or to correct a board out of band. Unlike `mark-in-review`, it is best-effort: failures are logged, not reported.

```bash
crow transition-ticket --session <uuid> --to inProgress
crow transition-ticket --session <uuid> --to inReview
crow transition-ticket --session <uuid> --to done
```

| Flag        | Required | Description                              |
| ----------- | -------- | ---------------------------------------- |
| `--session` | yes      | Session UUID                             |
| `--to`      | yes      | `inProgress`, `inReview`, or `done` (matched case-insensitively) |

Jira maps the pipeline status onto a real workflow transition through `jiraStatusMap` (see [Configuration](configuration.md)). Requires a linked ticket and a provider that supports transitions.

### `crow resync-jira`

Re-sync every Jira-backed session's ticket to the status implied by its Crow session state — one-shot remediation for tickets left in Backlog because earlier sessions never transitioned them (CROW-529).

```bash
crow resync-jira
```

Takes no arguments and walks every session, so it is safe but not cheap. Nothing happens for sessions whose ticket is not Jira-backed.

---

## Allowlist Commands

The Claude Code permission allowlist, aggregated across the global `~/.claude/settings.json` and every registered worktree's `.claude/settings.local.json`. `crowd` owns the scan (it is pure disk I/O), so these work with the desktop app closed.

### `crow list-allowlist`

List every known pattern and where it is defined.

```bash
crow list-allowlist
```

Takes no flags. Returns:

```json
{
  "entries": [
    { "pattern": "Bash(npm test:*)", "is_global": false, "worktree_session_names": ["acme-api-197"] }
  ],
  "loading": false
}
```

`is_global` means the pattern is in `~/.claude/settings.json`; `worktree_session_names` lists the sessions whose worktree settings declare it. This reads the daemon's **last scan** rather than re-reading disk — run `crow refresh-allowlist` first if a settings file changed underneath it.

### `crow promote-allowlist`

Copy worktree-local patterns into the global `~/.claude/settings.json`, then re-scan.

```bash
crow promote-allowlist --pattern 'Bash(npm test:*)' --pattern 'Read'
```

| Flag        | Required | Description                                        |
| ----------- | -------- | -------------------------------------------------- |
| `--pattern` | yes      | Pattern to promote; repeat for more than one       |

**Quote your patterns.** `(`, `)`, and `*` are shell metacharacters — `--pattern 'Bash(npm test:*)'`, not `--pattern Bash(npm test:*)`.

Returns which patterns actually changed:

```json
{
  "ok": true,
  "added": ["Bash(npm test:*)"],
  "already_global": ["Read"],
  "global_settings_path": "/Users/you/.claude/settings.json"
}
```

Promoting an already-global pattern is a no-op, not an error — it comes back under `already_global` with an empty `added`.

A write that cannot land is an **error** (non-zero exit), never `{"ok": true}`. Two cases are refused outright rather than half-applied:

- the global settings file exists but is not valid JSON — it is left byte-for-byte untouched rather than being replaced by one containing only `permissions.allow`;
- any element of the request is not a string — the whole call is rejected instead of silently promoting the valid subset.

Promote everything not yet global:

```bash
crow list-allowlist \
  | jq -r '.entries[] | select(.is_global | not) | "--pattern", .pattern' \
  | xargs crow promote-allowlist
```

### `crow refresh-allowlist`

Re-scan the global and per-worktree settings files from disk.

```bash
crow refresh-allowlist
```

Takes no flags. Returns `{"ok": true}`.
## Settings Commands

The General-tab settings that were previously web-only. Every `set` is a patch — only the flags you pass change, and passing none is an error rather than a silent no-op. Each `set` echoes the resulting subtree plus a `restart_required` boolean, so a write is self-verifying without a follow-up `get`.

Booleans take an explicit value (`--enabled true`), not a bare flag, so that a patch can express "set to false" as distinct from "leave alone". Only the literals `true` and `false` are accepted.

Agent selection is a General-tab setting too, but has its own group — see [Agent Commands](#agent-commands).

### `crow telemetry get | set`

Session-analytics collection over Claude Code's OpenTelemetry exporter.

```bash
crow telemetry get
crow telemetry set --enabled true --port 4318
crow telemetry set --retention-days 0
```

| Flag               | Required | Description                                                |
| ------------------ | -------- | ---------------------------------------------------------- |
| `--enabled`        | no¹      | `true` or `false` — enable the OTLP receiver               |
| `--port`           | no¹      | OTLP HTTP receiver port, 1024–65535 (default 4318)         |
| `--retention-days` | no¹      | Days of telemetry to keep; `0` keeps forever (default 180) |

¹ At least one flag is required.

`--enabled` and `--port` are read once when `crowd` starts, and the port is baked into every agent launch's `OTEL_EXPORTER_OTLP_ENDPOINT`, so changing either returns `"restart_required": true` (plus a warning on stderr). Restart `crowd` to apply. `--retention-days` drives the prune that runs at startup, so it likewise takes effect at the next daemon start.

### `crow cleanup get | set`

Automatic deletion of completed and archived sessions.

```bash
crow cleanup get
crow cleanup set --enabled true --retention-hours 72
crow cleanup set --enabled false
```

| Flag                | Required | Description                                                        |
| ------------------- | -------- | ------------------------------------------------------------------ |
| `--enabled`         | no¹      | `true` or `false` — enable auto-cleanup                            |
| `--retention-hours` | no¹      | Hours to keep completed/archived sessions, minimum 1 (default 24)  |

¹ At least one flag is required.

Cleanup deletes eligible sessions **including their worktree and branch**. Manager, virtual, and locked sessions are never deleted. Unlike telemetry this setting is live: the board poll re-reads it from disk each cycle, so enabling it starts deleting within about a minute — no restart, and no confirmation prompt.

### `crow ui get | set`

Display preferences for the web UI. This does not start, stop, or open the UI.

```bash
crow ui get
crow ui set --hide-session-details true
```

| Flag                     | Required | Description                                                        |
| ------------------------ | -------- | ------------------------------------------------------------------ |
| `--hide-session-details` | yes      | `true` or `false` — hide ticket title and repo/branch sidebar lines |

Settings are grouped by the config block they belong to, so `get` returns `{"ui": {"sidebar": {...}}}` and gains further blocks as more view options become configurable. Connected browsers pick the change up within a couple of seconds — no reload.

### `crow version` / `crow version check` / `crow version get | set`

Compare the running build against `corveil/crow` `main` (CROW-938). The daemon owns the GitHub compare call and caches the result; the CLI and Settings → About read it back.

```bash
crow version
crow version --check
crow version check
crow version get
crow version set --enabled false
crow version set --interval-hours 12
```

| Flag / subcommand | Description |
| ----------------- | ----------- |
| `--check`         | Force a fresh compare and print a human summary (exit `0` up to date, `1` behind, `2` could not check) |
| `check`           | Same as `--check` |
| `get`             | JSON: `version_update` settings plus the cached `status` |
| `set --enabled`   | Opt out of periodic checks (`true` or `false`) |
| `set --interval-hours` | Hours between automatic checks (minimum 1, default 1) |

`get` returns `{"version_update":{"enabled":…,"interval_hours":…},"status":{…}}` where `status.state` is `up_to_date`, `behind`, or `unknown`. A `dev` build SHA or an unrecognized commit reports `unknown` — never a false up-to-date.

### `crow defaults get | set`

Workspace and automation defaults — the `defaults` block of `config.json`, behind Settings → Workspaces (provider, branch prefix), → Automation (the board filter lists) and → General (the corveil binary path).

```bash
crow defaults get

crow defaults set --provider gitlab --cli glab
crow defaults set --branch-prefix 'feat/'
crow defaults set --add-exclude-review-repo 'acme/legacy-*' --add-exclude-review-repo acme/docs
crow defaults set --remove-ignore-review-label wip
crow defaults set --clear-exclude-ticket-repos
crow defaults set --binary corveil=/opt/corveil/bin/corveil
crow defaults set --binary corveil=                       # remove the override
```

| Flag                             | Required | Description                                                                 |
| -------------------------------- | -------- | --------------------------------------------------------------------------- |
| `--provider`                     | no¹      | Forge for new workspaces: `github` or `gitlab`                              |
| `--cli`                          | no¹      | Forge CLI for new workspaces: `gh` or `glab`                                |
| `--branch-prefix`                | no¹      | Prefix for new session branches, e.g. `feature/`; empty means no prefix     |
| `--binary NAME=PATH`             | no¹      | Absolute binary path override, repeatable; `NAME=` removes the entry        |
| `--add-exclude-review-repo`      | no¹      | Hide a repo from the review board, repeatable; one `*` wildcard allowed     |
| `--remove-exclude-review-repo`   | no¹      | Stop hiding a repo from the review board, repeatable                        |
| `--clear-exclude-review-repos`   | no¹      | Empty the review-board repo exclusions                                      |
| `--add-exclude-ticket-repo`      | no¹      | Hide a repo from the ticket board, repeatable; one `*` wildcard allowed     |
| `--remove-exclude-ticket-repo`   | no¹      | Stop hiding a repo from the ticket board, repeatable                        |
| `--clear-exclude-ticket-repos`   | no¹      | Empty the ticket-board repo exclusions                                      |
| `--add-ignore-review-label`      | no¹      | PR label that hides a review, repeatable; exact match, no wildcards         |
| `--remove-ignore-review-label`   | no¹      | Stop ignoring a PR label, repeatable                                        |
| `--clear-ignore-review-labels`   | no¹      | Empty the ignored review labels                                             |

¹ At least one flag is required.

`get` echoes the whole block — including `exclude_dirs` and `mirror_claude_mcp_to_codex`, which `set` does not write and which have no Settings UI either. It also returns `config_readable`; when that is `false`, `config.json` exists but could not be decoded and the values shown are the built-in defaults rather than yours.

**Lists are edited incrementally**, not replaced — excluding one more repo shouldn't mean restating the list. `--add-` and `--remove-` compose in one call (remove is applied first, so naming a value in both means "ensure it's there"); `--clear-` is rejected alongside `--add-`/`--remove-` **for that same list**, but clearing one list while editing another is fine. Matching is case-insensitive, mirroring how the board filters actually compare — `--remove-exclude-review-repo ACME/Docs` removes a stored `acme/docs`. Re-adding a value that is already stored keeps the stored casing.

Note that the review board filters on the **union** of this list and every workspace's own `excludeReviewRepos`, so `--clear-exclude-review-repos` does not unhide a repo a workspace excludes. `--add-exclude-ticket-repo` and `--add-ignore-review-label` have no workspace-level counterpart.

Most of these are live: `--provider`/`--cli` are re-read on each repo scan, the three lists on each board poll (about a minute), and `--branch-prefix` when a workspace is created. **`--binary` is the exception** — agent binary discovery and the `{devRoot}/.claude/bin` symlinks are both set up at startup, so a change returns `"restart_required": true` and needs a `crowd` restart. That includes *removing* one: nothing re-scaffolds on a config change, so the stale symlink keeps shadowing `PATH` until the next launch. `crow` is rejected as a binary name — Crow re-points that symlink at its own CLI every launch, so an override there could never take effect.

A path that isn't executable right now is **saved with a warning**, not rejected (`binaries_not_executable` in the response) — pointing at a tool you haven't installed yet is a legitimate flow, and the symlink is simply skipped until the target appears. `--provider` and `--cli` are stored independently and neither implies the other, matching how repo scanning reads them; setting only one warns via `provider_cli_mismatch` if the resulting pair is crossed.

`crow defaults set --binary` is **local-only** — binary overrides are absolute paths that execute at the next agent launch, so the remote `/rpc` path refuses any `defaults-set` carrying them. Every other flag, and `defaults get`, work remotely.

> **Concurrent edits.** An open web Settings modal snapshots the whole config when you open it and re-sends all of it on Save, so saving a stale modal reverts a CLI write made in the meantime. This applies equally to `crow notifications set`, `crow ui set` and `crow job add`; close or reopen Settings after a CLI change.

---

## Job Commands

Scheduled jobs (CROW-604) are timed prompt-sets scoped to one repo in one workspace — the Jobs sidebar feature, as CLI verbs. When a job fires, Crow creates a session, clones the repo if needed, launches the configured agent, and sends the job's prompts in order.

Every subcommand goes through the running app's RPC socket, so mutations land on the live in-memory config: the scheduler and the web Settings UI pick them up immediately, with no restart. Jobs are addressed by UUID (`--id`), which `crow job list` prints.

### `crow job list`

```bash
crow job list
```

Returns `{"jobs": [...]}` — every job with its schedule, prompts, and `enabled` flag.

### `crow job get`

```bash
crow job get --id <job-uuid>
```

| Flag   | Required | Description |
| ------ | -------- | ----------- |
| `--id` | yes      | Job UUID    |

### `crow job add`

Create a job. Prompts are sent in the order given: every `--prompt` first, then the contents of every `--prompt-file`.

Exactly one schedule is required — either `--interval-seconds` or `--daily-at HH:MM`, the latter optionally narrowed with `--weekdays`.

```bash
crow job add --name "nightly-audit" --workspace Corveil --repo corveil/crow \
  --prompt "Run the test suite and summarise failures" --daily-at 02:00

crow job add --name "hourly-triage" --workspace Corveil --repo corveil/crow \
  --prompt-file ./prompts/triage.md --interval-seconds 3600 --disabled
```

| Flag                 | Required | Description                                                            |
| -------------------- | -------- | ---------------------------------------------------------------------- |
| `--name`             | yes      | Job name; must be unique                                               |
| `--workspace`        | yes      | Workspace name (a folder under the dev root)                           |
| `--repo`             | yes      | Repository slug, `owner/repo`                                          |
| `--prompt`           | one of   | Prompt text; repeatable, sent in order                                  |
| `--prompt-file`      | one of   | Read a prompt from a file; repeatable. `-` reads stdin (at most once)  |
| `--interval-seconds` | one of   | Run every N seconds                                                    |
| `--daily-at`         | one of   | Run daily at `HH:MM`, 24-hour local time                               |
| `--weekdays`         | no       | Comma-separated days for `--daily-at` (`sun,mon,…` or `1-7`); omit for every day |
| `--disabled`         | no       | Create the job disabled                                                |

Returns `{"job": {...}}`.

### `crow job edit`

Update fields on an existing job. Only the flags you pass change — with two sharp edges:

- Any `--prompt` / `--prompt-file` replaces the **whole** prompt list, not appends to it.
- Any schedule flag replaces the **whole** schedule, so changing `--weekdays` means restating `--daily-at` alongside it.

```bash
crow job edit --id <job-uuid> --name "nightly-audit-v2"
crow job edit --id <job-uuid> --daily-at 03:30 --weekdays mon,tue,wed,thu,fri
```

| Flag                 | Required | Description                                       |
| -------------------- | -------- | ------------------------------------------------- |
| `--id`               | yes      | Job UUID                                          |
| `--name`             | no       | New name; must still be unique                    |
| `--workspace`        | no       | New workspace name                                |
| `--repo`             | no       | New repository slug                               |
| `--prompt`           | no       | Replacement prompt text (repeatable)              |
| `--prompt-file`      | no       | Replacement prompt read from a file (repeatable)  |
| `--interval-seconds` | no       | Replacement interval schedule                     |
| `--daily-at`         | no       | Replacement daily schedule                        |
| `--weekdays`         | no       | Weekday filter for `--daily-at`                   |

At least one field flag is required. Use `enable` / `disable` rather than `edit` to toggle the enabled flag.

### `crow job enable | disable`

```bash
crow job enable --id <job-uuid>
crow job disable --id <job-uuid>
```

| Flag   | Required | Description |
| ------ | -------- | ----------- |
| `--id` | yes      | Job UUID    |

### `crow job run`

Run a job right now, whatever its schedule says and even if it is disabled.

```bash
crow job run --id <job-uuid>
```

Returns `{"job_id": "…", "session_id": "…", "terminal_id": "…"}`. Needs tmux on the daemon host. The CLI waits up to 120s because a first run may clone the repo — and the run continues inside the app even if the CLI gives up waiting.

### `crow job delete`

```bash
crow job delete --id <job-uuid>
```

Returns `{"deleted": true, "job_id": "…"}`.

### `crow job duplicate`

Copy a job. The copy is created **disabled**, with a uniquified name, so it can be edited before it fires.

```bash
crow job duplicate --id <job-uuid>
```
---

## Agent Commands

Which coding harness Crow launches — `AppConfig.defaultAgentKind` plus the per-role overrides in `AppConfig.agentsByKind`, the same fields the web Settings → General "Agent" pickers edit. Resolution is `agentsByKind[<role>]` falling back to `defaultAgentKind`.

The four roles are `work` (coding sessions), `review` (PR reviews), `job` (scheduled jobs), and `manager` (the Manager session).

Writes land under the shared config lock and take effect within about one board poll — no restart, and an open browser tab repaints within a couple of seconds. There is no `restart_required` in the response for that reason.

### `crow agents list`

Show what this daemon can launch, what you configured, and what each role resolves to.

```bash
crow agents list
crow agents list | jq -r '.agents.effective'
```

Takes no flags.

```json
{
  "agents": {
    "known": [
      { "kind": "claude-code", "name": "Claude Code", "binary": "claude", "available": true },
      { "kind": "codex", "name": "OpenAI Codex", "binary": "codex", "available": true },
      { "kind": "antigravity", "name": "Antigravity", "binary": "agy", "available": false }
    ],
    "default_agent_kind": "claude-code",
    "by_kind": { "review": "codex" },
    "effective": {
      "work": "claude-code",
      "review": "codex",
      "job": "claude-code",
      "manager": "claude-code"
    },
    "config_readable": true
  }
}
```

### `crow agents set`

Change the default agent or a per-role override. Only the flags you pass change; at least one is required.

```bash
crow agents set --default codex
crow agents set --work codex --review cursor
crow agents set --clear review --clear job
```

| Flag              | Required | Description                                                        |
| ----------------- | -------- | ------------------------------------------------------------------ |
| `--default`       | no       | Agent for sessions with no per-role override                       |
| `--work`          | no       | Agent for new coding sessions                                      |
| `--review`        | no       | Agent for PR-review sessions                                       |
| `--job`           | no       | Agent for scheduled-job sessions                                   |
| `--manager`       | no       | Agent for the Manager session                                      |
| `--clear <role>`  | no       | Remove that role's override; repeatable (`work\|review\|job\|manager`) |

Returns the same `agents` subtree as `list`, plus `"saved": true`.

Notes:

- **`known` lists every agent Crow ships, installed or not**, each with an `available` flag — the same surface-but-disable roster the web pickers show ([#879](https://github.com/corveil/crow/issues/879)), so an off-PATH harness reads as "not installed" rather than vanishing from the list. `binary` is the `PATH` token to install (never the resolved absolute path, which would leak the daemon host's layout).
- **`available` is decided when `crowd` starts** and is binary-dependent — Codex, Cursor, OpenCode and Antigravity register only if their CLI was on `PATH` at boot. Installing an agent therefore needs a daemon restart before it can be selected.
- **Only `available: true` kinds are selectable; anything else is rejected and nothing is written** — no lock taken, no `config.json` rewrite. This is stricter than `crow new-session --agent`, which falls back to the default instead; here the configured value is trusted at launch time, so a typo would persist sessions that never start. A kind that's listed but uninstalled gets its own message naming the binary, rather than an "expected one of" list that would be confusing when the agent is right there in `crow agents list`.
- **A role also rejects an agent that can't run that kind of session.** **No agent is review-incapable today** — review-on-Antigravity was the last such case and its review dispatch landed in #902, so the gate refuses nothing right now. It is kept in lockstep with `crow handoff-agent` (which throws on the same predicate) so a future review-incapable harness is refused on both surfaces at once, rather than being configured into "created but never launches". The gate applies to the role flags only, not `--default`: validating the *resolved* outcome would make a pre-existing default fail every later write, including patches to unrelated roles. A default that resolves review to a review-incapable agent surfaces at launch time instead, where Crow writes an explanatory line into the terminal.
- **`--clear <role>` removes the override key**; it does not write a null. (`agentsByKind` is a `[String: AgentKind]` map that cannot decode a JSON null — a single one would make the whole `config.json` undecodable.) Passing `--clear X` together with `--X <kind>` is rejected rather than resolved by precedence.
- Patch semantics: a role you don't mention keeps its stored value.
- `config_readable: false` means `config.json` exists but would not decode. The values shown are then defaults, not your settings.
- `effective` reports what a new session of each role *would* get. If it names a kind that isn't available — an agent whose binary left `PATH`, say — the CLI warns on stderr: that role's sessions will not launch.
- `by_kind` echoes the stored map verbatim, including a hand-edited key that isn't a real role. Such a key shows up in `by_kind` and is absent from `effective`; that difference is the tell.
- Not to be confused with the older web-facing `list-agents` RPC, whose per-agent `default` flag means the *registry* default (whichever agent registered first). `default_agent_kind` here is the *configured* default; a `known` row deliberately carries no `default` field.

---

## Corveil CLI Commands

Settings → General → Corveil CLI's two buttons, as verbs (CROW-1011). Both act on `defaults.binaries["corveil"]` — the path that section stores — and both are **local-only** on `/rpc`: they execute an absolute path on the daemon host, which is the same capability writing that field is gated for. That is no obstacle from the CLI, which reaches the daemon over its 0600 Unix socket and is local by construction.

Pass `--path` to act on a different binary. That is how you check one *before* committing it to config; omit the flag and the configured path is used.

### `crow corveil verify`

Run `corveil --version` and report what came back.

```bash
crow corveil verify
crow corveil verify --path /opt/homebrew/bin/corveil
```

```json
{"ok": true, "message": "corveil 1.4.0", "path": "/opt/homebrew/bin/corveil"}
```

- **Branch on `ok`, not on the exit code.** A corveil that is missing, not executable, exits non-zero, or hangs past 5s is a successful *report* of a broken binary — `ok` is `false` and `message` carries the diagnostic. A non-zero exit from `crow` itself means the request never ran (no daemon, no path configured anywhere).
- `message` is one line. A chatty `--version` banner is truncated to its first, and a binary that writes its version to stderr is still read.
- The 5s ceiling matches the launch-time `corveil skill install` budget, so a wedged binary reports the same way from either.

### `crow corveil reinstall-skill`

Reinstall **every** embedded slash command from the corveil binary — the same `corveil skill install` the daemon runs at launch, without restarting it. The set is enumerated from the binary (`corveil skill list`), so a corveil that ships a new embedded skill gets it installed without a Crow change.

```bash
crow corveil reinstall-skill
crow corveil reinstall-skill --path ~/src/corveil/bin/corveil
```

```json
{
  "ok": true,
  "message": "Skills reinstalled",
  "path": "/opt/homebrew/bin/corveil",
  "skill_path": "/Users/you/Dev/.claude/commands"
}
```

- Each skill lands as `{devRoot}/.claude/commands/<name>.md`; `skill_path` names that directory. The install is idempotent, so running it repeatedly is safe.
- The loop this serves is "I just rebuilt corveil locally; install its new embedded skills." Each skill installs independently — one that fails doesn't abort the rest, and `message` names the ones that didn't install (`ok` is then `false`).
- A run also updates the launch-time corveil warning: succeeding clears it, a per-skill failure replaces it. There is one answer to "is corveil broken?", not a startup one and a button one.

---

## Automation Commands

Settings → Automation: which sessions launch in auto permission mode, whether Crow watches for `crow:auto` / `crow:merge` labels, and whether it responds to changes-requested reviews and failed checks on your behalf.

The tab also renders three board-filter lists (excluded review repos, ignored review labels, excluded ticket repos). Those are `AppConfig.defaults` fields and are written by [`crow defaults set`](#crow-defaults-get--set) — one writer, one set of list semantics. `crow automation get` echoes them read-only so the tab still reads as a whole from one call.

Same patch contract as the settings verbs above — only the flags you pass change, and passing none is an error rather than a silent no-op. Booleans take an explicit `true`/`false`, which matters more here than anywhere else: **six of these twelve toggles default to on**, so a bare-flag design could never turn one off.

### `crow automation get | set`

```bash
crow automation get

crow automation set --auto-merge-watcher-enabled true
crow automation set --respond-to-failed-checks true --auto-rebase-and-resolve-conflicts true
crow automation set --manager-auto-permission-mode false && crow restart-manager
```

**Permission modes** — each passes `--permission-mode auto` to the agent at launch. `--jobs-auto-permission-mode` is here rather than under `crow job` so all five read and write as one group, even though the web UI renders it on the Jobs tab.

| Flag                                 | Default | Description                                                          |
| ------------------------------------ | ------- | -------------------------------------------------------------------- |
| `--remote-control-enabled`           | `false` | Launch new Claude Code sessions with `--rc` (drivable from claude.ai) |
| `--manager-auto-permission-mode`     | `true`  | Manager terminal runs `crow`/`gh`/`git` without per-call approval     |
| `--review-auto-permission-mode`      | `true`  | Code-review sessions run their review flow unattended                 |
| `--coder-view-auto-permission-mode`  | `false` | New work coder views start in auto-accept instead of plan mode        |
| `--jobs-auto-permission-mode`        | `true`  | Scheduled jobs run unattended                                         |

**Attribution & watchers**

| Flag                            | Default | Description                                                              |
| ------------------------------- | ------- | ------------------------------------------------------------------------ |
| `--attribution-trailers`        | `true`  | Write a per-worktree hook adding a `Crow-Session: <uuid>` commit trailer  |
| `--auto-create-watcher-enabled` | `false` | Auto-launch a workspace for issues assigned to you labeled `crow:auto`    |
| `--auto-merge-watcher-enabled`  | `false` | Auto-merge Crow-authored PRs labeled `crow:merge`                         |

**Auto-respond** — Crow acts on a PR's behalf without you asking: three of these type an instruction into the session's agent terminal, one calls the host API directly.

| Flag                                   | Default | Description                                                       |
| -------------------------------------- | ------- | ----------------------------------------------------------------- |
| `--respond-to-changes-requested`       | `true`  | Respond to a changes-requested review                             |
| `--respond-to-failed-checks`           | `false` | Respond to failed CI checks                                       |
| `--auto-rebase-and-resolve-conflicts`  | `false` | Rebase onto the base branch and `--force-with-lease` push          |
| `--auto-re-request-review`             | `true`  | Re-request review once a changes-requested PR's fix has landed     |

At least one flag from any group is required.

Returns:

```json
{
  "automation": {
    "remote_control_enabled": false,
    "manager_auto_permission_mode": true,
    "review_auto_permission_mode": true,
    "coder_view_auto_permission_mode": false,
    "jobs_auto_permission_mode": true,
    "attribution_trailers": true,
    "auto_create_watcher_enabled": false,
    "auto_merge_watcher_enabled": true,
    "auto_respond": {
      "respond_to_changes_requested": true,
      "respond_to_failed_checks": false,
      "auto_rebase_and_resolve_conflicts": false,
      "auto_re_request_review": true
    },
    "defaults": {
      "exclude_review_repos": ["corveil/*"],
      "ignore_review_labels": [],
      "exclude_ticket_repos": [],
      "effective_exclude_review_repos": ["corveil/*", "acme/legacy"]
    },
    "config_readable": true
  },
  "restart_required": false,
  "manager_restart_required": false
}
```

Notes:

- **Nothing here needs a `crowd` restart.** The daemon re-reads `config.json` rather than holding a snapshot, so `restart_required` is always `false` and every change is live within about one board poll (~60s). The permission modes and `--remote-control-enabled` apply to **newly launched** sessions and `--attribution-trailers` to **newly created** worktrees; running sessions and existing worktrees are untouched.
- **`--manager-auto-permission-mode` is the one exception.** It is baked into the Manager terminal's stored shell command, so it only takes effect on a Manager rebuild. Changing it returns `"manager_restart_required": true` (plus a warning on stderr) — run [`crow restart-manager`](#crow-restart-manager) to apply it.
- **The whole `defaults` block in the response is read-only here.** Write those three lists with [`crow defaults set`](#crow-defaults-get--set); `automation-set` ignores `add_*` / `remove_*` / `clear_*` params even if a hand-rolled RPC call sends them.
- **`defaults.effective_exclude_review_repos` is additionally derived** — the global exclude list unioned with every workspace's own `excludeReviewRepos`, which is what the review board actually filters on. It is the only way to see the per-workspace half from the CLI, and explains why `crow defaults set --clear-exclude-review-repos` may not unhide a repo.
- **`config_readable: false`** means `config.json` exists but could not be decoded: the values shown are defaults, not what is on disk. A `set` against such a file is refused rather than overwriting it.

---

## Worktree Commands

### `crow add-worktree`

Register a git worktree for a session. The app uses `--repo-path` to run git commands against the main repo when needed.

```bash
crow add-worktree \
  --session <uuid> \
  --repo "acme-api" \
  --repo-path "/Users/you/Dev/Corveil/acme-api" \
  --path "/Users/you/Dev/Corveil/acme-api-123-feature" \
  --branch "feature/acme-api-123" \
  --primary
```

| Flag          | Required | Description                                                                |
| ------------- | -------- | -------------------------------------------------------------------------- |
| `--session`   | yes      | Session UUID                                                               |
| `--repo`      | yes      | Repo name                                                                  |
| `--path`      | yes      | Worktree path                                                              |
| `--branch`    | yes      | Branch name                                                                |
| `--repo-path` | no       | Main repo path (used when shelling out to git against the primary repo)    |
| `--primary`   | no       | Flag — mark this as the primary worktree for the session                   |

> Note: `add-worktree` does **not** support a `--workspace` flag. Workspace association is derived from `--repo-path`.

### `crow list-worktrees`

```bash
crow list-worktrees --session <uuid>
```

---

## Terminal Commands

### `crow new-terminal`

Create a new terminal tab inside a session. Use `--managed` for the primary Claude Code terminal that Crow auto-starts and tracks readiness for.

```bash
crow new-terminal --session <uuid> --cwd "/path/to/worktree" --name "Claude Code" --command "claude" --managed
```

| Flag        | Required | Description                                                              |
| ----------- | -------- | ------------------------------------------------------------------------ |
| `--session` | yes      | Session UUID                                                             |
| `--cwd`     | yes      | Working directory                                                        |
| `--name`    | no       | Terminal display name                                                    |
| `--command` | no       | Command to run once the shell is ready                                   |
| `--managed` | no       | Flag — mark as a managed Claude Code terminal (readiness tracking, auto-launch) |

### `crow list-terminals`

```bash
crow list-terminals --session <uuid>
```

### `crow close-terminal`

Close a terminal tab in a session.

```bash
crow close-terminal --session <uuid> --terminal <uuid>
```

### `crow recreate-terminal`

Rebuild a terminal whose tmux window has degraded scrollback (CROW-804). Kills the stale window, creates a fresh correctly-configured one at the same worktree, and relaunches the session's agent with `--continue` so the conversation carries over.

```bash
crow recreate-terminal --session <uuid> --terminal <uuid>
```

| Flag         | Required | Description   |
| ------------ | -------- | ------------- |
| `--session`  | yes      | Session UUID  |
| `--terminal` | yes      | Terminal UUID |

**Destructive to whatever is running in that pane** — anything mid-flight dies with the window. The web UI asks for confirmation first; from the CLI that judgement is yours.

### `crow rename-terminal`

Rename a terminal tab. The new name is positional.

```bash
crow rename-terminal --session <uuid> --terminal <uuid> "Build watcher"
```

| Arg / Flag              | Required | Description       |
| ----------------------- | -------- | ----------------- |
| `--session`             | yes      | Session UUID      |
| `--terminal`            | yes      | Terminal UUID     |
| *(positional)* `NAME`   | yes      | New terminal name |

Returns `{"session_id": "...", "terminal_id": "...", "name": "..."}`.

### `crow send`

Write text to a terminal. Newlines in `TEXT` are converted to Enter keypresses; include a trailing newline to submit a command.

```bash
crow send --session <uuid> --terminal <uuid> "claude --continue"$'\n'
```

| Arg / Flag              | Required | Description       |
| ----------------------- | -------- | ----------------- |
| `--session`             | yes      | Session UUID      |
| `--terminal`            | yes      | Terminal UUID     |
| *(positional)* `TEXT`   | yes      | Text to send      |

---

## Maintenance Commands

CLI parity for the maintenance actions that used to be web-only — Settings → About's
maintenance group and the session-header host-app buttons. Each verb maps 1:1 to the RPC
method of the same name.

All of these need tmux on the daemon host. Without it the daemon answers
`… requires tmux on the daemon host`.

### `crow restart-manager`

Relaunch the Manager's agent process in place after it has exited (crash, kill, OOM). The
Manager session row and its UUID survive; only the dead terminal surface is replaced, so the
new terminal gets a fresh UUID.

```bash
crow restart-manager
```

Only the **primary** Manager session (`00000000-0000-0000-0000-000000000000`) is restarted —
secondary Manager sessions are untouched.

Returns `{"ok": true}`.

### `crow restart-tmux-server`

Restart the shared tmux server. **Destructive:** this kills every pane — every agent in every
session dies — then relaunches each persisted terminal (the Manager via its stored command,
work sessions via `claude --continue`).

```bash
crow restart-tmux-server
```

The web UI confirms first; from the CLI the caller owns that choice, the same stance as
`recreate-terminal`. There is no `--yes` flag.

Returns `{"ok": true}` as soon as the teardown is done — **the per-terminal rebuild continues
in the background**, so don't chain a `crow send` straight after this or you'll race a
half-rebuilt surface.

### `crow reload-tmux-config`

Reload the bundled tmux config into the running server (`tmux source-file`) without restarting
it. Non-destructive: windows, sessions, and running agents are unaffected.

```bash
crow reload-tmux-config
```

Returns `{"ok": true}`, or errors with `tmux server is not running` /
`bundled crow-tmux.conf not found`.

### `crow launch-agent`

Launch the session's coding agent in a terminal whose shell is ready.

```bash
crow launch-agent --terminal <uuid>
```

| Flag         | Required | Description   |
| ------------ | -------- | ------------- |
| `--terminal` | yes      | Terminal UUID |

Note this takes **only** `--terminal` — the terminal id alone identifies the surface, so unlike
`new-terminal` / `send` / `rename-terminal` there is no `--session` flag.

Returns `{"ok": true}`. The daemon applies this only to a terminal that is shell-ready and
still pending auto-launch; in any other state it is a silent no-op, so `ok` means the request
was **accepted**, not that an agent was started.

### `crow retry-readiness`

Re-arm the tmux readiness watch for a terminal whose first attempt timed out, with a longer
budget. Clears the Retry overlay in the UI.

```bash
crow retry-readiness --terminal <uuid>
```

| Flag         | Required | Description   |
| ------------ | -------- | ------------- |
| `--terminal` | yes      | Terminal UUID |

Takes only `--terminal`, like `launch-agent`. Returns `{"ok": true}`; the daemon applies it
only to a terminal that timed out or never reached shell-ready, so `ok` again means
"accepted", not "applied".

### `crow open-in-vscode`

Open the session's primary worktree in VS Code on the daemon host.

```bash
crow open-in-vscode --session <uuid>
```

| Flag        | Required | Description  |
| ----------- | -------- | ------------ |
| `--session` | yes      | Session UUID |

Requires the `code` CLI on PATH (or a standard VS Code install) and a worktree attached to the
session. Returns `{"opened": true}`, or errors with `No worktree for session` /
`VS Code CLI not found`.

### `crow open-terminal`

Open a **macOS Terminal.app window** on the daemon host, cd'd to the session's primary
worktree.

```bash
crow open-terminal --session <uuid>
```

| Flag        | Required | Description  |
| ----------- | -------- | ------------ |
| `--session` | yes      | Session UUID |

This is **not** a Crow terminal tab — use [`crow new-terminal`](#crow-new-terminal) for that.
macOS only. Returns `{"opened": true}`, or errors with `No worktree for session`.

`open-in-vscode` and `open-terminal` launch a GUI app on the host, so the daemon restricts them
to local callers. The CLI always qualifies: it reaches the daemon over its `0600` Unix socket,
not the network `/rpc` endpoint.

---

## Inspection & Analytics

Read-only reads of the daemon's own state, plus the one idempotent rebuild verb. All local.

### `crow get-scorecard`

Print the private efficiency scorecard.

```bash
crow get-scorecard | jq '{telemetryEnabled, snapshotCount}'
```

Takes no flags. The result object **is** the scorecard — grade, weekly rollups, baseline medians, per-session rows, and Manager usage weeks — not a wrapper around one. Grading runs daemon-side so the CLI, web, and desktop can never drift apart.

With telemetry disabled the result is an empty shell; check `telemetryEnabled` and `snapshotCount` before reading grades. All timestamps are **epoch milliseconds**, not ISO 8601.

### `crow rebuild-scorecard`

Backfill analytics snapshots for sessions recorded before snapshotting existed, recompute the Manager weekly rollups, and refresh the capture-status line.

```bash
crow rebuild-scorecard
```

Takes no flags. Returns `{"rebuilt": true}`. Idempotent, and overlapping callers coalesce into a single rebuild rather than racing the same database — success is only ever reported for work that actually ran. Errors when telemetry is disabled, since there is no database to rebuild from. Uses an extended timeout; a first rebuild over a large history is not instant.

### `crow get-state`

Print the daemon's entire render-state snapshot in one call.

```bash
crow get-state | jq 'keys'
```

Takes no flags. The result object **is** the snapshot: `sessions`, `terminals`, `worktrees`, `links`, `hookStates`, `terminalReadiness`, `prStatus`, `reviewRequests`, `assignedIssues`, `allowEntries`, `remoteControlActiveTerminals`, `remoteControlEnabled`, `activeTerminalID`, and `config`. Credentials (Jira token, gateway auth headers, web-password hash and salt) are stripped before transport.

This is deliberately everything at once, and it is large — the snapshot carries every assigned issue's full body text, and the socket caps a response at 1 MB. On a busy install the command fails with a message naming the narrower reads. Prefer `crow list-sessions`, `crow get-session --session <uuid>`, `crow list-links`, or `crow list-terminals` when you want one slice.

### `crow list-artifacts`

List the images an agent dropped in a session's artifacts directory.

```bash
crow list-artifacts --session <uuid>
```

| Flag        | Required | Description  |
| ----------- | -------- | ------------ |
| `--session` | yes      | Session UUID |

Returns, newest first:

```json
{
  "dir": "/var/folders/.../crow/artifacts/<session-uuid>",
  "images": [
    {
      "name": "shot.png",
      "size": 20418,
      "mtime": "2026-07-27T10:14:02Z",
      "url": "/artifacts/<session-uuid>/shot.png",
      "path": "/var/folders/.../crow/artifacts/<session-uuid>/shot.png"
    }
  ]
}
```

`path` and `dir` are absolute on-disk locations — use these from a shell. `url` only resolves against the daemon's own web server and is there for the web UI. The directory is the one agents see as `$CROW_ARTIFACTS_DIR`; it lives under `$TMPDIR` and does not survive a reboot.
---

## Notification Commands

Read and write `AppConfig.notifications` — the same settings the web Settings → Notifications tab edits. Writes land under the shared config lock, and the daemon's config poll broadcasts a `configReloaded` event, so an open web tab refreshes within a couple of seconds.

Notifications cascade: one fires only if `globalMute` is off, the matching global category toggle is on, **and** the per-event toggle is on.

The twelve events are `taskComplete`, `agentWaiting`, `reviewRequested`, `changesRequested`, `checksFailing`, `autoWorkspaceCreated`, `autoMergeEnabled`, `autoMergeBlocked`, `autoRebasePushed`, `autoRebaseConflicts`, `autoRebaseStuck`, and `configReloaded`.

### `crow notifications get`

Show the global toggles, every event's effective settings, the built-in sound names, and whether the config was readable. Events absent from `config.json` are reported with the defaults they will actually fire with.

```bash
crow notifications get
crow notifications get --event checksFailing
```

| Flag      | Required | Description                             |
| --------- | -------- | --------------------------------------- |
| `--event` | no       | Restrict the event list to one event    |

Returns:

```json
{
  "notifications": {
    "global_mute": false,
    "sound_enabled": true,
    "system_notifications_enabled": true,
    "events": {
      "taskComplete": {
        "enabled": true,
        "sound_enabled": true,
        "system_notification_enabled": true,
        "sound_name": "Glass"
      }
    },
    "available_sounds": ["Basso", "Blow", "..."],
    "config_readable": true
  }
}
```

`--event` narrows `events` to one entry but always keeps the global toggles — `global_mute` can be the reason an event never fires. `config_readable` is `false` when `config.json` exists but could not be decoded, meaning the values shown are defaults rather than your real settings.

### `crow notifications set`

Change global toggles, one event's settings, or both. Only the provided flags change; everything else keeps its value.

```bash
crow notifications set --global-mute
crow notifications set --no-global-mute --sound-enabled
crow notifications set --event checksFailing --event-sound-name Hero --no-event-sound-enabled
```

| Flag                                       | Required | Description                                                    |
| ------------------------------------------ | -------- | -------------------------------------------------------------- |
| `--global-mute` / `--no-global-mute`       | no       | Master mute — suppresses every sound and system notification    |
| `--sound-enabled` / `--no-sound-enabled`   | no       | Global sound-playback toggle                                    |
| `--system-notifications-enabled` / `--no-…`| no       | Global system-notification toggle                               |
| `--event`                                  | no       | Event to change — required by every `--event-*` flag            |
| `--event-enabled` / `--no-event-enabled`   | no       | Whether this event notifies at all                              |
| `--event-sound-enabled` / `--no-…`         | no       | Whether this event plays a sound                                |
| `--event-system-notification-enabled` / `--no-…` | no | Whether this event posts a system notification                  |
| `--event-sound-name`                       | no       | Sound for this event — a built-in name, matched case-insensitively |

Returns the resulting settings in the same shape as `get`, plus `"saved": true`.

Notes:

- Every toggle is a `--flag` / `--no-flag` pair; **omitting** it leaves the stored value alone. `--flag --no-flag` together is rejected rather than silently resolved.
- The global toggle is `--system-notifications-enabled` (plural) and the per-event one is `--event-system-notification-enabled` (singular). The flag names mirror the config field names, which differ the same way.
- `--event-sound-name` accepts only the built-in sounds listed under `available_sounds`, matching the Settings sound picker. A config that already stores a custom sound path keeps it — reads never validate — but the CLI won't set a new one.
- Only the event you name is written to `config.json`. Events you never touch stay absent and keep following the current defaults — a globals-only `set` leaves `eventSettings` alone entirely.
- Each write seeds the entry from the event's real default before applying your flags, so `set` never has to be told a sound just to change a toggle. Hand-editing has no such help: an event entry written without `soundName` falls back to `Glass` rather than that event's default (see [configuration.md](configuration.md#notifications)).

---

## Workspace Commands

Read and write `AppConfig.workspaces` — the same list the web Settings → Workspaces tab edits. Writes land under the shared config lock, and the daemon's config poll broadcasts a `configReloaded` event, so an open web tab refreshes within a couple of seconds.

A workspace maps to a directory under the dev root and decides which forge its repos live on, where its tickets come from, and what extra context its sessions get.

`--workspace` accepts a **workspace name (case-insensitive) or a workspace UUID**. A name that matches more than one workspace is an error rather than a guess — nothing enforced name uniqueness before these verbs, so an older `config.json` can hold duplicates.

The per-workspace **AI gateway** is not managed here: it carries credentials and is local-only, so it stays with [`crow gateway`](#gateway-commands). These verbs preserve a workspace's stored gateway across every edit and report only whether one is set.

### `crow workspace list`

List every configured workspace.

```bash
crow workspace list
crow workspace list | jq '.workspaces[] | select(.task_provider == "jira") | .name'
```

Takes no flags. Returns `{"workspaces": [...], "config_readable": true}`, each entry in the shape shown under `get`. `config_readable` is `false` when `config.json` exists but could not be decoded, meaning the empty list is a fallback rather than the truth (the CLI also warns on stderr).

### `crow workspace get`

Show one workspace's full configuration.

```bash
crow workspace get --workspace Acme
crow workspace get --workspace 3f7c1a90-2b4e-4f18-9c33-5a1d0e6b8742
```

| Flag          | Required | Description                    |
| ------------- | -------- | ------------------------------ |
| `--workspace` | yes      | Workspace name or UUID         |

Returns:

```json
{
  "workspace": {
    "id": "3f7c1a90-2b4e-4f18-9c33-5a1d0e6b8742",
    "name": "Acme",
    "provider": "gitlab",
    "cli": "glab",
    "host": "gitlab.acme.io",
    "task_provider": "jira",
    "task_provider_explicit": true,
    "jira_site": "acme.atlassian.net",
    "jira_project_key": "PROPS",
    "jira_jql": "assignee = currentUser() AND statusCategory != Done",
    "jira_status_map": { "In Progress": "In Dev" },
    "corveil_host": null,
    "always_include": ["acme/api"],
    "auto_review_repos": ["acme/web"],
    "exclude_review_repos": [],
    "custom_instructions": "Always run make test before pushing.",
    "review_blocking_severities": ["red"],
    "review_blocking_severities_explicit": true,
    "session_env": { "AWS_PROFILE": "dev" },
    "gateway_set": true,
    "gateway_base_url": "https://gw.acme.io"
  }
}
```

`task_provider` is the **effective** provider, so it falls back to `provider` when none is set; `task_provider_explicit` distinguishes "follow the code provider" from a task provider that happens to equal it. Unset optionals are explicit `null`s rather than missing keys. `gateway_set` and `gateway_base_url` are all a workspace payload ever reveals about its gateway — the auth header names and values are never included. Use `crow gateway get --workspace <name> --reveal` for those.

### `crow workspace add`

Create a workspace. Only `--name` is required; every other field takes its documented default and can be set later with `edit`.

```bash
crow workspace add --name Acme
crow workspace add --name Acme --provider gitlab --host gitlab.acme.io \
  --task-provider jira --jira-site acme.atlassian.net --jira-project-key PROPS \
  --always-include acme/api --session-env AWS_PROFILE=dev
```

Takes `--name` plus every [field flag](#workspace-field-flags). Returns `{"workspace": {...}, "saved": true}`.

The name becomes a directory under the dev root, so it must be non-blank, must not contain `/` or `:`, must not be `.` or `..`, and must not collide case-insensitively with an existing workspace. Creating a workspace does not create its directory — the daemon scaffolds it at next launch.

### `crow workspace edit`

Change fields on an existing workspace. Only the provided flags change.

```bash
crow workspace edit --workspace Acme --host gitlab.acme.io
crow workspace edit --workspace Acme --always-include acme/api --always-include acme/web
crow workspace edit --workspace Acme --clear-always-include
crow workspace edit --workspace Acme --jira-status-in-progress "In Dev"
crow workspace edit --workspace Acme --name Acme2 --force
```

| Flag          | Required | Description                                                     |
| ------------- | -------- | --------------------------------------------------------------- |
| `--workspace` | yes      | Workspace name or UUID                                          |
| `--name`      | no¹      | New name — see the rename guard below                           |
| `--force`     | no       | Rename even when sessions or jobs reference this workspace      |

¹ At least one of `--name` or a field flag is required; `--force` alone is not a change.

Returns `{"workspace": {...}, "saved": <bool>}`, plus `renamed_from`, `orphaned_sessions` and `orphaned_jobs` when the name changed.

**Renaming is guarded.** Nothing stores a workspace id: a session is tied to its workspace only by its worktree living at `{devRoot}/{workspace}/{repo}`, and a job only by the `job.workspace` string. Renaming moves no directory, so it silently breaks AI-gateway resolution for those sessions, code-provider detection (which falls back to GitHub), job launches, and the `/crow-workspace` skill's config lookups — while the daemon scaffolds a *new* empty directory beside the old populated one. So a rename with live references is refused; `--force` proceeds and reports the counts.

**An idempotent edit is free.** If every value you pass already holds, the response is `"saved": false` and `config.json` is not rewritten — re-running the same command doesn't churn the file or chime "Config reloaded" in every open browser.

### `crow workspace remove`

Delete a workspace from the configuration.

```bash
crow workspace remove --workspace Acme
crow workspace remove --workspace Acme --force
```

| Flag          | Required | Description                                                     |
| ------------- | -------- | --------------------------------------------------------------- |
| `--workspace` | yes      | Workspace name or UUID                                          |
| `--force`     | no       | Remove even when sessions or jobs reference this workspace      |

Returns:

```json
{
  "removed": true,
  "id": "3f7c1a90-2b4e-4f18-9c33-5a1d0e6b8742",
  "name": "Acme",
  "worktree_dir_kept": "/Users/you/Dev/Acme",
  "gateway_discarded": true,
  "orphaned_sessions": 0,
  "orphaned_jobs": 0
}
```

Notes:

- This removes the **config entry only**. The workspace directory under the dev root, its worktrees, and its branches are left on disk — same as the web UI. `worktree_dir_kept` names the path so a script can clean up deliberately.
- Any AI gateway stored for the workspace is discarded with it, and there is no undo. `gateway_discarded` says whether one was lost; the CLI also warns on stderr.
- Like rename, removal is refused while sessions or jobs still reference the workspace unless `--force` is passed.

### Workspace field flags

`add` and `edit` accept the same field flags.

| Flag                         | Description                                                                |
| ---------------------------- | -------------------------------------------------------------------------- |
| `--provider`                 | Code/PR host: `github` or `gitlab`                                          |
| `--host`                     | GitLab host, e.g. `gitlab.example.com` — GitLab workspaces only              |
| `--task-provider`            | Where tickets live: `github`, `gitlab`, `jira`, `corveil`, or `""` to follow the code provider |
| `--jira-site`                | Atlassian site, e.g. `acme.atlassian.net`                                   |
| `--jira-project-key`         | Jira project key, e.g. `PROPS`                                              |
| `--jira-jql`                 | JQL for this workspace's ticket board                                       |
| `--jira-status-backlog`      | Jira workflow status name for **Backlog**                                   |
| `--jira-status-ready`        | Jira workflow status name for **Ready**                                     |
| `--jira-status-in-progress`  | Jira workflow status name for **In Progress**                               |
| `--jira-status-in-review`    | Jira workflow status name for **In Review**                                 |
| `--jira-status-done`         | Jira workflow status name for **Done**                                      |
| `--clear-jira-status-map`    | Drop every Crow→Jira status mapping                                         |
| `--corveil-host`             | Self-hosted Corveil host — blank means the public `corveil.io`               |
| `--custom-instructions`      | Free text appended to this workspace's session prompts                      |
| `--custom-instructions-file` | Read `--custom-instructions` from a file; `-` reads stdin                   |
| `--always-include`           | Repo always listed in the prompt table (repeatable)                         |
| `--clear-always-include`     | Empty the always-include list                                               |
| `--auto-review-repo`         | Repo whose review requests auto-create a session (repeatable)               |
| `--clear-auto-review-repos`  | Empty the auto-review list                                                  |
| `--exclude-review-repo`      | Repo hidden from the review board (repeatable)                              |
| `--clear-exclude-review-repos` | Empty the exclude-from-reviews list                                       |
| `--session-env`              | `KEY=VALUE` exported into agents in this workspace (repeatable)             |
| `--clear-session-env`        | Drop every session env var                                                  |
| `--review-blocking-severity` | Review finding severity that forces `--request-changes`: `red`, `yellow`, or `green` (repeatable) |
| `--clear-review-blocking-severities` | Restore the default review blocking set (`red` + `yellow`)          |
| `--upload-session-logs`      | Upload this workspace's coding-session transcripts to Corveil, reusing its gateway credential: `true` or `false` |

Notes:

- **Clearing.** An optional scalar clears with an empty string — `--host ""` — matching the Settings form, where blanking a text input stores nothing. Lists and maps can't say "empty" that way, so they take an explicit `--clear-*` flag. `--jira-status-ready ""` clears just that one mapping.
- **Repeatable flags replace, they don't append.** Every `--always-include` on one invocation is the complete new list, matching `crow job edit --prompt`. Same for `--auto-review-repo`, `--exclude-review-repo`, `--review-blocking-severity`, and `--session-env`.
- **`--review-blocking-severity` decides which review findings block.** Unset means Crow's default, `red` + `yellow` — the rule every install had before this flag existed — so a workspace that never sets it is unchanged. `--clear-review-blocking-severities` returns to that default by **removing** the key, never writing a null or an empty list. **At least one severity must block**: a workspace where nothing gates the verdict approves every review, and with `autoMergeWatcherEnabled` on merges it too, so an empty set is rejected rather than stored. Non-blocking findings are still reported in the review body — only the verdict changes. `crow workspace get` echoes the *effective* list plus `review_blocking_severities_explicit`, which separates "inheriting the default" from "pinned to red + yellow".

  This is **advisory**. Crow renders the policy into the `crow-review-pr` skill on every launch path — the copied `SKILL.md` that Claude reads, and the inlined prompt body that Cursor, Codex, OpenCode, Grok and Antigravity read — but the review agent invokes `gh pr review` itself. Crow never sees that call and cannot check the posted verdict against the policy it handed over. The flag configures a prompt, not a gate.
- **`--jira-status-*` patches per key.** Setting one leaves the other four alone — unlike the list flags.
- **Fields are checked against the resulting workspace.** `--host` on a GitHub workspace, or any `--jira-*` flag on a workspace whose task provider isn't Jira, is an error rather than a value that would be stored and never read. Set the provider in the same invocation and both apply. Clearing a stranded field is always allowed.
- **`--session-env` is one variable per entry.** The `/crow-workspace` setup script reads the map as one `KEY=VALUE` per line and splits each at the first `=`, so both delimiters are reserved: a newline in a key or value is rejected (it would smuggle in a second variable), and so is a `=` in a *key* (it would come back as a different variable). A `=` in a value is fine — the split takes only the first one. Keys additionally may not contain whitespace or control characters, since no shell could reference them. All enforced server-side, not just by the CLI.
- **`--session-env` values are not credentials.** Unlike a gateway header they are stored in plain `config.json` and are not stripped from the web Settings payload. Put tokens in a gateway header instead.
- **`--upload-session-logs` opts this workspace's session transcripts in to Corveil upload (CROW-1066), reusing its gateway credential** so you don't re-enter a Corveil key. It is the CLI twin of the Settings → Workspaces checkbox and, unlike the local-only `crow logsync` block, is a normal workspace field — so a remote `set-config` can flip it too. Uploads still require the local-only master switch (`crow logsync set --enabled true`), which stays the kill switch, and a base URL on the `logSync` block (the destination is never the browser-flippable `--corveil-host`). A workspace with no gateway falls back to the global `logSync` API key. See [session-log-collector.md](session-log-collector.md#per-workspace-ui-opt-in-that-reuses-the-gateway-credential-crow-1066).
- **`cli` is derived, never set.** It follows `--provider` (`gh` / `glab`) on every write, so a stale value from an older config is repaired by any edit.
- There is no `--gateway` flag; see [Gateway Commands](#gateway-commands).

---

## Board & Workflow Commands

The CLI half of the actions the web Ticket Board and Reviews board expose as buttons — so a Manager agent or a shell script can drive the board without a browser.

Prerequisites differ by verb:

- `list-tickets` / `list-reviews` need a provider-configured tracker. Without one they return an empty board rather than failing. **No tmux required.**
- `refresh-tickets` needs a provider-configured tracker and errors without one. **No tmux required.**
- `work-on-issue`, `batch-work-on-issues`, `start-review`, and `create-manager` spawn or drive sessions, so they need tmux on the daemon host.
- `quick-action` needs either the Crow desktop app or tmux on the daemon host.

### `crow list-tickets`

Print the Ticket Board payload verbatim: every assigned issue, per-status counts, the 24-hour done count, and whether a poll is in flight. Filter with `jq`.

```bash
crow list-tickets
crow list-tickets | jq '.issues[] | select(.project_status == "In Progress")'
crow list-tickets | jq -r '.issues[] | select(.linked_session_id == null) | .url'
```

Returns `{"issues": [...], "counts": {"Backlog": N, "Ready": N, "In Progress": N, "In Review": N, "Done": N, "All": N}, "done_last_24h": N, "loading": bool}`. Each issue carries `id`, `number`, `title`, `state`, `url`, `repo`, `provider`, `pr_number`, `pr_url`, `updated_at`, `project_status`, `labels`, `body`, `author`, `created_at`, `comments_count`, `pr_state`, `checks`, and `linked_session_id` (`null` when no session is working it — the same field the web uses to decide whether to offer "Start Working").

### `crow list-reviews`

Print the Reviews board payload verbatim: PRs awaiting your review.

```bash
crow list-reviews
crow list-reviews | jq -r '.reviews[] | select(.review_session_id == null) | .url'
```

Returns `{"reviews": [...], "loading": bool, "unseen": N}`. Each review carries `id`, `pr_number`, `title`, `url`, `repo`, `author`, `head_branch`, `base_branch`, `is_draft`, `requested_at`, `labels`, `provider`, and `review_session_id` (`null` when no review session exists yet).

### `crow refresh-tickets`

Re-poll the ticket provider now instead of waiting for the next automatic poll. Shells out to `gh` / `glab` / Jira across every configured repo, so it uses a 120s timeout.

```bash
crow refresh-tickets
```

Returns `{"ok": true}` after the poll completes, so a following `crow list-tickets` already sees the new snapshot. Two cases return `{"ok": true}` without polling at all: a refresh is already in flight, or the provider is rate-limited.

### `crow work-on-issue`

Start working on a ticket. Types `/crow-workspace <url>` into the primary Manager terminal and lets that agent do the worktree/session setup — identical to the board's "Start Working" button.

```bash
crow work-on-issue --url "https://github.com/corveil/crow/issues/817"
```

| Flag    | Required | Description         |
| ------- | -------- | ------------------- |
| `--url` | yes      | Ticket / issue URL  |

The URL must be an `http(s)` URL with no whitespace or control characters — it becomes terminal keystrokes, and `crow send` semantics turn a newline into an Enter press. Returns `{"ok": true}`; the session appears once the Manager agent has set it up.

### `crow batch-work-on-issues`

Batch counterpart of `work-on-issue`: types one `/crow-batch-workspace <url1> <url2> …` line so the Manager runs the parallel batch skill once instead of N sequential submissions.

```bash
crow batch-work-on-issues --url "https://github.com/o/r/issues/1" --url "https://github.com/o/r/issues/2"

gh issue list -R corveil/crow --json url --jq '.[].url' \
  | crow batch-work-on-issues --urls-file -
```

| Flag           | Required | Description                                                        |
| -------------- | -------- | ------------------------------------------------------------------ |
| `--url`        | one of   | Ticket / issue URL (repeatable)                                    |
| `--urls-file`  | one of   | Read newline-delimited URLs from a file; `-` reads stdin           |

URLs are sent in order: every `--url` first, then the file's lines (blank lines dropped). Malformed URLs are **not** rejected locally — the daemon drops them into `rejected` and starts the rest, so one bad ticket can't block the batch. Duplicates are deduped server-side.

Returns `{"ok": true, "sent": N, "rejected": ["..."]}`. Check `rejected` — a non-empty array is a partial success, not a failure.

### `crow start-review`

Clone a pull request, scaffold the review skill, and spawn a review session — identical to the Reviews board's "Start Review" button. Uses a 120s timeout because it clones a repo.

```bash
crow start-review --url "https://github.com/corveil/crow/pull/842"
```

| Flag    | Required | Description        |
| ------- | -------- | ------------------ |
| `--url` | yes      | Pull request URL   |

Unlike `work-on-issue`, the URL is only checked for non-emptiness: it goes to `git clone` rather than terminal keystrokes. Returns `{"session_id": "..."}`.

### `crow create-manager`

Create an additional Manager session, named with the lowest unused `Manager N` — identical to the sidebar's `+` button.

```bash
crow create-manager
crow create-manager --agent cursor
```

| Flag      | Required | Description                                                                  |
| --------- | -------- | ---------------------------------------------------------------------------- |
| `--agent` | no       | Coding agent kind (`claude-code`, `cursor`, `codex`, `opencode`, `antigravity`, `grok`, `muse`); default agent when omitted |

Returns `{"session_id": "...", "name": "Manager N"}`.

`--agent` is used **as given**. `AgentKind` is an open `RawRepresentable` struct, so any non-empty string parses and an unrecognized kind is not rejected — a typo like `claude_code` stamps the Manager with a kind no agent is registered for (the terminal then launches with the registry's default agent, but the session record keeps the bogus kind). Only **omitting** `--agent` falls back to the configured Manager default. Same open-kind model as [`crow handoff-agent`](#crow-handoff-agent).

### `crow quick-action`

Dispatch a PR next-step into a session's managed agent terminal — identical to the PR badge buttons on a session card. The prompt is deterministic and shared with the auto-respond pipeline.

```bash
crow quick-action --session <uuid> --action fixChecks
```

| Flag        | Required | Description                                                                     |
| ----------- | -------- | ------------------------------------------------------------------------------- |
| `--session` | yes      | Session UUID                                                                    |
| `--action`  | yes      | `fixConflicts`, `addressChanges`, `fixChecks`, `mergePR`, or `reReview`         |

Returns `{"dispatched": true, "action": "..."}` on success. A **skipped** dispatch is reported as `{"dispatched": false, "action": "...", "reason": "..."}` with a **zero** exit code — the RPC succeeded, the session just had no managed terminal, no ready surface, or no linked PR. Scripts must branch on `dispatched`, not the exit code.

`addressChanges`, `fixChecks`, and `fixConflicts` are refused on a **review** session (`reason: "a reviewer can't modify the branch under review — use Re-review instead"`); use `reReview` there.

---

## Gateway Commands

An AI gateway is a base URL plus the auth headers sent with it. Agents launched into a workspace inherit them as `ANTHROPIC_BASE_URL` / `ANTHROPIC_CUSTOM_HEADERS`; the Manager session has its own gateway (`AppConfig.managerGateway`) rather than following a workspace's. Header values may be `op://…` 1Password references, resolved at launch so the secret never rests in `config.json` — see [Configuration](configuration.md#ai-gateway).

**Local-only.** These run over the Unix socket, which is local by construction. The same RPC methods are refused for remote `/rpc` web clients (`RPCWebSocketHandler.localOnlyDenial`), because gateway headers are credentials — reads included. A local browser can drive the equivalent controls at Settings → the workspace / Manager gateway editor.

Every subcommand takes exactly one target: `--manager`, or `--workspace` with a workspace name or UUID.

### `crow gateway get`

Show a gateway's base URL and header names. Header **values are blanked** unless `--reveal`, so the default output is safe to paste into a ticket.

```bash
crow gateway get --manager
crow gateway get --workspace Corveil --reveal
```

| Flag          | Required | Description                                          |
| ------------- | -------- | ---------------------------------------------------- |
| `--manager`   | one of   | Target the Manager AI gateway                        |
| `--workspace` | one of   | Target a workspace's gateway (name or UUID)          |
| `--reveal`    | no       | Print header values instead of blanking them         |

Returns `{"gateway_set": true, "base_url": "...", "headers": {...}}`, plus `workspace_id` / `workspace_name` for a workspace target.

### `crow gateway set`

Set a gateway. `--base-url` and at least one `--header` are both required — a gateway needs both or neither, so a half-filled one is rejected rather than persisted.

A `--header` with a **blank value keeps the secret already stored** under that name. That is how to change a base URL without restating credentials:

```bash
crow gateway set --manager --base-url https://gw.example.com --header "X-Api-Key: sk-…"
crow gateway set --manager --base-url https://gw2.example.com --header "X-Api-Key:"
crow gateway set --workspace Corveil \
  --base-url https://gw.example.com \
  --header "X-Api-Key: op://Prod/Gateway/api_key" \
  --header "X-Tenant: acme"
```

A header value must not carry **literal surrounding quotes**. They are stored and transmitted verbatim, so the gateway sees them as part of the credential and rejects the request — which surfaces in the agent as a bare "API error" naming nothing. Quote the whole `Name: Value` pair in your shell, never inside it:

```bash
# ✅ the quotes are the shell's, and do not reach the header value
crow gateway set --workspace Corveil --base-url https://gw.example.com \
  --header "X-Api-Key: Bearer sk-…"

# ❌ rejected — the value would be stored as "Bearer sk-…" with the quotes
crow gateway set --workspace Corveil --base-url https://gw.example.com \
  --header 'X-Api-Key: "Bearer sk-…"'

# ❌ rejected — quoting the whole pair leaves a quote on the header name
crow gateway set --workspace Corveil --base-url https://gw.example.com \
  --header '"X-Api-Key: Bearer sk-…"'
```

Both write paths enforce this (the CLI and the Settings gateway editor). A value already stored this way still launches, but logs a redacted warning — see [configuration.md](configuration.md#secret-storage).

| Flag          | Required | Description                                          |
| ------------- | -------- | ---------------------------------------------------- |
| `--manager`   | one of   | Target the Manager AI gateway                        |
| `--workspace` | one of   | Target a workspace's gateway (name or UUID)          |
| `--base-url`  | yes      | Gateway base URL                                     |
| `--header`    | yes      | Header as `Name: Value` (repeatable)                 |

Returns `{"saved": true, "gateway_set": true}`.

### `crow gateway clear`

Remove a gateway. Agents launched afterwards fall back to vanilla Anthropic (the env vars are explicitly unset, so a global `~/.zshrc` export cannot leak in).

```bash
crow gateway clear --manager
crow gateway clear --workspace Corveil
```

| Flag          | Required | Description                                 |
| ------------- | -------- | ------------------------------------------- |
| `--manager`   | one of   | Target the Manager AI gateway               |
| `--workspace` | one of   | Target a workspace's gateway (name or UUID) |

Returns `{"saved": true, "gateway_set": false}`.

---

## Secrets Commands

### `crow web-password status | set | clear`

Manage the password that gates the `crowd` web UI for non-loopback clients. It is stored as a PBKDF2-HMAC-SHA256 hash (210,000 iterations, random per-password salt); the plaintext is never persisted and never leaves the local socket. **Local-only**, like the gateway commands.

```bash
crow web-password status
crow web-password set                              # prompts twice, echo off
printf '%s' "$PW" | crow web-password set --stdin  # for scripts
crow web-password clear
```

| Flag       | Applies to | Description                                  |
| ---------- | ---------- | -------------------------------------------- |
| `--stdin`  | set        | Read the password from stdin instead of prompting |

There is deliberately **no `--password` flag** — a plaintext password in `argv` lands in shell history and is visible to any local `ps`. Changing the password does not require the old one; the local-only gate is the control, matching the web UI. Clearing it means remote web clients are no longer challenged, so check how `crowd` is bound first.

`status` returns `{"password_set": true, "iterations": 210000}` — never the hash or salt. `set` / `clear` return `{"saved": true, "password_set": <bool>}`.

---

## Session-Log Sync Commands

The multi-harness session-log collector (CROW-1056) uploads each opted-in workspace's coding-session transcripts to Corveil as session artifacts, attributed to your own Corveil API key. It is **opt-in and OFF by default** — nothing uploads until you enable it *and* opt a workspace in. Uploads are best-effort and never block or fail a session, and **no AWS credentials are stored on this machine** (the server performs the object-storage upload). These verbs are **local-only**, like `gateway` / `web-password` — they configure uploads from the daemon host and carry a Corveil API-key reference.

> **Two ways to opt a workspace in.** `--add-workspace` (below) is the local-only list on this block. The second surface (CROW-1066) is the per-workspace `--upload-session-logs` flag / Settings → Workspaces checkbox, which **reuses the workspace's gateway credential** instead of the `--api-key-ref` here — see [`crow workspace edit`](#workspace-commands) and [session-log-collector.md](session-log-collector.md#per-workspace-ui-opt-in-that-reuses-the-gateway-credential-crow-1066). Either surface opts a workspace in; both still require `--enabled true` and a `--base-url` on this block.

### `crow logsync get`

```bash
crow logsync get
crow logsync get --reveal   # unmask a plaintext API key (op:// refs are always shown)
```

Returns the collector block: `enabled`, `base_url`, `api_key_ref` (masked unless `--reveal` or an `op://…` reference), `api_key_set`, `enabled_workspaces`, `retention_days`, `quiet_period_minutes`, `max_upload_bytes`, and `configured` (whether the block exists at all).

### `crow logsync set`

PATCH — only the flags you pass change; at least one is required.

```bash
# Turn it on, point it at your Corveil API, opt a workspace in.
crow logsync set --enabled true \
  --base-url https://api.corveil.io \
  --api-key-ref 'op://vault/corveil/api-key' \
  --add-workspace Corveil
crow logsync set --add-workspace Acme --remove-workspace Legacy
crow logsync set --clear-workspaces          # opt every workspace out
crow logsync set --enabled false             # stop uploading
crow logsync set --api-key-ref ''            # clear the stored key
```

| Flag | Description |
| --- | --- |
| `--enabled true\|false` | Master switch (default false) |
| `--base-url URL` | Corveil API base (hosts `POST /api/crow-sessions/{id}/artifacts`); empty clears |
| `--api-key-ref REF` | Corveil API key as an `op://…` reference (preferred) or plaintext; empty clears |
| `--add-workspace NAME` | Opt a workspace in (repeatable) |
| `--remove-workspace NAME` | Opt a workspace out (repeatable) |
| `--clear-workspaces` | Opt every workspace out |
| `--retention-days N` | Local upload-ledger retention (0 = forever, default 30) |
| `--quiet-period-minutes N` | Wait this long after a session's last activity before uploading (default 30) |
| `--max-upload-bytes N` | Per-transcript upload cap (default 8000000) |

Only Claude Code transcripts are collected today (its logs are the one harness partitioned by working directory); other harnesses are wired as their on-disk log locations are confirmed. Changes are live — the collector re-reads config each tick, so they apply within a few minutes with no restart.

---

## MCP Commands

Crow serves a **read-only** MCP surface so agent clients that speak MCP — Cowork, a Grok bot — can read the board without a Crow-launched session. Six tools over five read RPCs; there is no prompt-send, no session creation, and no config access. See [MCP](mcp.md) for client setup and the full tool list.

There are two transports, with two different trust models:

| Transport | Verb / endpoint | Credential | For |
| --- | --- | --- | --- |
| stdio | `crow mcp serve` | none — the 0600 Unix socket is the boundary | a local client on this machine |
| HTTP | `POST /mcp` | `Authorization: Bearer <token>` | an off-box client |

### `crow mcp serve`

Speaks MCP on stdin/stdout, forwarding each tool call to the running `crowd` over its Unix socket. Point a local MCP client at it:

```bash
crow mcp serve
crow mcp serve --scope board:read          # narrow the served tools
```

```json
{"mcpServers": {"crow": {"command": "crow", "args": ["mcp", "serve"]}}}
```

| Flag      | Required | Description                                                    |
| --------- | -------- | -------------------------------------------------------------- |
| `--scope` | no       | Limit served tools (repeatable). Defaults to every read scope.  |

No token is needed: a caller that can run this could already run every other `crow` verb, so a token would gate nothing. Unlike every other verb, **stdout carries framed JSON-RPC** rather than one JSON object — it is a transport, not a query. Diagnostics go to stderr.

### `crow mcp token mint`

Mint a scoped bearer token for the remote `POST /mcp` endpoint. **Local-only**, like the gateway and web-password commands — a remote peer must not be able to issue itself the credential that gates remote access.

```bash
crow mcp token mint --name grok-bot --scope board:read
crow mcp token mint --name cowork --scope sessions:read --scope board:read --expires-in 30d
crow mcp token mint --name ci --scope board:read --no-expiry
```

| Flag           | Required | Description                                                          |
| -------------- | -------- | -------------------------------------------------------------------- |
| `--name`       | yes      | A label for the token, e.g. `grok-bot`                                |
| `--scope`      | yes      | `sessions:read` or `board:read` (repeatable; at least one)            |
| `--expires-in` | no       | Lifetime: `30s`, `45m`, `12h`, `90d`, `2w`. Defaults to `90d`.        |
| `--no-expiry`  | no       | Mint a token that never expires (mutually exclusive with the above)   |

The token is printed **once** and stored only as a SHA-256 hash, so it cannot be recovered — losing it means minting another and revoking the old one. A bare `--expires-in 90` is rejected rather than guessed: seconds and days differ by seven orders of magnitude in what a leaked token buys.

Returns `{"saved": true, "token": "crow_mcp_…", "warning": "...", "record": {...}}`.

### `crow mcp token list`

List tokens — names, prefixes, scopes and expiry, never the tokens themselves.

```bash
crow mcp token list
```

Returns `{"tokens": [{"id": "...", "name": "...", "prefix": "...", "scopes": [...], "created_at": "...", "expires_at": "...", "expired": false}], "count": 1}`.

### `crow mcp token revoke`

Revoke a token. Takes exactly one of `--id` or `--name`; an ambiguous name is refused rather than guessed, since deleting the wrong credential is not something to be helpful about.

```bash
crow mcp token revoke --name grok-bot
crow mcp token revoke --id 7F3A1C22-0B4E-4E51-9E2A-2C9F4E6D1A80
```

| Flag     | Required | Description                                       |
| -------- | -------- | ------------------------------------------------- |
| `--id`   | one of   | Token UUID, from `crow mcp token list`            |
| `--name` | one of   | Token name, when only one token carries it        |

Returns `{"revoked": true, "id": "...", "name": "...", "remaining": 0}`.

---

## Not Exposed on the CLI

The **Jira credential** (`AppConfig.jiraCredential`) is intentionally UI-only. It is a `op://` 1Password reference managed outside Crow, and the app resolves it at call time rather than storing a secret — so there is nothing for a CLI verb to write that editing the reference in Settings (or 1Password) does not already cover.

---

## Hooks (Internal)

### `crow hook-event`

Forwards an agent hook event (e.g. `Stop`, `Notification`, `PreToolUse`) to `crowd`. The JSON payload is read from stdin and wrapped in an RPC call. This is wired up automatically by each agent's per-worktree hook config (Claude Code, Cursor, Codex, Grok, Muse, …), with the Crow session UUID baked into the command — you do not invoke it by hand.

```bash
echo '{"tool":"Bash"}' | crow hook-event --session <uuid> --event PreToolUse
```

On success it is silent; on error it prints JSON to stdout.

---

## Exit Codes

- `0` — success
- non-zero — connection error, validation failure, or RPC error (details on stderr)

## Error Responses

When `crowd` returns an RPC error, the command prints JSON of the form:

```json
{"error": "..."}
```

and exits non-zero. Common causes: `crowd` is not running (socket connection refused), an invalid UUID, or a session/terminal that does not exist.
