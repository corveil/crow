#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2012  # fixtures hold literal backticks and $(...); ls lists our own fixture names
# Unit tests for diagnose.sh (CROW-1415): workspace resolution, the repo
# listing and its glob filter, scratch clones at origin's default branch,
# source resolution (Scratch, FollowUp + transcript window, meeting, Slack,
# issue, text), the duplicate search, the ticket-standard check, filing with
# placeholders, sub-issues and resume, and the read-only corveil wrapper.
#
# Drives diagnose.sh as a subprocess against a fake `gh`, `crow` and `corveil`
# (answers from fixture files, logs every call) and a local bare git origin,
# so nothing touches GitHub, Corveil or a running daemon.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAGNOSE_SH="$SCRIPT_DIR/diagnose.sh"

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1415-diagnose-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fixtures"
mkdir -p "$FIX"
export FIX

# ─── fakes ───────────────────────────────────────────────────────────────────
# Fake gh. Every call is appended to $FIX/gh.log, one line per call.
cat > "$TMP/fake-gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/gh.log"
repo=""; owner=""; q=""; title=""; bodyfile=""; labels=""
for ((i = 1; i <= $#; i++)); do
  a="${!i}"; j=$((i + 1))
  case "$a" in
    -R) repo="${!j}" ;;
    --title) title="${!j}" ;;
    --body-file) bodyfile="${!j}" ;;
    --label) labels="$labels,${!j}" ;;
    owner=*) owner="${a#owner=}" ;;
    q=*) q="${a#q=}" ;;
  esac
done
case "$1 $2" in
  "api graphql")
    if [[ -n "$owner" ]]; then
      f="$FIX/repos-$owner.json"
      if [[ -f "$f" ]]; then cat "$f"; else echo '{"data":{"repositoryOwner":null}}'; fi
    else
      printf '%s\n' "$q" >> "$FIX/search.log"
      case "$q" in
        *"in:title,body"*) cat "$FIX/search-id.json" ;;
        *) cat "$FIX/search-terms.json" ;;
      esac
    fi ;;
  "repo clone")
    src="$FIX/origin-${3//\//__}.git"
    git clone -q "$src" "$4" || exit 1
    git -C "$4" config remote.origin.url "https://github.com/$3.git"
    git -C "$4" config "url.$src.insteadOf" "https://github.com/$3.git" ;;
  "issue view")
    f="$FIX/issue-${repo//\//__}-$3.json"
    [[ -f "$f" ]] || { echo "GraphQL: Could not resolve to an issue" >&2; exit 1; }
    cat "$f" ;;
  "issue create")
    n=$(cat "$FIX/next-number" 2>/dev/null || echo 100)
    [[ -f "$FIX/fail-create-at" && "$(cat "$FIX/fail-create-at")" == "$n" ]] && { echo "HTTP 502: fake outage" >&2; exit 1; }
    echo $((n + 1)) > "$FIX/next-number"
    cp "$bodyfile" "$FIX/created-$n.md"
    printf '%s\t%s\t%s\n' "$n" "$repo" "$title" >> "$FIX/created.log"
    printf '%s\n' "${labels#,}" > "$FIX/labels-$n"
    echo "Creating issue in $repo"
    echo "https://github.com/$repo/issues/$n" ;;
  "issue edit")
    cp "$bodyfile" "$FIX/edited-$3.md" ;;
  "label list")
    f="$FIX/labels-${repo//\//__}.json"
    if [[ -f "$f" ]]; then cat "$f"; else echo '[{"name":"triaged"},{"name":"enhancement"}]'; fi ;;
  "label create")
    printf '%s %s\n' "$3" "$repo" >> "$FIX/label-create.log" ;;
  "api repos/"*)
    case "$2" in
      */issues/*) n="${2##*/}"; echo $((9000 + n)) ;;
      *) r="${2#repos/}"; f="$FIX/visibility-${r//\//__}"
         if [[ -f "$f" ]]; then cat "$f"; else echo private; fi ;;
    esac ;;
  "api -X")
    [[ -f "$FIX/fail-subissue" ]] && { echo "HTTP 422: sub-issues are not enabled" >&2; exit 1; }
    printf '%s %s\n' "$4" "$6" >> "$FIX/subissue.log"
    echo '{}' ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
SH
cat > "$TMP/fake-crow" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "workspace list") cat "$FIX/workspaces.json" ;;
  "get-session --session") [[ -f "$FIX/session.json" ]] || exit 1; cat "$FIX/session.json" ;;
  "defaults get") [[ -f "$FIX/defaults.json" ]] && cat "$FIX/defaults.json" || echo '{"defaults":{}}' ;;
  "todo get")
    f="$FIX/todo-$4.json"
    [[ -f "$f" ]] || { echo "Error: Error -32000: Todo not found"; exit 64; }
    cat "$f" ;;
  *) echo "fake crow: unexpected call: $*" >&2; exit 1 ;;
esac
SH
cat > "$TMP/fake-corveil" <<'SH'
#!/usr/bin/env bash
printf 'capture_off=%s args=%s\n' "${CORVEIL_NO_CAPTURE:-}" "$*" >> "$FIX/corveil.log"
case "$1" in
  entity|evidence|event)
    # The first argument that isn't a flag is the id (corveil takes flags anywhere).
    id=""; skip=0
    for a in "${@:2}"; do
      if [[ $skip -eq 1 ]]; then skip=0; continue; fi
      case "$a" in --limit) skip=1 ;; --*) ;; *) id="$a"; break ;; esac
    done
    f="$FIX/$1-$id.json"
    [[ -f "$f" ]] || { echo "Error: server error (404)" >&2; exit 1; }
    cat "$f" ;;
  *) printf '{"capture_off":"%s","args":"%s"}\n' "${CORVEIL_NO_CAPTURE:-}" "$*" ;;
esac
SH
chmod +x "$TMP/fake-gh" "$TMP/fake-crow" "$TMP/fake-corveil"
export GH_BIN="$TMP/fake-gh" CROW_BIN="$TMP/fake-crow" CORVEIL_BIN="$TMP/fake-corveil"
unset CROW_SESSION_ID

D() { bash "$DIAGNOSE_SH" "$@"; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }

cat > "$FIX/workspaces.json" <<'JSON'
{"workspaces": [
  {"id": "W1", "name": "Acme", "provider": "github", "task_provider": "github", "host": null,
   "always_include": ["acme/*"], "auto_review_repos": ["partner/wid*"]},
  {"id": "W2", "name": "Widgets", "provider": "github", "task_provider": "jira", "host": null,
   "always_include": ["partner/widget"], "auto_review_repos": []},
  {"id": "W3", "name": "Lab", "provider": "gitlab", "task_provider": "gitlab", "host": "gitlab.example.com",
   "always_include": ["lab/*"], "auto_review_repos": []}
]}
JSON

# ─── usage ───────────────────────────────────────────────────────────────────
echo "usage"
check "no subcommand is a usage error" "2" "$(rc_of D)"
out=$(D frobnicate)
check "an unknown subcommand is refused" "error" "$(jq -r .status <<<"$out")"
check "an unknown flag is refused" "2" "$(rc_of D workspace --bogus x)"

