#!/usr/bin/env bash
# Unit tests for release.sh (CROW-1371): items.json validation and id filling,
# assemble, the page build (placeholders, escaping, the data round-trip), the
# read-back of the four collections in every shape ArtifactData produces, the
# Markdown report, the subagent JSON extractor, and scope against real git
# repos with a fake gh.
#
# Nothing touches claude.ai or GitHub. When node is on PATH the built page's
# data block is parsed back and its inline script syntax-checked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SH="$SCRIPT_DIR/release.sh"

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1371-release-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

rr() { bash "$RELEASE_SH" "$@"; }

# A synthetic two-repo release. The ids are left out: assemble fills them.
PAGE="$TMP/page.json"
cat > "$PAGE" <<'JSON'
{
  "title": "Acme <Release> & Review",
  "heading": "Acme release review: api v2.4.0 and infra v0.9.0",
  "generated": "2026-10-27",
  "repos": [
    {"id": "api", "name": "API", "repo": "acme/api", "from": "v2.3.0", "to": "v2.4.0", "head": "aaaaaaaaaaaa",
     "count_label": "2 PRs", "how": ["A v* tag builds the image and rolls the API."], "live": "curl -s https://api.example.com/version"},
    {"id": "infra", "name": "Infra", "repo": "acme/infra", "from": "v0.8.0", "to": "v0.9.0", "how": ["A tag applies the saved plan."]}
  ],
  "verdict": {"level": "medium", "headline": "Ship infra, then the API.", "paragraphs": ["Nothing is high risk.", "The pipeline is new."]},
  "blockers": [{"title": "Rehearse the pipeline", "why": "New runners.", "action": "Dry run.", "soft": true}],
  "top_risks": ["First run of the new pipeline."],
  "user_visible": ["Retry-After on 429s."],
  "cleared": ["CI is green on main."],
  "progress": [{"state": "waiting", "label": "Infra v0.9.0"}],
  "runbook_intro": ["Do these in order."],
  "runbook": [
    {"phase": "Before tagging", "action": "Confirm main has not moved", "cmd": "git -C api rev-parse origin/main\ngit -C infra rev-parse origin/main"},
    {"phase": "Infra v0.9.0", "action": "Tag v0.9.0", "why": "Applies the saved plan."}
  ],
  "rollback": [{"repo": "api", "text": "Redeploy v2.3.0.", "cmd": "deploy v2.3.0"}],
  "agent_notes": ["Read-only cloud calls only."],
  "method": ["Read every PR at main."]
}
JSON
STUDY_A="$TMP/study-a.json"
cat > "$STUDY_A" <<'JSON'
[
  {"repo": "api", "pr": 51, "title": "Retry-After on 429s", "url": "https://github.com/acme/api/pull/51",
   "category": "api", "audience": "API clients", "before": "No header.", "after": "A Retry-After header.",
   "fixes": "Clients retry blind.", "pros": ["Better backoff"], "cons": ["None found"], "risk_level": "low", "risk": "Header only.",
   "test_steps": [
     {"step": "Header present", "how": "curl -sI https://api.example.com/limited", "expect": "Retry-After is set", "needs": "agent"},
     {"step": "Dashboard looks right", "how": "Open the dashboard", "expect": "No gaps", "needs": "human", "when": "the next morning"}
   ]},
  {"repo": "api", "pr": 52, "title": "Staff sessions </script><script>alert(1)</script> and <!-- a comment", "category": "security",
   "audience": "Staff", "before": "7-day cookies.", "after": "12-hour sessions.", "fixes": "Stolen cookies.",
   "pros": ["Real logout"], "cons": ["Everyone signs in again once"], "risk_level": "medium", "risk": "A new, empty table.",
   "questions": ["Are 12 hours enough?"],
   "test_steps": [
     {"step": "Migration applied", "how": "Query the logs", "expect": "One event", "needs": "agent+aws", "baseline": "the session count"},
     {"step": "Optional deep check", "how": "Look closer", "expect": "Fine", "needs": "agent", "optional": true}
   ]}
]
JSON
STUDY_B="$TMP/study-b.json"
cat > "$STUDY_B" <<'JSON'
{"items": [
  {"repo": "infra", "pr": 7, "title": "Latency alarm", "category": "infra", "audience": "On-call", "before": "No alarm.",
   "after": "An alarm.", "fixes": "Slow gateways go unnoticed.", "pros": ["Pages on-call"], "cons": ["Could be noisy"],
   "risk_level": "low", "risk": "Additive.", "test_steps": [{"step": "Alarm exists", "how": "describe-alarms", "expect": "OK state", "needs": "agent+aws"}]},
  {"repo": "api", "label": "infra", "pr": 9, "not_merged": true, "title": "Pin the worker image", "category": "infra",
   "audience": "Nobody directly", "before": "Mutable tag.", "after": "Pinned tag.", "fixes": "Surprise deploys.",
   "pros": ["Reviewed deploys"], "cons": ["A restart"], "risk_level": "high", "risk": "Restarts the worker.", "blocker": "Conflicts with main."}
]}
JSON

ITEMS="$TMP/items.json"

# mutate <jq filter> → path of a copy of $ITEMS with the filter applied
n_mut=0
mutate() {
  n_mut=$((n_mut+1))
  local f="$TMP/mut-$n_mut.json"
  jq "$1" "$ITEMS" > "$f"
  printf '%s' "$f"
}

echo "== check --study =="
out=$(rr check --study "$STUDY_A"); rc=$?
check "a valid study file exits 0" "0" "$rc"
check "counts its items and steps" '{"items":2,"steps":4}' "$(jq -c '{items, steps}' <<<"$out")"
out=$(rr check --study "$STUDY_B"); rc=$?
check "an {items} study file is valid too" "0" "$rc"
jq '.[0].risk_level = "huge" | .[0].test_steps[0].needs = "robot" | del(.[1].before) | .[1].pros = []' "$STUDY_A" > "$TMP/bad-study.json"
out=$(rr check --study "$TMP/bad-study.json"); rc=$?
check "a bad study file exits 1" "1" "$rc"
errs=$(jq -r '.errors | join(" | ")' <<<"$out")
contains "names the risk level" "$errs" "item 1: risk_level must be one of high, medium, low"
contains "names the needs" "$errs" "step 1: needs must be one of agent, agent+aws, agent+staff, human"
contains "names a missing before" "$errs" "item 2: before is required"
contains "an empty pros list fails" "$errs" "item 2: pros is required"
echo '{"x": 1}' > "$TMP/not-study.json"
out=$(rr check --study "$TMP/not-study.json"); rc=$?
check "a study file that is neither an array nor {items} exits 1" "1" "$rc"
out=$(rr check --study "$STUDY_A" --items "$PAGE"); rc=$?
check "--study with --items exits 2" "2" "$rc"

