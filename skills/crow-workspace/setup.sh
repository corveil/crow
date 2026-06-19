#!/bin/bash
# setup.sh — Deterministic workspace setup for Crow
#
# Called by the crow-workspace skill after the LLM resolves names,
# detects PRs, and composes the prompt content. This script handles
# all mechanical operations: git worktree creation, crow session
# setup, GitHub housekeeping, prompt file writing, and Claude Code launch.
#
# All output goes to stderr except the final JSON result on stdout.

set -uo pipefail
# NOTE: We intentionally do NOT use `set -e`. Each fallible command is
# handled explicitly with `if ! ...` or `|| die/log` so that we always
# emit structured JSON on failure instead of silently exiting.

# ─── Defaults ────────────────────────────────────────────────────────────────

DEV_ROOT=""
WORKSPACE=""
REPO=""
REPO_PATH=""
SLUG=""
BRANCH=""
WORKTREE_PATH=""
SESSION_NAME=""
PROVIDER=""
CLI_TOOL=""
HOST=""
TICKET_URL=""
TICKET_TITLE=""
TICKET_NUMBER=""
PR_NUMBER=""
PR_URL=""
PR_BRANCH=""
PROMPT_CONTENT=""
CLAUDE_BINARY=""
AGENT_BINARY=""
AGENT_KIND=""
SESSION_ID=""
PRIMARY=false
SKIP_LAUNCH=false
SKIP_ASSIGN=false
SKIP_PROJECT_STATUS=false
BASE_BRANCH=""

# Runtime state
TERMINAL_ID=""

# Resolved AI gateway for this workspace (populated by resolve_gateway_env).
WS_BASE_URL=""
WS_CUSTOM_HEADERS=""
WS_HAS_GATEWAY=false
WS_GATEWAY_RESOLVED=false

# Resolved task provider for this workspace (populated by resolve_task_provider).
# The CODE provider lives in $PROVIDER (github/gitlab); the TASK provider may
# differ (e.g. github code + jira tasks). Empty until resolved; falls back to
# $PROVIDER. Used to skip GitHub issue housekeeping for Jira tickets (CROW-522).
TASK_PROVIDER=""
TASK_PROVIDER_RESOLVED=false

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() { echo "[setup.sh] $*" >&2; }

# Extract a JSON string value by key. Handles both compact and pretty-printed JSON.
# Usage: json_val "key" <<< "$json_string"
json_val() {
  local key="$1"
  # Normalize whitespace: collapse the JSON to one line, strip spaces around : and quotes
  tr -d '\n' | sed 's/[[:space:]]*:[[:space:]]*/:/g' | grep -o "\"$key\":\"[^\"]*\"" | cut -d'"' -f4 | head -1
}

# Extract the `readiness` of a specific terminal id from `crow list-terminals`
# JSON. Walks the flat per-terminal objects, finds the one carrying our id, and
# reads its readiness field. Usage: terminal_readiness "$tid" "$json"
terminal_readiness() {
  local tid="$1" json="$2"
  printf '%s' "$json" | tr -d '\n' | grep -o '{[^{}]*}' | grep "\"$tid\"" \
    | grep -o '"readiness":"[^"]*"' | cut -d'"' -f4 | head -1
}

# POSIX single-quote an arg so it's safe to interpolate into a shell command.
# Mirrors Swift's shellQuote() in ClaudeLaunchArgs: wraps value in '...' and
# escapes embedded single-quotes as '\''.
posix_quote() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

# Read the global remoteControlEnabled flag from {devRoot}/.claude/config.json.
# Returns 0 if true, 1 otherwise. Missing file / malformed JSON / missing
# key all default to 1 (off), matching AppConfig's decodeIfPresent behavior.
is_remote_control_enabled() {
  local config_path="$DEV_ROOT/.claude/config.json"
  [[ -f "$config_path" ]] || return 1
  tr -d '\n' < "$config_path" \
    | grep -qE '"remoteControlEnabled"[[:space:]]*:[[:space:]]*true'
}

# Read the attributionTrailers flag from {devRoot}/.claude/config.json.
# Defaults to 0 (on) when the file is missing, malformed, or the key is
# absent — matches AppConfig's decodeIfPresent default. Returns 1 only
# when the key is explicitly set to false.
is_attribution_trailers_enabled() {
  local config_path="$DEV_ROOT/.claude/config.json"
  [[ -f "$config_path" ]] || return 0
  if tr -d '\n' < "$config_path" \
    | grep -qE '"attributionTrailers"[[:space:]]*:[[:space:]]*false'; then
    return 1
  fi
  return 0
}

# Resolve the agent kind for a given SessionKind raw value, mirroring
# AppConfig.agentKind(for:) in Packages/CrowCore — agentsByKind[<kind>]
# wins, falling back to defaultAgentKind, falling back to claude-code.
# The crow-workspace skill is for `work` (coding) sessions.
read_agent_kind_from_config() {
  local session_kind="${1:-work}"
  local cfg="$DEV_ROOT/.claude/config.json"
  [[ -f "$cfg" ]] || { echo "claude-code"; return; }

  local flat
  flat=$(tr -d '\n' < "$cfg")

  # agentsByKind["<kind>"]: find the agentsByKind object body, then the key.
  local override
  override=$(printf '%s' "$flat" \
    | grep -oE "\"agentsByKind\"[[:space:]]*:[[:space:]]*\{[^}]*\}" \
    | grep -oE "\"$session_kind\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  if [[ -n "$override" ]]; then echo "$override"; return; fi

  # Fall back to defaultAgentKind.
  local def
  def=$(printf '%s' "$flat" \
    | grep -oE "\"defaultAgentKind\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  echo "${def:-claude-code}"
}

# Map an AGENT_KIND raw value to its human-readable display name. Mirrors
# CrowAttribution.knownDisplayNames in Packages/CrowCore. Used by
# write_settings_local to bake the resolved name into `attribution.commit`
# as a literal string — Claude Code's settings.local.json is JSON, not a
# shell context, so shell parameter expansion never fires there (#447).
agent_display_name() {
  case "${1:-claude-code}" in
    claude-code) echo "Claude Code" ;;
    cursor)      echo "Cursor" ;;
    codex)       echo "OpenAI Codex" ;;
    *)           echo "Claude Code" ;;
  esac
}