# ─── workspace ───────────────────────────────────────────────────────────────
echo "workspace"
out=$(D workspace --workspace acme)
check "a flag matches case-insensitively" "Acme flag" "$(jq -r '"\(.workspace.name) \(.how)"' <<<"$out")"
check "owners come from owner/* and owner/name patterns" '["acme","partner"]' "$(jq -c .owners <<<"$out")"
out=$(D workspace --workspace W2)
check "a flag matches a workspace id" "Widgets" "$(jq -r .workspace.name <<<"$out")"
check "task_provider is reported" "jira" "$(jq -r .workspace.task_provider <<<"$out")"
out=$(D workspace --repo partner/widget)
check "a workspace naming the repo exactly beats an earlier glob" "Widgets repo" "$(jq -r '"\(.workspace.name) \(.how)"' <<<"$out")"
out=$(D workspace --repo acme/api)
check "a glob claims a repo" "Acme repo" "$(jq -r '"\(.workspace.name) \(.how)"' <<<"$out")"
echo '{"workspace_name": "Widgets"}' > "$FIX/session.json"
out=$(CROW_SESSION_ID=S1 D workspace)
check "the Manager's workspace tag is next" "Widgets manager" "$(jq -r '"\(.workspace.name) \(.how)"' <<<"$out")"
out=$(CROW_SESSION_ID=S1 D workspace --repo acme/api)
check "a repo claim beats the Manager's tag" "Acme" "$(jq -r .workspace.name <<<"$out")"
rm -f "$FIX/session.json"
echo '{"defaults": {"manager_workspace": "Acme"}}' > "$FIX/defaults.json"
out=$(D workspace)
check "defaults.manager_workspace after that" "Acme default" "$(jq -r '"\(.workspace.name) \(.how)"' <<<"$out")"
rm -f "$FIX/defaults.json"
out=$(D workspace)
check "several workspaces and no signal is an error" "error" "$(jq -r .status <<<"$out")"
contains "the error names the workspaces" "$(jq -r .message <<<"$out")" "Acme, Widgets, Lab"
out=$(D workspace --workspace nope)
check "an unknown workspace is an error" "error" "$(jq -r .status <<<"$out")"
out=$(D workspace --workspace Lab)
contains "a GitLab workspace warns that the GitHub steps refuse it" "$(jq -r '.warnings | join(" ")' <<<"$out")" "not on GitHub"
cp "$FIX/workspaces.json" "$FIX/workspaces.all.json"
jq '.workspaces = [.workspaces[0]]' "$FIX/workspaces.all.json" > "$FIX/workspaces.json"
out=$(D workspace)
check "the only workspace resolves on its own" "Acme only" "$(jq -r '"\(.workspace.name) \(.how)"' <<<"$out")"
cp "$FIX/workspaces.all.json" "$FIX/workspaces.json"

# ─── repos ───────────────────────────────────────────────────────────────────
echo "repos"
node() { # node <slug> <description> <pushed>
  jq -cn --arg r "$1" --arg d "$2" --arg p "$3" '{nameWithOwner: $r, description: $d, isFork: false, pushedAt: $p,
    visibility: (if $r == "acme/api" then "PUBLIC" else "PRIVATE" end),
    primaryLanguage: {name: "Go"}, defaultBranchRef: {name: "main"}, repositoryTopics: {nodes: [{topic: {name: "api"}}]}}'
}
page() { # page <owner> <node-json>... — one GraphQL page
  local owner="$1"; shift
  printf '%s\n' "$@" | jq -cs --arg o "$owner" '{data: {repositoryOwner: {login: $o, repositories: {nodes: ., pageInfo: {hasNextPage: false, endCursor: null}}}}}'
}
# Two pages for acme, as `gh api graphql --paginate` prints them.
{ page acme "$(node acme/api "The API" 2026-11-01T00:00:00Z)" "$(node acme/web "" 2026-11-08T00:00:00Z)"
  page acme "$(node acme/docs "Docs site" 2026-10-01T00:00:00Z)"; } > "$FIX/repos-acme.json"
page partner "$(node partner/widget "Widget" 2026-11-05T00:00:00Z)" "$(node partner/other "Not claimed" 2026-11-09T00:00:00Z)" > "$FIX/repos-partner.json"
out=$(D repos --workspace Acme --out "$TMP/repos.json")
check "repos is ok" "ok" "$(jq -r .status <<<"$out")"
check "every claimed repo across pages and owners, newest push first" "acme/web,partner/widget,acme/api,acme/docs" "$(jq -r '[.repos[].repo] | join(",")' <<<"$out")"
check "an unclaimed repo of a listed owner is left out" "0" "$(jq '[.repos[] | select(.repo == "partner/other")] | length' <<<"$out")"
check "description, language, topics and default branch come along" "The API Go api main" "$(jq -r '.repos[] | select(.repo == "acme/api") | "\(.description) \(.language) \(.topics[0]) \(.default_branch)"' <<<"$out")"
check "--out writes the same JSON" "$(jq -c . <<<"$out")" "$(jq -c . "$TMP/repos.json")"
check "each repo reports its visibility, so a public one can be called out" "public private" "$(jq -r '[(.repos[] | select(.repo == "acme/api") | .visibility), (.repos[] | select(.repo == "acme/web") | .visibility)] | join(" ")' <<<"$out")"
check "one GraphQL call per owner" "2" "$(grep -c '^api graphql' "$FIX/gh.log")"
out=$(D repos --workspace Acme --repos acme/API,partner/other)
check "--repos keeps only those, matched case-insensitively" "acme/api,partner/other" "$(jq -r '[.repos[].repo] | sort | join(",")' <<<"$out")"
out=$(D repos --workspace Acme --repos acme/api,acme/gone)
check "a --repos entry that doesn't exist is invalid" "invalid" "$(jq -r .status <<<"$out")"
contains "and names the missing repo" "$(jq -r '.errors[0]' <<<"$out")" "acme/gone"
check "which exits 1" "1" "$(rc_of D repos --workspace Acme --repos acme/gone)"
out=$(D repos --workspace Acme --repos ghost/thing)
check "an owner GitHub doesn't know is an error" "error" "$(jq -r .status <<<"$out")"
out=$(D repos --workspace Lab)
check "a GitLab workspace is refused" "error" "$(jq -r .status <<<"$out")"
out=$(D repos --workspace Acme --repos 'acme/api;rm')
check "a malformed --repos slug is refused" "error" "$(jq -r .status <<<"$out")"
check "repos needs --workspace" "2" "$(rc_of D repos)"