echo "== assemble =="
out=$(rr assemble --page "$PAGE" --study "$STUDY_A" --study "$STUDY_B" --out "$ITEMS"); rc=$?
check "assemble exits 0" "0" "$rc"
check "assigns every id" '{"items":4,"steps":5,"runbook":2}' "$(jq -c .assigned <<<"$out")"
check "items keep the study order" '["api-51","api-52","infra-7","infra-9"]' "$(jq -c '[.items[].id]' "$ITEMS")"
check "a label prefixes the id" "infra-9" "$(jq -r '.items[3].id' "$ITEMS")"
check "step ids are {item id}-{n}" '["api-51-1","api-51-2"]' "$(jq -c '[.items[0].test_steps[].id]' "$ITEMS")"
check "runbook ids are rb-NN" '["rb-01","rb-02"]' "$(jq -c '[.runbook[].id]' "$ITEMS")"
check "the id comes first in each item" "id" "$(jq -r '.items[0] | keys_unsorted[0]' "$ITEMS")"
check "summary counts risk" '{"high":1,"medium":1,"low":2}' "$(jq -c .risk <<<"$out")"
check "summary counts needs" '{"agent":2,"agent+aws":2,"agent+staff":0,"human":1}' "$(jq -c .needs <<<"$out")"
contains "warns about a high-risk item with no steps" "$(jq -r '.warnings | join(" | ")' <<<"$out")" 'item "infra-9" is high risk but has no test steps'
out=$(rr assemble --page "$PAGE" --study "$STUDY_A" --out "$ITEMS"); rc=$?
check "assemble refuses to overwrite items.json" "2" "$rc"
contains "says why" "$out" "Its ids are the page's db keys"
cp "$ITEMS" "$TMP/items-keep.json"
out=$(rr assemble --page "$PAGE" --study "$STUDY_A" --out "$TMP/forced.json"); rc=$?
out=$(rr assemble --page "$PAGE" --study "$STUDY_B" --out "$TMP/forced.json" --force); rc=$?
check "--force overwrites" "0" "$rc"
check "--force wrote the new items" '["infra-7","infra-9"]' "$(jq -c '[.items[].id]' "$TMP/forced.json")"
jq '. + {items: [{"repo": "api"}]}' "$PAGE" > "$TMP/page-with-items.json"
out=$(rr assemble --page "$TMP/page-with-items.json" --study "$STUDY_A" --out "$TMP/x.json"); rc=$?
check "a page.json carrying items exits 2" "2" "$rc"
echo '"text"' > "$TMP/scalar.json"
out=$(rr assemble --page "$PAGE" --study "$TMP/scalar.json" --out "$TMP/y.json"); rc=$?
check "a study file that is not a list exits 2" "2" "$rc"
jq '.[1].title = ""' "$STUDY_A" > "$TMP/study-bad-title.json"
out=$(rr assemble --page "$PAGE" --study "$TMP/study-bad-title.json" --out "$TMP/z.json"); rc=$?
check "assemble reports validation errors with exit 1" "1" "$rc"
check "and still writes the file so it can be fixed" "yes" "$([[ -f "$TMP/z.json" ]] && echo yes || echo no)"

echo "== ids =="
# A new runbook step inserted mid-list, a new test step, a new item: each gets
# the next free number, and no existing id moves.
f=$(mutate '.runbook = [.runbook[0], {"phase": "Before tagging", "action": "Send the heads-up"}, .runbook[1]]
            | .items[0].test_steps += [{"step": "New", "how": "h", "expect": "e", "needs": "agent"}]
            | .items += [{"repo": "infra", "pr": 8, "title": "t", "category": "c", "audience": "a", "before": "b", "after": "a",
                          "fixes": "f", "pros": ["p"], "cons": ["c"], "risk_level": "low", "risk": "r",
                          "test_steps": [{"step": "s", "how": "h", "expect": "e", "needs": "agent"}]}]')
out=$(rr ids --items "$f"); rc=$?
check "ids exits 0" "0" "$rc"
check "ids counts what it filled" '{"items":1,"steps":2,"runbook":1}' "$(jq -c .assigned <<<"$out")"
check "an inserted runbook step gets the next number" '["rb-01","rb-03","rb-02"]' "$(jq -c '[.runbook[].id]' "$f")"
check "a new step continues its item's numbering" '["api-51-1","api-51-2","api-51-3"]' "$(jq -c '[.items[0].test_steps[].id]' "$f")"
check "a new item gets {repo}-{pr}" "infra-8" "$(jq -r '.items[4].id' "$f")"
before=$(jq -c . "$f")
rr ids --items "$f" >/dev/null
check "ids is idempotent" "$before" "$(jq -c . "$f")"
f=$(mutate '.items[0].test_steps[0].id = "api-51-7" | .items[0].test_steps += [{"step": "n", "how": "h", "expect": "e", "needs": "agent"}]')
rr ids --items "$f" >/dev/null
check "numbering continues after the highest id" "api-51-8" "$(jq -r '.items[0].test_steps[2].id' "$f")"
f=$(mutate '.items += [{"repo": "api", "title": "No PR", "category": "c", "audience": "a", "before": "b", "after": "a",
                        "fixes": "f", "pros": ["p"], "cons": ["c"], "risk_level": "low", "risk": "r"}]')
out=$(rr ids --items "$f"); rc=$?
check "an item with no id and no pr exits 1" "1" "$rc"
contains "asks for an id" "$(jq -r '.errors | join(" | ")' <<<"$out")" 'item "No PR" has no id and no pr'

echo "== check =="
out=$(rr check --items "$ITEMS"); rc=$?
check "valid items exit 0" "0" "$rc"
check "counts per repo" '[{"id":"api","items":3,"steps":4},{"id":"infra","items":1,"steps":1}]' "$(jq -c .repos <<<"$out")"

