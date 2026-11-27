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

Checkout restores the PR head into the working tree, including attacker-controlled harness config that Crow stripped at launch (CROW-960: `.cursor/`, `.grok/`, `.agents/`, `.gemini/`, `.muse/`, `.codex/`, repo-root `.mcp.json`, `.claude/settings.json`, `.claude/settings.local.json`). **Immediately after checkout — a separate Bash call, before any other tool use — have Crow re-strip those layers from the working tree:**

```bash
crow review restrip --session "$CROW_SESSION_ID"
```

Run it with the sandbox disabled, like every `crow` call, and do **not** chain it onto `gh pr checkout` with `&&` (a compound misses the allowlist prefix). Crow's daemon removes the files itself (CROW-1492): an `rm` run inside your sandbox cannot remove `.claude/settings*.json`, because Claude Code's sandbox blocks writes to them. Do **not** run your own `rm`, `git rm` or `git add` on these paths instead: the daemon removes them from the working tree only, and the index entry must survive, same as `SessionService.strip*ConfigFromReviewClone`. It never deletes `.claude/` wholesale — Crow's copied review skill lives under `.claude/skills/`.

On success it prints `"ok" : true` and lists what it removed. It checks every path again after removing them.

**If the command fails or exits non-zero, for any reason, stop the review.** Do not continue to Step 2, do not post anything, and tell the operator: `Review stopped: the CROW-1492 re-strip failed: <the error it printed>`. A failed strip means PR-supplied harness config may still be live in this session.

If any of those paths appear in the PR's changed-files list, inspect them with `git show HEAD:<path>` or `gh pr diff` — they are gone from disk by design, not missing from the review.

### Step 2: Gather PR Information

Get the PR details including title, description, and changed files:

```bash
gh pr view "$PR" --json title,body,headRefName,baseRefName,additions,deletions,changedFiles,files
```

Do **not** read the PR's earlier reviews yet. On a re-review you read them only after your fresh pass (see **Re-reviews** in Step 3), so they cannot anchor your findings.

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

**Failure modes (do this before the checklist below):**

Name the **three likeliest ways this change fails in production**, given what it does, the inputs it receives, the state it touches and what calls it. Check each one against the code or a test, and record the result: **ruled out** (cite the `file:line` or test that rules it out) or **a finding**. A failure mode you could not check is a finding, not a pass. The review body lists all three under `### Failure modes checked`.

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

**State findings, not fixes:**

Each finding gives three things:

- **The defect**: what is wrong.
- **The evidence**: `file:line`, a repro, or the test that fails or is missing.
- **The expected behavior**: what correct looks like.

Add at most one line of direction. Do **not** write:

- patches, diffs or code blocks of the fix;
- step-by-step change lists;
- product decisions that belong to the ticket owner (if the ticket is ambiguous, name the open question instead);
- predictions about your next verdict ("I'd expect to approve once…").

The implementer owns the fix. A review that writes the fix stops being an independent check on it.

**Re-reviews:**

When the PR already has a review from you (a re-review round), review it fresh first, then check off your earlier findings:

1. Do the full review above on the **whole PR diff**, as if you were seeing it for the first time. Form your findings from the code before you reread your earlier review, and do not limit them to what changed since then.
2. Only now read your earlier reviews and the author's replies. Run each command on its own, and set `PR_NUMBER` to the number the first command prints:

   ```bash
   gh pr view "$PR" --json number --jq .number
   ```

   ```bash
   gh pr view "$PR" --json reviews,comments
   ```

   ```bash
   gh api "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments"
   ```