# ─── checkout ────────────────────────────────────────────────────────────────
echo "checkout"
DEVROOT="$TMP/devroot"
mkdir -p "$DEVROOT"
gitq() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@"; }
seed="$TMP/seed"
gitq init -q "$seed"
echo "first" > "$seed/README.md"
gitq -C "$seed" add README.md
gitq -C "$seed" commit -q -m first
git clone -q --bare "$seed" "$FIX/origin-acme__api.git"
git -C "$FIX/origin-acme__api.git" symbolic-ref HEAD refs/heads/main
first_sha=$(git -C "$seed" rev-parse HEAD)
out=$(D checkout --repo acme/api --dev-root "$DEVROOT")
check "a first checkout clones" "ok true" "$(jq -r '"\(.status) \(.cloned)"' <<<"$out")"
check "into crow-reviews, which the repo scan skips, with -- between owner and name" "$DEVROOT/crow-reviews/diagnose-acme--api" "$(jq -r .path <<<"$out")"
check "at origin's default branch" "origin/main $first_sha" "$(jq -r '"\(.ref) \(.sha)"' <<<"$out")"
check "the files are on disk" "first" "$(cat "$DEVROOT/crow-reviews/diagnose-acme--api/README.md")"
echo "second" > "$seed/README.md"
gitq -C "$seed" commit -q -am second
git -C "$seed" push -q "$FIX/origin-acme__api.git" main
echo "local junk" > "$DEVROOT/crow-reviews/diagnose-acme--api/junk.txt"
out=$(D checkout --repo acme/api --dev-root "$DEVROOT" --branch main)
check "a second checkout fetches instead of cloning" "false" "$(jq -r .cloned <<<"$out")"
check "and moves to the new origin/main" "$(git -C "$seed" rev-parse HEAD)" "$(jq -r .sha <<<"$out")"
check "the tree matches origin" "second" "$(cat "$DEVROOT/crow-reviews/diagnose-acme--api/README.md")"
check "and leftovers are cleaned" "no" "$([[ -e "$DEVROOT/crow-reviews/diagnose-acme--api/junk.txt" ]] && echo yes || echo no)"
check "one clone across both calls" "1" "$(grep -c '^repo clone' "$FIX/gh.log")"
git -C "$DEVROOT/crow-reviews/diagnose-acme--api" config remote.origin.url https://github.com/acme/other.git
out=$(D checkout --repo acme/api --dev-root "$DEVROOT")
check "a clone of another repo at that path is refused" "error" "$(jq -r .status <<<"$out")"
contains "and named" "$(jq -r .message <<<"$out")" "acme/other"
mkdir -p "$DEVROOT/crow-reviews/diagnose-acme--web"
out=$(D checkout --repo acme/web --dev-root "$DEVROOT")
check "a directory that isn't a clone is refused" "error" "$(jq -r .status <<<"$out")"
out=$(D checkout --repo acme/api --dev-root "$DEVROOT" --branch 'main;rm')
check "a branch name with shell characters is refused" "error" "$(jq -r .status <<<"$out")"
out=$(D checkout --repo acme/api)
contains "outside a scaffolded dev root, --dev-root is required" "$(jq -r .message <<<"$out")" "--dev-root"

# ─── source ──────────────────────────────────────────────────────────────────
echo "source"
BASE="$TMP/diagnose"
SCRATCH_ID="4B7D0C52-9A1E-4C33-8F0E-2D6A1B9C7E41"
cat > "$FIX/todo-$SCRATCH_ID.json" <<'JSON'
{"todo": {"id": "4B7D0C52-9A1E-4C33-8F0E-2D6A1B9C7E41", "text": "explore has no idea where it came from", "note": null,
  "tags": ["scratch"], "state": "captured", "workspace": "Acme",
  "links": [{"id": "L1", "type": "custom", "label": "Slack thread", "url": "https://acme.slack.com/archives/C1/p1762441200000000"},
            {"id": "L2", "type": "ticket", "label": "acme/api#7", "url": "https://github.com/acme/api/issues/7"}]}}
JSON
out=$(D source --id "$SCRATCH_ID" --dir "$BASE")
check "a Scratch id resolves to a Scratch item" "ok scratch scratch-4b7d0c52" "$(jq -r '"\(.status) \(.kind) \(.run_id)"' <<<"$out")"
check "its ticket links are existing tickets" '["https://github.com/acme/api/issues/7"]' "$(jq -c .existing_tickets <<<"$out")"
check "source.json keeps the item's text and links" "explore has no idea where it came from 2" "$(jq -r '"\(.scratch.text) \(.scratch.links | length)"' "$BASE/scratch-4b7d0c52/source.json")"
check "a Scratch hit never calls corveil" "no" "$([[ -f "$FIX/corveil.log" ]] && echo yes || echo no)"

FU="05d9dcd9-e6a3-4450-a3be-34665e204be7"; MEET="3e695928-34ef-49fd-8e12-2e442ef43058"; TR="359027b7-d49c-4970-b8a7-3f7c32d59f17"
cat > "$FIX/entity-$FU.json" <<JSON
{"id": "$FU", "entity_type": "FollowUp", "canonical_name": "Create preliminary triage tickets",
 "properties": {"assignee": "Dana", "kind": "commitment", "status": "open", "meeting_date": "2026-11-06",
   "quote": "maybe I should create the preliminary tickets", "said_at": "15:59:03",
   "source_meeting_id": "$MEET", "ticket_url": "https://github.com/acme/api/issues/9"}}
JSON
cat > "$FIX/entity-$MEET.json" <<JSON
{"id": "$MEET", "entity_type": "Meeting", "canonical_name": "Google Meet — 2026-11-06 15:19 UTC",
 "properties": {"attendees": ["Dana", "Lee"], "meeting_date": "2026-11-06T15:19:05Z", "summary": "A sync."}}
JSON
cat > "$FIX/evidence-$MEET.json" <<JSON
{"count": 3, "source_events": [
  {"id": "aaaaaaaa-0000-0000-0000-000000000001", "category": "provenance", "source": "ontology_write", "content_preview": "Reason: …"},
  {"id": "aaaaaaaa-0000-0000-0000-000000000002", "category": "meeting", "source": "googlecalendar", "content_preview": "Daily Check-In"},
  {"id": "$TR", "category": "meeting", "source": "googlemeet", "content_preview": "**Lee** (15:27:44): Yo"}]}
JSON
transcript=$(printf '%s\n' \
  '**Lee** (15:50:00): too early, outside the window' '' \
  '**Lee** (15:54:03): exactly five minutes before' '' \
  '**Dana** (15:58:37): something triages it that has the code in mind' \
  'and writes the ticket' '' \
  '**Dana** (15:59:03): maybe I should create the preliminary tickets' '' \
  '**Lee** (16:04:03): exactly five minutes after' '' \
  '**Lee** (16:04:04): one second too late')
