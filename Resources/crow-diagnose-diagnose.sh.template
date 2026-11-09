#!/usr/bin/env bash
# crow-diagnose helper (CROW-1415) — the deterministic half of /crow-diagnose.
# The LLM half (reading the source, the gate, the investigation, deciding the
# shape, writing the ticket) lives in SKILL.md.
#
#   workspace [--workspace NAME] [--repo OWNER/NAME]
#                                  which workspace's repos and provider to use
#   repos     --workspace NAME [--repos A,B] [--out F]
#                                  every repo the workspace claims, with its description
#                                  and topics: one GraphQL query per owner, no clones
#   checkout  --repo OWNER/NAME [--branch B] [--dev-root D]
#                                  a scratch clone at origin's default branch, kept at
#                                  {devRoot}/crow-reviews/diagnose-{owner}-{name}
#   source    (--id UUID [--at HH:MM[:SS]] | --url URL | --text-file F) --dir BASE
#             [--minutes N] [--now T]
#                                  resolve one observation into BASE/{run}/source.json
#   dupes     --repos A,B [--id S]... [--terms "..."]... [--exclude URL]... [--out F]
#                                  open and closed issues and PRs that may already cover it
#   check     --plan F             the plan and every body against the ticket standard
#   file      --plan F             file the plan's ticket or epic; resumable (filed.json)
#   corveil   VERB [ARGS...]       a read-only corveil call with --no-capture
#
# Exit codes: 0 ok; 1 invalid input (an `errors` list says what); 2 usage or
# environment error; 3 skip (corveil: no CLI on PATH). Every subcommand except
# corveil prints one JSON object. Reads GitHub through `gh`, Crow through
# `crow` and Corveil through `corveil`; override with GH_BIN / CROW_BIN /
# CORVEIL_BIN / GIT_BIN (tests do). Needs jq 1.6+. GitHub only: a GitLab
# workspace is refused by repos, checkout, dupes and file.
#
# Source text (quotes, transcripts, Slack threads, Scratch items, issue bodies)
# only ever travels inside JSON files and --body-file. It is never put on a
# command line, and nothing here interprets it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_BIN="${GH_BIN:-gh}"
CROW_BIN="${CROW_BIN:-crow}"
CORVEIL_BIN="${CORVEIL_BIN:-corveil}"
GIT_BIN="${GIT_BIN:-git}"
# The corveil verbs that only read the ontology. Anything else is refused, so
# the pre-approved `diagnose.sh corveil` prefix can never write.
CORVEIL_READ_VERBS="search entity entities context evidence event history timeline graph stats whoami health"
# Read verbs that record nothing and take no --no-capture flag.
CORVEIL_UNCAPTURED_VERBS="whoami health"
TRIAGED_LABEL="triaged"
TRIAGED_COLOR="C5DEF5"
TRIAGED_DESCRIPTION="Diagnosed against docs/ticket-standard.md by /crow-diagnose"

WORKSPACE=""; REPO=""; REPOS=""; OUT=""; BRANCH=""; DEV_ROOT=""; ID=""; AT=""
URL=""; TEXT_FILE=""; DIR=""; MINUTES=5; NOW=""; PLAN=""
IDS=(); TERMS=(); EXCLUDES=()
TMP_FILES=()

cleanup() { [[ ${#TMP_FILES[@]} -eq 0 ]] || rm -rf "${TMP_FILES[@]}"; }
trap cleanup EXIT

die() { # die <step> <message>
  jq -cn --arg step "$1" --arg msg "$2" '{status:"error", step:$step, message:$msg}'
  exit 2
}

invalid() { # invalid <errors-json-array> — exit 1 with an errors list
  jq -cn --argjson e "$1" '{status:"invalid", errors:$e}'
  exit 1
}

usage() {
  sed -n '2,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

tmpfile() { # tmpfile <var>
  local __tmp_path
  __tmp_path=$(mktemp "${TMPDIR:-/tmp}/crow-diagnose.XXXXXX") || die "preflight" "cannot create a temp file"
  TMP_FILES+=("$__tmp_path")
  printf -v "$1" '%s' "$__tmp_path"
}

write_atomic() { # write_atomic <path> <content>
  local dir tmp
  dir=$(dirname "$1")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.diagnose.XXXXXX") || return 1
  if printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$1"; then return 0; fi
  rm -f "$tmp"
  return 1
}

emit() { # emit <json> — print it, and also write it to --out when given
  if [[ -n "$OUT" ]]; then
    write_atomic "$OUT" "$1" || die "write" "cannot write $OUT"
  fi
  printf '%s\n' "$1"
}

is_uuid() { [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; }
is_slug() { [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] && [[ "$1" != *..* ]]; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# The filters are written for jq 1.6: every `if` has an `else`, no keyword is
# used as a bare object key, and no 1.7-only builtin (abs, pick, trim, ltrimstr
# on non-strings) appears.
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
      --workspace|--repo|--repos|--out|--branch|--dev-root|--id|--at|--url|--text-file|--dir|--minutes|--now|--plan|--terms|--exclude)
        [[ $# -ge 2 ]] || die "parse_args" "$1 needs a value"
        case "$1" in
          --workspace) WORKSPACE="$2" ;;
          --repo)      REPO="$2" ;;
          --repos)     REPOS="$2" ;;
          --out)       OUT="$2" ;;
          --branch)    BRANCH="$2" ;;
          --dev-root)  DEV_ROOT="$2" ;;
          --id)        ID="$2"; IDS+=("$2") ;;
          --at)        AT="$2" ;;
          --url)       URL="$2" ;;
          --text-file) TEXT_FILE="$2" ;;
          --dir)       DIR="$2" ;;
          --minutes)   MINUTES="$2" ;;
          --now)       NOW="$2" ;;
          --plan)      PLAN="$2" ;;
          --terms)     TERMS+=("$2") ;;
          --exclude)   EXCLUDES+=("$2") ;;
        esac
        shift 2 ;;
      *) die "parse_args" "unknown argument: $1" ;;
    esac
  done
}

# ─── workspace ──────────────────────────────────────────────────────────────
# The glob rule matches AppConfig.repoMatchesPatterns: case-insensitive, one `*`.
# shellcheck disable=SC2016  # $vars below are jq's or GraphQL's, not the shell's
JQ_GLOB='
def glob_match($slug):
  (ascii_downcase) as $p | ($slug | ascii_downcase) as $s
  | if ($p | index("*")) == null then $p == $s
    else ($p | split("*")) as $parts
      | ($parts[0]) as $pre | ($parts[1:] | join("*")) as $suf
      | ($s | startswith($pre)) and ($s | endswith($suf))
        and (($s | length) >= (($pre | length) + ($suf | length)))
    end;
