# Crow Create Ticket

Create a new ticket (GitHub issue via `gh`, GitLab issue via `glab`, or Jira work item
via the **`jira` MCP server**) for a repo/project in the current Crow workspace,
assigned to the invoking user and labeled `crow:auto`. For GitHub/GitLab, Crow's
auto-pickup queue then implements it. (Jira's auto-pickup isn't wired — the label is
for parity/board visibility — but the work item is created **with an assignee in one
step**, which `acli` could never do; CROW-528.)

## Important: Sandbox Bypass

All `gh`, `glab`, and `git` commands require `dangerouslyDisableSandbox: true` because
they communicate over the network (TLS) or read outside the sandbox-allowed
directories. They will fail with TLS certificate errors otherwise.

## Arguments

- `$ARGUMENTS` — the ticket title (required) and an optional body.
  - The first quoted string is the **title**.
  - Any remaining text (including multiple lines) is the **body**.
  - If no title can be determined, ask the user for one before proceeding.

Examples:
```
/crow-create-ticket "Fix tab URL hash routing"
/crow-create-ticket "Add JWT validation" The /auth endpoint should reject expired tokens.
```

## Activation

This skill activates when:
- User invokes `/crow-create-ticket` command
- User asks to "create a ticket", "file an issue", or "open an issue" in Crow

## Configuration

Configuration is at `{devRoot}/.claude/config.json` (managed by the Crow app), the
same file used by `/crow-workspace`. It maps each workspace to a provider/cli/host:

```json
{
  "devRoot": "/Users/name/Dev",
  "workspaces": {
    "RadiusMethod": { "provider": "github", "cli": "gh" },
    "MyGitLab": { "provider": "gitlab", "cli": "glab", "host": "gitlab.example.com" }
  },
  "defaults": { "provider": "github", "cli": "gh" }
}
```

### Provider Detection

| Workspace `taskProvider` | Tool         | Notes                       |
|--------------------------|--------------|-----------------------------|
| `github` (or unset)      | gh           | —                           |
| `gitlab`                 | glab         | workspace `host`            |
| `jira`                   | `jira` MCP   | project `jiraProjectKey`   |

