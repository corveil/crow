<!-- This file is both repo documentation and Manager tab context.
     Crow scaffolds it into {devRoot}/.claude/CLAUDE.md on launch (see Scaffolder.swift). -->

# Crow — Manager Context

This is the development root managed by Crow. The Manager tab runs Claude Code here to orchestrate work sessions via the `crow` CLI.

## Architecture Decision Records

Architectural decisions live in [`docs/adr/`](docs/adr/). Read [`docs/adr/README.md`](docs/adr/README.md) for the index, and copy [`docs/adr/template.md`](docs/adr/template.md) to start a new one. When superseding a decision, update the old ADR's `Status` field to `Superseded by NNNN` — don't delete it. The history is the point.

## crow CLI Reference

The `crow` CLI communicates with the Crow app via Unix socket at `~/.local/share/crow/crow.sock`. The app must be running for commands to work. **All `crow`, `gh`, `glab`, and `git worktree` commands require `dangerouslyDisableSandbox: true`** and return JSON.

### Session Commands
```
crow new-session --name "feature-name"          → {"session_id":"<uuid>","name":"..."}
crow rename-session --session <uuid> "new-name" → {"session_id":"...","name":"..."}
crow select-session --session <uuid>            → {"session_id":"..."}
crow list-sessions                              → {"sessions":[...]}
crow get-session --session <uuid>               → {id, name, status, ticket_url, ...}
crow set-status --session <uuid> active|paused|inReview|completed|archived
crow handoff-agent --session <uuid> --agent cursor [--note "..."] → {"session_id":"...","agent_kind":"...","terminal_id":"..."}
crow delete-session --session <uuid>            → {"deleted":true}
```

### Daemon Autostart

Runs locally, not over the socket — these work with `crowd` down (CROW-769). macOS only for now.

```
crow autostart install [--binary PATH] [--host H] [--port N] [--dev-root PATH] [--socket PATH]
                                                → registers a launchd LaunchAgent so crowd starts at login (idempotent; re-points after an upgrade)
crow autostart uninstall                        → removes the login item
crow autostart status [--json]                  → {enabled, running, loaded, stale, plistPath, logPath, ...}
```

### Metadata Commands
```
crow set-ticket --session <uuid> --url "..." [--title "..."] [--number N]
crow set-goal --session <uuid> --goal "..." | --clear                  → tag the session's org goal/KPI (feeds alignment weight; exactly one of --goal/--clear)
crow add-link --session <uuid> --label "Issue" --url "..." --type ticket|pr|repo|custom
crow list-links --session <uuid>
crow remove-link --session <uuid> --id <link-uuid> | --url "..."       → detach a link by id (from list-links) or url; returns {"removed":N}
crow edit-link --session <uuid> --id <link-uuid> | --url "..." [--label "..."] [--new-url "..."] [--type ...]   → update a link in place (only provided fields change; --url selects, --new-url sets); returns {"updated":N}
crow transition-ticket --session <uuid> --to inProgress|inReview|done   → moves the linked ticket to a pipeline status (Jira honors jiraStatusMap)
crow resync-jira                                                        → re-sync every Jira ticket's status from its Crow session state
```

### Worktree Commands
```
crow add-worktree --session <uuid> --repo "name" --repo-path "/main/repo" --path "/worktree/path" --branch "feature/..." [--primary]
crow list-worktrees --session <uuid>
```

### Terminal Commands
```
crow new-terminal --session <uuid> --cwd "/path" [--name "Claude Code"] [--command "claude ..."] [--managed]
crow list-terminals --session <uuid>
crow close-terminal --session <uuid> --terminal <uuid>
crow send --session <uuid> --terminal <uuid> "text to send"
```

The `crow send` command writes text to the terminal. Newlines in the text are converted to Enter keypresses. To submit a command, include a newline at the end of the text.

## Important Notes

- `--session` always expects a full UUID (e.g., `a1b2c3d4-e5f6-7890-abcd-ef1234567890`), not a session name
- Always capture the `session_id` from `new-session` output before using it in subsequent commands
- The Manager session UUID is always `00000000-0000-0000-0000-000000000000` — do not delete it
- Use `/crow-workspace` skill for full workspace setup (worktrees + session + Claude Code)
- **Worktree paths go DIRECTLY under the workspace folder**: `{devRoot}/{workspace}/{repo}-{number}-{slug}` — NOT in a subfolder
- Use `$TMPDIR` (not `/tmp`) for temporary files

## Git Worktree Best Practices

