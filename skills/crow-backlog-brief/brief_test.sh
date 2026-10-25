#!/usr/bin/env bash
# Unit tests for brief.sh (CROW-1367): config defaults, fetch's sub-issue
# graph batching, scope's epic grouping and assignment rules (deterministic
# claims), the PR snapshot, the burndown, compose's carry-forward, the card
# format check, build's publish guards and escaping, readback's round closing,
# and the DEFERRED / memory / corveil safety rails.
#
# Drives brief.sh as a subprocess against a fake `gh` (answers from fixture
# files, logs every call), a fake `crow` and a fake `corveil`, so nothing
# touches GitHub, claude.ai or a running daemon. When node is on PATH the
# built page's data block is parsed back and its inline script syntax-checked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIEF_SH="$SCRIPT_DIR/brief.sh"

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
lacks() { # lacks <description> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then
    pass=$((pass+1)); echo "  ok: $1"
  else
    fail=$((fail+1)); echo "  FAIL: $1"; echo "    [$2] should not contain [$3]"
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1367-brief-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixtures"
mkdir -p "$FIX"
export FIX

# Fake gh. `issue list -R o/n --state S` → $FIX/issues-o__n-S.json; `pr list
# -R o/n --state S` → $FIX/prs-o__n-S.json; `pr checks N -R o/n` →
# $FIX/checks-o__n-N.json (exit code from .rc; a .none file means "no checks
# reported"); `api graphql` answers the aliased issues from $FIX/graph-o__n.json
# (a graph-fail-o__n file makes it fail). A missing fixture is an outage.
# Every call is appended to $FIX/gh.log.
cat > "$TMP/fake-gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FIX/gh.log"
sub="$1 $2"
repo=""; state=""; q=""
for ((i = 1; i <= $#; i++)); do
  a="${!i}"; j=$((i + 1))
  case "$a" in
    -R) repo="${!j}" ;;
    --state) state="${!j}" ;;
    query=*) q="${a#query=}" ;;
  esac
done
case "$sub" in
  "issue list")
    f="$FIX/issues-${repo//\//__}-$state.json"
    [[ -f "$f" ]] || { echo "HTTP 502: fake outage" >&2; exit 1; }
    cat "$f" ;;
  "pr list")
    f="$FIX/prs-${repo//\//__}-$state.json"
    [[ -f "$f" ]] || { echo "HTTP 502: fake outage" >&2; exit 1; }
    cat "$f" ;;
  "pr checks")
    f="$FIX/checks-${repo//\//__}-$3.json"
    if [[ -f "$f.none" ]]; then echo "no checks reported on the 'topic' branch" >&2; exit 1; fi
    [[ -f "$f" ]] || { echo "HTTP 502: fake outage" >&2; exit 1; }
    cat "$f"
    exit "$(cat "$f.rc" 2>/dev/null || echo 0)" ;;
  "api graphql")
    r=$(sed -E 's/.*repository\(owner: "([^"]+)", name: "([^"]+)"\).*/\1__\2/' <<<"$q")
    [[ -f "$FIX/graph-fail-$r" ]] && { echo "GraphQL: Field 'subIssuesSummary' doesn't exist on type 'Issue'" >&2; exit 1; }
    nums=$(grep -oE 'i[0-9]+: issue' <<<"$q" | grep -oE '[0-9]+' | paste -sd, -)
    jq -c --arg nums "$nums" '($nums | split(",") | map(tonumber)) as $n
      | {data: {r: (reduce (.[] | select(.number as $x | ($n | index($x)) != null)) as $i ({}; .["i\($i.number)"] = $i))}}' "$FIX/graph-$r.json" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
SH
cat > "$TMP/fake-crow" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-sessions) [[ -f "$FIX/sessions.json" ]] || { echo "crow.sock unreachable" >&2; exit 1; }; cat "$FIX/sessions.json" ;;
  *) echo "fake crow: unexpected call: $*" >&2; exit 1 ;;
esac
SH
cat > "$TMP/fake-corveil" <<'SH'
#!/usr/bin/env bash
printf '{"capture_off":"%s","args":"%s"}\n' "${CORVEIL_NO_CAPTURE:-}" "$*"
SH
chmod +x "$TMP/fake-gh" "$TMP/fake-crow" "$TMP/fake-corveil"
export GH_BIN="$TMP/fake-gh" CROW_BIN="$TMP/fake-crow" CORVEIL_BIN="$TMP/fake-corveil"

