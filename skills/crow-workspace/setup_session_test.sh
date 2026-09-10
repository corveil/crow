#!/usr/bin/env bash
# shellcheck disable=SC2034
# Unit tests for create_session's set-ticket handling (CROW-1166) and
# worktree registration / launch gating (CROW-1218).
#
# Sources setup.sh (sourcing is side-effect free thanks to the BASH_SOURCE
# guard at the bottom) and drives create_session / launch_agent against a
# fake `crow` that records argv.

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1166-session-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1090
source "$SETUP_SH"

SESSION_ID="11112222-3333-4444-5555-666677778888"
SESSION_NAME="crow-1166-test"
REPO="crow"
REPO_PATH="$TMP/repo"
WORKTREE_PATH="$TMP/wt"
BRANCH="feature/crow-1166"
PRIMARY=false
TICKET_URL="https://github.com/corveil/crow/issues/1166"
TICKET_TITLE="setup.sh swallows set-ticket failure"
TICKET_NUMBER="1166"
PR_URL=""
PR_NUMBER=""
SKIP_LAUNCH=false
AGENT_KIND="cursor"

CROW_LOG="$TMP/crow.log"
CROW_BIN="$TMP/fake-crow"
cat > "$CROW_BIN" <<'SH'
#!/usr/bin/env bash
# argv[1] is the subcommand. Log every invocation, then succeed or fail
# based on CROW_FAKE_* env.
printf '%s\n' "$*" >> "${CROW_LOG:?}"
case "$1" in
  set-ticket)
    if [[ "${CROW_FAKE_SET_TICKET:-ok}" == fail ]]; then
      echo "Session not found" >&2
      exit 1
    fi
    echo '{"session_id":"11112222-3333-4444-5555-666677778888"}'
    ;;
  add-worktree)
    if [[ "${CROW_FAKE_ADD_WORKTREE:-ok}" == fail ]]; then
      echo "Unknown session_id (no such session)" >&2
      exit 1
    fi
    echo '{"ok":true}'
    ;;
  add-link)
    echo '{"ok":true}'
    ;;
  list-worktrees)
    echo "${CROW_FAKE_LIST_WORKTREES:-{\"worktrees\":[]}}"
    ;;
  *)
    echo "unexpected crow subcommand: $1" >&2
    exit 1
    ;;
esac
SH
chmod +x "$CROW_BIN"
export CROW_LOG

reset_log() { : > "$CROW_LOG"; }
reset_session_globals() {
  PRIMARY=false
  SKIP_LAUNCH=false
  CROW_FAKE_SET_TICKET=ok
  CROW_FAKE_ADD_WORKTREE=ok
  CROW_FAKE_LIST_WORKTREES='{"worktrees":[]}'
  export CROW_FAKE_SET_TICKET CROW_FAKE_ADD_WORKTREE CROW_FAKE_LIST_WORKTREES
}

echo "== set-ticket failure aborts before add-link =="
reset_log
reset_session_globals
CROW_FAKE_SET_TICKET=fail
export CROW_FAKE_SET_TICKET
fail_out=$(create_session 2>&1)
fail_status=$?
check "create_session exits non-zero" "1" "$fail_status"
contains "JSON step is set_ticket" "$fail_out" '"step":"set_ticket"'
contains "JSON status is error" "$fail_out" '"status":"error"'
contains "RPC stderr is in the message" "$fail_out" "Session not found"
contains "partial session_id present" "$fail_out" "$SESSION_ID"
not_contains "add-link not invoked" "$(cat "$CROW_LOG")" "add-link"
not_contains "add-worktree not invoked" "$(cat "$CROW_LOG")" "add-worktree"
contains "set-ticket was invoked" "$(cat "$CROW_LOG")" "set-ticket"
not_contains "no leftover warning" "$fail_out" "may already be set"

echo "== set-ticket success continues to add-worktree + add-link =="
reset_log
reset_session_globals
ok_out=$(create_session 2>&1)
ok_status=$?
check "create_session succeeds" "0" "$ok_status"
contains "set-ticket called with url" "$(cat "$CROW_LOG")" "--url $TICKET_URL"
contains "set-ticket called with number" "$(cat "$CROW_LOG")" "--number $TICKET_NUMBER"
contains "add-worktree invoked" "$(cat "$CROW_LOG")" "add-worktree"
contains "first worktree is --primary" "$(cat "$CROW_LOG")" "--primary"
contains "add-link invoked" "$(cat "$CROW_LOG")" "add-link"
not_contains "no error JSON on success" "$ok_out" '"status":"error"'

echo "== no ticket URL skips set-ticket =="
reset_log
reset_session_globals
saved_url="$TICKET_URL"
TICKET_URL=""
create_session >/dev/null 2>&1
skip_status=$?
TICKET_URL="$saved_url"
check "create_session succeeds without ticket" "0" "$skip_status"
not_contains "set-ticket not invoked" "$(cat "$CROW_LOG")" "set-ticket"
contains "add-worktree still invoked" "$(cat "$CROW_LOG")" "add-worktree"

echo "== add-worktree failure aborts before add-link (CROW-1218) =="
reset_log
reset_session_globals
CROW_FAKE_ADD_WORKTREE=fail
export CROW_FAKE_ADD_WORKTREE
wt_fail_out=$(create_session 2>&1)
wt_fail_status=$?
check "create_session exits non-zero" "1" "$wt_fail_status"
contains "JSON step is add_worktree" "$wt_fail_out" '"step":"add_worktree"'
contains "RPC stderr is in the message" "$wt_fail_out" "Unknown session_id"
not_contains "add-link not invoked after add-worktree fail" "$(cat "$CROW_LOG")" "add-link"

echo "== secondary worktree does not force --primary (CROW-1218) =="
reset_log
reset_session_globals
CROW_FAKE_LIST_WORKTREES='{"worktrees":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","repo":"crow","path":"/wt","branch":"feature/existing","primary":true}]}'
export CROW_FAKE_LIST_WORKTREES
create_session >/dev/null 2>&1
sec_status=$?
check "create_session succeeds for secondary" "0" "$sec_status"
contains "add-worktree still invoked for secondary" "$(cat "$CROW_LOG")" "add-worktree"
not_contains "secondary omits --primary" "$(cat "$CROW_LOG")" "--primary"

echo "== launch_agent dies when list-worktrees is empty (CROW-1218) =="
reset_log
reset_session_globals
CROW_FAKE_LIST_WORKTREES='{"worktrees":[]}'
export CROW_FAKE_LIST_WORKTREES
launch_out=$(launch_agent 2>&1)
launch_status=$?
check "launch_agent exits non-zero" "1" "$launch_status"
contains "JSON step is launch_agent" "$launch_out" '"step":"launch_agent"'
contains "message names missing worktree" "$launch_out" "no registered worktree"
not_contains "new-terminal not invoked" "$(cat "$CROW_LOG")" "new-terminal"

echo "== launch_agent skip-launch does not require worktrees =="
reset_log
reset_session_globals
SKIP_LAUNCH=true
skip_launch_out=$(launch_agent 2>&1)
skip_launch_status=$?
check "skip-launch returns zero" "0" "$skip_launch_status"
not_contains "list-worktrees not required when skipping launch" "$(cat "$CROW_LOG")" "list-worktrees"
not_contains "no error JSON on skip-launch" "$skip_launch_out" '"status":"error"'

echo
if [[ "$fail" -eq 0 ]]; then
  echo "All $pass checks passed."
  exit 0
else
  echo "$fail failed, $pass passed."
  exit 1
fi
