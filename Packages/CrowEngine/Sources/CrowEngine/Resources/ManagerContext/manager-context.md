# Crow — Manager Context

This is the development root managed by Crow. The Manager tab runs a coding agent here to orchestrate work sessions via the `crow` CLI. Every Crow session under this root loads this file (Managers, work, review and job sessions), so it holds only what they all need. The full CLI reference loads on demand; see **crow CLI** below.

## Naming this Manager session

Additional Managers are created as `Manager 2`, `Manager 3`, … — a title that tells the operator nothing about the work. As soon as you know what this session is for, give it a name that reflects that, so the sidebar stays legible.

**On the first real ask of this session** — the first user turn that hands you actual work, not a greeting — and before you start that work:

1. If `$CROW_SESSION_ID` is `00000000-0000-0000-0000-000000000000`, you are the **primary Manager**. Never rename it — stop here.
2. Run `crow get-session --session "$CROW_SESSION_ID"` and read `name`. If it is **not** of the form `Manager <N>` (e.g. `Manager 2`), this session was already named — stop here.
3. Otherwise derive a short title from the ask: 2–6 words or a short slug (`ios-keyboard-cursor`, `review crow-1078`, `file keyboard bug`). It must be non-empty, ≤256 characters, free of control characters, and must not collide with an existing name — check `crow list-sessions`.
4. Rename through the CLI, so the persist / sidebar row / agent `/rename` (CROW-629) all run on one path:
   ```
   crow rename-session --session "$CROW_SESSION_ID" "<derived-name>"
   ```

Do this **once**. After step 4 the name is no longer `Manager <N>`, so step 2 keeps it from firing again on later turns. Never rename on every message, and never rename the primary Manager or a session the operator already named.

## crow CLI

The `crow` CLI talks to the Crow daemon (`crowd`) over the Unix socket `~/.local/share/crow/crow.sock`; the daemon must be running. When the socket is unreachable (Cursor sandbox), `crow` retries over loopback `POST /rpc` (`http://127.0.0.1:8787/rpc`; `CROW_HTTP_URL` / `CROW_HTTP_PORT`). Every verb prints JSON. **All `crow`, `gh`, `glab`, and `git worktree` commands require `dangerouslyDisableSandbox: true`.**

**For any verb or flag not listed here, use the `crow-cli` skill**, which reads `.claude/skills/crow-cli/reference.md` under the development root: flags, JSON output and gotchas for every group (sessions and lifecycle, links, terminals, worktrees, board and reviews, jobs, Scratch todos, workspaces, agents, automation, defaults, settings, notifications, skins, gateways, Corveil, session-log sync, backfill, MCP, TUI recordings, maintenance). An agent without skills reads that file directly. `crow <verb> --help` prints any verb's exact flags. Never guess a flag.

The verbs most sessions need:

```
crow list-sessions                              → {"sessions":[...]}
crow get-session --session <uuid>               → {id, name, status, ticket_url, ...}
crow new-session --name "feature-name"          → {"session_id":"<uuid>","name":"..."}
crow rename-session --session <uuid> "new-name"
crow set-status --session <uuid> active|paused|inReview|completed|archived
crow set-ticket --session <uuid> --url "..." [--title "..."] [--number N]
crow add-link --session <uuid> --label "PR #12" --url "..." --type ticket|pr|repo|custom
crow list-links --session <uuid>
crow list-worktrees --session <uuid>
crow list-terminals --session <uuid>
crow send --session <uuid> --terminal <uuid> "text to send"
crow list-tickets / crow list-reviews           → board payloads verbatim; filter with jq
crow work-on-issue --url "..."                  → types /crow-workspace <url> into the Manager
crow start-review --url "<pr-url>"              → {"session_id":"<uuid>"}
crow create-manager [--agent KIND] [--workspace NAME]
crow todo add "text" / crow todo list
```

`crow send` writes text to the terminal as one bracketed paste; newlines become Enter, so end with a newline to submit. It errors instead of printing `"sent": true` when the text can't be delivered. `add-link --type pr` is idempotent: it skips when the session already has a PR link.

## Important Notes

- `--session` always expects a full UUID (e.g., `a1b2c3d4-e5f6-7890-abcd-ef1234567890`), not a session name
- Always capture the `session_id` from `new-session` output before using it in subsequent commands
- The Manager session UUID is always `00000000-0000-0000-0000-000000000000` — do not delete it
- Use `/crow-workspace` skill for full workspace setup (worktrees + session + Claude Code)
- **Worktree paths go DIRECTLY under the workspace folder**: `{devRoot}/{workspace}/{repo}-{number}-{slug}` — NOT in a subfolder
- Use `$TMPDIR` (not `/tmp`) for temporary files
- The `crow` CLI is safe to run concurrently, and parallel `setup.sh` runs share nothing (each gets its own worktree, session and terminal)

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
WRONG: /Users/jane/Dev/acme-api-197-fix-tab              (directly in the dev root)
WRONG: /Users/jane/Dev/not-a-workspace/acme-api-197-fix  (folder isn't a configured workspace)
```

`crow add-worktree` and `setup.sh` reject any path that isn't exactly `{devRoot}/{workspace}/{dir}` for a configured workspace (case-insensitive), or `{devRoot}/crow-reviews/{dir}`, after resolving symlinks and `..` — before anything is created (CROW-1396). Add a missing workspace with `crow workspace add`.

### Always use `--no-track` for new branches
Prevents accidental push to main:
```bash
git worktree add /path -b feature/name --no-track origin/main
```

## Bundled skills

Each one documents itself; use it by name.

- `/crow-workspace` sets up one work session; `/crow-batch-workspace` sets up several in parallel.
- `/crow-cascade-epic <epic-url>` runs an epic's sub-tickets wave by wave, starting the next wave only after the current wave's PRs merge.
- `/crow-triage` turns proposed work items into a Kick off / Later / Drop decision page and hands the Kick off set to `/crow-cascade-epic`.
- `/crow-ci-queue` serializes the label-gated `ci:full` suite across live session PRs, one per repo at a time.
- `/crow-backlog-brief` drains the backlog in rounds of decision pages.
- `/crow-release-review` publishes a release review page and runs each tag only on the operator's go.
- `/crow-diagnose <observation>` turns one observation into a diagnosed ticket or epic (or a non-ticket outcome).
- `/my-follow-ups [owner/repo]` lists your open Corveil follow-ups and files, triages or closes the ones you pick.
- `crow-cli` is the per-verb `crow` reference (above).

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

## Bash Conventions

The same prefix rule defeats `find -exec`: the rule engine can't see what gets exec'd, so it falls back to a permission prompt.

| Intent | Use | Not |
|---|---|---|
| Search files for text | `rg PATTERN` (recursive, respects `.gitignore`) | `find . -exec grep PATTERN {} \;` |
| Search by file type | `rg PATTERN --type py` | `find . -name '*.py' -exec grep ...` |
| Find files by name | `find . -name X` (no `-exec`) | — |
| Delete matches | `find . -name X -delete` | `find . -name X -exec rm {} \;` |
| Run a command per match | `find ... -print0 \| xargs -0 CMD` | `find ... -exec CMD {} \;` |

## Known Issues / Corrections
