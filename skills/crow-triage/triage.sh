#!/usr/bin/env bash
# crow-triage helper (CROW-1325) — the deterministic half of /crow-triage.
# The LLM half (writing the items, publishing the page, acting on the
# decisions) lives in SKILL.md.
#
#   check    --items F                            validate items.json
#   build    --items F --out F [--template F]     validate, then write the page
#   readback --items F --decisions PATH           join the `decisions` docs to the items
#
# Each subcommand prints one JSON object and exits 0 on success, 1 when the
# items fail validation, 2 on a usage or environment error. Invalid decision
# docs never fail readback: viewers wrote them, so they are reported, not trusted.
#
# --decisions takes the directory `ArtifactData list` wrote with out_dir
# (<out_dir>/decisions/<doc_id>.json, one doc per file), or one JSON file:
# an array of docs, an {id: doc} map, or the inline list output (one
# {id, data, version} per line). `version` is reported when the input has it;
# out_dir files carry only the doc body. Requires jq 1.6 or newer.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ITEMS=""
OUT=""
TEMPLATE="$SCRIPT_DIR/page.html"
DECISIONS=""

die() { # die <step> <message>
  jq -cn --arg step "$1" --arg msg "$2" '{status:"error", step:$step, message:$msg}'
  exit 2
}

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# Same floor as cascade.sh: the filters below are written for jq 1.6, and
# older jq lacks any/all with a generator.
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
      --items)     ITEMS="${2:-}"; shift 2 ;;
      --out)       OUT="${2:-}"; shift 2 ;;
      --template)  TEMPLATE="${2:-}"; shift 2 ;;
      --decisions) DECISIONS="${2:-}"; shift 2 ;;
      --help|-h)   usage ;;
      *) die "parse_args" "unknown argument: $1" ;;
    esac
  done
  require_jq_16
  [[ -n "$ITEMS" ]] || die "parse_args" "--items is required"
  [[ -f "$ITEMS" ]] || die "parse_args" "items file not found: $ITEMS"
  jq empty "$ITEMS" 2>/dev/null || die "parse_args" "items file is not valid JSON: $ITEMS"
}

