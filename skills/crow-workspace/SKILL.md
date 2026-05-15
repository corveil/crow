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

### Provider Detection from URL

| URL Contains | Provider | CLI | GITLAB_HOST |
|---|---|---|---|
| `github.com` | github | gh | - |
| `gitlab.example.com` | gitlab | glab | gitlab.example.com |
| `gitlab.com` | gitlab | glab | gitlab.com |
| `gitlab-il2.example.com` | gitlab | glab | gitlab-il2.example.com |

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

#### Step 1: Write the prompt file

The LLM writes the prompt content (see template below) to a file:

```bash
mkdir -p {devRoot}/.claude/prompts
cat > {devRoot}/.claude/prompts/crow-prompt-{session_name}.md << 'PROMPT'
{prompt content — see template below}
PROMPT
```

#### Step 2: Run setup.sh

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
  --claude-binary "$(which claude)" \
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

```bash
# Secondary repo (no launch, attach to existing session):
.claude/skills/crow-workspace/setup.sh \
  --session-id "{session_id_from_first_call}" \
  --dev-root "{devRoot}" \
  --workspace "{other_workspace}" \
  --repo "{other_repo}" \
  --repo-path "{other_repo_path}" \
  --slug "{slug}" \
  --branch "main" \
  --worktree-path "{other_repo_path}" \
  --session-name "{session_name}" \
  --provider "{provider}" \
  --cli "{cli}" \
  --skip-launch
```

## First Prompt Template

IMPORTANT: Always use full absolute paths, never abbreviated (`...`) or home-relative (`~`) paths.

The prompt is written to `{devRoot}/.claude/prompts/crow-prompt-{session_name}.md`. It starts with `/plan` to enter plan mode.

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

IMPORTANT: All gh/glab commands MUST use dangerouslyDisableSandbox: true. They will fail with TLS certificate errors otherwise. Do NOT attempt sandboxed first.

```bash
gh issue view https://github.com/org/repo/issues/123 --comments
```

## Instructions
1. Study the ticket thoroughly — use dangerouslyDisableSandbox: true for ALL gh/glab commands
2. Create an implementation plan
3. Implement the plan
4. Commit the changes with a descriptive message
5. Push the branch to origin
6. Open a pull request linked to the ticket:

```bash
gh pr create --title "<summary>" --body "Closes #123" --base main
```

## Custom Instructions

{workspace customInstructions text — include verbatim}
~~~

If the workspace config contains a non-empty `customInstructions` field, append a `## Custom Instructions` section at the end of the prompt with its contents verbatim. Omit this section entirely if the field is absent, null, or empty.

For GitLab tickets, substitute `glab mr create --title "<summary>" --description "Closes #{number}" --target-branch main` on step 6 (use "merge request" instead of "pull request"). When no ticket number is available, drop the body/description and fall back to `gh pr create --fill` / `glab mr create --fill`.

**When an existing PR was detected**, add this section to the prompt between `## Ticket` and `## Instructions`:

~~~markdown
## Existing Pull Request

There is an existing open PR for this issue. Review it before planning:

```bash
gh pr view {pr_url} --comments
```

This workspace is checked out on the PR's branch. Review existing changes with `git log origin/main..HEAD` before adding new work.
~~~

And update the Instructions section to:

~~~markdown
## Instructions
1. Review the existing PR and its changes — use dangerouslyDisableSandbox: true for ALL gh/glab commands
2. Study the ticket thoroughly
3. Create an implementation plan that builds on the existing work
4. Implement the plan
5. Commit the changes with a descriptive message
6. Push the branch — this updates the existing PR automatically; do NOT open a new one
~~~

For MyGitLab, add: `7. If any changes to my-project are required, create a new worktree with a feature branch before making modifications`

### CLI Commands for Fetching Issues

**GitHub:**
```bash
gh issue view {url} --comments
gh pr view {url} --comments
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
| `new_terminal` — crow new-terminal failed | Session may not exist; check session_id |
| `send_launch` — crow send failed | Terminal may not be ready; retry |
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