expect_error() { # expect_error <description> <jq mutation> <needle>
  local f out rc
  f=$(mutate "$2")
  out=$(rr check --items "$f"); rc=$?
  check "$1 exits 1" "1" "$rc"
  contains "$1 names the problem" "$(jq -r '.errors | join(" | ")' <<<"$out")" "$3"
}
expect_error "duplicate item id" '.items[1].id = "api-51"' 'item id "api-51" is used more than once'
expect_error "duplicate step id" '.items[1].test_steps[0].id = "api-52-2"' 'step id "api-52-2" is used more than once'
expect_error "step id outside its item" '.items[1].test_steps[0].id = "api-51-9"' 'must start with "api-52-"'
expect_error "a slash in an id" '.items[0].id = "api/51"' 'may use only letters, digits'
expect_error "a missing item id" 'del(.items[0].id)' 'id is missing; run release.sh ids'
expect_error "a missing step id" 'del(.items[0].test_steps[0].id)' 'step 1: id is missing'
expect_error "a missing runbook id" 'del(.runbook[0].id)' 'runbook step 1: id is missing'
expect_error "a runbook id that is not rb-NN" '.runbook[0].id = "step-1"' 'must look like rb-01'
expect_error "duplicate runbook id" '.runbook[1].id = "rb-01"' 'runbook id "rb-01" is used more than once'
expect_error "an unknown repo" '.items[0].repo = "web"' 'repo must be one of api, infra'
expect_error "an unknown risk level" '.items[0].risk_level = "spicy"' 'risk_level must be one of high, medium, low'
expect_error "an unknown needs" '.items[0].test_steps[0].needs = "robot"' 'needs must be one of agent, agent+aws, agent+staff, human'
expect_error "a step without how" 'del(.items[0].test_steps[0].how)' 'how is required'
expect_error "a step without expect" '.items[0].test_steps[0].expect = ""' 'expect is required'
expect_error "a non-boolean optional" '.items[0].test_steps[0].optional = "yes"' 'optional must be true or false'
expect_error "a fractional pr" '.items[0].pr = 5.5' 'pr must be a positive whole number'
expect_error "a non-http url" '.items[0].url = "javascript:alert(1)"' 'url must be an http(s) URL'
expect_error "no cons" 'del(.items[0].cons)' 'cons is required'
expect_error "no title" 'del(.title)' 'title is required'
expect_error "no repos" '.repos = []' 'repos must be a non-empty array'
expect_error "duplicate repo id" '.repos[1].id = "api"' 'repo id "api" is used more than once'
expect_error "a repo without from" 'del(.repos[0].from)' 'repo 1 (api): from is required'
expect_error "no verdict" 'del(.verdict)' 'verdict is required'
expect_error "a bad verdict level" '.verdict.level = "meh"' 'verdict: level must be one of high, medium, low'
expect_error "a verdict without paragraphs" '.verdict.paragraphs = []' 'verdict: paragraphs is required'
expect_error "a bad progress state" '.progress[0].state = "shipping"' 'state must be one of done, running, waiting, held'
expect_error "a blocker without why" 'del(.blockers[0].why)' 'blocker 1: why is required'
expect_error "a non-boolean soft" '.blockers[0].soft = 1' 'soft must be true or false'
expect_error "a finding without title" '.findings = [{"why": "x"}]' 'finding 1: title is required'
expect_error "a bad generated date" '.generated = "yesterday"' 'generated must be a date'
expect_error "a top_risks that is not a list" '.top_risks = "x"' 'top_risks must be an array of strings'
expect_error "no items" '.items = []' 'items must be a non-empty array'
f=$(mutate '.repos += [{"id": "web", "name": "Web", "from": "v1", "to": "v2"}] | del(.runbook)')
out=$(rr check --items "$f"); rc=$?
check "an empty repo and no runbook are only warnings" "0" "$rc"
contains "warns about the empty repo" "$(jq -r '.warnings | join(" | ")' <<<"$out")" 'repo "web" has no changes'
contains "warns about the missing runbook" "$(jq -r '.warnings | join(" | ")' <<<"$out")" 'the page has no runbook'
printf 'not json' > "$TMP/bad.json"
out=$(rr check --items "$TMP/bad.json"); rc=$?
check "unparseable items exit 2" "2" "$rc"
out=$(rr check --items "$TMP/missing.json"); rc=$?
check "a missing items file exits 2" "2" "$rc"

echo "== build =="
OUTPAGE="$TMP/out/page.html"
out=$(rr build --items "$ITEMS" --out "$OUTPAGE" --url-file "$TMP/no-url-yet"); rc=$?
check "build exits 0 before there is an artifact-url" "0" "$rc"
check "build reports no url yet" "null" "$(jq -r .url <<<"$out")"
html=$(cat "$OUTPAGE")
lacks "no data placeholder left" "$html" "__RELEASE_DATA__"
lacks "no title placeholder left" "$html" "__RELEASE_TITLE__"
check "the title is HTML-escaped" "<title>Acme &lt;Release&gt; &amp; Review</title>" "$(head -n 1 "$OUTPAGE")"
check "item text cannot close the data block" "0" "$(grep -c '</script><script>alert' "$OUTPAGE")"
data_line=$(grep -A1 'id="release-data"' "$OUTPAGE" | tail -n 1)
lacks "item text cannot open a comment in the data block" "$data_line" "<!--"
# The backslash is built at run time: a literal backslash-u escape in this
# file would be one more thing to keep from being decoded.
bs=$(printf "%s" "\\")
check "the escaped text is still in the data" "1" "$(grep -cF "Staff sessions ${bs}u003c/script>" "$OUTPAGE")"
check "exactly one data block" "1" "$(grep -c 'id="release-data"' "$OUTPAGE")"
contains "the page subscribes to checks" "$html" 'const COLS = ["notes", "decisions", "checks", "runbook"]'
contains "the page reads the db through claude.use" "$html" 'c.use("db")'
contains "the page asks whether the viewer may write" "$html" 'user.can("data.write")'
# The tab panels are display: grid, which beats the browser's own [hidden]
# rule: without this every tab renders at once.
contains "hidden tab panels stay hidden" "$html" '[hidden] { display: none !important; }'

