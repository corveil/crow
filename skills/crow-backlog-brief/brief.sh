#!/usr/bin/env bash
# crow-backlog-brief helper (CROW-1367) — the deterministic half of the daily
# backlog brief. The LLM half (studying, writing cards, publishing the page,
# acting on the decisions) lives in SKILL.md.
#
#   config   --config F                               validate config.json, print it with defaults filled in
#   fetch    --config F --out DIR                     open issues, issue history and the sub-issue graph, per repo
#   scope    --config F --backlog DIR [--out F]       epics with their children, freestanding tickets, out of scope
#   prs      --config F --scope F [--merged-since T] [--out F]
#                                                     open PRs (latest check runs, mergeable), in-flight issues, merged PRs
#   stats    --config F --backlog DIR --scope F [--days N] [--now T] [--out F]
#                                                     open-issue burndown and the week's flow
#   compose  --config F --round F --cards F [--stats F] [--prs F]
#            [--prev-brief F --decisions PATH] [--now T] --out F
#                                                     round + cards (+ the previous round's undecided cards) -> brief.json
#   check    --brief F                                validate brief.json, including the card format
#   build    --brief F --out F (--decisions PATH | --first-publish) [--active-minutes N] [--now T]
#                                                     validate, refuse to publish over fresh answers, write the page
#   mark-read --decisions DIR --count N               record a fresh ArtifactData list of N docs in DIR (build needs it)
#   readback --brief F --decisions PATH [--rounds PATH] [--round-hours N] [--idle-minutes N] [--now T]
#                                                     join the decisions to the cards; say whether the round has closed
#   deferred --issue OWNER/NAME#N --repo-path P [--repo-path P ...] [--ref R]
#                                                     DEFERRED(#N) markers still in the code
#   memory   [--min-free PCT]                         free memory, to gate kickoffs
#   corveil  VERB [ARGS...]                           a read-only corveil call with CORVEIL_NO_CAPTURE=1
#
# Exit codes: 0 ok; 1 invalid input (an `errors` list says what); 2 usage or
# environment error; 3 hold (build: the operator wrote in the last
# --active-minutes, so wait and build again; corveil: no CLI, skip the
# ontology); 4 stale (build: no read recorded, the read is too old, or the
# previous round's decisions changed since compose). Every subcommand except corveil
# prints one JSON object. Reads GitHub through `gh` and Crow through `crow`;
# override with GH_BIN / CROW_BIN / CORVEIL_BIN (tests do). Needs jq 1.6+.
#
# --decisions and --rounds take the directory `ArtifactData list` wrote with
# out_dir (<out_dir>/<collection>/<doc_id>.json), or one JSON file: an array of
# docs, an {id: doc} map, or the inline list output (one {id, data, version}
# per line). Viewers wrote those docs, so bad fields are reported, never trusted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_BIN="${GH_BIN:-gh}"
CROW_BIN="${CROW_BIN:-crow}"
CORVEIL_BIN="${CORVEIL_BIN:-corveil}"
# The corveil verbs that only read the ontology. Anything else is refused, so
# the pre-approved `brief.sh corveil` prefix can never write.
CORVEIL_READ_VERBS="search entity entities context evidence event history timeline graph stats whoami health"
# Read verbs that record nothing and take no --no-capture flag.
CORVEIL_UNCAPTURED_VERBS="whoami health"

CONFIG=""; OUT=""; BACKLOG=""; SCOPE=""; ROUND=""; CARDS=""; STATS=""; PRS=""
PREV=""; DECISIONS=""; ROUNDS=""; BRIEF=""; TEMPLATE="$SCRIPT_DIR/page.html"
NOW=""; MERGED_SINCE=""; DAYS=60; ISSUE=""; REF=""; MIN_FREE=""; COUNT=""
ACTIVE_MINUTES=""; IDLE_MINUTES=""; ROUND_HOURS=""; MAX_READ_AGE=600; FIRST_PUBLISH=0
REPO_PATHS=()
CONFIG_JSON=""; CHECK_RESULT=""
TMP_FILES=()

cleanup() { [[ ${#TMP_FILES[@]} -eq 0 ]] || rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT

die() { # die <step> <message>
  jq -cn --arg step "$1" --arg msg "$2" '{status:"error", step:$step, message:$msg}'
  exit 2
}

usage() {
  sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# True when the jq program prints exactly `true`. jq 1.6's `-e` exits 0 on
# empty input, so it can't be trusted for this.
jq_true() {
  [[ "$(jq -r "$@" 2>/dev/null)" == "true" ]]
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
is_iso() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]+)?)?Z$ ]]; }
now_iso() { if [[ -n "$NOW" ]]; then echo "$NOW"; else date -u +%Y-%m-%dT%H:%M:%SZ; fi; }
repo_dir() { echo "${1%%/*}__${1#*/}"; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

tmpfile() { # tmpfile <var> — a temp file removed on exit (locals are prefixed so they never shadow <var>)
  local __tmp_path
  __tmp_path=$(mktemp "${TMPDIR:-/tmp}/crow-brief.XXXXXX") || die "preflight" "cannot create a temp file"
  TMP_FILES+=("$__tmp_path")
  printf -v "$1" '%s' "$__tmp_path"
}

write_atomic() { # write_atomic <path> <content>
  local dir tmp
  dir=$(dirname "$1")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.brief.XXXXXX") || return 1
  if printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# The filters are written for jq 1.6: every `if` has an `else`, no keyword
# (`label`, `if`, `end`, …) is used as a bare object key or field, and maps are
# built with `obj` because 1.6's from_entries mishandles false values.
require_jq_16() {
  command -v jq >/dev/null 2>&1 || { echo '{"status":"error","step":"preflight","message":"jq is required"}'; exit 2; }
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
      --config|--out|--backlog|--scope|--round|--cards|--stats|--prs|--prev-brief|--decisions|--rounds|--brief|--template|--now|--merged-since|--days|--issue|--ref|--repo-path|--min-free|--active-minutes|--idle-minutes|--round-hours|--max-read-age|--count)
        [[ $# -ge 2 ]] || die "parse_args" "$1 needs a value"
        case "$1" in
          --config)         CONFIG="$2" ;;
          --out)            OUT="$2" ;;
          --backlog)        BACKLOG="$2" ;;
          --scope)          SCOPE="$2" ;;
          --round)          ROUND="$2" ;;
          --cards)          CARDS="$2" ;;
          --stats)          STATS="$2" ;;
          --prs)            PRS="$2" ;;
          --prev-brief)     PREV="$2" ;;
          --decisions)      DECISIONS="$2" ;;
          --rounds)         ROUNDS="$2" ;;
          --brief)          BRIEF="$2" ;;
          --template)       TEMPLATE="$2" ;;
          --now)            NOW="$2" ;;
          --merged-since)   MERGED_SINCE="$2" ;;
          --days)           DAYS="$2" ;;
          --issue)          ISSUE="$2" ;;
          --ref)            REF="$2" ;;
          --repo-path)      REPO_PATHS+=("$2") ;;
          --min-free)       MIN_FREE="$2" ;;
          --active-minutes) ACTIVE_MINUTES="$2" ;;
          --idle-minutes)   IDLE_MINUTES="$2" ;;
          --round-hours)    ROUND_HOURS="$2" ;;
          --max-read-age)   MAX_READ_AGE="$2" ;;
          --count)          COUNT="$2" ;;
        esac
        shift 2 ;;
      --first-publish) FIRST_PUBLISH=1; shift ;;
      --help|-h) usage ;;
      *) die "parse_args" "unknown argument: $1" ;;
    esac
  done
  require_jq_16
  local name value
  for name in DAYS MIN_FREE ACTIVE_MINUTES IDLE_MINUTES ROUND_HOURS MAX_READ_AGE; do
    value="${!name}"
    [[ -z "$value" ]] || is_uint "$value" || die "parse_args" "--$(tr 'A-Z_' 'a-z-' <<< "$name") must be a whole number (got $value)"
  done
  [[ -z "$NOW" ]] || is_iso "$NOW" || die "parse_args" "--now must be an ISO 8601 UTC time such as 2026-10-26T08:00:00Z (got $NOW)"
  if [[ -n "$MERGED_SINCE" ]] && ! is_iso "$MERGED_SINCE" && [[ ! "$MERGED_SINCE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    die "parse_args" "--merged-since must be a date or an ISO 8601 UTC time (got $MERGED_SINCE)"
  fi
  return 0
}

require_file() { # require_file <flag> <path>
  [[ -n "$2" ]] || die "parse_args" "$1 is required"
  [[ -f "$2" ]] || die "parse_args" "$1 file not found: $2"
  jq empty "$2" 2>/dev/null || die "parse_args" "$1 is not valid JSON: $2"
}

# ─── shared jq ───────────────────────────────────────────────────────────────

# shellcheck disable=SC2016  # $vars below are jq's, not the shell's
JQ_LIB='
def nonempty: type == "string" and (gsub("\\s"; "") | length) > 0;
def member($xs): . as $v | $xs | map(. == $v) | any;
def obj: reduce .[] as $e ({}; .[$e.key] = $e.value);
def is_url: type == "string" and test("^https?://[^[:space:]]+$");
# Seconds since 1970 for a UTC time (YYYY-MM-DDTHH:MM[:SS[.fff]]Z), or null.
# Computed here, not with fromdateiso8601: jq 1.6 on macOS reads a DST date
# through local time and returns it an hour late (PR #1368 review).
def civil_days($y; $m; $d):
  (if $m <= 2 then $y - 1 else $y end) as $yy
  | ((if $yy >= 0 then $yy else $yy - 399 end) / 400 | floor) as $era
  | ($yy - $era * 400) as $yoe
  | (((153 * (if $m > 2 then $m - 3 else $m + 9 end) + 2) / 5 | floor) + $d - 1) as $doy
  | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy) as $doe
  | $era * 146097 + $doe - 719468;
