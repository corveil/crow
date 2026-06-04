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

Verdict rule — **only a review whose findings are entirely Green (or empty) may approve**. Any Yellow or Red finding forces `--request-changes`.

- **Approve** (`--approve`): no Red, no Yellow, only Green or no findings.
- **Request Changes** (`--request-changes`): any Red **or** any Yellow finding.

Yellow findings are "should fix" — the implementing agent will address them as soon as it sees the request-changes verdict, so rejecting on Yellow lands them in the same round trip instead of a follow-up. Comment-only reviews remain forbidden; if uncertain, request changes.

Post the review using exactly one of these two flags:

```bash
# If approving:
gh pr review $ARGUMENTS --approve --body "YOUR_REVIEW_HERE"

# If requesting changes (also the default when uncertain):
gh pr review $ARGUMENTS --request-changes --body "YOUR_REVIEW_HERE"
```

Use this format for the review:

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
| Red    | Must fix     | Request changes           |
| Yellow | Should fix   | Request changes           |
| Green  | Consider     | Approve allowed           |

**Recommendation:** [Approve | Request Changes] — driven by [N Red, M Yellow, K Green] findings.

---

[🐦‍⬛ Reviewed by Crow via {{CROW_AGENT_DISPLAY_NAME}}](https://github.com/radiusmethod/crow)
```

### Step 5b: Attribution (REQUIRED)

See `.claude/skills/crow-attribution/FOOTER.md` for the full rules. The review body passed to
`gh pr review --body` MUST end with a blank line followed by:

```
[🐦‍⬛ Reviewed by Crow via $CROW_AGENT_DISPLAY_NAME](https://github.com/radiusmethod/crow)
```

- Use `$CROW_AGENT_DISPLAY_NAME` from the environment (Crow injects it per session). Fall back to `Claude Code` if unset.
- Do not modify the URL — the link target is always `https://github.com/radiusmethod/crow`, never a fork or a derived value from the local git remote.
- Do not wrap the line in additional formatting (no blockquote, no extra brackets, no surrounding text).
- This line MUST appear in every review body, regardless of whether you used `--approve` or `--request-changes`.

### Important Notes

- Be thorough but concise
- Prioritize security issues
- Include file:line references for specific issues
- Don't include sensitive information in the review
- If tests fail, note which ones and why
- Use `--approve` only when findings are entirely Green or empty (no Red, no Yellow).
- Use `--request-changes` when there is any Red or Yellow finding.
- **Never** use `--comment` — a Crow review must always be a verdict. If you would have commented, request changes instead.
- All `gh` and `git` commands require `dangerouslyDisableSandbox: true`
