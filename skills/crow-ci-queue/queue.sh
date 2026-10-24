#!/usr/bin/env bash
# crow-ci-queue helper (CROW-1365) — the deterministic half of a serialized
# `ci:full` queue: one Crow session PR per repo runs the label-gated suite and
# merges, then the next one starts. The LLM half (reporting, operator
# decisions, telling coders) lives in SKILL.md.
#
#   status    [--repo R]                        each repo's queue: holder, order, readiness, what to strip
#   normalize --repo R [--keep N] [--dry-run]   strip ci:full from every queued PR except the holder
#   advance   --repo R [--pr N] [--relabel]     update the next ready PR from its base, then add ci:full
#   watch     --repo R --pr N [--ack-failure SHA]   wait on the holder until the queue needs a decision
#   watch     --repo R                          no holder: wait until a queued PR is ready or labeled
#
# status, normalize and advance print one JSON object and exit 0 (2 on error).
# watch prints a line whenever something changes, then one last
# `EVENT=<name>` line, and exits:
#   0  a decision is needed — holder: MERGED CLOSED LABEL_REMOVED CONTENTION
#      CI_FAILED NO_FIX STUCK_AFTER_GREEN SUITE_NOT_RUN; idle: READY LABELED
#   10 HEARTBEAT — nothing needs a decision yet; re-arm
#   2  usage error
#
# The queue is every open PR linked (type pr) from an active or inReview Crow
# work session, plus any a queue file adds, in repos that follow the CI Gate
# convention (ADR 0082, CIGateConvention.swift). Needs jq 1.6+. Reads GitHub
# via `gh` and Crow via `crow`; override with GH_BIN / CROW_BIN (tests do).

set -uo pipefail

GH_BIN="${GH_BIN:-gh}"
CROW_BIN="${CROW_BIN:-crow}"
QUEUE_DIR="${CROW_CI_QUEUE_DIR:-.claude/ci-queues}"
# How long advance waits for update-branch to land and for the new head's own
# run to start, and how often it looks.
UPDATE_TIMEOUT="${QUEUE_UPDATE_TIMEOUT:-90}"
UPDATE_POLL="${QUEUE_UPDATE_POLL:-5}"

REPO=""
PR=""
KEEP=""
ACK=""
DRY_RUN=0
RELABEL=0
INTERVAL=""
TIMEOUT=3000
STUCK_AFTER=900
NO_FIX_AFTER=2700
SKIP_GRACE=120

die() { # die <step> <message>
  jq -cn --arg step "$1" --arg msg "$2" '{status:"error", step:$step, message:$msg}'
  exit 2
}

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# True when the jq program prints exactly `true`. Use this instead of
# `jq -e`: jq 1.6's `-e` exits 0 on empty or blank input. Args go to jq as-is.
jq_true() {
  [[ "$(jq -r "$@" 2>/dev/null)" == "true" ]]
}

# The filters are written for jq 1.6: no keyword-named object keys (a bare
# `label` — GraphQL aliases it to `lbl` instead), and every `if` has an
# `else`. Older jq lacks IN, so refuse it rather than mis-read a queue.
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

now_epoch() { if [[ -n "${QUEUE_NOW:-}" ]]; then echo "$QUEUE_NOW"; else date -u +%s; fi; }
log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|--pr|--keep|--ack-failure|--interval|--timeout|--stuck-after|--no-fix-after|--skip-grace|--queue-dir)
        [[ $# -ge 2 ]] || die "parse_args" "$1 needs a value"
        case "$1" in
          --repo)         REPO=$(tr '[:upper:]' '[:lower:]' <<< "$2") ;;
          --pr)           PR="$2" ;;
          --keep)         KEEP="$2" ;;
          --ack-failure)  ACK="$2" ;;
          --interval)     INTERVAL="$2" ;;
          --timeout)      TIMEOUT="$2" ;;
          --stuck-after)  STUCK_AFTER="$2" ;;
          --no-fix-after) NO_FIX_AFTER="$2" ;;
          --skip-grace)   SKIP_GRACE="$2" ;;
          --queue-dir)    QUEUE_DIR="$2" ;;
        esac
        shift 2 ;;
      --dry-run) DRY_RUN=1; shift ;;
      --relabel) RELABEL=1; shift ;;
      --help|-h) usage ;;
      *) die "parse_args" "unknown argument: $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "preflight" "jq is required"
  require_jq_16
  if [[ -n "$REPO" && ! "$REPO" =~ ^[a-z0-9_.-]+/[a-z0-9_.-]+$ ]]; then
    die "parse_args" "--repo must be owner/name (got $REPO)"
  fi
  local name value
  for name in PR KEEP INTERVAL TIMEOUT STUCK_AFTER NO_FIX_AFTER SKIP_GRACE; do
    value="${!name}"
    [[ -z "$value" ]] || is_uint "$value" || die "parse_args" "--$(tr 'A-Z_' 'a-z-' <<< "$name") must be a whole number (got $value)"
  done
  [[ -z "$ACK" || "$ACK" =~ ^[0-9A-Za-z]+$ ]] || die "parse_args" "--ack-failure must be a commit SHA (got $ACK)"
  return 0
}

# ─── reading GitHub ──────────────────────────────────────────────────────────

# One PR and its head commit's check suites. `lbl:` aliases `label`, which is
# a jq keyword (see require_jq_16).
# shellcheck disable=SC2016  # GraphQL variables, not shell expansion
PR_QUERY='query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number url title state isDraft createdAt mergedAt
      author { login }
      baseRefName headRefName headRefOid reviewDecision mergeable mergeStateStatus
      labels(first: 50) { nodes { name } }
      timelineItems(last: 50, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
        nodes {
          __typename
          ... on LabeledEvent { createdAt actor { login } lbl: label { name } }
          ... on UnlabeledEvent { createdAt actor { login } lbl: label { name } }
        }
      }
      commits(last: 1) { nodes { commit {
        statusCheckRollup { contexts(first: 100) { nodes { ... on CheckRun { name } ... on StatusContext { context } } } }
        checkSuites(last: 50) { nodes {
          status conclusion createdAt updatedAt
          workflowRun { url workflow { name } }
          checkRuns(first: 50) { nodes { name status conclusion } }
        } }
      } } }
    }
  }
}'

