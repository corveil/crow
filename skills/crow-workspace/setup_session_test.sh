#!/usr/bin/env bash
# shellcheck disable=SC2034
# Unit tests for create_session's set-ticket handling (CROW-1166).
#
# Sources setup.sh (sourcing is side-effect free thanks to the BASH_SOURCE
# guard at the bottom) and drives create_session against a fake `crow` that
# records argv. Pin: a failed set-ticket must abort before add-link, and the
# RPC error must land in the JSON die payload.

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

CROW_LOG="$TMP/crow.log"
CROW_BIN="$TMP/fake-crow"
cat > "$CROW_BIN" <<'SH'
#!/usr/bin/env bash
# argv[1] is the subcommand. Log every invocation, then succeed or fail
# based on CROW_FAKE_SET_TICKET (ok|fail).
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
    echo '{"ok":true}'
    ;;
  add-link)
    echo '{"ok":true}'
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

echo "== set-ticket failure aborts before add-link =="
reset_log
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
CROW_FAKE_SET_TICKET=ok
export CROW_FAKE_SET_TICKET
ok_out=$(create_session 2>&1)
ok_status=$?
check "create_session succeeds" "0" "$ok_status"
contains "set-ticket called with url" "$(cat "$CROW_LOG")" "--url $TICKET_URL"
contains "set-ticket called with number" "$(cat "$CROW_LOG")" "--number $TICKET_NUMBER"
contains "add-worktree invoked" "$(cat "$CROW_LOG")" "add-worktree"
contains "add-link invoked" "$(cat "$CROW_LOG")" "add-link"
not_contains "no error JSON on success" "$ok_out" '"status":"error"'

echo "== no ticket URL skips set-ticket =="
reset_log
saved_url="$TICKET_URL"
TICKET_URL=""
create_session >/dev/null 2>&1
skip_status=$?
TICKET_URL="$saved_url"
check "create_session succeeds without ticket" "0" "$skip_status"
not_contains "set-ticket not invoked" "$(cat "$CROW_LOG")" "set-ticket"
contains "add-worktree still invoked" "$(cat "$CROW_LOG")" "add-worktree"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "All $pass checks passed."
  exit 0
else
  echo "$fail failed, $pass passed."
  exit 1
fi
