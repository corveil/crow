#!/usr/bin/env bash
# Unit tests for scripts/package-release.sh. No Swift build — the helpers are
# exercised with fixtures and a mocked lipo. The real dual-arch compile lives
# in ci.yml's Universal macOS Build job (CROW-1192).
#
# shellcheck disable=SC1091,SC2034
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/package-release.sh"

# shellcheck source=package-release.sh
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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-package-release-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "paths"
check "arm64 products dir" ".build/arm64-apple-macosx/release" "$(arch_products_dir arm64)"
check "x86_64 products dir" ".build/x86_64-apple-macosx/release" "$(arch_products_dir x86_64)"
check "thin crow path" ".build/arm64-apple-macosx/release/crow" "$(thin_product_path arm64 crow)"
check "universal products dir" ".build/universal/release" "$UNIVERSAL_PRODUCTS_DIR"

echo "CROW-1192: never two --arch on one swift build"
# Pin the invocation shape, not just the helpers: a future "simplification"
# back to two --arch flags on one swift build is exactly the XCBuild path
# that broke the v0.2.0 cut.
if grep -qE -- '--arch[[:space:]]+arm64[[:space:]]+--arch[[:space:]]+x86_64' "$SRC"; then
  check "script has no dual --arch invocation" "absent" "present"
else
  check "script has no dual --arch invocation" "absent" "absent"
fi
check_rc "rejects unknown arch" 1 swift_build_release_arch ppc

echo "package_release_main"
unset CROW_VERSION || true
check_rc "missing CROW_VERSION" 1 package_release_main

echo "lipo helpers"
# A fake lipo so this suite runs on the Ubuntu shellcheck job (no Darwin toolchain).
cat > "$TMP/lipo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-archs" ]; then
  echo "arm64 x86_64"
  exit 0
fi
if [ "${1:-}" = "-create" ]; then
  # lipo -create -output dest a b
  dest=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -create) shift ;;
      -output) dest=$2; shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'fat\n' > "$dest"
  exit 0
fi
echo "unexpected lipo argv: $*" >&2
exit 2
EOF
chmod +x "$TMP/lipo"
LIPO_BIN="$TMP/lipo"

mkdir -p "$TMP/work/.build/arm64-apple-macosx/release" \
  "$TMP/work/.build/x86_64-apple-macosx/release"
printf 'arm\n' > "$TMP/work/.build/arm64-apple-macosx/release/crow"
printf 'x86\n' > "$TMP/work/.build/x86_64-apple-macosx/release/crow"
(
  cd "$TMP/work"
  lipo_create_universal crow "$TMP/work/crow.fat"
)
check "lipo wrote dest" "fat" "$(cat "$TMP/work/crow.fat")"
check_rc "require_universal_archs on fat" 0 require_universal_archs "$TMP/work/crow.fat"

# Thin-only fake: missing x86_64 should fail the arch gate.
cat > "$TMP/lipo-thin" <<'EOF'
#!/usr/bin/env bash
echo "arm64"
EOF
chmod +x "$TMP/lipo-thin"
LIPO_BIN="$TMP/lipo-thin"
check_rc "require_universal_archs missing x86_64" 1 require_universal_archs "$TMP/work/crow.fat"

echo "copy_release_bundles"
LIPO_BIN="$TMP/lipo"
mkdir -p "$TMP/work/.build/arm64-apple-macosx/release/CrowDaemon_CrowDaemon.bundle"
printf 'ui\n' > "$TMP/work/.build/arm64-apple-macosx/release/CrowDaemon_CrowDaemon.bundle/index.html"
mkdir -p "$TMP/work/dest"
(
  cd "$TMP/work"
  copy_release_bundles "$TMP/work/dest"
)
check "copied daemon bundle" "ui" "$(cat "$TMP/work/dest/CrowDaemon_CrowDaemon.bundle/index.html")"

mkdir -p "$TMP/empty-src/.build/arm64-apple-macosx/release" "$TMP/empty-dest"
missing_bundles() {
  ( cd "$TMP/empty-src" && copy_release_bundles "$TMP/empty-dest" )
}
check_rc "copy_release_bundles missing bundles" 1 missing_bundles

echo "lipo_create_universal missing thin product"
printf 'arm-crowd\n' > "$TMP/work/.build/arm64-apple-macosx/release/crowd"
rm -f "$TMP/work/.build/x86_64-apple-macosx/release/crowd"
missing_x86_crowd() {
  ( cd "$TMP/work" && lipo_create_universal crowd "$TMP/work/crowd.fat" )
}
check_rc "missing x86_64 crowd" 1 missing_x86_crowd

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail  passed: $pass"
  exit 1
fi
echo "PASSED: $pass"
