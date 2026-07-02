#!/usr/bin/env bash
# Unit tests for binary discovery helpers in setup.sh (CROW-484 parity).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/setup.sh"

pass=0; fail=0
check() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass+1)); echo "  ok: $1"
  else
    fail=$((fail+1)); echo "  FAIL: $1"; echo "    expected: [$2]"; echo "    actual:   [$3]"
  fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TEST_DEV_ROOT="$TMP/devroot"
mkdir -p "$TEST_DEV_ROOT/.claude/bin"
cat > "$TMP/codex-from-config" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/codex-from-config"
ln -sf "$TMP/codex-from-config" "$TMP/codex"
ln -sf "$TMP/codex-from-config" "$TEST_DEV_ROOT/.claude/bin/codex"

cat > "$TMP/crow-from-config" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/crow-from-config"

cat > "$TEST_DEV_ROOT/.claude/config.json" <<JSON
{
  "defaults": {
    "binaries": {
      "crow": "$TMP/crow-from-config",
      "codex": "$TMP/codex-from-config"
    }
  }
}
JSON

# shellcheck disable=SC1090
source "$SETUP_SH"
DEV_ROOT="$TEST_DEV_ROOT"

echo "binary_from_config"
check "crow override" "$TMP/crow-from-config" "$(binary_from_config crow)"
check "codex override" "$TMP/codex-from-config" "$(binary_from_config codex)"
check "missing key" "" "$(binary_from_config missing)"

echo "resolve_binary"
check "config wins" "$TMP/codex-from-config" \
  "$(resolve_binary codex codex /opt/homebrew/bin/codex)"

echo "find_on_path"
check "walks injected path" "$TMP/codex" \
  "$(find_on_path codex "$TMP:/usr/bin")"

echo "resolve_crow_binary (config)"
CROW_BIN=""
check "crow from config" "0" "$(
  if resolve_crow_binary && [[ "$CROW_BIN" == "$TMP/crow-from-config" ]]; then echo 0; else echo 1; fi
)"

echo "resolve_crow_binary (dev build)"
mkdir -p "$TMP/ws2/rm/crow/.build/debug"
cat > "$TMP/ws2/rm/crow/.build/debug/crow" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP/ws2/rm/crow/.build/debug/crow"
mkdir -p "$TMP/ws2/rm/crow/.git"
mkdir -p "$TMP/ws2/.claude"
cat > "$TMP/ws2/.claude/config.json" <<'JSON'
{"defaults":{"binaries":{}}}
JSON
DEV_ROOT="$TMP/ws2"
CROW_BIN=""
# Skip live login-shell PATH resolution; empty LOGIN_PATH lets resolve_crow_binary
# fall through to the dev-build branch without picking up a host-installed crow.
LOGIN_PATH=""
LOGIN_PATH_RESOLVED=true
EXPECTED="$TMP/ws2/rm/crow/.build/debug/crow"
check "dev build under workspace" "$EXPECTED" "$(
  if resolve_crow_binary; then echo "$CROW_BIN"; else echo missing; fi
)"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "All $pass checks passed."
  exit 0
else
  echo "$fail failed, $pass passed."
  exit 1
fi