def patterns: ((.always_include // []) + (.auto_review_repos // []));
def owners: [patterns[] | select(contains("/")) | split("/")[0] | select(contains("*") | not) | ascii_downcase] | unique;
'

# resolve_workspace — sets WS_JSON to {workspace, owners, how} or dies.
resolve_workspace() {
  local list how="" name="" err
  list=$("$CROW_BIN" workspace list 2>&1) || die "workspace" "crow workspace list failed: $list"
  jq -e '.workspaces | type == "array"' >/dev/null 2>&1 <<<"$list" \
    || die "workspace" "crow workspace list returned no workspaces array"
  if [[ "$(jq '.workspaces | length' <<<"$list")" == "0" ]]; then
    die "workspace" "no workspaces are configured; add one with crow workspace add"
  fi

  if [[ -n "$WORKSPACE" ]]; then
    name=$(jq -r --arg w "$WORKSPACE" '[.workspaces[] | select((.name | ascii_downcase) == ($w | ascii_downcase) or (.id // "" | ascii_downcase) == ($w | ascii_downcase))][0].name // empty' <<<"$list")
    [[ -n "$name" ]] || die "workspace" "no workspace named $WORKSPACE ($(jq -r '[.workspaces[].name] | join(", ")' <<<"$list"))"
    how="flag"
  fi
  if [[ -z "$name" && -n "$REPO" ]]; then
    is_slug "$REPO" || die "workspace" "--repo must be owner/name, not $REPO"
    # Exact beats glob; among equals the first in config order wins (AppConfig.workspace(forRepoSlug:)).
    name=$(jq -r --arg r "$REPO" "$JQ_GLOB"'
      [.workspaces[] | . as $w | (patterns) as $p
        | select(any($p[]; glob_match($r)))
        | {name: $w.name, exact: any($p[]; ascii_downcase == ($r | ascii_downcase))}]
      | ((map(select(.exact)) + map(select(.exact | not)))[0].name) // empty' <<<"$list")
    [[ -n "$name" ]] && how="repo"
  fi
  if [[ -z "$name" && -n "${CROW_SESSION_ID:-}" ]]; then
    local sess
    if sess=$("$CROW_BIN" get-session --session "$CROW_SESSION_ID" 2>/dev/null); then
      name=$(jq -r '.workspace_name // empty' <<<"$sess" 2>/dev/null)
      [[ -n "$name" ]] && how="manager"
    fi
  fi
  if [[ -z "$name" ]]; then
    local defs
    if defs=$("$CROW_BIN" defaults get 2>/dev/null); then
      name=$(jq -r '.defaults.manager_workspace // empty' <<<"$defs" 2>/dev/null)
      [[ -n "$name" ]] && how="default"
    fi
  fi
  if [[ -z "$name" && "$(jq '.workspaces | length' <<<"$list")" == "1" ]]; then
    name=$(jq -r '.workspaces[0].name' <<<"$list")
    how="only"
  fi
  if [[ -z "$name" ]]; then
    err="no workspace resolved: pass --workspace ($(jq -r '[.workspaces[].name] | join(", ")' <<<"$list"))"
    die "workspace" "$err"
  fi

  WS_JSON=$(jq -c --arg n "$name" --arg how "$how" "$JQ_GLOB"'
    [.workspaces[] | select(.name == $n)][0]
    | {workspace: {name, provider: (.provider // "github"), task_provider: (.task_provider // .provider // "github"),
                   host, patterns: patterns},
       owners: owners, how: $how}' <<<"$list") || die "workspace" "cannot read workspace $name"
}

cmd_workspace() {
  local warnings='[]'
  resolve_workspace
  if [[ "$(jq '.owners | length' <<<"$WS_JSON")" == "0" ]]; then
    warnings='["the workspace names no owner/* or owner/name repo pattern, so repos has nothing to list: pass --repos"]'
  fi
  if [[ "$(jq -r '.workspace.provider' <<<"$WS_JSON")" != "github" ]]; then
    warnings=$(jq -c '. + ["this workspace is not on GitHub: repos, checkout, dupes and file refuse it, so do those steps with glab by hand"]' <<<"$warnings")
  fi
  emit "$(jq -c --argjson w "$warnings" '{status: "ok"} + . + {warnings: $w}' <<<"$WS_JSON")"
}

# ─── repos ──────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # $vars below are jq's or GraphQL's, not the shell's
REPOS_QUERY='query($owner: String!, $endCursor: String) {
  repositoryOwner(login: $owner) {
    login
    repositories(first: 100, after: $endCursor, isArchived: false, orderBy: {field: PUSHED_AT, direction: DESC}) {
      nodes { nameWithOwner description isFork pushedAt primaryLanguage { name } defaultBranchRef { name }
              repositoryTopics(first: 10) { nodes { topic { name } } } }
      pageInfo { hasNextPage endCursor }
    }
  }
}'

cmd_repos() {
  [[ -n "$WORKSPACE" ]] || die "parse_args" "repos needs --workspace (run workspace first)"
  resolve_workspace
  [[ "$(jq -r '.workspace.provider' <<<"$WS_JSON")" == "github" ]] \
    || die "repos" "workspace $(jq -r '.workspace.name' <<<"$WS_JSON") is not on GitHub; list its repos with glab by hand"

  local wanted='[]' owners slug
  if [[ -n "$REPOS" ]]; then
    local IFS_SAVE="$IFS"; IFS=','
    # shellcheck disable=SC2206  # split on commas on purpose
    local parts=($REPOS)
    IFS="$IFS_SAVE"
    for slug in "${parts[@]}"; do
      slug="${slug// /}"
      [[ -z "$slug" ]] && continue
      is_slug "$slug" || die "parse_args" "--repos takes owner/name slugs, not $slug"
      wanted=$(jq -c --arg s "$slug" '. + [$s | ascii_downcase]' <<<"$wanted")
    done
    owners=$(jq -c '[.[] | split("/")[0]] | unique' <<<"$wanted")
  else
    owners=$(jq -c '.owners' <<<"$WS_JSON")
  fi
  [[ "$(jq 'length' <<<"$owners")" != "0" ]] \
    || die "repos" "no owner to list: the workspace patterns name none, so pass --repos owner/a,owner/b"

  local all='[]' owner pages
  while IFS= read -r owner; do
    [[ -z "$owner" ]] && continue
    pages=$("$GH_BIN" api graphql --paginate -f owner="$owner" -f query="$REPOS_QUERY" 2>&1) \
      || die "repos" "listing $owner's repos failed: $pages"
    local got
    got=$(jq -cs --arg owner "$owner" '
      if any(.[]; .data.repositoryOwner == null) then {missing: $owner}
      else {nodes: [.[] | .data.repositoryOwner.repositories.nodes[]
        | {repo: .nameWithOwner, description: (.description // ""), fork: .isFork, pushed_at: .pushedAt,
           language: (.primaryLanguage.name // null), default_branch: (.defaultBranchRef.name // null),
           topics: [.repositoryTopics.nodes[].topic.name]}]}
      end' <<<"$pages") || die "repos" "unreadable GraphQL response for $owner"
    if [[ "$(jq -r '.missing // empty' <<<"$got")" != "" ]]; then
      die "repos" "GitHub has no user or organization named $owner"
    fi
    all=$(jq -c --argjson more "$(jq -c '.nodes' <<<"$got")" '. + $more' <<<"$all")
  done < <(jq -r '.[]' <<<"$owners")

  local result
  result=$(jq -c --argjson ws "$WS_JSON" --argjson wanted "$wanted" "$JQ_GLOB"'
    ($ws.workspace.patterns) as $p
    | (if ($wanted | length) > 0 then [.[] | select((.repo | ascii_downcase) as $r | $wanted | index($r) != null)]
       else [.[] | . as $x | select(any($p[]; glob_match($x.repo)))] end) as $kept
    | ([$wanted[] | . as $w | select(($kept | map(.repo | ascii_downcase) | index($w)) == null)]) as $missing
    | {status: (if ($missing | length) > 0 then "invalid" else "ok" end),
       workspace: $ws.workspace.name, count: ($kept | length),
       repos: ($kept | unique_by(.repo | ascii_downcase) | sort_by(.pushed_at) | reverse),
       errors: [$missing[] | "\(.) is not a non-archived repo of its owner"]}' <<<"$all")
  emit "$result"
  [[ "$(jq -r .status <<<"$result")" == "ok" ]] || exit 1
}

# ─── checkout ───────────────────────────────────────────────────────────────
default_dev_root() {
  # The scaffold installs this script at {devRoot}/.claude/skills/crow-diagnose/.
  case "$SCRIPT_DIR" in
    */.claude/skills/crow-diagnose) (cd "$SCRIPT_DIR/../../.." && pwd) ;;
    *) return 1 ;;
  esac
}

slug_of_remote() { # owner/name from a GitHub remote URL, lower-cased; empty otherwise
  local u="$1"
  u="${u%.git}"; u="${u%/}"
  case "$u" in
    https://github.com/*) u="${u#https://github.com/}" ;;
    git@github.com:*)     u="${u#git@github.com:}" ;;
    ssh://git@github.com/*) u="${u#ssh://git@github.com/}" ;;
    *) u="" ;;
  esac
  lower "$u"
}

cmd_checkout() {
  [[ -n "$REPO" ]] || die "parse_args" "checkout needs --repo owner/name"
  is_slug "$REPO" || die "parse_args" "--repo must be owner/name, not $REPO"
  if [[ -n "$BRANCH" && ! "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    die "parse_args" "--branch has characters a branch name can't have: $BRANCH"
  fi
  if [[ -z "$DEV_ROOT" ]]; then
    DEV_ROOT=$(default_dev_root) || die "parse_args" "pass --dev-root: this script isn't running from {devRoot}/.claude/skills/crow-diagnose"
  fi
  [[ -d "$DEV_ROOT" ]] || die "checkout" "dev root $DEV_ROOT does not exist"

  local owner="${REPO%%/*}" name="${REPO#*/}"
  local dir
  dir="$DEV_ROOT/crow-reviews/diagnose-$(lower "$owner")-$(lower "$name")"
  local cloned=false out remote
  if [[ -e "$dir" && ! -d "$dir/.git" ]]; then
    die "checkout" "$dir exists but is not a git clone; remove it and run again"
  fi
  if [[ -d "$dir/.git" ]]; then
    # The raw config value, not `remote get-url`, so an insteadOf rewrite can't
    # make a different repo's clone look like this one.
    remote=$("$GIT_BIN" -C "$dir" config --get remote.origin.url 2>/dev/null || true)
    if [[ "$(slug_of_remote "$remote")" != "$(lower "$REPO")" ]]; then
      die "checkout" "$dir is a clone of ${remote:-an unknown remote}, not $REPO; remove it and run again"
    fi
    out=$("$GIT_BIN" -C "$dir" fetch --quiet --prune origin 2>&1) || die "checkout" "git fetch failed in $dir: $out"
  else
    mkdir -p "$DEV_ROOT/crow-reviews" || die "checkout" "cannot create $DEV_ROOT/crow-reviews"
    out=$("$GH_BIN" repo clone "$REPO" "$dir" -- --filter=blob:none --no-checkout --quiet 2>&1) \
      || { rm -rf "$dir"; die "checkout" "gh repo clone $REPO failed: $out"; }
    cloned=true
  fi

  local branch="$BRANCH"
  if [[ -z "$branch" ]]; then
    "$GIT_BIN" -C "$dir" remote set-head origin --auto >/dev/null 2>&1 || true
    branch=$("$GIT_BIN" -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    branch="${branch#origin/}"
  fi
  [[ -n "$branch" ]] || die "checkout" "cannot tell $REPO's default branch; pass --branch"
  # This clone is ours alone (never the operator's checkout), so a forced,
  # detached checkout and a full clean are safe.
  out=$("$GIT_BIN" -C "$dir" checkout --quiet --force --detach "origin/$branch" 2>&1) \
    || die "checkout" "cannot check out origin/$branch in $dir: $out"
  "$GIT_BIN" -C "$dir" clean -ffdxq >/dev/null 2>&1 || true

  local sha at
  sha=$("$GIT_BIN" -C "$dir" rev-parse HEAD 2>/dev/null) || die "checkout" "cannot read HEAD in $dir"
  at=$("$GIT_BIN" -C "$dir" log -1 --format=%cI 2>/dev/null || true)
  emit "$(jq -cn --arg repo "$REPO" --arg path "$dir" --arg branch "$branch" --arg sha "$sha" \
    --arg at "$at" --argjson cloned "$cloned" \
    '{status: "ok", repo: $repo, path: $path, ref: ("origin/" + $branch), branch: $branch,
      sha: $sha, committed_at: $at, cloned: $cloned}')"
}

# ─── corveil ────────────────────────────────────────────────────────────────
have_corveil() { command -v "$CORVEIL_BIN" >/dev/null 2>&1; }

corveil_read() { # corveil_read VERB ARGS... — stdout JSON; a read the org's capture sensor never sees
  local verb="$1"; shift
  CORVEIL_NO_CAPTURE=1 "$CORVEIL_BIN" "$verb" --no-capture "$@" 2>/dev/null
}

cmd_corveil() {
  local verb="${1:-}"
  [[ -n "$verb" ]] || die "parse_args" "corveil needs a verb, such as entity or evidence"
  case " $CORVEIL_READ_VERBS " in
    *" $verb "*) ;;
    *) die "corveil" "diagnose.sh corveil runs read verbs only ($CORVEIL_READ_VERBS), not $verb" ;;
  esac
  if ! have_corveil; then
    jq -cn '{status: "skipped", reason: "no corveil CLI on PATH"}'
    exit 3
  fi
  local arg
  for arg in "$@"; do
    case "$arg" in
      --no-capture*|--capture*|--question*) die "corveil" "diagnose.sh corveil sets --no-capture itself and never records a question; don't pass $arg" ;;
    esac
  done
  export CORVEIL_NO_CAPTURE=1
  shift
  case " $CORVEIL_UNCAPTURED_VERBS " in
    *" $verb "*) exec "$CORVEIL_BIN" "$verb" "$@" ;;
    *) exec "$CORVEIL_BIN" "$verb" --no-capture "$@" ;;
  esac
}

# ─── source ─────────────────────────────────────────────────────────────────
is_clock() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$ ]]; }