echo "https://claude.ai/artifact/AbC123  " > "$TMP/artifact-url"
out=$(rr build --items "$ITEMS" --out "$OUTPAGE" --url-file "$TMP/artifact-url"); rc=$?
check "build with --url-file exits 0" "0" "$rc"
check "build reports the url" "https://claude.ai/artifact/AbC123" "$(jq -r .url <<<"$out")"
check "the url is embedded for the agent brief" "1" "$(grep -cF '"url":"https://claude.ai/artifact/AbC123"' "$OUTPAGE")"
lacks "items.json itself is not changed" "$(cat "$ITEMS")" "AbC123"
out=$(rr build --items "$ITEMS" --out "$OUTPAGE" --url "javascript:alert(1)"); rc=$?
check "a non-http url exits 2" "2" "$rc"
out=$(rr build --items "$ITEMS" --out "$OUTPAGE" --url "https://x" --url-file "$TMP/artifact-url"); rc=$?
check "--url with --url-file exits 2" "2" "$rc"

if command -v node >/dev/null 2>&1; then
  rt=$(node -e '
    const fs = require("fs");
    const html = fs.readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script type="application\/json" id="release-data">\n([\s\S]*?)\n<\/script>/);
    const data = JSON.parse(m[1]);
    const src = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
    const same = JSON.stringify(Object.assign({}, src, {url: data.url})) === JSON.stringify(data);
    const code = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x => x[1]);
    new Function(code[0]);
    console.log(same + " " + code.length);
  ' "$OUTPAGE" "$ITEMS" 2>&1)
  check "data round-trips and the page script parses (node)" "true 1" "$rt"
else
  echo "  skip: node not on PATH (data round-trip + script parse)"
fi

f=$(mutate '.items[1].id = "api-51"')
out=$(rr build --items "$f" --out "$TMP/never.html"); rc=$?
check "invalid items fail the build" "1" "$rc"
check "no page is written for invalid items" "no" "$([[ -e "$TMP/never.html" ]] && echo yes || echo no)"
grep -v '^__RELEASE_DATA__$' "$SCRIPT_DIR/page.html" > "$TMP/broken-template.html"
out=$(rr build --items "$ITEMS" --out "$TMP/x.html" --template "$TMP/broken-template.html"); rc=$?
check "a template without the data line exits 2" "2" "$rc"
contains "names the missing marker" "$out" "__RELEASE_DATA__"
out=$(rr build --items "$ITEMS"); rc=$?
check "build without --out exits 2" "2" "$rc"

echo "== readback =="
RAW="$TMP/raw"
mkdir -p "$RAW/checks" "$RAW/decisions" "$RAW/notes" "$RAW/runbook"
# out_dir files are bare doc bodies, one per doc, named <doc_id>.json.
echo '{"status": "pass", "note": "Retry-After: 30", "by": "agent", "at": "2026-10-27T16:08:00Z"}' > "$RAW/checks/api-51-1.json"
echo '{"status": "", "note": "Baseline: 412 sessions", "by": "agent", "at": "2026-10-27T15:00:00Z"}' > "$RAW/checks/api-52-1.json"
echo '{"status": "fail", "note": "", "by": "u_operator1234567890abcd", "at": "2026-10-27T16:10:00Z"}' > "$RAW/checks/infra-7-1.json"
echo '{"status": "maybe", "note": 4, "by": 9, "at": "x"}' > "$RAW/checks/api-99-1.json"
echo '{"value": "hold", "at": "2026-10-27T15:30:00Z"}' > "$RAW/decisions/api-52.json"
echo '{"value": "ship", "at": "2026-10-27T15:31:00Z"}' > "$RAW/decisions/api-51.json"
echo '{"value": "yes"}' > "$RAW/decisions/infra-7.json"
echo '{"text": "Do we warn staff first?", "at": "2026-10-27T15:32:00Z"}' > "$RAW/notes/api-52.json"
echo '{"text": "old item", "at": "x"}' > "$RAW/notes/api-1.json"
echo '{"done": true, "at": "2026-10-27T15:00:00Z"}' > "$RAW/runbook/rb-01.json"
printf '{"done": tru' > "$RAW/runbook/rb-02.json"

out=$(rr readback --items "$ITEMS" --data "$RAW"); rc=$?
check "readback exits 0" "0" "$rc"
check "counts" '{"items":4,"steps":5,"pass":1,"fail":1,"pending":3,"noted":1,"set_by_people":1,"ship":1,"question":0,"hold":1,"undecided":2,"notes":1,"runbook_done":1,"runbook_total":2}' "$(jq -c .counts <<<"$out")"
check "per-repo counts" '[{"id":"api","pass":1,"fail":0,"pending":3,"hold":1},{"id":"infra","pass":0,"fail":1,"pending":0,"hold":0}]' "$(jq -c '[.repos[] | {id, pass, fail, pending, hold}]' <<<"$out")"
check "to_run skips done, optional and people steps" '["api-52-1"]' "$(jq -c '[.to_run[].id]' <<<"$out")"
check "to_run carries how and expect" '{"how":"Query the logs","expect":"One event"}' "$(jq -c '.to_run[0] | {how, expect}' <<<"$out")"
check "the agent may write over its own baseline" "true" "$(jq -r '.to_run[0].agent_may_write' <<<"$out")"
check "for_people lists the human step" '["api-51-2"]' "$(jq -c '[.for_people[].id]' <<<"$out")"
check "a recorded baseline is not needed again" '[]' "$(jq -c '.baselines_needed' <<<"$out")"
check "time_gated lists steps with a when" '[{"id":"api-51-2","when":"the next morning"}]' "$(jq -c '[.time_gated[] | {id, when}]' <<<"$out")"
check "failed carries the owner" '[{"id":"infra-7-1","owner":"viewer"}]' "$(jq -c '[.failed[] | {id, owner}]' <<<"$out")"
check "passed carries the evidence" "Retry-After: 30" "$(jq -r '.passed[0].note' <<<"$out")"
check "a person's tick is not the agent's to overwrite" "false" "$(jq -r '.steps[] | select(.id == "infra-7-1") | .owner == "agent"' <<<"$out")"
check "decisions per value" '{"ship":["api-51"],"question":[],"hold":["api-52"],"undecided":["infra-7","infra-9"]}' "$(jq -c .decisions <<<"$out")"
check "notes carry the decision" '[{"id":"api-52","decision":"hold","text":"Do we warn staff first?"}]' "$(jq -c '[.notes[] | {id, decision, text}]' <<<"$out")"
check "the runbook's next step" '{"id":"rb-02","phase":"Infra v0.9.0","action":"Tag v0.9.0"}' "$(jq -c .runbook.next <<<"$out")"
check "orphans from every collection" '["checks:api-99-1","notes:api-1"]' "$(jq -c '[.orphans[] | "\(.collection):\(.id)"]' <<<"$out")"
check "invalid fields are reported" '["checks:api-99-1:status","checks:api-99-1:note","checks:api-99-1:by","decisions:infra-7:value","runbook:rb-02:doc"]' \
  "$(jq -c '[.invalid[] | "\(.collection):\(.id):\(.field)"]' <<<"$out")"
