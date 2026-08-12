---
name: crow-review-pr
description: >-
  Perform a comprehensive code and security review on a GitHub pull request,
  then post the findings as a PR review. Use when the user invokes
  /crow-review-pr or asks to review a pull request through Crow.
---

# Crow Review PR

Perform a comprehensive code and security review on a GitHub pull request, then post the findings as a PR review.

## Important: Sandbox Bypass

All `gh` and `git` commands require `dangerouslyDisableSandbox: true` because they need network/TLS access.

## Arguments

- `$ARGUMENTS` - The PR URL or number to review (required)

## Activation

This skill activates when:
- User invokes `/crow-review-pr` command
- User asks to "review a PR" or "review this pull request"
- This is a review session (the session was created via the Crow Reviews board)

## Instructions

You are performing a code and security review on PR $ARGUMENTS. Follow these steps:

### Step 1: Checkout the PR

```bash
gh pr checkout $ARGUMENTS
```

### Step 2: Gather PR Information

Get the PR details including title, description, and changed files:

```bash
gh pr view $ARGUMENTS --json title,body,headRefName,baseRefName,additions,deletions,changedFiles,files
```

### Step 3: Review the Code

Read all changed files in the PR. For each file, analyze:

**Security Review:**
- Authentication/authorization issues
- Input validation vulnerabilities
- Injection risks (SQL, command, XSS)
- Secrets/credentials exposure
- Cryptographic weaknesses
- Insecure configurations
- OWASP Top 10 concerns

**Code Quality:**
- Logic errors
- Error handling
- Resource leaks
- Race conditions
- API design issues
- Missing tests for new code

### Step 4: Run Static Analysis

Run the `gh`/`git` review commands (Steps 1–3 and Step 5) as **single, clean invocations** so the allowlist auto-approves them — one command per Bash call, no `cd …`/`echo` prefix or pipe bundling (see CLAUDE.md → "Fetching Ticket / PR Data"). Use a tool's own directory flag (`go -C <dir>`, `git -C <path>`) rather than `cd <dir> && …`.

For Go projects:
```bash
go -C core vet ./...
go -C core test ./... -v 2>&1 | head -50
```

For JavaScript/TypeScript projects:
```bash
npm run lint 2>&1 | head -50
```

For Swift projects:
```bash
swift build 2>&1 | tail -20
```

For Python projects:
```bash
ruff check . 2>&1 | head -50
```

### Step 5: Post Review

Every Crow review must end with a verdict — **exactly one** of the two actions below. Comment-only reviews (`--comment` / `event: COMMENT`) are **not permitted**: they are ambiguous, don't move the PR forward, and effectively no-op the review.

{{CROW_REVIEW_VERDICT_RULE}}

{{CROW_REVIEW_GRADING_GUIDANCE}}

Draft the review using this format:

```markdown
## Code & Security Review

### Critical Issues (if any)
[List blocking issues that must be fixed]

### Security Review
**Strengths:**
- [Positive security aspects]

**Concerns:**
- [Security issues found]

### Code Quality
- [Code quality issues]

### Summary Table
| Color  | Meaning      | Verdict effect            |
|--------|--------------|---------------------------|
{{CROW_REVIEW_VERDICT_TABLE}}

**Recommendation:** [Approve | Request Changes] — driven by [N Red, M Yellow, K Green] findings.

---

[🐦‍⬛ Reviewed by Crow via {{CROW_AGENT_DISPLAY_NAME}}](https://github.com/corveil/crow)
```

### Step 5a: Pre-submit Guardrails (REQUIRED)

Before running `gh pr review`, you **must** pass both checks below on your draft body. If either fails, **do not post** — stop and report what failed (which paths or verdict mismatched) so a human can intervene.

#### Target check

Re-fetch the PR's changed-file paths (same data as Step 2):

```bash
gh pr view $ARGUMENTS --json files --jq '.files[].path'
```

Collect every repo-relative path cited in your review body — `` `path/to/file:42` ``, `` `path/to/file` ``, bullet references, etc. Strip line/column suffixes (`:42`, `:42-46`) so you compare paths only.

- If the body cites **one or more** specific file paths, at least one cited path must appear in the PR's changed-files list.
- **Zero overlap** ⇒ do not post. Report that the review body appears to be about a different PR (list the orphan paths and the PR's actual changed files).

If the review cites no specific file paths (only general observations), this check passes.

#### Verdict consistency check

The `**Recommendation:**` line in your draft body must agree with the `gh pr review` flag you will pass:

| Body recommendation | Required flag |
|---------------------|---------------|
| `Approve` | `--approve` |
| `Request Changes` | `--request-changes` |

A body that says **Approve** with `--request-changes` (or the reverse) ⇒ **do not post**. Report the mismatch.

Only after **both** checks pass, post the review using exactly one of these two flags:

```bash
# If approving:
gh pr review $ARGUMENTS --approve --body "YOUR_REVIEW_HERE"

# If requesting changes (also the default when uncertain):
gh pr review $ARGUMENTS --request-changes --body "YOUR_REVIEW_HERE"
```

### Step 5b: Attribution (REQUIRED)

See `.claude/skills/crow-attribution/FOOTER.md` for the full rules. The review body passed to
`gh pr review --body` MUST end with a blank line followed by:

```
[🐦‍⬛ Reviewed by Crow via {{CROW_AGENT_DISPLAY_NAME}}](https://github.com/corveil/crow)
```

- Crow filled in the agent name for this session before this skill reached you — paste the line literally; do not re-introduce `${…}` shell parameter expansion of your own (it silently fails inside single-quoted heredocs and the literal text leaks into the review body).
- Do not modify the URL — the link target is always `https://github.com/corveil/crow`, never a fork or a derived value from the local git remote.
- Do not wrap the line in additional formatting (no blockquote, no extra brackets, no surrounding text).
- This line MUST appear in every review body, regardless of whether you used `--approve` or `--request-changes`.

### Important Notes

- Be thorough but concise
- Prioritize security issues
- Include file:line references for specific issues
- Don't include sensitive information in the review
- If tests fail, note which ones and why
{{CROW_REVIEW_VERDICT_NOTES}}
- **Never** use `--comment` — a Crow review must always be a verdict. If you would have commented, request changes instead.
- All `gh` and `git` commands require `dangerouslyDisableSandbox: true`
