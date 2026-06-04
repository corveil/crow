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

  # Step 2: Set ticket metadata (if URL provided)
  if [[ -n "$TICKET_URL" && -n "$TICKET_NUMBER" ]]; then
    log "Setting ticket metadata..."
    local ticket_args=(crow set-ticket --session "$SESSION_ID" --url "$TICKET_URL")
    [[ -n "$TICKET_TITLE" ]] && ticket_args+=(--title "$TICKET_TITLE")
    ticket_args+=(--number "$TICKET_NUMBER")
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
# alongside the standard `Co-Authored-By: Claude` line. Runs for every
# worktree (primary and secondary) regardless of --skip-launch, so any worktree
# the user later opens with Claude Code picks up the override.
write_settings_local() {
  if ! is_attribution_trailers_enabled; then
    log "Attribution trailers disabled via config; skipping settings.local.json"
    return
  fi

  if [[ -z "$SESSION_ID" ]]; then
    log "Warning: SESSION_ID not set, skipping settings.local.json"
    return
  fi

  local settings_dir="$WORKTREE_PATH/.claude"
  local settings_path="$settings_dir/settings.local.json"
  mkdir -p "$settings_dir"

  # The newlines inside the "commit" string are literal \n escapes in JSON;
  # the heredoc passes them through to the file as the two-character sequence.
  cat > "$settings_path" <<EOF
{
  "attribution": {
    "commit": "🐦‍⬛ Generated with Claude Code, orchestrated by Crow\\n\\nCo-Authored-By: Claude <noreply@anthropic.com>\\nCrow-Session: $SESSION_ID"
  }
}
EOF
  log "Wrote attribution settings to $settings_path"

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

# ─── GitHub Housekeeping (best-effort) ───────────────────────────────────────

github_ops() {
  if [[ "$PROVIDER" != "github" ]]; then
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
  local launch_cmd="cd $WORKTREE_PATH && $bin --permission-mode plan$rc_args \"\$(cat $prompt_path)\""
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
  # Codex has no prompt-argv form (matches OpenAICodexAgent.autoLaunchCommand
  # — bare `codex` only). The prompt file is still written; the user can
  # paste from it into the TUI.
  log "Note: Codex has no prompt-argv form; prompt file is at $prompt_path (paste manually if needed)."
  local launch_cmd="cd $WORKTREE_PATH && $bin"
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
  github_ops
  write_prompt
  launch_agent
  emit_result
}

main "$@"