check "an invalid decision reads as none" '""' "$(jq -c '.items[] | select(.id == "infra-7") | .decision' <<<"$out")"
check "an unreadable runbook doc reads as not done" "false" "$(jq -r '.runbook.steps[1].done' <<<"$out")"
check "out_dir files carry no version" "null" "$(jq -c '.steps[0].version' <<<"$out")"
check "write says how to record each step" '{"api-51-1":"update","api-51-2":"set","api-52-1":"update","api-52-2":"set","infra-7-1":"leave"}' \
  "$(jq -c '[.steps[] | {(.id): .write}] | add' <<<"$out")"
check "docs Claude may update with no version known need a pin" '["checks:api-51-1","checks:api-52-1","runbook:rb-02"]' \
  "$(jq -c '[.pins_needed[] | "\(.collection):\(.id)"]' <<<"$out")"
check "a runbook tick with no by is a person's" '{"owner":null,"write":"leave"}' "$(jq -c '.runbook.steps[0] | {owner, write}' <<<"$out")"
check "to_run carries the write mode" '{"exists":true,"write":"update"}' "$(jq -c '.to_run[0] | {exists, write}' <<<"$out")"
check "items carry their step counts" '{"id":"api-51","pass":1,"fail":0,"pending":1}' "$(jq -c '.items[0] | {id, pass, fail, pending}' <<<"$out")"

rm "$RAW/checks/api-52-1.json"
out=$(rr readback --items "$ITEMS" --data "$RAW" --repo api)
check "a step with a baseline and nothing recorded needs one" '["api-52-1"]' "$(jq -c '[.baselines_needed[].id]' <<<"$out")"
check "--repo narrows to_run" '["api-52-1"]' "$(jq -c '[.to_run[].id]' <<<"$out")"
out=$(rr readback --items "$ITEMS" --data "$RAW" --repo infra)
check "--repo infra has nothing to run" '[]' "$(jq -c '.to_run' <<<"$out")"
check "--repo keeps the full counts" "5" "$(jq -r '.counts.steps' <<<"$out")"
out=$(rr readback --items "$ITEMS" --data "$RAW" --repo web); rc=$?
check "an unknown --repo exits 2" "2" "$rc"

# A viewer who unticked a step leaves an empty doc: nothing to clobber.
echo '{"status": "", "note": "", "by": "u_operator1234567890abcd", "at": "x"}' > "$RAW/checks/api-52-1.json"
out=$(rr readback --items "$ITEMS" --data "$RAW")
check "an empty doc a person left is safe to write" "true" "$(jq -r '.to_run[] | select(.id == "api-52-1") | .agent_may_write' <<<"$out")"
echo '{"status": "", "note": "Holding this one", "by": "u_operator1234567890abcd", "at": "x"}' > "$RAW/checks/api-52-1.json"
out=$(rr readback --items "$ITEMS" --data "$RAW")
check "a person's note is not safe to overwrite" "false" "$(jq -r '.to_run[] | select(.id == "api-52-1") | .agent_may_write' <<<"$out")"
check "and its write mode is leave" "leave" "$(jq -r '.to_run[] | select(.id == "api-52-1") | .write' <<<"$out")"
check "a leave is never in pins_needed" '["api-51-1"]' "$(jq -c '[.pins_needed[] | select(.collection == "checks") | .id]' <<<"$out")"
# A page that couldn't learn the viewer's id writes by "viewer": still a person.
echo '{"status": "pass", "note": "Baseline: 412 sessions", "by": "viewer", "at": "x"}' > "$RAW/checks/api-52-1.json"
out=$(rr readback --items "$ITEMS" --data "$RAW")
check "by viewer reads as a person" '{"owner":"viewer","write":"leave"}' "$(jq -c '.steps[] | select(.id == "api-52-1") | {owner, write}' <<<"$out")"

mkdir -p "$TMP/fresh"
out=$(rr readback --items "$ITEMS" --data "$TMP/fresh")
check "a fresh page has everything pending" '{"pending":5,"undecided":4,"runbook_done":0}' "$(jq -c '.counts | {pending, undecided, runbook_done}' <<<"$out")"
check "a fresh page needs its baselines" '["api-52-1"]' "$(jq -c '[.baselines_needed[].id]' <<<"$out")"
mkdir -p "$TMP/wrong"; echo x > "$TMP/wrong/other.txt"
out=$(rr readback --items "$ITEMS" --data "$TMP/wrong"); rc=$?
check "a directory with none of the collections exits 2" "2" "$rc"
out=$(rr readback --items "$ITEMS" --data "$TMP/nowhere"); rc=$?
check "a missing data directory exits 2" "2" "$rc"
out=$(rr readback --items "$ITEMS"); rc=$?
check "readback without --data exits 2" "2" "$rc"
f=$(mutate '.items[1].id = "api-51"')
out=$(rr readback --items "$f" --data "$RAW"); rc=$?
check "readback refuses invalid items" "2" "$rc"

