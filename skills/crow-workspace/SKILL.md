# Crow Workspace Setup Skill

## Purpose

Orchestrates work sessions in **Crow** by setting up git worktrees and creating a crow session with auto-launched Claude Code and ticket metadata. Supports multiple organizations/workspaces with different Git providers.

## Important: Sandbox Bypass

All `crow`, `gh`, `glab`, and `git worktree` commands require `dangerouslyDisableSandbox: true` because they communicate via Unix socket, need network/TLS access, or write outside the sandbox-allowed directories.

## Activation

This skill activates when:
- User invokes `/crow-workspace` command
- User asks to "set up crow workspace" or "start working on" a feature in Crow

## Configuration

Configuration is at `{devRoot}/.claude/config.json` (managed by the Crow app). The format is:

```json
{
  "devRoot": "/Users/name/Dev",
  "workspaces": {
    "RadiusMethod": {
      "provider": "github",
      "cli": "gh",
      "customInstructions": "Always run `npm test` before committing."
    },
    "MyGitLab": {
      "provider": "gitlab",
      "cli": "glab",
      "host": "gitlab.example.com",
      "alwaysInclude": [],
      "customInstructions": null
    }
  },
  "defaults": {
    "provider": "github",
    "cli": "gh",
    "worktreePattern": "{repo}-{feature}",
    "branchPrefix": "feature/",
    "excludeDirs": ["node_modules", ".git", "vendor", "dist", "build", "target"],
    "keywordSources": ["CLAUDE.md", "README.md", "package.json", "Cargo.toml", "pyproject.toml", "go.mod"]
  }
}
```

### Commit Attribution Trailers

By default, `setup.sh` writes a per-worktree `.claude/settings.local.json` that overrides Claude Code's `attribution.commit` so commits include a `Crow-Session: <uuid>` trailer alongside the standard `Co-Authored-By: Claude` line. The trailer is a stable handle back to session metadata via `crow get-session <uuid>`. To opt out globally, set `"attributionTrailers": false` at the top level of `{devRoot}/.claude/config.json` (also surfaced in Settings → Automation → Attribution).

The worktree's settings.local.json is added to that worktree's per-worktree git exclude list, so it stays local even when the repo's tracked `.gitignore` does not already cover it.

**When authoring commits by hand** (`git commit -m "…"`, heredoc, `git commit --amend`), include both `Crow-Session: <session-uuid>` and `Co-Authored-By: Claude <noreply@anthropic.com>` as trailers at the end of the message. `attribution.commit` only fires for Claude Code's built-in commit flow; hand-rolled commits bypass it. `setup.sh` also installs a per-worktree `prepare-commit-msg` hook (CROW-518) that idempotently appends both trailers when missing — treat that hook as a safety net, not the primary path. Both trailers must be line-anchored at the end of the message; the `crow:merge` auto-merge gate parses `^Crow-Session:\s*<uuid>\s*$` (see `IssueTracker.crowSessionTrailerPattern`).

## Multi-Workspace Discovery

### Step 1: Enumerate Workspaces

```bash
ls -d {devRoot}/*/
```

For each workspace: check if it has explicit config, otherwise apply defaults.

### Step 2: Scan Each Workspace for Repos

```bash
for dir in {workspace}/*/; do
  if [ -d "$dir/.git" ]; then
    echo "$dir"
  fi
done
```

### Step 3: Build Global Repo Index

Match repos to input by: direct name match (+10), workspace mention (+5), keyword match (+2 per).

## Git Provider Commands

### GitHub (gh)
```bash
gh issue view {url} --json title,body,labels
gh pr view {url} --json title,body,labels
```

### GitLab (glab)
```bash
GITLAB_HOST=gitlab.example.com glab issue view {number} --repo {org/repo} --comments
GITLAB_HOST=gitlab.example.com glab mr view {number} --repo {org/repo} --comments
```

### Jira (Atlassian MCP)
Jira work items are fetched via the **official Atlassian Remote MCP Server**, not
`acli` (CROW-522). When a workspace is configured for Jira and the Atlassian MCP
credential is set in Settings → Automation, Crow pre-registers and auto-trusts the
`atlassian` MCP server in the launched session. Resolve your `cloudId` once with
`getAccessibleAtlassianResources`, then call `getJiraIssue` for the full key
(`PROJ-NNN`, e.g. `MAXX-6859`). The summary field is the `{ticket_title}`. Use the
same MCP tools (`createJiraIssue`, `editJiraIssue`, `transitionJiraIssue`,
`lookupJiraAccountId`) for any create/assign/transition. (If the MCP isn't
configured in this environment, fall back to `acli jira workitem view {key} --json`.)

