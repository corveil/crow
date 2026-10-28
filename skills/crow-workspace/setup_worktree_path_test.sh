#!/usr/bin/env bash
# shellcheck disable=SC2034
# Unit tests for validate_worktree_path (CROW-1396): setup.sh refuses a
# --worktree-path outside {devRoot}/{workspace}/{dir} before `git worktree add`
# creates anything. Mirrors WorktreePathPolicyTests in Packages/CrowCore.
#
# Sources setup.sh (main is guarded) and runs validate_worktree_path in a
# subshell per case, since `die` exits.

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

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed (validate_worktree_path reads workspace names with jq)"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1396-path-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
source "$SETUP_SH"

DEV_ROOT="$TMP/devroot"
mkdir -p "$DEV_ROOT/.claude" "$DEV_ROOT/Corveil" "$DEV_ROOT/bmlt-enabled"
cat > "$DEV_ROOT/.claude/config.json" <<'JSON'
{"workspaces":[{"name":"Corveil"},{"name":"personal"}]}
JSON

# run <workspace> <path> → prints "OK" or the die JSON; never exits the test.
run() {
  ( WORKSPACE="$1"; WORKTREE_PATH="$2"; validate_worktree_path 2>/dev/null && echo OK )
}

echo "== accepted =="
check "workspace folder" "OK" "$(run Corveil "$DEV_ROOT/Corveil/crow-1396-x")"
check "differently-cased workspace folder" "OK" "$(run Corveil "$DEV_ROOT/corveil/crow-1396-x")"
check "--workspace in a different case" "OK" "$(run corveil "$DEV_ROOT/Corveil/crow-1396-x")"
check "workspace folder not yet on disk" "OK" "$(run personal "$DEV_ROOT/personal/x")"
check "review clone" "OK" "$(run Corveil "$DEV_ROOT/crow-reviews/crow-pr-1")"
check "trailing slash" "OK" "$(run Corveil "$DEV_ROOT/Corveil/x/")"
check "'..' that stays inside a workspace" "OK" "$(run Corveil "$DEV_ROOT/personal/../Corveil/x")"
ln -s "$DEV_ROOT" "$TMP/devroot-link"
check "dev root configured as a symlink, path spelled the same way" "OK" \
  "$(DEV_ROOT="$TMP/devroot-link"; run Corveil "$TMP/devroot-link/Corveil/x")"

echo "== rejected =="
out=$(run Corveil "$DEV_ROOT/corveil-3004-dock-greeting")
contains "directly in the dev root" "$out" "directly in the dev root"
contains "error JSON status" "$out" '"status":"error"'
contains "error step" "$out" '"step":"validate_worktree_path"'
contains "names the path" "$out" "'$DEV_ROOT/corveil-3004-dock-greeting'"
contains "names the expected form" "$out" "$DEV_ROOT/{workspace}/{dir}"
contains "names the review root" "$out" "$DEV_ROOT/crow-reviews/{dir}"
contains "names the configured workspaces" "$out" "Configured workspaces: Corveil, personal"
contains "names the fix" "$out" "crow workspace add"

contains "nested too deep" "$(run Corveil "$DEV_ROOT/Corveil/worktrees/x")" "nested 1 level too deep inside 'Corveil'"
contains "unconfigured workspace folder" "$(run Corveil "$DEV_ROOT/bmlt-enabled/x")" "'bmlt-enabled' is not a configured workspace"
contains "outside the dev root" "$(run Corveil "$TMP/elsewhere/x")" "outside the dev root"
contains "'..' escaping the dev root" "$(run Corveil "$DEV_ROOT/Corveil/../../escape")" "outside the dev root"
contains "relative path" "$(run Corveil "Corveil/x")" "not an absolute path"
contains "the workspace folder itself" "$(run Corveil "$DEV_ROOT/Corveil")" "the 'Corveil' folder itself"
contains "the dev root itself" "$(run Corveil "$DEV_ROOT")" "the dev root itself"
contains "path's workspace differs from --workspace" "$(run personal "$DEV_ROOT/Corveil/x")" \
  "inside workspace 'Corveil', but --workspace is 'personal'"
contains "path spelled through a dev-root symlink" "$(run Corveil "$TMP/devroot-link/Corveil/x")" \
  "does not spell out the dev root"
ln -s "$DEV_ROOT/Corveil" "$DEV_ROOT/alias"
contains "symlink alias of a workspace folder" "$(run Corveil "$DEV_ROOT/alias/x")" \
  "'alias' is a symlink to 'Corveil'"
mkdir -p "$TMP/outside-ws"
ln -s "$TMP/outside-ws" "$DEV_ROOT/personal"
contains "workspace folder symlinked out of the dev root" "$(run personal "$DEV_ROOT/personal/x")" "outside the dev root"

echo "== no config =="
rm "$DEV_ROOT/.claude/config.json"
out=$(run Corveil "$DEV_ROOT/Corveil/x")
contains "no workspaces configured" "$out" "(none configured)"
check "review clone still accepted without config" "OK" "$(run Corveil "$DEV_ROOT/crow-reviews/x")"

echo "== nothing created =="
check "rejected path was not created" "no" "$([[ -e "$DEV_ROOT/corveil-3004-dock-greeting" || -e "$DEV_ROOT/Corveil/worktrees" ]] && echo yes || echo no)"

echo
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