jq -n --arg c "$transcript" --arg id "$TR" '{id: $id, category: "meeting", source: "googlemeet", content: $c}' > "$FIX/event-$TR.json"
out=$(D source --id "$FU" --dir "$BASE")
check "a FollowUp id falls through Scratch to Corveil" "ok followup followup-05d9dcd9" "$(jq -r '"\(.status) \(.kind) \(.run_id)"' <<<"$out")"
check "its ticket_url is an existing ticket" '["https://github.com/acme/api/issues/9"]' "$(jq -c .existing_tickets <<<"$out")"
SRC="$BASE/followup-05d9dcd9/source.json"
check "the FollowUp's fields are kept" "commitment|maybe I should create the preliminary tickets|15:59:03" "$(jq -r '.followup | "\(.kind)|\(.quote)|\(.said_at)"' "$SRC")"
check "the transcript is the googlemeet source, not the calendar entry" "$TR" "$(jq -r .transcript.source_id "$SRC")"
check "the window is 5 minutes either side, inclusive" "15:54:03 16:04:03 4" "$(jq -r '.transcript | "\(.from) \(.to) \(.lines | length)"' "$SRC")"
check "a continuation line joins its utterance" "something triages it that has the code in mind and writes the ticket" "$(jq -r '.transcript.lines[] | select(.at == "15:58:37") | .text' "$SRC")"
check "the meeting's attendees come along" "Dana,Lee" "$(jq -r '.meeting.attendees | join(",")' "$SRC")"
check "the whole transcript was counted" "6" "$(jq -r .transcript.total_lines "$SRC")"
check "every corveil call passed --no-capture" "0" "$(grep -vc -- '--no-capture' "$FIX/corveil.log")"
check "with CORVEIL_NO_CAPTURE=1 in the environment" "0" "$(grep -vc '^capture_off=1 ' "$FIX/corveil.log")"
out=$(D source --id "$FU" --dir "$BASE" --minutes 1)
check "--minutes narrows the window" "2" "$(jq '.transcript.lines | length' "$SRC")"
echo '{"issues": {"T1": {"repo": "acme/api", "number": 500, "url": "https://github.com/acme/api/issues/500", "title": "Old"}}}' > "$BASE/followup-05d9dcd9/filed.json"
out=$(D source --id "$FU" --dir "$BASE")
check "a source whose folder already filed gets a fresh run folder" "followup-05d9dcd9-2" "$(jq -r .run_id <<<"$out")"
contains "and warns with what the earlier run filed" "$(jq -r '.warnings | join(" ")' <<<"$out")" "followup-05d9dcd9: T1 https://github.com/acme/api/issues/500"
check "the earlier run's folder is left alone" "Old" "$(jq -r .issues.T1.title "$BASE/followup-05d9dcd9/filed.json")"
echo '{"issues": {"T1": {"repo": "acme/api", "number": 501, "url": "https://github.com/acme/api/issues/501"}}}' > "$BASE/followup-05d9dcd9-2/filed.json"
out=$(D source --id "$FU" --dir "$BASE")
check "and the next one after that" "followup-05d9dcd9-3" "$(jq -r .run_id <<<"$out")"
contains "listing both earlier runs" "$(jq -r '.warnings | join(" ")' <<<"$out")" "followup-05d9dcd9-2: T1 https://github.com/acme/api/issues/501"
out=$(D source --id "$MEET" --dir "$BASE")
check "a meeting id without --at is refused" "error" "$(jq -r .status <<<"$out")"
contains "with a hint to pass --at" "$(jq -r .message <<<"$out")" "--at"
out=$(D source --id "$MEET" --at 16:04 --dir "$BASE")
check "a meeting and a time" "ok meeting meeting-3e695928-1604" "$(jq -r '"\(.status) \(.kind) \(.run_id)"' <<<"$out")"
check "centres the window on that time" "15:59:00 16:09:00 3" "$(jq -r '.transcript | "\(.from) \(.to) \(.lines | length)"' "$BASE/meeting-3e695928-1604/source.json")"
FU2="11111111-2222-3333-4444-555555555555"
cat > "$FIX/entity-$FU2.json" <<JSON
{"id": "$FU2", "entity_type": "FollowUp", "canonical_name": "Send the deck", "properties": {"kind": "commitment", "quote": "I'll send the deck", "status": "open"}}
JSON
out=$(D source --id "$FU2" --dir "$BASE")
check "a FollowUp with no meeting still resolves" "ok 0" "$(jq -r '"\(.status) \(.summary.transcript_lines)"' <<<"$out")"
check "with no existing tickets" "[]" "$(jq -c .existing_tickets <<<"$out")"
FU3="11111111-2222-3333-4444-666666666666"
cat > "$FIX/entity-$FU3.json" <<JSON
{"id": "$FU3", "entity_type": "FollowUp", "canonical_name": "x", "properties": {"kind": "action", "quote": "q", "said_at": "10:00:00", "source_meeting_id": "$FU2"}}
JSON
out=$(D source --id "$FU3" --dir "$BASE")
contains "a FollowUp whose meeting isn't a Meeting warns" "$(jq -r '.warnings | join(" ")' <<<"$out")" "not a Meeting"
out=$(D source --id 99999999-0000-0000-0000-000000000000 --dir "$BASE")
check "an id that is neither is an error" "error" "$(jq -r .status <<<"$out")"
out=$(D source --id not-a-uuid --dir "$BASE")
check "a non-UUID id is refused" "error" "$(jq -r .status <<<"$out")"
out=$(D source --id "$MEET" --at '15:59; rm -rf /' --dir "$BASE")
check "a malformed --at is refused" "error" "$(jq -r .status <<<"$out")"
out=$(CORVEIL_BIN="$TMP/no-such-corveil" D source --id "$FU" --dir "$BASE")
contains "no corveil CLI is a clear error" "$(jq -r .message <<<"$out")" "no corveil CLI"

out=$(D source --url "https://acme.slack.com/archives/C0123ABC/p1762441300123456?thread_ts=1762441200.000100&cid=C0123ABC" --dir "$BASE")
check "a Slack reply permalink parses" "ok slack slack-c0123abc-1762441200000100" "$(jq -r '"\(.status) \(.kind) \(.run_id)"' <<<"$out")"
check "to the channel, message and thread root" "C0123ABC 1762441300.123456 1762441200.000100 true" "$(jq -r '.slack | "\(.channel) \(.ts) \(.thread_ts) \(.is_reply)"' "$BASE/slack-c0123abc-1762441200000100/source.json")"
out=$(D source --url "https://acme.slack.com/archives/C0123ABC/p1762441200000100" --dir "$BASE")
check "a root permalink is its own thread" "1762441200.000100" "$(jq -r .summary.thread_ts <<<"$out")"

cat > "$FIX/issue-acme__api-1413.json" <<'JSON'
{"number": 1413, "url": "https://github.com/acme/api/issues/1413", "title": "maybe create the tickets", "state": "OPEN", "stateReason": null,
 "labels": [{"name": "enhancement"}], "author": {"login": "dana"}, "createdAt": "2026-11-06T16:00:00Z",
 "body": "> maybe I should create the preliminary tickets\n\n---\nCorveil FollowUp `05d9dcd9-e6a3-4450-a3be-34665e204be7`\nFiled with `/my-follow-ups` from the Corveil Follow-up Ledger.",
 "comments": [{"author": {"login": "lee"}, "createdAt": "2026-11-07T00:00:00Z", "body": "+1"}]}