# Validates items.json and prints the check result. Doc ids must satisfy the
# artifact db's segment grammar, because each item id is its decision doc's id.
# shellcheck disable=SC2016  # $vars below are jq's, not the shell's
VALIDATE='
def VERDICTS: ["strong","worth","marginal","none","bug","counterproductive","pending"];
def nonempty: type == "string" and length > 0;
def member($xs): . as $v | $xs | map(. == $v) | any;
def strfield($k):
  if (.[$k] // null) == null or (.[$k] | type) == "string" then [] else ["\($k) must be a string"] end;
def strlist($k):
  if (.[$k] // null) == null then []
  elif (.[$k] | type) == "array" and (.[$k] | all(type == "string")) then []
  else ["\($k) must be an array of strings"] end;
def where_($i): "item \($i + 1)" + (if (.id | type) == "string" then " (\(.id))" else "" end);

def item_errors($gids):
  (if (.id | type) != "string" then ["id must be a string"]
   elif (.id | test("^[A-Za-z0-9_.~:@+-]{1,200}$") | not) or .id == "." or .id == ".." then
     ["id \(.id | tojson) may use only letters, digits and _ - . ~ : @ + (1-200 characters)"]
   else [] end)
  + (if (.title | nonempty) then [] else ["title is required"] end)
  + (if (.repo | nonempty) then [] else ["repo is required: the owner/repo the work would land in"] end)
  + (if (.verdict | type) == "string" and (.verdict | member(VERDICTS)) then []
     else ["verdict must be one of \(VERDICTS | join(", "))"] end)
  + (if ($gids | length) == 0 then
       (if (.group // null) == null then [] else ["group \(.group | tojson) is set but the page has no groups"] end)
     elif (.group | type) == "string" and (.group | member($gids)) then []
     else ["group must be one of \($gids | join(", "))"] end)
  + (. as $it | [ "where","summary","effect","effort","rec","rec_why","mechanism","risks","changed" ]
     | map(. as $k | $it | strfield($k)) | add)
  + strlist("evidence");

def answer_errors:
  (if (.question | nonempty) then [] else ["question is required"] end)
  + (. as $a | ["id","short","verdict","footnote"] | map(. as $k | $a | strfield($k)) | add)
  + strlist("points")
  + (if (.figures // null) == null then []
     elif (.figures | type) == "array" and (.figures | all(type == "object" and (.value | type) == "string" and (."label" | type) == "string")) then []
     else ["figures must be an array of {value, label} strings"] end)
  + (if (.table // null) == null then []
     elif (.table | type) == "object" and (.table.rows | type) == "array"
          and (.table.rows | all(type == "array" and all(type == "string")))
          and ((.table.columns // []) | type == "array" and all(type == "string")) then []
     else ["table must be {columns: [strings], rows: [[strings]]}"] end);

if type != "object" then {errors: ["items file must be a JSON object"], warnings: []}
else
  . as $doc
  | (if (.groups // null) == null then [] elif (.groups | type) == "array" then .groups else null end) as $groups
  | (if $groups == null then [] else [$groups[] | .id? | select(type == "string")] end) as $gids
  | (if (.items | type) == "array" then .items else [] end) as $items
  | {
      errors: (
        (if (.title | nonempty) then [] else ["title is required"] end)
        + (if (.items | type) == "array" and (.items | length) > 0 then [] else ["items must be a non-empty array"] end)
        + (["context","lede","suggested","answers_heading","items_heading","items_note"] | map(. as $k | $doc | strfield($k)) | add)
        + strlist("method")
        + (if (.labels // null) == null then []
           elif (.labels | type) == "object" and (.labels | [.[]] | all(type == "string")) then []
           else ["labels must be an object of strings"] end)
        + (if $groups == null then ["groups must be an array"]
           else [$groups | to_entries[] | .key as $i | .value
                 | if type != "object" or (.id | nonempty | not) then "group \($i + 1): id is required"
                   elif (.title // "" | type) != "string" or (.sub // "" | type) != "string" then "group \(.id): title and sub must be strings"
                   else empty end] end)
        + [$gids | group_by(.) | .[] | select(length > 1) | "group id \(.[0] | tojson) is used more than once"]
        + (if (.answers // null) == null then []
           elif (.answers | type) != "array" then ["answers must be an array"]
           else [.answers | to_entries[] | .key as $i | .value
                 | if type != "object" then "answer \($i + 1) must be an object"
                   else answer_errors[] | "answer \($i + 1): \(.)" end] end)
        + [$items | to_entries[] | .key as $i | .value
           | if type != "object" then "item \($i + 1) must be an object"
             else where_($i) as $w | item_errors($gids)[] | "\($w): \(.)" end]
        + [$items | map(.id? | select(type == "string")) | group_by(.) | .[] | select(length > 1)
           | "item id \(.[0] | tojson) is used more than once; each id keys one decision"]
      ),
      warnings: (
        [($groups // [])[] | select(type == "object") | .id as $g
         | select(($items | map(select(type == "object" and .group == $g)) | length) == 0)
         | "group \($g | tojson) has no items and will not be shown"]
      ),
      summary: {
        title: .title,
        items: ($items | length),
        groups: [($groups // [])[] | select(type == "object") | .id as $g
                 | {id: $g, title: (.title // ""), items: ($items | map(select(type == "object" and .group == $g)) | length)}],
        verdicts: ($items | map(select(type == "object") | .verdict | select(type == "string"))
                   | group_by(.) | map({key: .[0], value: length}) | from_entries)
      }
    }
end
'

# Prints the check JSON; returns 1 when there are errors.
validate() {
  local result
  result=$(jq -c "$VALIDATE" "$ITEMS" 2>&1) || die "validate" "validation filter failed: $result"
  if [[ "$(jq -r '.errors | length' <<<"$result")" != "0" ]]; then
    jq -c '{status:"error", step:"validate", errors, warnings}' <<<"$result"
    return 1
  fi
  CHECK_RESULT="$result"
  return 0
}

cmd_check() {
  validate || exit 1
  jq -c '{status:"ok"} + .summary + {warnings}' <<<"$CHECK_RESULT"
}

cmd_build() {
  [[ -n "$OUT" ]] || die "parse_args" "--out is required"
  [[ -f "$TEMPLATE" ]] || die "build" "page template not found: $TEMPLATE"
  local n
  for marker in "__TRIAGE_DATA__" "<title>__TRIAGE_TITLE__</title>"; do
    n=$(grep -cxF -- "$marker" "$TEMPLATE")
    [[ "$n" == "1" ]] || die "build" "template must have exactly one line \"$marker\" (found $n): $TEMPLATE"
  done
  validate || exit 1

  # `<` is escaped inside the JSON so no item text can close the data
  # <script> block; JSON.parse turns \u003c back into `<`.
  local data title
  data=$(jq -c . "$ITEMS" | sed 's/</\\u003c/g') || die "build" "could not serialize $ITEMS"
  title=$(jq -r '.title | @html' "$ITEMS") || die "build" "could not read the title"

  local out_dir tmp
  out_dir=$(dirname "$OUT")
  mkdir -p "$out_dir" || die "build" "cannot create $out_dir"
  tmp=$(mktemp "$out_dir/.triage-page.XXXXXX") || die "build" "cannot write to $out_dir"
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in
        "__TRIAGE_DATA__") printf '%s\n' "$data" ;;
        "<title>__TRIAGE_TITLE__</title>") printf '<title>%s</title>\n' "$title" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$TEMPLATE"
  } > "$tmp" || { rm -f "$tmp"; die "build" "could not write the page"; }
  mv -f "$tmp" "$OUT" || { rm -f "$tmp"; die "build" "could not move the page into place at $OUT"; }

  jq -c --arg out "$OUT" --argjson bytes "$(wc -c < "$OUT" | tr -d ' ')" \
    '{status:"ok", out:$out, bytes:$bytes} + .summary + {warnings}' <<<"$CHECK_RESULT"
}

# Collects decision docs as [{id, raw}] from a directory of <id>.json files
# or from one JSON file (array of docs, or an {id: doc} map).
load_decisions() {
  if [[ -d "$DECISIONS" ]]; then
    local f id first=1
    printf '['
    for f in "$DECISIONS"/*.json; do
      [[ -e "$f" ]] || continue
      id=$(basename "$f" .json)
      [[ $first -eq 1 ]] || printf ','
      first=0
      jq -c --arg id "$id" '{id: $id, raw: .}' "$f" 2>/dev/null \
        || jq -cn --arg id "$id" '{id: $id, raw: null, unreadable: true}'
    done
    printf ']'
  elif [[ -f "$DECISIONS" ]]; then
    # One array of docs, one {id: doc} map, or JSON Lines of docs: the
    # inline `ArtifactData list` output is one {id, data, version} per line.
    jq -cs '
      def doc: if type == "object" then {id: ((.id // .doc_id // .docId) | if type == "string" then . else null end), raw: .}
               else {id: null, raw: .} end;
      if length == 1 and (.[0] | type) == "array" then .[0] | map(doc)
      elif length == 1 and (.[0] | type) == "object" and ((.[0] | has("id") and has("data")) | not) then
        .[0] | to_entries | map({id: .key, raw: .value})
      else map(doc) end' "$DECISIONS" 2>/dev/null \
      || die "readback" "decisions file is not JSON (an array, an {id: doc} map, or one doc per line): $DECISIONS"
  else
    die "parse_args" "decisions not found: $DECISIONS"
  fi
}

# shellcheck disable=SC2016  # $vars below are jq's, not the shell's
READBACK='
def STATUSES: ["go","later","drop"];
def member($xs): . as $v | $xs | map(. == $v) | any;
def is_url: type == "string" and test("^https?://[^[:space:]]+$");
# A doc may arrive as its bare body or wrapped with metadata ({data, version}).
def body: if type == "object" and (.data | type) == "object" then .data else . end;
def version: if type == "object" and (.version | type) == "number" then .version else null end;

($items[0]) as $page
| [$page.items[] | .id] as $ids
| [ $docs[] | select(.id != null) ] as $raw
| [ $raw[] | . as $d | ($d.raw | body) as $b
    | { id: $d.id,
        version: ($d.raw | version),
        unreadable: ($d.unreadable // false),
        ok: ($b | type == "object"),
        status: (if ($b | type) == "object" then $b.status else null end),
        note: (if ($b | type) == "object" then $b.note else null end),
        by: (if ($b | type) == "object" then $b.by else null end),
        at: (if ($b | type) == "object" then $b.at else null end),
        ticket: (if ($b | type) == "object" then $b.ticket else null end) } ] as $docs_n
| ($docs_n | map({key: .id, value: .}) | from_entries) as $by_id
| [ $docs_n[]
    | (if .unreadable then {id, field: "doc", value: null, problem: "file is not valid JSON"}
       elif (.ok | not) then {id, field: "doc", value: null, problem: "doc is not an object"}
       else empty end),
      (select(.ok) | select(.status != null and (.status | member(STATUSES) | not))
       | {id, field: "status", value: .status, problem: "not go, later, drop or null; read as undecided"}),
      (select(.ok) | select(.note != null and (.note | type) != "string")
       | {id, field: "note", value: .note, problem: "not a string; ignored"}),
      (select(.ok) | select(.ticket != null and (.ticket | is_url | not))
       | {id, field: "ticket", value: .ticket, problem: "not an http(s) URL; the page shows no link"}),
      (select(.ok) | select(.by != null and (.by | type) != "string")
       | {id, field: "by", value: .by, problem: "not a user id string; ignored"}) ] as $invalid
| def clean:
    { status: (if (.status | type) == "string" and (.status | member(STATUSES)) then .status else null end),
      note: (if (.note | type) == "string" then .note else "" end),
      by: (if (.by | type) == "string" then .by else null end),
      at: (if (.at | type) == "string" then .at else null end),
      ticket: (if (.ticket | is_url) then .ticket else null end),
      version };
  [ $page.items[] | . as $it | ($by_id[$it.id] // {}) as $d
    | {id: $it.id, title: $it.title, repo: $it.repo, verdict: $it.verdict, rec: ($it.rec // null)}
      + (if $by_id[$it.id] then ($d | clean) else {status: null, note: "", by: null, at: null, ticket: null, version: null} end) ] as $rows
| {
    status: "ok",
    title: $page.title,
    counts: {
      items: ($rows | length),
      go: ($rows | map(select(.status == "go")) | length),
      later: ($rows | map(select(.status == "later")) | length),
      drop: ($rows | map(select(.status == "drop")) | length),
      undecided: ($rows | map(select(.status == null)) | length),
      notes: ($rows | map(select(.note != "")) | length),
      filed: ($rows | map(select(.ticket != null)) | length)
    },
    go: [$rows[] | select(.status == "go") | .id],
    later: [$rows[] | select(.status == "later") | .id],
    drop: [$rows[] | select(.status == "drop") | .id],
    undecided: [$rows[] | select(.status == null) | .id],
    to_file: [$rows[] | select(.status == "go" and .ticket == null) | .id],
    notes: [$rows[] | select(.note != "") | {id, status, note, by}],
    filed_not_go: [$rows[] | select(.ticket != null and .status != "go") | {id, status, ticket}],
    orphans: [$docs_n[] | select(.id | member($ids) | not) | select(.ok) | {id} + clean | del(.version)],
    invalid: $invalid,
    people: ([$rows[] | .by | select(. != null)] | unique),
    items: $rows
  }
'

cmd_readback() {
  [[ -n "$DECISIONS" ]] || die "parse_args" "--decisions is required"
  validate >/dev/null || die "readback" "items file fails validation; run check and fix it before reading back"
  local docs
  docs=$(load_decisions) || { printf '%s\n' "$docs"; exit 2; }
  jq -c . <<<"$docs" >/dev/null 2>&1 || die "readback" "could not read the decision docs in $DECISIONS"
  local out
  out=$(jq -cn --slurpfile items "$ITEMS" --argjson docs "$docs" "$READBACK" 2>&1) \
    || die "readback" "readback filter failed: $out"
  printf '%s\n' "$out"
}

CHECK_RESULT=""
sub="${1:-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  check)    parse_args "$@"; cmd_check ;;
  build)    parse_args "$@"; cmd_build ;;
  readback) parse_args "$@"; cmd_readback ;;
  --help|-h|"") usage ;;
  *) die "parse_args" "unknown subcommand: $sub (expected check, build or readback)" ;;
esac
