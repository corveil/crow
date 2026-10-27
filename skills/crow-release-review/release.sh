#!/usr/bin/env bash
# crow-release-review helper (CROW-1371) — the deterministic half of
# /crow-release-review. The LLM half (studying the PRs, writing the synthesis,
# publishing the page, running the verify loop) lives in SKILL.md.
#
#   scope    --repo OWNER/NAME --path DIR [--since REV] [--target REF] --out F
#                                    the release range: last v* tag → head, merged PRs, open PRs
#   extract  --transcript F --out F  the last ```json block in a subagent transcript
#   assemble --page F --study F [--study F ...] --out F [--force]
#                                    page.json + study arrays → items.json, with ids filled in
#   ids      --items F               fill missing item, step and runbook ids in place
#   check    --items F | --study F   validate items.json, or one study file
#   build    --items F --out F [--url URL | --url-file F] [--template F]
#                                    validate, then write the page
#   readback --items F --data DIR [--repo ID]
#                                    join the notes/decisions/checks/runbook docs to the page
#   report   --items F [--data DIR] [--out F]
#                                    the page as Markdown (the no-Artifact fallback)
#
# Each subcommand prints one JSON object (report prints Markdown) and exits 0
# on success, 1 when the items fail validation, 2 on a usage or environment
# error. Rows read back from the artifact never fail readback: viewers wrote
# them, so they are reported, not trusted. Requires jq 1.6 or newer; scope also
# needs git and gh (override gh with GH_BIN; the tests do).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEMS=""
STUDY_FILES=()
PAGE_FILE=""
OUT=""
TEMPLATE="$SCRIPT_DIR/page.html"
DATA_DIR=""
FILTER_REPO=""
URL=""
URL_FILE=""
FORCE=0
REPO=""
REPO_PATH=""
SINCE=""
TARGET=""
TRANSCRIPT=""
GH_BIN="${GH_BIN:-gh}"
MERGED_LIMIT=1000   # scope: gh pr list --limit for merged PRs
LOOKUP_CAP=200      # scope: at most this many per-commit PR lookups

die() { # die <step> <message>
  jq -cn --arg step "$1" --arg msg "$2" '{status:"error", step:$step, message:$msg}'
  exit 2
}

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# Same floor as triage.sh: the filters below are written for jq 1.6.
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
      --items)      ITEMS="${2:-}"; shift 2 ;;
      --study)      STUDY_FILES+=("${2:-}"); shift 2 ;;
      --page)       PAGE_FILE="${2:-}"; shift 2 ;;
      --out)        OUT="${2:-}"; shift 2 ;;
      --template)   TEMPLATE="${2:-}"; shift 2 ;;
      --data)       DATA_DIR="${2:-}"; shift 2 ;;
      --repo)       REPO="${2:-}"; FILTER_REPO="${2:-}"; shift 2 ;;
      --url)        URL="${2:-}"; shift 2 ;;
      --url-file)   URL_FILE="${2:-}"; shift 2 ;;
      --force)      FORCE=1; shift ;;
      --path)       REPO_PATH="${2:-}"; shift 2 ;;
      --since)      SINCE="${2:-}"; shift 2 ;;
      --target)     TARGET="${2:-}"; shift 2 ;;
      --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
      --help|-h)    usage ;;
      *) die "parse_args" "unknown argument: $1" ;;
    esac
  done
  require_jq_16
}

require_items() {
  [[ -n "$ITEMS" ]] || die "parse_args" "--items is required"
  [[ -f "$ITEMS" ]] || die "parse_args" "items file not found: $ITEMS"
  jq empty "$ITEMS" 2>/dev/null || die "parse_args" "items file is not valid JSON: $ITEMS"
}

# Writes stdin to $1 through a temp file in the same directory, so a failed
# write never leaves a half-written file behind.
write_atomic() {
  local dest="$1" dir tmp
  dir=$(dirname "$dest")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.release-review.XXXXXX") || return 1
  if cat > "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
  rm -f "$tmp"
  return 1
}

