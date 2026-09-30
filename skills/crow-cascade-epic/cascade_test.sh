#!/usr/bin/env bash
# Unit tests for cascade.sh (CROW-1312): wave layering and plan validation,
# ticket-state classification, cascade-contract drift, the resume point
# (current_wave / to_launch / start_wave), and watch's exit codes.
#
# Drives cascade.sh as a subprocess against a fake `gh` (GraphQL answers from
# fixture files) and a fake `crow` (list-sessions / list-links), so nothing
# touches GitHub or a running daemon.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASCADE_SH="$SCRIPT_DIR/cascade.sh"

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1312-cascade-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixtures"
mkdir -p "$FIX"
export FIX

# Fake gh: `-F number=N` → $FIX/issue-N.json, `-F url=…/pull/N` → $FIX/pr-N.json.
# A missing fixture is an outage (exit 1), which is how "unknown" is exercised.
cat > "$TMP/fake-gh" <<'SH'
#!/usr/bin/env bash
f=""
for a in "$@"; do
  case "$a" in
    number=*) f="$FIX/issue-${a#number=}.json" ;;
    url=*)    f="$FIX/pr-${a##*/}.json" ;;
  esac
done
[[ -n "$f" && -f "$f" ]] || { echo "HTTP 502: fake outage" >&2; exit 1; }
cat "$f"
SH
# Fake crow: list-sessions → $FIX/sessions.json, list-links → $FIX/links-<id>.json.
cat > "$TMP/fake-crow" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-sessions) cat "$FIX/sessions.json" ;;
  list-links)    f="$FIX/links-$3.json"; [[ -f "$f" ]] && cat "$f" || echo '{"links":[]}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP/fake-gh" "$TMP/fake-crow"
export GH_BIN="$TMP/fake-gh" CROW_BIN="$TMP/fake-crow"

cascade() { bash "$CASCADE_SH" "$@"; }

U="https://github.com/o/r/issues"

pr_node() { # pr_node <number> <state> <draft> <labels,csv> <requested,csv> <approved,csv> [author]
  jq -cn --argjson n "$1" --arg st "$2" --argjson d "$3" --arg l "$4" --arg rq "$5" --arg ap "$6" \
    --arg au "${7:-coder}" '{
      number: $n, url: "https://github.com/o/r/pull/\($n)", state: $st, isDraft: $d,
      author: {login: $au},
      labels: {nodes: [$l | split(",")[] | select(. != "") | {name: .}]},
      reviewRequests: {nodes: [$rq | split(",")[] | select(. != "") | {requestedReviewer: {login: .}}]},
      latestReviews: {nodes: [$ap | split(",")[] | select(. != "") | {state: "APPROVED", author: {login: .}}]}
    }'
}
issue() { # issue <number> <OPEN|CLOSED> <stateReason|null> [pr-node-json…]
  local n="$1" st="$2" reason="$3"; shift 3
  local prs='[]' p
  for p in "$@"; do prs=$(jq -c --argjson p "$p" '. + [$p]' <<< "$prs"); done
  jq -cn --arg st "$st" --argjson r "$reason" --argjson prs "$prs" \
    '{data: {repository: {issue: {state: $st, stateReason: $r, closedByPullRequestsReferences: {nodes: $prs}}}}}' \
    > "$FIX/issue-$n.json"
}
pr_resource() { # pr_resource <number> <pr-node-json>
  jq -cn --argjson p "$2" '{data: {resource: $p}}' > "$FIX/pr-$1.json"
}

# ─── plan ────────────────────────────────────────────────────────────────────
echo "plan: wave layering"

PLAN="$TMP/plan.json"
cat > "$PLAN" <<JSON
{"epic": {"url": "$U/100", "title": "Epic"}, "gate": "human", "reviewer": "dgershman",
 "tickets": [
  {"id": "o/r#1",  "label": "T1", "url": "$U/1",  "title": "one",   "deps": []},
  {"id": "o/r#2",  "label": "T2", "url": "$U/2",  "title": "two",   "deps": []},
  {"id": "o/r#9",  "label": "X",  "url": "$U/9",  "title": "ext",   "deps": [], "external": true},
  {"id": "o/r#3",  "label": "T3", "url": "$U/3",  "title": "three", "deps": ["o/r#1", "o/r#2"]},
  {"id": "o/r#4",  "label": "T4", "url": "$U/4",  "title": "four",  "deps": ["o/r#1"]},
  {"id": "o/r#5",  "label": "T5", "url": "$U/5",  "title": "five",  "deps": ["o/r#9"]},
  {"id": "o/r#6",  "label": "T6", "url": "$U/6",  "title": "six",   "deps": ["o/r#2"]},
  {"id": "o/r#10", "label": "T10","url": "$U/10", "title": "ten",   "deps": ["o/r#1"]},
  {"id": "o/r#7",  "label": "T7", "url": "$U/7",  "title": "seven", "deps": ["o/r#3"]},
  {"id": "o/r#8",  "label": "T8", "url": "$U/8",  "title": "eight", "deps": ["o/r#3", "o/r#4"]}
 ]}