# The inline `ArtifactData list` output, one {id, data, version} per line, saved
# as a file per collection; and the array and {id: doc} map shapes.
mkdir -p "$TMP/inline"
cat > "$TMP/inline/checks" <<'JSON'
{"id":"api-51-1","data":{"status":"pass","note":"ok","by":"agent","at":"2026-10-27T16:08:00Z"},"version":3,"updatedAt":"2026-10-27T16:08:01Z"}
{"id":"infra-7-1","data":{"status":"fail","note":"no alarm","by":"agent","at":"2026-10-27T16:08:00Z"},"version":1,"updatedAt":"2026-10-27T16:08:01Z"}
JSON
jq -s . <<'JSON' > "$TMP/inline/decisions"
{"id":"infra-9","data":{"value":"question","at":"x"},"version":2}
JSON
echo '{"rb-02": {"done": true, "at": "x"}}' > "$TMP/inline/runbook"
out=$(rr readback --items "$ITEMS" --data "$TMP/inline")
check "JSON Lines input reads the statuses" '{"pass":1,"fail":1}' "$(jq -c '.counts | {pass, fail}' <<<"$out")"
check "JSON Lines input keeps the version" "3" "$(jq -r '.steps[] | select(.id == "api-51-1") | .version' <<<"$out")"
check "an array of docs reads the same" '["infra-9"]' "$(jq -c .decisions.question <<<"$out")"
check "an array keeps the decision's version" "2" "$(jq -r '.items[] | select(.id == "infra-9") | .decision_version' <<<"$out")"
check "an {id: doc} map reads the same" '{"id":"rb-02","done":true}' "$(jq -c '.runbook.steps[1] | {id, done}' <<<"$out")"
check "with versions known, nothing needs a pin" '[]' "$(jq -c '.pins_needed' <<<"$out")"

# Runbook write modes: Claude ticks only a new doc, its own, or an empty one.
mkdir -p "$TMP/rb/runbook"
echo '{"done": true, "at": "x", "by": "agent"}' > "$TMP/rb/runbook/rb-01.json"
out=$(rr readback --items "$ITEMS" --data "$TMP/rb")
check "an absent runbook doc is a set" "set" "$(jq -r '.runbook.steps[1].write' <<<"$out")"
check "Claude's own tick is an update that needs a pin" '{"owner":"agent","write":"update","pin":["runbook:rb-01"]}' \
  "$(jq -c '{owner: .runbook.steps[0].owner, write: .runbook.steps[0].write, pin: [.pins_needed[] | "\(.collection):\(.id)"]}' <<<"$out")"
echo '{"done": false, "at": "x", "by": "u_operator1234567890abcd"}' > "$TMP/rb/runbook/rb-01.json"
out=$(rr readback --items "$ITEMS" --data "$TMP/rb")
check "a person's untick is left alone" '{"owner":"viewer","write":"leave"}' "$(jq -c '.runbook.steps[0] | {owner, write}' <<<"$out")"
check "and is not in pins_needed" '[]' "$(jq -c '.pins_needed' <<<"$out")"
echo '{"done": false, "at": "x"}' > "$TMP/rb/runbook/rb-01.json"
out=$(rr readback --items "$ITEMS" --data "$TMP/rb")
check "an empty runbook doc is safe to update" "update" "$(jq -r '.runbook.steps[0].write' <<<"$out")"

echo "== report =="
md=$(rr report --items "$ITEMS" --data "$RAW"); rc=$?
check "report exits 0" "0" "$rc"
check "the report starts with the heading" "# Acme release review: api v2.4.0 and infra v0.9.0" "$(head -n 1 <<<"$md")"
contains "the report has the verdict" "$md" "## Verdict: Medium risk"
contains "the report has the do-first item" "$md" "- **Do first: Rehearse the pipeline** New runners. **Action:** Dry run."
contains "the report has each repo" "$md" "## Infra: v0.8.0 → v0.9.0"
contains "the report ticks a passed step" "$md" "- [x] **Header present** (\`agent\`, \`api-51-1\`)"
contains "the report marks a failed step" "$md" "- [ ] **Alarm exists** (\`agent+aws\`, \`infra-7-1\`) — **FAILED**"
contains "the report shows the evidence" "$md" "Evidence (agent): Retry-After: 30"
contains "the report shows the decision" "$md" "decision: **Hold**"
contains "the report shows the note" "$md" "- **Note on the page:** Do we warn staff first?"
contains "the report ticks the runbook" "$md" "1. [x] **Before tagging: Confirm main has not moved** (\`rb-01\`)"
contains "the report indents every line of a command" "$md" $'   git -C api rev-parse origin/main\n   git -C infra rev-parse origin/main'
contains "the report has the rollback" "$md" "## Rollback"
md=$(rr report --items "$ITEMS"); rc=$?
check "report without --data exits 0" "0" "$rc"
contains "with no data nothing is ticked" "$md" "- [ ] **Header present**"
out=$(rr report --items "$ITEMS" --out "$TMP/report.md"); rc=$?
check "report --out exits 0" "0" "$rc"
check "report --out writes the file" "# Acme release review: api v2.4.0 and infra v0.9.0" "$(head -n 1 "$TMP/report.md")"

echo "== extract =="
T="$TMP/agent.jsonl"
cat > "$T" <<'JSONL'
{"type":"user","message":{"role":"user","content":"Study PRs 51 and 52. ```json\n[\"from the prompt\"]\n```"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Plan:\n```json\n{\"draft\": true}\n```"}]}}
not json at all
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"hand_back","input":{"result":"Done.\n```json\n[{\"pr\": 51}, {\"pr\": 52}]\n```"}}]}}
JSONL
out=$(rr extract --transcript "$T" --out "$TMP/x/group.json"); rc=$?
check "extract exits 0" "0" "$rc"
check "extract finds the JSON inside a tool_use input" '[{"pr":51},{"pr":52}]' "$(jq -c . "$TMP/x/group.json")"
check "extract reports the shape" '{"type":"array","length":2}' "$(jq -c '{type, length}' <<<"$out")"
cat > "$TMP/two.jsonl" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"```json\n[1]\n```\nthen\n```json\n[2, 3]\n```"}]}}
JSONL
rr extract --transcript "$TMP/two.jsonl" --out "$TMP/two.json" >/dev/null
check "extract takes the last block in a message" "[2,3]" "$(jq -c . "$TMP/two.json")"
cat > "$TMP/out.md" <<'MD'
Here it is:
```json
{"items": [1]}
```
MD
rr extract --transcript "$TMP/out.md" --out "$TMP/md.json" >/dev/null
check "extract reads saved Markdown output" '{"items":[1]}' "$(jq -c . "$TMP/md.json")"
cat > "$TMP/none.jsonl" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"No JSON here."}]}}
JSONL
out=$(rr extract --transcript "$TMP/none.jsonl" --out "$TMP/none.json"); rc=$?
check "no block exits 2" "2" "$rc"
contains "says there was no block" "$out" "no closed"
cat > "$TMP/broken.jsonl" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"```json\n[1, 2\n```"}]}}
JSONL
out=$(rr extract --transcript "$TMP/broken.jsonl" --out "$TMP/broken.json"); rc=$?
check "an invalid block exits 2" "2" "$rc"
contains "says the block is not JSON" "$out" "is not valid JSON"
cat > "$TMP/open.jsonl" <<'JSONL'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"```json\n[1, 2]"}]}}
JSONL
out=$(rr extract --transcript "$TMP/open.jsonl" --out "$TMP/open.json"); rc=$?
check "an unclosed block exits 2" "2" "$rc"