JSON
out=$(D source --url https://github.com/acme/api/issues/1413 --dir "$BASE")
check "an issue URL resolves" "ok issue issue-acme-api-1413" "$(jq -r '"\(.status) \(.kind) \(.run_id)"' <<<"$out")"
check "a raw issue is not diagnosed" "false" "$(jq -r .summary.diagnosed <<<"$out")"
check "its body and comments are kept" "true 1" "$(jq -r '.issue | "\(.body | contains("Filed with")) \(.comments | length)"' "$BASE/issue-acme-api-1413/source.json")"
jq '.body = "## Observation\n\n> x\n\n## Diagnosis\n\n- **Repos:** acme/api"' "$FIX/issue-acme__api-1413.json" > "$FIX/issue-acme__api-1414.json"
out=$(D source --url https://github.com/acme/api/issues/1414 --dir "$BASE")
check "an issue with a Diagnosis section is diagnosed" "true" "$(jq -r .summary.diagnosed <<<"$out")"
out=$(D source --url "https://evil.example.com/issues/1" --dir "$BASE")
check "any other URL is refused" "error" "$(jq -r .status <<<"$out")"

printf 'the export button is greyed out "$(rm -rf ~)" for admins\n' > "$TMP/text.txt"
out=$(D source --text-file "$TMP/text.txt" --dir "$BASE" --now 2026-11-09T14:15:00Z)
check "plain text resolves" "ok text text-20261109-141500" "$(jq -r '"\(.status) \(.kind) \(.run_id)"' <<<"$out")"
check "and is kept byte for byte, never interpreted" "$(cat "$TMP/text.txt")" "$(jq -r .text "$BASE/text-20261109-141500/source.json")"
: > "$TMP/empty.txt"
out=$(D source --text-file "$TMP/empty.txt" --dir "$BASE")
check "an empty text file is refused" "error" "$(jq -r .status <<<"$out")"
check "source needs exactly one input" "2" "$(rc_of D source --id "$FU" --url https://github.com/acme/api/issues/1 --dir "$BASE")"
check "source needs --dir" "2" "$(rc_of D source --id "$FU")"

# ─── dupes ───────────────────────────────────────────────────────────────────
echo "dupes"
hit() { # hit <type> <repo> <n> <state> <updated> <body>
  jq -cn --arg t "$1" --arg r "$2" --argjson n "$3" --arg s "$4" --arg u "$5" --arg b "$6" \
    '{__typename: $t, number: $n, title: "t\($n)", url: "https://github.com/\($r)/\(if $t == "PullRequest" then "pull" else "issues" end)/\($n)",
      state: $s, stateReason: null, closedAt: null, updatedAt: $u, body: $b, repository: {nameWithOwner: $r}}'
}
search() { printf '%s\n' "$@" | jq -cs '{data: {search: {issueCount: length, nodes: .}}}'; }
search "$(hit Issue acme/api 9 OPEN 2026-11-06T00:00:00Z 'raw quote')" \
       "$(hit Issue partner/widget 3 CLOSED 2026-11-07T00:00:00Z $'## Observation\n\n## Diagnosis\n')" > "$FIX/search-id.json"
search "$(hit Issue acme/api 9 OPEN 2026-11-06T00:00:00Z 'raw quote')" \
       "$(hit Issue acme/api 2 CLOSED 2026-11-09T00:00:00Z '')" \
       "$(hit PullRequest acme/web 5 MERGED 2026-11-08T00:00:00Z '')" \
       "$(hit Issue acme/api 1413 OPEN 2026-11-09T00:00:00Z '')" > "$FIX/search-terms.json"
: > "$FIX/search.log"
out=$(D dupes --repos acme/api,acme/web,acme/docs,acme/a,acme/b,acme/c,partner/widget --id "$FU" --terms "triage pipeline" --exclude https://github.com/acme/api/issues/1413/ --out "$TMP/dupes.json")
check "dupes is ok" "ok" "$(jq -r .status <<<"$out")"
check "the id is searched per owner, in title and body" "2" "$(grep -c "^\"$FU\" in:title,body user:" "$FIX/search.log")"
check "terms are searched five repos at a time" "2" "$(grep -c '^triage pipeline repo:' "$FIX/search.log")"
check "the second chunk holds the rest" "triage pipeline repo:acme/c repo:partner/widget" "$(grep '^triage pipeline' "$FIX/search.log" | tail -n 1)"
check "a hit found twice is one result with both reasons" "id,terms" "$(jq -r '.results[] | select(.number == 9) | .matched_by | join(",")' <<<"$out")"
check "source-id hits first, then open, then newest" "9 3 2 5" "$(jq -r '[.results[].number] | join(" ")' <<<"$out")"
check "--exclude drops the issue being re-diagnosed" "0" "$(jq '[.results[] | select(.number == 1413)] | length' <<<"$out")"
check "from_source lists the id hits" "2" "$(jq '.from_source | length' <<<"$out")"
check "diagnosed reads the Diagnosis heading" "false true" "$(jq -r '[.results[] | select(.matched_by | index("id")) | .diagnosed] | map(tostring) | join(" ")' <<<"$out")"
check "a PR is typed pr" "pr" "$(jq -r '.results[] | select(.number == 5) | .type' <<<"$out")"
check "--out writes it" "$(jq -c . <<<"$out")" "$(jq -c . "$TMP/dupes.json")"
out=$(D dupes --repos acme/api --terms 'the "export" button')
check "copied text with quotes is refused as terms" "error" "$(jq -r .status <<<"$out")"
out=$(D dupes --repos acme/api --terms '$(id)')
check "shell syntax is refused as terms" "error" "$(jq -r .status <<<"$out")"
check "dupes needs --id or --terms" "2" "$(rc_of D dupes --repos acme/api)"
check "dupes needs --repos" "2" "$(rc_of D dupes --id "$FU")"

# ─── check ───────────────────────────────────────────────────────────────────
echo "check"
RUN="$TMP/run"
mkdir -p "$RUN/bodies"
PROV='Provenance: Corveil FollowUp `05d9dcd9-e6a3-4450-a3be-34665e204be7` · meeting `3e695928-34ef-49fd-8e12-2e442ef43058` (2026-11-06, 15:59)'
ATTR='[🐦‍⬛ Created with Crow via Claude Code](https://github.com/corveil/crow)'
footer() { printf '\n---\n%s\n\n%s\n' "$PROV" "$ATTR"; }
diag() { # diag <repo> <cite>
  printf '## Observation\n\n> maybe I should create the preliminary tickets\n\nCorveil FollowUp `05d9dcd9`, said by Dana on 2026-11-06 at 15:59.\n\n'
  printf '## Diagnosis\n\n- **Repos:** %s\n- **Code:** `%s`: the brief never reads links.\n- **Cause:** read in the code.\n- **Confidence:** `high`. One function builds it.\n- **Related:** none.\n\n' "$1" "$2"
}
accept() {
  printf '## Acceptance and verification\n\n**Done when**\n\n- [ ] The brief lists links.\n\n**Verify after release**\n\n'
  printf -- '- **Tests pass at the tag**\n  - needs: `agent`\n  - how: `swift test --filter X | tail -n 5`\n  - expect: the suite passes\n'
  printf -- '- **Explore carries the link**\n  - needs: `human`\n  - how: run Explore on an item with a link\n  - expect: the brief has a Links section\n\n'
}
oos() { printf '## Out of scope\n\n- The Ticket brief, which #1416 replaces.\n'; }
{ printf 'Some intro.\n\n'; diag "acme/api, acme/web" "src/brief.go:184-203"
  printf '## Shape\n\nAn epic: two repos that land in order.\n\n- [ ] T1 — {{T1}} API side\n- [ ] T2 — {{T2}} web side\n\nWave 1: T1\nWave 2: T2\n\n'
  printf '## Acceptance and verification\n\n**Done when**\n\n- [ ] Both sub-tickets merge.\n\n**Verify after release**\n\nNone: each sub-ticket carries its own checks.\n\n'
  oos; footer; } > "$RUN/bodies/epic.md"
{ printf 'Part of {{epic}} (link-aware briefs).\n\n'; diag acme/api "src/brief.go:184"
  printf '```yaml\ntoken: ${{ secrets.GITHUB_TOKEN }}\nname: {{ .Values.name }}\n```\n\n'
  printf '## Shape\n\nOne ticket in the epic.\n\n'; accept; oos; footer; } > "$RUN/bodies/T1.md"
{ printf 'Part of {{epic}} (link-aware briefs). Depends on {{T1}}.\n\n'; diag acme/web "web/src/Brief.tsx:12"
  printf '## Shape\n\nOne ticket in the epic. See also {{T1}}.\n\n'; accept; oos; footer; } > "$RUN/bodies/T2.md"
cat > "$RUN/plan.json" <<JSON
{"outcome": "ticket",
 "source": {"kind": "followup", "id": "$FU", "quote": "maybe I should create the preliminary tickets", "provenance": $(jq -Rn --arg p "$PROV" '$p')},
 "shape": "epic",
 "issues": [
   {"key": "epic", "repo": "acme/api", "title": "Epic: briefs carry their links", "body": "bodies/epic.md", "labels": ["triaged", "enhancement"]},
   {"key": "T1", "repo": "acme/api", "title": "API brief lists links", "body": "bodies/T1.md", "labels": ["triaged"], "parent": "epic"},
   {"key": "T2", "repo": "acme/web", "title": "Web brief lists links", "body": "bodies/T2.md", "labels": ["triaged"], "parent": "epic", "depends_on": ["T1"]}
 ]}
JSON
out=$(D check --plan "$RUN/plan.json")
check "a complete epic passes, other {{…}} text (an Actions expression, a Helm value) included" "ok" "$(jq -r .status <<<"$out")"
[[ "$(jq -r .status <<<"$out")" == "ok" ]] || jq -r '.errors[]?' <<<"$out" | sed 's/^/      /'
check "check exits 0 when ok" "0" "$(rc_of D check --plan "$RUN/plan.json")"
check "check needs no network" "0" "$(GH_BIN=/nonexistent CROW_BIN=/nonexistent CORVEIL_BIN=/nonexistent bash "$DIAGNOSE_SH" check --plan "$RUN/plan.json" >/dev/null 2>&1; echo $?)"

# expect_error <description> <needle> — mutate a copy of the run first with `mutate`.
copy_run() { rm -rf "$TMP/run2"; cp -R "$RUN" "$TMP/run2"; }
expect_error() {
  local out
  out=$(D check --plan "$TMP/run2/plan.json")
  check "$1: invalid" "invalid" "$(jq -r .status <<<"$out")"
  contains "$1: says why" "$(jq -r '.errors | join(" | ")' <<<"$out")" "$2"
}
edit_body() { # edit_body <key> <sed-expr>
  sed -E "$2" "$TMP/run2/bodies/$1.md" > "$TMP/run2/bodies/$1.tmp" && mv "$TMP/run2/bodies/$1.tmp" "$TMP/run2/bodies/$1.md"
}
edit_plan() { jq "$1" "$TMP/run2/plan.json" > "$TMP/run2/p.tmp" && mv "$TMP/run2/p.tmp" "$TMP/run2/plan.json"; }

copy_run; edit_body T1 '/^## Out of scope$/d'
expect_error "a missing section" "T1: missing the ## Out of scope section"
copy_run; edit_body T1 's/^## Diagnosis$/## Diagnosis-moved/; s/^## Shape$/## Shape\n\n## Diagnosis\n\n- **Repos:** x\n- **Code:** `a.go:1`\n- **Cause:** c\n- **Confidence:** `low`/'
expect_error "sections out of order" "T1: the sections are out of order"
copy_run; edit_body T1 's/^> maybe.*/maybe I should create the preliminary tickets/'
expect_error "no blockquote" "T1: Observation must quote the source verbatim"
copy_run; edit_body T1 's/`src\/brief.go:184`/src\/brief.go/'
expect_error "no file:line citation" "T1: Diagnosis cites no code"
copy_run; edit_body T1 's/^- \*\*Cause:\*\*.*$//'
expect_error "no cause" "T1: Diagnosis is missing **Cause:**"
copy_run; edit_body T1 's/`high`/`certain`/'
expect_error "a confidence that isn't a level" "T1: **Confidence:** must be high, medium or low"
copy_run; edit_body T1 's/^\*\*Done when\*\*$/Done when/'
expect_error "no Done when" "T1: Acceptance is missing **Done when**"
copy_run; edit_body T1 's/^\*\*Verify after release\*\*$/Verify/'
expect_error "no Verify after release" "T1: Acceptance is missing **Verify after release**"
copy_run; edit_body T1 's/needs: `human`/needs: `staff`/'
expect_error "a needs value outside the list" 'T1: check "Explore carries the link" has needs: staff'
copy_run; edit_body T1 '/- how: run Explore/d'
expect_error "a check without how" 'T1: check "Explore carries the link" is missing how:'
copy_run; edit_body T1 's/^Part of \{\{epic\}\}/Belongs to {{epic}}/'
expect_error "a sub-ticket without its Part of line" "T1: a sub-ticket body must open with Part of {{epic}}"
copy_run; edit_body T2 's/ Depends on \{\{T1\}\}\.//'
expect_error "a missing Depends on" "T2: the first line must say Depends on {{T1}}"
copy_run; edit_body epic '/^- \[ \] T2/d'
expect_error "an epic task list missing a sub-ticket" "epic: the Shape task list has no line for T2"
copy_run; edit_body T1 '$d'
expect_error "no attribution line" "T1: the last line must be the Crow attribution line"
copy_run; edit_body T1 's/^Provenance: .*/Provenance: something else/'
expect_error "a provenance line that isn't the plan's" "T1: the line above the attribution must be the plan source.provenance line"
copy_run; edit_body T1 's/^---$//'
expect_error "no rule above the provenance" "T1: put a --- rule above the Provenance line"
copy_run; edit_body T1 's/See also/See also {{T9}} and/; s/^## Shape$/## Shape\n\nSee {{T9}}./'
expect_error "a placeholder for a key that isn't in the plan" "T1: {{T9}} is not a key in this plan"
copy_run; edit_body T1 's/via Claude Code\]/via {{CROW_AGENT_DISPLAY_NAME}}]/'
expect_error "an unexpanded agent-name placeholder" "T1: the attribution line still has the agent-name placeholder"
copy_run; edit_plan '.issues[1].labels = ["triaged", "crow:auto"]'
expect_error "crow:auto" "T1: never label a diagnosed ticket crow:auto"
copy_run; edit_plan '.issues[1].labels = ["bug"]'
expect_error "no triaged label" "T1: labels must include triaged"
copy_run; edit_plan '.issues[1].title = "Maybe I should create the preliminary tickets "'
expect_error "a title that is the raw quote" "T1: the title is the raw quote"
copy_run; edit_plan '.issues = [.issues[0], .issues[2], .issues[1]]'
expect_error "a dependency listed after its dependent" "T2: depends_on T1, so list T1 first"
copy_run; edit_plan '.issues = [.issues[1], .issues[0], .issues[2]]'
expect_error "an epic that isn't first" "an epic plan lists the epic issue first"
copy_run; edit_plan '.issues = [.issues[0], .issues[1]]'
expect_error "an epic with one sub-ticket" "an epic needs at least two sub-tickets"
copy_run; edit_plan '.issues[2].parent = null'
expect_error "a sub-ticket without a parent" "T2: a sub-ticket needs parent: epic"
copy_run; edit_plan '.issues[1].body = "../outside.md"'
expect_error "a body path outside the run folder" "T1: body must be a relative .md path"
copy_run; edit_plan '.issues[1].body = "bodies/missing.md"'
expect_error "a body file that doesn't exist" "T1: body file bodies/missing.md does not exist"
copy_run; edit_plan '.issues[1].repo = "not a slug"'
expect_error "a bad repo" "T1: repo must be owner/name"
copy_run; edit_plan '.source.provenance = "Corveil FollowUp x"'
expect_error "a provenance without its prefix" "source.provenance must be the footer line"
copy_run; edit_plan '.outcome = "maybe"'
expect_error "an unknown outcome" "outcome must be one of"

# A fenced block can hold a heading-like line without counting as a section.
copy_run; edit_body T1 's/^## Shape$/```markdown\n## Diagnosis\n```\n\n## Shape/'
out=$(D check --plan "$TMP/run2/plan.json")
check "a heading inside a code fence doesn't count" "ok" "$(jq -r .status <<<"$out")"

# A single ticket.
copy_run
{ diag acme/api "src/brief.go:184"; printf '## Shape\n\nOne ticket: one function.\n\n'; accept; oos; footer; } > "$TMP/run2/bodies/T1.md"
edit_plan '.shape = "ticket" | .issues = [.issues[1] | del(.parent)]'
out=$(D check --plan "$TMP/run2/plan.json")
check "a single ticket passes" "ok" "$(jq -r .status <<<"$out")"
edit_plan '.issues[0].parent = "epic"'
expect_error "a single ticket with a parent" "T1: a single ticket has no epic, parent or depends_on"

# The standard's own worked example must pass: check and the standard can't drift apart.
STANDARD="$SCRIPT_DIR/../../docs/ticket-standard.md"
if [[ -f "$STANDARD" ]]; then
  WX="$TMP/worked"
  mkdir -p "$WX/bodies"
  awk '/^\*\*The ticket it becomes:\*\*/{f=1;next} f&&/^````markdown/{g=1;next} g&&/^````$/{exit} g{print}' "$STANDARD" > "$WX/full.md"
  wtitle=$(head -n 1 "$WX/full.md" | sed 's/^# //')
  tail -n +3 "$WX/full.md" > "$WX/bodies/T1.md"
  wprov=$(grep '^Provenance: ' "$WX/bodies/T1.md")
  jq -n --arg t "$wtitle" --arg p "$wprov" '{outcome: "ticket", source: {kind: "scratch", id: "4b7d0c52-9a1e-4c33-8f0e-2d6a1b9c7e41", provenance: $p},
    shape: "ticket", issues: [{key: "T1", repo: "corveil/crow", title: $t, body: "bodies/T1.md", labels: ["triaged"]}]}' > "$WX/plan.json"
  out=$(D check --plan "$WX/plan.json")
  check "the standard's worked example passes check" "ok" "$(jq -r .status <<<"$out")"
  [[ "$(jq -r .status <<<"$out")" == "ok" ]] || jq -r '.errors[]?' <<<"$out" | sed 's/^/      /'
