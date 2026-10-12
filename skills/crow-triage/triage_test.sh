#!/usr/bin/env bash
# Unit tests for triage.sh (CROW-1325): items.json validation, the page build
# (placeholders, escaping, the data round-trip), and readback's join of the
# `decisions` docs to the items, in every input shape ArtifactData produces.
#
# Pure file in, JSON out: nothing touches claude.ai. When node is on PATH the
# built page's data block is parsed back and its inline script syntax-checked.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIAGE_SH="$SCRIPT_DIR/triage.sh"

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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-1325-triage-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

triage() { bash "$TRIAGE_SH" "$@"; }

ITEMS="$TMP/items.json"
cat > "$ITEMS" <<'JSON'
{
  "title": "CI <Ticket> & Triage",
  "context": "corveil/corveil · CI tickets · 12 Oct 2026",
  "lede": "Mark each one **Kick off**, **Later** or **Drop**.",
  "suggested": "8-alt, then 7.",
  "answers": [
    {"question": "Would a re-run make it worse?", "short": "Yes.",
     "table": {"columns": ["Label", "Effect"], "rows": [["`ci:full`", "Unlocks the suite."]]},
     "points": ["138 failures."], "figures": [{"value": "138", "label": "real failures"}],
     "verdict": "Drop 2.", "footnote": "229 PRs."}
  ],
  "groups": [
    {"id": "s1", "title": "Step 1", "sub": "This week"},
    {"id": "s2", "title": "Step 2", "sub": "Next two weeks"}
  ],
  "labels": {"effect": "Effect per month"},
  "items": [
    {"id": "2", "group": "s1", "repo": "corveil/crow", "title": "Re-run failed jobs once", "verdict": "counterproductive",
     "effect": "**+160** re-runs/mo", "effort": "Hours", "rec": "Drop", "rec_why": "One prompt sentence instead.",
     "evidence": ["138 real failures."], "mechanism": "Re-runs only fix flakes.", "risks": "Queue load.", "changed": "Sessions are free."},
    {"id": "4", "group": "s1", "repo": "corveil/corveil", "title": "Gate the mcp-runner build",
     "summary": "Text with </script><script>alert(1)</script> in it.", "verdict": "worth"},
    {"id": "7", "group": "s1", "repo": "corveil/corveil", "title": "Fix the digest check", "verdict": "bug"},
    {"id": "8", "group": "s2", "repo": "corveil/crow", "title": "Merge lane", "verdict": "strong"},
    {"id": "8-alt", "group": "s2", "repo": "corveil/corveil", "title": "Drop require-up-to-date", "verdict": "strong"}
  ],
  "method": ["Workflow files at `main`."]
}
JSON

# mutate <jq filter> → path of a copy of $ITEMS with the filter applied
n_mut=0
mutate() {
  n_mut=$((n_mut+1))
  local f="$TMP/mut-$n_mut.json"
  jq "$1" "$ITEMS" > "$f"
  printf '%s' "$f"
}

echo "== check =="
out=$(triage check --items "$ITEMS"); rc=$?
check "valid items exit 0" "0" "$rc"
check "status ok" "ok" "$(jq -r .status <<<"$out")"
check "counts the items" "5" "$(jq -r .items <<<"$out")"
check "counts items per group" '[{"id":"s1","items":3},{"id":"s2","items":2}]' "$(jq -c '[.groups[] | {id, items}]' <<<"$out")"
check "counts verdicts" '{"bug":1,"counterproductive":1,"strong":2,"worth":1}' "$(jq -c .verdicts <<<"$out")"