### Branch Conflicts
If `git worktree add` fails with "branch already exists":
```bash
git branch -D feature/branch-name          # Delete the conflicting local branch
git worktree add /path -b feature/name --no-track origin/main   # Retry
```

### Worktree Naming
**Correct:** `{devRoot}/{workspace}/{repo}-{number}-{slug}` (same level as main repo)
```
/Users/jane/Dev/Corveil/acme-api-197-fix-tab-url-hash
```

**WRONG — never create subdirectories:**
```
WRONG: /Users/jane/Dev/Corveil/acme-api-worktrees/197-fix-tab
WRONG: /Users/jane/Dev/Corveil/worktrees/acme-api-197-fix-tab
```

### Always use `--no-track` for new branches
Prevents accidental push to main:
```bash
git worktree add /path -b feature/name --no-track origin/main
```

## Concurrency Safety

The crow CLI is safe for concurrent use. Multiple `crow` commands can run simultaneously without race conditions:

- **Socket Server**: Each CLI connection is dispatched to GCD's global concurrent queue. Multiple connections are accepted and processed in parallel.
- **State Mutations**: All RPC handlers use `await MainActor.run { ... }`, serializing all AppState mutations on the main thread. This prevents data races even when multiple CLI commands arrive simultaneously.
- **Persistence**: `JSONStore` serializes disk writes with `NSLock` and coalesces them by sequence — but **only within a single instance**. Its in-memory `_data` and `writeSeq` are instance state, and every `mutate` rewrites the whole `StoreData`. **All writers must therefore share the one injected `JSONStore`** (owned by `SessionService`, created in `AppDelegate`). Constructing a throwaway `JSONStore().mutate { … }` reads its own (possibly stale) disk snapshot, and its full-store write can silently clobber a record another writer just added (#728).
- **Git Operations**: Each `setup.sh` creates its own worktree at a unique path, its own session (unique UUID), and its own terminal. There are no shared resources between parallel workspace setups.

Use `/crow-batch-workspace` to set up multiple workspaces in parallel.

## Fetching Ticket / PR Data

Claude Code permission allow-rules (`Bash(gh issue view:*)`, `Bash(gh api:*)`, `Bash(gh pr view:*)`, `Bash(git -C:*)`, …) are **prefix matches against the whole Bash command**. A compound invocation auto-approves only if **every** segment matches a rule — so one un-allowlisted segment (a `cd`, a `find`, an `echo` banner, a pipe into `head`) forces a permission prompt even though the `gh`/`git` part is allowlisted on its own.

Issue ticket/PR fetches as **single, clean invocations**:

- Use `gh -R <owner>/<repo> …` and `git -C <path> …` instead of `cd <path> && …`.
- Do **not** chain with `;` / `&&`, add `echo` banners, or pipe into `head`/`tail`/`find` in the same Bash call as a `gh`/`git` fetch.
- Run **one** command per Bash call for ticket/PR fetches.

```bash
# ✅ single clean invocations — auto-approved
gh issue view https://github.com/owner/repo/issues/123 --comments
gh api repos/owner/repo/issues/123
git -C /path/to/worktree log --oneline -10

# ❌ compound — falls back to a permission prompt
cd /path && gh issue view 123 | head -200
echo "=== api ==="; gh api repos/owner/repo/issues/123 | head -120
```

This keeps the allowlist tight (preferred over broadening it with `cd:*` / `find:*`).

## Bash Conventions

Same allowlist-prefix problem applies to `find -exec`: the rule engine can't see what gets exec'd, so `find ... -exec X` falls back to a permission prompt even when both `find` and `X` are individually allowlisted. Prefer these instead — they avoid the prompt entirely:

| Intent | Use | Not |
|---|---|---|
| Search files for text | `rg PATTERN` (recursive by default, respects `.gitignore`) | `find . -exec grep PATTERN {} \;` |
| Search by file type | `rg PATTERN --type py` / `--type swift` | `find . -name '*.py' -exec grep ...` |
| Find files by name | `find . -name X` (no `-exec`) | — |
| Delete matches | `find . -name X -delete` | `find . -name X -exec rm {} \;` |
| Run a command per match | `find ... -print0 \| xargs -0 CMD` | `find ... -exec CMD {} \;` |
| Filter then count | `find ... \| wc -l` (single pipe is fine) | — |

`rg` (ripgrep) is the default search tool — much faster than `grep -r` and skips ignored files. Install via `brew install ripgrep` if missing.

`find -exec` is essentially never the right tool today — `-delete` and `xargs` cover what it was originally needed for, and both keep the allowlist clean.

## Known Issues / Corrections

<!-- Auto-maintained by Claude Code during workspace setup -->