**Status names when transitioning (CROW-523):** Jira workflow status names are
configurable per project, so before `transitionJiraIssue` consult this workspace's
`jiraStatusMap` in `{devRoot}/.claude/config.json` — it maps Crow's pipeline states
(`Backlog` / `Ready` / `In Progress` / `In Review` / `Done`) to this project's actual
status names. Use the mapped name for the target state; fall back to the Crow default
(`Ready` → `To Do`, all others use the state name verbatim) for any unmapped state.

### Provider Detection from URL

| URL Contains | Provider | CLI | GITLAB_HOST |
|---|---|---|---|
| `github.com` | github | gh | - |
| `atlassian.net` / `/browse/` / bare `PROJ-123` | jira | Atlassian MCP | - |
| `gitlab.example.com` | gitlab | glab | gitlab.example.com |
| `gitlab.com` | gitlab | glab | gitlab.com |
| `gitlab-il2.example.com` | gitlab | glab | gitlab-il2.example.com |

**Jira is task-only** (no code/VCS surface): the ticket lives in Jira while code
lands in the workspace's configured GitHub/GitLab repo. Detect it *before* the
loose GitLab match. The Jira key is `PROJ-NNN` (e.g. `MAXX-6859`).

**Resolving `{ticket_number}` for Jira:** Jira keys have no standalone numeric
id, so use the **numeric suffix** of the key — `MAXX-6859` → `6859`. Pass that as
`--ticket-number`, the full Atlassian browse URL as `--ticket-url`
(`https://<site>.atlassian.net/browse/MAXX-6859`), and the summary as
`--ticket-title`. The worktree/branch/session slug uses the full lowercased key,
e.g. `{repo}-maxx-6859-{brief_slug}`.

## PR Detection

Before creating a worktree, check if the issue already has an open PR. If so, use the PR's branch instead of creating a new one.

### GitHub
```bash
gh pr list --repo {owner}/{repo} --search "{issue_number}" --state open \
  --json number,title,headRefName,url --limit 5
```

### GitLab
```bash
GITLAB_HOST={host} glab mr list --repo {org/repo} --search "{issue_number}" --state opened --output-format json
```

### Selection Logic

If multiple PRs are found, prefer the one whose `headRefName` contains the issue number. If exactly one PR is returned, use it. If none are found, proceed with the normal new-branch flow.

When a PR is found, capture:
- `pr_number` — the PR/MR number
- `pr_url` — the full URL to the PR/MR
- `pr_branch` — the `headRefName` (branch name)

These values are used in worktree creation, session linking, and the prompt template below.

## Worktree Management

### Naming Convention

**CRITICAL: Worktrees go DIRECTLY under the workspace folder, at the same level as the main repo clone. NOT in a subfolder.**

**For ticket URLs (no existing PR):**
```
{devRoot}/{workspace}/{repo}-{ticket_number}-{brief_slug}
```
Branch: `feature/{repo}-{ticket_number}-{brief_slug}`

The brief slug is 2-4 key words from the ticket title.

**Concrete example with full paths:**
Given: devRoot=`/Users/jane/Dev`, workspace=`RadiusMethod`, repo=`acme-api` (cloned at `/Users/jane/Dev/RadiusMethod/acme-api`), ticket #197 "Fix tab URL hash routing"

```
Worktree path: /Users/jane/Dev/RadiusMethod/acme-api-197-fix-tab-url-hash
Branch:        feature/acme-api-197-fix-tab-url-hash
Git command:   git -C /Users/jane/Dev/RadiusMethod/acme-api worktree add /Users/jane/Dev/RadiusMethod/acme-api-197-fix-tab-url-hash -b feature/acme-api-197-fix-tab-url-hash --no-track origin/main
```

More examples:
```
web-app #252 "Update deployment-guide.md"    → {devRoot}/MyGitLab/web-app-252-update-deploy-docs
acme-api #45 "Add JWT validation endpoint"   → {devRoot}/RadiusMethod/acme-api-45-jwt-validation
```

