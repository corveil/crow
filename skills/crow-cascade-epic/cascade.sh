#!/usr/bin/env bash
# crow-cascade-epic helper (CROW-1312) — the deterministic half of a
# dependency-gated epic cascade. The LLM half (reading the epic, composing
# coder prompts, running crow-workspace/setup.sh) lives in SKILL.md.
#
#   plan   --plan-file F                 validate the DAG, assign waves, write them back
#   status --plan-file F [--wave N]      per-ticket merge state, contract drift, resume point
#   watch  --plan-file F --wave N        poll one wave until every ticket's PR has merged
#
# `plan` and `status` print one JSON object. `watch` prints one line per change
# so it can run under run_in_background / Monitor, and exits:
#   0  every ticket in the wave is satisfied — release the next wave
#   3  blocked — an unsatisfied ticket can't progress on its own (needs the operator)
#   10 still open at --timeout — re-arm
#   2  usage / plan error
#
# Requires jq. Reads GitHub via `gh api graphql` and Crow via `crow` —
# override with GH_BIN / CROW_BIN (tests do).

set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
CROW_BIN="${CROW_BIN:-crow}"

PLAN_FILE=""
WAVE=""
INTERVAL=120
TIMEOUT=6600

die() { # die <step> <message>
  jq -cn --arg step "$1" --arg msg "$2" '{status:"error", step:$step, message:$msg}'
  exit 2
}

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# The filters are written for jq 1.6 (so no keyword-named keys like a bare
# `label`, which 1.7 accepts and 1.6 rejects). Older jq lacks IN/any-with-
# generator, so refuse it up front rather than mis-evaluating a gate. An
# unparseable version string is let through: collect_status fails closed.
require_jq_16() {
  local v
  v=$(jq --version 2>/dev/null)
  if [[ "$v" =~ ^jq-([0-9]+)\.([0-9]+) ]]; then
    local major="${BASH_REMATCH[1]}" minor="${BASH_REMATCH[2]}"
    if (( major < 1 || (major == 1 && minor < 6) )); then
      die "preflight" "jq 1.6 or newer is required (found $v at $(command -v jq))"
    fi
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan-file) PLAN_FILE="$2"; shift 2 ;;
      --wave)      WAVE="$2"; shift 2 ;;
      --interval)  INTERVAL="$2"; shift 2 ;;
      --timeout)   TIMEOUT="$2"; shift 2 ;;
      --help|-h)   usage ;;
      *) die "parse_args" "unknown argument: $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "preflight" "jq is required"
  require_jq_16
  [[ -n "$PLAN_FILE" ]] || die "parse_args" "--plan-file is required"
  [[ -f "$PLAN_FILE" ]] || die "parse_args" "plan file not found: $PLAN_FILE"
  jq -e 'type == "object"' "$PLAN_FILE" >/dev/null 2>&1 || die "parse_args" "plan file is not a JSON object: $PLAN_FILE"
  if [[ -n "$WAVE" && ! "$WAVE" =~ ^[0-9]+$ ]]; then
    die "parse_args" "--wave must be a positive integer (got $WAVE)"
  fi
}

# ─── plan ────────────────────────────────────────────────────────────────────

