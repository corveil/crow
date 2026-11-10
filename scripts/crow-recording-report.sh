#!/usr/bin/env bash
# crow-recording-report.sh — is Corveil recording each Crow session?
#
# Deterministic, read-only, no LLM, and never prints a secret. Works on any
# Crow install: it needs only the `crow` CLI (talking to a running crowd), `jq`,
# and optionally a `corveil` CLI login. It does NOT need the sidebar-recording
# spike build; the spike's sidebar glyphs compute the same answers in crowd.
#
# Usage:
#   cd <devRoot or any folder under it>        # e.g. a Manager's .crow/managers/<id>
#   scripts/crow-recording-report.sh | column -t -s $'\t'
#
#   CROW_DEVROOT=/path/to/devroot  scripts/crow-recording-report.sh   # from anywhere
#   GW_PAGES=10                    scripts/crow-recording-report.sh   # scan 10×500 requests
#
# Columns: name, kind, status, workspace, gw_launch (settings.local.json routes
# through a gateway), gw_seen (PROOF: the session's Claude Code conversation ids
# in Corveil's gateway request log), transcripts (log-sync ledger status).
#
# gw_seen only sees the org your `corveil` login belongs to
# (`corveil control observability logs-list`); sessions whose traffic goes to
# another org read "no requests in window". Without a login it reads "unknown".
#
# crow-recording-report.sh — deterministic, read-only, no LLM.
# For every Crow session:
#   gw_launch : did the agent launch with a gateway (its .claude/settings.local.json env)
#   gw_seen   : PROOF — requests from this session's Claude Code conversations in
#               Corveil's gateway request log (metadata.request_body_claude_code_session)
#   transcripts: log-sync ledger status
# Needs: crow, jq, and a `corveil` login that can read the org request log
# (`corveil control observability logs-list`). Without it gw_seen is "unknown".
#
# Env: GW_LOG_LIMIT (default 2000) — how many recent gateway requests to scan.
#      CROW_DEVROOT  — defaults to the folder holding .crow/ above $PWD.
set -uo pipefail

DEVROOT="${CROW_DEVROOT:-}"
if [ -z "$DEVROOT" ]; then
  d="$PWD"; while [ "$d" != "/" ] && [ ! -d "$d/.crow" ]; do d="$(dirname "$d")"; done
  DEVROOT="$d"
fi
[ -d "$DEVROOT/.crow" ] || { echo "can't find devRoot (folder with .crow/); set CROW_DEVROOT" >&2; exit 1; }
LEDGER="$DEVROOT/.claude/logsync-ledger.json"
[ -f "$LEDGER" ] || LEDGER=/dev/null
WS_JSON="$(crow workspace list)"
QUIET="$(crow logsync get | jq -r '.logsync.quiet_period_minutes')"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- Gateway request log → {conversation_id: {n, last}} ----------------------
GW_OK=false; GW_WINDOW="n/a"
# The API caps a page at 500 (a larger --limit silently falls back to 50), so
# page with next_cursor. GW_PAGES × 500 recent requests (default 6 → 3000).
cursor=""; : >"$WORK/pages.jsonl"
for _ in $(seq 1 "${GW_PAGES:-6}"); do
  corveil control observability logs-list --limit 500 ${cursor:+--cursor "$cursor"} 2>/dev/null >"$WORK/page.json" || break
  jq -e '.logs' "$WORK/page.json" >/dev/null 2>&1 || break
  jq -c '.logs[]' "$WORK/page.json" >>"$WORK/pages.jsonl"
  cursor=$(jq -r '.next_cursor // empty' "$WORK/page.json"); [ -n "$cursor" ] || break
done
if [ -s "$WORK/pages.jsonl" ]; then
  jq -s '{logs: .}' "$WORK/pages.jsonl" >"$WORK/gw.json"
  GW_OK=true
  jq '[.logs[] | select(.metadata.request_body_claude_code_session != null)
       | {id: .metadata.request_body_claude_code_session, at: .created_at}]
      | group_by(.id) | map({key: .[0].id, value: {n: length, last: (map(.at) | max)}}) | from_entries' \
     "$WORK/gw.json" >"$WORK/gwmap.json"
  GW_WINDOW=$(jq -r '[.logs[].created_at] | "\(min // "?") → \(max // "?") (\(length) requests)"' "$WORK/gw.json")
fi