fi

# Outcomes that aren't tickets.
echo '{"outcome": "commitment", "source": {"kind": "followup", "id": "x"}, "reason": "A promise to send a deck."}' > "$TMP/run2/plan.json"
out=$(D check --plan "$TMP/run2/plan.json")
check "a commitment with a reason passes" "ok" "$(jq -r .status <<<"$out")"
echo '{"outcome": "needs_info", "source": {"kind": "text"}}' > "$TMP/run2/plan.json"
expect_error "a needs info without its question" "a needs_info outcome needs a reason"
echo '{"outcome": "duplicate", "source": {"kind": "scratch", "id": "x"}, "reason": "Covered."}' > "$TMP/run2/plan.json"
expect_error "a duplicate without a link" "a duplicate outcome needs link"
echo '{"outcome": "wont_do", "source": {"kind": "text"}, "reason": "ADR 0026 settles it.", "issues": [{"key": "T1"}]}' > "$TMP/run2/plan.json"
expect_error "a non-ticket outcome that files" "only a ticket outcome files issues"
echo '[1, 2]' > "$TMP/run2/plan.json"
check "a plan that isn't an object is invalid" "1" "$(rc_of D check --plan "$TMP/run2/plan.json")"
check "check needs an existing plan" "2" "$(rc_of D check --plan "$TMP/nope.json")"