# ---------------------------------------------------------------------------
# Validation. Ids must satisfy the artifact db's doc-id grammar, because item
# ids key `notes` and `decisions`, step ids key `checks`, and runbook ids key
# `runbook`. Keyword field names (label) are quoted for jq 1.6.
# shellcheck disable=SC2016  # $vars below are jq's, not the shell's
COMMON='
def RISKS: ["high","medium","low"];
def NEEDS: ["agent","agent+aws","agent+staff","human"];
def PROGRESS: ["done","running","waiting","held"];
def nonempty: type == "string" and length > 0;
def member($xs): . as $v | $xs | map(. == $v) | any;
def is_url: type == "string" and test("^https?://[^[:space:]]+$");
def bad_id: (type != "string") or (test("^[A-Za-z0-9_.~:@+-]{1,200}$") | not) or . == "." or . == "..";
def id_msg: "id \(tojson) may use only letters, digits and _ - . ~ : @ + (1-200 characters)";
def strfield($k):
  if (.[$k] // null) == null or (.[$k] | type) == "string" then [] else ["\($k) must be a string"] end;
def strfields($ks): . as $o | [$ks[] | . as $k | $o | strfield($k)[]];
def strlist($k):
  if (.[$k] // null) == null then []
  elif (.[$k] | type) == "array" and (.[$k] | all(type == "string")) then []
  else ["\($k) must be an array of strings"] end;
def strlists($ks): . as $o | [$ks[] | . as $k | $o | strlist($k)[]];
def reqstr($k; $why): if (.[$k] | nonempty) then [] else ["\($k) is required\($why)"] end;
def reqlist($k; $why):
  if (.[$k] | type) == "array" and (.[$k] | length) > 0 and (.[$k] | all(nonempty)) then []
  else ["\($k) is required: \($why)"] end;
def urlfield($k): if (.[$k] // null) == null or (.[$k] | is_url) then [] else ["\($k) must be an http(s) URL"] end;
def boolfield($k): if (.[$k] | type) == "null" or (.[$k] | type) == "boolean" then [] else ["\($k) must be true or false"] end;
def where_($what; $i): "\($what) \($i + 1)" + (if (.id | type) == "string" then " (\(.id))" else "" end);
def list_of($k): if (.[$k] | type) == "array" then .[$k] else [] end;
'

# shellcheck disable=SC2016
ITEM_DEFS='
def step_errors($iid; $strict):
  (if (.id // null) == null then (if $strict then ["id is missing; run release.sh ids to fill it"] else [] end)
   elif (.id | bad_id) then [.id | id_msg]
   elif ($iid | type) == "string" and ((.id | startswith($iid + "-")) | not) then
     ["id \(.id | tojson) must start with \(($iid + "-") | tojson): step ids are {item id}-{n}"]
   else [] end)
  + reqstr("step"; ": a short name for the check")
  + reqstr("how"; ": the exact command or action")
  + reqstr("expect"; ": what passing looks like")
  + (if (.needs | type) == "string" and (.needs | member(NEEDS)) then []
     else ["needs must be one of \(NEEDS | join(", "))"] end)
  + strfields(["baseline", "when"])
  + boolfield("optional");

def item_errors($rids; $strict):
  (if (.id // null) == null then (if $strict then ["id is missing; run release.sh ids to fill it (needs a pr)"] else [] end)
   elif (.id | bad_id) then [.id | id_msg]
   else [] end)
  + (if $strict then
       (if (.repo | type) == "string" and (.repo | member($rids)) then []
        else ["repo must be one of \($rids | join(", ")) (a repos[].id)"] end)
     else reqstr("repo"; ": the repos[].id of the tab it goes on") end)
  + (if (."label" // null) == null then []
     elif (."label" | bad_id) then ["label \(."label" | tojson) may use only letters, digits and _ - . ~ : @ +"]
     else [] end)
  + (if (.pr // null) == null or ((.pr | type) == "number" and .pr >= 1 and (.pr | floor) == .pr) then []
     else ["pr must be a positive whole number"] end)
  + reqstr("title"; "")
  + reqstr("audience"; ": who notices the change")
  + reqstr("category"; ": a short tag such as security, billing, infra, docs")
  + reqstr("before"; ": what users see today, in plain language")
  + reqstr("after"; ": what they see after the release")
  + reqstr("fixes"; ": what it fixes, in plain language")
  + reqlist("pros"; "at least one")
  + reqlist("cons"; "at least one (\"None found\" is an answer)")
  + (if (.risk_level | type) == "string" and (.risk_level | member(RISKS)) then []
     else ["risk_level must be one of \(RISKS | join(", "))"] end)
  + reqstr("risk"; ": the deploy risk, technical and in plain language")
  + strfields(["blocker"])
  + strlists(["deploy_prereqs", "questions"])
  + urlfield("url")
  + boolfield("not_merged")
  + (.id as $iid
     | if (.test_steps // null) == null then []
       elif (.test_steps | type) != "array" then ["test_steps must be an array"]
       else [.test_steps | to_entries[] | .key as $j | .value
             | if type != "object" then "step \($j + 1) must be an object"
               else where_("step"; $j) as $w | step_errors($iid; $strict)[] | "\($w): \(.)" end]
       end);

def items_errors($items; $rids; $strict):
  [$items | to_entries[] | .key as $i | .value
   | if type != "object" then "item \($i + 1) must be an object"
     else where_("item"; $i) as $w | item_errors($rids; $strict)[] | "\($w): \(.)" end]
  + [$items | map(select(type == "object") | .id | select(type == "string")) | group_by(.) | .[] | select(length > 1)
     | "item id \(.[0] | tojson) is used more than once; each id keys one note and one decision"]
  + [[$items[] | select(type == "object") | list_of("test_steps")[] | select(type == "object") | .id | select(type == "string")]
     | group_by(.) | .[] | select(length > 1)
     | "step id \(.[0] | tojson) is used more than once; each id keys one check"];
'

# shellcheck disable=SC2016
VALIDATE="$COMMON$ITEM_DEFS"'
def entry_errors($what; $req; $opt):
  [to_entries[] | .key as $i | .value
   | if type != "object" then "\($what) \($i + 1) must be an object"
     else . as $e | ([$req[] | . as $k | $e | reqstr($k; "")[]] + ($e | strfields($opt)) + ($e | urlfield("url")))[]
          | "\($what) \($i + 1): \(.)" end];

def page_errors:
  . as $doc
  | (if (.repos | type) == "array" then .repos else [] end) as $repos
  | [$repos[] | select(type == "object") | .id | select(type == "string")] as $rids
  | (if (.items | type) == "array" then .items else [] end) as $items
  | reqstr("title"; ": the page name, 2-6 words (\"Acme Release Review\")")
  + strfields(["heading", "context", "slug"])
  + (if (.generated // null) == null or ((.generated | type) == "string" and (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}"))) then []
     else ["generated must be a date, YYYY-MM-DD"] end)
  + urlfield("url")
  + strlists(["top_risks", "user_visible", "cleared", "deploy_order", "ordering_risks", "runbook_intro", "agent_notes", "method"])
  + (if (.repos | type) == "array" and (.repos | length) > 0 then [] else ["repos must be a non-empty array: one entry per repo in the release"] end)
  + [$repos | to_entries[] | .key as $i | .value
     | if type != "object" then "repo \($i + 1) must be an object"
       else where_("repo"; $i) as $w
            | ((if (.id // null) == null then ["id is required: a short label such as api, the tab and id prefix"]
                elif (.id | bad_id) then [.id | id_msg] else [] end)
               + reqstr("name"; ": the tab name")
               + reqstr("from"; ": the last release, such as v1.4.0")
               + reqstr("to"; ": what this release ships, such as v1.5.0")
               + strfields(["repo", "head", "count_label", "live"])
               + strlists(["how"]))[]
            | "\($w): \(.)" end]
  + [$rids | group_by(.) | .[] | select(length > 1) | "repo id \(.[0] | tojson) is used more than once"]
  + (if (.verdict | type) != "object" then ["verdict is required: {level, headline, paragraphs}"]
     else [.verdict
           | (if (.level | type) == "string" and (.level | member(RISKS)) then [] else ["level must be one of \(RISKS | join(", "))"] end)
             + reqstr("headline"; ": one line, what to ship and what to hold")
             + reqlist("paragraphs"; "the reasoning, one string per paragraph")
           | .[] | "verdict: \(.)"] end)
  + (if (.blockers // null) == null then [] elif (.blockers | type) != "array" then ["blockers must be an array"]
     else (.blockers | entry_errors("blocker"; ["title", "why"]; ["action"]))
          + [.blockers[] | select(type == "object") | boolfield("soft")[] | "blocker: \(.)"] end)
  + (if (.findings // null) == null then [] elif (.findings | type) != "array" then ["findings must be an array"]
     else (.findings | entry_errors("finding"; ["title", "why"]; ["tag", "action"])) end)
  + (if (.progress // null) == null then [] elif (.progress | type) != "array" then ["progress must be an array"]
     else (.progress | entry_errors("progress"; ["label"]; ["text"]))
          + [.progress | to_entries[] | select(.value | type == "object") | .key as $i | .value
             | select((.state | type) != "string" or (.state | member(PROGRESS) | not))
             | "progress \($i + 1): state must be one of \(PROGRESS | join(", "))"] end)
  + (if (.rollback // null) == null then [] elif (.rollback | type) != "array" then ["rollback must be an array"]
     else (.rollback | entry_errors("rollback"; ["text"]; ["repo", "cmd"])) end)
  + (if (.runbook // null) == null then [] elif (.runbook | type) != "array" then ["runbook must be an array"]
     else (.runbook | entry_errors("runbook step"; ["phase", "action"]; ["why", "cmd"]))
          + [.runbook | to_entries[] | select(.value | type == "object") | .key as $i | .value
             | if (.id // null) == null then "runbook step \($i + 1): id is missing; run release.sh ids to fill it"
               elif (.id | type) != "string" or (.id | test("^rb-[0-9]{2,}$") | not) then
                 "runbook step \($i + 1): id \(.id | tojson) must look like rb-01 (rb- and at least two digits)"
               else empty end]
          + [[.runbook[] | select(type == "object") | .id | select(type == "string")] | group_by(.) | .[] | select(length > 1)
             | "runbook id \(.[0] | tojson) is used more than once; each id keys one tick"] end)
  + (if (.items | type) == "array" and (.items | length) > 0 then [] else ["items must be a non-empty array"] end)
  + items_errors($items; $rids; true);

def summary:
  (if (.items | type) == "array" then [.items[] | select(type == "object")] else [] end) as $items
  | [$items[] | list_of("test_steps")[] | select(type == "object")] as $steps
  | { title: .title,
      repos: [(.repos // [])[] | select(type == "object") | .id as $r
              | {id: $r, items: ([$items[] | select(.repo == $r)] | length),
                 steps: ([$items[] | select(.repo == $r) | list_of("test_steps")[]] | length)}],
      items: ($items | length),
      steps: ($steps | length),
      risk: (reduce RISKS[] as $l ({}; .[$l] = ([$items[] | select(.risk_level == $l)] | length))),
      needs: (reduce NEEDS[] as $n ({}; .[$n] = ([$steps[] | select(.needs == $n)] | length))),
      runbook: (list_of("runbook") | length) };

def warnings:
  (if (.items | type) == "array" then [.items[] | select(type == "object")] else [] end) as $items
  | [(.repos // [])[] | select(type == "object") | .id as $r
     | select(([$items[] | select(.repo == $r)] | length) == 0)
     | "repo \($r | tojson) has no changes and its tab will be empty"]
  + (if (list_of("runbook") | length) == 0 then ["the page has no runbook"] else [] end)
  + [$items[] | select(.risk_level == "high" and (list_of("test_steps") | length) == 0)
     | "item \(.id // .title | tojson) is high risk but has no test steps"];

if type != "object" then {errors: ["items file must be a JSON object"], warnings: [], summary: {}}
else {errors: page_errors, warnings: warnings, summary: summary} end
'

# shellcheck disable=SC2016
VALIDATE_STUDY="$COMMON$ITEM_DEFS"'
(if type == "array" then . elif type == "object" and (.items | type) == "array" then .items else null end) as $items
| if $items == null then {errors: ["a study file is an array of items, or {\"items\": [...]}"], summary: {}}
  else {errors: items_errors($items; []; false),
        summary: {items: ($items | length),
                  steps: ([$items[] | select(type == "object") | list_of("test_steps")[]] | length)}} end
'

CHECK_RESULT=""

# Large JSON goes to jq through files, not --argjson: a big release's docs or
# PR lists could pass the argument-length limit.
WORK=""
work_dir() {
  if [[ -z "$WORK" ]]; then
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/release-review.XXXXXX") || die "preflight" "cannot create a temp directory"
    trap 'rm -rf "$WORK"' EXIT
  fi
}

# Prints the errors as JSON and returns 1 when the items fail validation;
# leaves the result in CHECK_RESULT otherwise.
validate() { # validate <file>
  local result
  result=$(jq -c "$VALIDATE" "$1" 2>&1) || die "validate" "validation filter failed: $result"
  if [[ "$(jq -r '.errors | length' <<<"$result")" != "0" ]]; then
    jq -c '{status:"error", step:"validate", errors, warnings}' <<<"$result"
    return 1
  fi
  CHECK_RESULT="$result"
  return 0
}

cmd_check() {
  if [[ ${#STUDY_FILES[@]} -gt 0 ]]; then
    [[ -z "$ITEMS" ]] || die "parse_args" "pass --items or --study, not both"
    local f="${STUDY_FILES[0]}" result
    [[ ${#STUDY_FILES[@]} -eq 1 ]] || die "parse_args" "check takes one --study file at a time"
    [[ -f "$f" ]] || die "parse_args" "study file not found: $f"
    jq empty "$f" 2>/dev/null || die "parse_args" "study file is not valid JSON: $f"
    result=$(jq -c "$VALIDATE_STUDY" "$f" 2>&1) || die "validate" "validation filter failed: $result"
    if [[ "$(jq -r '.errors | length' <<<"$result")" != "0" ]]; then
      jq -c '{status:"error", step:"validate", errors}' <<<"$result"
      exit 1
    fi
    jq -c '{status:"ok"} + .summary' <<<"$result"
    return
  fi
  require_items
  validate "$ITEMS" || exit 1
  jq -c '{status:"ok"} + .summary + {warnings}' <<<"$CHECK_RESULT"
}

# ---------------------------------------------------------------------------
# Id filling. An item gets {label or repo}-{pr}; a step gets {item id}-{n}, n
# one past the highest number already used in that item; a runbook entry gets
# rb-NN, one past the highest in the runbook. An id that is already there is
# never changed, so ids stay stable across republishes.
# shellcheck disable=SC2016
FILL_IDS='
def num_after($prefix):
  if type == "string" and startswith($prefix) and (ltrimstr($prefix) | test("^[0-9]+$"))
  then ltrimstr($prefix) | tonumber else 0 end;
def pad2: if . < 10 then "0\(.)" else tostring end;
def missing: (.id // null) == null;
def fill_steps:
  .id as $iid
  | if (.test_steps | type) != "array" then .
    else (reduce .test_steps[] as $s (0; [., ($s | if type == "object" then .id | num_after($iid + "-") else 0 end)] | max)) as $top
         | .test_steps |= (reduce .[] as $s ({n: $top, out: []};
             if ($s | type) == "object" and ($s | missing)
             then .n += 1 | .n as $n | .out += [{id: "\($iid)-\($n)"} + ($s | del(.id))]
             else .out += [$s] end) | .out)
    end;
def fill_item:
  if type != "object" then .
  else (if missing and (.pr | type) == "number" and ((."label" // .repo) | type) == "string"
        then ({id: "\(."label" // .repo)-\(.pr)"} + del(.id)) else . end)
       | if (.id | type) == "string" then fill_steps else . end
  end;
def count_missing:
  { items: ([(.items // [])[] | select(type == "object") | select(missing)] | length),
    steps: ([(.items // [])[] | select(type == "object") | (.test_steps // [])[] | select(type == "object") | select(missing)] | length),
    runbook: ([(.runbook // [])[] | select(type == "object") | select(missing)] | length) };
def fill:
  (if (.items | type) == "array" then .items |= map(fill_item) else . end)
  | if (.runbook | type) == "array" then
      (reduce .runbook[] as $r (0; [., ($r | if type == "object" then .id | num_after("rb-") else 0 end)] | max)) as $top
      | .runbook |= (reduce .[] as $r ({n: $top, out: []};
          if ($r | type) == "object" and ($r | missing)
          then .n += 1 | .n as $n | .out += [{id: "rb-\($n | pad2)"} + ($r | del(.id))]
          else .out += [$r] end) | .out)
    else . end;
count_missing as $before
| fill
| count_missing as $after
| {doc: ., assigned: {items: ($before.items - $after.items), steps: ($before.steps - $after.steps), runbook: ($before.runbook - $after.runbook)},
   unassigned: [(.items // [])[] | select(type == "object") | select(missing) | (.title // "an untitled item")]}
'

# Fills ids into $1, rewrites it, and prints the result. Exits 1 when the
# filled file still fails validation.
fill_and_report() { # fill_and_report <items-file> <step>
  local file="$1" step="$2" res
  res=$(jq -c "$FILL_IDS" "$file" 2>&1) || die "$step" "could not fill ids: $res"
  jq '.doc' <<<"$res" | write_atomic "$file" || die "$step" "could not write $file"
  local assigned unassigned
  assigned=$(jq -c '.assigned' <<<"$res")
  unassigned=$(jq -c '.unassigned' <<<"$res")
  if ! validate "$file" >/dev/null; then
    jq -c --argjson a "$assigned" --argjson u "$unassigned" --arg out "$file" '
      {status:"error", step:"validate", out:$out, assigned:$a,
       errors: (.errors + [$u[] | "item \(tojson) has no id and no pr: give it an id such as {repo}-{short-name}"])}' \
      <<<"$(jq -c "$VALIDATE" "$file")"
    exit 1
  fi
  jq -c --argjson a "$assigned" --arg out "$file" '{status:"ok", out:$out, assigned:$a} + .summary + {warnings}' <<<"$CHECK_RESULT"
}

cmd_ids() {
  require_items
  fill_and_report "$ITEMS" "ids"
}

cmd_assemble() {
  [[ -n "$PAGE_FILE" ]] || die "parse_args" "--page is required: the synthesis (everything but the items)"
  [[ -f "$PAGE_FILE" ]] || die "parse_args" "page file not found: $PAGE_FILE"
  [[ ${#STUDY_FILES[@]} -gt 0 ]] || die "parse_args" "at least one --study file is required"
  [[ -n "$OUT" ]] || die "parse_args" "--out is required"
  if [[ -e "$OUT" && $FORCE -ne 1 ]]; then
    die "assemble" "$OUT already exists. Its ids are the page's db keys: edit it and run ids instead, or pass --force before the first publish"
  fi
  jq -e 'type == "object" and ((has("items") | not) or (.items == []))' "$PAGE_FILE" >/dev/null 2>&1 \
    || die "assemble" "page file must be a JSON object without items: $PAGE_FILE"
  local f
  for f in "${STUDY_FILES[@]}"; do
    [[ -f "$f" ]] || die "parse_args" "study file not found: $f"
    jq -e 'type == "array" or (type == "object" and (.items | type) == "array")' "$f" >/dev/null 2>&1 \
      || die "assemble" "study file must be an array of items, or {\"items\": [...]}: $f"
  done
  jq -s '.[0] + {items: ([.[1:][] | if type == "array" then . else .items end] | add // [])}' \
    "$PAGE_FILE" "${STUDY_FILES[@]}" | write_atomic "$OUT" || die "assemble" "could not write $OUT"
  fill_and_report "$OUT" "assemble"
}

# ---------------------------------------------------------------------------

cmd_build() {
  require_items
  [[ -n "$OUT" ]] || die "parse_args" "--out is required"
  [[ -f "$TEMPLATE" ]] || die "build" "page template not found: $TEMPLATE"
  local n marker
  for marker in "__RELEASE_DATA__" "<title>__RELEASE_TITLE__</title>"; do
    n=$(grep -cxF -- "$marker" "$TEMPLATE")
    [[ "$n" == "1" ]] || die "build" "template must have exactly one line \"$marker\" (found $n): $TEMPLATE"
  done
  if [[ -n "$URL_FILE" ]]; then
    [[ -z "$URL" ]] || die "parse_args" "pass --url or --url-file, not both"
    # A missing file is the first publish: there is no URL yet.
    if [[ -f "$URL_FILE" ]]; then URL=$(head -n 1 "$URL_FILE" | tr -d '[:space:]'); fi
  fi
  if [[ -n "$URL" && ! "$URL" =~ ^https?://[^[:space:]]+$ ]]; then
    die "parse_args" "--url must be an http(s) URL: $URL"
  fi
  validate "$ITEMS" || exit 1

  # Every `<` in the JSON becomes <, so no text can close the data
  # <script> block (`</script>`) or open a comment (`<!--`); JSON.parse
  # turns it back into `<`.
  local data title
  data=$(jq -c --arg url "$URL" 'if $url != "" then .url = $url else . end' "$ITEMS" | sed 's/</\\u003c/g') \
    || die "build" "could not serialize $ITEMS"
  title=$(jq -r '.title | @html' "$ITEMS") || die "build" "could not read the title"

  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "__RELEASE_DATA__") printf '%s\n' "$data" ;;
        "<title>__RELEASE_TITLE__</title>") printf '<title>%s</title>\n' "$title" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$TEMPLATE"
  } | write_atomic "$OUT" || die "build" "could not write the page to $OUT"

  jq -c --arg out "$OUT" --arg url "$URL" --argjson bytes "$(wc -c < "$OUT" | tr -d ' ')" \
    '{status:"ok", out:$out, url:(if $url == "" then null else $url end), bytes:$bytes} + .summary + {warnings}' <<<"$CHECK_RESULT"
}

# ---------------------------------------------------------------------------
# Read-back. The four collections arrive as `ArtifactData list` wrote them
# with out_dir (<dir>/<collection>/<doc_id>.json, bare bodies), or as one
# JSON file per collection (an array of docs, an {id: doc} map, or the inline
# list output: one {id, data, version} per line).

load_docs() { # load_docs <path> → [{id, raw, unreadable?}]
  local path="$1"
  if [[ -z "$path" || ! -e "$path" ]]; then
    printf '[]'
  elif [[ -d "$path" ]]; then
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
  else
    jq -cs '
      def doc: if type == "object" then {id: ((.id // .doc_id // .docId) | if type == "string" then . else null end), raw: .}
               else {id: null, raw: .} end;
      if length == 1 and (.[0] | type) == "array" then .[0] | map(doc)
      elif length == 1 and (.[0] | type) == "object" and ((.[0] | has("id") and has("data")) | not) then
        .[0] | to_entries | map({id: .key, raw: .value})
      else map(doc) end' "$path" 2>/dev/null \
      || die "readback" "not JSON (an array, an {id: doc} map, or one doc per line): $path"
  fi
}

# shellcheck disable=SC2016
READBACK="$COMMON"'
def CHECK_STATUSES: ["pass","fail",""];
def DECISIONS: ["ship","question","hold",""];
def body: if type == "object" and (.data | type) == "object" then .data else . end;
def version: if type == "object" and (.version | type) == "number" then .version else null end;
def str_or($d): if type == "string" then . else $d end;
def norm($c):
  [ $docs[$c][] | select(.id != null) | . as $d | ($d.raw | body) as $b
    | { id: $d.id, version: ($d.raw | version), unreadable: ($d.unreadable // false),
        ok: ($b | type == "object"), b: (if ($b | type) == "object" then $b else {} end) } ];
def bad($c; $f; $v; $p): {collection: $c, id, field: $f, value: $v, problem: $p};
def shape($c):
  if .unreadable then bad($c; "doc"; null; "file is not valid JSON")
  elif (.ok | not) then bad($c; "doc"; null; "doc is not an object")
  else empty end;
def by_id: reduce .[] as $d ({}; .[$d.id] = $d);
def owner: if (.by | type) != "string" or .by == "" then null
           elif (.by | ascii_downcase | startswith("agent")) then "agent" else "viewer" end;

($items[0]) as $page
| [$page.repos[] | .id] as $repo_ids
| [ $page.items[] | . as $it | list_of("test_steps")[]
    | { id, item: $it.id, repo: $it.repo, step, how, expect, needs,
        when: (.when // null), baseline: (.baseline // null), optional: (.optional == true) } ] as $steps
| ($steps | map(.id)) as $sids
| ($page.items | map(.id)) as $iids
| ($page | list_of("runbook") | map(.id)) as $rbids
| (norm("checks")) as $chk
| (norm("decisions")) as $dec
| (norm("notes")) as $nts
| (norm("runbook")) as $rbk
| def clean_check:
    { status: (.b.status | if type == "string" and member(CHECK_STATUSES) then . else "" end),
      note: (.b.note | str_or("")), by: (.b.by | str_or(null)), at: (.b.at | str_or(null)), version };
  def clean_decision: { value: (.b.value | if type == "string" and member(DECISIONS) then . else "" end), at: (.b.at | str_or(null)), version };
  def clean_note: { text: (.b.text | str_or("")), at: (.b.at | str_or(null)), version };
  def clean_runbook: { done: (.b.done == true), at: (.b.at | str_or(null)), by: (.b.by | str_or(null)), version };
  ($chk | by_id) as $cmap
| ($dec | by_id) as $dmap
| ($nts | by_id) as $nmap
| ($rbk | by_id) as $rmap
| [ ($chk[] | shape("checks")),
    ($chk[] | select(.ok) | select(.b.status != null and ((.b.status | type) != "string" or (.b.status | member(CHECK_STATUSES) | not)))
     | bad("checks"; "status"; .b.status; "not pass, fail or empty; read as not run")),
    ($chk[] | select(.ok) | select(.b.note != null and (.b.note | type) != "string") | bad("checks"; "note"; .b.note; "not a string; ignored")),
    ($chk[] | select(.ok) | select(.b.by != null and (.b.by | type) != "string") | bad("checks"; "by"; .b.by; "not a string; ignored")),
    ($dec[] | shape("decisions")),
    ($dec[] | select(.ok) | select(.b.value != null and ((.b.value | type) != "string" or (.b.value | member(DECISIONS) | not)))
     | bad("decisions"; "value"; .b.value; "not ship, question, hold or empty; read as no decision")),
    ($nts[] | shape("notes")),
    ($nts[] | select(.ok) | select(.b.text != null and (.b.text | type) != "string") | bad("notes"; "text"; .b.text; "not a string; ignored")),
    ($rbk[] | shape("runbook")),
    ($rbk[] | select(.ok) | select(.b.done != null and (.b.done | type) != "boolean") | bad("runbook"; "done"; .b.done; "not true or false; read as not done"))
  ] as $invalid
| [ $steps[] | . as $s
    | ($cmap[$s.id] // null) as $d
    | $s + (if $d != null and $d.ok then ($d | clean_check) + {exists: true}
            else {status: "", note: "", by: null, at: null, version: ($d.version // null), exists: ($d != null)} end)
    | . + {owner: owner}
    | . + {agent_may_write: ((.exists | not) or .owner == "agent" or (.status == "" and .note == ""))}
    # How Claude records a result here: set creates (no pin), update needs
    # if_version, leave means a person set it. out_dir files carry no version,
    # so an update with version null takes its pin from the list result.
    | . + {write: (if (.exists | not) then "set" elif .agent_may_write then "update" else "leave" end)} ] as $rows
| def in_repo: if $repo == "" then true else .repo == $repo end;
  def brief: {id, item, repo, step, needs, status, note, by, at, version, owner, write};
  [ $page.items[] | . as $it
    | ($dmap[$it.id] // null) as $d | ($nmap[$it.id] // null) as $n
    | [$rows[] | select(.item == $it.id)] as $mine
    | { id: $it.id, repo: $it.repo, pr: ($it.pr // null), title: $it.title, risk_level: $it.risk_level,
        decision: (if $d != null and $d.ok then ($d | clean_decision | .value) else "" end),
        decision_version: ($d.version // null),
        note: (if $n != null and $n.ok then ($n | clean_note | .text) else "" end),
        note_at: (if $n != null and $n.ok then ($n | clean_note | .at) else null end),
        pass: ([$mine[] | select(.status == "pass")] | length),
        fail: ([$mine[] | select(.status == "fail")] | length),
        pending: ([$mine[] | select(.status == "")] | length) } ] as $irows
| [ $page | list_of("runbook")[] | . as $r | ($rmap[$r.id] // null) as $d
    | {id: $r.id, phase: $r.phase, action: $r.action}
      + (if $d != null and $d.ok then ($d | clean_runbook) else {done: false, at: null, by: null, version: ($d.version // null)} end) ] as $rb
| {
    status: "ok",
    title: $page.title,
    url: ($page.url // null),
    repo: (if $repo == "" then null else $repo end),
    counts: {
      items: ($irows | length),
      steps: ($rows | length),
      pass: ([$rows[] | select(.status == "pass")] | length),
      fail: ([$rows[] | select(.status == "fail")] | length),
      pending: ([$rows[] | select(.status == "")] | length),
      noted: ([$rows[] | select(.status == "" and .note != "")] | length),
      set_by_people: ([$rows[] | select(.owner == "viewer" and .status != "")] | length),
      ship: ([$irows[] | select(.decision == "ship")] | length),
      question: ([$irows[] | select(.decision == "question")] | length),
      hold: ([$irows[] | select(.decision == "hold")] | length),
      undecided: ([$irows[] | select(.decision == "")] | length),
      notes: ([$irows[] | select(.note != "")] | length),
      runbook_done: ([$rb[] | select(.done)] | length),
      runbook_total: ($rb | length)
    },
    repos: [ $page.repos[] | .id as $r | [$rows[] | select(.repo == $r)] as $rs | [$irows[] | select(.repo == $r)] as $is
             | {id: $r, name, items: ($is | length), steps: ($rs | length),
                pass: ([$rs[] | select(.status == "pass")] | length),
                fail: ([$rs[] | select(.status == "fail")] | length),
                pending: ([$rs[] | select(.status == "")] | length),
                hold: ([$is[] | select(.decision == "hold")] | length)} ],
    failed: [ $rows[] | select(.status == "fail") | brief ],
    passed: [ $rows[] | select(.status == "pass") | brief ],
    to_run: [ $rows[] | select(in_repo) | select(.status == "" and (.needs == "agent" or .needs == "agent+aws") and (.optional | not))
              | {id, item, repo, step, how, expect, needs, when, baseline, note, exists, version, agent_may_write, write} ],
    pins_needed: [ $rows[] | select(in_repo) | select(.write == "update" and .version == null) | {collection: "checks", id} ],
    for_people: [ $rows[] | select(in_repo) | select(.status == "" and (.needs == "human" or .needs == "agent+staff")) | {id, item, repo, step, needs, when} ],
    baselines_needed: [ $rows[] | select(in_repo) | select(.baseline != null and .status == "" and .note == "") | {id, item, repo, step, baseline, needs} ],
    time_gated: [ $rows[] | select(in_repo) | select(.when != null and .status == "") | {id, item, repo, step, when, needs} ],
    decisions: {
      ship: [$irows[] | select(.decision == "ship") | .id],
      question: [$irows[] | select(.decision == "question") | .id],
      hold: [$irows[] | select(.decision == "hold") | .id],
      undecided: [$irows[] | select(.decision == "") | .id]
    },
    notes: [ $irows[] | select(.note != "") | {id, repo, title, decision, text: .note, at: .note_at} ],
    runbook: {
      done: ([$rb[] | select(.done)] | length),
      total: ($rb | length),
      next: ([$rb[] | select(.done | not) | {id, phase, action}] | first // null),
      steps: $rb
    },
    orphans: (
      [ $chk[] | select(.ok) | select(.id | member($sids) | not) | {collection: "checks", id} + (clean_check | del(.version)) ]
      + [ $dec[] | select(.ok) | select(.id | member($iids) | not) | {collection: "decisions", id} + (clean_decision | del(.version)) ]
      + [ $nts[] | select(.ok) | select(.id | member($iids) | not) | {collection: "notes", id} + (clean_note | del(.version)) ]
      + [ $rbk[] | select(.ok) | select(.id | member($rbids) | not) | {collection: "runbook", id} + (clean_runbook | del(.version)) ]
    ),
    invalid: $invalid,
    items: $irows,
    steps: [ $rows[] | brief ]
  }
'

# Runs READBACK over $DATA_DIR (or an empty set) and prints the result.
readback_json() {
  local d chk dec nts rbk
  d="$DATA_DIR"
  chk=$(load_docs "${d:+$d/checks}") || { printf '%s\n' "$chk"; exit 2; }
  dec=$(load_docs "${d:+$d/decisions}") || { printf '%s\n' "$dec"; exit 2; }
  nts=$(load_docs "${d:+$d/notes}") || { printf '%s\n' "$nts"; exit 2; }
  rbk=$(load_docs "${d:+$d/runbook}") || { printf '%s\n' "$rbk"; exit 2; }
  local out
  work_dir
  printf '%s\n' "$chk" > "$WORK/checks.json"
  printf '%s\n' "$dec" > "$WORK/decisions.json"
  printf '%s\n' "$nts" > "$WORK/notes.json"
  printf '%s\n' "$rbk" > "$WORK/runbook.json"
  if ! jq -cn --slurpfile c "$WORK/checks.json" --slurpfile d "$WORK/decisions.json" \
         --slurpfile n "$WORK/notes.json" --slurpfile r "$WORK/runbook.json" \
         '{checks: $c[0], decisions: $d[0], notes: $n[0], runbook: $r[0]}' > "$WORK/docs.json" 2>/dev/null; then
    die "readback" "could not read the docs in $DATA_DIR"
  fi
  out=$(jq -cn --slurpfile items "$ITEMS" --slurpfile docs_ "$WORK/docs.json" --arg repo "$FILTER_REPO" \
          '$docs_[0] as $docs | '"$READBACK" 2>&1) \
    || die "readback" "readback filter failed: $out"
  printf '%s\n' "$out"
}

check_data_dir() {
  [[ -n "$DATA_DIR" ]] || return 0
  [[ -d "$DATA_DIR" ]] || die "parse_args" "data directory not found: $DATA_DIR"
  local c found=0
  for c in checks decisions notes runbook; do [[ -e "$DATA_DIR/$c" ]] && found=1; done
  # An empty directory is a fresh page with nothing saved yet; anything else
  # that has none of the four collections is probably the wrong directory.
  if [[ $found -eq 0 && -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    die "parse_args" "$DATA_DIR has none of checks/, decisions/, notes/ or runbook/: pass the out_dir you gave ArtifactData list"
  fi
}

cmd_readback() {
  require_items
  [[ -n "$DATA_DIR" ]] || die "parse_args" "--data is required: the out_dir ArtifactData list wrote to"
  check_data_dir
  validate "$ITEMS" >/dev/null || die "readback" "items file fails validation; run check and fix it before reading back"
  if [[ -n "$FILTER_REPO" ]]; then
    jq -e --arg r "$FILTER_REPO" '[.repos[].id | select(. == $r)] | length > 0' "$ITEMS" >/dev/null \
      || die "parse_args" "--repo $FILTER_REPO is not one of the page's repos[].id"
  fi
  readback_json
}

# ---------------------------------------------------------------------------
# The Markdown report: the same content as the page, for a Manager without
# the Artifact tool. With --data it carries the saved state too.
# shellcheck disable=SC2016
REPORT='
def RISK_WORD: {"high": "High", "medium": "Medium", "low": "Low"};
def STATE_WORD: {"done": "Done", "running": "In progress", "waiting": "Waiting", "held": "Held"};
def DECISION_WORD: {"ship": "OK to ship", "question": "Question", "hold": "Hold"};
def list_of($k): if (.[$k] | type) == "array" then .[$k] else [] end;
def oneline: tostring | gsub("[\r\n]+"; " ");
def bullets: map("- " + oneline);
def section($h; $lines): if ($lines | length) == 0 then [] else ["", "## " + $h, ""] + $lines end;
def link: if (.url // null) != null then " (" + .url + ")" else "" end;
def fence($ind; $s): (["```"] + ($s | split("\n")) + ["```"]) | map($ind + .);

($items[0]) as $p
| $state as $st
| (reduce $st.steps[] as $s ({}; .[$s.id] = $s)) as $sx
| (reduce $st.items[] as $i ({}; .[$i.id] = $i)) as $ix
| (reduce $st.runbook.steps[] as $r ({}; .[$r.id] = $r)) as $rx
| def ref: (if (."label" // null) != null then ."label" else .repo end) + (if (.pr // null) != null then " #\(.pr)" else "" end);
  def step_line:
    ($sx[.id] // {status: "", note: ""}) as $s
    | ["- [" + (if $s.status == "pass" then "x" else " " end) + "] **" + (.step | oneline) + "** (`" + .needs + "`, `" + .id + "`)"
        + (if $s.status == "fail" then " — **FAILED**" else "" end)
        + (if .optional == true then " — optional" else "" end),
       "  How: " + (.how | oneline),
       "  Expect: " + (.expect | oneline)]
    + (if (.baseline // null) != null then ["  Before the deploy, capture: " + (.baseline | oneline)] else [] end)
    + (if (.when // null) != null then ["  When: " + (.when | oneline)] else [] end)
    + (if $s.note != "" then ["  " + (if $s.status == "" then "Note" else "Evidence" end) + (if $s.by == "agent" then " (agent)" else "" end) + ": " + ($s.note | oneline)] else [] end);
  def item_md:
    ($ix[.id] // {decision: "", note: ""}) as $i
    | ["", "### " + ref + ": " + (.title | oneline),
       "",
       "**" + RISK_WORD[.risk_level] + " risk** · " + (.category | oneline)
         + (if .not_merged == true then " · not merged" else "" end)
         + (if (.blocker // null) != null then " · **blocker**" else "" end)
         + (if $i.decision != "" then " · decision: **" + DECISION_WORD[$i.decision] + "**" else "" end),
       "",
       "- **Who notices:** " + (.audience | oneline) + link,
       "- **Before:** " + (.before | oneline),
       "- **After:** " + (.after | oneline),
       "- **Fixes:** " + (.fixes | oneline),
       "- **Pros:** " + (.pros | map(oneline) | join("; ")),
       "- **Cons:** " + (.cons | map(oneline) | join("; ")),
       "- **Deploy risk:** " + (.risk | oneline)]
    + (if (.blocker // null) != null then ["- **Must resolve before release:** " + (.blocker | oneline)] else [] end)
    + (if (list_of("deploy_prereqs") | length) > 0 then ["- **Operator steps:** " + (.deploy_prereqs | map(oneline) | join("; "))] else [] end)
    + (if (list_of("questions") | length) > 0 then ["- **Open questions:** " + (.questions | map(oneline) | join("; "))] else [] end)
    + (if $i.note != "" then ["- **Note on the page:** " + ($i.note | oneline)] else [] end)
    + (if (list_of("test_steps") | length) > 0 then ["", "Test steps:", ""] + [.test_steps[] | step_line[]]
       else ["", "_No production test needed for this change._"] end);
  def runbook_md:
    [ $p | list_of("runbook") | to_entries[] | .key as $k | .value
      | ($rx[.id] // {done: false}) as $r
      | ["\($k + 1). [" + (if $r.done then "x" else " " end) + "] **" + (.phase | oneline) + ": " + (.action | oneline) + "** (`" + .id + "`)"]
        + (if (.why // null) != null then ["   " + (.why | oneline)] else [] end)
        + (if (.cmd // null) != null then fence("   "; .cmd) else [] end) ]
    | add // [];

  (["# " + ($p.heading // $p.title | oneline), ""]
   + ["_Release review" + (if ($p.generated // null) != null then " · prepared " + $p.generated else "" end)
      + (if ($p.url // null) != null then " · " + $p.url else "" end) + "_", ""]
   + [$p.repos[] | "- **" + (.name | oneline) + "**: " + .from + " → " + .to + (if (.count_label // null) != null then " · " + (.count_label | oneline) else "" end)]
   + ["", "Steps: \($st.counts.pass) passed · \($st.counts.fail) failed · \($st.counts.pending) not run of \($st.counts.steps). Decisions: \($st.counts.ship + $st.counts.question + $st.counts.hold) of \($st.counts.items). Runbook: \($st.runbook.done) of \($st.runbook.total) done."]
   + ["", "## Verdict: " + RISK_WORD[$p.verdict.level] + " risk", "", "**" + ($p.verdict.headline | oneline) + "**", ""]
   + ($p.verdict.paragraphs | map(., "") | .[:-1])
   + section("Release progress"; [$p | list_of("progress")[] | "- **" + STATE_WORD[.state] + ":** " + (."label" | oneline) + (if (.text // null) != null then ". " + (.text | oneline) else "" end) + link])
   + section("Found during the release (not caused by it)"; [$p | list_of("findings")[] | "- **" + (if (.tag // null) != null then .tag + ": " else "" end) + (.title | oneline) + "** " + (.why | oneline) + (if (.action // null) != null then " **Action:** " + (.action | oneline) else "" end) + link])
   + section("Fix these before you tag"; (if ($p | list_of("blockers") | length) == 0 then ["No blockers found."]
       else [$p.blockers[] | "- **" + (if .soft == true then "Do first" else "Blocker" end) + ": " + (.title | oneline) + "** " + (.why | oneline) + (if (.action // null) != null then " **Action:** " + (.action | oneline) else "" end) + link] end))
   + section("Biggest risks"; $p | list_of("top_risks") | bullets)
   + section("What users will notice"; $p | list_of("user_visible") | bullets)
   + section("Checked and not blocking"; $p | list_of("cleared") | bullets)
   + ([ $p.repos[] | . as $r
        | ["", "## " + (.name | oneline) + ": " + .from + " → " + .to, ""]
          + (list_of("how") | map(., "") )
          + (if (.live // null) != null then ["What is live: `" + (.live | oneline) + "`"] else [] end)
          + ([$p.items[] | select(.repo == $r.id) | item_md[]]) ] | add // [])
   + section("Release runbook"; ($p | list_of("runbook_intro") | map(., "")) + runbook_md)
   + section("Deploy order"; $p | list_of("deploy_order") | bullets)
   + section("What goes wrong if the order slips"; $p | list_of("ordering_risks") | bullets)
   + section("Rollback"; [$p | list_of("rollback")[] | ["- " + (if (.repo // null) != null then "**" + .repo + ":** " else "" end) + (.text | oneline)] + (if (.cmd // null) != null then fence("  "; .cmd) else [] end)] | add // [])
   + section("Method"; $p | list_of("method") | bullets)
  ) | join("\n")
'

cmd_report() {
  require_items
  check_data_dir
  validate "$ITEMS" >/dev/null || die "report" "items file fails validation; run check and fix it first"
  local state out
  state=$(readback_json) || { printf '%s\n' "$state"; exit 2; }
  work_dir
  printf '%s\n' "$state" > "$WORK/state.json"
  out=$(jq -rn --slurpfile items "$ITEMS" --slurpfile state_ "$WORK/state.json" '$state_[0] as $state | '"$REPORT" 2>&1) \
    || die "report" "report filter failed: $out"
  if [[ -n "$OUT" ]]; then
    printf '%s\n' "$out" | write_atomic "$OUT" || die "report" "could not write $OUT"
    jq -cn --arg out "$OUT" --argjson lines "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" '{status:"ok", out:$out, lines:$lines}'
  else
    printf '%s\n' "$out"
  fi
}

# ---------------------------------------------------------------------------
# Subagent hand-back. A study subagent's JSON can arrive as text or inside a
# tool_use input, so every string in every assistant message is searched.

# shellcheck disable=SC2016
EXTRACT_BLOCKS='def blocks: [match("```json[ \\t]*\\r?\\n?([\\s\\S]*?)```"; "g") | .captures[0].string];'

cmd_extract() {
  [[ -n "$TRANSCRIPT" ]] || die "parse_args" "--transcript is required: the subagent transcript (.jsonl) or its saved output"
  [[ -f "$TRANSCRIPT" ]] || die "parse_args" "transcript not found: $TRANSCRIPT"
  [[ -n "$OUT" ]] || die "parse_args" "--out is required"
  local block is_transcript
  is_transcript=$(jq -Rn '[inputs | (fromjson? // null) | select(type == "object" and (.message | type) == "object")] | length > 0' \
    "$TRANSCRIPT" 2>/dev/null)
  if [[ "$is_transcript" == "true" ]]; then
    # The last assistant string that holds a block, wherever it sits: a text
    # part, or a tool_use input the subagent handed back through.
    # shellcheck disable=SC2016
    block=$(jq -Rnr "$EXTRACT_BLOCKS"'
      [inputs | (fromjson? // null) | select(type == "object")
       | select((.message | type) == "object" and .message.role == "assistant")
       | .message.content | .. | strings | select(contains("```json"))]
      | if length > 0 then (last | blocks | last // empty) else empty end' "$TRANSCRIPT" 2>/dev/null)
  else
    # Saved output (Markdown or plain text): read the file as one string.
    # shellcheck disable=SC2016
    block=$(jq -Rsr "$EXTRACT_BLOCKS"' blocks | last // empty' "$TRANSCRIPT" 2>/dev/null)
  fi
  [[ -n "$block" ]] || die "extract" "no closed \`\`\`json block found in $TRANSCRIPT"
  jq . <<<"$block" >/dev/null 2>&1 || die "extract" "the last \`\`\`json block in $TRANSCRIPT is not valid JSON"
  jq . <<<"$block" | write_atomic "$OUT" || die "extract" "could not write $OUT"
  jq -c --arg out "$OUT" '{status:"ok", out:$out, type:type, length:(if type == "array" or type == "object" then length else null end)}' "$OUT"
}

# ---------------------------------------------------------------------------
# Scope: what is on the target since the last release.

cmd_scope() {
  [[ -n "$REPO" ]] || die "parse_args" "--repo is required: owner/name"
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "parse_args" "--repo must be owner/name: $REPO"
  [[ -n "$REPO_PATH" ]] || die "parse_args" "--path is required: a local clone of $REPO"
  [[ -n "$OUT" ]] || die "parse_args" "--out is required"
  command -v git >/dev/null 2>&1 || die "preflight" "git is required"
  command -v "$GH_BIN" >/dev/null 2>&1 || die "preflight" "gh is required"
  git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1 || die "scope" "not a git checkout: $REPO_PATH"

  local err
  err=$(git -C "$REPO_PATH" fetch origin --tags --prune --quiet 2>&1) || die "scope" "git fetch failed in $REPO_PATH: $err"

  local target="$TARGET" t
  if [[ -z "$target" ]]; then
    target=$(git -C "$REPO_PATH" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || target=""
    if [[ -z "$target" ]]; then
      for t in origin/main origin/master; do
        if git -C "$REPO_PATH" rev-parse --verify --quiet "$t^{commit}" >/dev/null; then target="$t"; break; fi
      done
    fi
    [[ -n "$target" ]] || die "scope" "cannot find the default branch (no origin/HEAD, origin/main or origin/master); pass --target"
  fi
  local head
  head=$(git -C "$REPO_PATH" rev-parse --verify --quiet "$target^{commit}") || die "scope" "cannot resolve --target $target"

  local since="$SINCE"
  if [[ -z "$since" ]]; then
    since=$(git -C "$REPO_PATH" describe --tags --abbrev=0 --match 'v*' "$head" 2>/dev/null) \
      || die "scope" "no v* tag is reachable from $target; pass --since with the last release (a tag, a commit, or a deploy marker's commit)"
  fi
  local since_sha
  since_sha=$(git -C "$REPO_PATH" rev-parse --verify --quiet "$since^{commit}") || die "scope" "cannot resolve --since $since"
  git -C "$REPO_PATH" merge-base --is-ancestor "$since_sha" "$head" \
    || die "scope" "$since is not an ancestor of $target: the range would be wrong"

  local commits since_epoch search_from merged open
  commits=$(git -C "$REPO_PATH" log --first-parent --format='%H%x09%ct%x09%s' "$since_sha..$head" \
    | jq -Rc 'split("\t") | {sha: .[0], date: (.[1] | tonumber | todate), subject: (.[2:] | join("\t"))}' | jq -sc .) \
    || die "scope" "git log failed for $since..$target"
  since_epoch=$(git -C "$REPO_PATH" log -1 --format=%ct "$since_sha") || die "scope" "git log failed for $since"
  # A day early, so a timezone can't push a PR merged right after the tag out of the search.
  search_from=$(jq -rn --argjson t "$since_epoch" '($t - 86400) | todate | .[0:10]')
  merged=$("$GH_BIN" pr list -R "$REPO" --state merged --search "merged:>=$search_from" --limit "$MERGED_LIMIT" \
    --json number,title,url,mergedAt,mergeCommit,author,labels,baseRefName 2>&1) \
    || die "scope" "gh pr list (merged) failed for $REPO: $merged"
  open=$("$GH_BIN" pr list -R "$REPO" --state open --limit 300 \
    --json number,title,url,isDraft,reviewDecision,mergeable,baseRefName,headRefName,labels,updatedAt 2>&1) \
    || die "scope" "gh pr list (open) failed for $REPO: $open"
  jq -e 'type == "array"' <<<"$merged" >/dev/null 2>&1 || die "scope" "gh returned something other than a list of merged PRs"
  jq -e 'type == "array"' <<<"$open" >/dev/null 2>&1 || die "scope" "gh returned something other than a list of open PRs"
  work_dir
  printf '%s\n' "$commits" > "$WORK/commits.json"
  printf '%s\n' "$merged" > "$WORK/merged.json"
  printf '%s\n' "$open" > "$WORK/open.json"

  # Ask GitHub which merged PR each unmatched commit belongs to. A
  # rebase-merged PR's earlier commits land here, because only its last
  # commit is the PR's merge commit, and a PR the search missed (its limit)
  # shows up here too. One API call per commit, up to LOOKUP_CAP.
  local direct sha pulls pr looked=0 failed=0 skipped=0
  # shellcheck disable=SC2016
  direct=$(jq -r --slurpfile m "$WORK/merged.json" '
      (reduce $m[0][] as $p ({}; if ($p.mergeCommit | type) == "object" then .[$p.mergeCommit.oid] = true else . end)) as $set
      | .[] | select($set[.sha] | not) | .sha' "$WORK/commits.json") || die "scope" "could not read the commit list"
  : > "$WORK/pulls.jsonl"
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    if (( looked >= LOOKUP_CAP )); then skipped=$((skipped+1)); continue; fi
    looked=$((looked+1))
    if pulls=$("$GH_BIN" api "repos/$REPO/commits/$sha/pulls" 2>/dev/null) \
       && pr=$(jq -c '[.[] | select(.merged_at != null) | .number] | first // null' <<<"$pulls" 2>/dev/null); then
      jq -cn --arg sha "$sha" --argjson pr "$pr" '{sha: $sha, pr: $pr}' >> "$WORK/pulls.jsonl"
    else
      failed=$((failed+1))
    fi
  done <<<"$direct"

  # shellcheck disable=SC2016
  jq -n --arg repo "$REPO" --arg path "$REPO_PATH" --arg target "$target" --arg head "$head" \
    --arg since "$since" --arg since_sha "$since_sha" --argjson since_epoch "$since_epoch" \
    --argjson limit "$MERGED_LIMIT" --argjson cap "$LOOKUP_CAP" --argjson failed "$failed" --argjson skipped "$skipped" \
    --slurpfile c "$WORK/commits.json" --slurpfile m "$WORK/merged.json" --slurpfile o "$WORK/open.json" \
    --slurpfile l "$WORK/pulls.jsonl" '
    $c[0] as $commits | $m[0] as $merged | $o[0] as $open
    | def login: if (.author | type) == "object" then .author.login else null end;
    def names: [(.labels // [])[] | .name];
    (reduce $merged[] as $p ({}; if ($p.mergeCommit | type) == "object" then .[$p.mergeCommit.oid] = $p else . end)) as $by_oid
    | (reduce $l[] as $x ({}; .[$x.sha] = $x.pr)) as $via
    | [ $commits[] | . as $c | ($by_oid[$c.sha] // null) as $p
        | if $p == null then {sha: $c.sha, subject: $c.subject, date: $c.date,
                              pr_hint: ($c.subject | (capture("\\(#(?<n>[0-9]+)\\)$") | .n | tonumber)? // null),
                              via_pr: ($via[$c.sha] // null)}
          else {pr: $p.number, title: $p.title, url: $p.url, merged_at: $p.mergedAt, author: ($p | login),
                labels: ($p | names), sha: $c.sha} end ] as $rows0
    | [$rows0[] | select(.pr != null) | .pr] as $pr_nums
    | [ $rows0[] | if .pr == null then . + {covered: (.via_pr != null and (.via_pr as $n | $pr_nums | map(. == $n) | any))} else . end ] as $rows
    | { status: "ok", repo: $repo, path: $path,
        target: $target, head: $head, head_short: $head[0:12],
        since: $since, since_sha: $since_sha, since_date: ($since_epoch | todate),
        counts: {commits: ($commits | length), prs: ($pr_nums | length),
                 direct_commits: ([$rows[] | select(.pr == null)] | length),
                 to_study: (($pr_nums | length) + ([$rows[] | select(.pr == null and (.covered | not))] | length)),
                 open_prs: ($open | length)},
        warnings: (
          (if ($merged | length) >= $limit then
             ["gh pr list returned \($limit) merged PRs, its limit, so some may be missing from prs: their commits are in direct_commits, with via_pr when the lookup found the PR"]
           else [] end)
          + (if $failed > 0 then ["could not look up the PR for \($failed) direct commits: check them by hand"] else [] end)
          + (if $skipped > 0 then ["looked up the PR for only the first \($cap) direct commits; \($skipped) were not looked up"] else [] end)),
        prs: ([$rows[] | select(.pr != null)] | reverse),
        direct_commits: ([$rows[] | select(.pr == null)] | reverse),
        open_prs: [ $open | sort_by(.number)[]
                    | {pr: .number, title, url, draft: .isDraft, review: .reviewDecision, mergeable,
                       base: .baseRefName, head: .headRefName, labels: names, updated_at: .updatedAt} ] }' \
    | write_atomic "$OUT" || die "scope" "could not write $OUT"
  jq -c --arg out "$OUT" '{status, out:$out, repo, since, head_short, counts, warnings}' "$OUT"
}

sub="${1:-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  check)    parse_args "$@"; cmd_check ;;
  build)    parse_args "$@"; cmd_build ;;
  ids)      parse_args "$@"; cmd_ids ;;
  assemble) parse_args "$@"; cmd_assemble ;;
  readback) parse_args "$@"; cmd_readback ;;
  report)   parse_args "$@"; cmd_report ;;
  extract)  parse_args "$@"; cmd_extract ;;
  scope)    parse_args "$@"; cmd_scope ;;
  --help|-h|"") usage ;;
  *) die "parse_args" "unknown subcommand: $sub (expected scope, extract, assemble, ids, check, build, readback or report)" ;;
esac