# Resolve this workspace's AI gateway from {devRoot}/.claude/config.json (CROW-402).
# Populates WS_BASE_URL / WS_CUSTOM_HEADERS and sets WS_HAS_GATEWAY=true when a
# gateway is configured. Header values prefixed `op://` are resolved via the
# 1Password CLI (`op read`); any other value is used literally. Idempotent — the
# expensive `op read` only runs once. Never logs the resolved header values.
resolve_gateway_env() {
  [[ "$WS_GATEWAY_RESOLVED" == true ]] && return 0
  WS_GATEWAY_RESOLVED=true

  local config_path="$DEV_ROOT/.claude/config.json"
  [[ -f "$config_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || { log "jq not found; skipping gateway resolution"; return 0; }

  local gateway
  gateway=$(jq -c --arg name "$WORKSPACE" \
    '.workspaces[]? | select(.name == $name) | .gateway // empty' \
    "$config_path" 2>/dev/null) || return 0
  [[ -n "$gateway" && "$gateway" != "null" ]] || return 0

  local base_url
  base_url=$(jq -r '.baseURL // ""' <<< "$gateway")
  [[ -n "$base_url" ]] || return 0

  # Resolve each header value and join as newline-separated "Name: Value".
  local headers="" name value resolved
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    value=$(jq -r --arg k "$name" '.customHeaders[$k]' <<< "$gateway")
    if [[ "$value" == op://* ]]; then
      if ! resolved=$(op read "$value" 2>/dev/null); then
        log "Gateway: failed to resolve secret reference for header '$name' (op read failed); dropping it"
        continue
      fi
      value="$resolved"
    fi
    [[ -n "$headers" ]] && headers+=$'\n'
    headers+="$name: $value"
  done < <(jq -r '.customHeaders | keys[]' <<< "$gateway" 2>/dev/null)

  WS_BASE_URL="$base_url"
  WS_CUSTOM_HEADERS="$headers"
  WS_HAS_GATEWAY=true
  log "Gateway: routing this workspace through $base_url"
}

# Populate TASK_PROVIDER from this workspace's config.json entry (CROW-522).
# Mirrors AppConfig.derivedTaskProvider: the explicit `taskProvider` when set,
# otherwise the code `provider`. Falls back to $PROVIDER when config/jq is
# unavailable. Idempotent.
resolve_task_provider() {
  [[ "$TASK_PROVIDER_RESOLVED" == true ]] && return 0
  TASK_PROVIDER_RESOLVED=true
  TASK_PROVIDER="$PROVIDER"

  local config_path="$DEV_ROOT/.claude/config.json"
  [[ -f "$config_path" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local tp
  tp=$(jq -r --arg name "$WORKSPACE" \
    '.workspaces[]? | select(.name == $name) | (.taskProvider // .provider) // empty' \
    "$config_path" 2>/dev/null) || return 0
  [[ -n "$tp" && "$tp" != "null" ]] && TASK_PROVIDER="$tp"
}

# Build the shell prefix that applies (or clears) the gateway env vars on the
# `claude` launch line — mirrors ClaudeLaunchArgs.gatewayEnvPrefix in Swift.
# Gateway absent → `unset … && ` so a no-gateway workspace doesn't inherit a
# sibling's or ~/.zshrc's gateway. Single header → `ANTHROPIC_BASE_URL='…'
# ANTHROPIC_CUSTOM_HEADERS='…' `. Multi-header → the header value has an embedded
# newline and can't go on the line (a pasted newline would submit the command
# early), so settings.local.json carries it; we still `unset ANTHROPIC_CUSTOM_HEADERS`
# so the gateway's baseURL is never paired with a stale ~/.zshrc-inherited header.
gateway_launch_prefix() {
  if [[ "$WS_HAS_GATEWAY" != true ]]; then
    printf 'unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && '
    return 0
  fi
  if [[ "$WS_CUSTOM_HEADERS" == *$'\n'* ]]; then
    printf 'unset ANTHROPIC_CUSTOM_HEADERS && ANTHROPIC_BASE_URL=%s ' "$(posix_quote "$WS_BASE_URL")"
    return 0
  fi
  printf 'ANTHROPIC_BASE_URL=%s ANTHROPIC_CUSTOM_HEADERS=%s ' \
    "$(posix_quote "$WS_BASE_URL")" "$(posix_quote "$WS_CUSTOM_HEADERS")"
}

die() {
  local step="$1" msg="$2"
  local partial=""
  if [[ -n "$SESSION_ID" ]]; then
    partial=", \"partial\": {\"session_id\": \"$SESSION_ID\"}"
  fi
  printf '{"status":"error","step":"%s","message":"%s"%s}\n' \
    "$step" \
    "$(echo "$msg" | sed 's/"/\\"/g' | tr '\n' ' ')" \
    "$partial"
  exit 1
}

# ─── Argument Parsing ────────────────────────────────────────────────────────

usage() {
  cat >&2 <<'EOF'
Usage: setup.sh [OPTIONS]

Required:
  --dev-root <path>          Development root directory
  --workspace <name>         Workspace name (e.g. RadiusMethod)
  --repo <name>              Repository name
  --repo-path <path>         Main repo clone path
  --slug <slug>              LLM-generated slug (e.g. 104-global-terminals)
  --branch <branch>          Target branch name
  --worktree-path <path>     Target worktree path
  --session-name <name>      Crow session name
  --provider <github|gitlab> Git provider
  --cli <gh|glab>            CLI tool

Optional:
  --host <hostname>          GitLab host (required for gitlab)
  --ticket-url <url>         Issue/ticket URL
  --ticket-title <title>     Ticket title
  --ticket-number <number>   Ticket number
  --pr-number <number>       Existing PR number
  --pr-url <url>             Existing PR URL
  --pr-branch <branch>       Existing PR branch name
  --prompt-content <path>    Path to LLM-written prompt file
  --agent-kind <kind>        Coding agent: claude-code | cursor | codex.
                             Defaults to agentsByKind["work"] then
                             defaultAgentKind from {devRoot}/.claude/config.json
                             (final fallback: claude-code).
  --agent-binary <path>      Full path to the selected agent's binary.
  --claude-binary <path>     [deprecated alias] Same as --agent-binary; only
                             honored when the resolved agent is claude-code.
  --session-id <uuid>        Existing session ID (for secondary repos)
  --base-branch <branch>     Default base branch (auto-detected from origin/HEAD if omitted)
  --primary                  Mark worktree as primary
  --skip-launch              Skip agent launch
  --skip-assign              Skip auto-assign
  --skip-project-status      Skip project status mutation
  --help                     Show this help
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dev-root)          DEV_ROOT="$2"; shift 2 ;;
      --workspace)         WORKSPACE="$2"; shift 2 ;;
      --repo)              REPO="$2"; shift 2 ;;
      --repo-path)         REPO_PATH="$2"; shift 2 ;;
      --slug)              SLUG="$2"; shift 2 ;;
      --branch)            BRANCH="$2"; shift 2 ;;
      --worktree-path)     WORKTREE_PATH="$2"; shift 2 ;;
      --session-name)      SESSION_NAME="$2"; shift 2 ;;
      --provider)          PROVIDER="$2"; shift 2 ;;
      --cli)               CLI_TOOL="$2"; shift 2 ;;
      --host)              HOST="$2"; shift 2 ;;
      --ticket-url)        TICKET_URL="$2"; shift 2 ;;
      --ticket-title)      TICKET_TITLE="$2"; shift 2 ;;
      --ticket-number)     TICKET_NUMBER="$2"; shift 2 ;;
      --pr-number)         PR_NUMBER="$2"; shift 2 ;;
      --pr-url)            PR_URL="$2"; shift 2 ;;
      --pr-branch)         PR_BRANCH="$2"; shift 2 ;;
      --prompt-content)    PROMPT_CONTENT="$2"; shift 2 ;;
      --agent-kind)        AGENT_KIND="$2"; shift 2 ;;
      --agent-binary)      AGENT_BINARY="$2"; shift 2 ;;
      --claude-binary)     CLAUDE_BINARY="$2"; shift 2 ;;
      --session-id)        SESSION_ID="$2"; shift 2 ;;
      --base-branch)       BASE_BRANCH="$2"; shift 2 ;;
      --primary)           PRIMARY=true; shift ;;
      --skip-launch)       SKIP_LAUNCH=true; shift ;;
      --skip-assign)       SKIP_ASSIGN=true; shift ;;
      --skip-project-status) SKIP_PROJECT_STATUS=true; shift ;;
      --help)              usage ;;
      *)                   die "parse_args" "Unknown argument: $1" ;;
    esac
  done

  # Validate required args
  local missing=()
  [[ -z "$DEV_ROOT" ]]      && missing+=("--dev-root")
  [[ -z "$WORKSPACE" ]]     && missing+=("--workspace")
  [[ -z "$REPO" ]]          && missing+=("--repo")
  [[ -z "$REPO_PATH" ]]     && missing+=("--repo-path")
  [[ -z "$SLUG" ]]          && missing+=("--slug")
  [[ -z "$BRANCH" ]]        && missing+=("--branch")
  [[ -z "$WORKTREE_PATH" ]] && missing+=("--worktree-path")
  [[ -z "$SESSION_NAME" ]]  && missing+=("--session-name")
  [[ -z "$PROVIDER" ]]      && missing+=("--provider")
  [[ -z "$CLI_TOOL" ]]      && missing+=("--cli")

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "parse_args" "Missing required arguments: ${missing[*]}"
  fi

  # Validate --agent-kind early so bad values fail fast rather than at launch.
  if [[ -n "$AGENT_KIND" ]]; then
    case "$AGENT_KIND" in
      claude-code|cursor|codex) ;;
      *) die "parse_args" "Unknown --agent-kind: $AGENT_KIND (expected claude-code | cursor | codex)" ;;
    esac
  fi
}