def epoch:
  if type != "string" then null
  else ([capture("^(?<y>[0-9]{4})-(?<mo>[0-9]{2})-(?<d>[0-9]{2})T(?<h>[0-9]{2}):(?<mi>[0-9]{2})(?::(?<s>[0-9]{2})(?:\\.[0-9]+)?)?Z$")] | .[0]) as $c
    | if $c == null then null
      else ($c.y | tonumber) as $y | ($c.mo | tonumber) as $m | ($c.d | tonumber) as $d
        | ($c.h | tonumber) as $h | ($c.mi | tonumber) as $mi | (($c.s // "0") | tonumber) as $s
        | if $m < 1 or $m > 12 or $d < 1 or $d > 31 or $h > 23 or $mi > 59 or $s > 60 then null
          else civil_days($y; $m; $d) * 86400 + $h * 3600 + $mi * 60 + $s end
      end
  end;
def ID_RE: "^[A-Za-z0-9_.~:@+-]{1,200}$";
def slugify: tostring | ascii_downcase | gsub("[^a-z0-9]+"; "-") | sub("^-+"; "") | sub("-+$"; "");
def signed: if . > 0 then "+\(.)" elif . < 0 then "−\(0 - .)" else "±0" end;
def strfield($k): if (.[$k] // null) == null or (.[$k] | type) == "string" then [] else ["\($k) must be a string"] end;
def strlist($k):
  if (.[$k] // null) == null then []
  elif (.[$k] | type) == "array" and (.[$k] | all(type == "string")) then []
  else ["\($k) must be an array of strings"] end;
# A decision doc may arrive as its bare body or wrapped with metadata ({data, version}).
def body: if type == "object" and (.data | type) == "object" then .data else . end;
def version: if type == "object" and (.version | type) == "number" then .version else null end;
def blank: (type == "string" and (gsub("\\s"; "") | length) > 0) | not;
# Claude writes an interim result as "Pending: …" (waiting for free memory, for
# a marker-cleanup PR to merge). Only a final result takes a card off the to-act
# list (PR #1368 review).
def is_pending: type == "string" and test("^\\s*Pending:");
def is_final: (blank | not) and (is_pending | not);
'

# ─── config ──────────────────────────────────────────────────────────────────

# shellcheck disable=SC2016
CONFIG_FILTER='
def DEFAULTS: {
  title: "Backlog Brief", repos: [], operator: null, release: null, defer_label: null, ontology: "auto",
  cadence: {check_minutes: 60, round_hours: 24, active_minutes: 10, idle_minutes: 60, daily_at: null},
  kickoff: {wave_size: 10, min_free_pct: 20}
};
def uint: type == "number" and . >= 0 and . == floor;
if type != "object" then {errors: ["config must be a JSON object"]}
else
  (DEFAULTS * .) as $e
  | {
      errors: (
        (if ($e.repos | type) == "array" and ($e.repos | length) > 0
            and ($e.repos | all(type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))) then
           [$e.repos | group_by(ascii_downcase)[] | select(length > 1) | "repo \(.[0]) is listed more than once"]
         else ["repos must be a non-empty array of owner/name strings"] end)
        + (if ($e.operator | type) == "string" and ($e.operator | test("^[A-Za-z0-9-]{1,39}$")) then []
           else ["operator must be the operator'"'"'s GitHub login"] end)
        + (if ($e.title | nonempty) then [] else ["title must be a non-empty string"] end)
        + (if $e.release == null then []
           elif ($e.release | type) == "object" and ($e.release.name | nonempty)
                and ((($e.release.date // null) == null) or (($e.release.date | type) == "string" and ($e.release.date | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))) then []
           else ["release must be {name, date: YYYY-MM-DD}"] end)
        + (if $e.defer_label == null or ($e.defer_label | nonempty) then [] else ["defer_label must be a label name"] end)
        + (if ($e.ontology | type) == "string" and ($e.ontology | member(["auto", "off"])) then [] else ["ontology must be auto or off"] end)
        + (if ($e.cadence | type) != "object" then ["cadence must be an object"]
           else
             (if ($e.cadence.check_minutes | uint) and $e.cadence.check_minutes >= 5 then [] else ["cadence.check_minutes must be a whole number of 5 or more"] end)
             + (if ($e.cadence.round_hours | uint) and $e.cadence.round_hours >= 1 then [] else ["cadence.round_hours must be a whole number of 1 or more"] end)
             + (if ($e.cadence.active_minutes | uint) then [] else ["cadence.active_minutes must be a whole number"] end)
             + (if ($e.cadence.idle_minutes | uint) then [] else ["cadence.idle_minutes must be a whole number"] end)
             + (if $e.cadence.daily_at == null or (($e.cadence.daily_at | type) == "string" and ($e.cadence.daily_at | test("^([01][0-9]|2[0-3]):[0-5][0-9]$"))) then []
                else ["cadence.daily_at must be HH:MM (24-hour, local time)"] end)
           end)
        + (if ($e.kickoff | type) != "object" then ["kickoff must be an object"]
           else
             (if ($e.kickoff.wave_size | uint) and $e.kickoff.wave_size >= 1 and $e.kickoff.wave_size <= 25 then [] else ["kickoff.wave_size must be 1 to 25"] end)
             + (if ($e.kickoff.min_free_pct | type) == "number" and $e.kickoff.min_free_pct >= 0 and $e.kickoff.min_free_pct <= 100 then [] else ["kickoff.min_free_pct must be 0 to 100"] end)
           end)
      ),
      config: $e
    }
end
'

load_config() {
  require_file --config "$CONFIG"
  local res
  res=$(jq -c "$JQ_LIB$CONFIG_FILTER" "$CONFIG" 2>&1) || die "config" "config filter failed: $res"
  if [[ "$(jq -r '.errors | length' <<<"$res")" != "0" ]]; then
    jq -c '{status:"error", step:"config", errors}' <<<"$res"
    exit 1
  fi
  CONFIG_JSON=$(jq -c '.config' <<<"$res")
}

cmd_config() {
  load_config
  jq -c '{status:"ok", config: .}' <<<"$CONFIG_JSON"
}

# Writes the full result to --out (pretty) and prints a summary, or prints
# the full result when there is no --out.
emit() { # emit <step> <json> <summary-filter>
  if [[ -n "$OUT" ]]; then
    write_atomic "$OUT" "$(jq . <<<"$2")" || die "$1" "could not write $OUT"
    jq -c --arg out "$OUT" "$3 + {out: \$out}" <<<"$2"
  else
    printf '%s\n' "$2"
  fi
}

# ─── fetch ───────────────────────────────────────────────────────────────────

GRAPH_FIELDS='number state parent { number state repository { nameWithOwner } } subIssuesSummary { total completed } subIssues(first: 100) { nodes { number state repository { nameWithOwner } } }'

graph_chunk() { # graph_chunk <owner/name> <n>... — one GraphQL call, one JSON line per issue
  local repo="$1"; shift
  local q="" n out
  for n in "$@"; do q+="i$n: issue(number: $n) { $GRAPH_FIELDS } "; done
  out=$("$GH_BIN" api graphql -f query="query { r: repository(owner: \"${repo%%/*}\", name: \"${repo#*/}\") { $q} }" 2>&1 </dev/null) \
    || { printf '%s' "$(head -c 300 <<<"$out")"; return 1; }
  jq -c --arg repo "$repo" '(.data.r // {}) | to_entries[] | .value | select(type == "object") | . + {repo: $repo}' <<<"$out" 2>/dev/null \
    || { printf 'unreadable GraphQL response'; return 1; }
}

cmd_fetch() {
  [[ -n "$OUT" ]] || die "parse_args" "--out is required: the backlog directory to write"
  load_config
  mkdir -p "$OUT" || die "fetch" "cannot create $OUT"
  local summary repo dir out n lines gerr nums fetched
  local chunk=()
  tmpfile summary
  fetched=$(now_iso)
  while IFS= read -r repo; do
    dir="$OUT/$(repo_dir "$repo")"
    mkdir -p "$dir" || die "fetch" "cannot create $dir"
    out=$("$GH_BIN" issue list -R "$repo" --state open --limit 2000 \
          --json assignees,author,body,createdAt,labels,milestone,number,title,updatedAt,url 2>&1 </dev/null) \
      || die "fetch" "gh issue list -R $repo --state open failed: $(head -c 300 <<<"$out")"
    jq_true 'type == "array"' <<<"$out" || die "fetch" "gh issue list -R $repo did not return a JSON array"
    printf '%s\n' "$out" > "$dir/open.json"
    out=$("$GH_BIN" issue list -R "$repo" --state all --limit 6000 --json number,createdAt,closedAt,stateReason 2>&1 </dev/null) \
      || die "fetch" "gh issue list -R $repo --state all failed: $(head -c 300 <<<"$out")"
    jq_true 'type == "array"' <<<"$out" || die "fetch" "gh issue list -R $repo --state all did not return a JSON array"
    printf '%s\n' "$out" > "$dir/history.json"

    # The sub-issue graph, 40 issues per query. A host without sub-issues
    # (older GHES) fails the query; scope then groups by title, label and body
    # references only, and the failure is reported as a warning.
    : > "$dir/graph.jsonl"
    gerr=""
    chunk=()
    nums=$(jq -r '.[].number' "$dir/open.json")
    for n in $nums; do
      chunk+=("$n")
      if [[ ${#chunk[@]} -eq 40 ]]; then
        lines=$(graph_chunk "$repo" "${chunk[@]}") || { gerr="$lines"; break; }
        [[ -z "$lines" ]] || printf '%s\n' "$lines" >> "$dir/graph.jsonl"
        chunk=()
      fi
    done
    if [[ -z "$gerr" && ${#chunk[@]} -gt 0 ]]; then
      if lines=$(graph_chunk "$repo" "${chunk[@]}"); then
        [[ -z "$lines" ]] || printf '%s\n' "$lines" >> "$dir/graph.jsonl"
      else
        gerr="$lines"
      fi
    fi
    if [[ -n "$gerr" ]]; then echo '[]' > "$dir/graph.json"; else jq -s . "$dir/graph.jsonl" > "$dir/graph.json"; fi
    rm -f "$dir/graph.jsonl"
    jq -cn --arg repo "$repo" --arg gerr "$gerr" \
      --slurpfile o "$dir/open.json" --slurpfile h "$dir/history.json" --slurpfile g "$dir/graph.json" \
      '{repo: $repo, open: ($o[0] | length), history: ($h[0] | length), graph: ($g[0] | length)}
       + (if $gerr == "" then {} else {graph_error: $gerr} end)' >> "$summary"
  done < <(jq -r '.repos[]' <<<"$CONFIG_JSON")
  jq -cn --argjson cfg "$CONFIG_JSON" --arg at "$fetched" '{repos: $cfg.repos, fetched_at: $at}' > "$OUT/meta.json"
  jq -cs --arg out "$OUT" --arg at "$fetched" \
    '{status: "ok", out: $out, fetched_at: $at, repos: .,
      warnings: [.[] | select(.graph_error) | "\(.repo): no sub-issue graph (\(.graph_error)); epics come from titles, labels and body references only"]}' "$summary"
}

# ─── scope ───────────────────────────────────────────────────────────────────

# Groups the backlog into units: each epic with its open children, and each
# freestanding ticket. An epic is an issue whose title starts with "epic", that
# carries an `epic` label, or that has sub-issues. Children are sub-issues
# first, then issue references in an epic's body. Everything is sorted before
# children are claimed, so an issue named by two epics always lands in the
# same one (in-scope epics first, then by repo and number).
#
# Scope: an issue assigned to someone other than the operator is out. An epic
# that is out takes its children with it, except children assigned to the
# operator, which stay in as freestanding tickets.
# shellcheck disable=SC2016
SCOPE_FILTER='
def canon($name): ([$cfg.repos[] | select(ascii_downcase == ($name | ascii_downcase))] | .[0]) // $name;
def short_repo($nm): [$cfg.repos[] | select((split("/") | .[1] | ascii_downcase) == ($nm | ascii_downcase))] | .[0];
($cfg.operator | ascii_downcase) as $op
| [ .[] | .repo as $r | (.open // [])[] | select(type == "object")
    | { key: "\($r)#\(.number)", repo: $r, number, title: (.title // ""), url: (.url // null), body: (.body // ""),
        labels: [(.labels // [])[] | .name | select(type == "string")],
        assignees: [(.assignees // [])[] | .login | select(type == "string")],
        created: ((.createdAt // "") | .[0:10]), updated: ((.updatedAt // "") | .[0:10]) } ] as $list
| ($list | map({key: .key, value: .}) | obj) as $issues
| ([ .[] | (.graph // [])[] | select(type == "object" and (.number | type) == "number")
     | {key: "\(canon(.repo))#\(.number)", value: .} ] | obj) as $graph
| def elsewhere: (.assignees | length) > 0 and ((.assignees | map(ascii_downcase) | index($op)) == null);
  def mine: (.assignees | map(ascii_downcase) | index($op)) != null;
  def node_key: "\(canon(.repository.nameWithOwner))#\(.number)";
  def is_epic: (.title | test("^\\W*epic\\b"; "i"))
    or ((.labels | map(ascii_downcase) | index("epic")) != null)
    or ((($graph[.key].subIssuesSummary.total) // 0) > 0);
  ([ $list[] | {key: .key, value: is_epic} ] | obj) as $is_epic
| ($list | sort_by([.repo, .number])) as $sorted
# Sub-issue links, from both ends of the graph: a node'"'"'s parent, and an epic'"'"'s subIssues.
| ([ $graph | to_entries[] | .key as $k | .value.parent | select(type == "object" and .state == "OPEN")
     | node_key as $p | select($issues[$p] != null and $p != $k) | {key: $k, value: $p} ]
   + [ $graph | to_entries[] | .key as $p | select($issues[$p] != null) | (.value.subIssues.nodes // [])[]
       | select(type == "object" and .state == "OPEN") | node_key as $k | select($issues[$k] != null and $k != $p) | {key: $k, value: $p} ]
   | reduce .[] as $e ({}; if .[$e.key] == null then .[$e.key] = $e.value else . end)) as $parent0
# Body references: owner/name#N, name#N (a configured repo), #N (the epic'"'"'s own repo), or an issue URL.
| def refs($e):
    [ $e.body | match("(?:https?://github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/([0-9]+))|(?:(?<![A-Za-z0-9_./#-])(?:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)|([A-Za-z0-9_.-]+))?#([0-9]+)\\b)"; "g")
      | .captures | map(.string)
      | if .[0] != null then "\(canon(.[0]))#\(.[1])"
        elif .[2] != null then "\(canon(.[2]))#\(.[4])"
        elif .[3] != null then (short_repo(.[3]) as $rr | .[4] as $n | if $rr == null then empty else "\($rr)#\($n)" end)
        else "\($e.repo)#\(.[4])" end ];
  ([ $sorted[] | select($is_epic[.key]) ] | sort_by([(if elsewhere then 1 else 0 end), .repo, .number])) as $epics_sorted
| (reduce $epics_sorted[] as $e ($parent0;
     reduce (refs($e)[]) as $ck (.;
       if $issues[$ck] != null and $ck != $e.key and .[$ck] == null and ($is_epic[$ck] | not) then .[$ck] = $e.key else . end))) as $parent
| def root($k; $seen): $parent[$k] as $p | if $p == null or ($seen | index($p)) != null then $k else root($p; $seen + [$k]) end;
  ([ $sorted[] | {key: .key, value: root(.key; [])} ] | obj) as $rootof
| ([ $sorted[] | .key | select($rootof[.] != . or $is_epic[.]) ] | group_by($rootof[.])
   | map({key: $rootof[.[0]], value: .}) | sort_by($issues[.key] | [.repo, .number])) as $groups
| [ $groups[] | select($issues[.key] | elsewhere) ] as $out_groups
| [ $groups[] | select($issues[.key] | elsewhere | not) ] as $in_groups
| [ $out_groups[] | .key as $rk | .value[] | select(. != $rk and ($issues[.] | mine)) ] as $rescued
| ([ $out_groups[] | .key as $rk | .value[] | select(. == $rk or ($issues[.] | mine | not))
     | {key: ., why: (if . == $rk then "epic assigned to someone else" else "in epic \($rk), which is assigned to someone else" end)} ]
   + [ $in_groups[] | .key as $rk | .value[] | select(. != $rk and ($issues[.] | elsewhere))
       | {key: ., why: "child of \($rk), assigned to someone else"} ]) as $ex_groups
| ([ $sorted[] | .key | select($rootof[.] == . and ($is_epic[.] | not)) ] + $rescued) as $free0
| [ $free0[] | select($issues[.] | elsewhere) | {key: ., why: "assigned to someone else"} ] as $ex_free
| [ $free0[] | select($issues[.] | elsewhere | not) ] as $free
| def unit: {key, repo, number, title, url, labels, assignees};
  [ $in_groups[] | .key as $rk
    | ($issues[$rk] | unit)
      + {progress: (($graph[$rk].subIssuesSummary // null) | if type == "object" then {closed: .completed, total: .total} else null end),
         children: ([.value[] | select(. != $rk and ($issues[.] | elsewhere | not)) | $issues[.] | unit] | sort_by([.repo, .number]))} ]
  | sort_by([(0 - (.children | length)), .repo, .number]) as $epics
| [ $free[] | $issues[.] | unit + {created, updated} ] | sort_by([.repo, .number]) as $free_out
| [ ($ex_groups + $ex_free)[] | . as $x | $issues[$x.key] | {key, title, url, assignees, why: $x.why} ] | sort_by([.key]) as $excluded
| {
    status: "ok",
    operator: $cfg.operator,
    repos: $cfg.repos,
    counts: {
      open: ($list | length),
      in_scope: (($epics | length) + ([$epics[].children[]] | length) + ($free_out | length)),
      epics: ($epics | length),
      epic_children: ([$epics[].children[]] | length),
      free: ($free_out | length),
      excluded: ($excluded | length)
    },
    epics: $epics,
    free: $free_out,
    excluded: $excluded
  }
'

cmd_scope() {
  load_config
  [[ -n "$BACKLOG" && -d "$BACKLOG" ]] || die "parse_args" "--backlog must be the directory fetch wrote"
  local bundle repo dir g out
  tmpfile bundle
  while IFS= read -r repo; do
    dir="$BACKLOG/$(repo_dir "$repo")"
    [[ -f "$dir/open.json" ]] || die "scope" "no open issues for $repo in $BACKLOG: run fetch first"
    g="$dir/graph.json"
    [[ -f "$g" ]] || g=/dev/null
    jq -cn --arg repo "$repo" --slurpfile o "$dir/open.json" --slurpfile g "$g" \
      '{repo: $repo, open: ($o[0] // []), graph: ($g[0] // [])}' >> "$bundle" 2>/dev/null \
      || die "scope" "unreadable backlog files for $repo in $dir"
  done < <(jq -r '.repos[]' <<<"$CONFIG_JSON")
  out=$(jq -cs --argjson cfg "$CONFIG_JSON" "$JQ_LIB$SCOPE_FILTER" "$bundle" 2>&1) || die "scope" "scope filter failed: $out"
  emit "scope" "$out" '{status, counts}'
}

# ─── prs ─────────────────────────────────────────────────────────────────────

# shellcheck disable=SC2016
PR_ROW='
{ repo: $repo, number, title: (.title // ""), url: (.url // null), draft: (.isDraft == true),
  review: ((.reviewDecision // "") | if . == "" then "NONE" else . end),
  labels: [(.labels // [])[] | .name | select(type == "string")],
  mergeable: (.mergeable // "UNKNOWN"), created: (.createdAt // null), branch: (.headRefName // null),
  author: (.author.login // null), body: (.body // ""), checks_raw: $checks }
'

# A PR links an issue with a closing or reference keyword in its body. Check
# state comes from `gh pr checks`, which reports only the latest run of each
# check; the status rollup keeps stale runs.
# shellcheck disable=SC2016
PRS_FILTER='
def canon($name): ([$cfg.repos[] | select(ascii_downcase == ($name | ascii_downcase))] | .[0]) // $name;
def links($repo):
  [ .body | match("\\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)\\b:?\\s+(?:https?://github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/([0-9]+)|(?:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+))?#([0-9]+))"; "gi")
    | .captures | map(.string)
    | {verb: (.[0] | ascii_downcase), key: (if .[1] != null then "\(canon(.[1]))#\(.[2])" else "\(canon(.[3] // $repo))#\(.[4])" end)} ]
  | unique_by(.key);
def check_state:
  if . == null then "unknown"
  else (map(.bucket) as $b
        | if any($b[]; . == "fail" or . == "cancel") then "failing"
          elif any($b[]; . == "pending") then "pending"
          elif ($b | length) > 0 then "green"
          else "none" end) end;
def num_key: split("#") | [.[0], (.[1] | tonumber)];
($scope[0]) as $sc
| ([$sc.epics[] | ., .children[]] + $sc.free) as $units
| ($units | map(.key)) as $inscope
| ($units | map({key: .key, value: .}) | obj) as $iss
| [ $prs[] | . as $p
    | {repo, number, key: "\(.repo)#\(.number)", title, url, draft, review, labels,
       crow_merge: ((.labels | index("crow:merge")) != null), mergeable, created, branch, author,
       checks: (if .draft then "not_read" else (.checks_raw | check_state) end),
       failing: [(.checks_raw // [])[] | select(.bucket == "fail" or .bucket == "cancel") | .name],
       links: ($p | links($p.repo))} ]
  | sort_by([.repo, .number]) as $rows
| def pr_state:
    if .draft then "PR draft"
    elif .review == "APPROVED" then "PR approved" + (if .crow_merge then ", crow:merge" else "" end)
    elif .review == "CHANGES_REQUESTED" then "PR changes requested"
    else "PR in review" end;
  ([ $rows[] | . as $p | .links[] | select(.key | member($inscope))
     | {key, pr: $p.key, pr_url: $p.url, state: ($p | pr_state)} ] | unique_by(.key)) as $by_pr
| ($sessions[0] // null) as $ss
| ([ (if ($ss | type) == "object" then ($ss.sessions // []) else [] end)[]
     | select(type == "object" and (.status == "active" or .status == "inReview") and (.ticket_url | type) == "string")
     | . as $s
     | (.ticket_url | capture("^https?://github\\.com/(?<r>[^/]+/[^/]+)/issues/(?<n>[0-9]+)")) | "\(canon(.r))#\(.n)" as $k
     | select($k | member($inscope))
     | {key: $k, session: $s.id, session_name: ($s.name // null),
        state: (if $s.status == "inReview" then "In review (Crow)" else "In progress (Crow)" end)} ] | unique_by(.key)) as $by_session
| ($by_session | map({key: .key, value: .}) | obj) as $sess_of
| ([ $by_pr[] | . + (if $sess_of[.key] then {session: $sess_of[.key].session} else {} end) ]
   + [ $by_session[] | select(.key as $k | ($by_pr | map(.key) | index($k)) == null) ]
   | map(. + {url: $iss[.key].url, title: $iss[.key].title}) | sort_by(.key | num_key)) as $flight
| [ $merged[] ] | sort_by(.merged) as $merged_rows
| {
    status: "ok",
    counts: {
      open_prs: ($rows | length),
      ready_to_merge: ([$rows[] | select(.review == "APPROVED" and (.draft | not) and .mergeable == "MERGEABLE" and .checks == "green" and (.crow_merge | not))] | length),
      in_flight: ($flight | length),
      merged_since: ($merged_rows | length)
    },
    sessions_read: (($ss | type) == "object"),
    ready_to_merge: [$rows[] | select(.review == "APPROVED" and (.draft | not) and .mergeable == "MERGEABLE" and .checks == "green" and (.crow_merge | not)) | .key],
    prs: $rows,
    in_flight: $flight,
    merged_since: $merged_rows
  }
'

cmd_prs() {
  load_config
  require_file --scope "$SCOPE"
  local rows merged sessions errf repo list pr n checks out
  tmpfile rows; tmpfile merged; tmpfile sessions; tmpfile errf
  while IFS= read -r repo; do
    list=$("$GH_BIN" pr list -R "$repo" --state open --limit 200 \
           --json number,title,url,isDraft,reviewDecision,labels,createdAt,headRefName,body,author,mergeable 2>&1 </dev/null) \
      || die "prs" "gh pr list -R $repo failed: $(head -c 300 <<<"$list")"
    jq_true 'type == "array"' <<<"$list" || die "prs" "gh pr list -R $repo did not return a JSON array"
    while IFS= read -r pr; do
      [[ -n "$pr" ]] || continue
      n=$(jq -r '.number' <<<"$pr")
      checks="null"
      if ! jq_true '.isDraft == true' <<<"$pr"; then
        # gh pr checks exits non-zero for failing (1) and pending (8) checks,
        # so read its output, not its status.
        checks=$("$GH_BIN" pr checks "$n" -R "$repo" --json name,bucket 2>"$errf" </dev/null) || true
        if ! jq_true 'type == "array"' <<<"$checks"; then
          if grep -qi 'no checks reported' "$errf"; then checks="[]"; else checks="null"; fi
        fi
      fi
      jq -c --arg repo "$repo" --argjson checks "$checks" "$PR_ROW" <<<"$pr" >> "$rows" \
        || die "prs" "could not read PR $repo#$n"
    done < <(jq -c '.[]' <<<"$list")
    if [[ -n "$MERGED_SINCE" ]]; then
      list=$("$GH_BIN" pr list -R "$repo" --state merged --search "merged:>=$MERGED_SINCE" --limit 200 \
             --json number,title,url,mergedAt,author 2>&1 </dev/null) \
        || die "prs" "gh pr list -R $repo --state merged failed: $(head -c 300 <<<"$list")"
      jq -c --arg repo "$repo" '.[] | {key: "\($repo)#\(.number)", repo: $repo, number, title, url, merged: .mergedAt, by: (.author.login // null)}' \
        <<<"$list" >> "$merged" 2>/dev/null || die "prs" "gh pr list -R $repo --state merged did not return a JSON array"
    fi
  done < <(jq -r '.repos[]' <<<"$CONFIG_JSON")
  # Live Crow sessions count as in flight. If Crow can't be read, say so
  # (sessions_read: false) instead of reporting those issues as free.
  if ! "$CROW_BIN" list-sessions > "$sessions" 2>/dev/null </dev/null || ! jq_true '(.sessions | type) == "array"' "$sessions"; then
    echo 'null' > "$sessions"
  fi
  out=$(jq -cn --argjson cfg "$CONFIG_JSON" --slurpfile scope "$SCOPE" --slurpfile prs "$rows" \
        --slurpfile merged "$merged" --slurpfile sessions "$sessions" "$JQ_LIB$PRS_FILTER" 2>&1) \
    || die "prs" "prs filter failed: $out"
  emit "prs" "$out" '{status, counts, sessions_read, ready_to_merge}'
}

# ─── stats ───────────────────────────────────────────────────────────────────

# Open issues per repo at the end of each of the last --days UTC days, and the
# last seven days' flow. Counts every open issue, in scope or not.
# shellcheck disable=SC2016
STATS_FILTER='
($now | epoch) as $t
| ($t - ($t % 86400)) as $today
| [range($days - 1; -1; -1) | $today - . * 86400] as $starts
| [ .[] | {repo, rows: [(.history // [])[] | select(type == "object") | {c: (.createdAt | epoch), x: (.closedAt | epoch)}]} ] as $hist
| ($scope[0].counts) as $sc
| {
    status: "ok",
    days: ($starts | map(strftime("%Y-%m-%d"))),
    order: [$hist[].repo],
    series: ([ $hist[] | .rows as $rows | {key: .repo, value: [ $starts[] | (. + 86399) as $eod
               | [ $rows[] | select(.c != null and .c <= $eod and (.x == null or .x > $eod)) ] | length ]} ] | obj),
    open_total: $sc.open,
    in_scope: $sc.in_scope,
    excluded: $sc.excluded,
    epics: $sc.epics,
    epic_children: $sc.epic_children,
    free: $sc.free,
    opened_7d: ([ $hist[].rows[] | select(.c != null and .c > $t - 7 * 86400) ] | length),
    closed_7d: ([ $hist[].rows[] | select(.x != null and .x > $t - 7 * 86400) ] | length)
  }
'

cmd_stats() {
  load_config
  [[ -n "$BACKLOG" && -d "$BACKLOG" ]] || die "parse_args" "--backlog must be the directory fetch wrote"
  require_file --scope "$SCOPE"
  (( DAYS >= 1 && DAYS <= 365 )) || die "parse_args" "--days must be 1 to 365"
  local bundle repo dir out
  tmpfile bundle
  while IFS= read -r repo; do
    dir="$BACKLOG/$(repo_dir "$repo")"
    [[ -f "$dir/history.json" ]] || die "stats" "no issue history for $repo in $BACKLOG: run fetch first"
    jq -cn --arg repo "$repo" --slurpfile h "$dir/history.json" '{repo: $repo, history: ($h[0] // [])}' >> "$bundle" 2>/dev/null \
      || die "stats" "unreadable $dir/history.json"
  done < <(jq -r '.repos[]' <<<"$CONFIG_JSON")
  out=$(jq -cs --arg now "$(now_iso)" --argjson days "$DAYS" --slurpfile scope "$SCOPE" "$JQ_LIB$STATS_FILTER" "$bundle" 2>&1) \
    || die "stats" "stats filter failed: $out"
  emit "stats" "$out" '{status, open_total, in_scope, opened_7d, closed_7d}'
}

# ─── decision docs ───────────────────────────────────────────────────────────

# Prints decision docs as [{id, raw}] from a directory of <id>.json files or
# one JSON file (array of docs, {id: doc} map, or one {id, data, version} per line).
load_docs() { # load_docs <flag> <path>
  local path="$2"
  if [[ -d "$path" ]]; then
    local f id first=1
    printf '['
    for f in "$path"/*.json; do
      [[ -e "$f" ]] || continue
      id=$(basename "$f" .json)
      [[ $first -eq 1 ]] || printf ','
      first=0
      jq -c --arg id "$id" '{id: $id, raw: .}' "$f" 2>/dev/null \
        || jq -cn --arg id "$id" '{id: $id, raw: null, unreadable: true}'
    done
    printf ']'
  elif [[ -f "$path" ]]; then
    jq -cs '
      def doc: if type == "object" then {id: ((.id // .doc_id // .docId) | if type == "string" then . else null end), raw: .}
               else {id: null, raw: .} end;
      if length == 0 then []
      elif length == 1 and (.[0] | type) == "array" then .[0] | map(doc)
      elif length == 1 and (.[0] | type) == "object" and ((.[0] | has("id") and has("data")) | not) then
        .[0] | to_entries | map({id: .key, raw: .value})
      else map(doc) end' "$path" 2>/dev/null \
      || die "parse_args" "$1 is not JSON (an array, an {id: doc} map, or one doc per line): $path"
  else
    die "parse_args" "$1 not found: $path"
  fi
}

docs_file() { # docs_file <var> <flag> <path> — the docs as one JSON array in a temp file
  local __docs_path __docs_json
  tmpfile __docs_path
  __docs_json=$(load_docs "$2" "$3") || { printf '%s\n' "$__docs_json"; exit 2; }
  jq -c . <<<"$__docs_json" > "$__docs_path" 2>/dev/null || die "parse_args" "could not read the docs in $3"
  printf -v "$1" '%s' "$__docs_path"
}

# A directory read is proven by the marker `mark-read` writes after the
# ArtifactData list, never by the directory's own mtime: `mkdir` alone would
# pass that (PR #1368 review). A single saved list file proves itself.
READ_MARKER=".read.json"

# Seconds since the decisions were read, or "none" when no read is recorded.
read_age() { # read_age <path>
  local f="$1" t
  [[ -d "$1" ]] && f="$1/$READ_MARKER"
  [[ -f "$f" ]] || { echo none; return; }
  t=$(mtime "$f") || { echo none; return; }
  echo $(( $(date -u +%s) - t ))
}

# Records that DIR holds a fresh ArtifactData list of --count docs. Refuses a
# count that doesn't match the files on disk (a list that didn't land).
cmd_mark_read() {
  [[ -n "$DECISIONS" && -d "$DECISIONS" ]] || die "parse_args" "--decisions must be the directory the list wrote (<out_dir>/decisions)"
  is_uint "$COUNT" || die "parse_args" "--count is required: how many docs the ArtifactData list returned"
  local f n=0
  for f in "$DECISIONS"/*.json; do [[ -e "$f" ]] && n=$((n + 1)); done
  if (( n != COUNT )); then
    jq -cn --argjson n "$n" --argjson c "$COUNT" --arg d "$DECISIONS" \
      '{status:"error", step:"mark_read", errors:["the list returned \($c) docs but \($d) holds \($n): list again into an emptied directory"]}'
    exit 1
  fi
  jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson c "$COUNT" '{read_at: $at, count: $c}' > "$DECISIONS/$READ_MARKER"     || die "mark_read" "cannot write $DECISIONS/$READ_MARKER"
  jq -cn --argjson c "$COUNT" '{status:"ok", count: $c}'
}

# ─── check (the brief and card format) ───────────────────────────────────────

# shellcheck disable=SC2016
VALIDATE='
def SECTIONS: ["waiting", "kickoff", "watch", "close"];
def KINDS: ["ticket", "epic", "pr", "decision", "action"];
def RECS: ["kickoff", "defer", "close"];
def LEVELS: ["low", "medium", "high"];
def TIMING_RE: "^(before-release|any-time|after [0-9]{4}-[0-9]{2}-[0-9]{2})$";
def need($k): if (.[$k] | nonempty) then [] else ["\($k) is required"] end;
def nelist($k; $what):
  if (.[$k] | type) == "array" and (.[$k] | length) > 0 and (.[$k] | all(nonempty)) then []
  else ["\($k) needs at least one \($what), each a non-empty string"] end;
def objlist($k; $req; $what):
  if (.[$k] // null) == null then []
  elif (.[$k] | type) == "array" and (.[$k] | all(type == "object" and (. as $o | $req | all(. as $f | $o[$f] | nonempty)))) then []
  else ["\($k) must be a list of \($what)"] end;
def sentences: [match("[.!?](\\s|$)"; "g")] | length;

# The card format the operator approved: what it is, who notices, pros, cons,
# a risk profile, why now, and every decision with a suggested answer.
def card_errors($rid):
  (if (.id | type) != "string" then ["id must be a string"]
   elif (.id | test(ID_RE) | not) or .id == "." or .id == ".." then ["id \(.id | tojson) may use only letters, digits and _ - . ~ : @ +"]
   elif (.id | startswith("\($rid)-") | not) or .id == "\($rid)-" then ["id \(.id | tojson) must be \($rid)-<slug>: every id carries its round id"]
   elif .id == "\($rid)-general" then ["id \(.id | tojson) is reserved for the general notes box"]
   else [] end)
  + (if (.section | type) == "string" and (.section | member(SECTIONS)) then [] else ["section must be one of \(SECTIONS | join(", "))"] end)
  + (if (.kind // null) == null or ((.kind | type) == "string" and (.kind | member(KINDS))) then [] else ["kind must be one of \(KINDS | join(", "))"] end)
  + need("key") + need("title")
  + (if (.url // null) == null or (.url | is_url) then [] else ["url must be an http(s) URL"] end)
  + (if (.rec | type) == "string" and (.rec | member(RECS)) then [] else ["rec must be kickoff, defer or close"] end)
  + need("effort")
  + (if (.timing | type) == "string" and (.timing | test(TIMING_RE)) then [] else ["timing must be before-release, any-time, or \"after YYYY-MM-DD\""] end)
  + (if (.summary | nonempty) then [] else ["summary is required: what it is, in 1-3 plain sentences"] end)
  + (if (.who_notices | type) != "object" then ["who_notices is required: {today, after, asked_by, internal}"]
     else (.who_notices as $w | ["today", "after", "asked_by"] | map(select($w[.] | nonempty | not) | "who_notices.\(.) is required"))
          + (if (.who_notices.internal | type) == "boolean" then [] else ["who_notices.internal must be true or false: is whoever asked for it inside the org?"] end)
     end)
  + nelist("pros"; "pro") + nelist("cons"; "con")
  + (if (.risk | type) != "object" then ["risk is required: {level, if_wrong, undo, notice}"]
     else (if (.risk.level | type) == "string" and (.risk.level | member(LEVELS)) then [] else ["risk.level must be low, medium or high"] end)
          + (.risk as $r | ["if_wrong", "undo", "notice"] | map(select($r[.] | nonempty | not) | "risk.\(.) is required"))
     end)
  + need("why_now")
  + (if (.decisions // null) == null then []
     elif (.decisions | type) == "array" and (.decisions | all(type == "object" and (.question | nonempty) and (.suggested | nonempty))) then []
     else ["decisions must be a list of {question, suggested}: every decision carries a suggested answer"] end)
  + strlist("evidence") + strlist("labels") + strlist("children")
  + (if .rec == "close" and ((.evidence // []) | length) == 0 then ["a close needs verified evidence: list it in evidence"] else [] end)
  + (. as $c | ["repo", "rec_why", "carried_from"] | map(. as $k | $c | strfield($k)) | add)
  + (if (.buttons // null) == null then []
     elif (.buttons | type) != "object" then ["buttons must be {go, later, drop}"]
     else [ .buttons | to_entries[]
            | if (.key | member(["go", "later", "drop"]) | not) then "buttons.\(.key) is not go, later or drop"
              elif (.value | type) != "object" or (.value."label" | nonempty | not) then "buttons.\(.key) needs a label"
              elif (.value."label" | length) > 40 then "buttons.\(.key).label is longer than 40 characters"
              elif ((.value.hint // "") | type) != "string" or ((.value.hint // "") | length) > 60 then "buttons.\(.key).hint must be a string of at most 60 characters"
              else empty end ] end)
  + (if (.progress // null) == null or ((.progress | type) == "object" and (.progress.closed | type) == "number" and (.progress.total | type) == "number") then []
     else ["progress must be {closed, total} numbers"] end)
  + (if has("user_effect") then ["user_effect is the old name: write who_notices {today, after, asked_by, internal}"] else [] end)
  + (if has("risk_profile") then ["risk_profile is the old name: write risk {level, if_wrong, undo, notice}"] else [] end);

def card_warnings($release):
  (if (.summary | nonempty) and (.summary | sentences) > 3 then ["summary runs past 3 sentences"] else [] end)
  + (if .timing == "before-release" and $release == null then ["timing is before-release but the brief names no release"] else [] end)
  + (if .section == "close" and .rec != "close" then ["sits under close but recommends \(.rec)"]
     elif .rec == "close" and .section != "close" and .section != "waiting" then ["recommends close but sits under \(.section)"]
     else [] end);

def where_($i): "card \($i + 1)" + (if (.id | type) == "string" then " (\(.id))" else "" end);

if type != "object" then {errors: ["brief must be a JSON object"], warnings: []}
else
  . as $b
  | ((.round_id // "") | tostring) as $rid
  | (if (.cards | type) == "array" then .cards else [] end) as $cards
  | {
      errors: (
        (if (.round_id | type) == "string" and (.round_id | test("^[A-Za-z0-9_.~:@+-]{1,80}$")) then []
         else ["round_id is required: letters, digits and _ - . ~ : @ +, such as r20261026"] end)
        + need("round") + need("title")
        + (if (.generated_at | epoch) != null then [] else ["generated_at must be an ISO 8601 UTC time"] end)
        + (["context", "lede"] | map(. as $k | $b | strfield($k)) | add)
        + strlist("method")
        + (if (.release // null) == null then []
           elif (.release | type) == "object" and (.release.name | nonempty) then [] else ["release must be {name, date}"] end)
        + (if (.stats // null) == null then []
           elif (.stats | type) == "object"
                and ((.stats.kpis // []) | type == "array" and all(type == "object" and ((.value | type) == "string" or (.value | type) == "number") and (."label" | type) == "string"))
                and ((.stats.composition // []) | type == "array" and all(type == "object" and (."label" | type) == "string" and (.n | type) == "number")) then []
           else ["stats must be {kpis: [{value, label, delta, dir}], composition: [{label, n}]}"] end)
        + (if (.burndown // null) == null then []
           elif (.burndown | type) == "object" and (.burndown.days | type) == "array" and (.burndown.order | type) == "array"
                and (.burndown.series | type) == "object"
                and (.burndown as $bd | $bd.order | all(. as $r | ($bd.series[$r] | type) == "array" and ($bd.series[$r] | length) == ($bd.days | length) and ($bd.series[$r] | all(type == "number")))) then []
           else ["burndown must be {days, order, series} with one number per day for every repo in order"] end)
        + objlist("signal"; ["head"]; "{head, body, src}")
        + objlist("in_flight"; ["key"]; "{key, url, title, state}")
        + objlist("reviewed"; ["key"]; "{key, url, title, why}")
        + objlist("history"; ["round"]; "{round, go, later, drop, carried, open_after}")
        + objlist("earlier"; ["id", "key", "title", "round"]; "{id, key, title, round} as compose writes them")
        + (if (.carry // null) == null then []
           elif (.carry | type) == "object" and (.carry.from_round | nonempty) and (.carry.basis | type) == "array" then []
           else ["carry must be {from_round, basis} as compose writes it"] end)
        + (if (.cards | type) == "array" then [] else ["cards must be an array"] end)
        + [ $cards | to_entries[] | .key as $i | .value
            | if type != "object" then "card \($i + 1) must be an object"
              else where_($i) as $w | card_errors($rid)[] | "\($w): \(.)" end ]
        + [ $cards | map(.id? | select(type == "string")) | group_by(.) | .[] | select(length > 1)
            | "card id \(.[0] | tojson) is used more than once; each id keys one decision" ]
      ),
      warnings: (
        (if ($cards | length) == 0 then ["the brief has no cards"] else [] end)
        + [ $cards | to_entries[] | .key as $i | .value | select(type == "object")
            | where_($i) as $w | card_warnings($b.release // null)[] | "\($w): \(.)" ]
      ),
      summary: {
        round_id: .round_id,
        title: .title,
        cards: ($cards | length),
        sections: ([SECTIONS[] as $s | {key: $s, value: ([$cards[] | select(type == "object" and .section == $s)] | length)}] | obj),
        recs: ([$cards[] | select(type == "object") | .rec | select(type == "string")] | group_by(.) | map({key: .[0], value: length}) | obj),
        carried: ([$cards[] | select(type == "object" and (.carried_from | type) == "string")] | length)
      }
    }
end
'

validate_brief() { # validate_brief <file> — sets CHECK_RESULT, or prints the errors and returns 1
  local result
  result=$(jq -c "$JQ_LIB$VALIDATE" "$1" 2>&1) || die "validate" "validation filter failed: $result"
  if [[ "$(jq -r '.errors | length' <<<"$result")" != "0" ]]; then
    jq -c '{status:"error", step:"validate", errors, warnings}' <<<"$result"
    return 1
  fi
  CHECK_RESULT="$result"
}

cmd_check() {
  require_file --brief "$BRIEF"
  validate_brief "$BRIEF" || exit 1
  jq -c '{status:"ok"} + .summary + {warnings}' <<<"$CHECK_RESULT"
}

# ─── compose ─────────────────────────────────────────────────────────────────

# round.json + cards.json (+ the previous round's undecided cards) → brief.json.
# A card's id is <round_id>-<slug>; slug defaults to its key, slugified. A
# previous card is carried forward when it has no decision and no note, its
# slug isn't on a new card (a new card with that slug replaces it and keeps the
# carried_from), and round.json doesn't retire it. Decided and noted cards are
# never carried as cards: they are acted on. One that has no final result yet
# (blank, or "Pending: …") goes to `earlier` under its old id, with its earlier
# entries that are still unfinished, so its action is never dropped.
# shellcheck disable=SC2016
COMPOSE='
def SECTIONS: ["waiting", "kickoff", "watch", "close"];
def STATUSES: ["go", "later", "drop"];
($round[0]) as $r
| ($cards[0]) as $cs
| ($prev[0] // null) as $p
| ($stats[0] // null) as $st
| ($prs[0] // null) as $pr
| ($r.round_id | tostring) as $rid
| ($now | epoch) as $t
| (if $p then "\($p.round_id)-" else null end) as $pp
| ($docs | map(select(.id != null)) | map({key: .id, value: (.raw | body)}) | obj) as $dmap
| def undecided($d):
    $d == null
    or (($d | type) == "object" and (($d.status | member(STATUSES)) | not) and ($d.note | blank));
  def noted($d): ($d | type) == "object" and (($d.status | member(STATUSES)) | not) and ($d.note | blank | not);
  ([ ($r.retire // [])[] | if type == "object" then .slug else . end | select(type == "string") ]) as $retire
| [ $cs[] | select(type == "object") | (.slug // .key // "" | slugify) as $slug | {id: "\($rid)-\($slug)", _slug: $slug} + del(.slug) ] as $new0
| ($new0 | map(._slug)) as $new_slugs
| (if $p then [ ($p.cards // [])[] | (.id | ltrimstr($pp)) as $s | {card: ., slug: $s, d: $dmap[.id]} ] else [] end) as $prevs
| [ $prevs[] | select(undecided(.d)) ] as $und
| [ $und[] | select((.slug | member($new_slugs) | not) and (.slug | member($retire) | not))
    | .card + {id: "\($rid)-\(.slug)", carried_from: (.card.carried_from // $p.round_id)} ] as $carried
| ([ $und[] | select(.slug | member($new_slugs)) | {key: .slug, value: (.card.carried_from // $p.round_id)} ] | obj) as $refreshed
| [ $new0[] | (if $refreshed[._slug] then . + {carried_from: $refreshed[._slug]} else . end) | del(._slug) ] as $new
| ([ SECTIONS[] as $s | ($new[] | select(.section == $s)), ($carried[] | select(.section == $s)) ]
   + [ ($new + $carried)[] | select((.section | member(SECTIONS)) | not) ]) as $all
| def unfinished($d):
    ($d | type) == "object" and (($d.status | member(STATUSES)) or ($d.note | blank | not)) and (($d.result | is_final) | not);
  def stub($round):
    {id, key, url: (.url // null), title, section, kind: (.kind // "ticket"), rec, round: $round}
    + (if (.buttons | type) == "object" then {buttons} else {} end);
  ([ $prevs[] | select(unfinished(.d)) | .card | stub($p.round_id) ]
   + [ (if $p then ($p.earlier // []) else [] end)[] | select(unfinished($dmap[.id])) ]) as $earlier
| def count($status): [ $prevs[] | select((.d | type) == "object" and .d.status == $status) ] | length;
  (if $r.history then $r.history
   elif $p then (($p.history // []) + [ {round: ($p.round // $p.round_id), go: (count("go") | tostring), later: (count("later") | tostring),
                                         drop: (count("drop") | tostring), carried: ($carried | length | tostring),
                                         open_after: (if $st then ($st.in_scope | tostring) else "" end)} + ($r.history_entry // {}) ])
   else [] end) as $history
| (if $r.stats then $r.stats
   elif $st then {
     kpis: ([ {value: ($st.in_scope | tostring), "label": "open issues in scope"}
              + (if $p and (($p.stats_basis.in_scope // null) | type) == "number"
                 then (($st.in_scope - $p.stats_basis.in_scope) as $d | {delta: "\($d | signed) since the last brief", dir: (if $d > 0 then "up" elif $d < 0 then "down" else "" end)})
                 else {} end),
              {value: "\($st.opened_7d) / \($st.closed_7d)", "label": "opened / closed, last 7 days",
               delta: "net \(($st.opened_7d - $st.closed_7d) | signed)", dir: (if $st.opened_7d > $st.closed_7d then "up" elif $st.opened_7d < $st.closed_7d then "down" else "" end)},
              {value: ($all | length | tostring), "label": "cards on this brief"} ]
            + (if ($carried | length) > 0 then [ {value: ($carried | length | tostring), "label": "carried from an earlier brief"} ] else [] end)),
     composition: ([ {"label": "in \($st.epics) epics", n: ($st.epics + $st.epic_children)},
                     {"label": "freestanding", n: $st.free},
                     {"label": "assigned to someone else", n: $st.excluded} ] | map(select(.n > 0)))
   }
   else null end) as $kstats
| def basis($pre): [ $docs[] | select((.id | type) == "string" and (.id | startswith($pre))) | (.raw | body) as $x
                      | "\(.id)@\(if ($x | type) == "object" then ($x.at // "") else "" end)" ] | sort;
  {
    round_id: $rid,
    round: ($r.round // ($t | strftime("%Y-%m-%d"))),
    title: ($r.title // $cfg.title),
    context: ($r.context // ($cfg.repos | join(" · "))),
    generated_at: ($r.generated_at // ($t | strftime("%Y-%m-%dT%H:%M:%SZ"))),
    lede: ($r.lede // null),
    release: (if $r | has("release") then $r.release else $cfg.release end),
    stats: $kstats,
    stats_basis: (if $st then {in_scope: $st.in_scope, open_total: $st.open_total} else ($r.stats_basis // null) end),
    burndown: ($r.burndown // (if $st then {days: $st.days, order: $st.order, series: $st.series} else null end)),
    signal: ($r.signal // []),
    in_flight: ($r.in_flight // (if $pr then [ $pr.in_flight[] | {key, url, title, state} ] else [] end)),
    reviewed: ($r.reviewed // []),
    history: $history,
    method: ($r.method // []),
    carry: (if $p then {from_round: $p.round_id, basis: basis($pp)} else null end),
    earlier: (if ($earlier | length) > 0 then $earlier else null end),
    cards: $all
  }
  | with_entries(select(.value != null))
  | . as $brief
  | {
      brief: $brief,
      report: {
        carried: [ $carried[] | .id ],
        refreshed: ($refreshed | keys),
        retired: [ $und[] | select(.slug | member($retire)) | .slug ],
        decided_prev: [ $prevs[] | select((.d | type) == "object" and (.d.status | member(STATUSES))) | .card.id ],
        noted_prev: [ $prevs[] | select(noted(.d)) | .card.id ],
        earlier: [ $earlier[] | .id ],
        errors: ([ $cs[] | select(type == "object" and has("id")) | "card \(.key // "?" | tostring): cards.json carries no id; compose derives it from slug (or key)" ]
                 + (if $p and $p.round_id == $rid then ["round_id \($rid) is the previous round'"'"'s: a new round needs a new id"] else [] end)
                 + (if ($cs | type) == "array" then [] else ["cards must be a JSON array of cards"] end))
      }
    }
'

cmd_compose() {
  load_config
  require_file --round "$ROUND"
  require_file --cards "$CARDS"
  jq_true 'type == "array"' "$CARDS" || die "parse_args" "--cards must be a JSON array of cards: $CARDS"
  [[ -n "$OUT" ]] || die "parse_args" "--out is required: where to write brief.json"
  [[ -z "$STATS" ]] || require_file --stats "$STATS"
  [[ -z "$PRS" ]] || require_file --prs "$PRS"
  local prev=/dev/null docs out brief
  if [[ -n "$PREV" ]]; then
    require_file --prev-brief "$PREV"
    [[ -n "$DECISIONS" ]] || die "parse_args" "--prev-brief needs --decisions: read the previous round's decisions before composing the next one"
    docs_file docs --decisions "$DECISIONS"
    prev="$PREV"
  else
    [[ -z "$DECISIONS" ]] || die "parse_args" "--decisions needs --prev-brief: decisions are carried from the previous round"
    tmpfile docs
    echo '[]' > "$docs"
  fi
  local stats_f="${STATS:-/dev/null}" prs_f="${PRS:-/dev/null}"
  out=$(jq -cn --argjson cfg "$CONFIG_JSON" --arg now "$(now_iso)" \
        --slurpfile round "$ROUND" --slurpfile cards "$CARDS" --slurpfile prev "$prev" \
        --slurpfile stats "$stats_f" --slurpfile prs "$prs_f" --slurpfile docsw "$docs" \
        "$JQ_LIB"'($docsw[0]) as $docs | '"$COMPOSE" 2>&1) \
    || die "compose" "compose filter failed: $out"
  if [[ "$(jq -r '.report.errors | length' <<<"$out")" != "0" ]]; then
    jq -c '{status:"error", step:"compose", errors: .report.errors}' <<<"$out"
    exit 1
  fi
  tmpfile brief
  jq '.brief' <<<"$out" > "$brief"
  validate_brief "$brief" || exit 1
  mkdir -p "$(dirname "$OUT")" || die "compose" "cannot create $(dirname "$OUT")"
  cp "$brief" "$OUT" || die "compose" "could not write $OUT"
  jq -c --arg out "$OUT" --argjson check "$CHECK_RESULT" \
    '{status: "ok", out: $out} + $check.summary + (.report | del(.errors)) + {warnings: $check.warnings}' <<<"$out"
}

# ─── build ───────────────────────────────────────────────────────────────────

# The republish guard. `stale` when the previous round's decisions changed
# since compose (the operator answered while the next round was being
# written), `active` when anyone wrote to this round or the previous one in the
# last --active-minutes (they are answering right now).
# shellcheck disable=SC2016
GUARD='
($b[0]) as $br
| "\($br.round_id)-" as $cur
| (if ($br.carry | type) == "object" then "\($br.carry.from_round)-" else null end) as $pp
| [ .[] | select((.id | type) == "string") | {id, x: (.raw | body)} ] as $d
| ([ $d[] | select((.id | startswith($cur)) or ($pp != null and (.id | startswith($pp)))) | .x | select(type == "object") | .at | epoch | select(. != null) ] | max) as $last
| (if $pp then ([ $d[] | select(.id | startswith($pp)) | "\(.id)@\(if (.x | type) == "object" then (.x.at // "") else "" end)" ] | sort) else null end) as $basis
| ($now | epoch) as $t
| {
    last_activity_at: (if $last then ($last | todate) else null end),
    active: ($last != null and ($t - $last) < $active * 60),
    retry_after_seconds: (if $last != null and ($t - $last) < $active * 60 then ($active * 60 - ($t - $last)) else 0 end),
    stale: ($pp != null and $basis != $br.carry.basis),
    changed: (if $pp then (($basis - $br.carry.basis) | map(split("@") | .[0]) | unique) else [] end)
  }
'

cmd_build() {
  require_file --brief "$BRIEF"
  [[ -n "$OUT" ]] || die "parse_args" "--out is required: the page to publish"
  [[ -f "$TEMPLATE" ]] || die "build" "page template not found: $TEMPLATE"
  local n marker
  for marker in "__BRIEF_DATA__" "<title>__BRIEF_TITLE__</title>"; do
    n=$(grep -cxF -- "$marker" "$TEMPLATE")
    [[ "$n" == "1" ]] || die "build" "template must have exactly one line \"$marker\" (found $n): $TEMPLATE"
  done
  validate_brief "$BRIEF" || exit 1

  # Read the decisions right before every publish. A first publish has none to
  # read; every other publish must pass a read made in the last --max-read-age
  # seconds, and holds while the operator is answering.
  local guard='{"first_publish":true}'
  if [[ -n "$DECISIONS" ]]; then
    [[ $FIRST_PUBLISH -eq 0 ]] || die "parse_args" "--first-publish and --decisions don't go together"
    [[ -e "$DECISIONS" ]] || die "parse_args" "--decisions not found: $DECISIONS"
    local age docs active
    age=$(read_age "$DECISIONS")
    if [[ "$age" == "none" ]]; then
      jq -cn --arg d "$DECISIONS" \
        '{status:"stale", reason:"no_read", message:"no decisions read is recorded in \($d): list the decisions with ArtifactData, then run mark-read"}'
      exit 4
    fi
    if (( MAX_READ_AGE > 0 && age > MAX_READ_AGE )); then
      jq -cn --argjson age "$age" --argjson max "$MAX_READ_AGE" \
        '{status:"stale", reason:"old_read", read_age_seconds:$age,
          message:"the decisions were read \($age)s ago (limit \($max)s): read them again right before publishing"}'
      exit 4
    fi
    docs_file docs --decisions "$DECISIONS"
    active="${ACTIVE_MINUTES:-10}"
    guard=$(jq -c --slurpfile b "$BRIEF" --arg now "$(now_iso)" --argjson active "$active" "$JQ_LIB$GUARD" "$docs" 2>&1) \
      || die "build" "guard filter failed: $guard"
    if jq_true '.stale' <<<"$guard"; then
      jq -c '{status:"stale", reason:"decisions_changed", changed, last_activity_at,
              message:"decisions on the previous round changed since compose: act on them, compose again, then build"}' <<<"$guard"
      exit 4
    fi
    if jq_true '.active' <<<"$guard"; then
      jq -c '{status:"hold", reason:"operator_active", last_activity_at, retry_after_seconds,
              message:"the operator is answering: wait, read the decisions again, then build"}' <<<"$guard"
      exit 3
    fi
  elif [[ $FIRST_PUBLISH -eq 0 ]]; then
    die "parse_args" "build needs --decisions (a read made right before this publish) or --first-publish"
  elif jq_true '(.carry | type) == "object"' "$BRIEF"; then
    die "parse_args" "this brief carries cards from an earlier round, so it is not a first publish: pass --decisions"
  fi

  # `<` is escaped inside the JSON so no card text can close the data
  # <script> block; JSON.parse turns the escape back into `<`.
  local data title out_dir tmp
  data=$(jq -c . "$BRIEF" | sed 's/</\\u003c/g') || die "build" "could not serialize $BRIEF"
  title=$(jq -r '.title | @html' "$BRIEF") || die "build" "could not read the title"
  out_dir=$(dirname "$OUT")
  mkdir -p "$out_dir" || die "build" "cannot create $out_dir"
  tmp=$(mktemp "$out_dir/.brief-page.XXXXXX") || die "build" "cannot write to $out_dir"
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "__BRIEF_DATA__") printf '%s\n' "$data" ;;
        "<title>__BRIEF_TITLE__</title>") printf '<title>%s</title>\n' "$title" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$TEMPLATE"
  } > "$tmp" || { rm -f "$tmp"; die "build" "could not write the page"; }
  mv -f "$tmp" "$OUT" || { rm -f "$tmp"; die "build" "could not move the page into place at $OUT"; }

  jq -c --arg out "$OUT" --argjson bytes "$(wc -c < "$OUT" | tr -d ' ')" --argjson guard "$guard" \
    '{status:"ok", out:$out, bytes:$bytes} + .summary + {warnings, guard: $guard}' <<<"$CHECK_RESULT"
}

# ─── readback ────────────────────────────────────────────────────────────────

# Joins this round's decision docs to the cards. The round closes when the
# operator presses "I'm done with this brief" (rounds/<round_id>.done), or goes
# stale once it is --round-hours old and nobody has written for
# --idle-minutes. Only a closed round is acted on: ready_to_act. A card stays in
# to_act until Claude writes a final result; "Pending: …" is not final.
# earlier_to_act lists actions carried from earlier, closed rounds.
# shellcheck disable=SC2016
READBACK='
def STATUSES: ["go", "later", "drop"];
def REC_STATUS: {kickoff: "go", defer: "later", close: "drop"};
($b[0]) as $br
| ($br.round_id) as $rid
| "\($rid)-" as $pre
| "\($rid)-general" as $gid
| [ $br.cards[] | .id ] as $ids
| [ $docs[] | select((.id | type) == "string") | . as $d | ($d.raw | body) as $x
    | { id: $d.id, version: ($d.raw | version), unreadable: ($d.unreadable // false), ok: (($x | type) == "object"),
        status: (if ($x | type) == "object" then $x.status else null end),
        note: (if ($x | type) == "object" then $x.note else null end),
        by: (if ($x | type) == "object" then $x.by else null end),
        at: (if ($x | type) == "object" then $x.at else null end),
        ticket: (if ($x | type) == "object" then $x.ticket else null end),
        result: (if ($x | type) == "object" then $x.result else null end) } ] as $all
| [ $all[] | select(.id | startswith($pre)) ] as $mine
| ($mine | map({key: .id, value: .}) | obj) as $by
| [ $mine[]
    | (if .unreadable then {id, field: "doc", value: null, problem: "file is not valid JSON"}
       elif (.ok | not) then {id, field: "doc", value: null, problem: "doc is not an object"}
       else empty end),
      (select(.ok) | select(.status != null and (.status | member(STATUSES) | not))
       | {id, field: "status", value: .status, problem: "not go, later, drop or null; read as undecided"}),
      (select(.ok) | select(.note != null and (.note | type) != "string")
       | {id, field: "note", value: .note, problem: "not a string; ignored"}),
      (select(.ok) | select(.ticket != null and (.ticket | is_url | not))
       | {id, field: "ticket", value: .ticket, problem: "not an http(s) URL; the page shows no link"}),
      (select(.ok) | select(.result != null and (.result | type) != "string")
       | {id, field: "result", value: .result, problem: "not a string; ignored"}),
      (select(.ok) | select(.by != null and (.by | type) != "string")
       | {id, field: "by", value: .by, problem: "not a user id string; ignored"}) ] as $invalid
| def clean:
    { status: (if (.status | type) == "string" and (.status | member(STATUSES)) then .status else null end),
      note: (if (.note | type) == "string" then .note else "" end),
      by: (if (.by | type) == "string" then .by else null end),
      at: (if (.at | type) == "string" then .at else null end),
      ticket: (if (.ticket | is_url) then .ticket else null end),
      result: (if (.result | type) == "string" then .result else "" end),
      version };
  [ $br.cards[] | . as $c | $by[$c.id] as $d
    | {id, key, url: (.url // null), repo: (.repo // null), title, section, kind: (.kind // "ticket"), rec, carried_from: (.carried_from // null)}
      + (if $d and $d.ok then ($d | clean)
         else {status: null, note: "", by: null, at: null, ticket: null, result: "", version: ($d.version // null)} end) ] as $rows
| (if $by[$gid] and $by[$gid].ok then ($by[$gid] | clean | {note, by, at, result, version}) else null end) as $general
# Actions decided on an earlier round and not finished yet (compose carries
# them in `earlier`). Their round has closed, so they are always actionable.
| ($all | map(select(.ok)) | map({key: .id, value: .}) | obj) as $all_by
| [ ($br.earlier // [])[] | . as $e | $all_by[$e.id] as $d
    | {id, key, url: (.url // null), title, round, rec}
      + (if $d then ($d | clean) else {status: null, note: "", by: null, at: null, ticket: null, result: "", version: null} end) ] as $earlier
| ([ $rounds[] | select(.id == $rid) | .raw | body | select(type == "object") ] | .[0] // null) as $rdoc
| ($rdoc != null and $rdoc.done == true) as $done
| ($now | epoch) as $t
| ($br.generated_at | epoch) as $g
| ([ $mine[] | select(.ok) | .at | epoch | select(. != null) ] + (if $rdoc then [($rdoc.at | epoch) | select(. != null)] else [] end) | max) as $last
| (if $g then (($t - $g) / 3600 | floor) else null end) as $age
| (if $last then (($t - $last) / 60 | floor) else null end) as $idle_for
| (if $done then "done"
   elif $age != null and $age >= $round_hours and ($idle_for == null or $idle_for >= $idle) then "stale"
   else null end) as $closed
| [ $rows[] | select(.status != null) ] as $decided
| [ $rows[] | select(.status == null and (.note | blank | not)) ] as $noted
| {
    status: "ok",
    round_id: $rid,
    title: $br.title,
    round: {
      done: $done,
      done_at: (if $done then ($rdoc.at // null) else null end),
      done_by: (if $done and ($rdoc.by | type) == "string" then $rdoc.by else null end),
      age_hours: $age,
      last_activity_at: (if $last then ($last | todate) else null end),
      idle_minutes: $idle_for,
      closed: $closed,
      ready_to_act: ($closed != null),
      waiting: (if $closed != null then null
                else "not closed: the operator has not pressed done, and the round closes as stale at \($round_hours)h old with \($idle) minutes idle (now \($age // 0)h old)" end)
    },
    counts: {
      cards: ($rows | length),
      go: ([$rows[] | select(.status == "go")] | length),
      later: ([$rows[] | select(.status == "later")] | length),
      drop: ([$rows[] | select(.status == "drop")] | length),
      noted: ($noted | length),
      undecided: ([$rows[] | select(.status == null and (.note | blank))] | length),
      notes: ([$rows[] | select(.note | blank | not)] | length),
      against_rec: ([$decided[] | select(.status != REC_STATUS[.rec])] | length),
      done_by_claude: ([$rows[] | select(.result | is_final)] | length),
      pending: ([$rows[] | select(.result | is_pending)] | length),
      earlier_to_act: ([$earlier[] | select(.result | is_final | not)] | length)
    },
    go: [$rows[] | select(.status == "go") | .id],
    later: [$rows[] | select(.status == "later") | .id],
    drop: [$rows[] | select(.status == "drop") | .id],
    noted: [$noted[] | .id],
    undecided: [$rows[] | select(.status == null and (.note | blank)) | .id],
    to_act: [$rows[] | select((.status != null or (.note | blank | not)) and (.result | is_final | not)) | .id],
    pending: [$rows[] | select(.result | is_pending) | {id, result}],
    earlier_to_act: [$earlier[] | select(.result | is_final | not) | .id],
    earlier: $earlier,
    carry_forward: [$rows[] | select(.status == null and (.note | blank)) | .id],
    against_rec: [$decided[] | select(.status != REC_STATUS[.rec]) | {id, rec, status}],
    notes: [$rows[] | select(.note | blank | not) | {id, status, note, by}],
    general_note: $general,
    orphans: [$mine[] | select((.id | member($ids) | not) and .id != $gid) | select(.ok) | {id} + clean | del(.version)],
    other_rounds: ([$all[] | select(.id | startswith($pre) | not)] | length),
    invalid: $invalid,
    people: ([$rows[] | .by | select(. != null)] + (if $done and ($rdoc.by | type) == "string" then [$rdoc.by] else [] end) | unique),
    cards: $rows
  }
'

cmd_readback() {
  require_file --brief "$BRIEF"
  [[ -n "$DECISIONS" ]] || die "parse_args" "--decisions is required"
  validate_brief "$BRIEF" >/dev/null || die "readback" "brief fails validation; run check and fix it before reading back"
  local docs rounds out
  docs_file docs --decisions "$DECISIONS"
  if [[ -n "$ROUNDS" ]]; then docs_file rounds --rounds "$ROUNDS"; else tmpfile rounds; echo '[]' > "$rounds"; fi
  out=$(jq -cn --slurpfile b "$BRIEF" --slurpfile docsw "$docs" --slurpfile roundsw "$rounds" --arg now "$(now_iso)" \
        --argjson round_hours "${ROUND_HOURS:-24}" --argjson idle "${IDLE_MINUTES:-60}" \
        "$JQ_LIB"'($docsw[0]) as $docs | ($roundsw[0]) as $rounds | '"$READBACK" 2>&1) \
    || die "readback" "readback filter failed: $out"
  printf '%s\n' "$out"
}

# ─── deferred ────────────────────────────────────────────────────────────────

# DEFERRED(#N) markers point code at an open issue. Closing the issue strands
# them, so a close waits until none are left on the default branch. Searches
# each --repo-path at --ref (default origin/HEAD, then origin/main) without
# fetching: run `git fetch origin` first.
cmd_deferred() {
  [[ "$ISSUE" =~ ^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)#([0-9]+)$ ]] || die "parse_args" "--issue must be owner/name#N (got ${ISSUE:-nothing})"
  local owner="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" num="${BASH_REMATCH[3]}"
  [[ ${#REPO_PATHS[@]} -gt 0 ]] || die "parse_args" "--repo-path is required: repeat it for every repo the marker could be in"
  local found searched errors path ref remote this rc out
  local pats=()
  tmpfile found; tmpfile searched; tmpfile errors
  for path in "${REPO_PATHS[@]}"; do
    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
      jq -cn --arg p "$path" '{path: $p, problem: "not a git checkout"}' >> "$errors"; continue
    fi
    ref="$REF"
    if [[ -z "$ref" ]]; then
      ref=$(git -C "$path" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=""
      [[ -n "$ref" ]] || ref="origin/main"
    fi
    if ! git -C "$path" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1; then
      jq -cn --arg p "$path" --arg r "$ref" '{path: $p, problem: "ref \($r) not found: git fetch origin, or pass --ref"}' >> "$errors"; continue
    fi
    remote=$(git -C "$path" remote get-url origin 2>/dev/null || true)
    this=""
    if [[ "$remote" =~ [:/]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$ ]]; then
      this="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    fi
    pats=(-e "DEFERRED($owner/$name#$num)" -e "DEFERRED($name#$num)")
    if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$this")" == "$(tr '[:upper:]' '[:lower:]' <<<"$owner/$name")" ]]; then
      pats+=(-e "DEFERRED(#$num)")
    fi
    out=$(git -C "$path" grep -n -I -F "${pats[@]}" "$ref" -- 2>&1); rc=$?
    jq -cn --arg p "$path" --arg r "$ref" --arg repo "$this" '{path: $p, ref: $r, repo: (if $repo == "" then null else $repo end)}' >> "$searched"
    if (( rc == 0 )); then
      jq -Rc --arg p "$path" --arg r "$ref" --arg repo "$this" \
        'ltrimstr($r + ":") | capture("^(?<file>[^:]+):(?<line>[0-9]+):(?<text>.*)$")
         | {path: $p, repo: (if $repo == "" then null else $repo end), ref: $r, file, line: (.line | tonumber), text: (.text | .[0:300])}' \
        <<<"$out" >> "$found"
    elif (( rc != 1 )); then
      jq -cn --arg p "$path" --arg m "$(head -c 300 <<<"$out")" '{path: $p, problem: $m}' >> "$errors"
    fi
  done
  jq -cn --arg issue "$ISSUE" --slurpfile found "$found" --slurpfile searched "$searched" --slurpfile errors "$errors" \
    '{status: "ok", issue: $issue, count: ($found | length), clear: (($found | length) == 0 and ($errors | length) == 0),
      markers: $found, searched: $searched, errors: $errors}'
}

# ─── memory ──────────────────────────────────────────────────────────────────

# Free memory as a percentage, to gate each kickoff. Unknown means not ok:
# ask the operator before starting more sessions.
cmd_memory() {
  local min="${MIN_FREE:-20}" pct="" src=""
  if [[ -n "${BRIEF_FREE_PCT:-}" ]]; then
    pct="$BRIEF_FREE_PCT"; src="BRIEF_FREE_PCT"
  elif command -v memory_pressure >/dev/null 2>&1; then
    pct=$(memory_pressure 2>/dev/null | awk -F': *' '/free percentage/ {gsub(/%/, "", $2); print $2; exit}'); src="memory_pressure"
  elif [[ -r /proc/meminfo ]]; then
    pct=$(awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {if (t > 0) printf "%d", a * 100 / t}' /proc/meminfo); src="/proc/meminfo"
  fi
  if is_uint "$pct"; then
    jq -cn --argjson pct "$pct" --argjson min "$min" --arg src "$src" \
      '{status: "ok", free_pct: $pct, min_free: $min, ok: ($pct >= $min), source: $src}'
  else
    jq -cn --argjson min "$min" \
      '{status: "ok", free_pct: null, min_free: $min, ok: false, source: "unknown",
        message: "could not read free memory: ask the operator before kicking off more sessions"}'
  fi
}

# ─── corveil ─────────────────────────────────────────────────────────────────

# Ontology reads without CORVEIL_NO_CAPTURE=1 are recorded as the operator's
# AI chat and create Topics, so every read goes through here.
cmd_corveil() {
  local verb="${1:-}"
  [[ -n "$verb" ]] || die "parse_args" "corveil needs a verb, such as whoami or search"
  case " $CORVEIL_READ_VERBS " in
    *" $verb "*) ;;
    *) die "corveil" "brief.sh corveil runs read verbs only ($CORVEIL_READ_VERBS), not $verb" ;;
  esac
  if ! command -v "$CORVEIL_BIN" >/dev/null 2>&1; then
    jq -cn '{status: "skipped", reason: "no corveil CLI on PATH: skip the ontology step and say so in the method"}'
    exit 3
  fi
  # The env var is only the flag's default, so a caller's --no-capture=false
  # would win. Refuse any capture flag, and pass --no-capture explicitly on
  # every verb that records reads (PR #1368 review).
  local arg
  for arg in "$@"; do
    case "$arg" in
      --no-capture*|--capture*) die "corveil" "brief.sh corveil sets --no-capture itself; don't pass $arg" ;;
    esac
  done
  export CORVEIL_NO_CAPTURE=1
  shift
  case " $CORVEIL_UNCAPTURED_VERBS " in
    *" $verb "*) exec "$CORVEIL_BIN" "$verb" "$@" ;;
    *) exec "$CORVEIL_BIN" "$verb" --no-capture "$@" ;;
  esac
}

sub="${1:-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  config)   parse_args "$@"; cmd_config ;;
  fetch)    parse_args "$@"; cmd_fetch ;;
  scope)    parse_args "$@"; cmd_scope ;;
  prs)      parse_args "$@"; cmd_prs ;;
  stats)    parse_args "$@"; cmd_stats ;;
  compose)  parse_args "$@"; cmd_compose ;;
  check)    parse_args "$@"; cmd_check ;;
  build)    parse_args "$@"; cmd_build ;;
  readback) parse_args "$@"; cmd_readback ;;
  mark-read) parse_args "$@"; cmd_mark_read ;;
  deferred) parse_args "$@"; cmd_deferred ;;
  memory)   parse_args "$@"; cmd_memory ;;
  corveil)  require_jq_16; cmd_corveil "$@" ;;
  --help|-h|"") usage ;;
  *) die "parse_args" "unknown subcommand: $sub (expected config, fetch, scope, prs, stats, compose, check, build, mark-read, readback, deferred, memory or corveil)" ;;
esac