# ─── file ────────────────────────────────────────────────────────────────────
echo "file"
: > "$FIX/gh.log"; rm -f "$FIX/next-number" "$FIX/created.log"
echo '[{"name":"enhancement"}]' > "$FIX/labels-acme__api.json"
out=$(D file --plan "$RUN/plan.json")
check "file is ok" "ok" "$(jq -r .status <<<"$out")"
check "the epic first, then the sub-tickets in order" $'100\tacme/api\tEpic: briefs carry their links\n101\tacme/api\tAPI brief lists links\n102\tacme/web\tWeb brief lists links' "$(cat "$FIX/created.log")"
check "triaged was created where the repo lacked it" "triaged acme/api" "$(cat "$FIX/label-create.log")"
check "labels are passed" "triaged,enhancement" "$(cat "$FIX/labels-100")"
check "never crow:auto" "" "$(grep -l 'crow:auto' "$FIX"/labels-1* 2>/dev/null)"
check "a sub-ticket names its epic in the same repo as #N" "Part of #100 (link-aware briefs)." "$(head -n 1 "$FIX/created-101.md")"
check "and across repos as owner/repo#N, with its dependency" "Part of acme/api#100 (link-aware briefs). Depends on acme/api#101." "$(head -n 1 "$FIX/created-102.md")"
contains "the epic was filed before its sub-tickets existed, so it shows bare keys at first" "$(cat "$FIX/created-100.md")" "- [ ] T1 — T1 API side"
contains "then it is edited with the real numbers" "$(cat "$FIX/edited-100.md")" "- [ ] T2 — acme/web#102 web side"
check "only the epic needed an edit" "edited-100.md" "$(cd "$FIX" && ls edited-*.md | tr '\n' ' ' | sed 's/ $//')"
check "each sub-ticket is added as a sub-issue of the epic" $'repos/acme/api/issues/100/sub_issues sub_issue_id=9101\nrepos/acme/api/issues/100/sub_issues sub_issue_id=9102' "$(cat "$FIX/subissue.log")"
check "filed.json records every issue" "100 101 102" "$(jq -r '[.issues[].number] | map(tostring) | join(" ")' "$RUN/filed.json")"
check "the output lists them" "https://github.com/acme/web/issues/102" "$(jq -r '.filed[] | select(.key == "T2") | .url' <<<"$out")"
check "the attribution line survives rendering" "$ATTR" "$(tail -n 1 "$FIX/created-102.md")"
contains "other {{…}} text is filed untouched" "$(cat "$FIX/created-101.md")" 'token: ${{ secrets.GITHUB_TOKEN }}'
check "filed.json records each title" "API brief lists links" "$(jq -r .issues.T1.title "$RUN/filed.json")"

