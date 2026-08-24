<!-- Generated from ArgumentParser metadata by `crow generate-docs`. Do not edit by hand. -->
<!-- Regenerate with `make docs` after changing anything in Packages/CrowCLI/Sources/CrowCLILib/Commands/. -->

# `crow` CLI — generated reference

CLI for Crow — manage sessions, terminals, and metadata.

Every subcommand and flag the `crow` binary accepts, generated from the commands themselves so it cannot drift. For prose, worked examples, JSON response shapes and the gotchas that matter in practice, read [`cli-reference.md`](cli-reference.md) instead — this file is the exhaustive surface, that one is the guide.

`--help` is accepted everywhere and `crow --version` prints the build version; neither is repeated per command below. Commands marked **hidden** are omitted from `crow --help` but still work.

---

## Command index

| Command | Summary |
| --- | --- |
| [`crow add-link`](#crow-add-link) | Add a link to a session |
| [`crow add-merge-label`](#crow-add-merge-label) | Add the crow:merge label to the session's PR |
| [`crow add-worktree`](#crow-add-worktree) | Register a worktree for a session |
| [`crow agents`](#crow-agents) | Show and change which coding agent Crow launches |
| [`crow agents list`](#crow-agents-list) | Show known agents, the configured default, and the agent each role resolves to |
| [`crow agents set`](#crow-agents-set) | Change the default agent or a per-role override |
| [`crow automation`](#crow-automation) | View or change the automation settings |
| [`crow automation get`](#crow-automation-get) | Show the current automation settings |
| [`crow automation set`](#crow-automation-set) | Change the automation settings |
| [`crow autostart`](#crow-autostart) | Start crowd at login (install/uninstall/status) |
| [`crow autostart install`](#crow-autostart-install) | Register crowd to start at login (idempotent; re-points after an upgrade) |
| [`crow autostart status`](#crow-autostart-status) | Report whether crowd is set to start at login, and whether it's running |
| [`crow autostart uninstall`](#crow-autostart-uninstall) | Remove the login item (leaves a running crowd alone) |
| [`crow backfill`](#crow-backfill) | Reconcile and upload historical on-disk session transcripts |
| [`crow backfill scan`](#crow-backfill-scan) | List on-disk sessions with reconstructed metadata and upload status |
| [`crow backfill upload`](#crow-backfill-upload) | Upload selected historical sessions (idempotent) |
| [`crow batch-work-on-issues`](#crow-batch-work-on-issues) | Start working on several tickets in one batch |
| [`crow cleanup`](#crow-cleanup) | View or change automatic session cleanup |
| [`crow cleanup get`](#crow-cleanup-get) | Show the current cleanup settings |
| [`crow cleanup set`](#crow-cleanup-set) | Change automatic session cleanup |
| [`crow close-terminal`](#crow-close-terminal) | Close a terminal tab in a session |
| [`crow complete-session`](#crow-complete-session) | Mark a session completed |
| [`crow corveil`](#crow-corveil) | Verify the configured Corveil CLI binary, and reinstall its skill |
| [`crow corveil reinstall-skill`](#crow-corveil-reinstall-skill) | Reinstall every embedded slash command from the corveil binary |
| [`crow corveil verify`](#crow-corveil-verify) | Run `corveil --version` and report what came back |
| [`crow create-manager`](#crow-create-manager) | Create an additional Manager session |
| [`crow defaults`](#crow-defaults) | View or change workspace and automation defaults |
| [`crow defaults get`](#crow-defaults-get) | Show the current workspace and automation defaults |
| [`crow defaults set`](#crow-defaults-set) | Change workspace and automation defaults |
| [`crow delete-session`](#crow-delete-session) | Delete a session |
| [`crow edit-link`](#crow-edit-link) | Edit a link's label, URL, or type in place |
| [`crow gateway`](#crow-gateway) | Manage AI gateways (local-only) |
| [`crow gateway clear`](#crow-gateway-clear) | Remove a gateway |
| [`crow gateway get`](#crow-gateway-get) | Show a gateway's base URL and header names |
| [`crow gateway set`](#crow-gateway-set) | Set a gateway's base URL and headers |
| [`crow generate-docs`](#crow-generate-docs) | Regenerate the generated CLI reference from ArgumentParser metadata |
| [`crow get-scorecard`](#crow-get-scorecard) | Print the efficiency scorecard as JSON |
| [`crow get-session`](#crow-get-session) | Get session details |
| [`crow get-state`](#crow-get-state) | Print the daemon's full render-state snapshot as JSON |
| [`crow handoff-agent`](#crow-handoff-agent) | Switch a session to a different coding agent (e.g. when credits run out) |
| [`crow hook-event`](#crow-hook-event) | Forward an agent hook event to the app (reads JSON from stdin) |
| [`crow job`](#crow-job) | Manage scheduled jobs |
| [`crow job add`](#crow-job-add) | Create a job |
| [`crow job delete`](#crow-job-delete) | Delete a job |
| [`crow job disable`](#crow-job-disable) | Disable a job |
| [`crow job duplicate`](#crow-job-duplicate) | Duplicate a job (the copy starts disabled with a unique name) |
| [`crow job edit`](#crow-job-edit) | Update fields on an existing job |
| [`crow job enable`](#crow-job-enable) | Enable a job |
| [`crow job get`](#crow-job-get) | Show one job's full details |
| [`crow job list`](#crow-job-list) | List all jobs |
| [`crow job run`](#crow-job-run) | Run a job now, regardless of its schedule or enabled flag |
| [`crow launch-agent`](#crow-launch-agent) | Launch the session's coding agent in a ready terminal |
| [`crow list-allowlist`](#crow-list-allowlist) | List allowlist patterns and where each one is defined |
| [`crow list-artifacts`](#crow-list-artifacts) | List images an agent dropped in a session's artifacts directory |
| [`crow list-links`](#crow-list-links) | List links for a session |
| [`crow list-reviews`](#crow-list-reviews) | List requested PR reviews (with unseen count and loading state) |
| [`crow list-sessions`](#crow-list-sessions) | List all sessions |
| [`crow list-terminals`](#crow-list-terminals) | List terminals for a session |
| [`crow list-tickets`](#crow-list-tickets) | List the ticket board (issues, per-status counts, loading state) |
| [`crow list-worktrees`](#crow-list-worktrees) | List worktrees for a session |
| [`crow logsync`](#crow-logsync) | View or change session-log upload behavior knobs |
| [`crow logsync get`](#crow-logsync-get) | Show the session-log collector behavior knobs |
| [`crow logsync set`](#crow-logsync-set) | Change session-log upload behavior knobs |
| [`crow mark-in-review`](#crow-mark-in-review) | Move a session to In Review |
| [`crow mark-issue-done`](#crow-mark-issue-done) | Close the session's linked issue and complete the session |
| [`crow mcp`](#crow-mcp) | Serve Crow over MCP, and manage the tokens remote clients use |
| [`crow mcp serve`](#crow-mcp-serve) | Serve the read-only MCP surface over stdio (for a local client) |
| [`crow mcp token`](#crow-mcp-token) | Mint, list and revoke MCP bearer tokens (local-only) |
| [`crow mcp token list`](#crow-mcp-token-list) | List MCP bearer tokens (never the tokens themselves) |
| [`crow mcp token mint`](#crow-mcp-token-mint) | Mint a scoped MCP bearer token |
| [`crow mcp token revoke`](#crow-mcp-token-revoke) | Revoke an MCP bearer token |
| [`crow new-session`](#crow-new-session) | Create a new session |
| [`crow new-terminal`](#crow-new-terminal) | Create a terminal tab inside Crow (tmux) |
| [`crow notifications`](#crow-notifications) | Read and write notification settings |
| [`crow notifications get`](#crow-notifications-get) | Show notification settings |
| [`crow notifications set`](#crow-notifications-set) | Change notification settings |
| [`crow open-in-vscode`](#crow-open-in-vscode) | Open the session's worktree in VS Code on the host |
| [`crow open-terminal`](#crow-open-terminal) | Open a macOS Terminal.app window at the session's worktree (host GUI) |
| [`crow promote-allowlist`](#crow-promote-allowlist) | Copy worktree-local allowlist patterns into ~/.claude/settings.json |
| [`crow quick-action`](#crow-quick-action) | Dispatch a PR quick action into a session's agent terminal |
| [`crow rebuild-scorecard`](#crow-rebuild-scorecard) | Backfill analytics snapshots and recompute the scorecard |
| [`crow recreate-terminal`](#crow-recreate-terminal) | Recreate a terminal to restore full scrollback (CROW-804) |
| [`crow refresh-allowlist`](#crow-refresh-allowlist) | Re-scan global and worktree settings files for allowlist patterns |
| [`crow refresh-tickets`](#crow-refresh-tickets) | Re-poll the ticket provider now |
| [`crow reload-tmux-config`](#crow-reload-tmux-config) | Reload the bundled tmux config into the running server |
| [`crow remove-link`](#crow-remove-link) | Remove a link from a session |
| [`crow rename-session`](#crow-rename-session) | Rename a session |
| [`crow rename-terminal`](#crow-rename-terminal) | Rename a terminal tab |
| [`crow restart-manager`](#crow-restart-manager) | Relaunch the Manager's agent process in place |
| [`crow restart-tmux-server`](#crow-restart-tmux-server) | Restart the tmux server, rebuilding every terminal (destructive) |
| [`crow resync-jira`](#crow-resync-jira) | Re-sync Jira ticket statuses from Crow session state |
| [`crow retry-readiness`](#crow-retry-readiness) | Re-arm the readiness watch for a stuck terminal |
| [`crow select-session`](#crow-select-session) | Switch to a session |
| [`crow send`](#crow-send) | Send text to a terminal |
| [`crow set-goal`](#crow-set-goal) | Set or clear the org-goal tag on a session |
| [`crow set-locked`](#crow-set-locked) | Lock/unlock a session to protect it from auto-cleanup |
| [`crow set-pinned`](#crow-set-pinned) | Deprecated alias for set-locked |
| [`crow set-session-active`](#crow-set-session-active) | Return a session to active |
| [`crow set-status`](#crow-set-status) | Set session status |
| [`crow set-ticket`](#crow-set-ticket) | Set ticket metadata |
| [`crow setup`](#crow-setup) | First-time setup for Crow |
| [`crow start-review`](#crow-start-review) | Start a review session for a pull request |
| [`crow telemetry`](#crow-telemetry) | View or change session-analytics collection |
| [`crow telemetry get`](#crow-telemetry-get) | Show the current telemetry settings |
| [`crow telemetry set`](#crow-telemetry-set) | Change telemetry settings |
| [`crow terminal`](#crow-terminal) | View or change terminal wheel-scroll speed |
| [`crow terminal get`](#crow-terminal-get) | Show the current terminal wheel-scroll settings |
| [`crow terminal set`](#crow-terminal-set) | Change terminal wheel-scroll speed |
| [`crow transition-ticket`](#crow-transition-ticket) | Transition a session's ticket to a pipeline status |
| [`crow ui`](#crow-ui) | View or change UI display preferences |
| [`crow ui get`](#crow-ui-get) | Show the current UI display preferences |
| [`crow ui set`](#crow-ui-set) | Change UI display preferences |
| [`crow version`](#crow-version) | Show the local build and check for upstream updates |
| [`crow version check`](#crow-version-check) | Compare this build against corveil/crow main |
| [`crow version get`](#crow-version-get) | Show version-update settings and the cached check result |
| [`crow version set`](#crow-version-set) | Change version-update settings |
| [`crow web-password`](#crow-web-password) | Manage the web-access password (local-only) |
| [`crow web-password clear`](#crow-web-password-clear) | Remove the web-access password |
| [`crow web-password set`](#crow-web-password-set) | Set or change the web-access password |
| [`crow web-password status`](#crow-web-password-status) | Report whether a web-access password is set |
| [`crow work-on-issue`](#crow-work-on-issue) | Start working on a ticket (types /crow-workspace into the Manager) |
| [`crow workspace`](#crow-workspace) | Manage workspaces (Settings → Workspaces) |
| [`crow workspace add`](#crow-workspace-add) | Create a workspace |
| [`crow workspace edit`](#crow-workspace-edit) | Change fields on an existing workspace |
| [`crow workspace get`](#crow-workspace-get) | Show one workspace's full configuration |
| [`crow workspace list`](#crow-workspace-list) | List every configured workspace |
| [`crow workspace remove`](#crow-workspace-remove) | Delete a workspace from the configuration |

---

## `crow add-link`

Add a link to a session.

```
crow add-link --session <session> --label <label> --url <url> [--type <type>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--label` | `<label>` | yes | Link label |
| `--url` | `<url>` | yes | Link URL |
| `--type` | `<type>` | no | Link type: ticket, pr, repo, custom. Default: `custom`. |

---

## `crow add-merge-label`

Add the crow:merge label to the session's PR.

```
crow add-merge-label --session <session>
```

Requires a linked PR (attach one with `crow add-link --type pr --url …`) and a provider whose backend supports auto-merge labels.

The label is applied even when Crow's auto-merge watcher can't act on it (the watcher is off, or the repo has GitHub "Allow auto-merge" disabled). In that case the response carries an additional `warning` field explaining why nothing will merge; `ok` is still true, because the label did land.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow add-worktree`

Register a worktree for a session.

```
crow add-worktree --session <session> --repo <repo> --path <path> --branch <branch> [--repo-path <repo-path>] [--primary]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--repo` | `<repo>` | yes | Repo name |
| `--path` | `<path>` | yes | Worktree path |
| `--branch` | `<branch>` | yes | Branch name |
| `--repo-path` | `<repo-path>` | no | Main repo path (for git commands) |
| `--primary` | — | no | Mark as primary worktree |

---

## `crow agents`

Show and change which coding agent Crow launches.

```
crow agents <list|set>
```

Resolution is agentsByKind[<role>] falling back to defaultAgentKind. The four roles are work (coding sessions), review (PR reviews), job (scheduled jobs), and manager (the Manager session).

Only agents whose CLI binary crowd found at startup can be selected — run `crow agents list` for the set. Changes apply within about one board poll; no restart.

Subcommands: [`list`](#crow-agents-list), [`set`](#crow-agents-set).

---

## `crow agents list`

Show known agents, the configured default, and the agent each role resolves to.

```
crow agents list
```

`known` lists every agent Crow ships, each flagged `available` — an agent whose binary wasn't on PATH when crowd started is listed but not selectable, so it reads as "not installed" rather than vanishing. `default_agent_kind` and `by_kind` are what you configured; `effective` is what a new session of each role would get.

`config_readable` is false when config.json exists but could not be decoded — the values shown are then defaults, not your settings.

---

## `crow agents set`

Change the default agent or a per-role override.

```
crow agents set [--default <default>] [--work <work>] [--review <review>] [--job <job>] [--manager <manager>] [--clear <clear> ...]
```

Only the flags you pass change; at least one is required.

--clear <role> removes that role's override so the role falls back to the default; repeat the flag per role. Setting and clearing the same role in one call is rejected.

An agent kind that is not currently available is rejected and nothing is written — run `crow agents list` for the set. Note availability is decided when crowd starts, so a newly installed agent needs a daemon restart before it can be selected.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--default` | `<default>` | no | Agent for sessions with no per-role override |
| `--work` | `<work>` | no | Agent for new coding sessions |
| `--review` | `<review>` | no | Agent for PR-review sessions |
| `--job` | `<job>` | no | Agent for scheduled-job sessions |
| `--manager` | `<manager>` | no | Agent for the Manager session |
| `--clear` | `<clear>` _(repeatable)_ | no | Role whose override to remove, falling back to the default (repeatable). Values: `work`, `review`, `job`, `manager`. |

---

## `crow automation`

View or change the automation settings.

```
crow automation <get|set>
```

The Settings → Automation toggles: which sessions launch in auto permission mode, whether Crow watches for crow:auto / crow:merge labels, and whether it responds to changes-requested reviews and failed checks on your behalf.

--jobs-auto-permission-mode is included here so all five permission modes read and write as one group, even though the web UI renders that one under the Jobs tab.

The tab's three board-filter lists are `AppConfig.defaults` fields and are written by `crow defaults set`; `get` echoes them read-only here.

Subcommands: [`get`](#crow-automation-get), [`set`](#crow-automation-set).

---

## `crow automation get`

Show the current automation settings.

```
crow automation get
```

The `defaults` block is echoed read-only for context — write those three lists with `crow defaults set`. Within it, effective_exclude_review_repos is additionally *derived*: the global exclude list unioned with every workspace's own, which is what the review board actually filters on and is not stored anywhere as such.

config_readable is false when config.json exists but could not be decoded — the settings shown are then defaults, not what is on disk.

---

## `crow automation set`

Change the automation settings.

```
crow automation set [--remote-control-enabled <remote-control-enabled>] [--manager-auto-permission-mode <manager-auto-permission-mode>] [--review-auto-permission-mode <review-auto-permission-mode>] [--coder-view-auto-permission-mode <coder-view-auto-permission-mode>] [--jobs-auto-permission-mode <jobs-auto-permission-mode>] [--attribution-trailers <attribution-trailers>] [--auto-create-watcher-enabled <auto-create-watcher-enabled>] [--auto-merge-watcher-enabled <auto-merge-watcher-enabled>] [--respond-to-changes-requested <respond-to-changes-requested>] [--respond-to-failed-checks <respond-to-failed-checks>] [--auto-rebase-and-resolve-conflicts <auto-rebase-and-resolve-conflicts>] [--auto-re-request-review <auto-re-request-review>]
```

Only the flags you pass change; at least one is required.

Everything here is live within about one board poll (~60s) — the daemon re-reads config.json rather than holding a snapshot, so no crowd restart is needed. The permission modes and --remote-control-enabled apply to newly launched sessions, and --attribution-trailers to newly created worktrees; running sessions and existing worktrees are untouched.

--manager-auto-permission-mode is the one exception: it is baked into the Manager terminal's stored command, so it needs `crow restart-manager` (or an app relaunch) to take effect. A change to it returns "manager_restart_required": true.

The tab's three board-filter lists (excluded review repos, ignored review labels, excluded ticket repos) are `AppConfig.defaults` fields, so they belong to `crow defaults set` — one writer, one set of semantics. `crow automation get` echoes them read-only for context.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--remote-control-enabled` | `<remote-control-enabled>` | no | Launch new Claude Code sessions with --rc (true or false) |
| `--manager-auto-permission-mode` | `<manager-auto-permission-mode>` | no | Launch the Manager terminal in auto permission mode (true or false) |
| `--review-auto-permission-mode` | `<review-auto-permission-mode>` | no | Launch code-review sessions in auto permission mode (true or false) |
| `--coder-view-auto-permission-mode` | `<coder-view-auto-permission-mode>` | no | Launch new work coder views in auto permission mode (true or false) |
| `--jobs-auto-permission-mode` | `<jobs-auto-permission-mode>` | no | Run scheduled jobs in auto permission mode (true or false) |
| `--attribution-trailers` | `<attribution-trailers>` | no | Add a Crow-Session trailer to commits in new worktrees (true or false) |
| `--auto-create-watcher-enabled` | `<auto-create-watcher-enabled>` | no | Auto-launch a workspace for crow:auto labeled issues (true or false) |
| `--auto-merge-watcher-enabled` | `<auto-merge-watcher-enabled>` | no | Auto-merge Crow-authored PRs labeled crow:merge (true or false) |
| `--respond-to-changes-requested` | `<respond-to-changes-requested>` | no | Type a fix-it instruction into the session on a changes-requested review (true or false) |
| `--respond-to-failed-checks` | `<respond-to-failed-checks>` | no | Type a fix-it instruction into the session when CI checks fail (true or false) |
| `--auto-rebase-and-resolve-conflicts` | `<auto-rebase-and-resolve-conflicts>` | no | Rebase onto the base branch and force-with-lease push on conflict (true or false) |
| `--auto-re-request-review` | `<auto-re-request-review>` | no | Re-request review once a changes-requested PR's findings are addressed (true or false) |

---

## `crow autostart`

Start crowd at login (install/uninstall/status).

```
crow autostart [install|uninstall|status]
```

Subcommands: [`install`](#crow-autostart-install), [`uninstall`](#crow-autostart-uninstall), [`status`](#crow-autostart-status).

Bare `crow autostart` runs `status`.

---

## `crow autostart install`

Register crowd to start at login (idempotent; re-points after an upgrade).

```
crow autostart install [--binary <binary>] [--host <host>] [--port <port>] [--dev-root <dev-root>] [--socket <socket>] [--json]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--binary` | `<binary>` | no | Path to the crowd binary, launched at login as-is (default: next to this crow, then PATH) |
| `--host` | `<host>` | no | Bind host to pass to crowd (default: crowd's own default) |
| `--port` | `<port>` | no | HTTP port to pass to crowd |
| `--dev-root` | `<dev-root>` | no | Development root to pass to crowd |
| `--socket` | `<socket>` | no | Unix socket path to pass to crowd |
| `--json` | — | no | Print the status as JSON |

---

## `crow autostart status`

Report whether crowd is set to start at login, and whether it's running.

```
crow autostart status [--binary <binary>] [--socket <socket>] [--json]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--binary` | `<binary>` | no | Path to the crowd binary to compare against (stale-plist detection) |
| `--socket` | `<socket>` | no | Unix socket to probe for a running crowd (default: the login item's, else the well-known socket) |
| `--json` | — | no | Print the status as JSON |

---

## `crow autostart uninstall`

Remove the login item (leaves a running crowd alone).

```
crow autostart uninstall [--json]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--json` | — | no | Print the status as JSON |

---

## `crow backfill`

Reconcile and upload historical on-disk session transcripts.

```
crow backfill <scan|upload>
```

Scans the coding-session transcripts already on disk (Claude Code under ~/.claude/projects, Codex under ~/.codex/sessions, and Grok Build under ~/.grok/sessions), reconstructs each one's workspace, repo, and ticket/PR, and uploads the ones you choose to Corveil as session artifacts — so a backfilled session lands in the ontology indistinguishable from a live-captured one.

A reconstructed ticket becomes a link only when the provider confirms it exists; otherwise the session uploads repo-only, and a true orphan uploads attributed but unlinked. Uploads reuse the named workspace's AI gateway for the destination and credential (no AWS credentials on this machine) and are idempotent — re-running never duplicates.

Subcommands: [`scan`](#crow-backfill-scan), [`upload`](#crow-backfill-upload).

---

## `crow backfill scan`

List on-disk sessions with reconstructed metadata and upload status.

```
crow backfill scan
```

Disk- and git-only (no provider calls), so it's fast over hundreds of sessions. Each row carries the recovered workspace/repo/ticket, a confidence tier (high = repo + ticket, medium = repo only, low = orphan), and its ledger upload status. Ticket links are validated at upload, not here.

---

## `crow backfill upload`

Upload selected historical sessions (idempotent).

```
crow backfill upload --workspace <workspace> [--session <session> ...] [--all-high-confidence] [--all]
```

Choose sessions with repeated --session <uid> (UIDs come from `crow backfill scan`), or bulk-select this workspace's history with --all-high-confidence (repo + validated ticket) or --all. Exactly one selection mode is required.

--workspace names the workspace whose AI gateway supplies the upload destination and credential; it must have a gateway configured. Uploads are serial and idempotent, so a re-run only fills gaps.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--workspace` | `<workspace>` | yes | Workspace whose gateway supplies the upload destination + credential |
| `--session` | `<session>` _(repeatable)_ | no | A session UID to upload (repeatable; Claude Code, Codex, or Grok Build — UIDs come from `crow backfill scan`). Mutually exclusive with --all/--all-high-confidence. |
| `--all-high-confidence` | — | no | Upload every not-yet-uploaded high-confidence session in this workspace |
| `--all` | — | no | Upload every not-yet-uploaded session in this workspace |

---

## `crow batch-work-on-issues`

Start working on several tickets in one batch.

```
crow batch-work-on-issues [--url <url> ...] [--urls-file <urls-file>]
```

URLs are sent in order: every --url first, then the lines of --urls-file. Malformed URLs are not rejected locally — the daemon drops them into the `rejected` array and starts the rest, so one bad ticket can't block the batch.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--url` | `<url>` _(repeatable)_ | no | Ticket / issue URL (repeatable) |
| `--urls-file` | `<urls-file>` | no | Read newline-delimited URLs from a file; '-' reads stdin |

---

## `crow cleanup`

View or change automatic session cleanup.

```
crow cleanup <get|set>
```

Subcommands: [`get`](#crow-cleanup-get), [`set`](#crow-cleanup-set).

---

## `crow cleanup get`

Show the current cleanup settings.

```
crow cleanup get
```

---

## `crow cleanup set`

Change automatic session cleanup.

```
crow cleanup set [--enabled <enabled>] [--retention-hours <retention-hours>]
```

Only the flags you pass change; at least one is required.

Auto-cleanup deletes completed and archived sessions after the retention period, including their worktree and branch. Manager, virtual, and locked sessions are never deleted.

This setting is live: the board poll re-reads it from disk each cycle, so enabling it starts deleting eligible sessions within about a minute. No restart, and no confirmation prompt.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--enabled` | `<enabled>` | no | Enable auto-cleanup (true or false) |
| `--retention-hours` | `<retention-hours>` | no | Hours to keep completed/archived sessions (minimum 1, default 24) |

---

## `crow close-terminal`

Close a terminal tab in a session.

```
crow close-terminal --session <session> --terminal <terminal>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--terminal` | `<terminal>` | yes | Terminal UUID |

---

## `crow complete-session`

Mark a session completed.

```
crow complete-session --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow corveil`

Verify the configured Corveil CLI binary, and reinstall its skill.

```
crow corveil <verify|reinstall-skill>
```

Subcommands: [`verify`](#crow-corveil-verify), [`reinstall-skill`](#crow-corveil-reinstall-skill).

---

## `crow corveil reinstall-skill`

Reinstall every embedded slash command from the corveil binary.

```
crow corveil reinstall-skill [--path <path>]
```

Re-runs the `corveil skill install` that `crowd` runs at launch, writing every embedded skill the binary ships (`corveil skill list`) into `{devRoot}/.claude/commands/` — one `<skill>.md` per skill. Use it after rebuilding corveil locally to pick up its new embedded skills without restarting the daemon. `skill_path` in the response is that directory.

A run also updates the launch-time corveil warning: succeeding clears it, a per-skill failure replaces it, so there is one answer to "is corveil broken?" rather than a startup one and a button one.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--path` | `<path>` | no | Binary to act on. Defaults to the path in Settings → General → Corveil CLI. |

---

## `crow corveil verify`

Run `corveil --version` and report what came back.

```
crow corveil verify [--path <path>]
```

Prints `{"ok": true|false, "message": "…", "path": "…"}`. Branch on `ok`, not on the exit code — a corveil that is missing, not executable, exits non-zero, or hangs past 5s is a successful *report* of a broken binary.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--path` | `<path>` | no | Binary to act on. Defaults to the path in Settings → General → Corveil CLI. |

---

## `crow create-manager`

Create an additional Manager session.

```
crow create-manager [--agent <agent>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--agent` | `<agent>` | no | Coding agent kind (claude-code, cursor, codex, opencode, antigravity, grok, muse); default agent when omitted |

---

## `crow defaults`

View or change workspace and automation defaults.

```
crow defaults <get|set>
```

These are the `defaults` block of config.json: the forge provider and CLI used for new workspaces, the branch prefix for new session branches, the repo/label lists that filter the review and ticket boards, and the binary path overrides.

Subcommands: [`get`](#crow-defaults-get), [`set`](#crow-defaults-set).

---

## `crow defaults get`

Show the current workspace and automation defaults.

```
crow defaults get
```

Echoes the whole defaults block, including `exclude_dirs` and `mirror_claude_mcp_to_codex`, which `set` does not write — neither has a Settings UI either, and omitting them would make this a worse answer to "what is my config?".

`config_readable` is false when config.json exists but could not be decoded: the values shown are then the built-in defaults rather than yours, which matters when you are working out why a filter isn't firing.

---

## `crow defaults set`

Change workspace and automation defaults.

```
crow defaults set [--provider <provider>] [--cli <cli>] [--branch-prefix <branch-prefix>] [--binary <binary> ...] [--add-exclude-review-repo <add-exclude-review-repo> ...] [--remove-exclude-review-repo <remove-exclude-review-repo> ...] [--clear-exclude-review-repos] [--add-exclude-ticket-repo <add-exclude-ticket-repo> ...] [--remove-exclude-ticket-repo <remove-exclude-ticket-repo> ...] [--clear-exclude-ticket-repos] [--add-ignore-review-label <add-ignore-review-label> ...] [--remove-ignore-review-label <remove-ignore-review-label> ...] [--clear-ignore-review-labels]
```

Only the flags you pass change; at least one is required.

Most of these are live. The provider and CLI are re-read on each repo scan, the board lists are re-read on each board poll (about a minute), and the branch prefix is read when a workspace is created. --binary is the exception: agent binary discovery and the .claude/bin symlinks are both set up at startup, so a change there returns "restart_required" and needs a crowd restart — including when you remove one, since the stale symlink keeps shadowing PATH until then.

--provider and --cli are stored independently and neither implies the other, matching how GitManager reads them; setting only one warns if the resulting pair is crossed.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--provider` | `<provider>` | no | Forge for new workspaces (github or gitlab) |
| `--cli` | `<cli>` | no | Forge CLI for new workspaces (gh or glab) |
| `--branch-prefix` | `<branch-prefix>` | no | Prefix for new session branches, e.g. 'feature/' (empty for none) |
| `--binary` | `<binary>` _(repeatable)_ | no | Binary path override as NAME=PATH, e.g. corveil=/opt/corveil/bin/corveil; NAME= removes it (repeatable) |
| `--add-exclude-review-repo` | `<add-exclude-review-repo>` _(repeatable)_ | no | Repo to hide from the review board; supports one wildcard, e.g. 'owner/*' (repeatable) |
| `--remove-exclude-review-repo` | `<remove-exclude-review-repo>` _(repeatable)_ | no | Repo to stop hiding from the review board (repeatable) |
| `--clear-exclude-review-repos` | — | no | Empty the review-board repo exclusions |
| `--add-exclude-ticket-repo` | `<add-exclude-ticket-repo>` _(repeatable)_ | no | Repo to hide from the ticket board; supports one wildcard (repeatable) |
| `--remove-exclude-ticket-repo` | `<remove-exclude-ticket-repo>` _(repeatable)_ | no | Repo to stop hiding from the ticket board (repeatable) |
| `--clear-exclude-ticket-repos` | — | no | Empty the ticket-board repo exclusions |
| `--add-ignore-review-label` | `<add-ignore-review-label>` _(repeatable)_ | no | PR label that hides a review from the board; exact match, no wildcards (repeatable) |
| `--remove-ignore-review-label` | `<remove-ignore-review-label>` _(repeatable)_ | no | PR label to stop ignoring (repeatable) |
| `--clear-ignore-review-labels` | — | no | Empty the ignored review labels |

---

## `crow delete-session`

Delete a session.

```
crow delete-session --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow edit-link`

Edit a link's label, URL, or type in place.

```
crow edit-link --session <session> [--id <id>] [--url <url>] [--label <label>] [--new-url <new-url>] [--type <type>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--id` | `<id>` | no | Link ID (from list-links) |
| `--url` | `<url>` | no | Current link URL to match (alternative to --id) |
| `--label` | `<label>` | no | New label |
| `--new-url` | `<new-url>` | no | New URL |
| `--type` | `<type>` | no | New link type: ticket, pr, repo, custom |

---

## `crow gateway`

Manage AI gateways (local-only).

```
crow gateway <get|set|clear>
```

Subcommands: [`get`](#crow-gateway-get), [`set`](#crow-gateway-set), [`clear`](#crow-gateway-clear).

---

## `crow gateway clear`

Remove a gateway.

```
crow gateway clear [--manager] [--workspace <workspace>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--manager` | — | no | Target the Manager AI gateway |
| `--workspace` | `<workspace>` | no | Target a workspace's AI gateway (workspace name or UUID) |

---

## `crow gateway get`

Show a gateway's base URL and header names.

```
crow gateway get [--manager] [--workspace <workspace>] [--reveal]
```

Header values are blanked by default so the output is safe to share. Pass --reveal to print the stored values (which may be op:// references rather than the secrets themselves).

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--manager` | — | no | Target the Manager AI gateway |
| `--workspace` | `<workspace>` | no | Target a workspace's AI gateway (workspace name or UUID) |
| `--reveal` | — | no | Print header values instead of blanking them |

---

## `crow gateway set`

Set a gateway's base URL and headers.

```
crow gateway set [--manager] [--workspace <workspace>] --base-url <base-url> [--header <header> ...]
```

Replaces the whole gateway: --base-url and at least one --header are both required (a gateway needs both, or neither). A --header with a blank value keeps the secret already stored under that name, so the base URL can be changed without restating credentials:

```
crow gateway set --manager --base-url https://gw.example.com --header "X-Api-Key:"
```

Header values may be op:// 1Password references, resolved at agent launch so the secret never rests in config.json.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--manager` | — | no | Target the Manager AI gateway |
| `--workspace` | `<workspace>` | no | Target a workspace's AI gateway (workspace name or UUID) |
| `--base-url` | `<base-url>` | yes | Gateway base URL |
| `--header` | `<header>` _(repeatable)_ | no | Header as 'Name: Value' (repeatable) |

---

## `crow generate-docs`

Regenerate the generated CLI reference from ArgumentParser metadata.

**Hidden** — not listed in `crow --help`.

```
crow generate-docs [--output <output>] [--check]
```

Writes every subcommand and flag the binary accepts to docs/cli.md. Run it after adding or changing a command; `make docs` does exactly this. Use --check in a script to assert the committed file is current without writing anything — it exits non-zero when the file is stale or missing.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--output` | `<output>` | no | Path to write (default: docs/cli.md, relative to the current directory) |
| `--check` | — | no | Verify the file on disk instead of writing it; exits non-zero when stale |

---

## `crow get-scorecard`

Print the efficiency scorecard as JSON.

```
crow get-scorecard
```

Grade, weekly rollups, baseline medians, and per-session rows. Grading runs daemon-side so the CLI, web, and desktop can never drift. With telemetry off the result is an empty shell — check telemetryEnabled and snapshotCount. All timestamps are epoch milliseconds.

---

## `crow get-session`

Get session details.

```
crow get-session --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow get-state`

Print the daemon's full render-state snapshot as JSON.

```
crow get-state
```

Sessions, terminals, worktrees, links, PR status, review requests, assigned issues, allowlist entries, and config (credentials stripped). This is the whole snapshot in one call and it is large — prefer list-sessions / get-session / list-links when you want one slice.

---

## `crow handoff-agent`

Switch a session to a different coding agent (e.g. when credits run out).

```
crow handoff-agent --session <session> --agent <agent> [--note <note>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--agent` | `<agent>` | yes | Target agent kind (claude-code, cursor, codex, opencode, grok, antigravity, muse) |
| `--note` | `<note>` | no | Optional note for the incoming agent about where to resume |

---

## `crow hook-event`

Forward an agent hook event to the app (reads JSON from stdin).

```
crow hook-event [--session <session>] --event <event> [--agent <agent>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | no | Session UUID (omit to resolve from payload cwd) |
| `--event` | `<event>` | yes | Event name (e.g., Stop, Notification, PreToolUse) |
| `--agent` | `<agent>` | no | Agent kind (e.g., claude-code, codex). Defaults to the session's stored agent. |

---

## `crow job`

Manage scheduled jobs.

```
crow job <list|get|add|edit|enable|disable|run|delete|duplicate>
```

Subcommands: [`list`](#crow-job-list), [`get`](#crow-job-get), [`add`](#crow-job-add), [`edit`](#crow-job-edit), [`enable`](#crow-job-enable), [`disable`](#crow-job-disable), [`run`](#crow-job-run), [`delete`](#crow-job-delete), [`duplicate`](#crow-job-duplicate).

---

## `crow job add`

Create a job.

```
crow job add --name <name> --workspace <workspace> --repo <repo> [--prompt <prompt> ...] [--prompt-file <prompt-file> ...] [--interval-seconds <interval-seconds>] [--daily-at <daily-at>] [--weekdays <weekdays>] [--disabled]
```

Prompts are sent in order: every --prompt first, then the contents of every --prompt-file. Exactly one schedule is required: --interval-seconds or --daily-at HH:MM (optionally restricted with --weekdays).

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--name` | `<name>` | yes | Job name (must be unique) |
| `--workspace` | `<workspace>` | yes | Workspace name (folder under the dev root) |
| `--repo` | `<repo>` | yes | Repository slug (owner/repo) |
| `--prompt` | `<prompt>` _(repeatable)_ | no | Prompt text (repeatable; sent in order) |
| `--prompt-file` | `<prompt-file>` _(repeatable)_ | no | Read a prompt from a file; '-' reads stdin (repeatable) |
| `--interval-seconds` | `<interval-seconds>` | no | Run every N seconds |
| `--daily-at` | `<daily-at>` | no | Run daily at HH:MM (24-hour, local time) |
| `--weekdays` | `<weekdays>` | no | Comma-separated weekdays for --daily-at (sun,mon,… or 1-7); omit for every day |
| `--disabled` | — | no | Create the job disabled |

---

## `crow job delete`

Delete a job.

```
crow job delete --id <id>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | yes | Job UUID |

---

## `crow job disable`

Disable a job.

```
crow job disable --id <id>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | yes | Job UUID |

---

## `crow job duplicate`

Duplicate a job (the copy starts disabled with a unique name).

```
crow job duplicate --id <id>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | yes | Job UUID |

---

## `crow job edit`

Update fields on an existing job.

```
crow job edit --id <id> [--name <name>] [--workspace <workspace>] [--repo <repo>] [--prompt <prompt> ...] [--prompt-file <prompt-file> ...] [--interval-seconds <interval-seconds>] [--daily-at <daily-at>] [--weekdays <weekdays>]
```

Only the provided flags change; everything else keeps its value. Any --prompt/--prompt-file replaces the job's whole prompt list, and any schedule flag replaces the whole schedule — so changing --weekdays requires restating --daily-at. Use enable/disable to toggle the enabled flag.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | yes | Job UUID |
| `--name` | `<name>` | no | New job name (must be unique) |
| `--workspace` | `<workspace>` | no | New workspace name |
| `--repo` | `<repo>` | no | New repository slug (owner/repo) |
| `--prompt` | `<prompt>` _(repeatable)_ | no | Replacement prompt text (repeatable; replaces all prompts) |
| `--prompt-file` | `<prompt-file>` _(repeatable)_ | no | Read a replacement prompt from a file; '-' reads stdin (repeatable) |
| `--interval-seconds` | `<interval-seconds>` | no | Run every N seconds |
| `--daily-at` | `<daily-at>` | no | Run daily at HH:MM (24-hour, local time) |
| `--weekdays` | `<weekdays>` | no | Comma-separated weekdays for --daily-at (sun,mon,… or 1-7); omit for every day |

---

## `crow job enable`

Enable a job.

```
crow job enable --id <id>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | yes | Job UUID |

---

## `crow job get`

Show one job's full details.

```
crow job get --id <id>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | yes | Job UUID |

---

## `crow job list`

List all jobs.

```
crow job list
```

---

## `crow job run`

Run a job now, regardless of its schedule or enabled flag.

```
crow job run --id <id>
```

Returns the launched session and terminal ids. The run continues in the app even if the CLI times out waiting (e.g. while a repo is cloned on demand).

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | yes | Job UUID |

---

## `crow launch-agent`

Launch the session's coding agent in a ready terminal.

```
crow launch-agent --terminal <terminal>
```

Takes only `--terminal` — the terminal id alone identifies the surface, so unlike `new-terminal` / `send` there is no `--session` flag.

The daemon applies this only to a terminal that is shell-ready and still pending auto-launch; in any other state it is a no-op. `{"ok": true}` means the request was accepted, not that an agent was started.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--terminal` | `<terminal>` | yes | Terminal UUID |

---

## `crow list-allowlist`

List allowlist patterns and where each one is defined.

```
crow list-allowlist
```

Reads the daemon's last scan rather than re-reading disk — run refresh-allowlist first if a settings file changed underneath it.

---

## `crow list-artifacts`

List images an agent dropped in a session's artifacts directory.

```
crow list-artifacts --session <session>
```

Each image reports an absolute on-disk path plus a url that only resolves against the daemon's own web server. The directory is the one agents see as $CROW_ARTIFACTS_DIR; it lives under $TMPDIR and does not survive a reboot.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow list-links`

List links for a session.

```
crow list-links --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow list-reviews`

List requested PR reviews (with unseen count and loading state).

```
crow list-reviews
```

---

## `crow list-sessions`

List all sessions.

```
crow list-sessions
```

---

## `crow list-terminals`

List terminals for a session.

```
crow list-terminals --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow list-tickets`

List the ticket board (issues, per-status counts, loading state).

```
crow list-tickets
```

---

## `crow list-worktrees`

List worktrees for a session.

```
crow list-worktrees --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow logsync`

View or change session-log upload behavior knobs.

```
crow logsync <get|set>
```

The session-log collector uploads each opted-in workspace's coding-session transcripts to Corveil as session artifacts, reusing that workspace's AI gateway for the destination and credential (no AWS credentials are stored on this machine). Opt a workspace in with `crow workspace edit --workspace NAME --upload-session-logs true` (or the Settings → Workspaces checkbox); it uploads once it also has a gateway.

These verbs tune only global behavior — ledger retention, the quiet period before a transcript is captured, and the per-upload size cap. Uploads are best-effort and never block or fail a session. Claude Code, Codex, and Grok Build transcripts are collected today (CROW-1089, CROW-1098); other harnesses are wired as their on-disk log locations are confirmed.

Subcommands: [`get`](#crow-logsync-get), [`set`](#crow-logsync-set).

---

## `crow logsync get`

Show the session-log collector behavior knobs.

```
crow logsync get
```

---

## `crow logsync set`

Change session-log upload behavior knobs.

```
crow logsync set [--retention-days <retention-days>] [--quiet-period-minutes <quiet-period-minutes>] [--max-upload-bytes <max-upload-bytes>]
```

Only the flags you pass change; at least one is required.

Opt a workspace in (and set its gateway) elsewhere — with `crow workspace edit --upload-session-logs true` and `crow gateway set`. These flags only tune collector behavior.

Live: the collector re-reads config each tick, so changes apply within a few minutes with no restart.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--retention-days` | `<retention-days>` | no | Days to keep the local upload ledger (0 = forever, default 30) |
| `--quiet-period-minutes` | `<quiet-period-minutes>` | no | Wait this long after a session's last activity before uploading (default 30) |
| `--max-upload-bytes` | `<max-upload-bytes>` | no | Per-transcript upload cap in bytes (default 8000000) |

---

## `crow mark-in-review`

Move a session to In Review.

```
crow mark-in-review --session <session>
```

Moves the session's linked ticket to In Review on the provider's board (GitHub Projects, Jira workflow), then sets the session's status. Requires a linked ticket (attach one with `crow set-ticket --url …`).

Fails without moving the session if the board transition fails. When the provider has no In Review status to move to — GitLab, or a board whose column isn't named "In Review" — the session still moves and the result carries an additive `warning` saying the ticket did not.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow mark-issue-done`

Close the session's linked issue and complete the session.

```
crow mark-issue-done --session <session>
```

GitHub/GitLab close the issue; Jira transitions it to the mapped done status. On success the session flips to completed. Requires a linked ticket and a provider-configured daemon.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow mcp`

Serve Crow over MCP, and manage the tokens remote clients use.

```
crow mcp <serve|token>
```

Subcommands: [`serve`](#crow-mcp-serve), [`token`](#crow-mcp-token).

---

## `crow mcp serve`

Serve the read-only MCP surface over stdio (for a local client).

```
crow mcp serve [--scope <scope> ...]
```

Speaks MCP on stdin/stdout and forwards each tool call to the running `crowd` over its Unix socket. Point a local MCP client at it:

```
{"mcpServers": {"crow": {"command": "crow", "args": ["mcp", "serve"]}}}
```

No token is needed. The socket is 0600 and reachable only from this machine, so a caller that can run this command could already run every other `crow` verb — a token would gate nothing. Remote clients use `POST /mcp` with a token from `crow mcp token mint` instead.

The surface is read-only either way, and identical: six tools over five read RPCs. This command cannot send prompts, create sessions, or write anything.

Unlike every other `crow` verb, stdout here carries framed JSON-RPC rather than one JSON object — it is a transport, not a query. Diagnostics go to stderr.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--scope` | `<scope>` _(repeatable)_ | no | Limit the served tools to these scopes (repeatable). Defaults to all read scopes: board:read, sessions:read. |

---

## `crow mcp token`

Mint, list and revoke MCP bearer tokens (local-only).

```
crow mcp token <list|mint|revoke>
```

Subcommands: [`list`](#crow-mcp-token-list), [`mint`](#crow-mcp-token-mint), [`revoke`](#crow-mcp-token-revoke).

---

## `crow mcp token list`

List MCP bearer tokens (never the tokens themselves).

```
crow mcp token list
```

---

## `crow mcp token mint`

Mint a scoped MCP bearer token.

```
crow mcp token mint --name <name> [--scope <scope> ...] [--expires-in <expires-in>] [--no-expiry]
```

Prints the token once. It is stored only as a SHA-256 hash, so it cannot be recovered — losing it means minting another and revoking this one.

```
crow mcp token mint --name grok-bot --scope board:read
```

Expiry defaults to 90 days. Pass --expires-in to choose another, or --no-expiry for a token that never expires — which has to be typed, because an off-box credential that never lapses is a decision, not a default.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--name` | `<name>` | yes | A label for this token, e.g. "grok-bot" |
| `--scope` | `<scope>` _(repeatable)_ | no | Capability to grant (repeatable). One of: board:read, sessions:read. |
| `--expires-in` | `<expires-in>` | no | Lifetime — a number with a unit: s (seconds), m (minutes), h (hours), d (days), w (weeks) — e.g. 90d. Defaults to 90d. |
| `--no-expiry` | — | no | Mint a token that never expires (mutually exclusive with --expires-in) |

---

## `crow mcp token revoke`

Revoke an MCP bearer token.

```
crow mcp token revoke [--id <id>] [--name <name>]
```

Revoke by --id (from `crow mcp token list`), or by --name when only one token carries that name. An ambiguous name is refused rather than guessed.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--id` | `<id>` | no | Token UUID, from `crow mcp token list` |
| `--name` | `<name>` | no | Token name, when it is unambiguous |

---

## `crow new-session`

Create a new session.

```
crow new-session --name <name> [--kind <kind>] [--agent <agent>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--name` | `<name>` | yes | Session name |
| `--kind` | `<kind>` | no | Session kind: work (default) or manager |
| `--agent` | `<agent>` | no | Agent kind (e.g. claude-code). Defaults to the configured default agent. |

---

## `crow new-terminal`

Create a terminal tab inside Crow (tmux).

```
crow new-terminal --session <session> --cwd <cwd> [--name <name>] [--command <command>] [--managed]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--cwd` | `<cwd>` | yes | Working directory |
| `--name` | `<name>` | no | Terminal name |
| `--command` | `<command>` | no | Command to run |
| `--managed` | — | no | Mark as managed Claude Code terminal |

---

## `crow notifications`

Read and write notification settings.

```
crow notifications <get|set>
```

Notifications cascade: a notification fires only if globalMute is off, the matching global category toggle is on, AND the per-event toggle is on. Global flags apply to every event; the --event-* flags apply to the single event named by --event.

Subcommands: [`get`](#crow-notifications-get), [`set`](#crow-notifications-set).

---

## `crow notifications get`

Show notification settings.

```
crow notifications get [--event <event>]
```

Lists the global toggles, every event's effective settings, and the built-in sound names. Events absent from config.json are reported with the defaults they will actually fire with. --event narrows the event list to one entry; the global toggles are always included, since they can be the reason an event never fires.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--event` | `<event>` | no | Restrict the event list to one event. Values: `taskComplete`, `agentWaiting`, `reviewRequested`, `changesRequested`, `checksFailing`, `autoWorkspaceCreated`, `autoMergeEnabled`, `autoMergeBlocked`, `autoRebasePushed`, `autoRebaseConflicts`, `autoRebaseStuck`, `configReloaded`. |

---

## `crow notifications set`

Change notification settings.

```
crow notifications set [--global-mute|--no-global-mute] [--sound-enabled|--no-sound-enabled] [--system-notifications-enabled|--no-system-notifications-enabled] [--event <event>] [--event-enabled|--no-event-enabled] [--event-sound-enabled|--no-event-sound-enabled] [--event-system-notification-enabled|--no-event-system-notification-enabled] [--event-sound-name <event-sound-name>]
```

Only the provided flags change; everything else keeps its value. Each toggle takes a --flag / --no-flag pair. The --event-* flags require --event and apply to that event alone. --event-sound-name accepts the built-in sounds listed by `crow notifications get` (case-insensitive).

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--global-mute`, `--no-global-mute` | — | no | Master mute — suppresses every sound and system notification |
| `--sound-enabled`, `--no-sound-enabled` | — | no | Global sound-playback toggle |
| `--system-notifications-enabled`, `--no-system-notifications-enabled` | — | no | Global system-notification toggle |
| `--event` | `<event>` | no | Event to change (required by every --event-* flag). Values: `taskComplete`, `agentWaiting`, `reviewRequested`, `changesRequested`, `checksFailing`, `autoWorkspaceCreated`, `autoMergeEnabled`, `autoMergeBlocked`, `autoRebasePushed`, `autoRebaseConflicts`, `autoRebaseStuck`, `configReloaded`. |
| `--event-enabled`, `--no-event-enabled` | — | no | Whether this event notifies at all |
| `--event-sound-enabled`, `--no-event-sound-enabled` | — | no | Whether this event plays a sound |
| `--event-system-notification-enabled`, `--no-event-system-notification-enabled` | — | no | Whether this event posts a system notification |
| `--event-sound-name` | `<event-sound-name>` | no | Sound for this event (a built-in sound name) |

---

## `crow open-in-vscode`

Open the session's worktree in VS Code on the host.

```
crow open-in-vscode --session <session>
```

Launches the `code` CLI at the session's primary worktree. Requires that CLI on PATH (or in a standard VS Code install location) and a worktree attached to the session.

Host-app launches are restricted to local callers; the CLI qualifies, since it talks to the daemon over its Unix socket.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow open-terminal`

Open a macOS Terminal.app window at the session's worktree (host GUI).

```
crow open-terminal --session <session>
```

This is NOT a Crow terminal tab — it opens Terminal.app on the daemon host, cd'd to the session's primary worktree. Use `new-terminal` to create a tab inside Crow.

macOS only. Host-app launches are restricted to local callers; the CLI qualifies, since it talks to the daemon over its Unix socket.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow promote-allowlist`

Copy worktree-local allowlist patterns into ~/.claude/settings.json.

```
crow promote-allowlist [--pattern <pattern> ...]
```

Patterns already in the global file are reported under already_global and left alone. Quote patterns — parentheses and '*' are shell metacharacters: --pattern 'Bash(npm test:*)'.

Promote everything not yet global:
```
crow list-allowlist | jq -r '.entries[] | select(.is_global | not) | "--pattern", .pattern' | xargs crow promote-allowlist
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--pattern` | `<pattern>` _(repeatable)_ | no | Allowlist pattern to promote, e.g. 'Bash(npm test:*)' (repeatable) |

---

## `crow quick-action`

Dispatch a PR quick action into a session's agent terminal.

```
crow quick-action --session <session> --action <action>
```

A skipped dispatch is reported as {"dispatched": false, "reason": "…"} with a zero exit code — the RPC succeeded, the session just had no terminal to send to (or no linked PR). Check `dispatched` rather than the exit code.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--action` | `<action>` | yes | Action: fixConflicts, addressChanges, fixChecks, mergePR, reReview |

---

## `crow rebuild-scorecard`

Backfill analytics snapshots and recompute the scorecard.

```
crow rebuild-scorecard
```

Idempotent, and overlapping callers coalesce into one rebuild. Errors when telemetry is disabled — there is no database to rebuild from.

---

## `crow recreate-terminal`

Recreate a terminal to restore full scrollback (CROW-804).

```
crow recreate-terminal --session <session> --terminal <terminal>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--terminal` | `<terminal>` | yes | Terminal UUID |

---

## `crow refresh-allowlist`

Re-scan global and worktree settings files for allowlist patterns.

```
crow refresh-allowlist
```

---

## `crow refresh-tickets`

Re-poll the ticket provider now.

```
crow refresh-tickets
```

---

## `crow reload-tmux-config`

Reload the bundled tmux config into the running server.

```
crow reload-tmux-config
```

Runs `tmux source-file` against the bundled crow-tmux.conf. Non-destructive: windows, sessions, and running agents are unaffected. Errors if the tmux server isn't running or the bundled config is missing.

---

## `crow remove-link`

Remove a link from a session.

```
crow remove-link --session <session> [--id <id>] [--url <url>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--id` | `<id>` | no | Link ID (from list-links) |
| `--url` | `<url>` | no | Link URL (alternative to --id) |

---

## `crow rename-session`

Rename a session.

```
crow rename-session --session <session> <name>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| _(positional)_ | `<name>` | yes | New name |

---

## `crow rename-terminal`

Rename a terminal tab.

```
crow rename-terminal --session <session> --terminal <terminal> <name>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--terminal` | `<terminal>` | yes | Terminal UUID |
| _(positional)_ | `<name>` | yes | New name |

---

## `crow restart-manager`

Relaunch the Manager's agent process in place.

```
crow restart-manager
```

Tears down the Manager's dead terminal surface and recreates a fresh one (new terminal UUID) with the current remote-control / auto-permission args. The Manager session row and its id are preserved.

Only the primary Manager session is restarted — secondary Managers are untouched.

---

## `crow restart-tmux-server`

Restart the tmux server, rebuilding every terminal (destructive).

```
crow restart-tmux-server
```

Kills the shared tmux server — every agent in every session dies — then relaunches each persisted terminal (the Manager via its stored command, work sessions via `claude --continue`).

The web UI confirms first; from the CLI the caller owns that choice, the same stance as `recreate-terminal`.

Returns as soon as the teardown is done — the per-terminal rebuild continues in the background, so don't chain a `crow send` straight after this or you'll race a half-rebuilt surface.

---

## `crow resync-jira`

Re-sync Jira ticket statuses from Crow session state.

```
crow resync-jira
```

---

## `crow retry-readiness`

Re-arm the readiness watch for a stuck terminal.

```
crow retry-readiness --terminal <terminal>
```

Starts a longer-budget readiness watch on a terminal whose first attempt timed out, clearing the Retry overlay in the UI.

Takes only `--terminal` — no `--session` flag.

The daemon applies this only to a terminal that timed out or never reached shell-ready; in any other state it is a no-op. `{"ok": true}` means the request was accepted, not that a watch was re-armed.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--terminal` | `<terminal>` | yes | Terminal UUID |

---

## `crow select-session`

Switch to a session.

```
crow select-session --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow send`

Send text to a terminal.

```
crow send --session <session> --terminal <terminal> <text>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--terminal` | `<terminal>` | yes | Terminal UUID |
| _(positional)_ | `<text>` | yes | Text to send |

---

## `crow set-goal`

Set or clear the org-goal tag on a session.

```
crow set-goal --session <session> [--goal <goal>] [--clear]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--goal` | `<goal>` | no | Org goal/KPI this session's work ladders up to |
| `--clear` | — | no | Clear the org-goal tag |

---

## `crow set-locked`

Lock/unlock a session to protect it from auto-cleanup.

```
crow set-locked --session <session> <locked>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| _(positional)_ | `<locked>` | yes | Locked state: true or false |

---

## `crow set-pinned`

Deprecated alias for set-locked.

**Hidden** — not listed in `crow --help`.

```
crow set-pinned --session <session> <pinned>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| _(positional)_ | `<pinned>` | yes | Locked state: true or false |

---

## `crow set-session-active`

Return a session to active.

```
crow set-session-active --session <session>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |

---

## `crow set-status`

Set session status.

```
crow set-status --session <session> <status>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| _(positional)_ | `<status>` | yes | Status: active, paused, inReview, completed, archived |

---

## `crow set-ticket`

Set ticket metadata.

```
crow set-ticket --session <session> [--url <url>] [--title <title>] [--number <number>] [--priority <priority>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--url` | `<url>` | no | Ticket URL |
| `--title` | `<title>` | no | Ticket title |
| `--number` | `<number>` | no | Ticket number |
| `--priority` | `<priority>` | no | Ticket priority: highest, high, medium, low, or lowest |

---

## `crow setup`

First-time setup for Crow.

```
crow setup [--dev-root <dev-root>]
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--dev-root` | `<dev-root>` | no | Development root path |

---

## `crow start-review`

Start a review session for a pull request.

```
crow start-review --url <url>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--url` | `<url>` | yes | Pull request URL |

---

## `crow telemetry`

View or change session-analytics collection.

```
crow telemetry <get|set>
```

Subcommands: [`get`](#crow-telemetry-get), [`set`](#crow-telemetry-set).

---

## `crow telemetry get`

Show the current telemetry settings.

```
crow telemetry get
```

---

## `crow telemetry set`

Change telemetry settings.

```
crow telemetry set [--enabled <enabled>] [--port <port>] [--retention-days <retention-days>]
```

Only the flags you pass change; at least one is required.

--enabled and --port are read once when crowd starts, and the port is baked into every agent launch's OTEL_EXPORTER_OTLP_ENDPOINT, so changing either returns "restart_required": true — restart crowd to apply it. --retention-days drives the prune that runs at startup, so it likewise applies at the next daemon start.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--enabled` | `<enabled>` | no | Enable the OTLP receiver (true or false) |
| `--port` | `<port>` | no | OTLP HTTP receiver port (1024-65535, default 4318) |
| `--retention-days` | `<retention-days>` | no | Days of telemetry to keep; 0 keeps forever (default 180) |

---

## `crow terminal`

View or change terminal wheel-scroll speed.

```
crow terminal <get|set>
```

Wheel-scroll tuning for the web terminal (CROW-835, ADR 0013). The wheel is routed by surface: plain-shell / review surfaces scroll their own scrollback, so the knob is lines per physical notch; agent TUIs (Claude Code, Cursor, the Manager) own their scrolling, so the knob is how many wheel notches are forwarded to the app per physical notch. Each surface gets its own value.

These are the two `AppConfig.terminal` fields the web Settings sliders write; this is the CLI half. Not to be confused with the terminal-*tab* verbs (`new-terminal`, `list-terminals`, `send`, …), which manage panes.

Subcommands: [`get`](#crow-terminal-get), [`set`](#crow-terminal-set).

---

## `crow terminal get`

Show the current terminal wheel-scroll settings.

```
crow terminal get
```

---

## `crow terminal set`

Change terminal wheel-scroll speed.

```
crow terminal set [--wheel-scroll-lines <wheel-scroll-lines>] [--agent-wheel-notches <agent-wheel-notches>]
```

Only the flags you pass change; at least one is required. Connected browsers pick the change up on their next scroll — no reload.

--wheel-scroll-lines sets scrollback lines per wheel notch on plain-shell and review surfaces (default 3). --agent-wheel-notches sets how many wheel reports are forwarded to the agent per physical notch (default 1 — one detent in, one out; raise it if agent scrolling feels too slow). Both floor at 1: a value of 0 would disable wheel scrolling on that surface.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--wheel-scroll-lines` | `<wheel-scroll-lines>` | no | Scrollback lines per wheel notch on plain-shell/review surfaces (minimum 1, default 3) |
| `--agent-wheel-notches` | `<agent-wheel-notches>` | no | Wheel notches forwarded to the agent per physical notch (minimum 1, default 1) |

---

## `crow transition-ticket`

Transition a session's ticket to a pipeline status.

```
crow transition-ticket --session <session> --to <to>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--session` | `<session>` | yes | Session UUID |
| `--to` | `<to>` | yes | Target status: inProgress, inReview, or done |

---

## `crow ui`

View or change UI display preferences.

```
crow ui <get|set>
```

Display preferences only — this does not start, stop, or open the web UI.

Settings are grouped by the config block they belong to, so `get` returns {"ui": {"sidebar": {...}}} and gains further blocks as more view options become configurable.

Subcommands: [`get`](#crow-ui-get), [`set`](#crow-ui-set).

---

## `crow ui get`

Show the current UI display preferences.

```
crow ui get
```

---

## `crow ui set`

Change UI display preferences.

```
crow ui set [--hide-session-details <hide-session-details>] [--switcher-enabled <switcher-enabled>] [--switcher-binding <switcher-binding>] [--switcher-capture-in-terminal <switcher-capture-in-terminal>] [--switcher-order <switcher-order>] [--switcher-preview <switcher-preview>] [--switcher-include <switcher-include> ...]
```

Only the flags you pass change; at least one is required. Connected browsers pick the change up within a couple of seconds — no reload.

--switcher-binding takes a modifier chord like `cmd+/` (the default) or `ctrl+space`, plus one sequence form: a leading `esc` is a prefix, not a modifier, so `esc+tab` means tap Esc, then Tab. A modifier chord commits on release of the modifier; a prefix chord holds nothing down, so the overlay stays open — the key or ←→ cycle, Enter switches, Esc cancels. Esc itself is never swallowed and still reaches the terminal.

`shift+tab` is rejected: coding agents cycle permission modes with it, and the switcher would swallow that keystroke in every focused terminal. A config still carrying it from an older Crow is migrated to the default on load. On a keyboard with no Cmd, use `ctrl+/`.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--hide-session-details` | `<hide-session-details>` | no | Hide ticket title and repo/branch lines in sidebar rows (true or false) |
| `--switcher-enabled` | `<switcher-enabled>` | no | Enable the session switcher overlay (true or false) |
| `--switcher-binding` | `<switcher-binding>` | no | Session switcher key chord (default: cmd+/; shift+tab is reserved by agents) |
| `--switcher-capture-in-terminal` | `<switcher-capture-in-terminal>` | no | Capture the switcher binding inside focused terminals (true or false) |
| `--switcher-order` | `<switcher-order>` | no | Session switcher ordering: mru or sidebar |
| `--switcher-preview` | `<switcher-preview>` | no | Fetch a tmux pane preview for the highlighted switcher card (true or false) |
| `--switcher-include` | `<switcher-include>` _(repeatable)_ | no | Include filter as key=value (managers, jobs, reviews, active, paused, in_review, completed, archived) |

---

## `crow version`

Show the local build and check for upstream updates.

```
crow version <check|get|set> [--check]
```

Bare `crow version` prints the stamped build version. Pass `--check` or run `crow version check` to compare against corveil/crow main via the daemon.

Subcommands: [`check`](#crow-version-check), [`get`](#crow-version-get), [`set`](#crow-version-set).

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--check` | — | no | Compare this build against corveil/crow main |

---

## `crow version check`

Compare this build against corveil/crow main.

```
crow version check
```

---

## `crow version get`

Show version-update settings and the cached check result.

```
crow version get
```

---

## `crow version set`

Change version-update settings.

```
crow version set [--enabled <enabled>] [--interval-hours <interval-hours>]
```

Only the flags you pass change; at least one is required. --interval-hours is floored at 1 (hourly checks stay within GitHub's unauthenticated 60 req/hr limit).

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--enabled` | `<enabled>` | no | Enable periodic upstream checks (true or false) |
| `--interval-hours` | `<interval-hours>` | no | Hours between automatic checks (minimum 1, default 1) |

---

## `crow web-password`

Manage the web-access password (local-only).

```
crow web-password <status|set|clear>
```

Subcommands: [`status`](#crow-web-password-status), [`set`](#crow-web-password-set), [`clear`](#crow-web-password-clear).

---

## `crow web-password clear`

Remove the web-access password.

```
crow web-password clear
```

With no password set, remote web clients are no longer challenged — check how the daemon is bound before clearing it.

---

## `crow web-password set`

Set or change the web-access password.

```
crow web-password set [--stdin]
```

Prompts twice with echo off. For scripts, pipe the password and pass --stdin:

```
printf '%s' "$PW" | crow web-password set --stdin
```

There is no --password flag on purpose — a plaintext password in argv is visible in shell history and to local `ps`. Changing the password does not require the old one; the local-only gate is the control.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--stdin` | — | no | Read the password from stdin instead of prompting |

---

## `crow web-password status`

Report whether a web-access password is set.

```
crow web-password status
```

---

## `crow work-on-issue`

Start working on a ticket (types /crow-workspace into the Manager).

```
crow work-on-issue --url <url>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--url` | `<url>` | yes | Ticket / issue URL |

---

## `crow workspace`

Manage workspaces (Settings → Workspaces).

```
crow workspace <list|get|add|edit|remove>
```

A workspace maps to a folder under the dev root and decides which forge its repos live on, where its tickets come from, and what extra context its sessions get. --workspace accepts a name (case-insensitive) or a workspace UUID.

`add` and `edit` take the same field flags. On `edit` only the flags you pass change; an optional scalar clears with an empty string (--host ""), and a list or map clears with its --clear-* flag.

Subcommands: [`list`](#crow-workspace-list), [`get`](#crow-workspace-get), [`add`](#crow-workspace-add), [`edit`](#crow-workspace-edit), [`remove`](#crow-workspace-remove).

---

## `crow workspace add`

Create a workspace.

```
crow workspace add --name <name> [--provider <provider>] [--host <host>] [--task-provider <task-provider>] [--jira-site <jira-site>] [--jira-project-key <jira-project-key>] [--jira-jql <jira-jql>] [--jira-status-backlog <jira-status-backlog>] [--jira-status-ready <jira-status-ready>] [--jira-status-in-progress <jira-status-in-progress>] [--jira-status-in-review <jira-status-in-review>] [--jira-status-done <jira-status-done>] [--clear-jira-status-map] [--custom-instructions <custom-instructions>] [--custom-instructions-file <custom-instructions-file>] [--always-include <always-include> ...] [--clear-always-include] [--auto-review-repo <auto-review-repo> ...] [--clear-auto-review-repos] [--exclude-review-repo <exclude-review-repo> ...] [--clear-exclude-review-repos] [--session-env <session-env> ...] [--clear-session-env] [--upload-session-logs <upload-session-logs>] [--review-blocking-severity <review-blocking-severity> ...] [--clear-review-blocking-severities]
```

Only --name is required; every other field takes its documented default and can be set later with `crow workspace edit`. The name becomes a directory under the dev root, so it cannot contain / or :, cannot be "." or "..", and must not collide with an existing workspace (case-insensitively).

Creating a workspace does not create its directory — the daemon scaffolds it on next launch.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--name` | `<name>` | yes | Workspace name (becomes a folder under the dev root) |
| `--provider` | `<provider>` | no | Code/PR host: github or gitlab |
| `--host` | `<host>` | no | GitLab host, e.g. gitlab.example.com (GitLab workspaces only; "" clears) |
| `--task-provider` | `<task-provider>` | no | Where tickets live: github, gitlab, or jira ("" follows the code provider) |
| `--jira-site` | `<jira-site>` | no | Atlassian site, e.g. acme.atlassian.net ("" clears) |
| `--jira-project-key` | `<jira-project-key>` | no | Jira project key, e.g. PROPS ("" clears) |
| `--jira-jql` | `<jira-jql>` | no | JQL for this workspace's ticket board ("" clears) |
| `--jira-status-backlog` | `<jira-status-backlog>` | no | Jira status name for Backlog ("" clears) |
| `--jira-status-ready` | `<jira-status-ready>` | no | Jira status name for Ready ("" clears) |
| `--jira-status-in-progress` | `<jira-status-in-progress>` | no | Jira status name for In Progress ("" clears) |
| `--jira-status-in-review` | `<jira-status-in-review>` | no | Jira status name for In Review ("" clears) |
| `--jira-status-done` | `<jira-status-done>` | no | Jira status name for Done ("" clears) |
| `--clear-jira-status-map` | — | no | Drop every Crow→Jira status mapping |
| `--custom-instructions` | `<custom-instructions>` | no | Free text appended to this workspace's session prompts ("" clears) |
| `--custom-instructions-file` | `<custom-instructions-file>` | no | Read --custom-instructions from a file; '-' reads stdin |
| `--always-include` | `<always-include>` _(repeatable)_ | no | Repo always listed in the prompt table (repeatable; replaces the whole list) |
| `--clear-always-include` | — | no | Empty the always-include list |
| `--auto-review-repo` | `<auto-review-repo>` _(repeatable)_ | no | Repo whose review requests auto-create a session (repeatable; replaces the whole list) |
| `--clear-auto-review-repos` | — | no | Empty the auto-review list |
| `--exclude-review-repo` | `<exclude-review-repo>` _(repeatable)_ | no | Repo hidden from the review board (repeatable; replaces the whole list) |
| `--clear-exclude-review-repos` | — | no | Empty the exclude-from-reviews list |
| `--session-env` | `<session-env>` _(repeatable)_ | no | KEY=VALUE exported into agents in this workspace (repeatable; replaces the whole map) |
| `--clear-session-env` | — | no | Drop every session env var |
| `--upload-session-logs` | `<upload-session-logs>` | no | Upload this workspace's coding-session transcripts to Corveil, reusing its gateway credential: true or false (needs the local-only log-sync master switch on) |
| `--review-blocking-severity` | `<review-blocking-severity>` _(repeatable)_ | no | Review finding severity that forces --request-changes (repeatable; replaces the whole list; default red + yellow). Values: `red`, `yellow`, `green`. |
| `--clear-review-blocking-severities` | — | no | Restore the default review blocking set (red + yellow) |

---

## `crow workspace edit`

Change fields on an existing workspace.

```
crow workspace edit --workspace <workspace> [--name <name>] [--provider <provider>] [--host <host>] [--task-provider <task-provider>] [--jira-site <jira-site>] [--jira-project-key <jira-project-key>] [--jira-jql <jira-jql>] [--jira-status-backlog <jira-status-backlog>] [--jira-status-ready <jira-status-ready>] [--jira-status-in-progress <jira-status-in-progress>] [--jira-status-in-review <jira-status-in-review>] [--jira-status-done <jira-status-done>] [--clear-jira-status-map] [--custom-instructions <custom-instructions>] [--custom-instructions-file <custom-instructions-file>] [--always-include <always-include> ...] [--clear-always-include] [--auto-review-repo <auto-review-repo> ...] [--clear-auto-review-repos] [--exclude-review-repo <exclude-review-repo> ...] [--clear-exclude-review-repos] [--session-env <session-env> ...] [--clear-session-env] [--upload-session-logs <upload-session-logs>] [--review-blocking-severity <review-blocking-severity> ...] [--clear-review-blocking-severities] [--force]
```

Only the provided flags change. A repeatable list flag replaces the whole list rather than appending, matching `crow job edit`; use the matching --clear-* flag to empty one. The --jira-status-* flags patch individually — each sets one mapping and leaves the other four alone.

Renaming is guarded. Sessions are tied to a workspace only by their worktree living under {devRoot}/{workspace}/, and jobs only by the workspace name string, so a rename silently orphans both — it does not move any directory. --force renames anyway and reports the counts.

An edit whose values already hold is reported as "saved": false and skips the write, so re-running the same command doesn't churn config.json.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--workspace` | `<workspace>` | yes | Workspace name or UUID |
| `--name` | `<name>` | no | New workspace name (see the rename guard above) |
| `--provider` | `<provider>` | no | Code/PR host: github or gitlab |
| `--host` | `<host>` | no | GitLab host, e.g. gitlab.example.com (GitLab workspaces only; "" clears) |
| `--task-provider` | `<task-provider>` | no | Where tickets live: github, gitlab, or jira ("" follows the code provider) |
| `--jira-site` | `<jira-site>` | no | Atlassian site, e.g. acme.atlassian.net ("" clears) |
| `--jira-project-key` | `<jira-project-key>` | no | Jira project key, e.g. PROPS ("" clears) |
| `--jira-jql` | `<jira-jql>` | no | JQL for this workspace's ticket board ("" clears) |
| `--jira-status-backlog` | `<jira-status-backlog>` | no | Jira status name for Backlog ("" clears) |
| `--jira-status-ready` | `<jira-status-ready>` | no | Jira status name for Ready ("" clears) |
| `--jira-status-in-progress` | `<jira-status-in-progress>` | no | Jira status name for In Progress ("" clears) |
| `--jira-status-in-review` | `<jira-status-in-review>` | no | Jira status name for In Review ("" clears) |
| `--jira-status-done` | `<jira-status-done>` | no | Jira status name for Done ("" clears) |
| `--clear-jira-status-map` | — | no | Drop every Crow→Jira status mapping |
| `--custom-instructions` | `<custom-instructions>` | no | Free text appended to this workspace's session prompts ("" clears) |
| `--custom-instructions-file` | `<custom-instructions-file>` | no | Read --custom-instructions from a file; '-' reads stdin |
| `--always-include` | `<always-include>` _(repeatable)_ | no | Repo always listed in the prompt table (repeatable; replaces the whole list) |
| `--clear-always-include` | — | no | Empty the always-include list |
| `--auto-review-repo` | `<auto-review-repo>` _(repeatable)_ | no | Repo whose review requests auto-create a session (repeatable; replaces the whole list) |
| `--clear-auto-review-repos` | — | no | Empty the auto-review list |
| `--exclude-review-repo` | `<exclude-review-repo>` _(repeatable)_ | no | Repo hidden from the review board (repeatable; replaces the whole list) |
| `--clear-exclude-review-repos` | — | no | Empty the exclude-from-reviews list |
| `--session-env` | `<session-env>` _(repeatable)_ | no | KEY=VALUE exported into agents in this workspace (repeatable; replaces the whole map) |
| `--clear-session-env` | — | no | Drop every session env var |
| `--upload-session-logs` | `<upload-session-logs>` | no | Upload this workspace's coding-session transcripts to Corveil, reusing its gateway credential: true or false (needs the local-only log-sync master switch on) |
| `--review-blocking-severity` | `<review-blocking-severity>` _(repeatable)_ | no | Review finding severity that forces --request-changes (repeatable; replaces the whole list; default red + yellow). Values: `red`, `yellow`, `green`. |
| `--clear-review-blocking-severities` | — | no | Restore the default review blocking set (red + yellow) |
| `--force` | — | no | Rename even when sessions or jobs reference this workspace |

---

## `crow workspace get`

Show one workspace's full configuration.

```
crow workspace get --workspace <workspace>
```

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--workspace` | `<workspace>` | yes | Workspace name or UUID |

---

## `crow workspace list`

List every configured workspace.

```
crow workspace list
```

---

## `crow workspace remove`

Delete a workspace from the configuration.

```
crow workspace remove --workspace <workspace> [--force]
```

Removes the config entry only. The workspace directory under the dev root, its worktrees, and its branches are left on disk — same as the web UI. Any AI gateway stored for this workspace is discarded with it, and there is no undo.

Refuses when sessions or jobs still reference the workspace; --force removes it anyway.

| Flag | Value | Required | Description |
| --- | --- | --- | --- |
| `--workspace` | `<workspace>` | yes | Workspace name or UUID |
| `--force` | — | no | Remove even when sessions or jobs reference this workspace |

---