# ─── Preflight ───────────────────────────────────────────────────────────────

preflight() {
  if ! command -v crow >/dev/null 2>&1; then
    die "preflight" "crow binary not found in PATH"
  fi
  if ! command -v git >/dev/null 2>&1; then
    die "preflight" "git binary not found in PATH"
  fi
}

# ─── Git Worktree ────────────────────────────────────────────────────────────

# Resolve BASE_BRANCH: explicit --base-branch flag wins, otherwise probe
# origin/HEAD locally (set by `git clone` for most repos), otherwise ask the
# remote, otherwise warn loudly and fall back to "main".
resolve_base_branch() {
  if [[ -n "$BASE_BRANCH" ]]; then
    log "Using base branch from --base-branch: $BASE_BRANCH"
    return
  fi
  local detected
  detected=$(git -C "$REPO_PATH" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || true
  detected="${detected#origin/}"
  if [[ -z "$detected" ]]; then
    detected=$(git -C "$REPO_PATH" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }') || true
  fi
  if [[ -n "$detected" ]]; then
    BASE_BRANCH="$detected"
    log "Auto-detected base branch from origin/HEAD: $BASE_BRANCH"
  else
    BASE_BRANCH="main"
    log "WARNING: could not detect default branch for $REPO_PATH; falling back to 'main'"
  fi
}

setup_worktree() {
  log "Fetching origin..."
  if ! git -C "$REPO_PATH" fetch origin >&2 2>&1; then
    die "git_fetch" "git fetch origin failed"
  fi

  resolve_base_branch

  # Determine which branch and tracking mode to use
  local use_branch="$BRANCH"
  local track_flag="--no-track"
  local base_ref="origin/$BASE_BRANCH"

  if [[ -n "$PR_BRANCH" ]]; then
    # PR branch: track the remote PR branch
    use_branch="$PR_BRANCH"
    track_flag="--track"
    base_ref="origin/$PR_BRANCH"
    log "Using PR branch: $PR_BRANCH"
  else
    # Check if branch already exists on remote
    local remote_check
    remote_check=$(git -C "$REPO_PATH" ls-remote --heads origin "$BRANCH" 2>/dev/null) || true
    if [[ -n "$remote_check" ]]; then
      track_flag="--track"
      base_ref="origin/$BRANCH"
      log "Branch $BRANCH exists on remote, will track"
    else
      log "Creating new branch $BRANCH from origin/$BASE_BRANCH"
    fi
  fi

  log "Creating worktree at $WORKTREE_PATH..."
  local wt_err
  if ! wt_err=$(git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" \
       -b "$use_branch" \
       $track_flag \
       "$base_ref" 2>&1); then
    # Branch or worktree might already exist — clean up and retry
    log "Worktree add failed, attempting cleanup..."
    log "  Error was: $wt_err"
    # Remove any existing worktree at this path first
    git -C "$REPO_PATH" worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
    # Prune stale worktree references
    git -C "$REPO_PATH" worktree prune 2>/dev/null || true
    # Now delete the branch (safe after worktree removal)
    git -C "$REPO_PATH" branch -D "$use_branch" 2>/dev/null || true

    log "Retrying worktree creation..."
    if ! wt_err=$(git -C "$REPO_PATH" worktree add "$WORKTREE_PATH" \
         -b "$use_branch" \
         $track_flag \
         "$base_ref" 2>&1); then
      die "git_worktree_add" "Failed to create worktree at $WORKTREE_PATH: $wt_err"
    fi
  fi

  log "Worktree created successfully"
}

# ─── Crow Session ────────────────────────────────────────────────────────────

create_session() {
  # Step 1: Create session (or use existing)
  if [[ -z "$SESSION_ID" ]]; then
    log "Creating session: $SESSION_NAME"
    local result
    if ! result=$(crow new-session --name "$SESSION_NAME" 2>&1); then
      die "new_session" "crow new-session failed: $result"
    fi
    SESSION_ID=$(json_val "session_id" <<< "$result")
    if [[ -z "$SESSION_ID" ]]; then
      die "new_session" "Could not parse session_id from: $result"
    fi
    log "Session created: $SESSION_ID"
  else
    log "Using existing session: $SESSION_ID"
  fi

  # Step 2: Set ticket metadata (if URL provided). The number is optional —
  # Jira keys (e.g. MAXX-6846) have no standalone numeric id, so gate on the
  # URL and add --number only when it's actually numeric. (crow set-ticket
  # accepts --url/--title without --number; a non-numeric --number would make
  # ArgumentParser reject the whole call and drop url+title too.)
  if [[ -n "$TICKET_URL" ]]; then
    log "Setting ticket metadata..."
    local ticket_args=(crow set-ticket --session "$SESSION_ID" --url "$TICKET_URL")
    [[ -n "$TICKET_TITLE" ]] && ticket_args+=(--title "$TICKET_TITLE")
    [[ "$TICKET_NUMBER" =~ ^[0-9]+$ ]] && ticket_args+=(--number "$TICKET_NUMBER")
    "${ticket_args[@]}" >/dev/null 2>&1 \
      || log "Warning: set-ticket failed (may already be set)"
  fi

  # Step 3: Register worktree
  log "Registering worktree..."
  local wt_args=(crow add-worktree --session "$SESSION_ID"
    --repo "$REPO"
    --repo-path "$REPO_PATH"
    --path "$WORKTREE_PATH"
    --branch "$BRANCH")
  [[ "$PRIMARY" == "true" ]] && wt_args+=(--primary)
  local wt_result
  if ! wt_result=$("${wt_args[@]}" 2>&1); then
    die "add_worktree" "crow add-worktree failed: $wt_result"
  fi

  # Step 4: Add ticket link (if URL provided)
  if [[ -n "$TICKET_URL" ]]; then
    log "Adding ticket link..."
    crow add-link --session "$SESSION_ID" \
      --label "Issue" \
      --url "$TICKET_URL" \
      --type ticket >/dev/null 2>&1 \
      || log "Warning: add-link (ticket) failed"
  fi

  # Step 4a: Add PR link (if PR detected)
  if [[ -n "$PR_URL" && -n "$PR_NUMBER" ]]; then
    log "Adding PR link..."
    crow add-link --session "$SESSION_ID" \
      --label "PR #$PR_NUMBER" \
      --url "$PR_URL" \
      --type pr >/dev/null 2>&1 \
      || log "Warning: add-link (PR) failed"
  fi
}

# ─── Per-Worktree Settings (attribution trailer) ─────────────────────────────

# Write a per-worktree .claude/settings.local.json that overrides Claude Code's
# attribution.commit so commits include a `Crow-Session: <uuid>` trailer
# alongside the standard `Co-Authored-By: Claude` line, and — when this workspace
# has an AI gateway (CROW-402) — an `env` block so manual `claude` re-runs in the
# terminal inherit the gateway. Runs for every worktree (primary and secondary)
# regardless of --skip-launch, so any worktree the user later opens with Claude
# Code picks up both overrides.
write_settings_local() {
  # Resolve the gateway first so its block is written even when attribution
  # trailers are disabled.
  resolve_gateway_env

  local want_attribution=false
  if is_attribution_trailers_enabled && [[ -n "$SESSION_ID" ]]; then
    want_attribution=true
  elif [[ -z "$SESSION_ID" ]]; then
    log "Warning: SESSION_ID not set, skipping attribution trailer"
  else
    log "Attribution trailers disabled via config"
  fi

  if [[ "$want_attribution" != true && "$WS_HAS_GATEWAY" != true ]]; then
    log "No attribution trailer or gateway to write; skipping settings.local.json"
    return
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "jq not found; skipping settings.local.json"
    return
  fi

  local settings_dir="$WORKTREE_PATH/.claude"
  local settings_path="$settings_dir/settings.local.json"
  mkdir -p "$settings_dir"

  # Resolve the agent display name so it lands in the JSON as a literal string.
  # Claude Code's settings.local.json is parsed as JSON, not by a shell, so any
  # ${VAR:-default} expression would survive verbatim and leak into commits
  # (#447). Fall back to read_agent_kind_from_config when --agent-kind wasn't
  # provided, matching launch_agent's resolution order.
  local resolved_kind="$AGENT_KIND"
  if [[ -z "$resolved_kind" ]]; then
    resolved_kind=$(read_agent_kind_from_config "work")
  fi
  local display_name
  display_name=$(agent_display_name "$resolved_kind")

  # Merge into existing settings (preserving hooks etc.) via jq, which handles
  # JSON escaping of the newlines in the commit trailer and the header values.
  local base="{}"
  [[ -f "$settings_path" ]] && base=$(cat "$settings_path")

  local commit_trailer="🐦‍⬛ Generated with $display_name, orchestrated by Crow

Co-Authored-By: Claude <noreply@anthropic.com>
Crow-Session: $SESSION_ID"

  local merged
  if ! merged=$(jq \
    --argjson want_attr "$want_attribution" \
    --arg commit "$commit_trailer" \
    --argjson want_gw "$WS_HAS_GATEWAY" \
    --arg base_url "$WS_BASE_URL" \
    --arg headers "$WS_CUSTOM_HEADERS" \
    '(if $want_attr then .attribution.commit = $commit else . end)
     | (if $want_gw then .env.ANTHROPIC_BASE_URL = $base_url
                       | .env.ANTHROPIC_CUSTOM_HEADERS = $headers else . end)' \
    <<< "$base"); then
    die "settings_local" "jq failed to build settings.local.json"
  fi
  printf '%s\n' "$merged" > "$settings_path"
  # The env block can carry a resolved bearer token, so restrict the file to
  # owner-only — matching ConfigStore's 0600 on config.json.
  chmod 600 "$settings_path" 2>/dev/null || true

  if [[ "$WS_HAS_GATEWAY" == true ]]; then
    log "Wrote settings.local.json (attribution + gateway env) to $settings_path (agent: $display_name)"
  else
    log "Wrote attribution settings to $settings_path (agent: $display_name)"
  fi

  # Belt-and-suspenders: add the file to the per-worktree git exclude so it
  # is never accidentally committed even if the repo's .gitignore does not
  # already cover .claude/settings.local.json. For worktrees, this lives at
  # .git/worktrees/<name>/info/exclude — `git rev-parse --git-path` resolves it.
  local exclude_file
  exclude_file="$(git -C "$WORKTREE_PATH" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [[ -n "$exclude_file" ]] || return 0
  mkdir -p "$(dirname "$exclude_file")"
  touch "$exclude_file"
  if ! grep -qxF '.claude/settings.local.json' "$exclude_file" 2>/dev/null; then
    printf '\n# Added by crow setup.sh\n.claude/settings.local.json\n' >> "$exclude_file"
  fi
}

# ─── Per-Worktree prepare-commit-msg Hook (CROW-518) ─────────────────────────

# Install a per-worktree `prepare-commit-msg` hook that idempotently appends
# `Crow-Session: <uuid>` and `Co-Authored-By: Claude` trailers to commit
# messages when missing. Closes the bypass where Claude Code's
# `attribution.commit` setting only fires for its own commit flow — hand-rolled
# `git commit -m`/heredoc commits skip it and produce trailerless commits, which
# defeats the `crow:merge` auto-merge gate (CROW-518).
#
# Worktree-scoped: enables `extensions.worktreeConfig` on the main repo
# (idempotent, one-time), sets per-worktree `core.hooksPath` to this worktree's
# gitdir hooks dir, and writes the session id to a `CROW_SESSION_ID` file under
# the same gitdir. Sibling worktrees of the same repo carry their own session
# id (or none) and are unaffected.
install_commit_hook() {
  if ! is_attribution_trailers_enabled; then
    log "Attribution trailers disabled via config; removing any prepare-commit-msg hook"
    remove_commit_hook
    return
  fi

  if [[ -z "$SESSION_ID" ]]; then
    log "Warning: SESSION_ID not set, skipping prepare-commit-msg hook"
    return
  fi

  if ! command -v git >/dev/null 2>&1; then
    log "git not found; skipping prepare-commit-msg hook"
    return
  fi

  local worktree_gitdir hooks_dir session_id_file
  worktree_gitdir=$(git -C "$WORKTREE_PATH" rev-parse --git-dir 2>/dev/null) || {
    log "Warning: could not resolve worktree gitdir; skipping hook install"
    return
  }
  # `git rev-parse --git-path hooks` resolves to $GIT_COMMON_DIR/hooks (shared
  # across worktrees by default), which would pollute every sibling worktree.
  # Compose the per-worktree path off --git-dir instead.
  hooks_dir="$worktree_gitdir/hooks"
  session_id_file=$(git -C "$WORKTREE_PATH" rev-parse --git-path CROW_SESSION_ID 2>/dev/null) || {
    log "Warning: could not resolve CROW_SESSION_ID path; skipping hook install"
    return
  }

  # Enable per-worktree config on the main repo (idempotent). Required before
  # `git config --worktree` writes to a per-worktree `config.worktree` file
  # instead of falling back to the shared local config.
  git -C "$WORKTREE_PATH" config --local extensions.worktreeConfig true \
    >/dev/null 2>&1 || log "Warning: failed to enable extensions.worktreeConfig"

  # Point this worktree at its own hooks dir using an absolute path so the
  # resolution does not depend on the agent's cwd at commit time.
  git -C "$WORKTREE_PATH" config --worktree core.hooksPath "$hooks_dir" \
    >/dev/null 2>&1 || log "Warning: failed to set per-worktree core.hooksPath"

  mkdir -p "$hooks_dir"
  printf '%s\n' "$SESSION_ID" > "$session_id_file"

  local hook_path="$hooks_dir/prepare-commit-msg"
  # The hook body is a verbatim heredoc — defined here so it lives in one
  # place. Resources/crow-workspace-setup.sh.template carries a byte-identical
  # copy; AttributionSkillTests guards against drift.
  cat > "$hook_path" <<'CROW_HOOK_EOF'
#!/bin/sh
# Crow prepare-commit-msg hook (CROW-518).
# Idempotently appends `Crow-Session: <uuid>` and `Co-Authored-By: Claude`
# trailers to commit messages when missing. Resolves the session id from a
# CROW_SESSION_ID file in this worktree's gitdir, so sibling worktrees that
# don't carry one are no-ops. Never blocks a commit.
set -u

COMMIT_MSG_FILE="${1:-}"
COMMIT_SOURCE="${2:-}"

[ -n "$COMMIT_MSG_FILE" ] && [ -f "$COMMIT_MSG_FILE" ] || exit 0

# Merge / squash messages get crafted server-side later — leave them alone.
case "$COMMIT_SOURCE" in
  merge|squash) exit 0 ;;
esac

SESSION_ID_FILE="$(git rev-parse --git-path CROW_SESSION_ID 2>/dev/null)" || exit 0
[ -f "$SESSION_ID_FILE" ] || exit 0
SESSION_ID="$(tr -d '[:space:]' < "$SESSION_ID_FILE" 2>/dev/null)"
[ -n "$SESSION_ID" ] || exit 0

# Skip when the message body has no non-comment content (`git commit -m ""`
# or a `# …` template-only file). Without this, an empty commit attempt
# would grow a body and the resulting "git commit -m ''" no-op-fails path
# would surface a confusing-looking message.
if ! grep -vE '^[[:space:]]*#' "$COMMIT_MSG_FILE" 2>/dev/null \
   | grep -q '[^[:space:]]'; then
  exit 0
fi

ADD_CROW=1
# Skip the Crow-Session trailer when ANY Crow-Session line already exists —
# preserves a user-typed trailer even if its UUID differs from ours; the
# crow:merge gate only needs at least one matching known session UUID.
if grep -qE '^Crow-Session:[[:space:]]' "$COMMIT_MSG_FILE" 2>/dev/null; then
  ADD_CROW=0
fi

ADD_COAUTH=1
if grep -qE '^Co-Authored-By:[[:space:]]*Claude' "$COMMIT_MSG_FILE" 2>/dev/null; then
  ADD_COAUTH=0
fi

if [ "$ADD_CROW" -eq 0 ] && [ "$ADD_COAUTH" -eq 0 ]; then
  exit 0
fi

# Apply remaining additions in a single interpret-trailers call so the
# resulting block is blank-line-separated from the body and line-anchored
# (matches IssueTracker.crowSessionTrailerPattern with .anchorsMatchLines).
if [ "$ADD_CROW" -eq 1 ] && [ "$ADD_COAUTH" -eq 1 ]; then
  git interpret-trailers --in-place \
    --trailer "Crow-Session: $SESSION_ID" \
    --trailer "Co-Authored-By: Claude <noreply@anthropic.com>" \
    "$COMMIT_MSG_FILE" 2>/dev/null || true
elif [ "$ADD_CROW" -eq 1 ]; then
  git interpret-trailers --in-place \
    --trailer "Crow-Session: $SESSION_ID" \
    "$COMMIT_MSG_FILE" 2>/dev/null || true
elif [ "$ADD_COAUTH" -eq 1 ]; then
  git interpret-trailers --in-place \
    --trailer "Co-Authored-By: Claude <noreply@anthropic.com>" \
    "$COMMIT_MSG_FILE" 2>/dev/null || true
fi

exit 0
CROW_HOOK_EOF
  chmod +x "$hook_path" 2>/dev/null || true
  log "Installed prepare-commit-msg hook at $hook_path"
}

# Remove a previously installed prepare-commit-msg hook and its companion
# CROW_SESSION_ID file. Called when attributionTrailers flips to false so a
# stale install does not keep adding trailers. Leaves
# `extensions.worktreeConfig` and `core.hooksPath` alone — both are harmless
# when the hook file is gone.
remove_commit_hook() {
  if ! command -v git >/dev/null 2>&1; then
    return
  fi
  local worktree_gitdir hooks_dir session_id_file
  worktree_gitdir=$(git -C "$WORKTREE_PATH" rev-parse --git-dir 2>/dev/null) || return
  hooks_dir="$worktree_gitdir/hooks"
  session_id_file=$(git -C "$WORKTREE_PATH" rev-parse --git-path CROW_SESSION_ID 2>/dev/null) || return
  rm -f "$hooks_dir/prepare-commit-msg" "$session_id_file" 2>/dev/null || true
}

# ─── GitHub Housekeeping (best-effort) ───────────────────────────────────────

github_ops() {
  if [[ "$PROVIDER" != "github" ]]; then
    return
  fi
  # CROW-522: a GitHub-code workspace can track its tasks in Jira. In that case
  # $TICKET_URL is a Jira browse URL, not a GitHub issue — running `gh issue
  # edit`/project-status against it just logs `auto-assign failed`. Skip GitHub
  # issue housekeeping entirely when the task provider is Jira: assignment
  # happens via the jira MCP in-session, and the Jira In-Progress transition
  # happens in jira_ops() (CROW-529), not here.
  resolve_task_provider
  if [[ "$TASK_PROVIDER" == "jira" ]]; then
    log "Task provider is Jira; skipping GitHub issue auto-assign/project-status"
    return
  fi

  # Auto-assign
  if [[ "$SKIP_ASSIGN" != "true" && -n "$TICKET_URL" ]]; then
    log "Auto-assigning issue..."
    gh issue edit "$TICKET_URL" --add-assignee @me 2>/dev/null || log "Warning: auto-assign failed"
  fi

  # Project status mutation
  if [[ "$SKIP_PROJECT_STATUS" != "true" && -n "$TICKET_URL" && -n "$TICKET_NUMBER" ]]; then
    log "Setting project status to In progress..."
    set_project_status || log "Warning: project status update failed"
  fi
}

# CROW-529: session-start status transition for Jira work items. setup.sh owns
# the GitHub Projects-v2 mutation (set_project_status) but there was no Jira
# equivalent, so a Jira-tasked session never left Backlog. Delegate to the Crow
# app — it resolves the mapped In-Progress status (jiraStatusMap, #523), fetches
# the issue's available transitions, and degrades gracefully when unavailable.
# Runs for any code provider (a Jira-tasked workspace may be GitHub- or
# GitLab-coded), so it lives outside github_ops. Best-effort, never fatal.
jira_ops() {
  resolve_task_provider
  [[ "$TASK_PROVIDER" == "jira" ]] || return 0
  [[ "$SKIP_PROJECT_STATUS" != "true" ]] || return 0
  [[ -n "$TICKET_URL" && -n "$SESSION_ID" ]] || return 0
  log "Transitioning Jira work item to In Progress..."
  crow transition-ticket --session "$SESSION_ID" --to inProgress \
    || log "Warning: Jira status transition failed (non-fatal)"
}

set_project_status() {
  # Extract owner/repo from ticket URL
  local owner_repo
  owner_repo=$(echo "$TICKET_URL" | sed -n 's|https://github.com/\([^/]*/[^/]*\)/.*|\1|p')
  if [[ -z "$owner_repo" ]]; then
    return 1
  fi

  # Step 1: Get project item ID and project ID
  local item_query
  item_query=$(cat <<GRAPHQL
query {
  repository(owner: "${owner_repo%%/*}", name: "${owner_repo##*/}") {
    issue(number: $TICKET_NUMBER) {
      projectItems(first: 1) {
        nodes {
          id
          project { id }
        }
      }
    }
  }
}
GRAPHQL
  )

  local item_result
  item_result=$(gh api graphql -f query="$item_query" 2>/dev/null) || return 1
  local item_id project_id
  item_id=$(echo "$item_result" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  project_id=$(echo "$item_result" | grep -o '"id":"[^"]*"' | tail -1 | cut -d'"' -f4)

  if [[ -z "$item_id" || -z "$project_id" || "$item_id" == "$project_id" ]]; then
    log "Issue not on any project, skipping status update"
    return 0
  fi

  # Step 2: Get Status field ID and "In progress" option ID
  local field_query
  field_query=$(cat <<GRAPHQL
query {
  node(id: "$project_id") {
    ... on ProjectV2 {
      field(name: "Status") {
        ... on ProjectV2SingleSelectField {
          id
          options { id name }
        }
      }
    }
  }
}
GRAPHQL
  )

  local field_result
  field_result=$(gh api graphql -f query="$field_query" 2>/dev/null) || return 1

  local field_id option_id
  field_id=$(echo "$field_result" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

  # Extract "In progress" option — look for the option name then grab its id
  option_id=$(echo "$field_result" | tr ',' '\n' | grep -B1 '"In [Pp]rogress"' | grep -o '"id":"[^"]*"' | cut -d'"' -f4 | head -1)

  if [[ -z "$field_id" || -z "$option_id" ]]; then
    log "Could not find Status field or In progress option"
    return 1
  fi

  # Step 3: Set the value
  local mutation
  mutation=$(cat <<GRAPHQL
mutation {
  updateProjectV2ItemFieldValue(input: {
    projectId: "$project_id"
    itemId: "$item_id"
    fieldId: "$field_id"
    value: { singleSelectOptionId: "$option_id" }
  }) {
    projectV2Item { id }
  }
}
GRAPHQL
  )

  gh api graphql -f query="$mutation" >/dev/null 2>&1 || return 1
  log "Project status set to In progress"
}

# ─── Prompt File ─────────────────────────────────────────────────────────────

write_prompt() {
  if [[ -z "$PROMPT_CONTENT" ]]; then
    log "No prompt content path provided, skipping prompt write"
    return
  fi

  if [[ ! -f "$PROMPT_CONTENT" ]]; then
    die "write_prompt" "Prompt content file not found: $PROMPT_CONTENT"
  fi

  local prompts_dir="$DEV_ROOT/.claude/prompts"
  mkdir -p "$prompts_dir"

  local prompt_dest="$prompts_dir/crow-prompt-$SESSION_NAME.md"

  # If prompt content path differs from destination, copy it
  if [[ "$PROMPT_CONTENT" != "$prompt_dest" ]]; then
    cp "$PROMPT_CONTENT" "$prompt_dest"
    log "Prompt copied to $prompt_dest"
  else
    log "Prompt already at $prompt_dest"
  fi
}

# ─── Launch Agent ───────────────────────────────────────────────────────────
#
# Dispatcher + per-agent launchers. The dispatcher resolves the agent kind
# (--agent-kind flag, then config.json, then claude-code default), invokes the
# matching launch_<kind> sub-launcher to build the --command string and create
# the terminal, then polls readiness centrally. Each sub-launcher mirrors the
# corresponding Swift `CodingAgent.autoLaunchCommand` in Packages/Crow{Claude,
# Cursor,Codex} so the skill and the in-app launch paths stay in agreement.

# Search a list of candidate paths and PATH for the first executable matching
# $token (or full path). Echoes the resolved path, or empty on failure.
# Usage: resolve_binary <token> <candidate1> [candidate2 ...]
resolve_binary() {
  local token="$1"; shift
  local p
  for p in "$@"; do
    [[ -n "$p" && -x "$p" ]] && { echo "$p"; return 0; }
  done
  p=$(command -v "$token" 2>/dev/null) || true
  [[ -n "$p" ]] && { echo "$p"; return 0; }
  return 1
}

launch_claude_code() {
  local prompt_path="$1"
  local override_bin="$2"   # from --agent-binary or legacy --claude-binary
  local bin
  if [[ -n "$override_bin" ]]; then
    bin="$override_bin"
  else
    bin=$(resolve_binary "claude" \
      "$HOME/.local/bin/claude" \
      "/usr/local/bin/claude" \
      "/opt/homebrew/bin/claude") || \
      die "launch_agent" "claude binary not found at PATH or known locations; provide --agent-binary"
  fi
  log "Resolved claude-code binary: $bin"

  # Build the agent launch command and hand it to crow at terminal-creation
  # time via --command. Crow holds the command and pastes it only once the
  # shell's line editor is live (the .shellReady sentinel), which is the
  # race-free replacement for the old `sleep 3` + `crow send` handshake that
  # intermittently dropped the launch into a not-yet-ready shell, leaving a
  # bare zsh with no agent (#408).
  #
  # The prompt stays in its file — `"$(cat $prompt_path)"` is expanded by the
  # TARGET shell at paste time, so the command sent over the socket is small
  # (no ARG_MAX / payload concern).
  local rc_args=""
  if is_remote_control_enabled; then
    # Keep building --rc here: crow's resolveClaudeInCommand only injects
    # remote-control flags for a bare `claude …` command, NOT a
    # `cd … && claude …` form, so setup.sh remains the source of truth.
    rc_args=" --rc --name $(posix_quote "$SESSION_NAME")"
    log "Remote control enabled — launching with --rc --name '$SESSION_NAME'"
  fi
  # CROW-402: prefix the launch line with the workspace gateway env (or `unset`
  # when there's none) so the deferred launch overrides any global ~/.zshrc
  # export. resolve_gateway_env is idempotent (it already ran in
  # write_settings_local), so this reuses its result without a second `op read`.
  # The assignments are intentionally not logged (the header value is a bearer
  # token). Placed immediately before $bin so the command-prefix
  # assignments bind to claude.
  resolve_gateway_env
  local gw_prefix
  gw_prefix=$(gateway_launch_prefix)
  local launch_cmd="cd $WORKTREE_PATH && ${gw_prefix}$bin --permission-mode plan$rc_args \"\$(cat $prompt_path)\""
  create_agent_terminal "Claude Code" "$launch_cmd"
}

launch_cursor() {
  local prompt_path="$1"
  local override_bin="$2"
  local bin
  if [[ -n "$override_bin" ]]; then
    bin="$override_bin"
  else
    # Cursor's CLI binary is named `agent`, not `cursor`. Candidate paths
    # mirror CursorAgent.cursorBinaryCandidates in CrowCursor.
    bin=$(resolve_binary "agent" \
      "/opt/homebrew/bin/agent" \
      "/usr/local/bin/agent" \
      "$HOME/.local/bin/agent") || \
      die "launch_agent" "cursor binary not found at PATH or known locations; provide --agent-binary"
  fi
  log "Resolved cursor binary: $bin"
  # Cursor: no --permission-mode, no --rc; pass the prompt as argv.
  # This intentionally uses CursorAgent's .job/.review first-launch argv
  # form (NOT the .work bare-`agent` form) so the unattended skill flow
  # feeds the prompt at launch — same divergence-from-Swift-.work
  # rationale that launch_claude_code uses for its prompt-argv form.
  local launch_cmd="cd $WORKTREE_PATH && $bin \"\$(cat $prompt_path)\""
  create_agent_terminal "Cursor" "$launch_cmd"
}

launch_codex() {
  local prompt_path="$1"
  local override_bin="$2"
  local bin
  if [[ -n "$override_bin" ]]; then
    bin="$override_bin"
  else
    bin=$(resolve_binary "codex" \
      "/opt/homebrew/bin/codex" \
      "/usr/local/bin/codex" \
      "$HOME/.local/bin/codex") || \
      die "launch_agent" "codex binary not found at PATH or known locations; provide --agent-binary"
  fi
  log "Resolved codex binary: $bin"
  # Codex 0.129+ accepts the initial prompt as a positional argv that
  # pre-fills the TUI composer — same mechanism Cursor's `agent` uses.
  # The prompt-argv form was deferred in MVP because older Codex CLIs
  # ignored extra argv; unblocked here (#492).
  local launch_cmd="cd $WORKTREE_PATH && $bin \"\$(cat $prompt_path)\""
  create_agent_terminal "OpenAI Codex" "$launch_cmd"
}

# Shared terminal creation + readiness polling, used by every launch_<kind>.
# Sets TERMINAL_ID on success. Polls `crow list-terminals` for up to 15s.
create_agent_terminal() {
  local terminal_name="$1"
  local launch_cmd="$2"

  log "Creating terminal '$terminal_name' (deferred agent launch via --command)..."
  local term_result
  if ! term_result=$(crow new-terminal --session "$SESSION_ID" \
    --cwd "$WORKTREE_PATH" \
    --name "$terminal_name" \
    --managed \
    --command "$launch_cmd" 2>&1); then
    die "new_terminal" "crow new-terminal failed: $term_result"
  fi

  # The RPC reports launch_failed when the tmux window could not be created
  # (e.g. new-window timed out under load) — don't pretend it launched.
  if grep -qE '"launch_failed"[[:space:]]*:[[:space:]]*true' <<< "$term_result"; then
    die "new_terminal" "crow could not create the terminal window: $term_result"
  fi

  TERMINAL_ID=$(json_val "terminal_id" <<< "$term_result")
  if [[ -z "$TERMINAL_ID" ]]; then
    die "new_terminal" "Could not parse terminal_id from: $term_result"
  fi
  log "Terminal created: $TERMINAL_ID"

  # Select session
  crow select-session --session "$SESSION_ID" >/dev/null 2>&1 \
    || log "Warning: select-session failed"

  # Verify the agent actually started rather than assuming success. Poll the
  # terminal's readiness (exposed on `crow list-terminals`) until it reaches
  # agentLaunched/shellReady. This is a warning, NOT a hard failure: the
  # workspace (worktree/session/metadata) is already set up, and crow's UI
  # shows a Retry affordance if the agent didn't start (#408).
  log "Waiting for the agent to launch..."
  local readiness="" attempt
  for attempt in $(seq 1 15); do
    local lt_result
    lt_result=$(crow list-terminals --session "$SESSION_ID" 2>/dev/null) || true
    readiness=$(terminal_readiness "$TERMINAL_ID" "$lt_result")
    case "$readiness" in
      agentLaunched|shellReady)
        log "$terminal_name launched (readiness=$readiness)"
        return
        ;;
      failed|timedOut)
        log "WARNING: agent did not start (readiness=$readiness). The terminal" \
            "is up but the agent isn't running — use Retry in the Crow UI."
        return
        ;;
    esac
    sleep 1
  done
  log "WARNING: agent launch not confirmed after 15s (last readiness='${readiness:-unknown}')." \
      "The workspace is set up; check the Crow terminal and use Retry if needed."
}

launch_agent() {
  if [[ "$SKIP_LAUNCH" == "true" ]]; then
    log "Skipping agent launch (--skip-launch)"
    return
  fi

  # Resolve agent kind: explicit flag > config.json (agentsByKind["work"]
  # then defaultAgentKind) > claude-code fallback.
  local kind="$AGENT_KIND"
  if [[ -z "$kind" ]]; then
    kind=$(read_agent_kind_from_config "work")
    log "Resolved agent kind from config: $kind"
  else
    log "Using agent kind from --agent-kind flag: $kind"
  fi

  # Pick the binary override. --agent-binary applies to any kind. The legacy
  # --claude-binary alias only applies when the resolved kind is claude-code.
  local override_bin="$AGENT_BINARY"
  if [[ -z "$override_bin" && "$kind" == "claude-code" && -n "$CLAUDE_BINARY" ]]; then
    override_bin="$CLAUDE_BINARY"
  fi

  local prompt_path="$DEV_ROOT/.claude/prompts/crow-prompt-$SESSION_NAME.md"

  case "$kind" in
    claude-code) launch_claude_code "$prompt_path" "$override_bin" ;;
    cursor)      launch_cursor "$prompt_path" "$override_bin" ;;
    codex)       launch_codex "$prompt_path" "$override_bin" ;;
    *) die "launch_agent" "Unknown agent kind: $kind (expected claude-code | cursor | codex)" ;;
  esac
}

# ─── Result ──────────────────────────────────────────────────────────────────

emit_result() {
  local terminal_field=""
  if [[ -n "$TERMINAL_ID" ]]; then
    terminal_field=", \"terminal_id\": \"$TERMINAL_ID\""
  fi

  printf '{"status":"ok","session_id":"%s"%s,"worktree_path":"%s","branch":"%s"}\n' \
    "$SESSION_ID" \
    "$terminal_field" \
    "$WORKTREE_PATH" \
    "$BRANCH"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"
  preflight

  setup_worktree
  create_session
  write_settings_local
  install_commit_hook
  github_ops
  jira_ops
  write_prompt
  launch_agent
  emit_result
}

# Only run when executed directly — sourcing (e.g. from tests) exposes the
# functions without kicking off a full workspace setup.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