expect_error() { # expect_error <description> <jq mutation> <needle>
  local f out rc
  f=$(mutate "$2")
  out=$(triage check --items "$f"); rc=$?
  check "$1 exits 1" "1" "$rc"
  contains "$1 names the problem" "$(jq -r '.errors | join(" | ")' <<<"$out")" "$3"
}
expect_error "duplicate item id" '.items[1].id = "2"' 'item id "2" is used more than once'
expect_error "id with a slash" '.items[0].id = "a/b"' 'may use only letters, digits'
expect_error "id of a single dot" '.items[0].id = "."' 'may use only letters, digits'
expect_error "numeric id" '.items[0].id = 2' 'id must be a string'
expect_error "missing repo" 'del(.items[2].repo)' 'item 3 (7): repo is required'
expect_error "missing title" '.items[2].title = ""' 'item 3 (7): title is required'
expect_error "unknown verdict" '.items[0].verdict = "great"' 'verdict must be one of strong, worth'
expect_error "unknown group" '.items[0].group = "s9"' 'group must be one of s1, s2'
expect_error "group without groups" 'del(.groups)' 'is set but the page has no groups'
expect_error "evidence not a list" '.items[0].evidence = "one"' 'evidence must be an array of strings'
expect_error "non-string field" '.items[0].effort = 3' 'effort must be a string'
expect_error "no page title" 'del(.title)' 'title is required'
expect_error "no items" '.items = []' 'items must be a non-empty array'
expect_error "groups not a list" '.groups = {}' 'groups must be an array'
expect_error "duplicate group id" '.groups[1].id = "s1"' 'group id "s1" is used more than once'
expect_error "answer without a question" 'del(.answers[0].question)' 'answer 1: question is required'
expect_error "malformed figures" '.answers[0].figures = [{"value": 1}]' 'figures must be an array of {value, label} strings'
expect_error "malformed table" '.answers[0].table.rows = ["x"]' 'table must be {columns'
expect_error "labels not strings" '.labels = {"effect": 1}' 'labels must be an object of strings'

f=$(mutate '.groups += [{"id": "s3", "title": "Empty"}]')
out=$(triage check --items "$f"); rc=$?
check "an empty group is only a warning" "0" "$rc"
contains "warns about the empty group" "$(jq -r '.warnings | join(" | ")' <<<"$out")" 'group "s3" has no items'

f=$(mutate 'del(.groups) | .items |= map(del(.group))')
out=$(triage check --items "$f"); rc=$?
check "items without groups are valid" "0" "$rc"

printf 'not json' > "$TMP/bad.json"
out=$(triage check --items "$TMP/bad.json"); rc=$?
check "unparseable items exit 2" "2" "$rc"
out=$(triage check --items "$TMP/missing.json"); rc=$?
check "missing items file exits 2" "2" "$rc"
out=$(triage check); rc=$?
check "check without --items exits 2" "2" "$rc"

echo "== build =="
PAGE="$TMP/out/page.html"
out=$(triage build --items "$ITEMS" --out "$PAGE"); rc=$?
check "build exits 0" "0" "$rc"
check "build reports the path" "$PAGE" "$(jq -r .out <<<"$out")"
html=$(cat "$PAGE")
lacks "no data placeholder left" "$html" "__TRIAGE_DATA__"
lacks "no title placeholder left" "$html" "__TRIAGE_TITLE__"
check "title is HTML-escaped" "<title>CI &lt;Ticket&gt; &amp; Triage</title>" "$(head -n 1 "$PAGE")"
check "item text cannot close the data block" "0" "$(grep -c '</script><script>alert' "$PAGE")"
# grep -F, not `contains`: bash 3.2 still reads a backslash in a quoted [[ == ]] pattern as an escape.
check "the escaped text is still in the data" "1" "$(grep -cF 'Text with \u003c/script>\u003cscript>alert(1)\u003c/script> in it.' "$PAGE")"
check "exactly one data block" "1" "$(grep -c 'id="triage-data"' "$PAGE")"
contains "page declares the decisions collection" "$html" 'db.collection("decisions")'
contains "page reads the db through claude.use" "$html" 'c.use("db")'