# Validates the plan and layers the DAG with Kahn's algorithm: wave 1 is every
# ticket with no deps, wave k+1 is every ticket whose deps all sit in waves ≤ k.
# Emits either {errors:[...]} or the plan with `.tickets[].wave` and `.waves`.
# shellcheck disable=SC2016  # jq program: the $names are jq variables
PLAN_JQ='
(.tickets // []) as $t
| [$t[].id] as $ids
| [
    (if ($t | length) == 0 then "plan has no tickets" else empty end),
    (if ((.gate // "") | IN("human", "auto")) then empty
     else "gate must be \"human\" or \"auto\" (got \(.gate // "null"))" end),
    (if (.reviewer // "") == "" then "reviewer is required" else empty end),
    ($t[] | select((.id // "") == "") | "ticket missing id: \(.url // tostring)"),
    ($t[] | select((.url // "") == "") | "ticket \(.id) missing url"),
    ($ids | group_by(.) | map(select(length > 1) | .[0]) | .[] | "duplicate ticket id: \(.)"),
    ($t[] | .id as $id | (.deps // [])[] | select(. == $id) | "\($id) depends on itself"),
    ($t[] | .id as $id | (.deps // [])[]
      | select(. as $d | $ids | any(. == $d) | not)
      | "\($id) depends on \(.), which is not in the plan (add it with \"external\": true to gate on it)")
  ] as $errors
| if ($errors | length) > 0 then {errors: $errors}
  else
    ($t | map({key: .id, value: (.deps // [])}) | from_entries) as $deps
    | ({assigned: {}, remaining: $ids, wave: 0, cycle: null}
       | until((.remaining | length) == 0 or .cycle != null;
           . as $s
           | [$s.remaining[] | select(. as $id | $deps[$id] | all(. as $d | $s.assigned | has($d)))] as $ready
           | if ($ready | length) == 0 then .cycle = $s.remaining
             else .wave += 1
               | .assigned += ([$ready[] | {key: ., value: ($s.wave + 1)}] | from_entries)
               | .remaining -= $ready
             end)) as $layered
    | if $layered.cycle != null then {errors: ["dependency cycle among: \($layered.cycle | join(", "))"]}
      else
        .tickets = [$t[] | .deps = (.deps // []) | .external = (.external // false) | .wave = $layered.assigned[.id]]
        | .start_wave = (.start_wave // 1)
        | .waves = [range(1; $layered.wave + 1) as $w
            | {wave: $w, tickets: [.tickets[] | select(.wave == $w) | .id]}]
      end
  end
'

cmd_plan() {
  local out tmp
  out=$(jq "$PLAN_JQ" "$PLAN_FILE" 2>&1) || die "plan" "jq failed: $out"
  if jq -e 'has("errors")' <<< "$out" >/dev/null; then
    jq -c '{status:"error", step:"plan", errors:.errors}' <<< "$out"
    exit 2
  fi
  tmp="$PLAN_FILE.tmp.$$"
  if ! { printf '%s\n' "$out" > "$tmp" && mv "$tmp" "$PLAN_FILE"; }; then
    rm -f "$tmp"
    die "plan" "could not write $PLAN_FILE"
  fi
  jq -c --arg file "$PLAN_FILE" '.tickets as $tickets | {
      status: "ok", plan_file: $file, gate, reviewer, start_wave,
      wave_count: (.waves | length),
      waves: [.waves[] | .wave as $w | {wave: $w, tickets: [$tickets[] | select(.wave == $w)
               | {id, "label": ."label", title, external, deps}]}]
    }' "$PLAN_FILE"
}

# ─── status ──────────────────────────────────────────────────────────────────

# shellcheck disable=SC2016  # GraphQL variables, not shell expansion
PR_FRAGMENT='fragment P on PullRequest { number url state mergedAt isDraft author { login } labels(first: 30) { nodes { name } } reviewRequests(first: 20) { nodes { requestedReviewer { ... on User { login } ... on Team { slug } } } } latestReviews(first: 20) { nodes { state author { login } } } }'
# shellcheck disable=SC2016
ISSUE_QUERY='query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { issue(number: $number) { state stateReason closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { ...P } } } } } '"$PR_FRAGMENT"
# shellcheck disable=SC2016
PR_QUERY='query($url: URI!) { resource(url: $url) { ... on PullRequest { ...P } } } '"$PR_FRAGMENT"

GITHUB_ISSUE_RE='^https://github\.com/([^/]+)/([^/]+)/issues/([0-9]+)'

# Raw facts for one ticket as a single JSON line — no interpretation here, so
# the classification stays in one jq program (STATUS_JQ) that tests can reach.
#   {id, issue: {state, stateReason}|null, prs: [PR nodes], error: str|null}
collect_ticket() { # collect_ticket <ticket-json> <sessions-json>
  local ticket="$1" sessions="$2"
  local id url issue='null' prs='[]' error='' resp
  id=$(jq -r '.id' <<< "$ticket")
  url=$(jq -r '.url' <<< "$ticket")

  if [[ "$url" =~ $GITHUB_ISSUE_RE ]]; then
    if resp=$("$GH_BIN" api graphql -f query="$ISSUE_QUERY" \
        -F owner="${BASH_REMATCH[1]}" -F name="${BASH_REMATCH[2]}" -F number="${BASH_REMATCH[3]}" 2>&1) \
       && jq -e '.data.repository.issue' <<< "$resp" >/dev/null 2>&1; then
      issue=$(jq -c '.data.repository.issue | {state, stateReason}' <<< "$resp")
      prs=$(jq -c '[.data.repository.issue.closedByPullRequestsReferences.nodes[]?]' <<< "$resp")
    else
      error="GitHub issue query failed: $(head -c 300 <<< "$resp")"
    fi
  fi

  # The coder registers its PR with `crow add-link --type pr` — that link is
  # the fallback when the PR body lacks `Closes #N` (and the only source for a
  # Jira ticket whose code lands on GitHub).
  local sid link_urls pr_url pr_resp
  sid=$(jq -r --arg url "$url" '[.[] | select(.kind == "work" and .ticket_url == $url and (.is_explore | not))][0].id // empty' <<< "$sessions")
  if [[ -n "$sid" ]]; then
    link_urls=$("$CROW_BIN" list-links --session "$sid" 2>/dev/null \
      | jq -r '.links[]? | select(.type == "pr") | .url' 2>/dev/null) || link_urls=''
    while IFS= read -r pr_url; do
      [[ -n "$pr_url" ]] || continue
      jq -e --arg u "$pr_url" 'any(.[]; .url == $u)' <<< "$prs" >/dev/null && continue
      if pr_resp=$("$GH_BIN" api graphql -f query="$PR_QUERY" -F url="$pr_url" 2>/dev/null) \
         && jq -e '.data.resource.number' <<< "$pr_resp" >/dev/null 2>&1; then
        prs=$(jq -c --argjson pr "$(jq -c '.data.resource' <<< "$pr_resp")" '. + [$pr]' <<< "$prs")
      fi
    done <<< "$link_urls"
  fi

  jq -cn --arg id "$id" --argjson issue "$issue" --argjson prs "$prs" --arg error "$error" \
    '{id: $id, issue: $issue, prs: $prs, error: (if $error == "" then null else $error end)}'
}

# Classification, contract drift and the resume point.
#
# Ticket state, first match wins:
#   merged             a linked PR merged                          satisfied
#   in_review / draft  an open PR (even if the issue was closed)   —
#   closed             issue closed COMPLETED, no PR               satisfied (a human closed it as done)
#   closed_not_planned issue closed NOT_PLANNED / DUPLICATE        blocked (dependents can never release)
#   pr_closed          only closed-unmerged PRs                    — (the coder may open another)
#   no_pr              nothing yet                                 —
#   unknown            the GitHub query failed                     — (transient; never releases a wave)
# shellcheck disable=SC2016  # jq program: the $names are jq variables
STATUS_JQ='
def pr: {
  number, url, state,
  merged: (.state == "MERGED"),
  draft: (.isDraft // false),
  author: (.author.login // null),
  labels: [.labels.nodes[]?.name],
  requested: [.reviewRequests.nodes[]?.requestedReviewer | (.login // .slug) | select(. != null)],
  reviewed_by: [.latestReviews.nodes[]?.author.login | select(. != null)],
  approved_by: [.latestReviews.nodes[]? | select(.state == "APPROVED") | .author.login | select(. != null)]
};

def classify($issue; $prs; $error):
  if any($prs[]; .merged) then "merged"
  elif any($prs[]; .state == "OPEN" and (.draft | not)) then "in_review"
  elif any($prs[]; .state == "OPEN") then "draft"
  elif $issue != null and $issue.state == "CLOSED" and $issue.stateReason == "COMPLETED" then "closed"
  elif $issue != null and $issue.state == "CLOSED" then "closed_not_planned"
  elif $error != null then "unknown"
  elif ($prs | length) > 0 then "pr_closed"
  else "no_pr" end;

def drift($gate; $reviewer; $prs):
  [$prs[] | select(.state == "OPEN")] as $open
  | [$prs[] | select(.merged)] as $merged
  | [ (if ($merged | length) > 0 and ($open | length) > 0
         then "\($open | map("PR #\(.number)") | join(", ")) still open although \($merged | map("#\(.number)") | join(", ")) already merged this ticket — close it, or move that work to its own ticket"
       else empty end),
      (if ($open | length) > 1
         then "\($open | length) open PRs (\($open | map("#\(.number)") | join(", "))) — the cascade expects exactly one PR per ticket"
       else empty end),
      ($open[] | . as $p
        | (if ($p.approved_by | any(. == $p.author)) then "PR #\($p.number) is approved by its own author" else empty end),
          (if ([$p.requested[], $p.reviewed_by[]] | any(. == $reviewer)) then empty
           else "PR #\($p.number) has no review request for @\($reviewer)" end),
          (if $gate == "human" and ($p.labels | any(. == "crow:merge"))
                and ([$p.approved_by[] | select(. != $p.author)] | length) == 0
             then "PR #\($p.number) carries crow:merge before any human approval (human gate)"
           else empty end),
          (if $gate == "auto" and ($p.draft | not) and ($p.labels | any(. == "crow:merge") | not)
             then "PR #\($p.number) is missing the crow:merge label (auto gate)"
           else empty end))
    ];

def session_for($url; $explore):
  [$sessions[] | select(.kind == "work" and .ticket_url == $url and ((.is_explore // false) == $explore))]
  | sort_by(if .status == "completed" or .status == "archived" then 1 else 0 end)
  | (.[0] // null) | if . == null then null else {id, name, status} end;

. as $plan
| ($raw | map({key: .id, value: .}) | from_entries) as $facts
| ($plan.start_wave // 1) as $start
| [$plan.tickets[] | select($wave == null or .wave == $wave)
    | . as $t
    | ($facts[$t.id] // {issue: null, prs: [], error: "not queried"}) as $f
    | [$f.prs[] | pr] as $prs
    | classify($f.issue; $prs; $f.error) as $state
    | {
        id, "label": ."label", title, url, wave,
        external: (.external // false),
        state: $state,
        satisfied: ($state == "merged" or $state == "closed"),
        blocked: ($state == "closed_not_planned"),
        prs: [$prs[] | {number, url, state, draft, labels}],
        session: session_for($t.url; false),
        explore_session: session_for($t.url; true),
        drift: (if (.external // false) then [] else drift($plan.gate; $plan.reviewer; $prs) end),
        error: $f.error
      }
  ] as $tickets
| ([$tickets[].wave] | unique) as $waves
| [ $waves[] as $w
    | [$tickets[] | select(.wave == $w)] as $in
    | {
        wave: $w,
        skipped: ($w < $start),
        total: ($in | length),
        satisfied: ([$in[] | select(.satisfied)] | length),
        complete: ($w < $start or all($in[]; .satisfied)),
        blocked: [$in[] | select(.blocked) | .id]
      }
  ] as $summary
| ([$summary[] | select(.complete | not) | .wave] | min) as $current
| {
    status: "ok",
    epic: $plan.epic,
    gate: $plan.gate,
    reviewer: $plan.reviewer,
    start_wave: $start,
    wave_count: ($plan.waves | length),
    complete: ($wave == null and $current == null),
    current_wave: (if $wave == null then $current else null end),
    # Nothing in flight: no Crow session, no open PR (someone may be working
    # it outside the cascade), and a state we could actually read.
    to_launch: (if $wave == null and $current != null
                then [$tickets[] | select(.wave == $current and (.external | not) and .session == null
                                          and (.state == "no_pr" or .state == "pr_closed")) | .id]
                else null end),
    waves: $summary,
    tickets: $tickets
  }
'

collect_status() { # collect_status <wave-or-empty>  → status JSON on stdout
  local wave="$1" sessions raw ticket tickets
  sessions=$("$CROW_BIN" list-sessions 2>/dev/null | jq -c '.sessions // []' 2>/dev/null) || sessions='[]'
  [[ -n "$sessions" ]] || sessions='[]'

  raw=$(mktemp "${TMPDIR:-/tmp}/crow-cascade-raw.XXXXXX")
  tickets=$(jq -c --arg w "$wave" '.tickets[] | select($w == "" or .wave == ($w | tonumber))' "$PLAN_FILE")
  while IFS= read -r ticket; do
    [[ -n "$ticket" ]] || continue
    collect_ticket "$ticket" "$sessions" >> "$raw"
  done <<< "$tickets"

  local wave_arg='null' out
  [[ -n "$wave" ]] && wave_arg="$wave"
  # Fail closed: a filter this jq can't run must never look like a finished
  # wave to `watch`, so any failure becomes an explicit error object.
  if ! out=$(jq -c --slurpfile raw "$raw" --argjson sessions "$sessions" --argjson wave "$wave_arg" \
      "$STATUS_JQ" "$PLAN_FILE" 2>&1) || ! jq -e '.status == "ok"' <<< "$out" >/dev/null 2>&1; then
    out=$(jq -cn --arg msg "$(head -c 500 <<< "$out")" \
      '{status: "error", step: "status", message: ("status filter failed: " + $msg)}')
  fi
  rm -f "$raw"
  printf '%s\n' "$out"
}

# Checked outside collect_status: a `die` inside `$(collect_status)` would only
# leave the subshell.
require_planned() {
  jq -e '.waves | length > 0' "$PLAN_FILE" >/dev/null 2>&1 \
    || die "status" "plan file has no waves — run \`cascade.sh plan\` first"
  if [[ -n "$WAVE" ]] && ! jq -e --argjson w "$WAVE" 'any(.waves[]; .wave == $w)' "$PLAN_FILE" >/dev/null; then
    die "status" "wave $WAVE is not in the plan ($(jq -r '.waves | length' "$PLAN_FILE") waves)"
  fi
}

cmd_status() {
  require_planned
  local out
  out=$(collect_status "$WAVE")
  printf '%s\n' "$out"
  jq -e '.status == "ok"' <<< "$out" >/dev/null 2>&1 || exit 2
}

# ─── watch ───────────────────────────────────────────────────────────────────

cmd_watch() {
  [[ -n "$WAVE" ]] || die "parse_args" "watch needs --wave N"
  require_planned
  local started prev cur status now next
  started=$(date +%s)
  prev=$(mktemp "${TMPDIR:-/tmp}/crow-cascade-watch.XXXXXX")
  cur="$prev.cur"
  trap 'rm -f "$prev" "$cur"' EXIT

  echo "watching wave $WAVE of $(jq -r '.epic.url // "the epic"' "$PLAN_FILE") every ${INTERVAL}s (timeout ${TIMEOUT}s)"
  while :; do
    status=$(collect_status "$WAVE")
    # Only an ok status object may release a wave — `jq -e` on an empty or
    # error document is not evidence that anything merged.
    if ! jq -e '.status == "ok"' <<< "$status" >/dev/null 2>&1; then
      echo "WAVE $WAVE status unavailable — $(jq -r '.message // "no status output"' <<< "$status" 2>/dev/null || echo "no status output")"
      exit 2
    fi

    # One line per ticket state + one per drift finding; print only lines that
    # are new since the last poll, so the event stream carries changes only.
    jq -r '.tickets[] | . as $t | "wave \($t.wave) · \($t."label" // $t.id) \($t.id)" as $name
      | "\($name) → \($t.state)"
        + (if ($t.prs | length) > 0 then " (" + ($t.prs | map("PR #\(.number) \(.state | ascii_downcase)") | join(", ")) + ")" else "" end)
        + (if $t.error then " — \($t.error)" else "" end),
        ($t.drift[] | "\($name) ⚠ contract: \(.)")' <<< "$status" > "$cur"
    grep -Fxv -f "$prev" "$cur" || true
    mv "$cur" "$prev"

    if jq -e '.waves[0].complete == true' <<< "$status" >/dev/null; then
      next=$(jq -r --argjson w "$WAVE" \
        '[.tickets[] | select(.wave == $w + 1) | "\(."label" // .id) \(.id)"] | join(", ")' "$PLAN_FILE")
      if [[ -n "$next" ]]; then
        echo "WAVE $WAVE COMPLETE — release wave $((WAVE + 1)): $next"
      else
        echo "WAVE $WAVE COMPLETE — that was the last wave; the cascade is done"
      fi
      exit 0
    fi

    if jq -e '[.tickets[] | select(.satisfied | not)] | length > 0 and all(.[]; .blocked)' <<< "$status" >/dev/null; then
      echo "WAVE $WAVE BLOCKED — needs the operator: $(jq -r '[.tickets[] | select(.blocked) | .id] | join(", ")' <<< "$status") closed without a merged PR"
      exit 3
    fi

    now=$(date +%s)
    if (( now - started >= TIMEOUT )); then
      echo "WAVE $WAVE still open after ${TIMEOUT}s ($(jq -r '"\(.waves[0].satisfied)/\(.waves[0].total) satisfied"' <<< "$status")) — re-arm the watcher"
      exit 10
    fi
    sleep "$INTERVAL"
  done
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    plan)   parse_args "$@"; cmd_plan ;;
    status) parse_args "$@"; cmd_status ;;
    watch)  parse_args "$@"; cmd_watch ;;
    ""|--help|-h|help) usage ;;
    *) die "parse_args" "unknown subcommand: $cmd (expected plan | status | watch)" ;;
  esac
}

# Only run when executed directly — sourcing (tests) exposes the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
