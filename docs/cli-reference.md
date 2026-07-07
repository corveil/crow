# `crow` CLI Reference

The `crow` CLI communicates over a Unix socket at `~/.local/share/crow/crow.sock` (override with `CROW_SOCKET`). A server must be listening on it for RPC commands to succeed — by default the `crowd` daemon owns this socket (the desktop app is a client of `crowd`); a legacy app run with `CROW_LOCAL_ENGINE=1` binds it instead. `crow setup` is the only subcommand that works with nothing listening.

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

This is the only subcommand that does not require a running app.

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

Make the given session the active tab in the app.

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

---

## Worktree Commands

### `crow add-worktree`

Register a git worktree for a session. The app uses `--repo-path` to run git commands against the main repo when needed.

```bash
crow add-worktree \
  --session <uuid> \
  --repo "acme-api" \
  --repo-path "/Users/you/Dev/RadiusMethod/acme-api" \
  --path "/Users/you/Dev/RadiusMethod/acme-api-123-feature" \
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

## Hooks (Internal)

### `crow hook-event`

Forwards a Claude Code hook event (e.g. `Stop`, `Notification`, `PreToolUse`) to the app. The JSON payload is read from stdin and wrapped in an RPC call. This is wired up automatically by Claude Code's hook system — you do not invoke it by hand.

```bash
echo '{"tool":"Bash"}' | crow hook-event --session <uuid> --event PreToolUse
```

On success it is silent; on error it prints JSON to stdout.

---

## Exit Codes

- `0` — success
- non-zero — connection error, validation failure, or RPC error (details on stderr)

## Error Responses

When the app returns an RPC error, the command prints JSON of the form:

```json
{"error": "..."}
```

and exits non-zero. Common causes: the app is not running (socket connection refused), an invalid UUID, or a session/terminal that does not exist.