JSON
out=$(cascade plan --plan-file "$PLAN")
check "plan succeeds" "ok" "$(jq -r .status <<< "$out")"
check "three waves" "3" "$(jq -r .wave_count <<< "$out")"
check "wave 1 = roots incl. external" "T1 T2 X" "$(jq -r '[.waves[0].tickets[].label] | join(" ")' <<< "$out")"
check "wave 2 = deps on wave 1" "T3 T4 T5 T6 T10" "$(jq -r '[.waves[1].tickets[].label] | join(" ")' <<< "$out")"
check "wave 3 = deps on wave 2" "T7 T8" "$(jq -r '[.waves[2].tickets[].label] | join(" ")' <<< "$out")"
check "waves written back to the plan file" "3" "$(jq -r '.tickets[] | select(.id == "o/r#8") | .wave' "$PLAN")"
check "start_wave defaults to 1" "1" "$(jq -r .start_wave "$PLAN")"
again=$(cascade plan --plan-file "$PLAN")
check "re-planning is idempotent" "$(jq -c .waves <<< "$out")" "$(jq -c .waves <<< "$again")"

echo "plan: validation"
cat > "$TMP/cycle.json" <<JSON
{"gate": "auto", "reviewer": "x", "tickets": [
  {"id": "a", "url": "u", "deps": ["b"]}, {"id": "b", "url": "u", "deps": ["a"]}, {"id": "c", "url": "u", "deps": []}]}
JSON
out=$(cascade plan --plan-file "$TMP/cycle.json"); rc=$?
check "cycle exits 2" "2" "$rc"
contains "cycle names its members" "$out" "dependency cycle among: a, b"
check "a failed plan leaves the file unwritten" "null" "$(jq -c .waves "$TMP/cycle.json")"

cat > "$TMP/bad.json" <<JSON
{"gate": "yolo", "reviewer": "", "tickets": [
  {"id": "c", "url": "u", "deps": ["zz", "c"]}, {"id": "c", "url": "u", "deps": []}]}
JSON
out=$(cascade plan --plan-file "$TMP/bad.json"); rc=$?
check "invalid plan exits 2" "2" "$rc"
contains "rejects an unknown gate" "$out" 'gate must be \"human\" or \"auto\" (got yolo)'
contains "requires a reviewer" "$out" "reviewer is required"
contains "rejects a self-dependency" "$out" "c depends on itself"
contains "rejects a dependency outside the plan" "$out" "c depends on zz, which is not in the plan"
contains "rejects duplicate ids" "$out" "duplicate ticket id: c"

# ─── status ──────────────────────────────────────────────────────────────────
echo "status: classification, drift, resume point"

issue 1 CLOSED '"COMPLETED"' "$(pr_node 11 MERGED false crow:merge "" dgershman)"
issue 2 CLOSED '"COMPLETED"'                                  # closed by hand, no PR
issue 9 CLOSED '"COMPLETED"' "$(pr_node 19 MERGED false "" "" dgershman)"
issue 3 OPEN null "$(pr_node 13 OPEN false crow:merge "" "")" # human gate: crow:merge before approval, no reviewer
issue 4 OPEN null "$(pr_node 14 OPEN true "" dgershman "")"  # draft
issue 5 OPEN null                                             # PR only via the session's registered link
pr_resource 50 "$(pr_node 50 OPEN false "" dgershman "")"
# issue 6: no fixture → gh fails → unknown
issue 10 OPEN null                                            # nothing yet → launchable
issue 7 CLOSED '"NOT_PLANNED"'
issue 8 OPEN null "$(pr_node 18 CLOSED false "" dgershman "")"

cat > "$FIX/sessions.json" <<JSON
{"sessions": [
  {"id": "S5", "name": "r-5-five", "kind": "work", "status": "active", "is_explore": false, "ticket_url": "$U/5"},
  {"id": "E4", "name": "r-4-explore-four", "kind": "work", "status": "active", "is_explore": true, "ticket_url": "$U/4"},
  {"id": "M", "name": "Manager", "kind": "manager", "status": "active", "is_explore": false, "ticket_url": null}
]}
JSON
echo '{"links": [{"type": "ticket", "url": "'"$U"'/5"}, {"type": "pr", "url": "https://github.com/o/r/pull/50"}]}' > "$FIX/links-S5.json"

st=$(cascade status --plan-file "$PLAN")
state() { jq -r --arg id "$1" '.tickets[] | select(.id == $id) | .state' <<< "$st"; }
field() { jq -r --arg id "$1" ".tickets[] | select(.id == \$id) | $2" <<< "$st"; }

