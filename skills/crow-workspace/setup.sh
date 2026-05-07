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
SESSION_ID=""
PRIMARY=false
SKIP_LAUNCH=false
SKIP_ASSIGN=false
SKIP_PROJECT_STATUS=false

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
  --claude-binary <path>     Full path to claude binary
  --session-id <uuid>        Existing session ID (for secondary repos)
  --primary                  Mark worktree as primary
  --skip-launch              Skip Claude Code launch
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
      --claude-binary)     CLAUDE_BINARY="$2"; shift 2 ;;
      --session-id)        SESSION_ID="$2"; shift 2 ;;
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

setup_worktree() {
  log "Fetching origin..."
  if ! git -C "$REPO_PATH" fetch origin >&2 2>&1; then
    die "git_fetch" "git fetch origin failed"
  fi

  # Determine which branch and tracking mode to use
  local use_branch="$BRANCH"
  local track_flag="--no-track"
  local base_ref="origin/main"

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
      log "Creating new branch $BRANCH from origin/main"
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
    "commit": "🤖 Generated with Claude Code, orchestrated by Crow\\n\\nCo-Authored-By: Claude <noreply@anthropic.com>\\nCrow-Session: $SESSION_ID"
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

# ─── Launch Claude Code ─────────────────────────────────────────────────────

launch_claude() {
  if [[ "$SKIP_LAUNCH" == "true" ]]; then
    log "Skipping Claude Code launch (--skip-launch)"
    return
  fi

  # Resolve claude binary
  local claude_bin="$CLAUDE_BINARY"
  if [[ -z "$claude_bin" ]]; then
    claude_bin=$(command -v claude 2>/dev/null) || true
    if [[ -z "$claude_bin" ]]; then
      die "launch_claude" "claude binary not found — provide --claude-binary"
    fi
  fi

  # Create terminal
  log "Creating terminal..."
  local term_result
  if ! term_result=$(crow new-terminal --session "$SESSION_ID" \
    --cwd "$WORKTREE_PATH" \
    --name "Claude Code" \
    --managed 2>&1); then
    die "new_terminal" "crow new-terminal failed: $term_result"
  fi

  TERMINAL_ID=$(json_val "terminal_id" <<< "$term_result")
  if [[ -z "$TERMINAL_ID" ]]; then
    die "new_terminal" "Could not parse terminal_id from: $term_result"
  fi
  log "Terminal created: $TERMINAL_ID"

  # Select session
  crow select-session --session "$SESSION_ID" >/dev/null 2>&1 \
    || log "Warning: select-session failed"

  # Wait for the shell to initialize in the new terminal.
  # The terminal surface is pre-initialized by crow new-terminal, but the
  # shell process needs time to start and display its prompt.
  log "Waiting for shell to initialize..."
  sleep 3

  # Build the prompt file path
  local prompt_path="$DEV_ROOT/.claude/prompts/crow-prompt-$SESSION_NAME.md"

  # Send launch command
  log "Launching Claude Code..."
  local rc_args=""
  if is_remote_control_enabled; then
    rc_args=" --rc --name $(posix_quote "$SESSION_NAME")"
    log "Remote control enabled — launching with --rc --name '$SESSION_NAME'"
  fi
  local send_text="cd $WORKTREE_PATH && $claude_bin --permission-mode plan$rc_args \"\$(cat $prompt_path)\"\\n"
  if ! crow send --session "$SESSION_ID" --terminal "$TERMINAL_ID" "$send_text" >/dev/null 2>&1; then
    die "send_launch" "crow send failed"
  fi

  log "Claude Code launched"
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
  launch_claude
  emit_result
}

main "$@"
