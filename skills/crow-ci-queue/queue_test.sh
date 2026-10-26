#!/usr/bin/env bash
# Unit tests for queue.sh (CROW-1365): queue collection and the CI Gate
# convention check (and a just-pushed head, CROW-1374), readiness, the run
# classification (including the false failure from the unlabeled run), holder
# choice and ordering, normalize, advance's update-before-label and its races,
# and watch's events.
#
# Drives queue.sh as a subprocess against a fake `gh` (answers from fixture
# files, records writes in gh.log) and a fake `crow` (list-sessions /
# list-links), so nothing touches GitHub or a running daemon.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUEUE_SH="$SCRIPT_DIR/queue.sh"

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1365-queue-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixtures"
mkdir -p "$FIX" "$TMP/queues"
export FIX

# Fake gh. Reads: graphql `-F number=N` → $FIX/pr-N.json; `pr list` →
# $FIX/labeled.json; `api repos/…/compare/BASE...SHA` → $FIX/compare-SHA.json.
# A missing fixture is an outage (exit 1). Each graphql read of PR N bumps
# $FIX/reads-N; once it reaches $FIX/pr-N.then-at, $FIX/pr-N.then.json
# replaces pr-N.json (state that appears later). Writes (`pr edit`,
# `pr update-branch`) are appended to $FIX/gh.log. update-branch moves
# $FIX/pr-N.after-update.json over pr-N.json (the new head), prints
# $FIX/update-N.out, and exits with $FIX/update-N.rc.
cat > "$TMP/fake-gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "api graphql")
    n=""
    for a in "$@"; do case "$a" in number=*) n="${a#number=}" ;; esac; done
    reads=$(( $(cat "$FIX/reads-$n" 2>/dev/null || echo 0) + 1 )); echo "$reads" > "$FIX/reads-$n"
    if [[ -f "$FIX/pr-$n.then.json" ]] && (( reads >= $(cat "$FIX/pr-$n.then-at") )); then
      mv "$FIX/pr-$n.then.json" "$FIX/pr-$n.json"
    fi
    f="$FIX/pr-$n.json"
    [[ -f "$f" ]] || { echo "HTTP 502: fake outage" >&2; exit 1; }
    cat "$f" ;;
  "pr list")
    [[ -f "$FIX/labeled.json" ]] || { echo "HTTP 502: fake outage" >&2; exit 1; }
    cat "$FIX/labeled.json" ;;
  "pr edit")
    echo "$*" >> "$FIX/gh.log"
    [[ -f "$FIX/edit-$3.rc" ]] && exit "$(cat "$FIX/edit-$3.rc")"
    exit 0 ;;
  "pr update-branch")
    echo "$*" >> "$FIX/gh.log"
    [[ -f "$FIX/pr-$3.after-update.json" ]] && mv "$FIX/pr-$3.after-update.json" "$FIX/pr-$3.json"
    if [[ -f "$FIX/update-$3.out" ]]; then cat "$FIX/update-$3.out"; else echo "✓ PR branch updated"; fi
    exit "$(cat "$FIX/update-$3.rc" 2>/dev/null || echo 0)" ;;
  api\ repos/*/compare/*)
    sha="${2##*...}"
    [[ -f "$FIX/compare-$sha.json" ]] || { echo "HTTP 404" >&2; exit 1; }
    cat "$FIX/compare-$sha.json" ;;
  *) echo "fake gh: unexpected $*" >&2; exit 1 ;;
esac
SH
# Fake crow: list-sessions → $FIX/sessions.json (FAKE_CROW_FAIL makes it
# fail), list-links → $FIX/links-<id>.json.
cat > "$TMP/fake-crow" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-sessions)
    [[ -n "${FAKE_CROW_FAIL:-}" ]] && { echo "crow: socket timeout" >&2; exit 1; }
    cat "$FIX/sessions.json" ;;
  list-links) f="$FIX/links-$3.json"; if [[ -f "$f" ]]; then cat "$f"; else echo '{"links":[]}'; fi ;;
  *) exit 1 ;;
esac
SH
# Fake jq, only for the version gate.
mkdir -p "$TMP/jqbin"
REAL_JQ=$(command -v jq)
export REAL_JQ
cat > "$TMP/jqbin/jq" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" && -n "${FAKE_JQ_VERSION:-}" ]]; then echo "$FAKE_JQ_VERSION"; exit 0; fi
exec "$REAL_JQ" "$@"
SH
chmod +x "$TMP/fake-gh" "$TMP/fake-crow" "$TMP/jqbin/jq"
export GH_BIN="$TMP/fake-gh" CROW_BIN="$TMP/fake-crow" CROW_CI_QUEUE_DIR="$TMP/queues"
# Fixed clock, and no waiting inside advance.
NOW=$(jq -n '"2026-10-23T11:00:00Z" | fromdateiso8601')
export QUEUE_NOW="$NOW" QUEUE_UPDATE_TIMEOUT=0 QUEUE_UPDATE_POLL=0

q() { bash "$QUEUE_SH" "$@"; }

# A PR fixture in GraphQL shape, from a short spec. Defaults: OPEN, approved,
# mergeable, labels ["crow:merge"], a CI Gate check on the head, head commit
# "h<number>" on branch "b<number>" (the branch its fixture session works on).
# timeline: [{t: "on"|"off", at, by}] for ci:full. suites:
# [{created, updated, status, conclusion, wf, runs: {name: conclusion|null}}],
# where a null conclusion is a job still running.
mkpr() { # mkpr <number> <spec-json> [file]
  jq -c --argjson n "$1" '
    def runs: (.runs // {}) | to_entries
      | map({name: .key, status: (if .value == null then "IN_PROGRESS" else "COMPLETED" end), conclusion: .value});
    . as $s | ($s.head // "h\($n)") as $head
    | {data: {repository: {pullRequest: {
        number: $n, url: "https://github.com/o/r/pull/\($n)", title: ($s.title // "PR \($n)"),
        state: ($s.state // "OPEN"), isDraft: ($s.draft // false), createdAt: ($s.created // "2026-10-23T08:00:00Z"),
        mergedAt: ($s.merged // null),
        author: {login: "coder"}, baseRefName: "main", headRefOid: $head, headRefName: ($s.branch // "b\($n)"),
        reviewDecision: (if $s | has("review") then $s.review else "APPROVED" end),
        mergeable: ($s.mergeable // "MERGEABLE"), mergeStateStatus: ($s.mss // "BLOCKED"),
        labels: {nodes: [($s.labels // ["crow:merge"])[] | {name: .}]},
        timelineItems: {nodes: [($s.timeline // [])[]
          | {__typename: (if .t == "on" then "LabeledEvent" else "UnlabeledEvent" end),
             createdAt: .at, actor: {login: (.by // "dgershman")}, lbl: {name: (.name // "ci:full")}}]},
        commits: {nodes: [{commit: {
          statusCheckRollup: {contexts: {nodes: [($s.rollup // ["CI Gate"])[] | {name: .}]}},
          checkSuites: {nodes: [($s.suites // [])[]
            | {status: (.status // "COMPLETED"), conclusion: (.conclusion // null), createdAt: .created,
               updatedAt: (.updated // .created),
               workflowRun: {url: "https://github.com/o/r/actions/runs/\($n)", workflow: {name: (.wf // "Test")}},
               checkRuns: {nodes: runs}}]}}}]}
      }}}}' <<< "$2" > "${3:-$FIX/pr-$1.json}"
}
compare() { echo "{\"behind_by\": $2}" > "$FIX/compare-$1.json"; } # compare <sha> <behind>
labeled() { # labeled <number[!]…> — the open PRs `gh pr list --label ci:full` returns; N! has no crow:merge
  local n out='[]'
  # shellcheck disable=SC2016
  for n in "$@"; do
    out=$(jq -c --argjson n "${n%!}" --argjson merge "$([[ "$n" == *! ]] && echo false || echo true)" '. + [{
      number: $n, title: "PR \($n)", url: "https://github.com/o/r/pull/\($n)", headRefName: "b\($n)",
      author: {login: (if $n >= 90 then "app/dependabot" else "coder" end)},
      labels: ([{name: "ci:full"}] + (if $merge then [{name: "crow:merge"}] else [] end))}]' <<< "$out")
  done
  echo "$out" > "$FIX/labeled.json"
}
glog() { cat "$FIX/gh.log" 2>/dev/null; }

# Suite shapes. FAIL_CLOSED is the unlabeled run: CI Gate red, every job
# skipped. RUNNING has no CI Gate check yet (it appears when the jobs finish).
FAIL_CLOSED='{"CI Gate": "FAILURE", "Lint": "SKIPPED", "Test (PostgreSQL)": "SKIPPED"}'
GREEN='{"Lint": "SUCCESS", "Test (PostgreSQL)": "SUCCESS", "CI Gate": "SUCCESS"}'
RED='{"Lint": "FAILURE", "Test (PostgreSQL)": "SUCCESS", "CI Gate": "FAILURE"}'
RUNNING='{"Lint": "SUCCESS", "Test (PostgreSQL)": null}'
suite() { # suite <created> <runs-json> [status] [conclusion] [updated] [workflow]
  jq -cn --arg c "$1" --argjson r "$2" --arg st "${3:-COMPLETED}" --arg co "${4:-}" --arg u "${5:-$1}" --arg wf "${6:-Test}" \
    '{created: $c, updated: $u, status: $st, conclusion: (if $co == "" then null else $co end), wf: $wf, runs: $r}'
}
on() { jq -cn --arg at "$1" --arg by "${2:-dgershman}" '{t: "on", at: $at, by: $by}'; }
off() { jq -cn --arg at "$1" --arg by "${2:-dgershman}" '{t: "off", at: $at, by: $by}'; }

# ─── fixtures: sessions ──────────────────────────────────────────────────────
cat > "$FIX/sessions.json" <<'JSON'
{"sessions": [
  {"id": "S11", "name": "r-11", "branch": "b11", "kind": "work", "status": "active",
   "links": [{"type": "ticket", "url": "https://github.com/o/r/issues/1"}, {"type": "pr", "url": "https://github.com/o/r/pull/11"}]},
  {"id": "S12", "name": "r-12", "branch": "b12", "kind": "work", "status": "inReview", "links": [{"type": "pr", "url": "https://github.com/O/R/pull/12"}]},
  {"id": "S14", "name": "r-14", "branch": "b14", "kind": "work", "status": "active", "links": [{"type": "pr", "url": "https://github.com/o/r/pull/14"}]},
  {"id": "S15", "name": "r-15", "branch": "b15", "kind": "work", "status": "active"},
  {"id": "S16", "name": "r-16", "branch": "b16", "kind": "work", "status": "active", "links": [{"type": "pr", "url": "https://github.com/o/r/pull/16"}]},
  {"id": "S17", "name": "r-17", "branch": "b17", "kind": "work", "status": "active", "links": [{"type": "pr", "url": "https://github.com/o/r/pull/17"}]},
  {"id": "S13", "name": "r-13", "branch": "b13", "kind": "work", "status": "completed", "links": [{"type": "pr", "url": "https://github.com/o/r/pull/13"}]},
  {"id": "R31", "name": "review-31", "kind": "review", "status": "active", "links": [{"type": "pr", "url": "https://github.com/o/r/pull/31"}]},
  {"id": "P21", "name": "plain-21", "kind": "work", "status": "active", "links": [{"type": "pr", "url": "https://github.com/o/plain/pull/21"}]},
  {"id": "G1", "name": "gitlab-1", "kind": "work", "status": "active", "links": [{"type": "pr", "url": "https://gitlab.example.com/g/p/-/merge_requests/1"}]},
  {"id": "M", "name": "Manager", "kind": "manager", "status": "active", "links": []}
]}
JSON
# S15 predates inline links: its PR comes from list-links.
echo '{"links": [{"type": "pr", "url": "https://github.com/o/r/pull/15"}]}' > "$FIX/links-S15.json"

# ─── fixtures: PRs ───────────────────────────────────────────────────────────
# 11 — the holder: labeled 10:05, its suite running. The fail-closed run on the
#      same head was created 10:04:58, before the label.
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"created\": \"2026-10-23T09:30:00Z\",
  \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE), $(suite 2026-10-23T10:05:02Z "$RUNNING" IN_PROGRESS)]}"
# 12 — ready, oldest; 16 — ready, newer
mkpr 12 '{"created": "2026-10-23T08:00:00Z"}'
mkpr 16 '{"created": "2026-10-23T09:00:00Z"}'
# 14 — approved but no crow:merge; 15 — draft; 17 — labeled but conflicting
mkpr 14 '{"labels": []}'
mkpr 15 '{"draft": true, "review": "REVIEW_REQUIRED"}'
mkpr 17 "{\"mergeable\": \"CONFLICTING\", \"created\": \"2026-10-23T10:00:00Z\", \"labels\": [\"crow:merge\", \"CI:Full\"], \"timeline\": [$(on 2026-10-23T10:30:00Z)],
  \"suites\": [$(suite 2026-10-23T10:30:03Z "$RUNNING" IN_PROGRESS)]}"
# 13 (completed session) and 31 (review session) must never be read.
# 21 — a repo with no CI Gate convention
mkpr 21 '{"rollup": ["build"]}'
labeled 11 17 99
compare h12 2
compare h12b 0
compare h16 0

# ─── status ──────────────────────────────────────────────────────────────────
echo "status: collection and the CI Gate convention"
st=$(q status)
check "status succeeds" "ok" "$(jq -r .status <<< "$st")"
check "one queue, for the convention repo" "o/r" "$(jq -r '[.repos[].repo] | join(" ")' <<< "$st")"
r() { jq -r ".repos[0] | $1" <<< "$st"; }
pr() { jq -r --argjson n "$1" ".repos[0] | [.holder // empty, .queue[]] | map(select(.number == \$n)) | .[0] | $2" <<< "$st"; }
check "active, inReview, and list-links PRs are queued; completed and review sessions are not" \
  "11 12 15 16 17" "$(r '[.holder.number, .queue[].number] | sort | map(tostring) | join(" ")')"
check "an approved PR without crow:merge merges by hand: outside the queue" "14" "$(r '[.manual_merge[].number] | map(tostring) | join(" ")')"
contains "a repo without the convention is ignored" "$(jq -c .ignored <<< "$st")" "o/plain does not follow the CI Gate convention"
contains "a non-GitHub link is ignored" "$(jq -c .ignored <<< "$st")" "not a github.com pull request URL"
check "a mixed-case URL lands in the lowercase repo" "S12" "$(pr 12 .session.id)"

echo "status: readiness"
check "approved + crow:merge + mergeable is ready" "true" "$(pr 12 .ready)"
check "no crow:merge" "no crow:merge" "$(r '.manual_merge[0].reasons | join(",")')"
check "draft and unapproved" "draft,not approved yet" "$(pr 15 '.reasons | join(",")')"
check "a conflict" "merge conflict" "$(pr 17 '.reasons | join(",")')"

echo "status: run classification"
check "labeled, suite in flight → running" "running" "$(pr 11 .run.state)"
check "the run is the one created after the label" "2026-10-23T10:05:02Z" "$(pr 11 .run.created_at)"
check "an unlabeled PR has no run" "null" "$(pr 12 .run)"
check "ci:full matched case-insensitively" "CI:Full" "$(pr 17 .full_label_name)"

echo "status: holder, order, strip, foreign"
check "the running ready PR holds" "11" "$(r .holder.number)"
contains "with a reason" "$(r .holder.reason)" "in progress"
check "queue is oldest first" "12 15 16 17" "$(r '[.queue[].number] | map(tostring) | join(" ")')"
check "next is the first ready PR" "12" "$(r .next)"
check "the not-ready labeled PR is to be stripped" "[17]" "$(r '.to_strip | tostring')"
check "a labeled PR no session owns is foreign" "99" "$(r '[.foreign_labeled[].number] | map(tostring) | join(" ")')"

echo "status: only a session's own PR is queued"
jq '(.sessions[] | select(.id == "S16") | .branch) = "b-other"' "$FIX/sessions.json" > "$TMP/s.json" && cp "$FIX/sessions.json" "$TMP/sessions.bak" && mv "$TMP/s.json" "$FIX/sessions.json"
labeled 11 16 99
st=$(q status --repo o/r)
check "a linked PR whose head branch isn't the session's is not queued" "12 15 17" "$(r '[.queue[].number] | map(tostring) | join(" ")')"
contains "it is ignored, with why" "$(jq -c .ignored <<< "$st")" "its head branch b16 is not the session branch b-other"
check "and reads as foreign, so normalize never strips it" "16 99" "$(r '[.foreign_labeled[].number] | map(tostring) | join(" ")')"
mv "$TMP/sessions.bak" "$FIX/sessions.json"
labeled 11 17 99

echo "status: queue file — add, order, hold"
mkpr 40 '{"created": "2026-10-23T10:59:00Z"}'
echo '{"repo": "O/R", "add": [40], "order": [16, 40], "hold": [12]}' > "$TMP/queues/o-r.json"
st=$(q status --repo o/r)
check "order goes first, then oldest first" "16 40 12 15 17" "$(r '[.queue[].number] | map(tostring) | join(" ")')"
check "an added PR is queued" "true" "$(pr 40 .added)"
check "a held PR is not ready" "held by the operator" "$(pr 12 '.reasons | join(",")')"
check "next skips the held PR" "16" "$(r .next)"
check "--repo narrows status" "0" "$(jq -r '.ignored | length' <<< "$st")"
# An added PR without crow:merge is not queued: it would go green and sit,
# blocking the queue. It is reported as added, outside the queue.
mkpr 40 "{\"labels\": [\"ci:full\"], \"created\": \"2026-10-23T10:59:00Z\", \"timeline\": [$(on 2026-10-23T10:59:30Z)]}"
st=$(q status --repo o/r)
check "an added PR without crow:merge is not queued" "16 12 15 17" "$(r '[.queue[].number] | map(tostring) | join(" ")')"
check "it is in manual_merge, marked added" "40 true" "$(r '.manual_merge[] | select(.number == 40) | "\(.number) \(.added)"')"
check "and is never stripped" "[]" "$(r '.to_strip | map(select(. == 40)) | tostring')"
out=$(q advance --repo o/r --pr 40); rc=$?
check "advance --pr on it exits 2" "2" "$rc"
contains "and says it needs crow:merge" "$out" "#40 has no crow:merge"
echo '{"repo": "o/r", "hold": ["twelve"]}' > "$TMP/queues/o-r.json"
out=$(q status); rc=$?
check "a malformed queue file exits 2" "2" "$rc"
contains "and says which file" "$out" "queue file $TMP/queues/o-r.json"
rm -f "$TMP/queues/o-r.json" "$FIX/pr-40.json"

echo "status: the false failure from the unlabeled run"
# Labeled at 10:05:00; the only suite is the fail-closed one from 10:04:58.
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE)]}"
st=$(q status --repo o/r)
check "a fail-closed run from before the label is not a failure" "pending" "$(pr 11 .run.state)"
# The labeled suite failed for real: a job other than CI Gate is red.
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE), $(suite 2026-10-23T10:05:02Z "$RED" COMPLETED FAILURE 2026-10-23T10:20:00Z)]}"
st=$(q status --repo o/r)
check "a red job in the labeled suite → failure" "failure" "$(pr 11 .run.state)"
check "names the failed job, not CI Gate" "Lint" "$(pr 11 '.run.failed_checks | join(",")')"
check "a failed holder keeps the queue" "11" "$(r .holder.number)"
# A fail-closed run created after the label: the suite never ran on this head.
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:05:01Z "$FAIL_CLOSED" COMPLETED CANCELLED)]}"
st=$(q status --repo o/r)
check "lone CI Gate red after the label → skipped" "skipped" "$(pr 11 .run.state)"
# Only suites of the workflow that owns CI Gate count.
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE), $(suite 2026-10-23T10:06:00Z '{"CodeQL": "FAILURE"}' COMPLETED FAILURE 2026-10-23T10:06:00Z CodeQL)]}"
st=$(q status --repo o/r)
check "another workflow's red is not the suite's" "pending" "$(pr 11 .run.state)"
# Re-labeled: the run counts from the latest ci:full, not the first.
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T09:00:00Z), $(off 2026-10-23T09:30:00Z), $(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T09:00:02Z "$RED" COMPLETED FAILURE), $(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE)]}"
st=$(q status --repo o/r)
check "a failure from an earlier labeling is not counted" "pending" "$(pr 11 .run.state)"

echo "status: holder choice"
green11() { mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"mss\": \"${1:-CLEAN}\", \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE), $(suite 2026-10-23T10:05:02Z "$GREEN" COMPLETED SUCCESS 2026-10-23T10:20:00Z)]}"; }
running16() { # running16 [labeled-at] [suite-created]
  mkpr 16 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"created\": \"2026-10-23T09:00:00Z\", \"timeline\": [$(on "${1:-2026-10-23T10:01:00Z}")],
  \"suites\": [$(suite 2026-10-23T09:59:00Z "$FAIL_CLOSED" COMPLETED FAILURE), $(suite "${2:-2026-10-23T10:01:02Z}" "$RUNNING" IN_PROGRESS)]}"; }
green11; running16
st=$(q status --repo o/r)
check "a green PR that is merging beats a running one" "11 [16,17]" "$(r '"\(.holder.number) \(.to_strip | tostring)"')"
green11 BEHIND
st=$(q status --repo o/r)
check "a green PR that is behind does not; the earlier-labeled running one holds" "16" "$(r .holder.number)"
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:00:00Z)],
  \"suites\": [$(suite 2026-10-23T10:00:02Z "$RED" COMPLETED FAILURE 2026-10-23T10:20:00Z)]}"
st=$(q status --repo o/r)
check "running beats failed" "16" "$(r .holder.number)"
contains "and the failed one is stripped with its state" "$(r '.queue[] | select(.number == 11) | .run.state')" "failure"
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:00:00Z)],
  \"suites\": [$(suite 2026-10-23T10:00:02Z "$RUNNING" IN_PROGRESS)]}"
st=$(q status --repo o/r)
check "two running: the first labeled holds" "11" "$(r .holder.number)"
running16 2026-10-23T09:59:30Z 2026-10-23T09:59:32Z
st=$(q status --repo o/r)
check "…whichever that is" "16" "$(r .holder.number)"
mkpr 16 '{"created": "2026-10-23T09:00:00Z"}'
mkpr 11 '{"created": "2026-10-23T09:30:00Z"}'
st=$(q status --repo o/r)
check "nothing labeled: no holder" "null" "$(r .holder)"
check "…and next is the oldest ready" "12" "$(r .next)"

echo "status: fail closed"
out=$(FAKE_CROW_FAIL=1 bash "$QUEUE_SH" status); rc=$?
check "crow unreachable exits 2" "2" "$rc"
contains "and names list-sessions" "$out" "crow list-sessions failed"
out=$(PATH="$TMP/jqbin:$PATH" FAKE_JQ_VERSION="jq-1.5" bash "$QUEUE_SH" status); rc=$?
check "jq older than 1.6 exits 2" "2" "$rc"
contains "names the jq requirement" "$out" "jq 1.6 or newer is required"
out=$(q status --repo nope); rc=$?
check "a malformed --repo exits 2" "2" "$rc"

# ─── normalize ───────────────────────────────────────────────────────────────
echo "normalize"
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"created\": \"2026-10-23T09:30:00Z\", \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE), $(suite 2026-10-23T10:05:02Z "$RUNNING" IN_PROGRESS)]}"
running16 2026-10-23T10:10:00Z 2026-10-23T10:10:02Z
: > "$FIX/gh.log"
out=$(q normalize --repo o/r --dry-run)
check "dry run reports the strips" "16 17" "$(jq -r '[.stripped[].number] | map(tostring) | join(" ")' <<< "$out")"
check "dry run edits nothing" "" "$(glog)"
out=$(q normalize --repo o/r)
check "keeps the holder" "11" "$(jq -r .holder.number <<< "$out")"
check "strips the rest, with each PR's own label name" \
  "pr edit 16 -R o/r --remove-label ci:full|pr edit 17 -R o/r --remove-label CI:Full" "$(glog | paste -sd'|' -)"
lacks "never touches a foreign PR" "$(glog)" "pr edit 99"
check "reports the foreign PR" "99" "$(jq -r '[.foreign_labeled[].number] | map(tostring) | join(" ")' <<< "$out")"
check "a stripped PR carries its run state" "running" "$(jq -r '.stripped[] | select(.number == 16) | .run_state' <<< "$out")"
: > "$FIX/gh.log"
out=$(q normalize --repo o/r --keep 16)
check "--keep picks the holder" "16" "$(jq -r .holder.number <<< "$out")"
check "--keep strips the computed holder" "11 17" "$(jq -r '[.stripped[].number] | map(tostring) | join(" ")' <<< "$out")"
out=$(q normalize --repo o/r --keep 99); rc=$?
check "--keep on a PR outside the queue exits 2" "2" "$rc"
echo 1 > "$FIX/edit-17.rc"
out=$(q normalize --repo o/r)
check "a failed strip is reported" "17" "$(jq -r '[.strip_failed[].number] | map(tostring) | join(" ")' <<< "$out")"
rm -f "$FIX/edit-17.rc"
mv "$FIX/pr-14.json" "$TMP/pr-14.bak"
out=$(q normalize --repo o/r); rc=$?
check "an unreadable queued PR exits 2" "2" "$rc"
contains "and names it" "$out" "could not read #14"
mv "$TMP/pr-14.bak" "$FIX/pr-14.json"
out=$(q normalize --repo o/plain); rc=$?
check "a repo without the convention exits 2" "2" "$rc"
contains "and says why" "$out" "does not follow the CI Gate convention"
out=$(q normalize --repo o/empty)
check "a repo with nothing queued is a no-op" "null" "$(jq -c .holder <<< "$out")"

echo "normalize: an approved PR without crow:merge keeps its suite"
# The reviewer's repro: approved, ci:full added on approval, suite running,
# no crow:merge — the queue can never label it again, so it must not strip it.
mkpr 14 "{\"labels\": [\"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z reviewer)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE), $(suite 2026-10-23T10:05:02Z "$RUNNING" IN_PROGRESS)]}"
: > "$FIX/gh.log"
out=$(q normalize --repo o/r)
lacks "it is not stripped" "$(glog)" "pr edit 14"
check "it is reported under manual_merge with its suite" "14 running true" \
  "$(jq -r '.manual_merge[] | select(.number == 14) | "\(.number) \(.run_state) \(.full_label)"' <<< "$out")"
check "and is never the holder" "11" "$(jq -r .holder.number <<< "$out")"
out=$(q advance --repo o/r --pr 14); rc=$?
check "advance --pr on it exits 2" "2" "$rc"
contains "and says why" "$out" "#14 has no crow:merge, so it merges by hand"
mkpr 14 '{"labels": []}'


# ─── advance ─────────────────────────────────────────────────────────────────
echo "advance: guards"
out=$(q advance --repo o/r)
check "a holder makes advance a no-op" "held 11" "$(jq -r '"\(.result) \(.holder.number)"' <<< "$out")"
check "…that still lists what normalize would strip" "[16,17]" "$(jq -c .to_strip <<< "$out")"
mkpr 11 '{"created": "2026-10-23T09:30:00Z"}'
mkpr 16 '{"created": "2026-10-23T09:00:00Z"}'
out=$(q advance --repo o/r); rc=$?
check "no holder, but #17 still carries ci:full → won't advance" "2" "$rc"
contains "says to normalize" "$out" "#17 also carry ci:full in o/r — run normalize first"
mkpr 17 '{"mergeable": "CONFLICTING", "created": "2026-10-23T10:00:00Z"}'
mkpr 11 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"created\": \"2026-10-23T09:30:00Z\", \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:05:02Z "$RUNNING" IN_PROGRESS)]}"
out=$(q advance --repo o/r --pr 11); rc=$?
check "advancing the holder itself needs --relabel" "2" "$rc"

echo "advance: update from main, then label"
mkpr 11 '{"state": "MERGED", "labels": ["crow:merge", "ci:full"]}'
# #12 is 2 behind main; update-branch moves it to h12b, which already has its
# own (unlabeled) run.
mkpr 12 "{\"created\": \"2026-10-23T08:00:00Z\", \"head\": \"h12b\", \"suites\": [$(suite 2026-10-23T10:59:00Z "$FAIL_CLOSED" COMPLETED FAILURE)]}" \
  "$FIX/pr-12.after-update.json"
: > "$FIX/gh.log"
out=$(q advance --repo o/r)
check "labels the oldest ready PR" "labeled 12" "$(jq -r '"\(.result) \(.pr)"' <<< "$out")"
check "after updating it" "true h12b 2" "$(jq -r '"\(.updated) \(.sha) \(.behind_by)"' <<< "$out")"
check "update-branch runs before the label goes on" \
  "pr update-branch 12 -R o/r|pr edit 12 -R o/r --add-label ci:full" "$(glog | paste -sd'|' -)"

echo "advance: up to date"
: > "$FIX/gh.log"
out=$(q advance --repo o/r --pr 16)
check "--pr picks the PR" "labeled 16 false" "$(jq -r '"\(.result) \(.pr) \(.updated)"' <<< "$out")"
check "no update when not behind" "pr edit 16 -R o/r --add-label ci:full" "$(glog)"

echo "advance: races"
mkpr 12 '{"created": "2026-10-23T08:00:00Z"}'
# compare says behind, update-branch says up to date — auto-rebase moved the head.
mkpr 12 "{\"head\": \"h12b\", \"suites\": [$(suite 2026-10-23T10:59:00Z "$FAIL_CLOSED" COMPLETED FAILURE)]}" "$FIX/pr-12.after-update.json"
echo "! PR branch already up-to-date" > "$FIX/update-12.out"
out=$(q advance --repo o/r --pr 12)
check "re-reads the head when update-branch says up to date" "labeled 12 h12b" "$(jq -r '"\(.result) \(.pr) \(.sha)"' <<< "$out")"
# …and when the head really is still behind, it does not label.
mkpr 12 '{"created": "2026-10-23T08:00:00Z"}'
: > "$FIX/gh.log"
out=$(q advance --repo o/r --pr 12)
check "still behind after the update → not labeled" "none_ready update_failed" "$(jq -r '"\(.result) \(.attempts[0].outcome)"' <<< "$out")"
lacks "and no label" "$(glog)" "--add-label"
rm -f "$FIX/update-12.out"
# update-branch fails outright: try the next ready PR.
echo 1 > "$FIX/update-12.rc"; echo "merge conflict between base and head" > "$FIX/update-12.out"
: > "$FIX/gh.log"
out=$(q advance --repo o/r)
check "a failed update moves on to the next ready PR" "labeled 16" "$(jq -r '"\(.result) \(.pr)"' <<< "$out")"
contains "and records why" "$(jq -r '.attempts[0] | "\(.pr) \(.outcome) \(.reason)"' <<< "$out")" "12 update_failed gh pr update-branch: merge conflict"
rm -f "$FIX/update-12.rc" "$FIX/update-12.out"
# The update dismissed the approval.
mkpr 12 "{\"head\": \"h12b\", \"review\": \"REVIEW_REQUIRED\"}" "$FIX/pr-12.after-update.json"
: > "$FIX/gh.log"
out=$(q advance --repo o/r --pr 12)
check "lost approval after the update → not labeled" "approval_lost" "$(jq -r '.attempts[0].outcome' <<< "$out")"
lacks "and no label" "$(glog)" "--add-label"

echo "advance: waits for the gated workflow's own run, not any run"
mkpr 12 "{\"created\": \"2026-10-23T08:00:00Z\", \"suites\": [$(suite 2026-10-23T09:00:00Z "$FAIL_CLOSED" COMPLETED FAILURE)]}"
compare h12 2
# After the update only a fast CodeQL run exists on h12b; the gated Test run
# shows up on the 5th read of #12.
mkpr 12 "{\"head\": \"h12b\", \"suites\": [$(suite 2026-10-23T10:59:00Z '{"CodeQL": "SUCCESS"}' COMPLETED SUCCESS 2026-10-23T10:59:00Z CodeQL)]}" \
  "$FIX/pr-12.after-update.json"
mkpr 12 "{\"head\": \"h12b\", \"suites\": [$(suite 2026-10-23T10:59:00Z '{"CodeQL": "SUCCESS"}' COMPLETED SUCCESS 2026-10-23T10:59:00Z CodeQL), $(suite 2026-10-23T10:59:05Z "$FAIL_CLOSED" COMPLETED FAILURE)]}" \
  "$FIX/pr-12.then.json"
echo 5 > "$FIX/pr-12.then-at"; rm -f "$FIX/reads-12"
out=$(QUEUE_NOW='' QUEUE_UPDATE_TIMEOUT=20 bash "$QUEUE_SH" advance --repo o/r --pr 12)
check "labels once the gated run exists" "labeled 12 h12b" "$(jq -r '"\(.result) \(.pr) \(.sha)"' <<< "$out")"
check "not as soon as the unrelated run appeared" "true" "$( (( $(cat "$FIX/reads-12") >= 5 )) && echo true || echo false)"
rm -f "$FIX/pr-12.then-at"

echo "advance: nothing to do"
mkpr 12 '{"review": "REVIEW_REQUIRED"}'; mkpr 16 '{"review": "REVIEW_REQUIRED"}'
out=$(q advance --repo o/r)
check "nothing ready" "none_ready" "$(jq -r .result <<< "$out")"
contains "lists why" "$(jq -c .not_ready <<< "$out")" '"reasons":["not approved yet"]'
out=$(q advance --repo o/empty)
check "nothing queued" "empty" "$(jq -r .result <<< "$out")"
out=$(q advance --repo o/r --pr 99); rc=$?
check "--pr outside the queue exits 2" "2" "$rc"

echo "advance: --relabel"
compare h12 0
mkpr 12 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:05:01Z "$FAIL_CLOSED" COMPLETED CANCELLED)]}"
: > "$FIX/gh.log"
out=$(q advance --repo o/r --pr 12 --relabel)
check "re-runs the holder's suite" "labeled 12 true" "$(jq -r '"\(.result) \(.pr) \(.relabeled)"' <<< "$out")"
check "by removing then re-adding ci:full" \
  "pr edit 12 -R o/r --remove-label ci:full|pr edit 12 -R o/r --add-label ci:full" "$(glog | paste -sd'|' -)"

# ─── watch (holder) ──────────────────────────────────────────────────────────
echo "watch: holder events"
wh() { bash "$QUEUE_SH" watch --repo o/r --pr 12 --interval 0 --timeout 0 "$@"; }
mkpr 12 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE)]}"
labeled 12 99
out=$(wh); rc=$?
check "the false failure right after labeling is no event (heartbeat)" "10" "$rc"
contains "heartbeat line" "$out" "EVENT=HEARTBEAT repo=o/r pr=12"
lacks "never CI_FAILED" "$out" "CI_FAILED"
contains "reports, but doesn't count, a foreign labeled PR" "$out" "outside the queue, not touched: #99 (app/dependabot)"

labeled 12 16 99
out=$(wh); rc=$?
check "another queued PR labeled → CONTENTION" "0 CONTENTION" "$rc $(grep -o 'EVENT=[A-Z_]*' <<< "$out" | sed 's/EVENT=//')"
contains "names it, not the foreign one" "$out" "others=16"
labeled 12 14! 99
out=$(wh); rc=$?
check "a labeled PR without crow:merge is not contention" "10" "$rc"
contains "it is reported as merged by hand" "$out" "#14 (no crow:merge, merged by hand)"
jq '(.sessions[] | select(.id == "S16") | .branch) = "b-other"' "$FIX/sessions.json" > "$TMP/s.json" && cp "$FIX/sessions.json" "$TMP/sessions.bak" && mv "$TMP/s.json" "$FIX/sessions.json"
labeled 12 16 99
out=$(wh); rc=$?
check "a labeled PR on another branch than its session is not contention" "10" "$rc"
contains "it is reported" "$out" "#16 (not on the branch of its session)"
mv "$TMP/sessions.bak" "$FIX/sessions.json"
labeled 12 99

h12() { mkpr 12 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"head\": \"${2:-h12}\", \"mss\": \"${3:-BLOCKED}\", \"timeline\": [$(on 2026-10-23T10:05:00Z)],
  \"suites\": [$(suite 2026-10-23T10:04:58Z "$FAIL_CLOSED" COMPLETED FAILURE), $1]}"; }
h12 "$(suite 2026-10-23T10:05:02Z "$RED" COMPLETED FAILURE 2026-10-23T10:40:00Z)"
out=$(wh); rc=$?
check "a labeled run that failed → CI_FAILED" "0" "$rc"
contains "with the head and the failed jobs" "$out" "EVENT=CI_FAILED repo=o/r pr=12 sha=h12 run=https://github.com/o/r/actions/runs/12 failed=Lint"
out=$(wh --ack-failure h12); rc=$?
check "acknowledged, 20m without a fix → keep waiting" "10" "$rc"
contains "says it is waiting for a fix" "$out" "waiting for a fix"
contains "the heartbeat carries the ack to re-arm with" "$out" "ack=h12"
h12 "$(suite 2026-10-23T10:05:02Z "$RED" COMPLETED FAILURE 2026-10-23T10:10:00Z)"
out=$(wh --ack-failure h12); rc=$?
check "acknowledged, 50m without a fix → NO_FIX" "0" "$rc"
contains "with how long" "$out" "EVENT=NO_FIX repo=o/r pr=12 sha=h12 failed_for=50m"
h12 "$(suite 2026-10-23T10:50:00Z "$RUNNING" IN_PROGRESS)" h12c
out=$(wh --ack-failure h12); rc=$?
check "the fix landed (new head, suite running) → keep waiting" "10" "$rc"
lacks "the old ack no longer applies" "$out" "waiting for a fix"

h12 "$(suite 2026-10-23T10:05:02Z "$GREEN" COMPLETED SUCCESS 2026-10-23T10:50:00Z)"
out=$(wh); rc=$?
check "green 10m, not merged yet → keep waiting" "10" "$rc"
h12 "$(suite 2026-10-23T10:05:02Z "$GREEN" COMPLETED SUCCESS 2026-10-23T10:40:00Z)" h12 CLEAN
out=$(wh); rc=$?
check "green 20m, not merged → STUCK_AFTER_GREEN" "0" "$rc"
contains "with the merge state" "$out" "EVENT=STUCK_AFTER_GREEN repo=o/r pr=12 mss=CLEAN green_for=20m"

h12 "$(suite 2026-10-23T10:59:30Z "$FAIL_CLOSED" COMPLETED CANCELLED 2026-10-23T10:59:30Z)"
out=$(wh); rc=$?
check "lone CI Gate red 30s after the label → keep waiting" "10" "$rc"
h12 "$(suite 2026-10-23T10:50:00Z "$FAIL_CLOSED" COMPLETED CANCELLED 2026-10-23T10:50:00Z)"
out=$(wh); rc=$?
check "lone CI Gate red for 10m → SUITE_NOT_RUN" "0 SUITE_NOT_RUN" "$rc $(grep -o 'EVENT=[A-Z_]*' <<< "$out" | sed 's/EVENT=//')"

mkpr 12 "{\"labels\": [\"crow:merge\"], \"timeline\": [$(on 2026-10-23T10:05:00Z), $(off 2026-10-23T10:30:00Z someone)]}"
out=$(wh); rc=$?
check "label taken off → LABEL_REMOVED" "0" "$rc"
contains "with who" "$out" "EVENT=LABEL_REMOVED repo=o/r pr=12 by=someone"
mkpr 12 "{\"state\": \"MERGED\", \"merged\": \"2026-10-23T10:14:00Z\", \"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:05:00Z)]}"
out=$(wh); rc=$?
check "merged → MERGED" "0" "$rc"
contains "MERGED line, with label-to-merge time" "$out" "EVENT=MERGED repo=o/r pr=12 took=9m"
mkpr 12 '{"state": "CLOSED", "labels": ["crow:merge", "ci:full"]}'
out=$(wh)
contains "closed → CLOSED" "$out" "EVENT=CLOSED repo=o/r pr=12"

echo "watch: degraded reads never invent an event"
h12 "$(suite 2026-10-23T10:05:02Z "$RUNNING" IN_PROGRESS)"
labeled 12 16
out=$(FAKE_CROW_FAIL=1 bash "$QUEUE_SH" watch --repo o/r --pr 12 --interval 0 --timeout 0); rc=$?
check "crow unreachable → heartbeat, not contention" "10" "$rc"
contains "and says contention went unchecked" "$out" "contention unchecked (crow unreachable)"
rm -f "$FIX/labeled.json"
out=$(wh); rc=$?
check "gh pr list failing → heartbeat" "10" "$rc"
contains "and says so" "$out" "contention unchecked (gh pr list failed)"
labeled 12
mv "$FIX/pr-12.json" "$TMP/pr-12.bak"
out=$(wh); rc=$?
check "the holder unreadable → heartbeat" "10" "$rc"
contains "and says so" "$out" "could not read o/r#12"
mv "$TMP/pr-12.bak" "$FIX/pr-12.json"

# ─── watch (idle) ────────────────────────────────────────────────────────────
echo "watch: idle"
wi() { bash "$QUEUE_SH" watch --repo o/r --interval 0 --timeout 0; }
mkpr 11 '{"state": "MERGED"}'
mkpr 12 '{"review": "REVIEW_REQUIRED"}'; mkpr 16 '{"review": "REVIEW_REQUIRED"}'
mkpr 14 "{\"labels\": [\"ci:full\"], \"timeline\": [$(on 2026-10-23T10:58:00Z)]}"
out=$(wi); rc=$?
check "nothing ready → heartbeat" "10" "$rc"
contains "lists why" "$out" "#12 (not approved yet)"
contains "a labeled manual-merge PR is listed, not LABELED" "$out" "merged by hand, not queued: #14"
mkpr 16 '{"created": "2026-10-23T09:00:00Z"}'
out=$(wi); rc=$?
check "a queued PR became ready → READY" "0" "$rc"
contains "names it" "$out" "EVENT=READY repo=o/r pr=16"
mkpr 12 "{\"labels\": [\"crow:merge\", \"ci:full\"], \"timeline\": [$(on 2026-10-23T10:58:00Z)]}"
out=$(wi); rc=$?
check "a queued PR got ci:full → LABELED" "0" "$rc"
contains "names it" "$out" "EVENT=LABELED repo=o/r prs=12"
out=$(q watch --repo o/r --ack-failure abc); rc=$?
check "--ack-failure without --pr exits 2" "2" "$rc"
out=$(q bogus); rc=$?
check "unknown subcommand exits 2" "2" "$rc"

# ─── keep running after a drain (CROW-1369) ──────────────────────────────────
echo "watch: idle on a drained queue"
# Every queued PR merged; their sessions still link them. #14 (no crow:merge) stays open.
for n in 12 15 16 17; do mkpr "$n" '{"state": "MERGED"}'; done
out=$(wi); rc=$?
check "a drained queue → heartbeat, not an event" "10" "$rc"
contains "reads as nothing queued" "$out" "idle · nothing queued · merged by hand, not queued: #14"
lacks "no 0-queued line" "$out" "0 queued"
out=$(q watch --repo o/empty --interval 0 --timeout 0); rc=$?
check "a repo with nothing tracked → heartbeat" "10" "$rc"
contains "reads as nothing queued" "$out" "EVENT=HEARTBEAT repo=o/empty · idle · nothing queued"
# A session created after kickoff opens a PR with crow:merge in the drained repo.
# shellcheck disable=SC2016
jq '.sessions += [{id: "S18", name: "r-18", branch: "b18", kind: "work", status: "active",
                   links: [{type: "pr", url: "https://github.com/o/r/pull/18"}]}]' "$FIX/sessions.json" > "$TMP/s.json" \
  && mv "$TMP/s.json" "$FIX/sessions.json"
mkpr 18 '{}'
out=$(wi); rc=$?
check "a new session PR in a drained queue → READY" "0" "$rc"
contains "names it" "$out" "EVENT=READY repo=o/r pr=18"

echo "status: a repo that becomes queueable after kickoff"
# shellcheck disable=SC2016
jq '.sessions += [{id: "S41", name: "new-41", branch: "b41", kind: "work", status: "active",
                   links: [{type: "pr", url: "https://github.com/o/new/pull/41"}]}]' "$FIX/sessions.json" > "$TMP/s.json" \
  && mv "$TMP/s.json" "$FIX/sessions.json"
mkpr 41 '{}'
st=$(q status)
check "the all-repos status picks it up" "o/new o/r" "$(jq -r '[.repos[].repo] | sort | join(" ")' <<< "$st")"
st=$(q status --repo o/r)
check "a --repo status leaves it out" "o/r" "$(jq -r '[.repos[].repo] | join(" ")' <<< "$st")"

# ─── a just-pushed head (CROW-1374) ──────────────────────────────────────────
echo "status: a just-pushed head doesn't drop a live repo"
# corveil/corveil#4973 on 2026-10-26: the holder merged, its session completed,
# and auto-rebase pushed the one PR left, a draft without ci:full. Its new head
# had no checks yet, so no CI Gate.
# shellcheck disable=SC2016
jq '.sessions += [{id: "S51", name: "live-51", branch: "b51", kind: "work", status: "active",
                   links: [{type: "pr", url: "https://github.com/o/live/pull/51"}]},
                  {id: "S52", name: "seen-52", branch: "b52", kind: "work", status: "active",
                   links: [{type: "pr", url: "https://github.com/o/seen/pull/52"}]}]' "$FIX/sessions.json" > "$TMP/s.json" \
  && mv "$TMP/s.json" "$FIX/sessions.json"
marker() { if [[ -e "$TMP/queues/.convention-$1" ]]; then echo present; else echo absent; fi; }
# Seen before: #52's head has a CI Gate check when normalize reads it.
mkpr 52 '{"draft": true, "review": "REVIEW_REQUIRED"}'
out=$(q normalize --repo o/seen); rc=$?
check "normalize on the old head succeeds" "0 ok" "$rc $(jq -r .status <<< "$out")"
check "and remembers that o/seen follows the convention" "present" "$(marker o-seen)"
# Auto-rebase pushes h52b: no check suites, no CI Gate, no ci:full, never labeled.
mkpr 52 '{"draft": true, "review": "REVIEW_REQUIRED", "head": "h52b", "rollup": []}'
st=$(q status --repo o/seen)
check "a fresh head in a repo seen following the convention stays queued" "o/seen" "$(jq -r '[.repos[].repo] | join(" ")' <<< "$st")"
check "and nothing is ignored" "0" "$(jq -r '.ignored | length' <<< "$st")"
out=$(q advance --repo o/seen); rc=$?
check "advance answers for the draft, not the convention" "0 none_ready" "$rc $(jq -r .result <<< "$out")"
out=$(q normalize --repo o/seen); rc=$?
check "and so does normalize" "0 ok" "$rc $(jq -r .status <<< "$out")"
# A sighting over a day old no longer bridges a read with no evidence.
touch -t 202601010000 "$TMP/queues/.convention-o-seen"
out=$(q advance --repo o/seen); rc=$?
check "a sighting over a day old doesn't count" "2" "$rc"
contains "and the repo reads as not following the convention" "$out" "o/seen does not follow the CI Gate convention"
# Never read before, but #51 carried ci:full yesterday: its timeline shows it.
mkpr 51 "{\"draft\": true, \"head\": \"h51b\", \"rollup\": [], \"timeline\": [$(on 2026-10-22T10:00:00Z), $(off 2026-10-22T11:00:00Z)]}"
st=$(q status --repo o/live)
check "a fresh head on a PR that has carried ci:full stays queued" "o/live" "$(jq -r '[.repos[].repo] | join(" ")' <<< "$st")"
out=$(q advance --repo o/live); rc=$?
check "advance answers for the draft" "0 none_ready" "$rc $(jq -r .result <<< "$out")"

echo "status: a repo that never showed the convention is still ignored"
# o/plain's #21 has never had a CI Gate check or ci:full.
st=$(q status)
contains "it is ignored" "$(jq -c .ignored <<< "$st")" "o/plain does not follow the CI Gate convention"
check "and never remembered" "absent" "$(marker o-plain)"
mkpr 21 '{"head": "h21b", "rollup": []}'
st=$(q status)
contains "a fresh head doesn't change that" "$(jq -c .ignored <<< "$st")" "o/plain does not follow the CI Gate convention"
check "it isn't queued" "false" "$(jq -r 'any(.repos[]; .repo == "o/plain")' <<< "$st")"
out=$(q normalize --repo o/plain); rc=$?
check "normalize still exits 2" "2" "$rc"
mkpr 21 '{"rollup": ["build"]}'

echo "watch: one watcher per repo"
lock="$TMP/queues/.watch-o-empty.pid"
lock_state() { if [[ -e "$lock" ]]; then echo present; else echo absent; fi; }
skip() { echo "  skip: $1 ($2)"; }
wq() { q watch --repo o/empty --interval 0 --timeout 0; }
# ps is denied in some sandboxes; the checks that need the real one say so.
ps_ok=false; ps -p $$ -o command= >/dev/null 2>&1 && ps_ok=true
printf '#!/usr/bin/env bash\necho "ps: operation not permitted" >&2\nexit 1\n' > "$TMP/fake-ps-fail"
chmod +x "$TMP/fake-ps-fail"
# Nothing queued and a fixed clock: this watcher polls until it's stopped.
bash "$QUEUE_SH" watch --repo o/empty --interval 30 > "$TMP/w1.out" 2>&1 &
w1=$!
for _ in $(seq 50); do [[ -s "$lock" ]] && break; sleep 0.1; done
check "a watcher takes its repo's lock" "$w1" "$(cat "$lock" 2>/dev/null)"
out=$(wq); rc=$?
check "a second watcher on the same repo is refused" "2" "$rc"
contains "and names the holder" "$out" "pid $w1 already holds the o/empty watcher lock"
if $ps_ok; then
  contains "as a running watcher" "$out" "(a running watcher)"
else
  skip "as a running watcher" "ps unavailable here"
fi
out=$(PS_BIN="$TMP/fake-ps-fail" wq); rc=$?
check "a live holder ps can't check still counts (fails closed)" "2" "$rc"
contains "and says why" "$out" "ps couldn't say what it is, so it counts as a watcher"
out=$(wi); rc=$?
check "another repo's watcher still starts" "0" "$rc"
check "and releases its own lock" "absent" "$([[ -e "$TMP/queues/.watch-o-r.pid" ]] && echo present || echo absent)"
kill -TERM "$w1"
for _ in $(seq 50); do [[ -e "$lock" ]] || break; sleep 0.1; done
check "a stopped watcher (TaskStop) frees the repo at once" "absent" "$(lock_state)"
kill -KILL "$w1" 2>/dev/null; wait "$w1" 2>/dev/null
sh -c 'exit 0' & dead=$!; wait "$dead"
echo "$dead" > "$lock"
out=$(PS_BIN="$TMP/fake-ps-fail" wq); rc=$?
check "a lock whose process is gone is taken over, with or without ps" "10" "$rc"
if $ps_ok; then
  echo "$$" > "$lock"
  out=$(wq); rc=$?
  check "a lock held by a live process that isn't a watcher is taken over" "10" "$rc"
  check "and released on exit" "absent" "$(lock_state)"
else
  skip "a lock held by a live process that isn't a watcher is taken over" "ps unavailable here"
fi
if [[ "$(export LC_ALL=C; kill -0 1 2>&1)" == *"not permitted"* ]]; then
  echo 1 > "$lock"
  out=$(wq); rc=$?
  check "a holder that can't be signalled counts (fails closed)" "2" "$rc"
  contains "and says why" "$out" "it can't be signalled"
else
  skip "a holder that can't be signalled counts" "pid 1 is signallable here"
fi
echo "$dead" > "$lock"
mkdir "$lock.takeover"
out=$(wq); rc=$?
check "a takeover already under way is refused" "2" "$rc"
contains "and says so" "$out" "taking its watcher lock right now"
touch -t 202601010000 "$lock.takeover"
out=$(wq); rc=$?
check "a takeover mutex left over a minute ago is cleared" "10" "$rc"
check "and released with the lock" "absent absent" "$(lock_state) $([[ -e "$lock.takeover" ]] && echo present || echo absent)"

echo
echo "queue_test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
