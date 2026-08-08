<!-- This file is both repo documentation and Manager tab context.
     Crow scaffolds it into {devRoot}/.claude/CLAUDE.md on launch (see Scaffolder.swift). -->

# Crow — Manager Context

This is the development root managed by Crow. The Manager tab runs Claude Code here to orchestrate work sessions via the `crow` CLI.

## Architecture Decision Records

Architectural decisions live in [`docs/adr/`](docs/adr/). Read [`docs/adr/README.md`](docs/adr/README.md) for the index, and copy [`docs/adr/template.md`](docs/adr/template.md) to start a new one. When superseding a decision, update the old ADR's `Status` field to `Superseded by NNNN` — don't delete it. The history is the point.

**Coding-agent harnesses:** Crow drives Claude Code, Cursor, Codex, and OpenCode through the `CodingAgent` adapter. What each harness can (and can't) do — and why — lives in [`docs/agent-harness-matrix.md`](docs/agent-harness-matrix.md); the architecture is [ADR 0014](docs/adr/0014-pluggable-coding-agent-adapter.md) and the capability gaps are [ADR 0015](docs/adr/0015-harness-capability-tiers.md).

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
crow set-locked --session <uuid> true|false     → exempt a session from (or return it to) the retention reaper
crow handoff-agent --session <uuid> --agent cursor [--note "..."] → {"session_id":"...","agent_kind":"...","terminal_id":"..."}
crow delete-session --session <uuid>            → {"deleted":true}
```

### Session Lifecycle

The web session-menu actions, as CLI verbs. All take only `--session`. Preconditions are enforced server-side (the browser hides menu items instead); current status is **not** gated, so these are safe to re-run.

```
crow mark-in-review --session <uuid>            → {"session_id":"...","status":"inReview","warning":"…"}  moves the ticket to In Review on the provider's board, then the session; needs a linked ticket
crow complete-session --session <uuid>          → {"session_id":"...","status":"completed"}
crow set-session-active --session <uuid>        → {"session_id":"...","status":"active"}      reopen a completed session
crow mark-issue-done --session <uuid>           → {"ok":true,"session_id":"..."}              closes the linked issue, then completes the session
crow add-merge-label --session <uuid>           → {"ok":true,"session_id":"...","warning":"…"}  adds crow:merge to the session's PR; needs a linked PR. `warning` is present only when the label won't lead to a merge (watcher off, repo forbids auto-merge)
```

`complete-session` / `set-session-active` write Crow's session status only — to move the **provider's** board for those, use `crow transition-ticket --to ...`. `mark-in-review` moves the board itself: it transitions the ticket **first**, so a failed transition errors instead of leaving the session marked. When the provider has no In Review status to move to (GitLab, or a board whose column isn't named "In Review"), the session still moves and `warning` says the ticket did not. Manager sessions are rejected.

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

### Allowlist

Claude Code permission patterns, aggregated from global `~/.claude/settings.json` + each worktree's `.claude/settings.local.json`.

```
crow list-allowlist                                → {"entries":[{pattern,is_global,worktree_session_names}],"loading":bool}; reads the last scan
crow refresh-allowlist                             → re-scan both sources from disk; {"ok":true}
crow promote-allowlist --pattern 'Bash(npm test:*)' [--pattern ...]   → {"ok":true,"added":[...],"already_global":[...],"global_settings_path":"..."}
```

Repeat `--pattern` for more than one, and **quote them** — `(`, `)`, `*` are shell metacharacters. A failed write is a non-zero exit, never `ok:true`; a malformed global settings file is refused rather than overwritten.

### Settings Commands
```
crow telemetry get                                                      → {"telemetry":{"enabled":…,"port":…,"retention_days":…}}
crow telemetry set [--enabled true|false] [--port N] [--retention-days N]  → patch; enabled/port need a crowd restart (returns "restart_required")
crow cleanup get                                                        → {"cleanup":{"enabled":…,"retention_hours":…}}
crow cleanup set [--enabled true|false] [--retention-hours N]           → patch; live within ~1 board poll. Deletes completed/archived sessions incl. worktree + branch
crow ui get                                                             → {"ui":{"sidebar":{"hide_session_details":…}}}
crow ui set --hide-session-details true|false                           → patch; connected browsers repaint within ~2s
crow version                                                            → prints the stamped build version
crow version --check                                                    → compare against corveil/crow main; human summary, exit 0/1/2
crow version check                                                      → same as --check
crow version get                                                        → {"version_update":{…},"status":{…}}
crow version set [--enabled true|false] [--interval-hours N]            → patch; interval floored at 1h
```

### Defaults

`AppConfig.defaults` — Settings → Workspaces (provider, branch prefix), → Automation (board filter lists), → General (corveil binary path).

```
crow defaults get                                                       → {"defaults":{…all 9 fields…},"config_readable":bool}
crow defaults set [--provider github|gitlab] [--cli gh|glab] [--branch-prefix 'feat/']
crow defaults set --binary NAME=PATH ...                                → merge; NAME= removes. LOCAL-ONLY; needs a crowd restart
crow defaults set --add-exclude-review-repo R | --remove-exclude-review-repo R | --clear-exclude-review-repos
                  --add-exclude-ticket-repo R | --remove-exclude-ticket-repo R | --clear-exclude-ticket-repos
                  --add-ignore-review-label L | --remove-ignore-review-label L | --clear-ignore-review-labels
```

Patch; at least one flag required. Lists are edited incrementally (add/remove compose, remove applied first; `--clear-X` is exclusive with add/remove **for that list only**) and matched case-insensitively, like the board filters. `--add-*-repo` takes one `*` wildcard; labels are exact.

Everything is live except `--binary` (agent discovery + `.claude/bin` symlinks are set up at startup) — that returns `restart_required`, *including on removal*. A non-executable path is saved with a warning, not rejected; `crow` is rejected as a binary name. `--provider`/`--cli` are independent — setting one warns via `provider_cli_mismatch` if the pair ends up crossed. `get` echoes all 9 fields, including the two `set` doesn't write (`exclude_dirs`, `mirror_claude_mcp_to_codex`).

The review board filters on defaults ∪ every workspace's own `excludeReviewRepos`, so `--clear-exclude-review-repos` won't unhide a repo a workspace excludes.
### Agent Commands

Which coding harness Crow launches — `AppConfig.defaultAgentKind` + `agentsByKind`, the Settings → General Agent pickers. Resolution is `agentsByKind[<role>] ?? defaultAgentKind`; roles are `work|review|job|manager`.

```
crow agents list                                        → {"agents":{"known":[{kind,name,binary,available}],"default_agent_kind":…,"by_kind":{…},"effective":{work,review,job,manager},"config_readable":…}}
crow agents set [--default <kind>] [--work|--review|--job|--manager <kind>] [--clear <role>]…
                                                        → patch; echoes the same subtree plus {"saved":true}; live within ~1 board poll
```

- `known` lists **every** agent Crow ships, each with `available` — the same surface-but-disable roster the web pickers show (#879), so an off-PATH agent reads as "not installed" rather than vanishing. Availability is decided when `crowd` **starts**, so a newly installed agent needs a daemon restart.
- Only `available: true` kinds are selectable. An unavailable one is **rejected and nothing is written** (stricter than `crow new-session --agent`, which falls back to the default); a known-but-uninstalled kind gets its own message naming the binary.
- A role flag also rejects an agent that can't run that session kind — but **no agent is review-incapable today** (Antigravity's review dispatch landed in #902), so the gate refuses nothing right now; it's kept in lockstep with `crow handoff-agent` for a future harness. `--default` is not gated this way on purpose.
- `--clear <role>` **removes** the override key, never writes a null — one null would make the whole `config.json` undecodable. Repeat per role; `--clear X` with `--X <kind>` is rejected.
- If `effective` names a kind that isn't available, the CLI warns on stderr — that role's sessions will not launch.

### Job Commands

Scheduled prompt-sets scoped to one repo in a workspace (CROW-604) — the Jobs sidebar, as CLI verbs. Jobs are addressed by UUID; `crow job list` prints them. Mutations hit the app's live config, so the scheduler and Settings UI see them immediately.

```
crow job list                                   → {"jobs":[...]}
crow job get --id <job-uuid>                    → {"job":{...}}
crow job add --name "..." --workspace "..." --repo owner/repo --prompt "..." (--interval-seconds N | --daily-at HH:MM [--weekdays mon,tue])
crow job edit --id <job-uuid> [--name ...] [--prompt ...] [--daily-at HH:MM] [--weekdays ...]
crow job enable --id <job-uuid>                 → {"job":{...}}
crow job disable --id <job-uuid>                → {"job":{...}}
crow job run --id <job-uuid>                    → {"job_id":"...","session_id":"...","terminal_id":"..."}   needs tmux; ignores schedule + enabled
crow job delete --id <job-uuid>                 → {"deleted":true,"job_id":"..."}
crow job duplicate --id <job-uuid>              → {"job":{...}}   the copy starts disabled with a uniquified name
```

- `add` needs exactly one schedule (`--interval-seconds` **or** `--daily-at`) and at least one `--prompt`/`--prompt-file`. `--prompt` and `--prompt-file` are repeatable and sent in that order; `--prompt-file -` reads stdin (at most once).
- On `edit`, any `--prompt` replaces the **whole** prompt list and any schedule flag replaces the **whole** schedule — so changing `--weekdays` means restating `--daily-at`. Use `enable`/`disable` instead of `edit` to toggle enabled.
- `job run` can take a while on first run (it may clone the repo); the run continues in the app even if the CLI stops waiting.

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
crow rename-terminal --session <uuid> --terminal <uuid> "new name"
crow recreate-terminal --session <uuid> --terminal <uuid>   → DESTRUCTIVE: rebuilds the pane to restore scrollback; relaunches the agent with --continue
crow send --session <uuid> --terminal <uuid> "text to send"
```

The `crow send` command writes text to the terminal. Newlines in the text are converted to Enter keypresses. To submit a command, include a newline at the end of the text.

### Maintenance Commands

Need tmux on the daemon host; otherwise they error with "… requires tmux on the daemon host".

```
crow restart-manager                            → relaunch the Manager's agent in place (primary Manager only; new terminal UUID)
crow restart-tmux-server                        → DESTRUCTIVE: kills every pane (all agents die), then rebuilds every terminal
crow reload-tmux-config                         → `tmux source-file` the bundled config into the live server (non-destructive)
crow launch-agent --terminal <uuid>             → launch the session's coding agent in a shell-ready terminal
crow retry-readiness --terminal <uuid>          → re-arm the readiness watch for a terminal whose first attempt timed out
crow open-in-vscode --session <uuid>            → open the session's worktree in VS Code on the host
crow open-terminal --session <uuid>             → open a macOS Terminal.app window at the worktree (host GUI, NOT a Crow tab)
```

- `restart-tmux-server` returns as soon as the teardown is done — the rebuild continues in the background, so don't chain a `crow send` right after it.
- `launch-agent` / `retry-readiness` take **only** `--terminal` (no `--session`), and their `{"ok": true}` means the request was accepted, not that it applied — the daemon no-ops them unless the terminal is in the right state.
- `open-terminal` is macOS-only and is not `new-terminal`: it opens Terminal.app on the host rather than a tab inside Crow.

### Inspection & Analytics
```
crow list-artifacts --session <uuid>  → {"images":[{name,size,mtime,url,path}],"dir":"..."} — images agents dropped in $CROW_ARTIFACTS_DIR (use path/dir, not url)
crow get-scorecard                    → the efficiency scorecard itself (grade, weekly rollups, baseline, per-session rows); timestamps are epoch ms
crow rebuild-scorecard                → backfill analytics snapshots; {"rebuilt":true}; errors when telemetry is off
crow get-state                        → the daemon's ENTIRE state snapshot; large, capped at 1 MB — prefer list-sessions / get-session / list-links
```

### Board & Workflow Commands

The CLI half of the web Ticket Board / Reviews board buttons — drive the board without a browser. The three read/refresh verbs need only a provider-configured daemon; the four session-spawning verbs additionally need tmux on the daemon host.

```
crow list-tickets                               → {issues:[...], counts:{...}, done_last_24h:N, loading:bool}
crow list-reviews                               → {reviews:[...], loading:bool, unseen:N}
crow refresh-tickets                            → {"ok":true}   (awaits the poll; see note below)
crow work-on-issue --url "..."                  → {"ok":true}   (types /crow-workspace <url> into the Manager)
crow batch-work-on-issues --url "..." [--url "..."] [--urls-file FILE|-]  → {"ok":true,"sent":N,"rejected":[...]}
crow start-review --url "<pr-url>"              → {"session_id":"<uuid>"}
crow create-manager [--agent claude-code|cursor|codex|opencode]           → {"session_id":"<uuid>","name":"Manager N"}
crow quick-action --session <uuid> --action fixConflicts|addressChanges|fixChecks|mergePR|reReview
                                                → {"dispatched":bool,"action":"...","reason":"..."}
```

- `list-tickets` / `list-reviews` print the board payload verbatim — filter with `jq`. A ticket with `linked_session_id: null` (or a review with `review_session_id: null`) is one nothing is working yet.
- `work-on-issue` URLs become terminal keystrokes, so they must be `http(s)` with no whitespace or control characters. `start-review` URLs go to `git clone` and are not checked that way.
- `batch-work-on-issues` sends `--url` values first, then the lines of `--urls-file`. Bad URLs come back in `rejected` instead of failing the batch.
- `quick-action` returns `dispatched:false` + `reason` with a **zero** exit code when the session has no agent terminal or no linked PR — branch on `dispatched`, not the exit code.
- `refresh-tickets` awaits the poll, so a following `list-tickets` sees the new data. It returns `{"ok":true}` without polling when a refresh is already in flight or the provider is rate-limited.
- `create-manager --agent` is used as given — an unrecognized kind is not rejected, so a typo stamps the Manager with a kind no agent is registered for. Omit `--agent` to get the configured Manager default.

### Notification Commands

Reads and writes `AppConfig.notifications` — the same settings as Settings → Notifications.

```
crow notifications get [--event <name>]                → {"notifications":{globals, events, available_sounds, config_readable}}
crow notifications set [--global-mute|--no-global-mute] [--sound-enabled|--no-sound-enabled]
                       [--system-notifications-enabled|--no-system-notifications-enabled]
crow notifications set --event <name> [--event-enabled|--no-event-enabled]
                       [--event-sound-enabled|--no-event-sound-enabled]
                       [--event-system-notification-enabled|--no-event-system-notification-enabled]
                       [--event-sound-name <Sound>]     → {"notifications":{...},"saved":true}
```

Events: `taskComplete`, `agentWaiting`, `reviewRequested`, `changesRequested`, `checksFailing`, `autoWorkspaceCreated`, `autoMergeEnabled`, `autoMergeBlocked`, `autoRebasePushed`, `autoRebaseConflicts`, `autoRebaseStuck`, `configReloaded`. Sounds: the 14 built-ins listed under `available_sounds` (case-insensitive).

Notifications cascade — one fires only if `globalMute` is off, the global category toggle is on, **and** the per-event toggle is on. Omitted flags leave their stored value alone; every `--event-*` flag requires `--event`.

### Workspace Commands

Manage `AppConfig.workspaces` — the Settings → Workspaces tab as CLI verbs. `--workspace` takes a name (case-insensitive) or a workspace UUID.

```
crow workspace list                                      → {"workspaces":[...],"config_readable":bool}
crow workspace get --workspace <name|uuid>               → {"workspace":{...}}
crow workspace add --name NAME [field flags]             → {"workspace":{...},"saved":true}
crow workspace edit --workspace <name|uuid> [flags]      → patch; {"saved":false} when nothing changed (no write)
crow workspace remove --workspace <name|uuid> [--force]  → {"removed":true,"gateway_discarded":bool,...}
```

Field flags (shared by `add`/`edit`): `--provider github|gitlab`, `--host`, `--task-provider github|gitlab|jira|corveil`, `--jira-site`, `--jira-project-key`, `--jira-jql`, `--jira-status-{backlog,ready,in-progress,in-review,done}`, `--corveil-host`, `--custom-instructions[-file]`, `--always-include`, `--auto-review-repo`, `--exclude-review-repo`, `--session-env KEY=VALUE`, and `--clear-{always-include,auto-review-repos,exclude-review-repos,jira-status-map,session-env}`.

- **Clearing:** optional scalars clear with an empty string (`--host ""`); lists/maps need their `--clear-*` flag. `--jira-status-ready ""` clears one entry.
- **Repeatable flags replace the whole list**, they don't append — but `--jira-status-*` patches per key.
- **Renaming and removing are guarded.** Sessions are tied to a workspace only by their worktree path (`{devRoot}/{workspace}/...`) and jobs only by the name string, so both refuse while references exist; `--force` proceeds and reports `orphaned_sessions`/`orphaned_jobs`. Neither verb touches the filesystem — `remove` leaves the directory and returns `worktree_dir_kept`.
- A field the workspace never reads is rejected (`--host` on GitHub, `--jira-*` on a non-Jira workspace) rather than silently stored. `cli` is always derived from `--provider`.
- The per-workspace **AI gateway** is not settable here — it's local-only, so use `crow gateway` (below). Edits preserve it; `remove` discards it.

### Gateways & Secrets

Local-only (CROW-815) — these carry credentials, so the remote `/rpc` web path refuses them and only the local Unix socket works. Take exactly one target: `--manager` or `--workspace <name|uuid>`.

```
crow gateway get [--manager | --workspace <name|uuid>] [--reveal]        → {"gateway_set":true,"base_url":"...","headers":{...}}
crow gateway set --manager --base-url URL --header "Name: Value" ...     → {"saved":true,"gateway_set":true}
crow gateway clear --manager                                            → {"saved":true,"gateway_set":false}
crow web-password status                                                → {"password_set":true,"iterations":210000}
crow web-password set [--stdin]                                         → {"saved":true,"password_set":true}
crow web-password clear                                                 → {"saved":true,"password_set":false}
```

`gateway get` blanks header values unless `--reveal`. A `--header` with a blank value (`--header "X-Api-Key:"`) keeps the stored secret — that's how to change a base URL without restating credentials. `web-password set` prompts twice with echo off; pipe with `--stdin` for scripts. There is no `--password` flag on purpose (shell history / `ps`).

### Automation Commands

Settings → Automation as a CLI verb. Every `set` flag is a patch; passing none is an error.

```
crow automation get                                                     → {"automation":{toggles, auto_respond, defaults, config_readable}}
crow automation set [--remote-control-enabled true|false]
                    [--manager-auto-permission-mode true|false]         → needs `crow restart-manager`; returns "manager_restart_required"
                    [--review-auto-permission-mode true|false]
                    [--coder-view-auto-permission-mode true|false]
                    [--jobs-auto-permission-mode true|false]
                    [--attribution-trailers true|false]
                    [--auto-create-watcher-enabled true|false]
                    [--auto-merge-watcher-enabled true|false]
                    [--respond-to-changes-requested true|false]
                    [--respond-to-failed-checks true|false]
                    [--auto-re-request-review true|false]
                    [--auto-rebase-and-resolve-conflicts true|false]    → {"automation":{...},"restart_required":false,"manager_restart_required":bool}
```

Booleans take an explicit `true`/`false` — a bare flag can't express "leave alone", and six of these default to **on** (`manager`/`review`/`jobs` auto permission mode, `attribution-trailers`, `respond-to-changes-requested`, `auto-re-request-review`). `--jobs-auto-permission-mode` lives here even though the web UI puts it under the Jobs tab, so all five permission modes read and write as one group.

`--auto-re-request-review` (CROW-921) is the one auto-respond toggle that types nothing into a terminal: when a changes-requested PR's fix has landed and no review request is pending, the daemon runs `gh pr edit --add-reviewer` itself. That's deliberate — the PRs it rescues are exactly the ones no prompt can reach.

Everything applies within ~1 board poll (no `crowd` restart) — permission modes and `--remote-control-enabled` to newly launched sessions, `--attribution-trailers` to newly created worktrees. `--manager-auto-permission-mode` is the exception: it's baked into the Manager terminal's stored command, so a change returns `manager_restart_required: true` and needs `crow restart-manager`.

The Automation tab's three board-filter lists are `AppConfig.defaults` fields, so **`crow defaults set` writes them** (above) — one writer, one set of list semantics. `crow automation get` echoes them read-only under `defaults`, including the derived `effective_exclude_review_repos` (the global list unioned with every workspace's own, which is what the review board actually filters on), so the tab still reads as a whole from one call.

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
