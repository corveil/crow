# Crow Create Ticket

Create a new ticket (GitHub issue via `gh`, or GitLab issue via `glab`) for a repo in
the current Crow workspace, assigned to the invoking user and labeled `crow:auto` so
Crow's auto-pickup queue implements it.

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

| Workspace `provider` | CLI  | GITLAB_HOST          |
|----------------------|------|----------------------|
| `github`             | gh   | —                    |
| `gitlab`             | glab | workspace `host`     |

## Instructions

You are creating a new ticket from the title/body in `$ARGUMENTS`. Follow these steps.
All `gh`/`glab`/`git` commands below require `dangerouslyDisableSandbox: true`.

### Step 1: Parse the title and body

Extract the title (required) and optional body from `$ARGUMENTS` per the **Arguments**
rules above. If there is no usable title, ask the user for one and stop until provided.

The body is the text the user provided (or empty). It MUST end with the Crow
attribution footer (see **Step 4b**): a blank line, then exactly
`[🐦‍⬛ Created with Crow via Claude Code](https://github.com/radiusmethod/crow)`.
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

### Step 4: Create the issue (assigned + labeled `crow:auto`)

In both commands below, `BODY` is the user-provided body followed by the required
attribution footer from **Step 4b** (a blank line, then the canonical link).

**GitHub:**
```bash
gh issue create --repo OWNER/REPO \
  --title "TITLE" \
  --body "BODY

[🐦‍⬛ Created with Crow via Claude Code](https://github.com/radiusmethod/crow)" \
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

[🐦‍⬛ Created with Crow via Claude Code](https://github.com/radiusmethod/crow)" \
  --assignee "{username}" \
  --label "crow:auto" \
  --yes
```

### Step 4b: Attribution (REQUIRED)

The body passed to `gh issue create --body` / `glab issue create --description` MUST
end with a blank line followed by exactly this line:

```
[🐦‍⬛ Created with Crow via Claude Code](https://github.com/radiusmethod/crow)
```

- Do not modify the link text.
- Do not modify the URL — the link target is always `https://github.com/radiusmethod/crow`, never a fork or a derived value from the local git remote.
- Do not wrap the line in additional formatting (no blockquote, no extra brackets, no surrounding text).
- This line MUST appear in every issue body, whether GitHub or GitLab, and whether or not the user supplied any body text.

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
- Assignee is resolved dynamically (`gh api user` / `glab api user`); never hardcode a
  login.
- All `gh`, `glab`, and `git` commands require `dangerouslyDisableSandbox: true`.