**For ticket URLs with an existing PR:**

Use the PR's `headRefName` as the branch — do NOT generate a new name. Derive the worktree directory from the branch name.

```
{devRoot}/{workspace}/{repo}-{pr_branch_slug}
```

Where `{pr_branch_slug}` is the `headRefName` with any `feature/` prefix stripped. For example, if the PR branch is `feature/acme-api-45-jwt-validation`, the worktree path is `{devRoot}/RadiusMethod/acme-api-45-jwt-validation`.

**WRONG — do NOT create subdirectories:**
```
WRONG: {devRoot}/{workspace}/{repo}-worktrees/{feature}
WRONG: {devRoot}/{workspace}/worktrees/{repo}-{feature}
```

**For natural language (no ticket):**
```
{devRoot}/{workspace}/{repo}-{feature-slug}
```
Branch: `feature/{feature-slug}`

### Git Commands

Git worktree creation is handled by `setup.sh`. The script automatically selects the correct flags:
- **PR branch**: `--track origin/{pr_branch}`
- **Existing remote branch**: `--track origin/{branch}`
- **New branch**: `--no-track origin/main`

Always uses `-b` to create a local branch (avoids detached HEAD). If the branch already exists locally, the script deletes it and retries.

**Important:** Always use `--no-track` for new branches to prevent accidental push to main.

## crow Session Creation

All `crow` and `git worktree` commands require `dangerouslyDisableSandbox: true`.

### Session Naming Convention

The session name **MUST** match the worktree directory name (which is the branch slug without the `feature/` prefix):

- **Ticket-based:** `{repo}-{ticket_number}-{slug}` (e.g., `crow-51-drag-drop-photo`)
- **PR-based:** `{repo}-{pr_branch_slug}` (e.g., `acme-api-45-jwt-validation`)
- **Natural language:** `{repo}-{feature-slug}` (e.g., `acme-api-update-auth`)

This keeps session names, worktree paths, and branch names consistent.

### Complete Step-by-Step Flow

After the LLM resolves names (slug, branch, worktree path, session name), detects any existing PR, and composes the prompt content, the setup is executed by calling `setup.sh`.

> **IMPORTANT:** All `crow`, `gh`, `glab`, and `git` commands require `dangerouslyDisableSandbox: true`. The `setup.sh` call itself must use `dangerouslyDisableSandbox: true` since it runs these commands internally.

#### Step 0: Pre-fetch ticket (and PR) content

Before writing the prompt file, fetch the ticket title, body, and comments so they can be embedded directly into the `## Ticket` section. This avoids the launched Claude Code session sitting on a `dangerouslyDisableSandbox` permission prompt at startup when it tries to run `gh issue view` itself (issue #295).

Use `dangerouslyDisableSandbox: true` for all of these fetches. Issue each as a **single, clean invocation** — one `gh`/`git` command per Bash call, with no `cd …`/`echo`/`find` prefix and no `| head`/`| tail` pipe. The permission allowlist prefix-matches the *whole* command, so bundling defeats the `Bash(gh issue view:*)` / `Bash(gh api:*)` rules and forces a prompt (see CLAUDE.md → "Fetching Ticket / PR Data").

**GitHub:**
```bash
gh issue view {ticket_url} --comments
# Fallback if the above returns empty output (see issue #295):
gh api repos/{owner}/{repo}/issues/{number}
gh api repos/{owner}/{repo}/issues/{number}/comments
```

**GitLab (non-default host):**
```bash
GITLAB_HOST={host} glab issue view {number} --repo {org/repo} --comments
```

**Jira (Atlassian MCP — task-only):**
Fetch the work item via the `atlassian` MCP server: resolve `cloudId` with
`getAccessibleAtlassianResources`, then `getJiraIssue` for `{key}` (full key, e.g.
`MAXX-6859` — not the numeric suffix). Use the work item's summary as
`{ticket_title}`. The code provider/PR detection below still runs against the
workspace's configured GitHub/GitLab repo, not Jira. (Fallback when MCP is
unconfigured: `acli jira workitem view {key} --json`, summary at `.fields.summary`.)

