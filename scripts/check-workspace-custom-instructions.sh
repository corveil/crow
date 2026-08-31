#!/usr/bin/env bash
# Guard for issue #683, ported from the retired
# Tests/CrowTests/CustomInstructionsSkillTests when the root monolith test tree
# was deleted (CROW-926). New-workspace creation must inject the *matched*
# workspace's customInstructions verbatim, without falling back to `defaults`.
#
# The /crow-workspace and /crow-batch-workspace skills drive prompt assembly —
# no Swift code builds the creation prompt — so the guard is a text check over
# each skill's SKILL.md AND its bundled Resources/*.template (release builds
# scaffold new dev roots from the template, so a fix must land in both or
# scaffolded installs silently regress).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$ROOT_DIR"

fail=0

require_frontmatter() {
    # require_frontmatter <file> <expected-name>
    local file="$1"
    local expected_name="$2"
    if [ ! -f "$file" ]; then
        echo "MISSING FILE: $file" >&2
        fail=1
        return
    fi
    if [ "$(head -n 1 "$file")" != "---" ]; then
        echo "DRIFT: $file is missing YAML frontmatter (Claude Code 2.1.x needs name + description)" >&2
        fail=1
        return
    fi
    require "$file" "name: ${expected_name}" "description:"
}

require() {
    # require <file> <substring>...
    local file="$1"; shift
    if [ ! -f "$file" ]; then
        echo "MISSING FILE: $file" >&2
        fail=1
        return
    fi
    local needle
    for needle in "$@"; do
        if ! grep -Fq -- "$needle" "$file"; then
            echo "DRIFT: $file is missing required text: $needle" >&2
            fail=1
        fi
    done
}

# /crow-workspace skill + its scaffold template (issue #683 acceptance criteria).
# shellcheck disable=SC2016  # backticks in the needles are literal, not command substitution
for f in skills/crow-workspace/SKILL.md Resources/crow-workspace-SKILL.md.template; do
    require "$f" \
        "Resolve custom instructions" \
        'workspaces["{workspace}"].customInstructions' \
        "{custom_instructions}" \
        "## Custom Instructions" \
        "verbatim" \
        'do not** read `defaults`'
done

# /crow-batch-workspace skill + its scaffold template.
# shellcheck disable=SC2016  # backticks in the needles are literal, not command substitution
for f in skills/crow-batch-workspace/SKILL.md Resources/crow-batch-workspace-SKILL.md.template; do
    require "$f" \
        'workspaces["{workspace}"].customInstructions' \
        "## Custom Instructions" \
        'not `defaults`'
done

# Claude Code 2.1.x registers slash commands only when SKILL.md has YAML
# frontmatter (name + description). Release scaffolds from Resources/*.template,
# so both halves must carry the block or installed skills silently regress.
for skill in \
    crow-workspace \
    crow-batch-workspace \
    crow-review-pr \
    crow-create-ticket \
    crow-show-image; do
    require_frontmatter "skills/${skill}/SKILL.md" "$skill"
    require_frontmatter "Resources/${skill}-SKILL.md.template" "$skill"
done

# The review skill's two halves must stay byte-identical: dev builds read
# `skills/crow-review-pr/SKILL.md`, release builds scaffold from
# `Resources/crow-review-pr-SKILL.md.template`, and `Scaffolder.bundledReviewSkill()`
# falls through from the first to the second. An edit landed in only one half
# ships a different skill to installed builds with nothing to catch it — which is
# how the CROW-963 verdict-policy placeholders could have gone live for dev
# builds only.
#
# Scoped to crow-review-pr deliberately. The other four skills have the same
# two-halves structure and deserve the same gate, but crow-batch-workspace is
# currently drifted (`settings.json` vs `settings.local.json`) and fixing that is
# a separate change, not this ticket's.
review_left="skills/crow-review-pr/SKILL.md"
review_right="Resources/crow-review-pr-SKILL.md.template"
if [ -f "$review_left" ] && [ -f "$review_right" ] && ! diff -q "$review_left" "$review_right" >/dev/null; then
    echo "DRIFT: $review_left and $review_right differ — an edit must land in both halves" >&2
    diff -u "$review_right" "$review_left" | head -40 >&2
    fail=1
fi

# The review skill's verdict policy is rendered at launch by
# `ReviewVerdictPolicy.expand` (CROW-963). If a placeholder is dropped or
# renamed, the corresponding block silently reverts to whatever static text
# replaced it — and the per-workspace setting stops reaching the agent.
for placeholder in \
    "{{CROW_REVIEW_VERDICT_RULE}}" \
    "{{CROW_REVIEW_GRADING_GUIDANCE}}" \
    "{{CROW_REVIEW_VERDICT_TABLE}}" \
    "{{CROW_REVIEW_VERDICT_NOTES}}"; do
    require "skills/crow-review-pr/SKILL.md" "$placeholder"
    require "Resources/crow-review-pr-SKILL.md.template" "$placeholder"
done

# CROW-974: pre-submit guardrails must be present in both halves so every
# harness (Claude slash-command, Cursor/Codex/OpenCode/Grok/Antigravity inline)
# refuses mis-targeted or verdict-inconsistent reviews before `gh pr review`.
for f in skills/crow-review-pr/SKILL.md Resources/crow-review-pr-SKILL.md.template; do
    require "$f" \
        "### Step 5a: Pre-submit Guardrails (REQUIRED)" \
        "#### Target check" \
        "#### Verdict consistency check" \
        "Zero overlap" \
        "do not post"
done

# CROW-960: `gh pr checkout` restores attacker-controlled harness config into
# a live review session. Both halves must re-strip immediately after checkout
# (working-tree `rm`, never `git rm`) so Cursor/Grok/Antigravity/Claude/Muse/
# Codex close in one place rather than four per-adapter changes.
# shellcheck disable=SC2016  # the rm command is a literal needle, not expansion
for f in skills/crow-review-pr/SKILL.md Resources/crow-review-pr-SKILL.md.template; do
    require "$f" \
        "CROW-960" \
        "rm -rf -- .cursor .grok .agents .gemini .muse .codex .mcp.json .claude/settings.json .claude/settings.local.json" \
        "Do **not** \`git rm\`"
done

# CROW-1166: set-ticket failure must abort setup, not warn-and-continue.
# Swallowing it left ticket_url null while add-link still attached a cosmetic
# ticket row, which hid the miss from the UI (mark-in-review needs ticketURL).
for f in skills/crow-workspace/setup.sh Resources/crow-workspace-setup.sh.template; do
    require "$f" 'die "set_ticket"' 'crow set-ticket failed'
    if grep -Fq 'Warning: set-ticket failed' "$f"; then
        echo "DRIFT: $f still swallows set-ticket failure" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "check-workspace-custom-instructions: FAILED (see #683)" >&2
    exit 1
fi
echo "check-workspace-custom-instructions: OK"
