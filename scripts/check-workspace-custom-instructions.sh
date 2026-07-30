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

if [ "$fail" -ne 0 ]; then
    echo "check-workspace-custom-instructions: FAILED (see #683)" >&2
    exit 1
fi
echo "check-workspace-custom-instructions: OK"