echo "== scope =="
if command -v git >/dev/null 2>&1; then
  G="$TMP/git"
  mkdir -p "$G"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  git init -q --bare "$G/origin.git"
  git -C "$G/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$G/work" 2>/dev/null || { git init -q "$G/work"; git -C "$G/work" checkout -q -b main; }
  commit() { echo "$1" >> "$G/work/f.txt"; git -C "$G/work" add f.txt; git -C "$G/work" commit -q -m "$1"; git -C "$G/work" rev-parse HEAD; }
  c0=$(commit "Initial")
  c1=$(commit "Old change (#10)")
  git -C "$G/work" tag -a v2.3.0 -m v2.3.0
  c2=$(commit "Retry-After on 429s (#51)")
  c3=$(commit "Fix a typo")
  c4=$(commit "Staff sessions (#52)")
  git -C "$G/work" tag v2.4.0-rc1 "$c3"
  git -C "$G/work" remote add origin "$G/origin.git"
  git -C "$G/work" push -q origin main --tags
  git clone -q "$G/origin.git" "$G/clone"
  : "$c0" "$c1"

  mkdir -p "$TMP/gh"
  cat > "$TMP/fake-gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_DIR/calls"
[[ -f "$FAKE_GH_DIR/fail" ]] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
case "$*" in
  *"--state merged"*) cat "$FAKE_GH_DIR/merged.json" ;;
  *"--state open"*)   cat "$FAKE_GH_DIR/open.json" ;;
  "api repos/acme/api/commits/"*"/pulls")
    [[ -f "$FAKE_GH_DIR/pulls-fail" ]] && { echo "HTTP 502" >&2; exit 1; }
    sha="${2#repos/acme/api/commits/}"; sha="${sha%/pulls}"
    if [[ -f "$FAKE_GH_DIR/pulls-$sha.json" ]]; then cat "$FAKE_GH_DIR/pulls-$sha.json"; else echo '[]'; fi ;;
  *) echo "unexpected: $*" >&2; exit 1 ;;