When a workspace sets `taskProvider: "jira"`, tasks live in Jira (code/PRs still on the
workspace's GitHub/GitLab repo). Use the `jira_*` MCP tools instead of `gh`/`glab` for
the steps below.

## Instructions

You are creating a new ticket from the title/body in `$ARGUMENTS`. Follow these steps.
All `gh`/`glab`/`git` commands below require `dangerouslyDisableSandbox: true`.

### Step 1: Parse the title and body

Extract the title (required) and optional body from `$ARGUMENTS` per the **Arguments**
rules above. If there is no usable title, ask the user for one and stop until provided.

The body is the text the user provided (or empty). It MUST end with the Crow
attribution footer (see **Step 4b** and `.claude/skills/crow-attribution/FOOTER.md`):
a blank line, then the literal attribution line shown in **Step 4** below.
Crow has already filled in the agent name for this session — copy the line
as-is into the body.
Do NOT add any other footer — no "Generated with Claude Code" line and no co-author
trailer. The Crow attribution is the only footer.

### Step 2: Determine the target repo and provider

1. Read the config: `cat {devRoot}/.claude/config.json`
2. If the user named a specific repo, use it. Otherwise, scan the repos in each
   configured workspace and match against the title/body by keyword (the same
   scoring approach as `/crow-workspace`: direct name match, workspace mention,
   keyword matches). Pick the highest-scoring repo.
3. If no repo clearly matches, or several are tied, **ask the user** which repo to
   file the ticket against. Do not guess.
4. Resolve the workspace's `provider`, `cli`, and (for GitLab) `host` from config,
   falling back to `defaults`.
5. Derive the canonical repo identifier from the repo's git remote:
   ```bash
   git -C {repo_path} remote get-url origin
   ```
   - GitHub → parse `OWNER/REPO` from the URL.
   - GitLab → parse the `org/repo` (group/subgroup) path from the URL.

### Step 3: Resolve the current user's login

**GitHub:**
```bash
gh api user --jq .login
```

**GitLab (non-default host):**
```bash
GITLAB_HOST={host} glab api user --jq '.username'
```

**Jira (`jira` MCP):** the assignee is the Jira server's configured account —
i.e. its `JIRA_USERNAME` email. `jira_create_issue`'s `assignee` param accepts that
email directly, so no separate account-id lookup is needed. (If you need to confirm
the resolved account, call `jira_get_user_profile {email}`.)

### Step 4: Create the issue (assigned + labeled `crow:auto`)

In both commands below, `BODY` is the user-provided body followed by the required
attribution footer from **Step 4b** (a blank line, then the canonical link).

**GitHub:**
```bash
gh issue create --repo OWNER/REPO \
  --title "TITLE" \
  --body "BODY

[🐦‍⬛ Created with Crow via {{CROW_AGENT_DISPLAY_NAME}}](https://github.com/radiusmethod/crow)" \
  --assignee "{login}" \
  --label "crow:auto"
```
- If the user-provided body is empty, the body is just the attribution footer — never
  pass `--body ""`, or `gh` would open an interactive editor.

**GitLab (non-default host):**
```bash
GITLAB_HOST={host} glab issue create --repo {org/repo} \
  --title "TITLE" \
  --description "BODY

[🐦‍⬛ Created with Crow via {{CROW_AGENT_DISPLAY_NAME}}](https://github.com/radiusmethod/crow)" \
  --assignee "{username}" \
  --label "crow:auto" \
  --yes
```

**Jira (`jira` MCP):** call `jira_create_issue` with `project_key` =
`jiraProjectKey`, `issue_type` `Task`, `summary` = `TITLE`, `description` = `BODY`
(including the attribution footer), `assignee` = the email from Step 3, and
`additional_fields` `{"labels":["crow:auto"]}` — so the work item is created already
assigned, the core fix in CROW-522. There is no missing-label fallback to run (Step 5
is GitHub/GitLab-only); Jira accepts arbitrary labels.

### Step 4b: Attribution (REQUIRED)

See `.claude/skills/crow-attribution/FOOTER.md` for the full rules. The body passed to
`gh issue create --body` / `glab issue create --description` MUST end with a blank line
followed by:

```
[🐦‍⬛ Created with Crow via {{CROW_AGENT_DISPLAY_NAME}}](https://github.com/radiusmethod/crow)
```

- Crow filled in the agent name for this session before this skill reached you — paste the line literally; do not re-introduce `${…}` shell parameter expansion of your own (it silently fails inside single-quoted heredocs and the literal text leaks into the issue body).
- Do not modify the URL — the link target is always `https://github.com/radiusmethod/crow`, never a fork or a derived value from the local git remote.
- Do not wrap the line in additional formatting (no blockquote, no extra brackets, no surrounding text).
- This line MUST appear in every issue body — GitHub, GitLab, or Jira — and whether or not the user supplied any body text.

### Step 5: Missing-label fallback

If `issue create` fails because the `crow:auto` label does not exist in the repo,
create it once, then retry Step 4:

**GitHub:**
```bash
gh label create "crow:auto" --repo OWNER/REPO \
  --color FBCA04 --description "Crow auto-pickup"
```

**GitLab:**
```bash
GITLAB_HOST={host} glab label create --repo {org/repo} \
  --name "crow:auto" --color "#FBCA04" --description "Crow auto-pickup"
```

### Step 6: Report the result

`issue create` prints the URL of the new issue. Report it back to the user along with
the repo, assignee, and `crow:auto` label so they can confirm Crow will pick it up.

## Notes

- This skill only creates the ticket. Crow's auto-pickup queue (driven by the
  `crow:auto` label) is responsible for starting implementation — do not also set up a
  worktree or session here. Use `/crow-workspace` for that.
- Assignee is resolved dynamically (`gh api user` / `glab api user` / the `jira` MCP
  server's configured `JIRA_USERNAME`); never hardcode a login or accountId.
- All `gh`, `glab`, and `git` commands require `dangerouslyDisableSandbox: true`.