brief() { bash "$BRIEF_SH" "$@"; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

CONFIG="$TMP/config.json"
cat > "$CONFIG" <<'JSON'
{"title": "Acme Backlog Brief", "repos": ["acme/api", "acme/web"], "operator": "jdoe",
 "release": {"name": "v2.4", "date": "2026-11-02"}, "defer_label": "P3", "cadence": {"round_hours": 24}}
JSON

# ─── config ──────────────────────────────────────────────────────────────────
echo "config"
out=$(brief config --config "$CONFIG")
check "config is ok" "ok" "$(jq -r .status <<<"$out")"
check "partial cadence keeps the other defaults" "60 24 10 60" "$(jq -r '.config.cadence | "\(.check_minutes) \(.round_hours) \(.active_minutes) \(.idle_minutes)"' <<<"$out")"
check "kickoff defaults" "10 20" "$(jq -r '.config.kickoff | "\(.wave_size) \(.min_free_pct)"' <<<"$out")"
check "ontology defaults to auto" "auto" "$(jq -r .config.ontology <<<"$out")"
expect_config_error() { # expect_config_error <description> <jq edit> <needle>
  jq "$2" "$CONFIG" > "$TMP/bad-config.json"
  local o rc
  o=$(brief config --config "$TMP/bad-config.json"); rc=$?
  check "$1: exits 1" "1" "$rc"
  contains "$1: says why" "$o" "$3"
}
expect_config_error "no repos" '.repos = []' 'repos must be a non-empty array'
expect_config_error "repo not owner/name" '.repos = ["api"]' 'owner/name'
expect_config_error "repo twice" '.repos = ["acme/api", "ACME/api"]' 'listed more than once'
expect_config_error "no operator" 'del(.operator)' "GitHub login"
expect_config_error "check too often" '.cadence.check_minutes = 1' 'check_minutes'
expect_config_error "bad daily_at" '.cadence.daily_at = "8am"' 'daily_at must be HH:MM'
expect_config_error "huge wave" '.kickoff.wave_size = 50' 'wave_size'
expect_config_error "bad release" '.release = {"date": "soon"}' 'release must be'
check "missing config is a usage error" "2" "$(rc_of brief config --config "$TMP/nope.json")"

# ─── fetch ───────────────────────────────────────────────────────────────────
echo "fetch"
# acme/api has 45 open issues (two GraphQL batches); acme/web's graph query fails.
jq -n '[range(1; 46) | {number: ., title: "Issue \(.)", body: "", labels: [], assignees: [], url: "https://github.com/acme/api/issues/\(.)", createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z"}]' > "$FIX/issues-acme__api-open.json"
jq -n '[range(1; 46) | {number: ., state: "OPEN", parent: null, subIssuesSummary: {total: 0, completed: 0}, subIssues: {nodes: []}}]' > "$FIX/graph-acme__api.json"
echo '[{"number":1,"createdAt":"2026-10-01T00:00:00Z","closedAt":null,"stateReason":null}]' > "$FIX/issues-acme__api-all.json"
echo '[{"number":5,"title":"Web","body":"","labels":[],"assignees":[],"url":"https://github.com/acme/web/issues/5"}]' > "$FIX/issues-acme__web-open.json"
echo '[]' > "$FIX/issues-acme__web-all.json"
touch "$FIX/graph-fail-acme__web"
: > "$FIX/gh.log"
out=$(brief fetch --config "$CONFIG" --out "$TMP/backlog-fetch")
check "fetch is ok" "ok" "$(jq -r .status <<<"$out")"
check "45 open issues and 45 graph nodes for acme/api" "45 45" "$(jq -r '.repos[0] | "\(.open) \(.graph)"' <<<"$out")"
check "the graph is fetched in batches of 40" "2" "$(grep '^api graphql' "$FIX/gh.log" | grep -c 'name: "api"' | tr -d ' ')"
check "graph nodes carry their repo" "acme/api" "$(jq -r '.[44].repo' "$TMP/backlog-fetch/acme__api/graph.json")"
contains "a host without sub-issues is a warning, not a failure" "$(jq -r '.warnings[0]' <<<"$out")" "acme/web: no sub-issue graph"
check "its graph is empty" "[]" "$(jq -c . "$TMP/backlog-fetch/acme__web/graph.json")"
check "meta.json names the repos" '["acme/api","acme/web"]' "$(jq -c .repos "$TMP/backlog-fetch/meta.json")"
rm "$FIX/issues-acme__web-all.json"
check "an issue-list outage fails fetch" "2" "$(rc_of brief fetch --config "$CONFIG" --out "$TMP/backlog-fetch2")"

# ─── scope ───────────────────────────────────────────────────────────────────
echo "scope"
BACKLOG="$TMP/backlog"
mkdir -p "$BACKLOG/acme__api" "$BACKLOG/acme__web"
cat > "$BACKLOG/acme__api/open.json" <<'JSON'
[
 {"number":10,"title":"Epic: Billing exports","labels":[{"name":"epic"}],"assignees":[],"body":"- [ ] #11\n- [ ] acme/web#5\n- [ ] #12\n- [ ] #40\n- [ ] #4","url":"https://github.com/acme/api/issues/10","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-10-20T00:00:00Z"},
 {"number":11,"title":"CSV export endpoint","labels":[],"assignees":[],"body":"","url":"https://github.com/acme/api/issues/11"},
 {"number":12,"title":"Export audit log","labels":[],"assignees":[{"login":"sam"}],"body":"","url":"https://github.com/acme/api/issues/12"},
 {"number":20,"title":"Epic: Search rewrite","labels":[],"assignees":[{"login":"sam"}],"body":"","url":"https://github.com/acme/api/issues/20"},
 {"number":21,"title":"Search index migration","labels":[],"assignees":[{"login":"jdoe"}],"body":"","url":"https://github.com/acme/api/issues/21","createdAt":"2026-09-03T00:00:00Z","updatedAt":"2026-10-20T00:00:00Z"},
 {"number":22,"title":"Search ranking","labels":[],"assignees":[],"body":"","url":"https://github.com/acme/api/issues/22"},
 {"number":30,"title":"Rate-limit header typo","labels":[{"name":"bug"}],"assignees":[],"body":"PR #99 and step #1 are related","url":"https://github.com/acme/api/issues/30"},
 {"number":31,"title":"Someone else's","labels":[],"assignees":[{"login":"sam"}],"body":"","url":"https://github.com/acme/api/issues/31"},
 {"number":40,"title":"Shared export schema","labels":[],"assignees":[],"body":"","url":"https://github.com/acme/api/issues/40"},
 {"number":41,"title":"Epic: nested under billing","labels":[{"name":"Epic"}],"assignees":[],"body":"#42","url":"https://github.com/acme/api/issues/41"},
 {"number":42,"title":"Grandchild","labels":[],"assignees":[],"body":"","url":"https://github.com/acme/api/issues/42"}
]
JSON
cat > "$BACKLOG/acme__api/graph.json" <<'JSON'
[
 {"repo":"acme/api","number":10,"state":"OPEN","parent":null,"subIssuesSummary":{"total":4,"completed":2},"subIssues":{"nodes":[{"number":11,"state":"OPEN","repository":{"nameWithOwner":"acme/api"}},{"number":41,"state":"OPEN","repository":{"nameWithOwner":"acme/api"}}]}},
 {"repo":"acme/api","number":20,"state":"OPEN","parent":null,"subIssuesSummary":{"total":2,"completed":0},"subIssues":{"nodes":[]}},
 {"repo":"acme/api","number":21,"state":"OPEN","parent":{"number":20,"state":"OPEN","repository":{"nameWithOwner":"ACME/API"}},"subIssuesSummary":{"total":0,"completed":0},"subIssues":{"nodes":[]}},
 {"repo":"acme/api","number":22,"state":"OPEN","parent":{"number":20,"state":"OPEN","repository":{"nameWithOwner":"acme/api"}},"subIssuesSummary":{"total":0,"completed":0},"subIssues":{"nodes":[]}}
]
JSON
cat > "$BACKLOG/acme__web/open.json" <<'JSON'
[
 {"number":5,"title":"Export button","labels":[],"assignees":[],"body":"","url":"https://github.com/acme/web/issues/5"},
 {"number":7,"title":"Dark mode contrast","labels":[],"assignees":[{"login":"JDoe"}],"body":"","url":"https://github.com/acme/web/issues/7"},
 {"number":8,"title":"[EPIC] Onboarding","labels":[],"assignees":[],"body":"Covers api#40, web#7 and https://github.com/acme/api/issues/30","url":"https://github.com/acme/web/issues/8"}
]
JSON
echo '[]' > "$BACKLOG/acme__web/graph.json"
out=$(brief scope --config "$CONFIG" --backlog "$BACKLOG")
check "scope is ok" "ok" "$(jq -r .status <<<"$out")"
check "epics are the units, largest first" "acme/api#10 acme/web#8" "$(jq -r '[.epics[].key] | join(" ")' <<<"$out")"
check "sub-issues, body refs (#N, owner/name#N) and a nested epic's children join the root epic" \
  "acme/api#11 acme/api#40 acme/api#41 acme/api#42 acme/web#5" "$(jq -r '[.epics[0].children[].key] | join(" ")' <<<"$out")"
check "an issue named by two epics goes to the first in key order" "acme/api#10" \
  "$(jq -r '[.epics[] | select(any(.children[]; .key == "acme/api#40")) | .key] | join(" ")' <<<"$out")"
check "an issue URL and a configured repo's short name both resolve" "acme/api#30 acme/web#7" "$(jq -r '[.epics[1].children[].key] | join(" ")' <<<"$out")"
check "a #N that isn't an open issue is ignored" "false" "$(jq '[.epics[].children[].key] | index("acme/api#4") != null' <<<"$out")"
check "epic progress comes from the sub-issue summary" "2/4" "$(jq -r '.epics[0].progress | "\(.closed)/\(.total)"' <<<"$out")"
check "a child assigned elsewhere is out" "child of acme/api#10, assigned to someone else" "$(jq -r '.excluded[] | select(.key == "acme/api#12") | .why' <<<"$out")"
check "an epic assigned elsewhere is out" "epic assigned to someone else" "$(jq -r '.excluded[] | select(.key == "acme/api#20") | .why' <<<"$out")"
check "and takes its unassigned children with it" "in epic acme/api#20, which is assigned to someone else" "$(jq -r '.excluded[] | select(.key == "acme/api#22") | .why' <<<"$out")"
check "but the operator's own child stays in, freestanding" "acme/api#21" "$(jq -r '[.free[].key] | join(" ")' <<<"$out")"
check "a freestanding ticket assigned elsewhere is out" "assigned to someone else" "$(jq -r '.excluded[] | select(.key == "acme/api#31") | .why' <<<"$out")"
check "the operator match ignores case (JDoe)" "false" "$(jq '[.excluded[].key] | index("acme/web#7") != null' <<<"$out")"
check "counts" '{"open":14,"in_scope":10,"epics":2,"epic_children":7,"free":1,"excluded":4}' "$(jq -c .counts <<<"$out")"
out2=$(brief scope --config "$CONFIG" --backlog "$BACKLOG")
check "scope is deterministic" "$out" "$out2"
SCOPE="$TMP/scope.json"
out=$(brief scope --config "$CONFIG" --backlog "$BACKLOG" --out "$SCOPE")
check "--out writes the file and prints counts" "10" "$(jq -r .counts.in_scope <<<"$out")"
check "the file holds the full scope" "2" "$(jq '.epics | length' "$SCOPE")"
check "scope without fetch output fails" "2" "$(rc_of brief scope --config "$CONFIG" --backlog "$TMP/empty-backlog")"

# ─── prs ─────────────────────────────────────────────────────────────────────
echo "prs"
cat > "$FIX/prs-acme__api-open.json" <<'JSON'
[
 {"number":51,"title":"Fix rate-limit header","url":"https://github.com/acme/api/pull/51","isDraft":false,"reviewDecision":"APPROVED","labels":[],"createdAt":"2026-10-20T00:00:00Z","headRefName":"fix/30","body":"Closes #30","author":{"login":"jdoe"},"mergeable":"MERGEABLE"},
 {"number":52,"title":"Billing CSV","url":"https://github.com/acme/api/pull/52","isDraft":false,"reviewDecision":"APPROVED","labels":[{"name":"crow:merge"}],"createdAt":"2026-10-21T00:00:00Z","headRefName":"feat/11","body":"Fixes: https://github.com/acme/api/issues/11","author":{"login":"jdoe"},"mergeable":"MERGEABLE"},
 {"number":53,"title":"WIP","url":"https://github.com/acme/api/pull/53","isDraft":true,"reviewDecision":"","labels":[],"createdAt":"2026-10-22T00:00:00Z","headRefName":"wip","body":"refs acme/web#5","author":{"login":"jdoe"},"mergeable":"UNKNOWN"},
 {"number":54,"title":"Failing","url":"https://github.com/acme/api/pull/54","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","labels":[],"createdAt":"2026-10-22T00:00:00Z","headRefName":"x","body":"","author":{"login":"jdoe"},"mergeable":"MERGEABLE"},
 {"number":55,"title":"No checks","url":"https://github.com/acme/api/pull/55","isDraft":false,"reviewDecision":"APPROVED","labels":[],"createdAt":"2026-10-22T00:00:00Z","headRefName":"y","body":"","author":{"login":"jdoe"},"mergeable":"MERGEABLE"}
]
JSON
echo '[]' > "$FIX/prs-acme__web-open.json"
echo '[{"name":"build","bucket":"pass"},{"name":"lint","bucket":"skipping"}]' > "$FIX/checks-acme__api-51.json"
echo '[{"name":"build","bucket":"pending"}]' > "$FIX/checks-acme__api-52.json"; echo 8 > "$FIX/checks-acme__api-52.json.rc"
echo '[{"name":"build","bucket":"pass"},{"name":"e2e","bucket":"fail"}]' > "$FIX/checks-acme__api-54.json"; echo 1 > "$FIX/checks-acme__api-54.json.rc"
touch "$FIX/checks-acme__api-55.json.none"
echo '[{"number":49,"title":"Older fix","url":"https://github.com/acme/api/pull/49","mergedAt":"2026-10-25T10:00:00Z","author":{"login":"sam"}}]' > "$FIX/prs-acme__api-merged.json"
echo '[]' > "$FIX/prs-acme__web-merged.json"
cat > "$FIX/sessions.json" <<'JSON'
{"sessions":[
 {"id":"S-1","name":"web-7-dark-mode","status":"active","ticket_url":"https://github.com/acme/web/issues/7"},
 {"id":"S-2","name":"api-30","status":"inReview","ticket_url":"https://github.com/acme/api/issues/30"},
 {"id":"S-3","name":"done","status":"completed","ticket_url":"https://github.com/acme/api/issues/21"}
]}
JSON
: > "$FIX/gh.log"
out=$(brief prs --config "$CONFIG" --scope "$SCOPE" --merged-since 2026-10-24T00:00:00Z)
check "prs is ok" "ok" "$(jq -r .status <<<"$out")"
check "check states from the latest runs" "green pending not_read failing none" "$(jq -r '[.prs[].checks] | join(" ")' <<<"$out")"
check "failing check names" '["e2e"]' "$(jq -c '.prs[] | select(.number == 54) | .failing' <<<"$out")"
check "drafts aren't read for checks" "0" "$(grep -c '^pr checks 53' "$FIX/gh.log" | tr -d ' ')"
check "ready to merge: approved, green, mergeable, no crow:merge" '["acme/api#51"]' "$(jq -c .ready_to_merge <<<"$out")"
check "links: Closes #N, Fixes: URL, refs owner/name#N" "acme/api#30 acme/api#11 acme/web#5" "$(jq -r '[.prs[].links[].key] | join(" ")' <<<"$out")"
check "in flight by PR and by live session; a completed session isn't" \
  "acme/api#11=PR approved, crow:merge acme/api#30=PR approved acme/web#5=PR draft acme/web#7=In progress (Crow)" \
  "$(jq -r '[.in_flight[] | "\(.key)=\(.state)"] | join(" ")' <<<"$out")"
check "a PR's issue also carries its live session" "S-2" "$(jq -r '.in_flight[] | select(.key == "acme/api#30") | .session' <<<"$out")"
check "merged since" "acme/api#49" "$(jq -r '[.merged_since[].key] | join(" ")' <<<"$out")"
check "sessions were read" "true" "$(jq -r .sessions_read <<<"$out")"
rm "$FIX/sessions.json"
out=$(brief prs --config "$CONFIG" --scope "$SCOPE")
check "an unreadable Crow is reported, not guessed" "false" "$(jq -r .sessions_read <<<"$out")"
check "without --merged-since nothing is listed" "0" "$(jq -r '.merged_since | length' <<<"$out")"
check "a bad --merged-since is refused" "2" "$(rc_of brief prs --config "$CONFIG" --scope "$SCOPE" --merged-since yesterday)"

# ─── stats ───────────────────────────────────────────────────────────────────
echo "stats"
cat > "$BACKLOG/acme__api/history.json" <<'JSON'
[{"number":1,"createdAt":"2026-10-01T00:00:00Z","closedAt":null},
 {"number":2,"createdAt":"2026-10-01T00:00:00Z","closedAt":"2026-10-25T12:00:00Z"},
 {"number":3,"createdAt":"2026-10-25T09:00:00.000Z","closedAt":null}]
JSON
echo '[{"number":5,"createdAt":"2026-09-01T00:00:00Z","closedAt":null}]' > "$BACKLOG/acme__web/history.json"
out=$(brief stats --config "$CONFIG" --backlog "$BACKLOG" --scope "$SCOPE" --days 3 --now 2026-10-26T08:00:00Z)
check "three UTC days ending today" '["2026-10-24","2026-10-25","2026-10-26"]' "$(jq -c .days <<<"$out")"
check "open at each day's end" '[2,2,2]' "$(jq -c '.series["acme/api"]' <<<"$out")"
check "opened / closed in the last 7 days" "1 1" "$(jq -r '"\(.opened_7d) \(.closed_7d)"' <<<"$out")"
check "scope counts ride along" "10 4" "$(jq -r '"\(.in_scope) \(.excluded)"' <<<"$out")"

# ─── cards ───────────────────────────────────────────────────────────────────
# One full card per section, in the operator's format.
CARDS="$TMP/cards.json"
cat > "$CARDS" <<'JSON'
[
 {"section":"waiting","kind":"pr","key":"PR acme/api#51","url":"https://github.com/acme/api/pull/51","repo":"acme/api",
  "title":"Merge the <rate-limit> header fix","rec":"kickoff","rec_why":"Approved and green.","effort":"Minutes","timing":"before-release",
  "summary":"PR #51 fixes the header typo. It is approved and every check passed.",
  "who_notices":{"today":"API clients get no `X-RateLimit-Remaining`.","after":"They get it.","asked_by":"Support, from a customer ticket","internal":false},
  "pros":["One line"],"cons":["None found"],"risk":{"level":"low","if_wrong":"The old name stays.","undo":"Revert.","notice":"The contract test."},
  "why_now":"The release cut is 2 Nov.","buttons":{"go":{"label":"I'll merge it","hint":"you merge"},"drop":{"label":"Close the PR"}},
  "evidence":["`gh pr checks 51`: 2 pass (latest runs)"]},
 {"section":"kickoff","kind":"epic","key":"acme/api#10","slug":"api-10","url":"https://github.com/acme/api/issues/10","title":"Epic: Billing exports",
  "rec":"kickoff","effort":"1-2 weeks","timing":"any-time","summary":"Five open children add CSV export.",
  "who_notices":{"today":"Finance exports by hand.","after":"One click.","asked_by":"Finance","internal":true},
  "pros":["Saves a day a month"],"cons":["Touches billing"],"risk":{"level":"medium","if_wrong":"Wrong totals.","undo":"Flag off.","notice":"Monthly reconcile."},
  "why_now":"Nothing blocks it.","decisions":[{"question":"Include refunds?","suggested":"Yes, as negative rows."}],"children":["acme/api#11"],"progress":{"closed":2,"total":4}},
 {"section":"watch","key":"acme/web#7","title":"Dark mode contrast","rec":"defer","effort":"Hours","timing":"after 2026-11-02",
  "summary":"Two buttons miss 4.5:1 in dark mode.","who_notices":{"today":"Dark-mode users.","after":"Nobody.","asked_by":"Design review","internal":true},
  "pros":["Accessibility"],"cons":["Not urgent"],"risk":{"level":"low","if_wrong":"Colors look off.","undo":"Revert.","notice":"Screenshot test."},"why_now":"It can wait for the release."},
 {"section":"close","key":"acme/web#9","title":"Old IE banner","rec":"close","rec_why":"Already removed.","effort":"Minutes","timing":"any-time",
  "summary":"The banner was removed in #61.","who_notices":{"today":"Nobody.","after":"Nobody.","asked_by":"A past audit","internal":true},
  "pros":["Clears the list"],"cons":["None"],"risk":{"level":"low","if_wrong":"Reopen it.","undo":"Reopen.","notice":"n/a"},
  "why_now":"Done already.","evidence":["`git grep ie-banner origin/main`: no hits"]}
]
JSON
ROUND="$TMP/round.json"
# shellcheck disable=SC2016  # the backticks are card markup, not command substitution
echo '{"round_id":"r20261026","round":"2026-10-26","lede":"Four cards. Lead with the merge.","method":["Read each against `origin/main`."]}' > "$ROUND"

# ─── compose ─────────────────────────────────────────────────────────────────
echo "compose"
R1="$TMP/r1/brief.json"
out=$(brief compose --config "$CONFIG" --round "$ROUND" --cards "$CARDS" --now 2026-10-26T08:00:00Z --out "$R1")
check "compose is ok" "ok" "$(jq -r .status <<<"$out")"
check "ids are <round_id>-<slug>; slug defaults to the key" \
  "r20261026-pr-acme-api-51 r20261026-api-10 r20261026-acme-web-7 r20261026-acme-web-9" "$(jq -r '[.cards[].id] | join(" ")' "$R1")"
check "slug is not kept on the card" "false" "$(jq '.cards[1] | has("slug")' "$R1")"
check "title and release come from config" "Acme Backlog Brief v2.4" "$(jq -r '"\(.title) \(.release.name)"' "$R1")"
check "context defaults to the repos" "acme/api · acme/web" "$(jq -r .context "$R1")"
check "generated_at defaults to now" "2026-10-26T08:00:00Z" "$(jq -r .generated_at "$R1")"
check "a first round has no carry" "false" "$(jq 'has("carry")' "$R1")"
check "sections in the report" '{"waiting":1,"kickoff":1,"watch":1,"close":1}' "$(jq -c .sections <<<"$out")"
jq '.[0].id = "x"' "$CARDS" > "$TMP/bad-cards.json"
o=$(brief compose --config "$CONFIG" --round "$ROUND" --cards "$TMP/bad-cards.json" --out "$TMP/never.json"); rc=$?
check "a card with its own id is refused" "1" "$rc"
contains "and says compose derives ids" "$o" "compose derives it"
check "nothing written on error" "no" "$([[ -e "$TMP/never.json" ]] && echo yes || echo no)"
jq '.[1].summary = ""' "$CARDS" > "$TMP/bad-cards.json"
o=$(brief compose --config "$CONFIG" --round "$ROUND" --cards "$TMP/bad-cards.json" --out "$TMP/never.json"); rc=$?
check "compose validates the card format" "1" "$rc"
contains "naming the card" "$o" "card 2 (r20261026-api-10): summary is required"
check "--prev-brief without --decisions is refused" "2" "$(rc_of brief compose --config "$CONFIG" --round "$ROUND" --cards "$CARDS" --prev-brief "$R1" --out "$TMP/never.json")"
check "--decisions without --prev-brief is refused" "2" "$(rc_of brief compose --config "$CONFIG" --round "$ROUND" --cards "$CARDS" --decisions "$TMP" --out "$TMP/never.json")"
echo '{}' > "$TMP/obj-cards.json"
check "cards must be an array" "2" "$(rc_of brief compose --config "$CONFIG" --round "$ROUND" --cards "$TMP/obj-cards.json" --out "$TMP/never.json")"

# Round 1 decisions: the merge is go, the epic has only a note, the close
# went against its recommendation, the watch card is untouched.
D1="$TMP/raw1/decisions"
mkdir -p "$D1"
echo '{"status":"go","note":"","by":"u_operator0000000000000","at":"2026-10-26T09:00:00.123Z","ticket":null,"result":null}' > "$D1/r20261026-pr-acme-api-51.json"
echo '{"status":null,"note":"Refunds yes, but ask finance first","by":"u_operator0000000000000","at":"2026-10-26T09:05:00Z"}' > "$D1/r20261026-api-10.json"
echo '{"status":"later","note":"Keep it open for now","by":"u_operator0000000000000","at":"2026-10-26T09:06:00Z"}' > "$D1/r20261026-acme-web-9.json"
echo '{"status":"go"}' > "$D1/r20261025-older-round.json"

# Round 2: one new card, and the watch card re-studied under its old slug.
jq '[.[2] | .slug = "acme-web-7" | .summary = "Still two buttons; one more found."]
    + [.[3] | .key = "acme/api#77" | .title = "Remove the v1 shim"]' "$CARDS" > "$TMP/cards2.json"
echo '{"round_id":"r20261027","round":"2026-10-27","history_entry":{"go":"1: PR #51 merged"}}' > "$TMP/round2.json"
cat > "$TMP/stats.json" <<'JSON'
{"status":"ok","days":["2026-10-26","2026-10-27"],"order":["acme/api","acme/web"],"series":{"acme/api":[9,8],"acme/web":[3,3]},
 "open_total":11,"in_scope":7,"excluded":4,"epics":2,"epic_children":3,"free":2,"opened_7d":2,"closed_7d":5}
JSON
R2="$TMP/r2/brief.json"
out=$(brief compose --config "$CONFIG" --round "$TMP/round2.json" --cards "$TMP/cards2.json" --stats "$TMP/stats.json" \
      --prev-brief "$R1" --decisions "$D1" --now 2026-10-27T08:00:00Z --out "$R2")
check "round 2 composes" "ok" "$(jq -r .status <<<"$out")"
check "decided and noted cards are not carried" "r20261027-acme-web-7 r20261027-acme-api-77" "$(jq -r '[.cards[].id] | join(" ")' "$R2")"
check "a re-studied undecided card keeps where it came from" "r20261026" "$(jq -r '.cards[0].carried_from' "$R2")"
check "and takes the new content" "Still two buttons; one more found." "$(jq -r '.cards[0].summary' "$R2")"
check "report: refreshed, decided, noted" '["acme-web-7"] ["r20261026-pr-acme-api-51","r20261026-acme-web-9"] ["r20261026-api-10"]' \
  "$(jq -c '.refreshed, .decided_prev, .noted_prev' <<<"$out" | paste -sd' ' -)"
check "carry basis: the previous round's docs as id@at" \
  '["r20261026-acme-web-9@2026-10-26T09:06:00Z","r20261026-api-10@2026-10-26T09:05:00Z","r20261026-pr-acme-api-51@2026-10-26T09:00:00.123Z"]' \
  "$(jq -c .carry.basis "$R2")"
check "an auto history row, merged with history_entry" '{"round":"2026-10-26","go":"1: PR #51 merged","later":"1","drop":"0","carried":"0","open_after":"7"}' \
  "$(jq -c '.history[0]' "$R2")"
check "kpis from stats" "7|2 / 5|net −3|down|2" "$(jq -r '[.stats.kpis[0].value, .stats.kpis[1].value, .stats.kpis[1].delta, .stats.kpis[1].dir, .stats.kpis[2].value] | join("|")' "$R2")"
check "burndown from stats" '[8,3]' "$(jq -c '[.burndown.series["acme/api"][1], .burndown.series["acme/web"][1]]' "$R2")"
check "stats_basis kept for the next delta" "7" "$(jq -r .stats_basis.in_scope "$R2")"

# Round 3 from round 2 with nothing decided: the untouched new card is
# carried, the carried card keeps its first round, and a retired slug drops.
D2="$TMP/raw2/decisions"; mkdir -p "$D2"
echo '[]' > "$TMP/cards3.json"
echo '{"round_id":"r20261028","round":"2026-10-28","retire":[{"slug":"acme-api-77","why":"closed by hand"}]}' > "$TMP/round3.json"
jq '.in_scope = 5' "$TMP/stats.json" > "$TMP/stats3.json"
out=$(brief compose --config "$CONFIG" --round "$TMP/round3.json" --cards "$TMP/cards3.json" --stats "$TMP/stats3.json" \
      --prev-brief "$R2" --decisions "$D2" --now 2026-10-28T08:00:00Z --out "$TMP/r3/brief.json")
check "carried cards keep their first round" "r20261028-acme-web-7=r20261026" "$(jq -r '[.cards[] | "\(.id)=\(.carried_from)"] | join(" ")' "$TMP/r3/brief.json")"
check "retire drops an undecided card" '["acme-api-77"]' "$(jq -c .retired <<<"$out")"
check "the delta compares with the last brief's in-scope count" "−2 since the last brief|down" "$(jq -r '.stats.kpis[0] | "\(.delta)|\(.dir)"' "$TMP/r3/brief.json")"
check "a carried-cards kpi" "1" "$(jq -r '.stats.kpis[] | select(."label" == "carried from an earlier brief") | .value' "$TMP/r3/brief.json")"
check "history accumulates" "2" "$(jq '.history | length' "$TMP/r3/brief.json")"
o=$(brief compose --config "$CONFIG" --round "$TMP/round2.json" --cards "$TMP/cards3.json" --prev-brief "$R2" --decisions "$D2" --out "$TMP/never.json"); rc=$?
check "a new round needs a new round_id" "1" "$rc"
contains "and says so" "$o" "a new round needs a new id"

# ─── check (the card format) ─────────────────────────────────────────────────
echo "check"
out=$(brief check --brief "$R1")
check "the composed brief checks clean" "ok" "$(jq -r .status <<<"$out")"
check "no warnings" "[]" "$(jq -c .warnings <<<"$out")"
expect_card_error() { # expect_card_error <description> <jq edit on .cards[1]> <needle>
  jq ".cards[1] |= ($2)" "$R1" > "$TMP/bad-brief.json"
  local o rc
  o=$(brief check --brief "$TMP/bad-brief.json"); rc=$?
  check "$1: exits 1" "1" "$rc"
  contains "$1: says why" "$o" "$3"
}
expect_card_error "no summary" 'del(.summary)' 'summary is required: what it is, in 1-3 plain sentences'
expect_card_error "no who_notices" 'del(.who_notices)' 'who_notices is required'
expect_card_error "who_notices without after" 'del(.who_notices.after)' 'who_notices.after is required'
expect_card_error "who_notices without asked_by" '.who_notices.asked_by = " "' 'who_notices.asked_by is required'
expect_card_error "internal must be a boolean" '.who_notices.internal = "yes"' 'who_notices.internal must be true or false'
expect_card_error "no pros" '.pros = []' 'pros needs at least one pro'
expect_card_error "no cons" 'del(.cons)' 'cons needs at least one con'
expect_card_error "no risk" 'del(.risk)' 'risk is required'
expect_card_error "bad risk level" '.risk.level = "spicy"' 'risk.level must be low, medium or high'
expect_card_error "risk without undo" 'del(.risk.undo)' 'risk.undo is required'
expect_card_error "no why_now" 'del(.why_now)' 'why_now is required'
expect_card_error "a decision without a suggested answer" '.decisions = [{"question": "Refunds?"}]' 'every decision carries a suggested answer'
expect_card_error "no effort" 'del(.effort)' 'effort is required'
expect_card_error "bad timing" '.timing = "soon"' 'timing must be before-release, any-time'
expect_card_error "bad rec" '.rec = "maybe"' 'rec must be kickoff, defer or close'
expect_card_error "bad section" '.section = "misc"' 'section must be one of waiting, kickoff, watch, close'
expect_card_error "an id from another round" '.id = "r20261025-api-10"' 'every id carries its round id'
expect_card_error "the reserved general id" '.id = "r20261026-general"' 'reserved for the general notes box'
expect_card_error "a close with no evidence" '.rec = "close" | .section = "close" | del(.evidence)' 'a close needs verified evidence'
expect_card_error "the old user_effect name" '.user_effect = "x"' 'user_effect is the old name'
expect_card_error "the old risk_profile name" '.risk_profile = {}' 'risk_profile is the old name'
expect_card_error "a long button label" '.buttons = {"go": {"label": "Kick this off right now please, all of it"}}' 'longer than 40 characters'
expect_card_error "a bad url" '.url = "javascript:alert(1)"' 'url must be an http(s) URL'
jq '.cards[1].id = .cards[0].id' "$R1" > "$TMP/bad-brief.json"
contains "duplicate ids are refused" "$(brief check --brief "$TMP/bad-brief.json")" 'is used more than once'
jq 'del(.generated_at)' "$R1" > "$TMP/bad-brief.json"
contains "generated_at is required" "$(brief check --brief "$TMP/bad-brief.json")" 'generated_at must be an ISO 8601 UTC time'
jq '.burndown = {days: ["a", "b"], order: ["acme/api"], series: {"acme/api": [1]}}' "$R1" > "$TMP/bad-brief.json"
contains "a burndown series must match its days" "$(brief check --brief "$TMP/bad-brief.json")" 'one number per day'
jq '.cards[1].summary = "One. Two. Three. Four." | del(.release)' "$R1" > "$TMP/warn-brief.json"
out=$(brief check --brief "$TMP/warn-brief.json")
contains "a long summary is a warning" "$(jq -c .warnings <<<"$out")" 'summary runs past 3 sentences'
contains "before-release without a release is a warning" "$(jq -c .warnings <<<"$out")" 'names no release'

# ─── build ───────────────────────────────────────────────────────────────────
echo "build"
PAGE="$TMP/out/page.html"
o=$(brief build --brief "$R1" --out "$PAGE"); rc=$?
check "build needs a decisions read or --first-publish" "2" "$rc"
contains "and says so" "$o" "build needs --decisions"
out=$(brief build --brief "$R1" --out "$PAGE" --first-publish)
check "a first publish builds" "ok" "$(jq -r .status <<<"$out")"
html=$(cat "$PAGE")
lacks "placeholders are replaced" "$html" "__BRIEF_"
contains "the title lands in <title>" "$html" "<title>Acme Backlog Brief</title>"
lacks "card text can't close the data script" "$html" "Merge the <rate-limit>"
# The needle is built at run time and matched with awk index(): bash 3.2's
# [[ == ]] and some greps read its backslash as an escape.
bs=$(printf '\134')
check "< is escaped in the data block" "1" \
  "$(NEEDLE="Merge the ${bs}u003crate-limit>" awk 'index($0, ENVIRON["NEEDLE"]) {c++} END {print c + 0}' "$PAGE")"
contains "the page reads the db through claude.use" "$html" 'c.use("db")'
contains "decisions collection" "$html" 'db.collection("decisions")'
contains "rounds collection for the done button" "$html" 'db.collection("rounds")'
contains "existing docs are merged" "$html" 'ref.update(patch)'
if command -v node >/dev/null 2>&1; then
  rt=$(node -e '
    const fs = require("fs");
    const h = fs.readFileSync(process.argv[1], "utf8");
    const m = h.match(/<script type="application\/json" id="brief-data">\n([\s\S]*?)\n<\/script>/);
    const d = JSON.parse(m[1]);
    new Function(h.split("<script>\n")[1].split("</script>")[0]);
    console.log(d.cards[0].title.startsWith("Merge the <rate") + " " + d.cards.length);
  ' "$PAGE" 2>&1)
  check "data round-trips and the page script parses (node)" "true 4" "$rt"
else
  echo "  skip: node not on PATH (data round-trip + script parse)"
fi
jq '.title = "A & B <x>"' "$R1" > "$TMP/title-brief.json"
brief build --brief "$TMP/title-brief.json" --out "$TMP/out/title.html" --first-publish >/dev/null
contains "the title is HTML-escaped" "$(cat "$TMP/out/title.html")" "<title>A &amp; B &lt;x&gt;</title>"
jq 'del(.cards[0].summary)' "$R1" > "$TMP/bad-brief.json"
check "an invalid brief writes no page" "1" "$(rc_of brief build --brief "$TMP/bad-brief.json" --out "$TMP/never.html" --first-publish)"
check "no page for it" "no" "$([[ -e "$TMP/never.html" ]] && echo yes || echo no)"
grep -v '^__BRIEF_DATA__$' "$SCRIPT_DIR/page.html" > "$TMP/broken-template.html"
contains "a damaged template is refused" "$(brief build --brief "$R1" --out "$TMP/never.html" --first-publish --template "$TMP/broken-template.html")" 'template must have exactly one line'
o=$(brief build --brief "$R2" --out "$TMP/never.html" --first-publish); rc=$?
check "a brief that carries cards is never a first publish" "2" "$rc"
contains "and says to pass --decisions" "$o" "pass --decisions"

# The republish guards, with the round-1 decisions as the fresh read.
out=$(brief build --brief "$R1" --out "$PAGE" --decisions "$D1" --now 2026-10-26T09:10:00Z); rc=$?
check "a write in the last 10 minutes holds the publish" "3" "$rc"
check "hold says the operator is answering" "operator_active 360" "$(jq -r '"\(.reason) \(.retry_after_seconds)"' <<<"$out")"
check "--active-minutes 0 disables the hold" "0" "$(rc_of brief build --brief "$R1" --out "$PAGE" --decisions "$D1" --active-minutes 0 --now 2026-10-26T09:10:00Z)"
out=$(brief build --brief "$R1" --out "$PAGE" --decisions "$D1" --now 2026-10-26T10:00:00Z)
check "an idle operator: the republish goes ahead" "ok false" "$(jq -r '"\(.status) \(.guard.active)"' <<<"$out")"
out=$(brief build --brief "$R2" --out "$PAGE" --decisions "$D1" --now 2026-10-27T08:30:00Z)
check "a new round over unchanged decisions builds" "ok false" "$(jq -r '"\(.status) \(.guard.stale)"' <<<"$out")"
cp -R "$D1" "$TMP/raw1-changed"
echo '{"status":"drop","note":"","by":"u_operator0000000000000","at":"2026-10-27T08:10:00Z"}' > "$TMP/raw1-changed/r20261026-acme-web-7.json"
out=$(brief build --brief "$R2" --out "$PAGE" --decisions "$TMP/raw1-changed" --now 2026-10-27T09:30:00Z); rc=$?
check "decisions that changed since compose stop the publish" "4" "$rc"
check "naming the card" "decisions_changed [\"r20261026-acme-web-7\"]" "$(jq -c '"\(.reason) \(.changed | tojson)"' <<<"$out" | jq -r .)"
mkdir -p "$TMP/old-read"
cp "$D1"/*.json "$TMP/old-read/"
touch -t 202001010000 "$TMP/old-read"/*.json "$TMP/old-read"
out=$(brief build --brief "$R1" --out "$PAGE" --decisions "$TMP/old-read" --now 2026-10-26T10:00:00Z); rc=$?
check "an old read stops the publish" "4" "$rc"
check "as old_read" "old_read" "$(jq -r .reason <<<"$out")"
mkdir -p "$TMP/empty-read"
check "an empty, fresh read (no decisions yet) is fine" "0" "$(rc_of brief build --brief "$R1" --out "$PAGE" --decisions "$TMP/empty-read")"

# ─── readback ────────────────────────────────────────────────────────────────
echo "readback"
echo '{"status":"maybe","note":5,"ticket":"not a url"}' > "$D1/r20261026-gone.json"
echo '{"note":"Also look at the docs","by":"u_operator0000000000000","at":"2026-10-26T09:07:00Z"}' > "$D1/r20261026-general.json"
echo '{"status":"go","note":"","by":"u_operator0000000000000","at":"2026-10-26T09:00:00Z","result":"Merged by the operator."}' > "$TMP/r51-done.json"
R_DIR="$TMP/raw1/rounds"; mkdir -p "$R_DIR"
out=$(brief readback --brief "$R1" --decisions "$D1" --rounds "$R_DIR" --now 2026-10-26T10:00:00Z)
check "readback is ok" "ok" "$(jq -r .status <<<"$out")"
check "counts" '{"cards":4,"go":1,"later":1,"drop":0,"noted":1,"undecided":1,"notes":2,"against_rec":1,"done_by_claude":0}' "$(jq -c .counts <<<"$out")"
check "a note with no button is noted, not undecided" '["r20261026-api-10"]' "$(jq -c .noted <<<"$out")"
check "untouched cards carry forward" '["r20261026-acme-web-7"]' "$(jq -c .carry_forward <<<"$out")"
check "to act: decided or noted, no result yet" '["r20261026-pr-acme-api-51","r20261026-api-10","r20261026-acme-web-9"]' "$(jq -c .to_act <<<"$out")"
check "a decision against its recommendation is flagged" '[{"id":"r20261026-acme-web-9","rec":"close","status":"later"}]' "$(jq -c .against_rec <<<"$out")"
check "the general note" "Also look at the docs" "$(jq -r .general_note.note <<<"$out")"
check "a doc for a card not on the page is an orphan" "r20261026-gone" "$(jq -r '[.orphans[].id] | join(" ")' <<<"$out")"
check "earlier rounds' docs are counted, not joined" "1" "$(jq -r .other_rounds <<<"$out")"
check "bad fields are reported" "status note ticket" "$(jq -r '[.invalid[].field] | join(" ")' <<<"$out")"
check "people" '["u_operator0000000000000"]' "$(jq -c .people <<<"$out")"
check "not done and young: not ready to act" "false null" "$(jq -r '.round | "\(.ready_to_act) \(.closed)"' <<<"$out")"
contains "says what it waits for" "$(jq -r .round.waiting <<<"$out")" "has not pressed done"
echo '{"done":true,"at":"2026-10-26T09:30:00Z","by":"u_operator0000000000000"}' > "$R_DIR/r20261026.json"
out=$(brief readback --brief "$R1" --decisions "$D1" --rounds "$R_DIR" --now 2026-10-26T10:00:00Z)
check "done closes the round" "true done u_operator0000000000000" "$(jq -r '.round | "\(.ready_to_act) \(.closed) \(.done_by)"' <<<"$out")"
rm "$R_DIR/r20261026.json"
out=$(brief readback --brief "$R1" --decisions "$D1" --rounds "$R_DIR" --now 2026-10-27T09:00:00Z)
check "a day old and idle: the round goes stale" "true stale" "$(jq -r '.round | "\(.ready_to_act) \(.closed)"' <<<"$out")"
echo '{"status":"go","note":"","by":"u_operator0000000000000","at":"2026-10-27T08:45:00Z"}' > "$D1/r20261026-acme-web-7.json"
out=$(brief readback --brief "$R1" --decisions "$D1" --now 2026-10-27T09:00:00Z)
check "but not while someone wrote in the last hour" "false 15" "$(jq -r '.round | "\(.ready_to_act) \(.idle_minutes)"' <<<"$out")"
check "--round-hours and --idle-minutes tune it" "true stale" "$(brief readback --brief "$R1" --decisions "$D1" --now 2026-10-27T09:00:00Z --idle-minutes 10 | jq -r '.round | "\(.ready_to_act) \(.closed)"')"
cp "$TMP/r51-done.json" "$D1/r20261026-pr-acme-api-51.json"
out=$(brief readback --brief "$R1" --decisions "$D1" --now 2026-10-26T10:00:00Z)
check "a card with a result is done, not to act" "false" "$(jq '.to_act | index("r20261026-pr-acme-api-51") != null' <<<"$out")"
check "its result is joined" "Merged by the operator." "$(jq -r '.cards[0].result' <<<"$out")"
{
  echo '{"id":"r20261026-api-10","data":{"status":"drop","note":"","by":"u_operator0000000000000","at":"2026-10-26T09:00:00Z"},"version":7}'
  echo '{"id":"r20261026-acme-web-9","data":{"status":"go","note":"x"},"version":3}'
} > "$TMP/inline.jsonl"
out=$(brief readback --brief "$R1" --decisions "$TMP/inline.jsonl" --now 2026-10-26T10:00:00Z)
check "the inline list output carries versions" "7 3" "$(jq -r '[.cards[] | select(.version != null) | .version] | join(" ")' <<<"$out")"
check "readback needs --decisions" "2" "$(rc_of brief readback --brief "$R1")"

# ─── deferred ────────────────────────────────────────────────────────────────
echo "deferred"
mkrepo() { # mkrepo <dir> <origin url> <file> <content>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" remote add origin "$2"
  printf '%s\n' "$4" > "$1/$3"
  git -C "$1" add -A
  git -C "$1" -c user.email=t@example.com -c user.name=t commit -qm init
  git -C "$1" update-ref refs/remotes/origin/main HEAD
  git -C "$1" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
mkrepo "$TMP/git-api" "https://github.com/acme/api.git" "main.go" $'// DEFERRED(#12): drop the shim\n// DEFERRED(#123): unrelated'
mkrepo "$TMP/git-web" "git@github.com:acme/web.git" "app.ts" $'// DEFERRED(acme/api#12): web side\n// DEFERRED(#12): web\'s own #12'
echo '// DEFERRED(#12): only in the working tree' >> "$TMP/git-api/main.go"
out=$(brief deferred --issue acme/api#12 --repo-path "$TMP/git-api" --repo-path "$TMP/git-web")
check "markers on the default branch, in its own repo and cross-repo" "2 false" "$(jq -r '"\(.count) \(.clear)"' <<<"$out")"
check "where they are" "main.go:1 app.ts:1" "$(jq -r '[.markers[] | "\(.file):\(.line)"] | join(" ")' <<<"$out")"
check "#12 doesn't match #123, nor another repo's bare #12, nor the working tree" "2" "$(jq -r '.markers | length' <<<"$out")"
check "the ref came from origin/HEAD" "origin/main" "$(jq -r '.searched[0].ref' <<<"$out")"
out=$(brief deferred --issue acme/api#5 --repo-path "$TMP/git-api")
check "no markers: clear" "0 true" "$(jq -r '"\(.count) \(.clear)"' <<<"$out")"
out=$(brief deferred --issue acme/api#5 --repo-path "$TMP/git-api" --ref origin/nope)
check "a missing ref is an error, never clear" "false 1" "$(jq -r '"\(.clear) \(.errors | length)"' <<<"$out")"
out=$(brief deferred --issue acme/api#5 --repo-path "$TMP/not-a-repo")
check "a path that isn't a checkout is an error, never clear" "false" "$(jq -r .clear <<<"$out")"
check "--issue must be owner/name#N" "2" "$(rc_of brief deferred --issue 12 --repo-path "$TMP/git-api")"

# ─── memory ──────────────────────────────────────────────────────────────────
echo "memory"
check "enough free memory" "true 45" "$(BRIEF_FREE_PCT=45 brief memory --min-free 20 | jq -r '"\(.ok) \(.free_pct)"')"
check "too little" "false" "$(BRIEF_FREE_PCT=12 brief memory --min-free 20 | jq -r .ok)"
check "unknown is not ok" "false unknown" "$(BRIEF_FREE_PCT=lots brief memory | jq -r '"\(.ok) \(.source)"')"
check "the host's own reading parses" "true" "$(brief memory --min-free 0 | jq -r '.ok or (.source == "unknown")')"

# ─── corveil ─────────────────────────────────────────────────────────────────
echo "corveil"
out=$(brief corveil search "billing exports")
check "reads run with CORVEIL_NO_CAPTURE=1" "1" "$(jq -r .capture_off <<<"$out")"
check "and pass their arguments through" "search billing exports" "$(jq -r .args <<<"$out")"
o=$(brief corveil ontology merge a b); rc=$?
check "a write verb is refused" "2" "$rc"
contains "naming the read verbs" "$o" "read verbs only"
o=$(CORVEIL_BIN="$TMP/no-such-corveil" bash "$BRIEF_SH" corveil whoami); rc=$?
check "no CLI: skip the ontology (exit 3)" "3 skipped" "$rc $(jq -r .status <<<"$o")"

echo
echo "brief_test: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