**If an existing PR was detected for this ticket**, also fetch the PR view so it can be embedded:
```bash
gh pr view {pr_url} --comments
# Fallback:
gh api repos/{owner}/{repo}/pulls/{pr_number}
gh api repos/{owner}/{repo}/issues/{pr_number}/comments
```

**Also detect the repo's default branch** so the worktree base ref and the prompt template's PR/MR commands aren't pinned to `main` (issue #397). One clean call per repo:

```bash
gh repo view {owner}/{repo} --json defaultBranchRef --jq .defaultBranchRef.name
# GitLab equivalent:
glab repo view {org}/{repo} -F json | jq -r .default_branch
```

Store the result as `{base_branch}` for substitution into Step 2 and into the prompt template. `setup.sh` will auto-detect from `origin/HEAD` if you omit the flag, but passing it explicitly avoids the round-trip and keeps the prompt template accurate.

Render the fetched content into the prompt template per the formatting rules in **First Prompt Template** below.

#### Step 1: Write the prompt file

The LLM writes the prompt content (see template below — with the pre-fetched ticket/PR content embedded) to a file:

```bash
mkdir -p {devRoot}/.claude/prompts
cat > {devRoot}/.claude/prompts/crow-prompt-{session_name}.md << 'PROMPT'
{prompt content — see template below}
PROMPT
```

#### Step 2: Run setup.sh

`setup.sh` resolves the coding agent automatically from `{devRoot}/.claude/config.json`: it prefers `agentsByKind["work"]`, falls back to `defaultAgentKind`, and finally to `claude-code`. Pass `--agent-kind <claude-code|cursor|codex>` only if you need to override the configured choice for a single invocation (e.g. for testing). The binary is looked up on PATH and in the standard install locations for the selected agent — pass `--agent-binary <path>` to pin it explicitly.

```bash
.claude/skills/crow-workspace/setup.sh \
  --dev-root "{devRoot}" \
  --workspace "{workspace}" \
  --repo "{repo}" \
  --repo-path "{repo_path}" \
  --slug "{slug}" \
  --branch "{branch}" \
  --worktree-path "{worktree_path}" \
  --base-branch "{base_branch}" \
  --session-name "{session_name}" \
  --provider "{provider}" \
  --cli "{cli}" \
  --ticket-url "{ticket_url}" \
  --ticket-title "{ticket_title}" \
  --ticket-number {ticket_number} \
  --prompt-content "{devRoot}/.claude/prompts/crow-prompt-{session_name}.md" \
  --primary
```

If an existing PR was detected, also pass:
```
  --pr-number {pr_number} \
  --pr-url "{pr_url}" \
  --pr-branch "{pr_branch}"
```

For GitLab, also pass:
```
  --host "{gitlab_host}"
```

#### Step 3: Parse the result

The script outputs JSON to stdout. On success:
```json
{
  "status": "ok",
  "session_id": "uuid",
  "terminal_id": "uuid",
  "worktree_path": "/path/to/worktree",
  "branch": "feature/name"
}
```

On failure:
```json
{
  "status": "error",
  "step": "git_worktree_add",
  "message": "error details",
  "partial": { "session_id": "uuid-if-created" }
}
```

If the script fails, read the error message and apply error handling (see below).

#### Multi-Repo Flow

For cross-workspace setups with multiple repos, call `setup.sh` once per repo:

1. **First repo** (primary): Use `--primary` flag. Capture `session_id` from output.
2. **Additional repos**: Pass `--session-id {uuid}` from the first call's output and use `--skip-launch` (Claude only launches once, in the primary worktree).

Detect each secondary repo's default branch with the same `gh repo view --json defaultBranchRef` call from Step 0 — each repo has its own (bigbang uses `master`, others use `main`).

```bash
# Secondary repo (no launch, attach to existing session):
.claude/skills/crow-workspace/setup.sh \
  --session-id "{session_id_from_first_call}" \
  --dev-root "{devRoot}" \
  --workspace "{other_workspace}" \
  --repo "{other_repo}" \
  --repo-path "{other_repo_path}" \
  --slug "{slug}" \
  --branch "{other_base_branch}" \
  --base-branch "{other_base_branch}" \
  --worktree-path "{other_repo_path}" \
  --session-name "{session_name}" \
  --provider "{provider}" \
  --cli "{cli}" \
  --skip-launch
```