3. Check each earlier finding off against the current code: **fixed** (cite where), **declined** (judge the author's reply under "Judge a declined finding on its merits", counting the rounds of disagreement from these threads), or **still open**.

If the fresh pass finds nothing new, say so (`Full pass over the diff: nothing new.`). Do not copy your earlier review and add "fixed in <sha>".

{{CROW_REVIEW_WORKSPACE_INSTRUCTIONS}}
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

A cross-tenant finding (see the floor under Grading discipline) is refute-checked against the code that would confine it to its own tenant: the tenant predicate on the query, the tenant key on the cache, the tenant argument the caller passes. If you cannot find that code, its absence is the verification — the finding stays **Red** and is not downgraded for being hard to reproduce.

### Step 5: Post Review

> **Dry run (`--no-post` / `--dry-run`):** if `POST=false`, render the full review body below to **stdout** and **stop** — do not run `gh pr review`, and do not add `ci:full`. The Step 5a guardrails still apply to the drafted body. Everything past this note assumes `POST=true`.

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

### Tenant effect
- [Required in every review. When the repo has no tenancy or the diff touches no tenant-scoped code, this section is one line, `n/a — <why>`, with no checklist. Otherwise answer the four tenant-effect checklist questions from Grading discipline, one line each with `file:line` or test evidence, then list each cross-tenant finding as **Red** or as **Deferred (#N)** with the deferral-bar items you checked.]

### Failure modes checked
1. [Likeliest production failure — ruled out by `file:line` / test, or → finding]
2. [...]
3. [...]

### Security Review
- [Security findings: defect, evidence, expected behavior]
- **Strengths:** [optional — only when something is worth calling out]

### Code Quality
- [Code quality findings: defect, evidence, expected behavior]

### Earlier findings (re-reviews only)
- [Each finding from your earlier reviews: **fixed** (where), **rationale accepted** (why it holds), **still open** (why the reply does not hold), or **needs a human** (see below)]

### Needs a human (only when a finding is handed off)
- [Finding — reviewer's case in one line; author's case in one line. Added `crow:needs-human`.]

**Recommendation:** [Approve | Request Changes] — driven by [N Red, M Yellow, K Green] findings.

---

[THE FOOTER LINE FROM STEP 5b]
```

### Step 5a: Pre-submit Guardrails (REQUIRED)

Before running `gh pr review`, you **must** pass all three checks below on your draft body. If the target check or the verdict consistency check fails, **do not post** — stop and report what failed (which paths or verdict mismatched) so a human can intervene. A failed tenant effect check is a drafting error: fix the draft, then run all three checks again.

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

#### Tenant effect check

The draft body must carry a `### Tenant effect` section that agrees with the verdict:

- **No section** ⇒ do not post. Add it.
- **`n/a`** passes only with a reason, and only when the repo has no tenancy or the diff touches no tenant-scoped code. If the body cites tenant-scoped code anywhere else, `n/a` fails.
- **"Yes" to "Can org A's row change org B's outcome?"** — or a cross-tenant finding anywhere in the body — needs a matching **Red** finding or a **Deferred (#N)** entry that names every deferral-bar item you checked. Otherwise ⇒ do not post. Grade it Red.
- **A cross-tenant Red** follows the verdict rule like any Red: under a policy where Red blocks, the recommendation must be `Request Changes`.

Only after **all three** checks pass, write the final body (footer included) to a file, e.g. `$TMPDIR/crow-review-body.md`, with your file-writing tool, and post it with exactly one of these two flags:

```bash
# If approving:
gh pr review "$PR" --approve --body-file "$TMPDIR/crow-review-body.md"

# If requesting changes (also the default when uncertain):
gh pr review "$PR" --request-changes --body-file "$TMPDIR/crow-review-body.md"
```

Pass the body with `--body-file`, never inline with `--body "…"`: a review quotes code, and the shell would expand any `$(…)`, backtick or `$VAR` in it.

### Step 5b: Attribution (REQUIRED)

See `.claude/skills/crow-attribution/FOOTER.md` for the full rules. Print this session's review footer (like every `crow` command, run it with `dangerouslyDisableSandbox: true`):

```bash
crow attribution --kind review
```

It prints one line naming the harness and, when Crow knows it, the model, e.g.
`[🐦‍⬛ Reviewed by Crow via {{CROW_AGENT_DISPLAY_NAME}} · claude-opus-5-5](https://github.com/corveil/crow)`.
The review body MUST end with a blank line followed by that line, copied verbatim.

If the command fails, or its output is not one line that starts with `[🐦‍⬛ Reviewed by Crow via ` and ends with `](https://github.com/corveil/crow)`, use this line instead:

```
[🐦‍⬛ Reviewed by Crow via {{CROW_AGENT_DISPLAY_NAME}}](https://github.com/corveil/crow)
```

- Copy the printed line into the body file as text. Never put `$(crow attribution …)` or any other `${…}` / `$(…)` expansion in the body or the `gh` command: it silently fails inside single-quoted heredocs and the literal text leaks into the review body (#447).
- Don't add, edit or guess a model yourself. If the printed line has none, post it without one.
- Do not modify the URL — the link target is always `https://github.com/corveil/crow`, never a fork or a derived value from the local git remote.
- Do not wrap the line in additional formatting (no blockquote, no extra brackets, no surrounding text).
- This line MUST appear in every review body, regardless of whether you used `--approve` or `--request-changes`.

### Step 5c: Add `ci:full` after an approve (CROW-1306)

`ci:full` starts the label-gated suite on a repo whose required check is named `CI Gate` (ADR 0082). The approver's review session applies it. Run this step only after `gh pr review "$PR" --approve` exits 0.

- `--request-changes` does not add `ci:full`. Stop after that review posts.
- `--no-post` / `--dry-run` (`POST=false`) does not add `ci:full`. Step 5 never posts, so this step does not run.
- A PR with no check named exactly `CI Gate` does not get `ci:full`. Do not create the label in that repo.

After `--approve` succeeds, run this on its own (one Bash call):

```bash
gh pr view "$PR" --json statusCheckRollup --jq '[.statusCheckRollup[]? | (.name // .context)] | any(. == "CI Gate")'
```

If that command does not print `true`, stop. Do not create `ci:full` and do not edit the PR.

If it prints `true`, resolve the PR's repo, ensure the label there, then add it. Each of these is its own Bash call. The label lives on the repo that owns the PR (the base), so pass `--repo` — a fork checkout must not grow the label. Set `REPO` to the `owner/repo` the first command prints. `gh label create` exiting because the label already exists is success — continue to the add. `gh pr edit --add-label` on a PR that already has `ci:full` is success.

```bash
gh pr view "$PR" --json url --jq '(.url | split("/"))[3:5] | join("/")'
```

```bash
gh label create "ci:full" --repo "$REPO" --color 0E8A16 --description "Run the full CI suite (ADR 0082)"
```

```bash
gh pr edit "$PR" --add-label "ci:full"
```

If creating or adding the label fails for a reason other than the label already existing, report the failure and leave the approval in place. A missing `ci:full` keeps the fail-closed `CI Gate` red.

### Step 5d: Add `crow:needs-human` after a hand-off (CROW-1511)

Run this step only when the posted review lists a finding under **Needs a human**: you and the author disagreed on it for two rounds, and the finding is not cross-tenant (see "Judge a declined finding on its merits"). It runs after either verdict. `--no-post` / `--dry-run` skips it.

Resolve the PR's repo, ensure the label there, then add it. Each of these is its own Bash call, and `REPO` is the `owner/repo` the first command prints. `gh label create` failing because the label already exists counts as success; go on to the add.

```bash
gh pr view "$PR" --json url --jq '(.url | split("/"))[3:5] | join("/")'
```

```bash
gh label create "crow:needs-human" --repo "$REPO" --color D93F0B --description "A reviewer and the author disagree on a finding; a human decides"
```

```bash
gh pr edit "$PR" --add-label "crow:needs-human"
```

If creating or adding the label fails for any other reason, report the failure. The review body still names the finding under **Needs a human**.

### Important Notes

- Be thorough but concise
- Prioritize security issues
- Include file:line references for specific issues
- Don't include sensitive information in the review
- If tests fail, note which ones and why
{{CROW_REVIEW_VERDICT_NOTES}}
- **Never** use `--comment` — a Crow review must always be a verdict. If you would have commented, request changes instead.
- All `gh` and `git` commands require `dangerouslyDisableSandbox: true`