# Shared jq definitions. "CI Gate" and "ci:full" mirror CIGateConvention's
# checkName and fullSuiteLabel; `bad` is its terminalNonSuccessConclusions.
# shellcheck disable=SC2016  # jq program: the $names are jq variables
QUEUE_DEFS='
def lc: (. // "") | ascii_downcase;
def bad: ["FAILURE", "TIMED_OUT", "CANCELLED", "STARTUP_FAILURE", "ACTION_REQUIRED", "STALE"];
# CIGateConvention: a repo follows the convention when one of its PRs has a
# check named exactly "CI Gate" or carries ci:full. No repo names.
def convention($entries): any($entries[]; .facts != null and (.facts.has_gate or .facts.full_label));
def convention_repos: [.[] | select(.kind == "pr")] | group_by(.repo) | map(select(convention(.)) | .[0].repo);
# A PR linked from a session belongs to it only when its head branch is the
# session branch, so a PR of a teammate that a coder linked is left alone.
# Unknown on either side (an older crowd, an unreadable PR) counts as own:
# an unreadable PR must still block normalize and advance.
def own: .added or .session == null or (.session.branch // null) == null or .facts == null
         or .facts.head_ref == .session.branch;
'

# Raw GraphQL PR → the facts everything else reads.
#
# run.state — only for a PR that carries ci:full, and only from suites of the
# gated workflow (one whose suite on this head has a "CI Gate" check) created
# at or after the latest time ci:full was added. The suite that the unlabeled
# push or update-branch started fails CI Gate closed on the same SHA, often
# seconds before the label; counting it would report a failure the suite
# never had.
#   pending   labeled, no gated suite yet (a fresh in-flight suite has no
#             CI Gate check until its workers finish, so it reads as pending)
#   running   the newest such suite is not done
#   success   it passed
#   failure   a job other than CI Gate ended in a terminal non-success
#             conclusion — the only kind of red CIGateConvention treats as real
#   skipped   it ended red with only CI Gate red: the suite did not run on
#             this head (a push event raced the label)
# shellcheck disable=SC2016
FACTS_JQ='
.data.repository.pullRequest as $p
| ($p.commits.nodes[0].commit // {}) as $c
| ([$p.labels.nodes[]?.name]) as $labels
| (any($labels[]; lc == "ci:full")) as $full
| ([$p.timelineItems.nodes[]? | select(.__typename == "LabeledEvent" and ((.lbl.name | lc) == "ci:full"))] | last) as $on
| ([$p.timelineItems.nodes[]? | select(.__typename == "UnlabeledEvent" and ((.lbl.name | lc) == "ci:full"))] | last) as $off
| ([$c.checkSuites.nodes[]? | select(.workflowRun != null)]) as $suites
| ([$suites[] | select(any(.checkRuns.nodes[]?; .name == "CI Gate")) | .workflowRun.workflow.name] | unique) as $gated
| ((any($c.statusCheckRollup.contexts.nodes[]?; (.name // .context) == "CI Gate")) or (($gated | length) > 0)) as $has_gate
| ({state: "pending", url: null, workflow: null, created_at: null, completed_at: null, failed_checks: []}) as $pending
| (if ($full | not) then null
   elif $on == null then $pending
   else
     ([$suites[] | select(.createdAt >= $on.createdAt)
       | select(.workflowRun.workflow.name as $w | any($gated[]; . == $w))]
      | sort_by(.createdAt) | last) as $s
     | if $s == null then $pending
       else {
         state: (if $s.status != "COMPLETED" then "running"
                 elif $s.conclusion == "SUCCESS" then "success"
                 elif any($s.checkRuns.nodes[]?; .name != "CI Gate" and ((.conclusion // "") | IN(bad[]))) then "failure"
                 else "skipped" end),
         url: $s.workflowRun.url,
         workflow: $s.workflowRun.workflow.name,
         created_at: $s.createdAt,
         completed_at: (if $s.status == "COMPLETED" then $s.updatedAt else null end),
         failed_checks: [$s.checkRuns.nodes[]? | select(.name != "CI Gate" and ((.conclusion // "") | IN(bad[]))) | .name]
       } end
   end) as $run
| {
    number: $p.number, url: $p.url, title: $p.title, state: $p.state,
    draft: ($p.isDraft // false), created_at: $p.createdAt, merged_at: ($p.mergedAt // null),
    author: ($p.author.login // null), base: $p.baseRefName, head: $p.headRefOid, head_ref: $p.headRefName,
    review: $p.reviewDecision, mergeable: $p.mergeable, merge_state: $p.mergeStateStatus,
    labels: $labels,
    full_label: $full,
    full_label_name: ([$labels[] | select(lc == "ci:full")] | .[0]),
    merge_label: (any($labels[]; lc == "crow:merge")),
    labeled_at: ($on.createdAt // null), labeled_by: ($on.actor.login // null),
    unlabeled_at: ($off.createdAt // null), unlabeled_by: ($off.actor.login // null),
    has_gate: $has_gate,
    head_runs: ($suites | length),
    head_workflows: ([$suites[].workflowRun.workflow.name] | unique),
    gated_workflows: $gated,
    run: $run,
    reasons: [
      (if $p.state != "OPEN" then ($p.state | ascii_downcase) else empty end),
      (if ($p.isDraft // false) then "draft" else empty end),
      (if $p.reviewDecision == "APPROVED" then empty
       elif $p.reviewDecision == "CHANGES_REQUESTED" then "changes requested"
       elif $p.reviewDecision == "REVIEW_REQUIRED" then "not approved yet"
       else "review decision is \($p.reviewDecision // "none")" end),
      (if any($labels[]; lc == "crow:merge") then empty else "no crow:merge" end),
      (if $p.mergeable == "CONFLICTING" then "merge conflict" else empty end)
    ]
  }
| .ready = ((.reasons | length) == 0)
'

fetch_pr() { # fetch_pr <owner/name> <number> → facts (exit 0), or {"error": …} (exit 1)
  local repo="$1" n="$2" resp out=''
  if resp=$("$GH_BIN" api graphql -f query="$PR_QUERY" \
       -F owner="${repo%%/*}" -F name="${repo#*/}" -F number="$n" 2>&1) \
     && jq_true '.data.repository.pullRequest != null' <<< "$resp" \
     && out=$(jq -c "$QUEUE_DEFS $FACTS_JQ" <<< "$resp" 2>&1) \
     && jq_true '.number != null' <<< "$out"; then
    printf '%s\n' "$out"
    return 0
  fi
  jq -cn --arg e "$(head -c 300 <<< "${out:-$resp}")" --arg pr "$repo#$n" '{error: "could not read \($pr): \($e)"}'
  return 1
}

labeled_open() { # labeled_open <owner/name> → JSON array of the open PRs carrying ci:full, or fail
  local out
  out=$("$GH_BIN" pr list -R "$1" --state open --label "ci:full" --limit 100 \
    --json number,title,url,author,headRefName,labels 2>/dev/null) || return 1
  jq_true 'type == "array"' <<< "$out" || return 1
  jq -c 'map({number, title, url, author: (.author.login // null), head_ref: (.headRefName // null),
              merge_label: any(.labels[]?; (.name // "" | ascii_downcase) == "crow:merge")})' <<< "$out"
}

behind_by() { # behind_by <owner/name> <base> <sha> → commits the head is behind its base, or fail
  local out
  out=$("$GH_BIN" api "repos/$1/compare/$2...$3" 2>/dev/null) || return 1
  jq_true '.behind_by | type == "number"' <<< "$out" || return 1
  jq -r '.behind_by' <<< "$out"
}

# ─── reading Crow and the queue files ────────────────────────────────────────

SESSIONS='[]'
CFGS='[]'
LOAD_ERROR=''

# Fail closed: a session list we couldn't read must never look like "no
# session PRs", or a PR already in the queue would read as foreign and keep
# its ci:full next to the holder's.
load_sessions() {
  local out
  if ! out=$("$CROW_BIN" list-sessions 2>&1) || ! jq_true '.sessions | type == "array"' <<< "$out"; then
    LOAD_ERROR="crow list-sessions failed, so which PRs belong to live sessions is unknown: $(head -c 300 <<< "$out")"
    return 1
  fi
  SESSIONS=$(jq -c '.sessions' <<< "$out")
}

# A queue file holds the operator's controls for one repo:
#   {queue-dir}/{owner}-{name}.json = {"repo": "owner/name", "add": [N…], "order": [N…], "hold": [N…]}
load_cfgs() {
  local f
  CFGS='[]'
  [[ -d "$QUEUE_DIR" ]] || return 0
  for f in "$QUEUE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if ! jq_true 'type == "object" and ((.repo | type) == "string") and (.repo | test("^[^/ ]+/[^/ ]+$"))
        and all(.add, .order, .hold; . == null or (type == "array" and all(.[]; type == "number")))' "$f"; then
      LOAD_ERROR="queue file $f must be {\"repo\": \"owner/name\", \"add\": [PR numbers], \"order\": [...], \"hold\": [...]}"
      return 1
    fi
    CFGS=$(jq -c --slurpfile c "$f" --arg file "$f" \
      '. + [$c[0] | {repo: (.repo | ascii_downcase), add: (.add // []), order: (.order // []), hold: (.hold // []), file: $file}]' \
      <<< "$CFGS")
  done
}

# One JSON line per PR link on a live (active / inReview) work session.
# Review sessions are excluded: the PRs they link belong to other people.
session_pr_lines() {
  local sid
  jq -c '.[] | select(.kind == "work" and (.status == "active" or .status == "inReview") and .links != null)
         | {id, name, status, branch} as $s | .links[]? | select(.type == "pr") | {url, session: $s}' <<< "$SESSIONS"
  # A crowd that doesn't inline `links` in list-sessions: ask per session.
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    # shellcheck disable=SC2016  # $s / $id are jq variables
    "$CROW_BIN" list-links --session "$sid" 2>/dev/null \
      | jq -c --argjson s "$(jq -c --arg id "$sid" '.[] | select(.id == $id) | {id, name, status, branch}' <<< "$SESSIONS")" \
          '.links[]? | select(.type == "pr") | {url, session: $s}' 2>/dev/null || true
  done < <(jq -r '.[] | select(.kind == "work" and (.status == "active" or .status == "inReview") and .links == null) | .id' <<< "$SESSIONS")
}

# Every PR the queue tracks, once each: {url, repo, number, session, added}.
# repo is lowercased; a URL that isn't a github.com PR has repo null.
tracked_prs() {
  {
    session_pr_lines
    jq -c '.[] | .repo as $r | .add[] | {url: "https://github.com/\($r)/pull/\(.)", session: null, added: true}' <<< "$CFGS"
  } | jq -c -s '
    group_by(.url // "" | ascii_downcase) | .[]
    | {url: .[0].url, session: ([.[].session | select(. != null)] | .[0]), added: any(.[]; .added == true)}
    | ((.url // "") | capture("^https://github\\.com/(?<o>[^/]+)/(?<n>[^/]+)/pull/(?<num>[0-9]+)") // null) as $m
    | . + (if $m == null then {repo: null, number: null}
           else {repo: ("\($m.o)/\($m.n)" | ascii_downcase), number: ($m.num | tonumber)} end)'
}

# The PRs tracked in one repo, without reading GitHub: [{number, branch, added}],
# where branch is the linking session's branch (null when unknown).
queued_prs() { # queued_prs <owner/name>
  load_sessions || return 1
  load_cfgs || return 1
  # shellcheck disable=SC2016
  tracked_prs | jq -c -s --arg r "$1" \
    '[.[] | select(.repo == $r) | {number, branch: (.session.branch // null), added}] | unique_by(.number)'
}

# ─── status ──────────────────────────────────────────────────────────────────

# Entries (one per tracked PR, with its facts) → {status, repos, ignored}.
#
# Only PRs that carry crow:merge are queued: they merge on their own once
# green, so the queue can advance past them. One without it is merged by hand
# (a human-gate cascade, an operator's call). It goes in manual_merge and is
# never stripped or labeled, or the queue would cancel a suite it can never
# restart.
#
# Holder: the open, ready PR carrying ci:full whose suite is furthest along —
# passed (and not behind, so it is merging) > running / pending > failed (the
# failure policy keeps a failed holder) > skipped; ties go to whoever was
# labeled first. Every other queued PR carrying ci:full is in to_strip.
# Queue: everything else that's open, the queue file's `order` first, then
# oldest first. next is the first ready one.
# shellcheck disable=SC2016
STATUS_JQ='
def rank:
  if .run.state == "success" and .merge_state != "BEHIND" then 0
  elif .run.state == "failure" then 2
  elif .run.state == "skipped" then 3
  else 1 end;
def holder_reason:
  if .run.state == "success" and .merge_state != "BEHIND" then "its labeled run passed; it is merging"
  elif .run.state == "success" then "its labeled run passed, but it is behind its base and will run again"
  elif .run.state == "running" then "its labeled run is in progress"
  elif .run.state == "pending" then "labeled; its run has not reported yet"
  elif .run.state == "failure" then "its labeled run failed; the queue holds until a fix lands"
  else "labeled, but the suite did not run on its head" end;
def build($repo; $entries; $cfg; $labeled):
  ($cfg.hold // []) as $hold
  | ($cfg.order // []) as $order
  | [$entries[] | select(.facts != null)
     | .facts + {session, added}
     | (.number as $n | any($hold[]; . == $n)) as $held
     | .held = $held
     | if $held then .ready = false | .reasons += ["held by the operator"] else . end] as $prs
  | [$prs[] | select(.state == "OPEN" and .merge_label)] as $open
  | [$prs[] | select(.state == "OPEN" and (.merge_label | not))] as $manual
  | ([$open[] | select(.full_label and .ready)] | sort_by([rank, (.labeled_at // "")]) | .[0]) as $holder
  | ($holder.number // null) as $hn
  | ([$open[] | select(.number != $hn) | . + {pos: (.number as $n | ($order | index($n)) // 1000000)}]
     | sort_by([.pos, .created_at, .number]) | map(del(.pos))) as $queue
  | {
      repo: $repo,
      queue_file: ($cfg.file // null),
      holder: (if $holder == null then null else $holder + {reason: ($holder | holder_reason)} end),
      next: ([$queue[] | select(.ready)] | .[0].number // null),
      queue: $queue,
      to_strip: [$queue[] | select(.full_label) | .number],
      held: [$prs[] | select(.held) | .number],
      manual_merge: [$manual[] | {number, title, url, full_label, run_state: (.run.state // null), reasons, session}],
      done: [$prs[] | select(.state != "OPEN") | {number, state}],
      # Open PRs with ci:full that no live session (or queue file) owns:
      # Dependabot, teammates. Reported, never touched. null = unreadable.
      foreign_labeled: (if $labeled == null then null
                        else [$labeled[] | select(.number as $n | any($entries[]; .number == $n) | not)] end),
      unreadable: [$entries[] | select(.facts == null) | {number, url, error}]
    };

. as $all
| [$all[] | select(.kind == "pr" and (own | not))] as $not_own
| ([$all[] | select(.kind == "pr" and own)] | group_by(.repo)) as $groups
| {
    status: "ok",
    repos: [$groups[] | select(convention(.)) | .[0].repo as $r
            | build($r; .; ([$cfgs[] | select(.repo == $r)] | .[0] // {}); $labeled[$r])],
    ignored: ([$all[] | select(.kind == "ignored") | {url, reason}]
              + [$not_own[] | {url, reason: "linked from session \(.session.name), but its head branch \(.facts.head_ref) is not the session branch \(.session.branch), so it is not a PR of that session"}]
              + [$groups[] | select(convention(.) | not) | .[]
                 | {url, reason: (.error // "\(.repo) does not follow the CI Gate convention: none of its PRs has a CI Gate check or ci:full")}])
  }
'

STATUS=''

# Builds the status for every repo (or only `filter`) into STATUS. Returns 1
# with LOAD_ERROR set; never prints, so a caller in the main shell can die.
collect() { # collect <owner/name or empty>
  local filter="$1" tracked entries line repo number facts err repos r lab labeled='{}'
  load_sessions || return 1
  load_cfgs || return 1
  # A tracked list we couldn't build must not read as "nothing queued".
  tracked=$(tracked_prs) || { LOAD_ERROR="could not list the PRs linked from live sessions"; return 1; }
  entries=$(mktemp "${TMPDIR:-/tmp}/crow-ci-queue.XXXXXX")
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    repo=$(jq -r '.repo // empty' <<< "$line")
    if [[ -z "$repo" ]]; then
      [[ -n "$filter" ]] || jq -c '{kind: "ignored", url, reason: "not a github.com pull request URL"}' <<< "$line" >> "$entries"
      continue
    fi
    [[ -z "$filter" || "$repo" == "$filter" ]] || continue
    number=$(jq -r '.number' <<< "$line")
    if facts=$(fetch_pr "$repo" "$number"); then
      err=null
    else
      err=$(jq -c '.error' <<< "$facts"); facts=null
    fi
    jq -c --argjson facts "$facts" --argjson error "$err" '. + {kind: "pr", facts: $facts, error: $error}' <<< "$line" >> "$entries"
  done <<< "$tracked"

  repos=$(jq -r -s "$QUEUE_DEFS"' convention_repos[]' "$entries" 2>/dev/null)
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    lab=$(labeled_open "$r") || lab=null
    # shellcheck disable=SC2016
    labeled=$(jq -c --arg r "$r" --argjson l "$lab" '. + {($r): $l}' <<< "$labeled")
  done <<< "$repos"

  STATUS=$(jq -c -s --argjson cfgs "$CFGS" --argjson labeled "$labeled" "$QUEUE_DEFS $STATUS_JQ" "$entries" 2>&1)
  rm -f "$entries"
  if ! jq_true '.status == "ok"' <<< "$STATUS"; then
    LOAD_ERROR="status filter failed: $(head -c 300 <<< "$STATUS")"
    return 1
  fi
}

RS=''

# Sets RS to REPO's queue object from STATUS, or `null` when nothing is
# queued there. Dies when the repo's PRs are tracked but it isn't queueable —
# so call it directly, never inside `$(…)`, where die only leaves the subshell.
load_repo_object() {
  local reason
  # shellcheck disable=SC2016
  RS=$(jq -c --arg r "$REPO" '[.repos[] | select(.repo == $r)] | .[0]' <<< "$STATUS")
  if [[ "$RS" == "null" ]]; then
    # shellcheck disable=SC2016
    reason=$(jq -r --arg r "$REPO" \
      '[.ignored[] | select(.url | ascii_downcase | contains("github.com/" + $r + "/pull/")) | .reason] | .[0] // empty' <<< "$STATUS")
    [[ -z "$reason" ]] || die "status" "$REPO has no queue: $reason"
  fi
}

# Normalize and advance act on what they read; a queued PR they can't read
# might be the one running the suite. Retry rather than guess.
require_readable() { # require_readable <step> <repo-object>
  local bad
  bad=$(jq -r '.unreadable | map("#\(.number)") | join(", ")' <<< "$2")
  [[ -z "$bad" ]] || die "$1" "could not read $bad in $REPO, so which PR holds ci:full is unknown — retry: $(jq -r '.unreadable[0].error' <<< "$2")"
}

require_queued() { # require_queued <step> <pr> <repo-object>
  # shellcheck disable=SC2016
  jq_true --argjson n "$2" '[.holder // empty, .queue[]] | any(.[]; .number == $n)' <<< "$3" && return 0
  # shellcheck disable=SC2016
  if jq_true --argjson n "$2" 'any(.manual_merge[]; .number == $n)' <<< "$3"; then
    die "$1" "#$2 has no crow:merge, so it merges by hand and stays outside the queue — add crow:merge to queue it"
  fi
  die "$1" "#$2 is not an open PR in the $REPO queue — link it to a session, or add it to the queue file"
}

cmd_status() {
  collect "$REPO" || die "status" "$LOAD_ERROR"
  printf '%s\n' "$STATUS"
}

# ─── normalize ───────────────────────────────────────────────────────────────

cmd_normalize() {
  [[ -n "$REPO" ]] || die "parse_args" "normalize needs --repo owner/name"
  collect "$REPO" || die "status" "$LOAD_ERROR"
  local rs holder strip n item name stripped='[]' failed='[]'
  load_repo_object; rs="$RS"
  if [[ "$rs" == "null" ]]; then
    jq -cn --arg r "$REPO" --argjson d "$DRY_RUN" \
      '{status: "ok", repo: $r, dry_run: ($d == 1), holder: null, stripped: [], strip_failed: [], next: null, queue: [], manual_merge: []}'
    return
  fi
  require_readable "normalize" "$rs"

  # shellcheck disable=SC2016
  if [[ -n "$KEEP" ]]; then
    require_queued "normalize" "$KEEP" "$rs"
    holder=$(jq -c --argjson k "$KEEP" \
      '[.holder // empty, .queue[]] | map(select(.number == $k)) | .[0] | {number, run_state: .run.state, reason: "kept with --keep"}' <<< "$rs")
    strip=$(jq -r --argjson k "$KEEP" '[.holder // empty, .queue[]] | .[] | select(.full_label and .number != $k) | .number' <<< "$rs")
  else
    holder=$(jq -c '.holder | if . == null then null else {number, run_state: .run.state, reason} end' <<< "$rs")
    strip=$(jq -r '.to_strip[]' <<< "$rs")
  fi

  for n in $strip; do
    # shellcheck disable=SC2016
    item=$(jq -c --argjson n "$n" \
      '[.holder // empty, .queue[]] | map(select(.number == $n)) | .[0] | {number, run_state: .run.state, labeled_by, labeled_at, ready, reasons}' <<< "$rs")
    name=$(jq -r --argjson n "$n" '[.holder // empty, .queue[]] | map(select(.number == $n)) | .[0].full_label_name' <<< "$rs")
    # Removing the label cancels the PR's in-flight suite (test.yml runs with
    # cancel-in-progress on the ref), which frees its runners at once.
    if (( DRY_RUN )) || "$GH_BIN" pr edit "$n" -R "$REPO" --remove-label "$name" >/dev/null 2>&1; then
      stripped=$(jq -c --argjson i "$item" '. + [$i]' <<< "$stripped")
    else
      failed=$(jq -c --argjson i "$item" '. + [$i]' <<< "$failed")
    fi
  done

  # shellcheck disable=SC2016
  jq -c --arg r "$REPO" --argjson d "$DRY_RUN" --argjson h "$holder" --argjson s "$stripped" --argjson f "$failed" '{
      status: "ok", repo: $r, dry_run: ($d == 1), holder: $h, stripped: $s, strip_failed: $f,
      next: (if $h == null then .next else null end),
      queue: [.queue[] | {number, title, ready, reasons, held}],
      manual_merge, foreign_labeled
    }' <<< "$rs"
}

# ─── advance ─────────────────────────────────────────────────────────────────

ATTEMPTS='[]'
attempt() { # attempt <pr> <outcome> <reason>
  # shellcheck disable=SC2016
  ATTEMPTS=$(jq -c --argjson n "$1" --arg o "$2" --arg r "$3" '. + [{pr: $n, outcome: $o, reason: $r}]' <<< "$ATTEMPTS")
}

# Re-read a PR during advance; leaves FACTS unchanged when the read fails.
FACTS=''
refetch() { local f; f=$(fetch_pr "$REPO" "$1") && FACTS="$f"; }

# Label one candidate, or record why not. 0 = labeled (result printed).
try_advance() { # try_advance <pr>
  local n="$1" f sha start_sha base behind out rc deadline b review gated
  if ! f=$(fetch_pr "$REPO" "$n"); then attempt "$n" read_failed "$(jq -r .error <<< "$f")"; return 1; fi
  FACTS="$f"
  if ! jq_true '.ready' <<< "$FACTS"; then attempt "$n" not_ready "$(jq -r '.reasons | join(", ")' <<< "$FACTS")"; return 1; fi
  if (( RELABEL )) && jq_true '.full_label' <<< "$FACTS"; then
    if ! "$GH_BIN" pr edit "$n" -R "$REPO" --remove-label "$(jq -r .full_label_name <<< "$FACTS")" >/dev/null 2>&1; then
      attempt "$n" label_failed "could not remove ci:full to re-run the suite"; return 1
    fi
  fi

  base=$(jq -r .base <<< "$FACTS")
  sha=$(jq -r .head <<< "$FACTS"); start_sha="$sha"
  # The gated workflow, learned before an update moves the head.
  gated=$(jq -c '.gated_workflows' <<< "$FACTS")
  if ! behind=$(behind_by "$REPO" "$base" "$sha"); then
    attempt "$n" update_failed "could not compare ${sha:0:9} with $base"; return 1
  fi

  # Update first: labeling a branch that's behind runs the suite once, then
  # auto-merge sees BEHIND, updates it, and the suite runs again.
  if (( behind > 0 )); then
    out=$("$GH_BIN" pr update-branch "$n" -R "$REPO" 2>&1); rc=$?
    # update-branch can answer "already up-to-date" while compare said behind,
    # and auto-rebase can move the head under us. A fresh head and a fresh
    # compare decide — never the cached SHA, never the command's own answer.
    deadline=$(( $(now_epoch) + UPDATE_TIMEOUT ))
    while :; do
      if refetch "$n"; then
        sha=$(jq -r .head <<< "$FACTS")
        b=$(behind_by "$REPO" "$base" "$sha") || b=''
        [[ "$b" == "0" ]] && break
      fi
      if (( rc != 0 )) && ! grep -qi 'up.to.date' <<< "$out"; then
        attempt "$n" update_failed "gh pr update-branch: $(head -c 200 <<< "$out")"; return 1
      fi
      if (( $(now_epoch) >= deadline )); then
        attempt "$n" update_failed "still behind $base after ${UPDATE_TIMEOUT}s (update-branch said: $(head -c 200 <<< "$out"))"; return 1
      fi
      sleep "$UPDATE_POLL"
    done
    # corveil/corveil keeps approvals across a push (dismiss_stale_reviews_on_push
    # is off), but another repo's ruleset may dismiss them. Check anyway.
    review=$(jq -r '.review // "none"' <<< "$FACTS")
    if [[ "$review" != "APPROVED" ]]; then
      attempt "$n" approval_lost "reviewDecision is $review after the update"; return 1
    fi
    if jq_true '.mergeable == "CONFLICTING"' <<< "$FACTS"; then
      attempt "$n" not_ready "merge conflict after the update"; return 1
    fi
  fi

  # Let the head's own unlabeled run of the gated workflow start before the
  # label goes on. It then predates the label, and watch never counts its
  # fail-closed CI Gate. Another workflow's run says nothing about that one;
  # only when the gated workflow is unknown does any run do.
  deadline=$(( $(now_epoch) + UPDATE_TIMEOUT ))
  # shellcheck disable=SC2016
  while ! jq_true --argjson g "$gated" \
      'if ($g | length) > 0 then any(.head_workflows[]; . as $w | any($g[]; . == $w)) else .head_runs > 0 end' <<< "$FACTS" \
      && (( $(now_epoch) < deadline )); do
    sleep "$UPDATE_POLL"
    refetch "$n" || true
  done
  sha=$(jq -r .head <<< "$FACTS")

  if ! "$GH_BIN" pr edit "$n" -R "$REPO" --add-label "ci:full" >/dev/null 2>&1; then
    attempt "$n" label_failed "gh pr edit --add-label ci:full failed"; return 1
  fi
  # shellcheck disable=SC2016
  jq -cn --arg r "$REPO" --argjson n "$n" --arg sha "$sha" --arg start "$start_sha" --argjson behind "$behind" \
    --argjson relabel "$RELABEL" --argjson attempts "$ATTEMPTS" --argjson f "$FACTS" '{
      status: "ok", repo: $r, result: "labeled", pr: $n, title: $f.title, sha: $sha,
      updated: ($sha != $start), behind_by: $behind, relabeled: ($relabel == 1), attempts: $attempts
    }'
  return 0
}

cmd_advance() {
  [[ -n "$REPO" ]] || die "parse_args" "advance needs --repo owner/name"
  collect "$REPO" || die "status" "$LOAD_ERROR"
  local rs holder strip candidates n
  load_repo_object; rs="$RS"
  if [[ "$rs" == "null" ]]; then
    jq -cn --arg r "$REPO" '{status: "ok", repo: $r, result: "empty", pr: null, attempts: []}'
    return
  fi
  require_readable "advance" "$rs"
  # Reject a --pr the queue can't take before looking at who holds.
  [[ -z "$PR" ]] || require_queued "advance" "$PR" "$rs"

  holder=$(jq -r '.holder.number // empty' <<< "$rs")
  if [[ -n "$holder" && "$PR" != "$holder" ]]; then
    jq -c '{status: "ok", repo, result: "held", pr: null,
            holder: {number: .holder.number, run_state: .holder.run.state, reason: .holder.reason},
            to_strip, attempts: []}' <<< "$rs"
    return
  fi
  if [[ -n "$holder" && "$PR" == "$holder" && "$RELABEL" -eq 0 ]]; then
    die "advance" "#$PR already holds ci:full in $REPO — pass --relabel to re-run its suite"
  fi
  strip=$(jq -r '.to_strip | map("#\(.)") | join(", ")' <<< "$rs")
  [[ -z "$strip" ]] || die "advance" "$strip also carry ci:full in $REPO — run normalize first, so only one suite runs"

  if [[ -n "$PR" ]]; then
    # shellcheck disable=SC2016
    if jq_true --argjson n "$PR" 'any(.held[]; . == $n)' <<< "$rs"; then
      die "advance" "#$PR is held in $(jq -r '.queue_file // "the queue file"' <<< "$rs") — take it off hold first"
    fi
    candidates="$PR"
  else
    candidates=$(jq -r '.queue[] | select(.ready) | .number' <<< "$rs")
  fi

  for n in $candidates; do
    try_advance "$n" && return 0
  done
  # shellcheck disable=SC2016
  jq -c --argjson attempts "$ATTEMPTS" '{
      status: "ok", repo, result: (if (.queue | length) == 0 then "empty" else "none_ready" end), pr: null,
      attempts: $attempts,
      not_ready: [.queue[] | select(.ready | not) | {number, title, reasons}]
    }' <<< "$rs"
}

# ─── watch ───────────────────────────────────────────────────────────────────

# Holder facts → the event that needs a decision (or none) and a status line.
# Times are measured from GitHub's own timestamps, so a re-armed watcher
# picks up where the last one stopped.
# shellcheck disable=SC2016
WATCH_JQ='
def age($t): if $t == null then null else ($now - ($t | fromdateiso8601)) end;
def mins($s): "\((($s // 0) / 60) | floor)m";
def short: (. // "") | .[0:9];
. as $f
| (age($f.run.completed_at // null) // 0) as $since_done
# Contention: another labeled PR that is queued — tracked, on the branch of
# its session (see `own`), and carrying crow:merge. Others are only reported.
| def tracked: . as $l | any(($queued // [])[]; .number == $l.number);
  def owned: . as $l | any(($queued // [])[]; .number == $l.number and (.added or .branch == null or .branch == $l.head_ref));
  [($labeled // [])[] | select(.number != $f.number)] as $other_labeled
| (if $queued == null or $labeled == null then null
   else [$other_labeled[] | select(owned and .merge_label) | .number] end) as $others
| (if $labeled == null then null
   else [$other_labeled[] | select((owned and .merge_label) | not)
         | "#\(.number) (" + (if owned then "no crow:merge, merged by hand"
                              elif tracked then "not on the branch of its session"
                              else (.author // "not a Crow session PR") end) + ")"] end) as $foreign
| ("pr=\($f.number) sha=\($f.head | short) mss=\($f.merge_state // "?") suite=\($f.run.state // "none")"
   + (if ($f.run.workflow // null) != null then " (\($f.run.workflow))" else "" end)
   + (if $f.labeled_at != null then " labeled \(mins(age($f.labeled_at))) ago" else "" end)
   + (if $ack != "" and $ack == $f.head then " · failure on \($ack | short) reported, waiting for a fix" else "" end)
   + (if $queued == null then " · contention unchecked (crow unreachable)"
      elif $labeled == null then " · contention unchecked (gh pr list failed)" else "" end)) as $line
| (if $f.state == "MERGED" then
     {event: "MERGED", detail: ("pr=\($f.number)"
       + (if $f.labeled_at != null and $f.merged_at != null
          then " took=\(mins(($f.merged_at | fromdateiso8601) - ($f.labeled_at | fromdateiso8601)))" else "" end))}
   elif $f.state == "CLOSED" then {event: "CLOSED", detail: "pr=\($f.number)"}
   elif ($f.full_label | not) then
     {event: "LABEL_REMOVED", detail: "pr=\($f.number) by=\($f.unlabeled_by // "?") at=\($f.unlabeled_at // "?")"}
   elif (($others // []) | length) > 0 then
     {event: "CONTENTION", detail: "pr=\($f.number) others=\($others | map(tostring) | join(","))"}
   elif $f.run.state == "failure" and $ack != $f.head then
     {event: "CI_FAILED", detail: "pr=\($f.number) sha=\($f.head) run=\($f.run.url) failed=\($f.run.failed_checks | join(","))"}
   elif $f.run.state == "failure" and $since_done >= $nofix then
     {event: "NO_FIX", detail: "pr=\($f.number) sha=\($f.head) failed_for=\(mins($since_done)) run=\($f.run.url)"}
   elif $f.run.state == "success" and $since_done >= $stuck then
     {event: "STUCK_AFTER_GREEN", detail: "pr=\($f.number) mss=\($f.merge_state // "?") green_for=\(mins($since_done)) run=\($f.run.url)"}
   elif $f.run.state == "skipped" and $since_done >= $grace then
     {event: "SUITE_NOT_RUN", detail: "pr=\($f.number) sha=\($f.head) run=\($f.run.url)"}
   else {event: null, detail: null} end)
| . + {line: $line, foreign: (($foreign // []) | join(", "))}
'

# Repo queue object (or null) → READY / LABELED, or a status line.
# shellcheck disable=SC2016
IDLE_JQ='
if . == null then {event: null, line: "idle · nothing queued"}
else
  ([(.holder // empty | .number), .to_strip[]] | unique) as $lab
  | ("idle · \(.queue | length) queued, none ready"
     + (if (.queue | length) > 0 then ": " + (.queue | map("#\(.number) (\(.reasons | join(", ")))") | join("; ")) else "" end)
     + (if (.manual_merge | length) > 0 then " · merged by hand, not queued: " + (.manual_merge | map("#\(.number)") | join(", ")) else "" end)
     + (if (.unreadable | length) > 0 then " · unreadable: " + (.unreadable | map("#\(.number)") | join(", ")) else "" end)) as $line
  | if ($lab | length) > 0 then {event: "LABELED", detail: "prs=\($lab | map(tostring) | join(","))", line: $line}
    elif .next != null then {event: "READY", detail: "pr=\(.next)", line: $line}
    else {event: null, line: $line} end
end
'

watch_holder() {
  local started now facts queued labeled decision event line prev_line='' foreign prev_foreign=''
  started=$(now_epoch)
  log "watching #$PR in $REPO every ${INTERVAL}s (heartbeat after ${TIMEOUT}s)${ACK:+; the failure on ${ACK:0:9} is already reported}"
  while :; do
    now=$(now_epoch)
    if facts=$(fetch_pr "$REPO" "$PR"); then
      queued=$(queued_prs "$REPO" 2>/dev/null) || queued=null
      labeled=$(labeled_open "$REPO") || labeled=null
      # shellcheck disable=SC2016
      if decision=$(jq -c --argjson now "$now" --arg ack "$ACK" --argjson queued "$queued" --argjson labeled "$labeled" \
          --argjson stuck "$STUCK_AFTER" --argjson nofix "$NO_FIX_AFTER" --argjson grace "$SKIP_GRACE" \
          "$WATCH_JQ" <<< "$facts" 2>&1) && jq_true 'has("line")' <<< "$decision"; then
        line=$(jq -r .line <<< "$decision")
        foreign=$(jq -r .foreign <<< "$decision")
        event=$(jq -r '.event // empty' <<< "$decision")
      else
        # A filter this jq can't run must never produce an event.
        line="watch filter failed: $(head -c 200 <<< "$decision")"; foreign=''; event=''
      fi
    else
      line=$(jq -r .error <<< "$facts"); foreign=''; event=''
    fi
    [[ "$line" == "$prev_line" ]] || log "$line"
    prev_line="$line"
    if [[ -n "$foreign" && "$foreign" != "$prev_foreign" ]]; then
      log "also carry ci:full, outside the queue, not touched: $foreign"
    fi
    prev_foreign="$foreign"
    if [[ -n "$event" ]]; then
      log "EVENT=$event repo=$REPO $(jq -r .detail <<< "$decision")"
      exit 0
    fi
    if (( now - started >= TIMEOUT )); then
      log "EVENT=HEARTBEAT repo=$REPO pr=$PR · $line${ACK:+ · ack=$ACK}"
      exit 10
    fi
    sleep "$INTERVAL"
  done
}

watch_idle() {
  local started now decision event line prev_line='' rs
  started=$(now_epoch)
  log "watching the $REPO queue (no holder) every ${INTERVAL}s (heartbeat after ${TIMEOUT}s)"
  while :; do
    now=$(now_epoch)
    event=''
    if collect "$REPO" && rs=$(jq -c --arg r "$REPO" '[.repos[] | select(.repo == $r)] | .[0]' <<< "$STATUS") \
       && decision=$(jq -c "$IDLE_JQ" <<< "$rs" 2>&1) && jq_true 'has("line")' <<< "$decision"; then
      line=$(jq -r .line <<< "$decision")
      event=$(jq -r '.event // empty' <<< "$decision")
    else
      line="status unavailable: ${LOAD_ERROR:-$(head -c 200 <<< "${decision:-}")}"
    fi
    [[ "$line" == "$prev_line" ]] || log "$line"
    prev_line="$line"
    if [[ -n "$event" ]]; then
      log "EVENT=$event repo=$REPO $(jq -r .detail <<< "$decision")"
      exit 0
    fi
    if (( now - started >= TIMEOUT )); then
      log "EVENT=HEARTBEAT repo=$REPO · $line"
      exit 10
    fi
    sleep "$INTERVAL"
  done
}

cmd_watch() {
  [[ -n "$REPO" ]] || die "parse_args" "watch needs --repo owner/name"
  if [[ -n "$PR" ]]; then
    INTERVAL="${INTERVAL:-60}"
    watch_holder
  else
    [[ -z "$ACK" ]] || die "parse_args" "--ack-failure needs --pr"
    INTERVAL="${INTERVAL:-120}"
    watch_idle
  fi
}

# ─── main ────────────────────────────────────────────────────────────────────

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    status)    parse_args "$@"; cmd_status ;;
    normalize) parse_args "$@"; cmd_normalize ;;
    advance)   parse_args "$@"; cmd_advance ;;
    watch)     parse_args "$@"; cmd_watch ;;
    ""|--help|-h|help) usage ;;
    *) die "parse_args" "unknown subcommand: $cmd (expected status | normalize | advance | watch)" ;;
  esac
}

# Only run when executed directly — sourcing (tests) exposes the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