## First Prompt Template

IMPORTANT: Always use full absolute paths, never abbreviated (`...`) or home-relative (`~`) paths.

The prompt is written to `{devRoot}/.claude/prompts/crow-prompt-{session_name}.md`. Plan mode is set by the `--permission-mode plan` flag in `setup.sh`'s launch command — do not prepend `/plan` to the prompt body (it would be parsed as a slash command by the receiving session). See issue #313.

**Repo descriptions for the prompt table:**

Extract dynamically from first non-heading line of CLAUDE.md or README.md. If no description is found, leave the Description column empty.

~~~markdown
# Workspace Context

| Repository | Path | Branch | Description |
|------------|------|--------|-------------|
| my-app | /Users/name/Dev/MyOrg/my-app-45-jwt | feature/my-app-45-jwt-validation | Auth gateway service |
| my-project | /Users/name/Dev/MyGitLab/my-project | main | Infrastructure chart |
| my-config | /Users/name/Dev/MyGitLab/my-config | - | Configuration overrides |

## Ticket

**{ticket_title}** — {ticket_url}

{ticket_body_verbatim}

### Comments

{rendered_comments_or_no_comments_marker}

---

If you need fresher ticket data later, re-fetch with (all gh/glab commands MUST use dangerouslyDisableSandbox: true — they will fail with TLS certificate errors otherwise, and will prompt for approval):

```bash
gh issue view {ticket_url} --comments
# Fallback if the above returns empty output (see issue #295):
gh api repos/{owner}/{repo}/issues/{number}
gh api repos/{owner}/{repo}/issues/{number}/comments
```

## Instructions
1. Study the ticket above — it has been pre-fetched and embedded. Only re-run gh/glab if you need fresher data; those calls use dangerouslyDisableSandbox: true and will prompt for approval.
2. Create an implementation plan
3. Implement the plan
4. Commit the changes with a descriptive message
5. Push the branch to origin
6. Open a pull request linked to the ticket:

```bash
gh pr create --title "<summary>" --body "Closes #123" --base {base_branch}
```

## Custom Instructions

{workspace customInstructions text — include verbatim}
~~~

If the workspace config contains a non-empty `customInstructions` field, append a `## Custom Instructions` section at the end of the prompt with its contents verbatim. Omit this section entirely if the field is absent, null, or empty.

For GitLab tickets, substitute `glab mr create --title "<summary>" --description "Closes #{number}" --target-branch {base_branch}` on step 6 (use "merge request" instead of "pull request"). When no ticket number is available, drop the body/description and fall back to `gh pr create --fill` / `glab mr create --fill`.

### Embedding pre-fetched content

Render the content pre-fetched in **Step 0** directly into the template:

- **Ticket body**: insert verbatim — preserve markdown, code fences, line breaks. Do not summarize or reformat.
- **Comments**: for each comment, render as `**@{login}** ({created_at}):` followed by the comment body, separated by `---` between comments. If there are zero comments, write `_No comments._` in the `### Comments` block.
- **PR body / PR review comments** (existing-PR variant): same rules as ticket body/comments.

If the pre-fetch fails (network, auth, rate limit), fall back to the prior behavior: leave a short `_(Ticket pre-fetch failed — run the gh command below to retrieve.)_` note in place of the embedded body and proceed. The launched Claude can re-fetch with the documented commands.

**When an existing PR was detected**, add this section to the prompt between `## Ticket` and `## Instructions` (with PR content also pre-fetched in Step 0 and embedded):

~~~markdown
## Existing Pull Request

**{pr_title}** — {pr_url}

{pr_body_verbatim}

### PR Comments

{rendered_pr_comments_or_no_comments_marker}

---

This workspace is checked out on the PR's branch. Review existing changes with `git log origin/{base_branch}..HEAD` before adding new work.

If you need fresher PR data later, re-fetch with (dangerouslyDisableSandbox: true):

```bash
gh pr view {pr_url} --comments
# Fallback if the above returns empty:
gh api repos/{owner}/{repo}/pulls/{pr_number}
gh api repos/{owner}/{repo}/issues/{pr_number}/comments
```
~~~

And update the Instructions section to:

