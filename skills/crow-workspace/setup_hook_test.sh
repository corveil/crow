#!/usr/bin/env bash
# Unit tests for the per-worktree prepare-commit-msg hook (CROW-518).
#
# Sources setup.sh (sourcing is side-effect free thanks to the BASH_SOURCE
# guard at the bottom) and exercises install_commit_hook / remove_commit_hook
# end-to-end against a throwaway git repo with two worktrees. The hook
# binary itself is also driven directly so each acceptance criterion in
# the ticket gets a dedicated row.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/setup.sh"

pass=0; fail=0
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    pass=$((pass+1)); echo "  ok: $1"
  else
    fail=$((fail+1)); echo "  FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"
  fi
}
contains() { # contains <description> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then
    pass=$((pass+1)); echo "  ok: $1"
  else
    fail=$((fail+1)); echo "  FAIL: $1"; echo "    [$2] does not contain [$3]"
  fi
}
not_contains() { # not_contains <description> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then
    pass=$((pass+1)); echo "  ok: $1"
  else
    fail=$((fail+1)); echo "  FAIL: $1"; echo "    [$2] should NOT contain [$3]"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-hook-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

UUID="11112222-3333-4444-5555-666677778888"
OTHER_UUID="aaaa1111-bbbb-2222-cccc-3333dddd4444"

# ─── Synthetic devRoot + repo with two worktrees ─────────────────────────────

DEV_ROOT="$TMP/devroot"
mkdir -p "$DEV_ROOT/.claude"
echo '{}' > "$DEV_ROOT/.claude/config.json"

MAIN_REPO="$TMP/repo"
mkdir -p "$MAIN_REPO"
git -C "$MAIN_REPO" init -q -b main
git -C "$MAIN_REPO" config user.email tester@example.invalid
git -C "$MAIN_REPO" config user.name "Tester"
echo "seed" > "$MAIN_REPO/README.md"
git -C "$MAIN_REPO" add README.md
git -C "$MAIN_REPO" commit -q -m "seed"

WT_A="$TMP/wt-a"
WT_B="$TMP/wt-b"
git -C "$MAIN_REPO" worktree add -q "$WT_A" -b wt-a
git -C "$MAIN_REPO" worktree add -q "$WT_B" -b wt-b

# Source the helpers (main is guarded).
# shellcheck disable=SC1090
source "$SETUP_SH"
# Re-assign globals after sourcing (top-level resets them to "").
DEV_ROOT="$TMP/devroot"

# Helpers used across tests.
hook_path() { echo "$(git -C "$1" rev-parse --git-dir)/hooks/prepare-commit-msg"; }
session_file() { git -C "$1" rev-parse --git-path CROW_SESSION_ID; }

# Drive the hook directly the way `git commit` would.
# Usage: run_hook <worktree> <msg_file> [<source>]
run_hook() {
  ( cd "$1" && "$(hook_path "$1")" "$2" "${3:-}" )
}

# ─── Install: happy path under wt-a ──────────────────────────────────────────
echo "== install wt-a =="
WORKTREE_PATH="$WT_A"
SESSION_ID="$UUID"
install_commit_hook

check "hook installed in wt-a" "yes" \
  "$([[ -x "$(hook_path "$WT_A")" ]] && echo yes || echo no)"
check "CROW_SESSION_ID written in wt-a" "$UUID" \
  "$(tr -d '[:space:]' < "$(session_file "$WT_A")")"
check "core.hooksPath set per-worktree" "$(git -C "$WT_A" rev-parse --git-path hooks)" \
  "$(git -C "$WT_A" config --get core.hooksPath)"
check "extensions.worktreeConfig enabled on main" "true" \
  "$(git -C "$MAIN_REPO" config --get extensions.worktreeConfig)"

# ─── Test A: body without trailers gets both appended ────────────────────────
echo "== test A: append both trailers =="
MSG_A="$TMP/msg-a"
printf 'feat: add thing\n\nbody text\n' > "$MSG_A"
run_hook "$WT_A" "$MSG_A"
actual_a="$(cat "$MSG_A")"
contains "test A: Crow-Session trailer appended" "$actual_a" "Crow-Session: $UUID"
contains "test A: Co-Authored-By trailer appended" "$actual_a" \
  "Co-Authored-By: Claude <noreply@anthropic.com>"
contains "test A: subject preserved" "$actual_a" "feat: add thing"
contains "test A: body preserved" "$actual_a" "body text"

# ─── Test B: existing trailers → no duplication ──────────────────────────────
echo "== test B: idempotent on already-trailered message =="
MSG_B="$TMP/msg-b"
cat > "$MSG_B" <<EOF
feat: another thing

body line

Crow-Session: $UUID
Co-Authored-By: Claude <noreply@anthropic.com>
EOF
before_b="$(cat "$MSG_B")"
run_hook "$WT_A" "$MSG_B"
after_b="$(cat "$MSG_B")"
check "test B: message unchanged" "$before_b" "$after_b"
check "test B: exactly one Crow-Session line" "1" \
  "$(grep -cE '^Crow-Session:' "$MSG_B" | tr -d '[:space:]')"
check "test B: exactly one Co-Authored-By line" "1" \
  "$(grep -cE '^Co-Authored-By: Claude' "$MSG_B" | tr -d '[:space:]')"

# ─── Test B2: existing Crow-Session w/ DIFFERENT uuid → preserved, not dupped ─
echo "== test B2: foreign Crow-Session is preserved =="
MSG_B2="$TMP/msg-b2"
cat > "$MSG_B2" <<EOF
chore: thing

Crow-Session: $OTHER_UUID
EOF
run_hook "$WT_A" "$MSG_B2"
after_b2="$(cat "$MSG_B2")"
contains "test B2: foreign Crow-Session preserved" "$after_b2" "Crow-Session: $OTHER_UUID"
not_contains "test B2: our Crow-Session NOT appended on top" "$after_b2" "Crow-Session: $UUID"
contains "test B2: Co-Authored-By still appended" "$after_b2" \
  "Co-Authored-By: Claude <noreply@anthropic.com>"

# ─── Test D: empty message → no-op ───────────────────────────────────────────
echo "== test D: empty + comment-only messages =="
MSG_D_EMPTY="$TMP/msg-d-empty"
: > "$MSG_D_EMPTY"
run_hook "$WT_A" "$MSG_D_EMPTY"
check "test D: empty message stays empty" "" "$(cat "$MSG_D_EMPTY")"

MSG_D_COMMENT="$TMP/msg-d-comment"
printf '# please enter the commit message\n# lines starting with # are ignored\n' > "$MSG_D_COMMENT"
before_d="$(cat "$MSG_D_COMMENT")"
run_hook "$WT_A" "$MSG_D_COMMENT"
check "test D: comment-only file unchanged" "$before_d" "$(cat "$MSG_D_COMMENT")"

# ─── Test E: merge / squash sources → no-op ─────────────────────────────────
echo "== test E: merge/squash sources =="
MSG_E_MERGE="$TMP/msg-e-merge"
printf 'Merge branch foo\n\nautomatic merge\n' > "$MSG_E_MERGE"
before_e_merge="$(cat "$MSG_E_MERGE")"
run_hook "$WT_A" "$MSG_E_MERGE" merge
check "test E: merge commit unchanged" "$before_e_merge" "$(cat "$MSG_E_MERGE")"

MSG_E_SQUASH="$TMP/msg-e-squash"
printf 'Squashed\n\nbody\n' > "$MSG_E_SQUASH"
before_e_squash="$(cat "$MSG_E_SQUASH")"
run_hook "$WT_A" "$MSG_E_SQUASH" squash
check "test E: squash commit unchanged" "$before_e_squash" "$(cat "$MSG_E_SQUASH")"

# ─── Test F: empty CROW_SESSION_ID → no-op ──────────────────────────────────
echo "== test F: empty CROW_SESSION_ID file =="
: > "$(session_file "$WT_A")"
MSG_F="$TMP/msg-f"
printf 'subject\n\nbody\n' > "$MSG_F"
before_f="$(cat "$MSG_F")"
run_hook "$WT_A" "$MSG_F"
check "test F: empty session id leaves message alone" "$before_f" "$(cat "$MSG_F")"
# Restore the session id file for the rest of the suite.
printf '%s\n' "$UUID" > "$(session_file "$WT_A")"

# ─── Test G: worktree isolation ─────────────────────────────────────────────
echo "== test G: sibling worktree is unaffected =="
# wt-b never had install_commit_hook called → no per-worktree hooksPath,
# no CROW_SESSION_ID, no hook file. A real commit there must NOT carry
# Crow-Session.
echo "isolation seed" > "$WT_B/isolation"
git -C "$WT_B" add isolation
git -C "$WT_B" commit -q -m "isolation: no trailer please"
WT_B_MSG="$(git -C "$WT_B" log -1 --format='%B')"
not_contains "test G: wt-b commit has no Crow-Session trailer" "$WT_B_MSG" "Crow-Session"
not_contains "test G: wt-b commit has no Co-Authored-By trailer" "$WT_B_MSG" "Co-Authored-By: Claude"
# Sanity: wt-a's CROW_SESSION_ID file is NOT visible from wt-b's gitdir.
check "test G: wt-b gitdir has no CROW_SESSION_ID" "no" \
  "$([[ -f "$(session_file "$WT_B")" ]] && echo yes || echo no)"

# ─── Test G2: wt-a commits via `git commit` DO carry trailers ───────────────
echo "== test G2: real commit in wt-a wears both trailers =="
echo "real seed" > "$WT_A/real"
git -C "$WT_A" add real
git -C "$WT_A" -c user.email=a@a.invalid -c user.name=A commit -q -m "real: just subject"
WT_A_MSG="$(git -C "$WT_A" log -1 --format='%B')"
contains "test G2: wt-a real commit has Crow-Session" "$WT_A_MSG" "Crow-Session: $UUID"
contains "test G2: wt-a real commit has Co-Authored-By" "$WT_A_MSG" \
  "Co-Authored-By: Claude <noreply@anthropic.com>"

# ─── Test C: attributionTrailers:false → install removes pre-existing hook ──
echo "== test C: opt-out removes hook + CROW_SESSION_ID =="
cat > "$DEV_ROOT/.claude/config.json" <<'JSON'
{"attributionTrailers": false}
JSON
# Confirm the hook is currently in place from earlier tests.
check "test C: hook present before opt-out call" "yes" \
  "$([[ -f "$(hook_path "$WT_A")" ]] && echo yes || echo no)"
install_commit_hook
check "test C: hook removed when opt-out" "no" \
  "$([[ -f "$(hook_path "$WT_A")" ]] && echo yes || echo no)"
check "test C: CROW_SESSION_ID removed when opt-out" "no" \
  "$([[ -f "$(session_file "$WT_A")" ]] && echo yes || echo no)"

# Restore the enabled config so any later tests (or reruns) work.
echo '{}' > "$DEV_ROOT/.claude/config.json"

# ─── Summary ────────────────────────────────────────────────────────────────
echo
echo "── prepare-commit-msg hook tests: $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
