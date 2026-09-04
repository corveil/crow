#!/usr/bin/env bash
# Unit tests for scripts/write-release-notes.sh.
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/write-release-notes.sh"

# shellcheck source=write-release-notes.sh
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

heading_indent() {
  # Print 1 if any ATX heading has 4+ leading spaces (GitHub would not render it).
  if grep -E '^ {4,}#' "$1" >/dev/null; then
    printf '1'
  else
    printf '0'
  fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-release-notes-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "write_release_notes_main"
unset CROW_VERSION || true
check_rc "missing CROW_VERSION" 1 write_release_notes_main --output "$TMP/out.md"
CROW_VERSION="0.2.0-rc.1"
check_rc "missing --output" 1 write_release_notes_main
check_rc "unknown flag" 2 write_release_notes_main --bogus --output "$TMP/out.md"
check_rc "--help" 0 write_release_notes_main --help

check_rc "signed notes" 0 write_release_notes_main --output "$TMP/signed.md" \
  --repository corveil/crow
check "signed first line is heading" "## Install" "$(head -n 1 "$TMP/signed.md")"
check "signed headings not indented" "0" "$(heading_indent "$TMP/signed.md")"
if grep -Fq "signed and notarized" "$TMP/signed.md"; then
  check "signed body mentions notarized" "0" "0"
else
  check "signed body mentions notarized" "0" "1"
fi
if grep -Fq "NOT signed" "$TMP/signed.md"; then
  check "signed body has no unsigned banner" "0" "1"
else
  check "signed body has no unsigned banner" "0" "0"
fi
if grep -Fq "github.com/corveil/crow/blob/main/docs/macos-release-signing.md" "$TMP/signed.md"; then
  check "signed body links signing docs" "0" "0"
else
  check "signed body links signing docs" "0" "1"
fi

check_rc "unsigned notes" 0 write_release_notes_main --unsigned \
  --output "$TMP/unsigned.md" --repository corveil/crow
check "unsigned first line is heading" "## Unsigned prerelease" "$(head -n 1 "$TMP/unsigned.md")"
check "unsigned headings not indented" "0" "$(heading_indent "$TMP/unsigned.md")"
if grep -Fq "This build is NOT signed and NOT notarized." "$TMP/unsigned.md"; then
  check "unsigned banner present" "0" "0"
else
  check "unsigned banner present" "0" "1"
fi
if grep -Fq "xattr -dr com.apple.quarantine" "$TMP/unsigned.md"; then
  check "unsigned notes include xattr" "0" "0"
else
  check "unsigned notes include xattr" "0" "1"
fi
if grep -Fq "These binaries are **unsigned**" "$TMP/unsigned.md"; then
  check "unsigned footer present" "0" "0"
else
  check "unsigned footer present" "0" "1"
fi
if grep -Fq "0.2.0-rc.1" "$TMP/unsigned.md"; then
  check "version interpolated" "0" "0"
else
  check "version interpolated" "0" "1"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail  passed: $pass"
  exit 1
fi
echo "PASSED: $pass"