check "merged PR → merged" "merged" "$(state o/r#1)"
check "closed COMPLETED without a PR → closed" "closed" "$(state o/r#2)"
check "closed counts as satisfied" "true" "$(field o/r#2 .satisfied)"
check "external ticket is classified too" "merged" "$(state o/r#9)"
check "open PR → in_review" "in_review" "$(state o/r#3)"
check "open draft PR → draft" "draft" "$(state o/r#4)"
check "session-registered PR is picked up" "in_review" "$(state o/r#5)"
check "session PR number" "50" "$(field o/r#5 '.prs[0].number')"
check "gh outage → unknown" "unknown" "$(state o/r#6)"
contains "unknown carries the error" "$(field o/r#6 .error)" "fake outage"
check "nothing yet → no_pr" "no_pr" "$(state o/r#10)"
check "closed NOT_PLANNED → closed_not_planned" "closed_not_planned" "$(state o/r#7)"
check "closed_not_planned is blocked" "true" "$(field o/r#7 .blocked)"
check "only closed-unmerged PRs → pr_closed" "pr_closed" "$(state o/r#8)"

check "work session matched by ticket_url" "S5" "$(field o/r#5 .session.id)"
check "explore session reported separately" "E4" "$(field o/r#4 .explore_session.id)"
check "explore session is not the work session" "null" "$(field o/r#4 .session)"

contains "human gate: crow:merge before approval is drift" "$(field o/r#3 '.drift | join("|")')" "carries crow:merge before any human approval"
contains "missing reviewer request is drift" "$(field o/r#3 '.drift | join("|")')" "no review request for @dgershman"
check "compliant PR has no drift" "0" "$(field o/r#5 '.drift | length')"

check "wave 1 complete (merged + closed + external)" "true" "$(jq -r '.waves[0].complete' <<< "$st")"
check "current wave is 2" "2" "$(jq -r .current_wave <<< "$st")"
check "to_launch = wave-2 tickets with nothing in flight" '["o/r#10"]' "$(jq -c .to_launch <<< "$st")"
check "cascade not complete" "false" "$(jq -r .complete <<< "$st")"

st=$(cascade status --plan-file "$PLAN" --wave 2)
check "--wave narrows the tickets" "5" "$(jq -r '.tickets | length' <<< "$st")"
check "--wave leaves the resume point null" "null" "$(jq -c .current_wave <<< "$st")"

echo "status: auto gate, self-approval, multiple PRs"
jq '.gate = "auto"' "$PLAN" > "$TMP/auto.json"
issue 3 OPEN null "$(pr_node 13 OPEN false "" dgershman coder)" "$(pr_node 23 OPEN false crow:merge dgershman "")"
st=$(cascade status --plan-file "$TMP/auto.json")
d3=$(field o/r#3 '.drift | join("|")')
contains "auto gate: missing crow:merge is drift" "$d3" "PR #13 is missing the crow:merge label (auto gate)"
contains "self-approval is drift" "$d3" "PR #13 is approved by its own author"
contains "two open PRs is drift" "$d3" "2 open PRs (#13, #23)"
contains "auto gate: session PR without crow:merge is drift" "$(field o/r#5 '.drift | join("|")')" "missing the crow:merge label"

echo "status: start_wave"
jq '.start_wave = 3' "$PLAN" > "$TMP/start3.json"
st=$(cascade status --plan-file "$TMP/start3.json")
check "waves before start_wave are skipped" "true true" "$(jq -r '[.waves[0].skipped, .waves[1].complete] | map(tostring) | join(" ")' <<< "$st")"
check "resume jumps to start_wave" "3" "$(jq -r .current_wave <<< "$st")"
check "pr_closed ticket is relaunchable" '["o/r#8"]' "$(jq -c .to_launch <<< "$st")"

# ─── watch ───────────────────────────────────────────────────────────────────
echo "watch: exit codes"

out=$(cascade watch --plan-file "$PLAN" --wave 1 --interval 0 --timeout 60); rc=$?
check "complete wave exits 0" "0" "$rc"
contains "names the next wave to release" "$out" "WAVE 1 COMPLETE — release wave 2: T3 o/r#3"
contains "streams ticket states" "$out" "wave 1 · T1 o/r#1 → merged (PR #11 merged)"

out=$(cascade watch --plan-file "$PLAN" --wave 3 --interval 0 --timeout 0); rc=$?
check "open wave at timeout exits 10" "10" "$rc"
contains "timeout says to re-arm" "$out" "re-arm the watcher"

issue 8 CLOSED '"NOT_PLANNED"'
out=$(cascade watch --plan-file "$PLAN" --wave 3 --interval 0 --timeout 60); rc=$?
check "every open ticket blocked exits 3" "3" "$rc"
contains "blocked names the tickets" "$out" "o/r#7, o/r#8"

issue 7 CLOSED '"COMPLETED"' "$(pr_node 17 MERGED false "" "" dgershman)"
issue 8 CLOSED '"COMPLETED"' "$(pr_node 28 MERGED false "" "" dgershman)"
out=$(cascade watch --plan-file "$PLAN" --wave 3 --interval 0 --timeout 60); rc=$?
check "last wave complete exits 0" "0" "$rc"
contains "last wave says the cascade is done" "$out" "that was the last wave"

out=$(cascade watch --plan-file "$PLAN" --interval 0); rc=$?
check "watch without --wave exits 2" "2" "$rc"
out=$(cascade bogus --plan-file "$PLAN"); rc=$?
check "unknown subcommand exits 2" "2" "$rc"

echo
echo "cascade_test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