~~~markdown
## Instructions
1. Review the existing PR and ticket above — both have been pre-fetched and embedded. Use `git log origin/{base_branch}..HEAD` to see the current branch's changes. Only re-run gh/glab if you need fresher data; those calls use dangerouslyDisableSandbox: true and will prompt for approval.
2. Create an implementation plan that builds on the existing work
3. Implement the plan
4. Commit the changes with a descriptive message
5. Push the branch — this updates the existing PR automatically; do NOT open a new one
~~~

For MyGitLab, add: `6. If any changes to my-project are required, create a new worktree with a feature branch before making modifications`

### CLI Commands for Fetching Issues

The manager uses these in **Step 0** to pre-fetch ticket and PR content. They are also documented in the prompt so the launched Claude can re-run them for fresher data.

**GitHub:**
```bash
gh issue view {url} --comments
gh pr view {url} --comments
# Fallbacks if the above return empty (see issue #295):
gh api repos/{owner}/{repo}/issues/{number}
gh api repos/{owner}/{repo}/issues/{number}/comments
gh api repos/{owner}/{repo}/pulls/{pr_number}
```

**GitLab (non-default host like gitlab.example.com):**
```bash
GITLAB_HOST=gitlab.example.com glab issue view {number} --repo {org/repo} --comments
GITLAB_HOST=gitlab.example.com glab mr view {number} --repo {org/repo} --comments
```

## Error Handling and Self-Correction

If `setup.sh` returns a JSON error (`"status": "error"`):
1. Read the `step` and `message` fields to understand what failed
2. If the error indicates a usage problem (wrong arg format, missing param), fix the invocation and retry
3. If `partial.session_id` is present, the session was created before the failure — you can pass `--session-id` to retry without recreating the session
4. If the error is in `git_worktree_add`, the branch may already exist — try with a different slug
5. Append a one-line correction to `{devRoot}/CLAUDE.md` under "## Known Issues / Corrections"

| Error | Response |
|-------|----------|
| `parse_args` — Missing required arguments | Check that all required flags are provided |
| `git_fetch` — git fetch failed | Check repo path exists and has remote configured |
| `git_worktree_add` — worktree creation failed | Branch may exist; script auto-retries after cleanup |
| `new_session` — crow new-session failed | Crow app may not be running. Inform user. |
| `add_worktree` — crow add-worktree failed | Use full UUID from session, check paths |
| `new_terminal` — crow new-terminal failed / could not create window | Session may not exist (check session_id), or tmux couldn't spawn a window under load |
| `write_prompt` — prompt file not found | Verify prompt was written before calling setup.sh |

## crow CLI Reference

```
crow new-session --name "name"
crow rename-session --session <uuid> "name"
crow select-session --session <uuid>
crow list-sessions
crow get-session --session <uuid>
crow set-status --session <uuid> active|completed|archived
crow delete-session --session <uuid>
crow set-ticket --session <uuid> --url "..." [--title "..."] [--number N]
crow add-worktree --session <uuid> --repo "name" --repo-path "/main/repo/path" --path "/worktree/path" --branch "..." [--primary]
crow list-worktrees --session <uuid>
crow new-terminal --session <uuid> --cwd "/..." [--name "..."] [--command "..."]
crow list-terminals --session <uuid>
crow send --session <uuid> --terminal <uuid> "text"
crow add-link --session <uuid> --label "..." --url "..." --type ticket|pr|repo|custom
crow list-links --session <uuid>
```

All commands return JSON and require `dangerouslyDisableSandbox: true`.

## Examples

### GitHub Issue URL
```
/crow-workspace https://github.com/RadiusMethod/acme-api/issues/45
```
→ Fetches issue #45, matches acme-api in RadiusMethod
→ Creates worktree at ~/Dev/RadiusMethod/acme-api-45-jwt-validation
→ Creates crow session with ticket metadata + worktree + Claude Code terminal

### Natural Language
```
/crow-workspace "update acme-api authentication"
```
→ Scans repos, matches acme-api by keyword
→ Creates worktree with feature slug
→ Creates crow session with Claude Code terminal

### Cross-Workspace
```
/crow-workspace "integrate my-project with acme-api gateway"
```
→ Matches my-project (MyGitLab) + acme-api (RadiusMethod)
→ Creates worktrees for both, one crow session
→ Claude launches in highest-scoring repo
