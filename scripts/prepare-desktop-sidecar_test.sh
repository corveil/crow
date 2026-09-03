#!/usr/bin/env bash
# Unit tests for scripts/prepare-desktop-sidecar.sh. No Swift build, no Tauri.
#
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/prepare-desktop-sidecar.sh"

# shellcheck source=prepare-desktop-sidecar.sh
source "$SRC"

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
    echo "  ok: $1"
  else
    fail=$((fail + 1))
    echo "  FAIL: $1"
    echo "    expected: [$2]"
    echo "    actual:   [$3]"
  fi
}

check_rc() {
  local name=$1 expected=$2
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  check "$name" "$expected" "$rc"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-sidecar-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "prepare_desktop_sidecar_main"
check_rc "unknown flag" 2 prepare_desktop_sidecar_main --bogus
check_rc "--help" 0 prepare_desktop_sidecar_main --help

# Point the script at an empty products dir so resolve_build_dir's default
# search is skipped and we exercise the missing-crowd error.
FROM_DIR="$TMP/empty"
mkdir -p "$FROM_DIR"
check_rc "missing crowd at --from" 1 prepare_desktop_sidecar_main --from "$FROM_DIR"

echo "resolve_build_dir"
SAVED_ROOT="$ROOT_DIR"
ROOT_DIR="$TMP/root"
FROM_DIR=""
mkdir -p "$ROOT_DIR/.build/universal/release" \
  "$ROOT_DIR/.build/apple/Products/Release" \
  "$ROOT_DIR/.build/release"
printf 'uni' > "$ROOT_DIR/.build/universal/release/crowd"
printf 'apple' > "$ROOT_DIR/.build/apple/Products/Release/crowd"
printf 'native' > "$ROOT_DIR/.build/release/crowd"
check "prefers lipo products" "$ROOT_DIR/.build/universal/release" "$(resolve_build_dir)"
rm "$ROOT_DIR/.build/universal/release/crowd"
check "falls back to XCBuild products" "$ROOT_DIR/.build/apple/Products/Release" "$(resolve_build_dir)"
rm "$ROOT_DIR/.build/apple/Products/Release/crowd"
check "falls back to native release" "$ROOT_DIR/.build/release" "$(resolve_build_dir)"
rm "$ROOT_DIR/.build/release/crowd"
check_rc "no crowd anywhere" 1 resolve_build_dir
ROOT_DIR="$SAVED_ROOT"
FROM_DIR=""

# Staging copies both binaries + every .bundle, named with the host triple.
if ! command -v rustc >/dev/null 2>&1; then
  echo "skipping sidecar staging (no rustc)"
else
  FROM_DIR="$TMP/products"
  mkdir -p "$FROM_DIR/CrowDaemon_CrowDaemon.bundle" "$FROM_DIR/CrowTerminal_CrowTerminal.bundle"
  printf 'crowd-bin' > "$FROM_DIR/crowd"
  printf 'crow-bin' > "$FROM_DIR/crow"
  chmod +x "$FROM_DIR/crowd" "$FROM_DIR/crow"
  printf 'ui' > "$FROM_DIR/CrowDaemon_CrowDaemon.bundle/index.html"

  # Redirect staging into the scratch dir by shadowing the script's dest paths.
  BINARIES_DIR="$TMP/binaries"
  RESOURCES_DIR="$TMP/sidecar-resources"
  mkdir -p "$BINARIES_DIR"
  prepare_desktop_sidecar_main --from "$FROM_DIR"
  triple="$(host_triple)"
  check "staged crowd sidecar" "1" "$( [ -x "$BINARIES_DIR/crowd-${triple}" ] && echo 1 || echo 0 )"
  check "staged crow sidecar" "1" "$( [ -x "$BINARIES_DIR/crow-${triple}" ] && echo 1 || echo 0 )"
  check "copied daemon bundle" "1" "$( [ -d "$RESOURCES_DIR/CrowDaemon_CrowDaemon.bundle" ] && echo 1 || echo 0 )"
  check "copied terminal bundle" "1" "$( [ -d "$RESOURCES_DIR/CrowTerminal_CrowTerminal.bundle" ] && echo 1 || echo 0 )"
  check "bundle contents preserved" "ui" "$(cat "$RESOURCES_DIR/CrowDaemon_CrowDaemon.bundle/index.html")"

  # --universal writes all three names from the same fat (or thin) binary.
  prepare_desktop_sidecar_main --from "$FROM_DIR" --universal
  check "universal crowd name" "1" "$( [ -x "$BINARIES_DIR/crowd-universal-apple-darwin" ] && echo 1 || echo 0 )"
  check "arm64 crowd name" "1" "$( [ -x "$BINARIES_DIR/crowd-aarch64-apple-darwin" ] && echo 1 || echo 0 )"
  check "x86_64 crowd name" "1" "$( [ -x "$BINARIES_DIR/crowd-x86_64-apple-darwin" ] && echo 1 || echo 0 )"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail  passed: $pass"
  exit 1
fi
echo "PASSED: $pass"