if command -v node >/dev/null 2>&1; then
  rt=$(node -e '
    const fs = require("fs");
    const html = fs.readFileSync(process.argv[1], "utf8");
    const m = html.match(/<script type="application\/json" id="triage-data">\n([\s\S]*?)\n<\/script>/);
    const same = JSON.stringify(JSON.parse(m[1])) === JSON.stringify(JSON.parse(fs.readFileSync(process.argv[2], "utf8")));
    const code = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(x => x[1]);
    new Function(code[0]);
    console.log(same + " " + code.length);
  ' "$PAGE" "$ITEMS" 2>&1)
  check "data round-trips and the page script parses (node)" "true 1" "$rt"
else
  echo "  skip: node not on PATH (data round-trip + script parse)"
fi

f=$(mutate '.items[1].id = "2"')
out=$(triage build --items "$f" --out "$TMP/never.html"); rc=$?
check "invalid items fail the build" "1" "$rc"
check "no page is written for invalid items" "no" "$([[ -e "$TMP/never.html" ]] && echo yes || echo no)"
grep -v '^__TRIAGE_DATA__$' "$SCRIPT_DIR/page.html" > "$TMP/broken-template.html"
out=$(triage build --items "$ITEMS" --out "$TMP/x.html" --template "$TMP/broken-template.html"); rc=$?
check "a template without the data line exits 2" "2" "$rc"
contains "names the missing marker" "$out" "__TRIAGE_DATA__"
out=$(triage build --items "$ITEMS"); rc=$?
check "build without --out exits 2" "2" "$rc"

echo "== readback =="
DEC="$TMP/raw/decisions"
mkdir -p "$DEC"
# out_dir files are bare doc bodies, one per doc, named <doc_id>.json.
cat > "$DEC/4.json" <<'JSON'
{"status": "go", "note": "Also notify #ci-alerts.", "by": "u_sam", "at": "2026-10-12T19:00:00Z", "ticket": null}
JSON
cat > "$DEC/2.json" <<'JSON'
{"status": "drop", "note": "", "by": "u_sam", "at": "2026-10-12T19:01:00Z", "ticket": null}
JSON
cat > "$DEC/8-alt.json" <<'JSON'
{"status": "later", "note": "Would this let duplicate migration numbers merge?", "by": "u_dana", "at": "2026-10-12T19:02:00Z", "ticket": null}
JSON
cat > "$DEC/7.json" <<'JSON'
{"status": "go", "note": "", "by": "u_dana", "at": "2026-10-12T19:03:00Z", "ticket": "https://github.com/corveil/corveil/issues/4500"}
JSON
cat > "$DEC/8.json" <<'JSON'
{"status": "later", "note": "", "by": "u_sam", "at": "2026-10-12T19:04:00Z", "ticket": "https://github.com/corveil/crow/issues/1400"}
JSON
cat > "$DEC/99.json" <<'JSON'
{"status": "maybe", "note": "orphan", "by": "u_sam", "at": "2026-10-12T19:05:00Z", "ticket": "javascript:alert(1)"}
JSON

out=$(triage readback --items "$ITEMS" --decisions "$DEC"); rc=$?
check "readback exits 0" "0" "$rc"
check "counts" '{"items":5,"go":2,"later":2,"drop":1,"undecided":0,"notes":2,"filed":2}' "$(jq -c .counts <<<"$out")"
check "go ids in page order" '["4","7"]' "$(jq -c .go <<<"$out")"
check "to_file skips the filed go item" '["4"]' "$(jq -c .to_file <<<"$out")"
check "notes are listed with their status" '[{"id":"4","status":"go"},{"id":"8-alt","status":"later"}]' "$(jq -c '[.notes[] | {id, status}]' <<<"$out")"
check "a ticket on a non-go item is flagged" '[{"id":"8","status":"later"}]' "$(jq -c '[.filed_not_go[] | {id, status}]' <<<"$out")"
check "a decision for an unknown id is an orphan" '["99"]' "$(jq -c '[.orphans[].id]' <<<"$out")"
check "an invalid status reads as undecided in the orphan" "null" "$(jq -c '.orphans[0].status' <<<"$out")"
check "invalid fields are reported" '["status","ticket"]' "$(jq -c '[.invalid[].field]' <<<"$out")"
check "people are unique user ids" '["u_dana","u_sam"]' "$(jq -c .people <<<"$out")"
check "items carry title and repo" '{"id":"4","title":"Gate the mcp-runner build","repo":"corveil/corveil"}' "$(jq -c '.items[1] | {id, title, repo}' <<<"$out")"
check "out_dir files carry no version" "null" "$(jq -c '.items[0].version' <<<"$out")"

printf '{"status": "go"' > "$DEC/2.json"
cat > "$DEC/4.json" <<'JSON'
{"status": "go", "note": 7, "by": 12, "at": "2026-10-12T19:00:00Z", "ticket": "ftp://x"}
JSON
out=$(triage readback --items "$ITEMS" --decisions "$DEC")
contains "an unreadable doc is reported" "$(jq -c '.invalid' <<<"$out")" '"problem":"file is not valid JSON"'
check "an unreadable doc counts as undecided" '["2"]' "$(jq -c .undecided <<<"$out")"
check "wrong-typed note, by and ticket are reported" '["by","note","ticket"]' "$(jq -c '[.invalid[] | select(.id == "4") | .field] | sort' <<<"$out")"
check "a non-http ticket is not treated as filed" '["4"]' "$(jq -c .to_file <<<"$out")"
check "a non-string note reads as empty" '""' "$(jq -c '.items[] | select(.id == "4") | .note' <<<"$out")"

mkdir -p "$TMP/empty"
out=$(triage readback --items "$ITEMS" --decisions "$TMP/empty")
check "an empty collection leaves every item undecided" "5" "$(jq -r .counts.undecided <<<"$out")"
check "an empty collection has nothing to file" "[]" "$(jq -c .to_file <<<"$out")"

# The inline `ArtifactData list` output: one {id, data, version, updatedAt} per line.
cat > "$TMP/inline.jsonl" <<'JSON'
{"id":"4","data":{"status":"go","note":"","by":"u_sam","at":"2026-10-12T19:00:00Z","ticket":null},"version":3,"updatedAt":"2026-10-12T19:00:01Z"}
{"id":"7","data":{"status":"drop","note":"","by":"u_sam","at":"2026-10-12T19:00:00Z","ticket":null},"version":1,"updatedAt":"2026-10-12T19:00:01Z"}
JSON
out=$(triage readback --items "$ITEMS" --decisions "$TMP/inline.jsonl")
check "JSON Lines input reads the statuses" '{"go":["4"],"drop":["7"]}' "$(jq -c '{go, drop}' <<<"$out")"
check "JSON Lines input keeps the version" "3" "$(jq -r '.items[] | select(.id == "4") | .version' <<<"$out")"

jq -s . "$TMP/inline.jsonl" > "$TMP/array.json"
out=$(triage readback --items "$ITEMS" --decisions "$TMP/array.json")
check "an array of docs reads the same" '{"go":["4"],"drop":["7"]}' "$(jq -c '{go, drop}' <<<"$out")"

echo '{"4": {"status": "later", "note": "", "by": null, "at": null, "ticket": null}}' > "$TMP/map.json"
out=$(triage readback --items "$ITEMS" --decisions "$TMP/map.json")
check "an {id: doc} map reads the same" '["4"]' "$(jq -c .later <<<"$out")"

out=$(triage readback --items "$ITEMS" --decisions "$TMP/nowhere"); rc=$?
check "a missing decisions path exits 2" "2" "$rc"
out=$(triage readback --items "$ITEMS"); rc=$?
check "readback without --decisions exits 2" "2" "$rc"
f=$(mutate '.items[1].id = "2"')
out=$(triage readback --items "$f" --decisions "$DEC"); rc=$?
check "readback refuses invalid items" "2" "$rc"

echo "== usage =="
out=$(triage bogus --items "$ITEMS"); rc=$?
check "unknown subcommand exits 2" "2" "$rc"
out=$(triage check --items "$ITEMS" --nope); rc=$?
check "unknown flag exits 2" "2" "$rc"

echo
echo "triage_test: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
