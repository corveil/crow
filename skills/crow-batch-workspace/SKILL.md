# Crow Batch Workspace Setup Skill

## Purpose

Sets up **multiple** crow workspaces in parallel, dramatically reducing total setup time. Delegates to the existing `/crow-workspace` skill's `setup.sh` for each workspace but fires all executions simultaneously.

## Important: Sandbox Bypass

All `crow`, `gh`, `glab`, and `git worktree` commands require `dangerouslyDisableSandbox: true` because they communicate via Unix socket, need network/TLS access, or write outside the sandbox-allowed directories.

## Activation

This skill activates when:
- User invokes `/crow-batch-workspace` command
- User asks to "set up multiple workspaces", "batch workspace setup", or provides multiple ticket URLs at once

## Concurrency Safety

The crow CLI is safe for concurrent use. Multiple `crow` commands can run simultaneously without race conditions:

- **Socket Server**: Each CLI connection is dispatched to GCD's global concurrent queue. Multiple connections are accepted and processed in parallel.
- **State Mutations**: All RPC handlers use `await MainActor.run { ... }`, serializing all AppState mutations on the main thread.
- **Persistence**: JSONStore uses NSLock to serialize disk writes. Concurrent `mutate()` calls are safe.
- **Git Operations**: Each `setup.sh` creates its own worktree at a unique path, its own session (unique UUID), and its own terminal. There are no shared resources between parallel workspace setups.

## Autonomous Execution

This skill runs autonomously without permission prompts because:
1. All `crow`, `gh`, `glab`, and `git` commands are pre-approved in `{devRoot}/.claude/settings.json`
2. All commands use `dangerouslyDisableSandbox: true` (sandbox excludes these binaries)
3. `setup.sh` is pre-approved via `Bash(bash .claude/skills/crow-workspace/setup.sh *)`

No additional permission configuration is needed.

## Configuration

Same as `/crow-workspace`. Configuration is at `{devRoot}/.claude/config.json` (managed by the Crow app).

## Input Format

One or more ticket URLs, separated by newlines:

```
/crow-batch-workspace
https://github.com/RadiusMethod/crow/issues/101
https://github.com/RadiusMethod/acme-api/issues/45
https://github.com/RadiusMethod/crow/issues/99
```

Or a mix of ticket URLs and natural language:

```
/crow-batch-workspace
https://github.com/RadiusMethod/crow/issues/101
"update acme-api authentication"
https://gitlab.example.com/org/repo/-/issues/42
```

## Execution Flow

### Phase 1: Parse Inputs

Split the user's input into individual workspace specs. Each spec is either:
- A ticket URL (GitHub or GitLab)
- A natural language description

Validate each is a recognizable format.

### Phase 2: Resolve Each Workspace (sequential)

For each workspace spec, perform the same resolution as `/crow-workspace`:

> Issue each `gh`/`git` fetch below as a **single, clean invocation** — one command per Bash call, no `cd …`/`echo`/`find` prefix or `| head` pipe — so the allowlist auto-approves it instead of prompting (see CLAUDE.md → "Fetching Ticket / PR Data").

1. **Read config**: `cat {devRoot}/.claude/config.json`
2. **Detect provider** from URL (see Provider Detection table in `/crow-workspace` skill — includes Jira)
3. **Scan repos**: Find repos in all configured workspaces
4. **Match repo**: Score repos against ticket content
5. **Fetch ticket** (provider-specific, with `dangerouslyDisableSandbox: true`):
   - GitHub: `gh issue view {url} --json title,body,labels`
   - GitLab: `GITLAB_HOST={host} glab issue view {number} --repo {org/repo} --comments`
   - Jira (task-only): `acli jira workitem view {key} --json` (title at `.fields.summary`)
6. **Check for existing PR**: `gh pr list --repo {owner}/{repo} --search "{issue_number}" --state open --json number,title,headRefName,url --limit 5` (with `dangerouslyDisableSandbox: true`). For a Jira-task session this runs against the workspace's configured GitHub/GitLab code repo, not Jira.
7. **Generate names**: slug, branch, worktree path, session name (following `/crow-workspace` naming conventions). **Jira:** resolve `{ticket_number}` as the **numeric suffix** of the key (`MAXX-6859` → `6859`); `{ticket_url}` is the full `…/browse/{key}` URL; the slug uses the lowercased full key (`{repo}-maxx-6859-{slug}`).
8. **Compose prompt**: Use the First Prompt Template from `/crow-workspace`
9. **Write prompt file**: `cat > {devRoot}/.claude/prompts/crow-prompt-{session_name}.md`

This phase is sequential because each resolution involves LLM reasoning (scoring repos, generating slugs). It's fast (~2-3 seconds per workspace).

