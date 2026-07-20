#!/usr/bin/env bash
# Unit tests for the AI-gateway helpers in setup.sh (CROW-402).
#
# Sources setup.sh (the bottom `main` is guarded so sourcing is side-effect free)
# and exercises resolve_gateway_env / gateway_launch_prefix / write_settings_local
# against a synthetic config.json, with a fake `op` on PATH so no real 1Password
# lookup happens.
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

# Fake `op` that resolves any reference to a fixed marker.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/op" <<'OP'
#!/usr/bin/env bash
# fake `op read <ref>`
echo "RESOLVED-SECRET-for-$2"
OP
chmod +x "$TMP/bin/op"
export PATH="$TMP/bin:$PATH"

# Synthetic devRoot + config.json.
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
      "gateway": {
        "baseURL": "https://corveil.io",
        "customHeaders": {
          "x-citadel-api-key": "op://Vault/Citadel/api_key",
          "x-plain": "literal-value"
        }
      }
    },
    {
      "id": "00000000-0000-0000-0000-000000000002",
      "name": "Personal",
      "provider": "github",
      "cli": "gh"
    }
  ]
}
JSON

# Source the helpers (main is guarded). NOTE: sourcing setup.sh runs its
# top-level global initializers (DEV_ROOT="", WORKSPACE="", …), so any globals
# the tests rely on must be assigned *after* this line.
# shellcheck disable=SC1090
source "$SETUP_SH"
DEV_ROOT="$TMP/devroot"

echo "== gateway-present workspace =="
WORKSPACE="Corveil"
WORKTREE_PATH="$DEV_ROOT/Corveil/repo-1-slug"
SESSION_ID="ABCD-1234"
WS_GATEWAY_RESOLVED=false; WS_HAS_GATEWAY=false; WS_BASE_URL=""; WS_CUSTOM_HEADERS=""

resolve_gateway_env
check "WS_HAS_GATEWAY true" "true" "$WS_HAS_GATEWAY"
check "WS_BASE_URL" "https://corveil.io" "$WS_BASE_URL"
contains "op:// header resolved via op read" "$WS_CUSTOM_HEADERS" "x-citadel-api-key: RESOLVED-SECRET-for-op://Vault/Citadel/api_key"
contains "plaintext header passed through" "$WS_CUSTOM_HEADERS" "x-plain: literal-value"

prefix=$(gateway_launch_prefix)
contains "launch prefix sets baseURL" "$prefix" "ANTHROPIC_BASE_URL='https://corveil.io'"
# Two headers → the value has an embedded newline, so it is carried by
# settings.local.json rather than the launch line; the prefix still unsets any
# inherited ANTHROPIC_CUSTOM_HEADERS so the baseURL isn't paired with a stale
# ~/.zshrc header, and must not contain a literal newline.
contains "multi-header prefix unsets inherited headers" "$prefix" "unset ANTHROPIC_CUSTOM_HEADERS && "
check "multi-header prefix omits headers assignment" "0" "$([[ "$prefix" == *"ANTHROPIC_CUSTOM_HEADERS='"* ]] && echo 1 || echo 0)"
check "launch prefix has no embedded newline" "0" "$([[ "$prefix" == *$'\n'* ]] && echo 1 || echo 0)"

mkdir -p "$WORKTREE_PATH"
# Not a git repo → the git-exclude step skips gracefully (rev-parse fails); the
# settings.local.json write still happens, which is what we assert.
write_settings_local
settings="$WORKTREE_PATH/.claude/settings.local.json"
check "settings.local.json written" "yes" "$([[ -f "$settings" ]] && echo yes || echo no)"
contains "env.ANTHROPIC_BASE_URL present" "$(cat "$settings")" '"ANTHROPIC_BASE_URL": "https://corveil.io"'
contains "attribution preserved alongside env" "$(cat "$settings")" '"attribution"'
# Resolved secret must be present in the file (settings.local.json is the at-rest
# store for re-runs) but the bearer reference scheme must be gone.
contains "resolved secret in env" "$(cat "$settings")" "RESOLVED-SECRET-for-op://Vault/Citadel/api_key"
contains "both headers serialized in env" "$(cat "$settings")" "x-plain: literal-value"
# The file caches a resolved bearer token, so it must be owner-only (0600).
check "settings.local.json is 0600" "600" "$(stat -f '%Lp' "$settings" 2>/dev/null || stat -c '%a' "$settings")"

echo "== gateway-absent workspace =="
WORKSPACE="Personal"
WS_GATEWAY_RESOLVED=false; WS_HAS_GATEWAY=false; WS_BASE_URL=""; WS_CUSTOM_HEADERS=""
resolve_gateway_env
check "WS_HAS_GATEWAY false" "false" "$WS_HAS_GATEWAY"
prefix=$(gateway_launch_prefix)
check "launch prefix unsets" "unset ANTHROPIC_BASE_URL ANTHROPIC_CUSTOM_HEADERS && " "$prefix"

echo "== single-header launch prefix =="
WS_HAS_GATEWAY=true; WS_BASE_URL="https://corveil.io"; WS_CUSTOM_HEADERS="x-key: Bearer sk-1"
prefix=$(gateway_launch_prefix)
check "single header on launch line" \
  "ANTHROPIC_BASE_URL='https://corveil.io' ANTHROPIC_CUSTOM_HEADERS='x-key: Bearer sk-1' " \
  "$prefix"

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
