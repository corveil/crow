#!/usr/bin/env bash
# Unit tests for the generic per-session env injection in setup.sh (CROW-543).
#
# Sources setup.sh (the bottom `main` is guarded so sourcing is side-effect free)
# and exercises substitute_session_env_tokens / resolve_session_env /
# write_settings_local against a synthetic config.json. Mirrors the structure of
# setup_gateway_test.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/setup.sh"

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
not_contains() { # not_contains <description> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then
    pass=$((pass+1)); echo "  ok: $1"
  else
    fail=$((fail+1)); echo "  FAIL: $1"; echo "    [$2] unexpectedly contains [$3]"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Synthetic devRoot + config.json. Corveil carries a sessionEnv map (one
# templated value); Bare carries no sessionEnv; WithGateway carries both a
# gateway block and a sessionEnv map (coexistence case).
DEV_ROOT="$TMP/devroot"
mkdir -p "$DEV_ROOT/.claude"
cat > "$DEV_ROOT/.claude/config.json" <<'JSON'
{
  "workspaces": [
    {
      "id": "00000000-0000-0000-0000-000000000001",
      "name": "Corveil",
      "provider": "github",
      "cli": "gh",
      "sessionEnv": {
        "COORD_SESSION_NAME": "{{session_name}}",
        "STATIC_KEY": "fixed-value"
      }
    },
    {
      "id": "00000000-0000-0000-0000-000000000002",
      "name": "Bare",
      "provider": "github",
      "cli": "gh"
    },
    {
      "id": "00000000-0000-0000-0000-000000000003",
      "name": "WithGateway",
      "provider": "github",
      "cli": "gh",
      "gateway": {
        "baseURL": "https://corveil.io",
        "customHeaders": { "x-plain": "literal-value" }
      },
      "sessionEnv": { "COORD_SESSION_NAME": "{{session_name}}" }
    }
  ]
}
JSON

# Source the helpers (main is guarded). NOTE: sourcing runs the top-level global
# initializers (DEV_ROOT="", WORKSPACE="", …), so reset globals *after* this.
# shellcheck disable=SC1090
source "$SETUP_SH"
DEV_ROOT="$TMP/devroot"

# Reset the per-case session-env state. resolve_session_env is idempotent via
# WS_SESSION_ENV_RESOLVED, so flip it back to false between workspaces.
reset_session_env() {
  WS_SESSION_ENV=""
  WS_SESSION_ENV_RESOLVED=false
  CLI_SESSION_ENV=""
}
reset_gateway() {
  WS_GATEWAY_RESOLVED=false; WS_HAS_GATEWAY=false; WS_BASE_URL=""; WS_CUSTOM_HEADERS=""
}

# ── 1. Config map → settings.local.json .env (token substitution) ──────────────
echo "== config sessionEnv map =="
WORKSPACE="Corveil"
SESSION_NAME="crow-543-session-env"
SLUG="543-session-env"; BRANCH="feature/crow-543-session-env"; REPO="crow"
TICKET_NUMBER="543"; TICKET_URL=""; SESSION_ID="ABCD-1234"
WORKTREE_PATH="$DEV_ROOT/Corveil/crow-543"
reset_session_env; reset_gateway
mkdir -p "$WORKTREE_PATH"

resolve_session_env
contains "WS_SESSION_ENV carries templated value" "$WS_SESSION_ENV" "COORD_SESSION_NAME=crow-543-session-env"
contains "WS_SESSION_ENV carries static value" "$WS_SESSION_ENV" "STATIC_KEY=fixed-value"

write_settings_local
settings="$WORKTREE_PATH/.claude/settings.local.json"
check "settings.local.json written" "yes" "$([[ -f "$settings" ]] && echo yes || echo no)"
contains "env.COORD_SESSION_NAME = resolved session name" "$(cat "$settings")" '"COORD_SESSION_NAME": "crow-543-session-env"'
contains "env.STATIC_KEY present" "$(cat "$settings")" '"STATIC_KEY": "fixed-value"'
contains "attribution still written alongside session env" "$(cat "$settings")" '"attribution"'
check "settings.local.json is 0600" "600" "$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings")"

# ── 2. Flag overrides a config key of the same name ────────────────────────────
echo "== --session-env overrides config key =="
reset_session_env
CLI_SESSION_ENV="COORD_SESSION_NAME=from-flag"
WORKTREE_PATH="$DEV_ROOT/Corveil/crow-543-flag"
mkdir -p "$WORKTREE_PATH"
resolve_session_env
write_settings_local
settings="$WORKTREE_PATH/.claude/settings.local.json"
contains "flag value wins for duplicate key" "$(cat "$settings")" '"COORD_SESSION_NAME": "from-flag"'
not_contains "config value for duplicate key is gone" "$(cat "$settings")" '"COORD_SESSION_NAME": "crow-543-session-env"'
contains "non-conflicting config key preserved" "$(cat "$settings")" '"STATIC_KEY": "fixed-value"'

# ── 3. Flag-only on a workspace with no config map ─────────────────────────────
echo "== --session-env only (no config map) =="
WORKSPACE="Bare"
reset_session_env; reset_gateway
CLI_SESSION_ENV="FLAG_ONLY={{slug}}"
WORKTREE_PATH="$DEV_ROOT/Bare/crow-543-flagonly"
mkdir -p "$WORKTREE_PATH"
resolve_session_env
write_settings_local
settings="$WORKTREE_PATH/.claude/settings.local.json"
contains "flag-only key present with templated value" "$(cat "$settings")" '"FLAG_ONLY": "543-session-env"'

# ── 4. No sessionEnv + no flag → no .env noise (backward compatible) ───────────
echo "== no sessionEnv + no flag =="
WORKSPACE="Bare"
reset_session_env; reset_gateway
WORKTREE_PATH="$DEV_ROOT/Bare/crow-543-noenv"
mkdir -p "$WORKTREE_PATH"
resolve_session_env
check "WS_SESSION_ENV empty" "" "$WS_SESSION_ENV"
write_settings_local
settings="$WORKTREE_PATH/.claude/settings.local.json"
# Attribution still writes (SESSION_ID set), but there must be no .env block.
check "settings.local.json written for attribution" "yes" "$([[ -f "$settings" ]] && echo yes || echo no)"
not_contains "no .env key when no session env / gateway" "$(cat "$settings")" '"env"'
contains "attribution present" "$(cat "$settings")" '"attribution"'

# ── 5. Coexistence with a gateway ──────────────────────────────────────────────
echo "== session env + gateway coexist =="
WORKSPACE="WithGateway"
reset_session_env; reset_gateway
WORKTREE_PATH="$DEV_ROOT/WithGateway/crow-543-gw"
mkdir -p "$WORKTREE_PATH"
write_settings_local   # resolves both gateway + session env internally
settings="$WORKTREE_PATH/.claude/settings.local.json"
contains "session env key present" "$(cat "$settings")" '"COORD_SESSION_NAME": "crow-543-session-env"'
contains "gateway base URL present" "$(cat "$settings")" '"ANTHROPIC_BASE_URL": "https://corveil.io"'
contains "gateway header present" "$(cat "$settings")" "x-plain: literal-value"
contains "attribution present" "$(cat "$settings")" '"attribution"'

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