**Collect all resolved parameters into a list** before proceeding to Phase 3.

### Phase 3: Parallel Execution

**CRITICAL: Launch ALL `setup.sh` calls in a SINGLE message using multiple Bash tool calls.**

Claude Code supports making multiple independent Bash calls simultaneously in a single response. Since each workspace creates its own independent session, there are no dependencies between them.

Record the start time:
```bash
date +%s
```

Then, in a **single message**, fire one Bash tool call per workspace:

```bash
.claude/skills/crow-workspace/setup.sh \
  --dev-root "{devRoot}" \
  --workspace "{workspace}" \
  --repo "{repo}" \
  --repo-path "{repo_path}" \
  --slug "{slug}" \
  --branch "{branch}" \
  --worktree-path "{worktree_path}" \
  --session-name "{session_name}" \
  --provider "{provider}" \
  --cli "{cli}" \
  --ticket-url "{ticket_url}" \
  --ticket-title "{ticket_title}" \
  --ticket-number {ticket_number} \
  --prompt-content "{devRoot}/.claude/prompts/crow-prompt-{session_name}.md" \
  --primary
```

Each call must use `dangerouslyDisableSandbox: true`.

If a workspace has an existing PR, also pass `--pr-number`, `--pr-url`, `--pr-branch`.
For GitLab workspaces, also pass `--host "{gitlab_host}"`.

Every workspace uses `--primary` because each is an independent session with its own Claude Code instance.

Record the end time after all calls complete:
```bash
date +%s
```

### Phase 4: Report Results

Parse the JSON output from each `setup.sh` call and present a summary:

```
## Batch Workspace Setup Complete

| # | Workspace | Session ID | Status | Branch |
|---|-----------|------------|--------|--------|
| 1 | crow-101-parallel-exec | a1b2c3d4-... | ok | feature/crow-101-parallel-exec |
| 2 | acme-api-45-jwt-validation | e5f6a7b8-... | ok | feature/acme-api-45-jwt-validation |
| 3 | crow-99-fix-terminal-focus | c9d0e1f2-... | error: git_worktree_add | - |

### Timing
- Parallel execution: 18s (3 workspaces)
- Estimated sequential: ~45s (3 x ~15s avg)
- Speedup: ~2.5x
```

For any failures, include the error message and suggest remediation (see Error Handling below).

## Naming Conventions

Same as `/crow-workspace`. See that skill for full details.

**CRITICAL: Worktrees go DIRECTLY under the workspace folder, at the same level as the main repo clone. NOT in a subfolder.**

```
{devRoot}/{workspace}/{repo}-{ticket_number}-{brief_slug}
```

## Error Handling

If any `setup.sh` call returns `"status": "error"`:

1. Report the failure in the summary table
2. Include the `step` and `message` from the error JSON
3. If `partial.session_id` is present, note it for potential cleanup
4. Do NOT retry automatically — report failures and let the user decide
5. Successful workspaces are not affected by individual failures

Common errors:
| Error | Likely Cause | Remediation |
|-------|-------------|-------------|
| `git_worktree_add` | Branch already exists | Use a different slug or delete the conflicting branch |
| `new_session` | Crow app not running | Ask user to start Crow |
| `git_fetch` | Network issue or bad repo path | Check repo path and network |

## crow CLI Reference

Same as `/crow-workspace`. See that skill for the full CLI reference.

## Examples

### Three GitHub Issues
```
/crow-batch-workspace
https://github.com/RadiusMethod/crow/issues/101
https://github.com/RadiusMethod/acme-api/issues/45
https://github.com/RadiusMethod/crow/issues/99
```
- Resolves all 3 sequentially (fetches tickets, detects PRs, generates names)
- Fires 3 `setup.sh` calls simultaneously
- Reports results with timing comparison

### Mixed Providers
```
/crow-batch-workspace
https://github.com/RadiusMethod/crow/issues/101
https://gitlab.example.com/org/my-project/-/issues/42
```
- Detects GitHub and GitLab providers from URLs
- Uses `gh` for first, `glab` for second
- Both `setup.sh` calls fire in parallel

### Five Workspaces (Stress Test)
```
/crow-batch-workspace
https://github.com/RadiusMethod/crow/issues/101
https://github.com/RadiusMethod/crow/issues/102
https://github.com/RadiusMethod/crow/issues/103
https://github.com/RadiusMethod/acme-api/issues/45
https://github.com/RadiusMethod/acme-api/issues/46
```
- 5 parallel `setup.sh` calls
- Each blocks one GCD thread in the socket server (well within the 64+ thread pool)
- Each script's readiness poll (up to ~15s) overlaps with the others — they wait
  concurrently, and most return as soon as the agent reports `agentLaunched`