# Transcript lines look like `**Speaker** (HH:MM:SS): text`, one utterance per
# line; a line that doesn't is a continuation of the one before it.
# shellcheck disable=SC2016  # $vars below are jq's or GraphQL's, not the shell's
JQ_TRANSCRIPT='
def secs: split(":") | map(tonumber) | (.[0] * 3600) + (.[1] * 60) + (if length > 2 then .[2] else 0 end);
def two: tostring | if length < 2 then "0" + . else . end;
def hms: (if . < 0 then 0 elif . > 86399 then 86399 else . end) as $t
  | [($t / 3600 | floor), (($t % 3600) / 60 | floor), ($t % 60)] | map(two) | join(":");
def utterances:
  split("\n")
  | reduce .[] as $l ([];
      [$l | capture("^\\*\\*(?<speaker>[^*]+)\\*\\* \\((?<at>[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?)\\): ?(?<text>.*)$")] as $m
      | if ($m | length) > 0 then . + [{speaker: $m[0].speaker, at: $m[0].at, text: $m[0].text}]
        elif ($l | test("^\\s*$")) then .
        elif length > 0 then (length - 1) as $i | .[$i].text = (.[$i].text + " " + ($l | sub("^\\s+"; "")))
        else . end);
'

# transcript_json MEETING_ID AT — prints {meeting, transcript, warnings}.
transcript_json() {
  local mid="$1" at="$2" ent ev ids sid evjson parsed
  ent=$(corveil_read entity "$mid") || { jq -cn --arg m "$mid" '{meeting: null, transcript: null, warnings: ["cannot read meeting \($m) from Corveil"]}'; return 0; }
  if [[ "$(jq -r '.entity_type // ""' <<<"$ent")" != "Meeting" ]]; then
    jq -cn --arg m "$mid" --arg t "$(jq -r '.entity_type // "unknown"' <<<"$ent")" \
      '{meeting: null, transcript: null, warnings: ["\($m) is a \($t), not a Meeting"]}'
    return 0
  fi
  local meeting
  meeting=$(jq -c '{id, name: .canonical_name, date: (.properties.meeting_date // .properties.start_time // null),
    attendees: (.properties.attendees // []), summary: (.properties.summary // null)}' <<<"$ent")
  ev=$(corveil_read evidence "$mid" --limit 500) || ev='{}'
  # Meeting-category sources whose preview already looks like a transcript first.
  ids=$(jq -r '[.source_events[]? | select(.category == "meeting")]
    | (map(select((.content_preview // "") | test("\\*\\*[^*]+\\*\\* \\([0-9]"))) + map(select((.content_preview // "") | test("\\*\\*[^*]+\\*\\* \\([0-9]") | not)))
    | .[].id' <<<"$ev" 2>/dev/null)
  for sid in $ids; do
    is_uuid "$sid" || continue
    evjson=$(corveil_read event "$sid") || continue
    parsed=$(jq -c --arg at "$at" --argjson min "$MINUTES" --arg sid "$sid" "$JQ_TRANSCRIPT"'
      (.content // "" | utterances) as $u
      | if ($u | length) == 0 then null
        else ($at | secs) as $t | ($min * 60) as $w
          | {source_id: $sid, at: $at, minutes: $min, from: (($t - $w) | hms), to: (($t + $w) | hms),
             total_lines: ($u | length),
             lines: [$u[] | select(((.at | secs) - $t) as $d | $d >= (0 - $w) and $d <= $w)]}
        end' <<<"$evjson" 2>/dev/null) || continue
    if [[ -n "$parsed" && "$parsed" != "null" ]]; then
      jq -cn --argjson m "$meeting" --argjson t "$parsed" \
        '{meeting: $m, transcript: $t,
          warnings: (if ($t.lines | length) == 0 then ["the transcript has no lines within \($t.minutes) minutes of \($t.at)"] else [] end)}'
      return 0
    fi
  done
  jq -cn --argjson m "$meeting" '{meeting: $m, transcript: null, warnings: ["no transcript source found in the meeting evidence"]}'
}

now_stamp() {
  if [[ -n "$NOW" ]]; then
    [[ "$NOW" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2}) ]] || die "parse_args" "--now must be an ISO time, not $NOW"
    printf '%s%s%s-%s%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
  else
    date -u +%Y%m%d-%H%M%S
  fi
}

cmd_source() {
  local n=0
  [[ -n "$ID" ]] && n=$((n + 1))
  [[ -n "$URL" ]] && n=$((n + 1))
  [[ -n "$TEXT_FILE" ]] && n=$((n + 1))
  [[ "$n" == "1" ]] || die "parse_args" "source needs exactly one of --id, --url or --text-file"
  [[ -n "$DIR" ]] || die "parse_args" "source needs --dir (the base folder for runs, such as .claude/diagnose)"
  [[ "$MINUTES" =~ ^[0-9]+$ && "$MINUTES" -ge 1 && "$MINUTES" -le 60 ]] || die "parse_args" "--minutes must be 1-60"
  [[ -z "$AT" ]] || is_clock "$AT" || die "parse_args" "--at must be HH:MM or HH:MM:SS, not $AT"
  [[ -z "$AT" || -n "$ID" ]] || die "parse_args" "--at goes with a meeting --id"

  local src="" run=""
  if [[ -n "$ID" ]]; then
    is_uuid "$ID" || die "parse_args" "--id must be a UUID, not $ID"
    local short; short=$(lower "${ID:0:8}")
    if [[ -n "$AT" ]]; then
      have_corveil || die "source" "a meeting needs the corveil CLI, and none is on PATH"
      local tj; tj=$(transcript_json "$ID" "$AT")
      [[ "$(jq -r '.meeting == null' <<<"$tj")" == "false" ]] || die "source" "$(jq -r '.warnings | join("; ")' <<<"$tj")"
      src=$(jq -c --arg id "$ID" --arg at "$AT" '{kind: "meeting", id: $id, at: $at} + . + {existing_tickets: []}' <<<"$tj")
      run="meeting-$short-${AT//:/}"
    else
      local todo
      # Scratch first: it is local and fast. Anything else falls through to Corveil.
      if todo=$("$CROW_BIN" todo get --id "$ID" 2>/dev/null) && jq -e '(.todo // .) | .id' >/dev/null 2>&1 <<<"$todo"; then
        src=$(jq -c '.todo // . | {kind: "scratch", id, scratch: {id, text, note, tags, priority, state, workspace, links},
          existing_tickets: [(.links // [])[] | select(.type == "ticket" and (.url // "") != "") | .url]}' <<<"$todo") \
          || die "source" "unreadable crow todo get output"
        run="scratch-$short"
      else
        have_corveil || die "source" "$ID is not a Scratch item, and there is no corveil CLI to look it up as a FollowUp"
        local ent type
        ent=$(corveil_read entity "$ID") || die "source" "$ID is neither a Scratch item nor a Corveil entity (corveil entity failed)"
        type=$(jq -r '.entity_type // ""' <<<"$ent")
        case "$type" in
          FollowUp)
            local fu mid said tj='{"meeting":null,"transcript":null,"warnings":[]}'
            fu=$(jq -c '{id, title: .canonical_name} + (.properties | {kind, status, assignee, quote, due, meeting_date, said_at, source_meeting_id, ticket_url})' <<<"$ent")
            mid=$(jq -r '.source_meeting_id // empty' <<<"$fu")
            said=$(jq -r '.said_at // empty' <<<"$fu")
            if [[ -n "$mid" && -n "$said" ]] && is_uuid "$mid" && is_clock "$said"; then
              tj=$(transcript_json "$mid" "$said")
            elif [[ -n "$mid" || -n "$said" ]]; then
              tj='{"meeting":null,"transcript":null,"warnings":["the FollowUp has no usable source_meeting_id and said_at, so there is no transcript window"]}'
            fi
            src=$(jq -c --argjson fu "$fu" '{kind: "followup", id: $fu.id, followup: $fu} + .
              + {existing_tickets: [($fu.ticket_url // "") | select(. != "")]}' <<<"$tj")
            run="followup-$short" ;;
          Meeting)
            die "source" "$ID is a Meeting: pass the time the remark was made with --at HH:MM[:SS]" ;;
          "")
            die "source" "$ID is neither a Scratch item nor a Corveil entity" ;;
          *)
            src=$(jq -c '{kind: "entity", id, entity: {id, type: .entity_type, name: .canonical_name, properties},
              existing_tickets: [(.properties.ticket_url // "") | select(type == "string" and . != "")], warnings: []}' <<<"$ent")
            run="entity-$short" ;;
        esac
      fi
    fi
  elif [[ -n "$URL" ]]; then
    if [[ "$URL" =~ ^https://([A-Za-z0-9-]+)\.slack\.com/archives/([A-Z0-9]+)/p([0-9]{10})([0-9]{6})(\?(.*))?$ ]]; then
      local team="${BASH_REMATCH[1]}" chan="${BASH_REMATCH[2]}" ts="${BASH_REMATCH[3]}.${BASH_REMATCH[4]}" query="${BASH_REMATCH[6]}"
      local thread="$ts" reply=false
      if [[ "$query" =~ (^|&)thread_ts=([0-9]{10}\.[0-9]{6})(&|$) ]]; then
        thread="${BASH_REMATCH[2]}"
        [[ "$thread" != "$ts" ]] && reply=true
      fi
      src=$(jq -cn --arg url "$URL" --arg team "$team" --arg chan "$chan" --arg ts "$ts" --arg thread "$thread" --argjson reply "$reply" \
        '{kind: "slack", id: $url, slack: {url: $url, team: $team, channel: $chan, ts: $ts, thread_ts: $thread, is_reply: $reply},
          existing_tickets: [], warnings: ["read the thread with a Slack MCP tool or Corveil (see SKILL.md Step 1), then save it as thread.md in the run folder"]}')
      run="slack-$(lower "$chan")-${thread//./}"
    elif [[ "$URL" =~ ^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/issues/([0-9]+)/?(#.*)?$ ]]; then
      local o="${BASH_REMATCH[1]}" r="${BASH_REMATCH[2]}" num="${BASH_REMATCH[3]}" iss
      iss=$("$GH_BIN" issue view "$num" -R "$o/$r" --json number,title,body,state,stateReason,labels,author,createdAt,url,comments 2>&1) \
        || die "source" "gh issue view failed: $iss"
      src=$(jq -c --arg repo "$o/$r" '{kind: "issue", id: .url,
        issue: {repo: $repo, number, url, title, state, state_reason: .stateReason, author: (.author.login // null),
                created_at: .createdAt, labels: [.labels[]?.name], body,
                diagnosed: ((.body // "") | test("(^|\\n)## Diagnosis\\s*(\\n|$)")),
                comments: [.comments[]? | {author: (.author.login // null), created_at: .createdAt, body}]},
        existing_tickets: [], warnings: []}' <<<"$iss") || die "source" "unreadable gh issue view output"
      run="issue-$(lower "$o")-$(lower "$r")-$num"
    else
      die "parse_args" "--url must be a Slack permalink or a GitHub issue URL (https://github.com/owner/repo/issues/N)"
    fi
  else
    [[ -f "$TEXT_FILE" ]] || die "source" "$TEXT_FILE does not exist"
    local size; size=$(wc -c < "$TEXT_FILE" | tr -d ' ')
    [[ "$size" -gt 0 ]] || die "source" "$TEXT_FILE is empty"
    [[ "$size" -le 65536 ]] || die "source" "$TEXT_FILE is over 64 KB; quote the part that carries the observation"
    src=$(jq -Rsc '{kind: "text", id: null, text: ., existing_tickets: [], warnings: []}' < "$TEXT_FILE")
    run="text-$(now_stamp)"
  fi

  local run_dir="${DIR%/}/$run"
  src=$(jq -c --arg run "$run" '{run_id: $run} + . + {warnings: (.warnings // [])}' <<<"$src")
  write_atomic "$run_dir/source.json" "$(jq . <<<"$src")" || die "write" "cannot write $run_dir/source.json"
  emit "$(jq -c --arg dir "$run_dir" '{status: "ok", run_id, run_dir: $dir, source_file: ($dir + "/source.json"), kind,
    summary: (if .kind == "followup" then {title: .followup.title, followup_kind: .followup.kind, status: .followup.status,
                 said: "\(.followup.meeting_date // "?") \(.followup.said_at // "?")",
                 transcript_lines: ((.transcript.lines // []) | length)}
              elif .kind == "meeting" then {meeting: .meeting.name, at, transcript_lines: ((.transcript.lines // []) | length)}
              elif .kind == "scratch" then {state: .scratch.state, workspace: .scratch.workspace, links: ((.scratch.links // []) | length)}
              elif .kind == "issue" then {title: .issue.title, state: .issue.state, diagnosed: .issue.diagnosed, comments: (.issue.comments | length)}
              elif .kind == "slack" then {channel: .slack.channel, thread_ts: .slack.thread_ts}
              elif .kind == "entity" then {type: .entity.type, name: .entity.name}
              else {chars: (.text | length)} end),
    existing_tickets, warnings}' <<<"$src")"
}

# ─── dupes ──────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # $vars below are jq's or GraphQL's, not the shell's
SEARCH_QUERY='query($q: String!) {
  search(type: ISSUE, query: $q, first: 20) {
    issueCount
    nodes {
      __typename
      ... on Issue { number title url state stateReason closedAt updatedAt body repository { nameWithOwner } }
      ... on PullRequest { number title url state merged closedAt updatedAt body repository { nameWithOwner } }
    }
  }
}'

cmd_dupes() {
  [[ -n "$REPOS" ]] || die "parse_args" "dupes needs --repos owner/a,owner/b (the shortlist)"
  [[ ${#IDS[@]} -gt 0 || ${#TERMS[@]} -gt 0 ]] || die "parse_args" "dupes needs at least one --id or --terms"
  local slugs=() s
  local IFS_SAVE="$IFS"; IFS=','
  # shellcheck disable=SC2206  # split on commas on purpose
  local parts=($REPOS)
  IFS="$IFS_SAVE"
  for s in "${parts[@]}"; do
    s="${s// /}"
    [[ -z "$s" ]] && continue
    is_slug "$s" || die "parse_args" "--repos takes owner/name slugs, not $s"
    slugs+=("$s")
  done
  [[ ${#slugs[@]} -gt 0 ]] || die "parse_args" "--repos is empty"
  local t
  for t in ${TERMS[@]+"${TERMS[@]}"}; do
    [[ "$t" =~ ^[A-Za-z0-9\ ._:/#-]{2,120}$ ]] \
      || die "parse_args" "--terms takes your own keywords (letters, digits, spaces and ._:/#-, 2-120 chars), never copied source text: $t"
  done
  local i
  for i in ${IDS[@]+"${IDS[@]}"}; do
    [[ "$i" =~ ^[A-Za-z0-9._:/-]{6,200}$ ]] || die "parse_args" "--id must be a source id such as a UUID, not $i"
  done

  local owners
  owners=$(printf '%s\n' "${slugs[@]}" | cut -d/ -f1 | tr '[:upper:]' '[:lower:]' | sort -u)
  local queries=() q
  for i in ${IDS[@]+"${IDS[@]}"}; do
    local o
    for o in $owners; do queries+=("id"$'\t'"\"$i\" in:title,body user:$o"); done
  done
  for t in ${TERMS[@]+"${TERMS[@]}"}; do
    # Five repos per query keeps it under GitHub's search length limit.
    local k=0 chunk=""
    for s in "${slugs[@]}"; do
      chunk="$chunk repo:$s"; k=$((k + 1))
      if [[ $k -eq 5 ]]; then queries+=("terms"$'\t'"$t$chunk"); chunk=""; k=0; fi
    done
    [[ -n "$chunk" ]] && queries+=("terms"$'\t'"$t$chunk")
  done

  local acc; tmpfile acc
  : > "$acc"
  local by res
  for q in "${queries[@]}"; do
    by="${q%%$'\t'*}"; q="${q#*$'\t'}"
    res=$("$GH_BIN" api graphql -f q="$q" -f query="$SEARCH_QUERY" 2>&1) || die "dupes" "GitHub search failed for [$q]: $res"
    jq -c --arg by "$by" --arg q "$q" '.data.search.nodes[]? | select(.url != null)
      | {repo: .repository.nameWithOwner, number, url, title, type: (if .__typename == "PullRequest" then "pr" else "issue" end),
         state, state_reason: (.stateReason // null), merged: (.merged // null), closed_at: .closedAt, updated_at: .updatedAt,
         diagnosed: ((.body // "") | test("(^|\\n)## Diagnosis\\s*(\\n|$)")), matched_by: [$by], query: $q}' <<<"$res" >> "$acc" \
      || die "dupes" "unreadable GitHub search response for [$q]"
  done

  local excl='[]' e
  for e in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do excl=$(jq -c --arg e "$e" '. + [$e | sub("/+$"; "")]' <<<"$excl"); done
  emit "$(jq -cs --argjson excl "$excl" --argjson n "${#queries[@]}" '
    [group_by(.url)[] | (.[0] + {matched_by: ([.[].matched_by[]] | unique), queries: ([.[].query] | unique)}) | del(.query)]
    | map(select(.url as $u | $excl | index($u) == null))
    # Newest first, then (stable) the source-id hits and open items ahead.
    | sort_by(.updated_at) | reverse
    | sort_by([(if (.matched_by | index("id")) != null then 0 else 1 end), (if .state == "OPEN" then 0 else 1 end)])
    | . as $r
    | {status: "ok", queries: $n, count: ($r | length),
       from_source: [$r[] | select((.matched_by | index("id")) != null) | .url],
       results: $r}' "$acc")"
}

# ─── check ──────────────────────────────────────────────────────────────────
# shellcheck disable=SC2016  # $vars below are jq's or GraphQL's, not the shell's
JQ_CHECK='
def OUTCOMES: ["ticket", "duplicate", "commitment", "needs_info", "wont_do"];
def KINDS: ["followup", "meeting", "slack", "scratch", "issue", "text", "entity"];
def NEEDS: ["agent", "agent+aws", "agent+staff", "human"];
def SECTIONS: ["## Observation", "## Diagnosis", "## Shape", "## Acceptance and verification", "## Out of scope"];
def str: type == "string" and (. | test("\\S"));
def low: ascii_downcase;

# Lines with whether each sits inside a fenced code block.
def marked:
  split("\n")
  | reduce .[] as $l ({fence: false, out: []};
      if ($l | test("^\\s*(```|~~~)")) then .out += [{t: $l, f: true}] | .fence = (.fence | not)
      else .out += [{t: $l, f: .fence}] end)
  | .out;
def stop_line: (.f | not) and ((.t | test("^## ")) or (.t | test("^---\\s*$")));
# The lines of one ## section (outside fences), or null when the heading is missing.
def section($lines; $h):
  ([$lines | to_entries[] | select((.value.f | not) and .value.t == $h) | .key] | .[0]) as $i
  | if $i == null then null
    else ([$lines | to_entries[] | select(.key > $i and (.value | stop_line)) | .key] | .[0] // ($lines | length)) as $j
      | [$lines[$i + 1:$j][] | .t]
    end;
def nonblank: map(select(test("\\S")));

def verify_items($sec):
  # The lines after **Verify after release**, split into "- **name**" items.
  ([$sec | to_entries[] | select(.value | test("^\\*\\*Verify after release\\*\\*")) | .key] | .[0]) as $v
  | if $v == null then {missing: true}
    else ($sec[$v + 1:]) as $rest
      | if any($rest[]; test("^None:")) then {none: true, items: []}
        else {items: (reduce $rest[] as $l ([];
          if ($l | test("^- \\*\\*")) then . + [{name: ($l | sub("^- \\*\\*"; "") | sub("\\*\\*.*$"; "")), lines: []}]
          elif length > 0 then (length - 1) as $i | .[$i].lines += [$l]
          else . end))}
        end
    end;

def body_errors($issue; $plan; $keys):
  ($issue.key) as $k
  | (.body // "") as $b
  | ($b | marked) as $lines
  | [$lines[] | select(.f | not) | .t | sub("\\s+$"; "")] as $plain
  | ($plain | nonblank) as $nb
  | [
      # Every section, once, in order.
      (SECTIONS[] as $h
        | ([$lines[] | select((.f | not) and .t == $h)] | length) as $c
        | if $c == 0 then "\($k): missing the \($h) section"
          elif $c > 1 then "\($k): \($h) appears \($c) times"
          else empty end),
      (if ([SECTIONS[] as $h | [$lines | to_entries[] | select((.value.f | not) and .value.t == $h) | .key][0]] | map(select(. != null))) as $pos
            | $pos != ($pos | sort) then "\($k): the sections are out of order (Observation, Diagnosis, Shape, Acceptance and verification, Out of scope)"
       else empty end),

      # Observation: a verbatim quote.
      (section($lines; "## Observation") as $s
        | if $s == null then empty
          elif any($s[]; test("^>")) then empty
          else "\($k): Observation must quote the source verbatim in a blockquote (> …)" end),

      # Diagnosis: repos, code with file:line, cause, confidence.
      (section($lines; "## Diagnosis") as $s
        | if $s == null then empty
          else ($s | join("\n")) as $d
            | (("Repos", "Code", "Cause", "Confidence") as $f
                | if ($d | contains("**\($f):**")) then empty else "\($k): Diagnosis is missing **\($f):**" end),
              (if ($d | test("`[^`\\s]+:[0-9]+(-[0-9]+)?`")) then empty
               else "\($k): Diagnosis cites no code: add a `path/to/file:line` reference" end),
              (if ($d | contains("**Confidence:**")) and (($d | test("\\*\\*Confidence:\\*\\* *`?(high|medium|low)`?")) | not)
               then "\($k): **Confidence:** must be high, medium or low" else empty end)
          end),

      # Shape: present; an epic lists every sub-ticket.
      (section($lines; "## Shape") as $s
        | if $s == null then empty
          elif ($s | nonblank | length) == 0 then "\($k): Shape is empty"
          elif $k == "epic" then
            ($keys[] | select(. != "epic") as $sub
              | if any($s[]; test("^- \\[[ xX]\\] " + $sub + "\\b.*\\{\\{" + $sub + "\\}\\}")) then empty
                else "\($k): the Shape task list has no line for \($sub) (- [ ] \($sub) — {{\($sub)}} …)" end)
          else empty end),

      # Acceptance and verification: Done when + Verify after release.
      (section($lines; "## Acceptance and verification") as $s
        | if $s == null then empty
          else
            (if any($s[]; test("^\\*\\*Done when\\*\\*")) then empty else "\($k): Acceptance is missing **Done when**" end),
            (if any($s[]; test("^\\s*- \\[[ xX]\\] \\S")) then empty else "\($k): **Done when** needs at least one - [ ] item" end),
            (verify_items($s) as $v
              | if $v.missing then "\($k): Acceptance is missing **Verify after release**"
                elif $v.none then empty
                elif ($v.items | length) == 0 then "\($k): **Verify after release** has no checks; add one or write None: and the reason"
                else ($v.items[] as $it
                  | ($it.lines | map(sub("^\\s+- "; "- "))) as $ls
                  | (("needs", "how", "expect") as $f
                      | if any($ls[]; test("^- " + $f + ": *\\S")) then empty
                        else "\($k): check \"\($it.name)\" is missing \($f):" end),
                    ([$ls[] | select(test("^- needs:")) | sub("^- needs: *"; "") | gsub("`"; "") | sub("\\s+$"; "")][0] as $n
                      | if $n == null or (NEEDS | index($n)) != null then empty
                        else "\($k): check \"\($it.name)\" has needs: \($n); use agent, agent+aws, agent+staff or human" end))
                end)
          end),

      (section($lines; "## Out of scope") as $s
        | if $s == null then empty
          elif ($s | nonblank | length) == 0 then "\($k): Out of scope is empty"
          else empty end),

      # A sub-ticket opens with its Part of / Depends on line.
      (if $k == "epic" or ($issue.parent // null) == null then empty
       else ($nb[0] // "") as $first
         | (if ($first | startswith("Part of {{epic}}")) then empty
            else "\($k): a sub-ticket body must open with Part of {{epic}} (…)" end),
           (($issue.depends_on // [])[] as $dep
             | if ($first | contains("Depends on")) and ($first | contains("{{\($dep)}}")) then empty
               else "\($k): the first line must say Depends on {{\($dep)}}" end)
       end),

      # Footer: ---, the Provenance line, then the attribution line, last.
      (($nb | length) as $n
        | ($nb[$n - 1] // "") as $attr
        | (if ($attr | startswith("[🐦‍⬛ Created with Crow via ")) and ($attr | endswith("](https://github.com/corveil/crow)"))
           then empty else "\($k): the last line must be the Crow attribution line" end),
          (if ($nb[$n - 2] // "") == $plan.source.provenance then empty
           else "\($k): the line above the attribution must be the plan source.provenance line, exactly" end),
          (if ($nb[$n - 3] // "") | test("^---\\s*$") then empty
           else "\($k): put a --- rule above the Provenance line" end)),

      # Placeholders name filed keys only.
      ([$b | scan("\\{\\{([^}]*)\\}\\}")[0]] | unique[] as $ph
        | if ($keys | index($ph)) != null then empty
          else "\($k): {{\($ph)}} is not a key in this plan" end)
    ];

. as $plan
| ($plan.issues // []) as $issues
| ([$issues[].key]) as $keys
| [
    (if (OUTCOMES | index($plan.outcome)) != null then empty
     else "outcome must be one of \(OUTCOMES | join(", "))" end),
    (if ($plan.source | type) == "object" and (KINDS | index($plan.source.kind)) != null then empty
     else "source.kind must be one of \(KINDS | join(", "))" end),
    (if $plan.outcome == "ticket" then
       (if ($plan.source.provenance // "") | test("^Provenance: \\S") then empty
        else "source.provenance must be the footer line, starting with Provenance: " end),
       (if (["ticket", "epic"] | index($plan.shape)) != null then empty else "shape must be ticket or epic" end),
       (if ($issues | length) == 0 then "a ticket outcome needs issues" else empty end),
       (if ($keys | length) != ($keys | unique | length) then "issue keys must be unique" else empty end),
       ($issues[] | select((.key // "") | test("^(epic|T[0-9]+)$") | not) | "key \(.key // "null") must be epic or T1, T2, …"),
       (if $plan.shape == "ticket" then
          (if ($issues | length) == 1 then empty else "shape ticket files exactly one issue" end),
          ($issues[] | select(.key == "epic" or .parent != null or ((.depends_on // []) | length) > 0)
            | "\(.key): a single ticket has no epic, parent or depends_on")
        elif $plan.shape == "epic" then
          (if ($issues[0].key // "") == "epic" then empty else "an epic plan lists the epic issue first, with key epic" end),
          (if ([$issues[] | select(.key != "epic")] | length) >= 2 then empty else "an epic needs at least two sub-tickets" end),
          ($issues[] | select(.key == "epic" and .parent != null) | "epic: the epic has no parent"),
          ($issues[] | select(.key != "epic" and .parent != "epic") | "\(.key): a sub-ticket needs parent: epic"),
          ($issues | to_entries[] | .key as $pos | .value as $iss
            | ($iss.depends_on // [])[] as $dep
            | ([$issues | to_entries[] | select(.value.key == $dep) | .key][0]) as $dpos
            | if $dep == "epic" or $dep == $iss.key then "\($iss.key): depends_on can only name other sub-tickets"
              elif $dpos == null then "\($iss.key): depends_on names \($dep), which is not in the plan"
              elif $dpos >= $pos then "\($iss.key): depends_on \($dep), so list \($dep) first"
              else empty end)
        else empty end),
       ($issues[]
         | . as $iss
         | (if (.repo // "") | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") then empty else "\(.key): repo must be owner/name" end),
           (if (.title // "") | str then
              (if ((.title | length) <= 256) then empty else "\(.key): the title is over 256 characters" end),
              (if ($plan.source.quote // "") != "" and ((.title | low | sub("^\\s+"; "") | sub("\\s+$"; "")) == ($plan.source.quote | low | sub("^\\s+"; "") | sub("\\s+$"; "")))
               then "\(.key): the title is the raw quote; say what is wrong or wanted" else empty end)
            else "\(.key): title is required" end),
           (if ((.labels // []) | map(low) | index("triaged")) != null then empty else "\(.key): labels must include triaged" end),
           (if ((.labels // []) | map(low) | index("crow:auto")) != null then "\(.key): never label a diagnosed ticket crow:auto" else empty end),
           (if ((.body // "") | test("^[^/].*\\.md$")) and (((.body // "") | contains("..")) | not) then empty
            else "\(.key): body must be a relative .md path inside the run folder" end),
           (if $iss.missing then "\(.key): body file \(.body) does not exist" else empty end))
     else
       (if ($plan.reason // "") | str then empty else "a \($plan.outcome) outcome needs a reason" end),
       (if $plan.outcome == "duplicate" and ((($plan.link // "") | test("^https?://\\S+$")) | not)
        then "a duplicate outcome needs link: the existing issue URL" else empty end),
       (if ($issues | length) > 0 then "only a ticket outcome files issues; drop issues" else empty end)
     end)
  ] as $plan_errors
| ($plan_errors + (if $plan.outcome == "ticket"
    then [$issues[] | select(.missing | not) | . as $iss | ($bodies[0][$iss.key] // {}) | body_errors($iss; $plan; $keys)[]]
    else [] end)) as $errors
| {status: (if ($errors | length) == 0 then "ok" else "invalid" end), outcome: $plan.outcome,
   shape: ($plan.shape // null), issues: ($keys | length), errors: $errors}
'

# check_plan — prints the check result and returns 0 when it is ok.
check_plan() {
  [[ -n "$PLAN" ]] || die "parse_args" "needs --plan F"
  [[ -f "$PLAN" ]] || die "check" "$PLAN does not exist"
  jq -e 'type == "object"' "$PLAN" >/dev/null 2>&1 || invalid '["the plan is not a JSON object"]'
  local pdir bodies key body
  pdir=$(cd "$(dirname "$PLAN")" && pwd)
  # Removed below rather than through tmpfile: `file` runs this in a command
  # substitution, whose subshell never runs the EXIT trap.
  bodies=$(mktemp "${TMPDIR:-/tmp}/crow-diagnose.XXXXXX") || die "preflight" "cannot create a temp file"
  echo '{}' > "$bodies"
  while IFS=$'\t' read -r key body; do
    [[ -z "$key" ]] && continue
    if [[ -n "$body" && "$body" != /* && "$body" != *..* && -f "$pdir/$body" ]]; then
      jq -Rs --arg k "$key" --slurpfile acc "$bodies" '$acc[0] + {($k): {body: .}}' < "$pdir/$body" > "$bodies.next" && mv "$bodies.next" "$bodies"
    fi
  done < <(jq -r '(.issues // [])[] | [(.key // ""), (.body // "")] | @tsv' "$PLAN")
  local result
  result=$(jq -c --slurpfile bodies "$bodies" '
    .issues = [(.issues // [])[] | . + {missing: (((.key // "") as $k | $bodies[0] | has($k)) | not)}]' "$PLAN" \
    | jq -c --slurpfile bodies "$bodies" "$JQ_CHECK")
  local rc=$?
  rm -f "$bodies" "$bodies.next"
  [[ $rc -eq 0 && -n "$result" ]] || die "check" "the checker failed on $PLAN"
  printf '%s\n' "$result"
  [[ "$(jq -r .status <<<"$result")" == "ok" ]]
}

cmd_check() {
  if check_plan; then exit 0; else exit 1; fi
}

# ─── file ───────────────────────────────────────────────────────────────────
# render <plan> <filed> <key> — the body with every {{KEY}} replaced: #N in the
# same repo, owner/repo#N across repos, the bare key while it is unfiled.
# shellcheck disable=SC2016  # $vars below are jq's or GraphQL's, not the shell's
JQ_REFS='
($plan.issues[] | select(.key == $key) | .repo | ascii_downcase) as $repo
| reduce ($plan.issues[].key) as $k ({};
    .[$k] = (if $filed[$k] == null then $k
             elif ($filed[$k].repo | ascii_downcase) == $repo then "#\($filed[$k].number)"
             else "\($filed[$k].repo)#\($filed[$k].number)" end))
'

render_body() { # render_body <plan-json> <filed-json> <key> <src> <dest> — 0 when every key the body names is filed, 1 when one isn't yet, 2 on error
  local refs unresolved
  refs=$(jq -cn --argjson plan "$1" --argjson filed "$2" --arg key "$3" "$JQ_REFS") || return 2
  jq -Rr --argjson refs "$refs" 'reduce ($refs | to_entries[]) as $e (.; gsub("\\{\\{" + $e.key + "\\}\\}"; $e.value))' < "$4" > "$5" || return 2
  unresolved=$(jq -Rs --argjson filed "$2" '[scan("\\{\\{([^}]*)\\}\\}")[0]] | unique | map(select($filed[.] == null)) | length' < "$4") || return 2
  [[ "$unresolved" == "0" ]] && return 0
  return 1
}

cmd_file() {
  local cr rc
  cr=$(check_plan); rc=$?
  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$cr"
    [[ $rc -eq 2 ]] && exit 2
    exit 1
  fi
  local plan pdir filed_path filed
  plan=$(jq -c . "$PLAN")
  [[ "$(jq -r .outcome <<<"$plan")" == "ticket" ]] || die "file" "only a ticket outcome files issues"
  pdir=$(cd "$(dirname "$PLAN")" && pwd)
  filed_path="$pdir/filed.json"
  if [[ -f "$filed_path" ]]; then
    filed=$(jq -c '.issues // {}' "$filed_path" 2>/dev/null) || die "file" "$filed_path is unreadable; fix or remove it"
  else
    filed='{}'
  fi
  save_filed() { write_atomic "$filed_path" "$(jq -n --argjson i "$filed" '{issues: $i}')" || die "file" "cannot write $filed_path"; }

  # Preflight every label before filing anything: create triaged where it's
  # missing; any other missing label stops the run so an epic is never half filed.
  local warnings='[]' repo labels missing='[]' l
  while IFS= read -r repo; do
    labels=$("$GH_BIN" label list -R "$repo" --limit 1000 --json name 2>&1) || die "file" "gh label list -R $repo failed: $labels"
    while IFS= read -r l; do
      [[ -z "$l" ]] && continue
      if [[ "$(jq -r --arg l "$l" 'map(.name | ascii_downcase) | index($l | ascii_downcase) != null' <<<"$labels")" != "true" ]]; then
        if [[ "$(lower "$l")" == "$TRIAGED_LABEL" ]]; then
          local made
          made=$("$GH_BIN" label create "$TRIAGED_LABEL" -R "$repo" --color "$TRIAGED_COLOR" --description "$TRIAGED_DESCRIPTION" 2>&1) \
            || die "file" "cannot create the $TRIAGED_LABEL label in $repo: $made"
          warnings=$(jq -c --arg r "$repo" '. + ["created the triaged label in \($r)"]' <<<"$warnings")
        else
          missing=$(jq -c --arg r "$repo" --arg l "$l" '. + ["\($r) has no \($l) label"]' <<<"$missing")
        fi
      fi
    done < <(jq -r --arg r "$repo" '[.issues[] | select(.repo == $r) | .labels[]] | unique[]' <<<"$plan")
  done < <(jq -r '[.issues[].repo] | unique[]' <<<"$plan")
  [[ "$(jq 'length' <<<"$missing")" == "0" ]] || invalid "$(jq -c '. + ["nothing was filed: drop those labels from the plan or create them first"]' <<<"$missing")"

  local key title body tmp url num args
  tmpfile tmp
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    [[ "$(jq -r --arg k "$key" '.[$k] != null' <<<"$filed")" == "true" ]] && continue
    repo=$(jq -r --arg k "$key" '.issues[] | select(.key == $k) | .repo' <<<"$plan")
    title=$(jq -r --arg k "$key" '.issues[] | select(.key == $k) | .title' <<<"$plan")
    body=$(jq -r --arg k "$key" '.issues[] | select(.key == $k) | .body' <<<"$plan")
    local resolved=true
    render_body "$plan" "$filed" "$key" "$pdir/$body" "$tmp"
    case $? in
      0) ;;
      1) resolved=false ;;
      *) die "file" "cannot render $key's body" ;;
    esac
    args=(issue create -R "$repo" --title "$title" --body-file "$tmp")
    while IFS= read -r l; do [[ -n "$l" ]] && args+=(--label "$l"); done \
      < <(jq -r --arg k "$key" '.issues[] | select(.key == $k) | .labels[]' <<<"$plan")
    url=$("$GH_BIN" "${args[@]}" 2>&1) || die "file" "gh issue create for $key failed: $url (filed so far: $(jq -c 'map_values(.url)' <<<"$filed"))"
    url=$(printf '%s\n' "$url" | grep -Eo 'https://[^[:space:]]+/issues/[0-9]+' | tail -n 1)
    [[ -n "$url" ]] || die "file" "gh issue create for $key printed no issue URL"
    num="${url##*/}"
    filed=$(jq -c --arg k "$key" --arg r "$repo" --arg u "$url" --argjson n "$num" --argjson resolved "$resolved" \
      '.[$k] = {repo: $r, number: $n, url: $u, rendered: $resolved, linked: false}' <<<"$filed")
    save_filed
  done < <(jq -r '.issues[].key' <<<"$plan")

  # Second pass: a body filed while a key it names (an epic's task list, a
  # forward reference) was unfiled gets its numbers filled in now.
  local edit_out
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    [[ "$(jq -r --arg k "$key" '.[$k].rendered' <<<"$filed")" == "true" ]] && continue
    repo=$(jq -r --arg k "$key" '.[$k].repo' <<<"$filed")
    num=$(jq -r --arg k "$key" '.[$k].number' <<<"$filed")
    body=$(jq -r --arg k "$key" '.issues[] | select(.key == $k) | .body' <<<"$plan")
    render_body "$plan" "$filed" "$key" "$pdir/$body" "$tmp" || die "file" "cannot render $key's body"
    edit_out=$("$GH_BIN" issue edit "$num" -R "$repo" --body-file "$tmp" 2>&1) \
      || { warnings=$(jq -c --arg k "$key" --arg e "$edit_out" '. + ["could not fill in the issue numbers on \($k); run file again: \($e)"]' <<<"$warnings"); continue; }
    filed=$(jq -c --arg k "$key" '.[$k].rendered = true' <<<"$filed")
    save_filed
  done < <(jq -r '.issues[].key' <<<"$plan")

  # Sub-issues, so the board and /crow-backlog-brief see the epic's children.
  local parent pr pn cid out
  while IFS=$'\t' read -r key parent; do
    [[ -z "$key" ]] && continue
    [[ "$(jq -r --arg k "$key" '.[$k].linked' <<<"$filed")" == "true" ]] && continue
    repo=$(jq -r --arg k "$key" '.[$k].repo' <<<"$filed"); num=$(jq -r --arg k "$key" '.[$k].number' <<<"$filed")
    pr=$(jq -r --arg k "$parent" '.[$k].repo' <<<"$filed"); pn=$(jq -r --arg k "$parent" '.[$k].number' <<<"$filed")
    if cid=$("$GH_BIN" api "repos/$repo/issues/$num" --jq .id 2>&1) && [[ "$cid" =~ ^[0-9]+$ ]] \
       && out=$("$GH_BIN" api -X POST "repos/$pr/issues/$pn/sub_issues" -F sub_issue_id="$cid" 2>&1); then
      filed=$(jq -c --arg k "$key" '.[$k].linked = true' <<<"$filed")
      save_filed
    else
      warnings=$(jq -c --arg k "$key" --arg e "${out:-$cid}" '. + ["could not add \($k) as a sub-issue of the epic (the Part of line still links it): \($e)"]' <<<"$warnings")
    fi
  done < <(jq -r '.issues[] | select(.parent != null) | [.key, .parent] | @tsv' <<<"$plan")

  emit "$(jq -cn --argjson plan "$plan" --argjson filed "$filed" --argjson w "$warnings" \
    '{status: "ok", shape: $plan.shape,
      filed: [$plan.issues[] | .key as $k | {key: $k, title, repo: $filed[$k].repo, number: $filed[$k].number, url: $filed[$k].url}],
      warnings: $w}')"
}

# ─── main ───────────────────────────────────────────────────────────────────
sub="${1:-}"
[[ $# -gt 0 ]] && shift
case "$sub" in
  workspace) require_jq_16; parse_args "$@"; cmd_workspace ;;
  repos)     require_jq_16; parse_args "$@"; cmd_repos ;;
  checkout)  require_jq_16; parse_args "$@"; cmd_checkout ;;
  source)    require_jq_16; parse_args "$@"; cmd_source ;;
  dupes)     require_jq_16; parse_args "$@"; cmd_dupes ;;
  check)     require_jq_16; parse_args "$@"; cmd_check ;;
  file)      require_jq_16; parse_args "$@"; cmd_file ;;
  corveil)   require_jq_16; cmd_corveil "$@" ;;
  --help|-h|"") usage ;;
  *) die "parse_args" "unknown subcommand: $sub (expected workspace, repos, checkout, source, dupes, check, file or corveil)" ;;
esac