out=$(D file --plan "$RUN/plan.json")
check "a rerun files nothing new" "3" "$(grep -c '' "$FIX/created.log")"
check "and still reports the filed issues" "3" "$(jq '.filed | length' <<<"$out")"

# A different diagnosis in a folder that already filed must not pass as a resume.
cp "$RUN/plan.json" "$TMP/plan.saved"
jq '.issues[1].title = "Regression: API brief drops links again"' "$TMP/plan.saved" > "$RUN/plan.json"
out=$(D file --plan "$RUN/plan.json")
check "a plan whose filed key changed title is invalid" "invalid" "$(jq -r .status <<<"$out")"
contains "and says what filed.json holds" "$(jq -r '.errors | join(" ")' <<<"$out")" 'filed.json records T1 as acme/api#101 "API brief lists links"'
check "and files nothing" "3" "$(grep -c '' "$FIX/created.log")"
jq '.issues[2].repo = "acme/api"' "$TMP/plan.saved" > "$RUN/plan.json"
out=$(D file --plan "$RUN/plan.json")
contains "a filed key that moved repo is refused too" "$(jq -r '.errors | join(" ")' <<<"$out")" "but this plan files T2"
cp "$TMP/plan.saved" "$RUN/plan.json"

# Resume: the outage hits the second sub-ticket.
copy_run; rm -f "$TMP/run2/filed.json" "$FIX/subissue.log" "$FIX"/edited-*.md
echo 200 > "$FIX/next-number"; echo 202 > "$FIX/fail-create-at"; : > "$FIX/created.log"
out=$(D file --plan "$TMP/run2/plan.json")
check "an outage partway stops the run" "error" "$(jq -r .status <<<"$out")"
contains "and lists what was filed" "$(jq -r .message <<<"$out")" "issues/201"
rm -f "$FIX/fail-create-at"
out=$(D file --plan "$TMP/run2/plan.json")
check "the rerun finishes" "ok" "$(jq -r .status <<<"$out")"
check "without filing the first two again" $'200\tacme/api\tEpic: briefs carry their links\n201\tacme/api\tAPI brief lists links\n202\tacme/web\tWeb brief lists links' "$(cat "$FIX/created.log")"
contains "the epic still gets its numbers" "$(cat "$FIX/edited-200.md")" "- [ ] T2 — acme/web#202 web side"

# A missing label other than triaged stops everything before filing, and
# before triaged is created anywhere.
copy_run; rm -f "$TMP/run2/filed.json"; : > "$FIX/created.log"; : > "$FIX/label-create.log"
edit_plan '.issues[2].labels = ["triaged", "frontend"]'
out=$(D file --plan "$TMP/run2/plan.json")
check "a missing label is invalid" "invalid" "$(jq -r .status <<<"$out")"
contains "and named" "$(jq -r '.errors | join(" ")' <<<"$out")" "acme/web has no frontend label"
check "and nothing was filed" "" "$(cat "$FIX/created.log")"
check "and no label was created in the other repo" "" "$(cat "$FIX/label-create.log")"

# A public repo needs --public-ok: the bodies quote the observation verbatim.
copy_run; rm -f "$TMP/run2/filed.json"; : > "$FIX/created.log"; : > "$FIX/label-create.log"
echo public > "$FIX/visibility-acme__web"
out=$(D file --plan "$TMP/run2/plan.json")
check "a public repo without --public-ok is invalid" "invalid" "$(jq -r .status <<<"$out")"
contains "and named" "$(jq -r '.errors | join(" ")' <<<"$out")" "acme/web is public"
check "nothing was filed" "" "$(cat "$FIX/created.log")"
check "and no label was created" "" "$(cat "$FIX/label-create.log")"
out=$(D file --plan "$TMP/run2/plan.json" --public-ok)
check "with --public-ok it files" "ok 3" "$(jq -r '"\(.status) \(.filed | length)"' <<<"$out")"
rm -f "$FIX/visibility-acme__web"

# A failed sub-issue link is a warning, not a failure.
copy_run; rm -f "$TMP/run2/filed.json"; touch "$FIX/fail-subissue"
out=$(D file --plan "$TMP/run2/plan.json")
check "a sub-issue failure still files" "ok" "$(jq -r .status <<<"$out")"
contains "and warns" "$(jq -r '.warnings | join(" ")' <<<"$out")" "could not add T1 as a sub-issue"
rm -f "$FIX/fail-subissue"

# An invalid plan files nothing.
copy_run; rm -f "$TMP/run2/filed.json"; : > "$FIX/created.log"
edit_plan '.issues[1].labels = ["triaged", "crow:auto"]'
check "an invalid plan exits 1" "1" "$(rc_of D file --plan "$TMP/run2/plan.json")"
check "and files nothing" "" "$(cat "$FIX/created.log")"
echo '{"outcome": "commitment", "source": {"kind": "text"}, "reason": "A promise."}' > "$TMP/run2/plan.json"
out=$(D file --plan "$TMP/run2/plan.json")
check "a non-ticket outcome files nothing" "error" "$(jq -r .status <<<"$out")"

# ─── corveil ─────────────────────────────────────────────────────────────────
echo "corveil"
out=$(D corveil entity "$FU2")
check "a read verb runs with --no-capture" "entity --no-capture $FU2" "$(grep -o "entity --no-capture $FU2" "$FIX/corveil.log" | tail -n 1)"
check "and CORVEIL_NO_CAPTURE=1" "capture_off=1" "$(tail -n 1 "$FIX/corveil.log" | cut -d' ' -f1)"
out=$(D corveil whoami)
check "whoami takes no --no-capture" "whoami" "$(jq -r .args <<<"$out")"
out=$(D corveil control knowledge ontology-entities-update x)
check "a write verb is refused" "error" "$(jq -r .status <<<"$out")"
out=$(D corveil search foo --no-capture=false)
check "a capture flag is refused" "error" "$(jq -r .status <<<"$out")"
out=$(D corveil search foo --question "why")
check "a recorded question is refused" "error" "$(jq -r .status <<<"$out")"
check "no CLI exits 3" "3" "$(CORVEIL_BIN="$TMP/no-such-corveil" bash "$DIAGNOSE_SH" corveil search foo >/dev/null 2>&1; echo $?)"

echo
echo "diagnose.sh: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