slug() { printf '%s' "$1" | sed 's#[^A-Za-z0-9]#-#g'; }
# Conversation ids for a cwd (order doesn't matter: callers count and look up).
convs() {
  local f
  for f in "$HOME/.claude/projects/$(slug "$1")"/*.jsonl; do
    [ -e "$f" ] || continue
    f="${f##*/}"; printf '%s\n' "${f%.jsonl}"
  done
}

gw_env() {
  local f="$1/.claude/settings.local.json"
  [ -n "$1" ] && [ -f "$f" ] || { echo "n/a"; return; }
  jq -r 'if (.env.ANTHROPIC_BASE_URL // "") != "" then "yes" else "no" end' "$f" 2>/dev/null || echo "n/a"
}

# conversation ids on stdin → "VERIFIED n req, last <ts>" / "no requests in window"
gw_seen() {
  $GW_OK || { echo "unknown (corveil logs unreadable)"; return; }
  jq -Rrn --slurpfile M "$WORK/gwmap.json" '
    [inputs | select(length>0)] as $ids | $M[0] as $m
    | [$ids[] | $m[.] | select(. != null)] as $hits
    | if ($hits|length)==0 then "no requests in window"
      else "VERIFIED \($hits|map(.n)|add) req, last \($hits|map(.last)|max|.[0:19])Z" end'
}

ledger_counts() {
  jq -Rrn --slurpfile L <(cat "$LEDGER" 2>/dev/null || echo '{}') '
    [inputs | select(length>0)] as $ids
    | ($L[0].entries // {}) as $e
    | [$ids[] as $id | ([$e | to_entries[] | select(.key|startswith($id + ":")) | .value.status] | first // "none")]
    | {up: map(select(.=="uploaded"))|length, retry: map(select(.=="failedTransient"))|length,
       rejected: map(select(.=="skippedPermanent"))|length, none: map(select(.=="none"))|length}
    | "\(.up) up / \(.retry) retry / \(.rejected) rejected / \(.none) not yet"'
}

printf 'name\tkind\tstatus\tworkspace\tgw_launch\tgw_seen\ttranscripts\n'
crow list-sessions | jq -c '.sessions[]' | while read -r s; do
  id=$(jq -r .id <<<"$s"); name=$(jq -r '.name[0:48]' <<<"$s"); kind=$(jq -r .kind <<<"$s")
  status=$(jq -r .status <<<"$s"); agent=$(jq -r .agent_kind <<<"$s"); primary=$(jq -r .is_primary_manager <<<"$s")
  gs="$(crow get-session --session "$id")"
  ws=$(jq -r '.workspace_name // "-"' <<<"$gs")
  ws_up=$(jq -r --arg w "$ws" '[.workspaces[]|select((.name|ascii_downcase)==($w|ascii_downcase))|.upload_session_logs][0] // false' <<<"$WS_JSON")

  if [ "$kind" = "manager" ]; then
    if [ "$primary" = "true" ]; then dir="$DEVROOT"; else dir="$DEVROOT/.crow/managers/$id"; fi
  else
    dir=$(crow list-worktrees --session "$id" | jq -r '([.worktrees[]? | select(.primary)][0] // .worktrees[0] // {}).path // empty')
  fi
  ids="$( [ -n "$dir" ] && convs "$dir" )"

  if [ "$agent" = "claude-code" ]; then
    launch=$(gw_env "$dir"); seen=$(printf '%s\n' "$ids" | gw_seen)
  else
    launch="unknown ($agent)"; seen="n/a (only Claude Code tags requests)"
  fi

  if [ "$kind" = "manager" ]; then
    n=$(printf '%s\n' "$ids" | grep -c . || true)
    if [ "$primary" = "true" ]; then tr="never (primary Manager)"
    elif [ "$(jq -r '.manager_workspace_name // empty' <<<"$s")" = "" ]; then tr="never (untagged Manager)"
    elif [ "$ws_up" != "true" ]; then tr="never ('$ws' not opted in)"
    elif [ "$n" -eq 0 ]; then tr="no conversations found"
    else tr="$n convs: $(printf '%s\n' "$ids" | ledger_counts)"; fi
  else
    if [ "$ws_up" != "true" ]; then tr="never ('$ws' not opted in)"
    else tr="$(printf '%s\n' "$id" | ledger_counts)"; fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$kind" "$status" "$ws" "$launch" "$seen" "$tr"
done
echo "gateway log window: $GW_WINDOW" >&2
echo "transcript quiet period: ${QUIET} min ('not yet' inside it is expected)" >&2
