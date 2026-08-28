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

`$ARGUMENTS` is the raw argument string. **Parse it — never paste it whole into a command.** A Crow review session passes just the PR reference, but a manual `/crow-review-pr` invocation may append flags (`/crow-review-pr 2437 --no-post`), and pasting the whole string makes step 1 `gh pr checkout 2437 --no-post` fail on an unknown flag.

- **PR reference** (required) — the first URL or number token in `$ARGUMENTS` (e.g. `2437` or `https://github.com/org/repo/pull/2437`). Every command below writes it as `$PR`; set `PR` to it in Step 0 and pass `"$PR"` to `gh`/`git`, never the raw `$ARGUMENTS`.
- **`--no-post`** / **`--dry-run`** (optional) — render the review to stdout and **skip Step 5** (do not post). Use it when you are the PR author (GitHub rejects a self-review), when iterating on this skill, or when you want to read the findings before deciding to post. Sets `POST=false`; otherwise `POST=true`.

## Activation

This skill activates when:
- User invokes `/crow-review-pr` command
- User asks to "review a PR" or "review this pull request"
- This is a review session (the session was created via the Crow Reviews board)

## Instructions

You are performing a code and security review on PR $ARGUMENTS. Follow these steps:

### Step 0: Parse the arguments

Split `$ARGUMENTS` (see **Arguments** above) before running anything:

- `PR` — the PR URL or number. Use `"$PR"` in every `gh`/`git` command below; a stray `--no-post` reaching `gh pr checkout` fails at the first command.
- `POST` — `false` if `$ARGUMENTS` contains `--no-post` or `--dry-run`, otherwise `true`. Gates Step 5.

### Step 1: Checkout the PR

```bash
gh pr checkout "$PR"
```

Checkout restores the PR head into the working tree, including attacker-controlled harness config that Crow stripped at launch (CROW-960: `.cursor/`, `.grok/`, `.agents/`, `.gemini/`, `.muse/`, `.codex/`, repo-root `.mcp.json`, `.claude/settings.json`, `.claude/settings.local.json`). **Immediately after checkout — a separate Bash call, before any other tool use — re-strip those layers from the working tree.** Do **not** chain the `rm` onto `gh pr checkout` with `&&` (a compound misses the allowlist prefix). Do **not** `git rm` or `git add` them: the index entry must survive, same as `SessionService.strip*ConfigFromReviewClone`. Do **not** delete `.claude/` wholesale — Crow's copied review skill lives under `.claude/skills/`.

```bash
rm -rf -- .cursor .grok .agents .gemini .muse .codex .mcp.json .claude/settings.json .claude/settings.local.json
```

`rm` is idempotent when a path is absent. If any of those paths appear in the PR's changed-files list, inspect them with `git show HEAD:<path>` or `gh pr diff` — they are gone from disk by design, not missing from the review.

### Step 2: Gather PR Information

Get the PR details including title, description, and changed files:

```bash
gh pr view "$PR" --json title,body,headRefName,baseRefName,additions,deletions,changedFiles,files
```

### Step 3: Review the Code

**Architecture & Existing Patterns (study this before scoring the diff):**

A PR can be correct in isolation yet wrong for the codebase — it reinvents a pathway that already exists, or builds the wrong shape because it misread the current control flow. Judge the change against how the system works **today**, not only against its own hunks:

- Read the surrounding modules, the call sites the change touches, and any ADRs in that area (`docs/adr/`) — not just the changed lines.
- Name the existing pathway the change should have extended, or state plainly that none exists.
- Raise a finding when the PR:
  - Invents a parallel mechanism where a small extension of current behavior would do.
  - Over-engineers relative to the established patterns in the same area.
  - Assumes a behavior is missing that the codebase already provides.
  - Misunderstands the current control flow and builds the wrong shape because of it.

These are defects in **this change**, not future improvements — grade them **Yellow** (should-fix) or **Red** (must-fix), never Green "consider later." A forced redesign or a reject is in scope when the approach cannot be made to fit an existing pattern.

Then read all changed files in the PR. For each file, analyze:

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

For Go projects — the module is not always at the repo root (corveil's lives in `go/`, not `core/`). Find its directory, then vet/test **that** directory. Drop `-v`: on a large suite it buries the failures and the final tally under thousands of `PASS` lines, and a leading `head` then cuts off inside the first package. Keep the **tail** so the failures and the summary line survive.

```bash
git ls-files '*go.mod'                        # module dir(s); use the parent of the go.mod path (`.` if at root)
go -C <module-dir> vet ./... 2>&1 | tail -50
go -C <module-dir> test ./... 2>&1 | tail -50
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

### Step 4b: Verify every Red finding (REQUIRED)

A Red finding is merge-blocking, so it must be *established*, not asserted — a hedged "this might…" a reader can dismiss is not worth blocking a PR over. For **each Red** finding, before you write it up, do exactly one of:

- **Reproduce it** — a throwaway test, a probe script, or a log line that makes the bad behavior happen. Delete the scratch afterward.
- **Refute-check it** — read and cite the specific code (`file:line`) that would refute the finding, and confirm it does not.

State in the finding which you did ("reproduced with a temporary test that triggered the double write", "confirmed against `mount.go:42` — no filter is applied"). A Red you could not verify is downgraded to **Yellow** or dropped; it must earn its blocking verdict. This composes with the workspace's `--review-blocking-severity` gate — a finding that forces `--request-changes` should have been checked, not guessed.

### Step 5: Post Review

> **Dry run (`--no-post` / `--dry-run`):** if `POST=false`, render the full review body below to **stdout** and **stop** — do not run `gh pr review`. The Step 5a guardrails still apply to the drafted body. Everything past this note assumes `POST=true`.

Every Crow review must end with a verdict — **exactly one** of the two actions below. Comment-only reviews (`--comment` / `event: COMMENT`) are **not permitted**: they are ambiguous, don't move the PR forward, and effectively no-op the review.

{{CROW_REVIEW_VERDICT_RULE}}

{{CROW_REVIEW_GRADING_GUIDANCE}}

Draft the review using this format:

```markdown
## Code & Security Review

### Critical Issues (if any)
[List blocking issues that must be fixed]

### Architecture / Existing Patterns
- **Existing pathway:** [name the current path the change should have used, or "none — this is a genuinely new capability"]
- [Architecture findings, if any — with file references and severity. State when the PR reinvents an existing path, over-engineers, assumes a behavior the codebase already has, or misreads the current control flow.]

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
gh pr view "$PR" --json files --jq '.files[].path'
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
gh pr review "$PR" --approve --body "YOUR_REVIEW_HERE"

# If requesting changes (also the default when uncertain):
gh pr review "$PR" --request-changes --body "YOUR_REVIEW_HERE"
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