esac
SH
  chmod +x "$TMP/fake-gh"
  jq -n --arg c2 "$c2" --arg c4 "$c4" '[
    {number: 52, title: "Staff sessions", url: "https://github.com/acme/api/pull/52", mergedAt: "2026-10-26T10:00:00Z",
     mergeCommit: {oid: $c4}, author: {login: "dana"}, labels: [{name: "security"}], baseRefName: "main"},
    {number: 51, title: "Retry-After on 429s", url: "https://github.com/acme/api/pull/51", mergedAt: "2026-10-25T10:00:00Z",
     mergeCommit: {oid: $c2}, author: {login: "sam"}, labels: [], baseRefName: "main"},
    {number: 60, title: "Merged to a release branch", url: "https://github.com/acme/api/pull/60", mergedAt: "2026-10-25T11:00:00Z",
     mergeCommit: {oid: "0000000000000000000000000000000000000000"}, author: {login: "sam"}, labels: [], baseRefName: "release"}
  ]' > "$TMP/gh/merged.json"
  echo '[{"number": 9, "title": "Pin the worker", "url": "https://github.com/acme/infra/pull/9", "isDraft": false,
          "reviewDecision": "APPROVED", "mergeable": "CONFLICTING", "baseRefName": "main", "headRefName": "pin", "labels": [], "updatedAt": "x"},
         {"number": 3, "title": "Old draft", "url": "https://github.com/acme/infra/pull/3", "isDraft": true,
          "reviewDecision": null, "mergeable": "MERGEABLE", "baseRefName": "main", "headRefName": "d", "labels": [{"name": "wip"}], "updatedAt": "x"}]' > "$TMP/gh/open.json"

  scope() { GH_BIN="$TMP/fake-gh" FAKE_GH_DIR="$TMP/gh" bash "$RELEASE_SH" scope "$@"; }
  out=$(scope --repo acme/api --path "$G/clone" --out "$TMP/scope/api.json"); rc=$?
  check "scope exits 0" "0" "$rc"
  S=$(cat "$TMP/scope/api.json")
  check "since defaults to the newest v* tag reachable from main" "v2.4.0-rc1" "$(jq -r .since <<<"$S")"
  check "head is origin's default branch" "$c4" "$(jq -r .head <<<"$S")"
  check "target is origin's default branch" "origin/main" "$(jq -r .target <<<"$S")"
  check "only PRs merged since the tag" '[52]' "$(jq -c '[.prs[].pr]' <<<"$S")"

  out=$(scope --repo acme/api --path "$G/clone" --since v2.3.0 --out "$TMP/scope/api.json"); rc=$?
  S=$(cat "$TMP/scope/api.json")
  check "an explicit --since" "v2.3.0" "$(jq -r .since <<<"$S")"
  check "the summary line" '{"commits":3,"prs":2,"direct_commits":1,"to_study":3,"open_prs":2}' "$(jq -c .counts <<<"$out")"
  check "no warnings on a clean range" '[]' "$(jq -c .warnings <<<"$out")"
  check "only the unmatched commit is looked up" "1" "$(grep -c "commits/$c3/pulls" "$TMP/gh/calls")"
  check "PRs come oldest first, matched by merge commit" '[51,52]' "$(jq -c '[.prs[].pr]' <<<"$S")"
  check "a PR carries its author and labels" '{"author":"dana","labels":["security"]}' "$(jq -c '.prs[1] | {author, labels}' <<<"$S")"
  check "a PR merged elsewhere is left out" "0" "$(jq '[.prs[] | select(.pr == 60)] | length' <<<"$S")"
  check "a commit with no PR is a direct commit" '[{"subject":"Fix a typo","pr_hint":null,"via_pr":null,"covered":false}]' \
    "$(jq -c '[.direct_commits[] | {subject, pr_hint, via_pr, covered}]' <<<"$S")"

  # A rebase-merged PR: only its last commit is the merge commit, so its
  # earlier commit is unmatched. The lookup ties it to the PR already listed.
  echo '[{"number": 52, "merged_at": "2026-10-26T10:00:00Z"}]' > "$TMP/gh/pulls-$c3.json"
  out=$(scope --repo acme/api --path "$G/clone" --since v2.3.0 --out "$TMP/scope/api.json")
  check "a rebase-merged PR's earlier commit is covered" '{"via_pr":52,"covered":true}' "$(jq -c '.direct_commits[0] | {via_pr, covered}' "$TMP/scope/api.json")"
  check "a covered commit isn't counted to study" "2" "$(jq -r .counts.to_study <<<"$out")"
  rm "$TMP/gh/pulls-$c3.json"

  touch "$TMP/gh/pulls-fail"
  out=$(scope --repo acme/api --path "$G/clone" --since v2.3.0 --out "$TMP/scope/api.json"); rc=$?
  check "a failed lookup does not fail scope" "0" "$rc"
  contains "but warns" "$(jq -r '.warnings | join(" | ")' <<<"$out")" "could not look up the PR for 1 direct commits"
  rm "$TMP/gh/pulls-fail"

  cp "$TMP/gh/merged.json" "$TMP/gh/merged-keep.json"
  jq '. + [range(0; 997) | {number: (1000 + .), title: "old", url: "https://github.com/acme/api/pull/1", mergedAt: "2026-10-01T00:00:00Z",
                             mergeCommit: {oid: "1111111111111111111111111111111111111111"}, author: null, labels: [], baseRefName: "main"}]' \
    "$TMP/gh/merged-keep.json" > "$TMP/gh/merged.json"
  out=$(scope --repo acme/api --path "$G/clone" --since v2.3.0 --out "$TMP/scope/api.json")
  contains "hitting gh's 1000-PR limit warns" "$(jq -r '.warnings | join(" | ")' <<<"$out")" "returned 1000 merged PRs, its limit"
  mv "$TMP/gh/merged-keep.json" "$TMP/gh/merged.json"
  check "open PRs, sorted, with review state" '[{"pr":3,"draft":true,"labels":["wip"]},{"pr":9,"review":"APPROVED","mergeable":"CONFLICTING"}]' \
    "$(jq -c '[.open_prs[] | if .pr == 3 then {pr, draft, labels} else {pr, review, mergeable} end]' <<<"$S")"
  check "the merged search starts a day before the tag" "1" "$(grep -c 'merged:>=' "$TMP/gh/calls" | awk '{print ($1 > 0)}')"

  # Unmatched (#N) subjects keep their hint: a rebase-merged PR's other commits.
  jq '[.[] | select(.number != 51)]' "$TMP/gh/merged.json" > "$TMP/gh/m2.json" && mv "$TMP/gh/m2.json" "$TMP/gh/merged.json"
  scope --repo acme/api --path "$G/clone" --since v2.3.0 --out "$TMP/scope/api.json" >/dev/null
  check "a (#N) subject with no matched PR keeps its hint" "51" "$(jq -r '.direct_commits[] | select(.subject | startswith("Retry")) | .pr_hint' "$TMP/scope/api.json")"
  # The search missed #51, but the lookup still finds it: study it as a PR.
  echo '[{"number": 51, "merged_at": "2026-10-25T10:00:00Z"}, {"number": 49, "merged_at": null}]' > "$TMP/gh/pulls-$c2.json"
  scope --repo acme/api --path "$G/clone" --since v2.3.0 --out "$TMP/scope/api.json" >/dev/null
  check "the lookup names a PR the search missed, and it isn't covered" '{"via_pr":51,"covered":false}' \
    "$(jq -c '.direct_commits[] | select(.subject | startswith("Retry")) | {via_pr, covered}' "$TMP/scope/api.json")"

  out=$(scope --repo acme/api --path "$G/clone" --since v2.3.0 --target "$c3" --out "$TMP/scope/t.json"); rc=$?
  check "an explicit --target" "$c3" "$(jq -r .head "$TMP/scope/t.json")"

  git init -q "$G/notags"
  echo x > "$G/notags/a"; git -C "$G/notags" add a; git -C "$G/notags" commit -q -m one
  git -C "$G/notags" remote add origin "$G/notags"
  out=$(scope --repo acme/api --path "$G/notags" --target HEAD --out "$TMP/scope/n.json"); rc=$?
  check "no v* tag exits 2" "2" "$rc"
  contains "and says to pass --since" "$out" "pass --since"
  out=$(scope --repo acme/api --path "$G/clone" --since "$c4" --target "$c2" --out "$TMP/scope/n.json"); rc=$?
  check "a --since that is not an ancestor exits 2" "2" "$rc"
  contains "says so" "$out" "is not an ancestor"
  touch "$TMP/gh/fail"
  out=$(scope --repo acme/api --path "$G/clone" --out "$TMP/scope/n.json"); rc=$?
  check "a gh failure exits 2" "2" "$rc"
  contains "and passes gh's message on" "$out" "Bad credentials"
  rm "$TMP/gh/fail"
  out=$(scope --repo not-a-repo --path "$G/clone" --out "$TMP/scope/n.json"); rc=$?
  check "a malformed --repo exits 2" "2" "$rc"
  out=$(scope --repo acme/api --path "$TMP" --out "$TMP/scope/n.json"); rc=$?
  check "a path that is not a checkout exits 2" "2" "$rc"
else
  echo "  skip: git not on PATH (scope)"
fi

echo "== usage =="
out=$(rr bogus --items "$ITEMS"); rc=$?
check "an unknown subcommand exits 2" "2" "$rc"
out=$(rr check --items "$ITEMS" --nope); rc=$?
check "an unknown flag exits 2" "2" "$rc"
out=$(rr); rc=$?
check "no subcommand prints usage and exits 2" "2" "$rc"

echo
echo "release_test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
