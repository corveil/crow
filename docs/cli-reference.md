# `crow` CLI Reference

The `crow` CLI communicates over a Unix socket at `~/.local/share/crow/crow.sock` (override with `CROW_SOCKET`). A server must be listening on it for RPC commands to succeed — the `crowd` daemon owns this socket. `crow setup` and `crow autostart` are the only subcommands that work with nothing listening.

All commands print JSON to stdout on success. Session and terminal identifiers are full UUIDs (e.g. `a1b2c3d4-e5f6-7890-abcd-ef1234567890`) — short names are not accepted.

Every subcommand source lives in `Packages/CrowCLI/Sources/CrowCLILib/Commands/`.

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

Returns full session details: id, name, status, ticket metadata, worktrees, terminals, and links.

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

### `crow handoff-agent`

Switch a session to a different coding agent mid-flight (e.g. when credits run out). Preserves session identity, worktree, branch, and ticket context. Tears down the managed agent terminal and launches the target agent with a handoff prompt. Conversation history does **not** transfer across agents — see [ADR 0009](adr/0009-agent-handoff-preserves-session-not-chat.md).

```bash
crow handoff-agent --session <uuid> --agent cursor
crow handoff-agent --session <uuid> --agent claude-code --note "Hit credit limit; continue from failing tests"
```

| Flag / Arg    | Required | Description                                              |
| ------------- | -------- | -------------------------------------------------------- |
| `--session`   | yes      | Session UUID                                             |
| `--agent`     | yes      | Target kind: `claude-code`, `cursor`, `codex`, `opencode` |
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
| `--agent` | no       | Coding agent kind (`claude-code`, `cursor`, `codex`, `opencode`); default agent when omitted |

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

---

## Hooks (Internal)

### `crow hook-event`

Forwards a Claude Code hook event (e.g. `Stop`, `Notification`, `PreToolUse`) to `crowd`. The JSON payload is read from stdin and wrapped in an RPC call. This is wired up automatically by Claude Code's hook system — you do not invoke it by hand.

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
