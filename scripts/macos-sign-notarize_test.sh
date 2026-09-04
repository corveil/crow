#!/usr/bin/env bash
# Unit tests for scripts/macos-sign-notarize.sh. No Apple cert, no Darwin
# toolchain — the helpers are exercised with fixtures and mocked bins.
#
# shellcheck disable=SC1091,SC2034
# SC1091: we source the sibling script (shellcheck -x would follow it).
# SC2034: assignments here are read by the sourced helpers / main.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/macos-sign-notarize.sh"

# shellcheck source=macos-sign-notarize.sh
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

TMP=$(mktemp -d "${TMPDIR:-/tmp}/crow-sign-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "first_set"
check "first wins" "alpha" "$(first_set alpha beta)"
check "skips empty" "beta" "$(first_set "" beta gamma)"
check_rc "all empty is failure" 1 first_set "" ""

echo "decode_maybe_base64"
decode_maybe_base64 "aGVsbG8=" "$TMP/b64.out"
check "base64 blob" "hello" "$(cat "$TMP/b64.out")"
decode_maybe_base64 "$(printf '%s\n' '-----BEGIN PRIVATE KEY-----' 'MII' '-----END PRIVATE KEY-----')" "$TMP/pem.out"
check "pem blob kept" "1" "$(grep -c 'BEGIN PRIVATE KEY' "$TMP/pem.out")"

echo "is_macho"
printf 'not a binary' > "$TMP/plain"
check_rc "plain file is not macho" 1 is_macho "$TMP/plain"
# MH_MAGIC_64, little-endian (cf fa ed fe)
printf '\xcf\xfa\xed\xfe\x00\x00\x00\x00' > "$TMP/thin64"
check_rc "thin arm64/x86_64 magic" 0 is_macho "$TMP/thin64"
# FAT_MAGIC (ca fe ba be)
printf '\xca\xfe\xba\xbe\x00\x00\x00\x02' > "$TMP/fat"
check_rc "universal fat magic" 0 is_macho "$TMP/fat"
check_rc "missing file" 1 is_macho "$TMP/does-not-exist"

echo "list_machos"
mkdir -p "$TMP/tree/sub"
cp "$TMP/thin64" "$TMP/tree/crow"
cp "$TMP/plain" "$TMP/tree/README"
cp "$TMP/fat" "$TMP/tree/sub/crowd"
found=$(list_machos "$TMP/tree" | wc -l | tr -d ' ')
check "finds both machos, skips readme" "2" "$found"

echo "require_secrets"
SKIP_NOTARIZE=0
unset APPLE_DEVELOPER_SIGNING_KEY_CERT RM_APPLE_DEVELOPER_SIGNING_KEY_CERT \
  DEVELOPER_CERTIFICATE_BASE64 CSC_KEY_PASSWORD DEVELOPER_CERTIFICATE_PASSWORD \
  APPLE_API_KEY APPLE_API_KEY_P8_BASE64 APPLE_API_KEY_ID APPLE_API_ISSUER \
  APPLE_API_ISSUER_ID
check_rc "missing all secrets" 1 require_secrets

APPLE_DEVELOPER_SIGNING_KEY_CERT="Y2VydA=="
CSC_KEY_PASSWORD="pw"
check_rc "p12 without notary secrets" 1 require_secrets

APPLE_API_KEY="-----BEGIN PRIVATE KEY-----"
APPLE_API_KEY_ID="KEYID"
APPLE_API_ISSUER="ISSUER"
check_rc "all secrets present" 0 require_secrets
check "alias stored cert" "Y2VydA==" "$SIGN_CERT_B64"
check "alias stored password" "pw" "$SIGN_CERT_PASSWORD"

SKIP_NOTARIZE=1
unset APPLE_API_KEY APPLE_API_KEY_ID APPLE_API_ISSUER
check_rc "skip-notarize allows missing api key" 0 require_secrets

echo "legacy + socketzero aliases"
unset APPLE_DEVELOPER_SIGNING_KEY_CERT CSC_KEY_PASSWORD
DEVELOPER_CERTIFICATE_BASE64="bGVnYWN5"
DEVELOPER_CERTIFICATE_PASSWORD="oldpw"
SKIP_NOTARIZE=1
check_rc "retired Crow secret names" 0 require_secrets
check "legacy cert alias" "bGVnYWN5" "$SIGN_CERT_B64"
check "legacy password alias" "oldpw" "$SIGN_CERT_PASSWORD"

unset DEVELOPER_CERTIFICATE_BASE64 DEVELOPER_CERTIFICATE_PASSWORD
RM_APPLE_DEVELOPER_SIGNING_KEY_CERT="c29ja2V0emVybw=="
CSC_KEY_PASSWORD="socketpw"
check_rc "socketzero cert alias" 0 require_secrets
check "socketzero cert" "c29ja2V0emVybw==" "$SIGN_CERT_B64"

echo "allow_unsigned_from_env"
unset CROW_ALLOW_UNSIGNED
check_rc "unset env is not unsigned" 1 allow_unsigned_from_env
CROW_ALLOW_UNSIGNED=1
check_rc "CROW_ALLOW_UNSIGNED=1" 0 allow_unsigned_from_env
CROW_ALLOW_UNSIGNED=true
check_rc "CROW_ALLOW_UNSIGNED=true" 0 allow_unsigned_from_env
CROW_ALLOW_UNSIGNED=0
check_rc "CROW_ALLOW_UNSIGNED=0 is not unsigned" 1 allow_unsigned_from_env
unset CROW_ALLOW_UNSIGNED

echo "macos_sign_notarize_main"
check_rc "unknown flag" 2 macos_sign_notarize_main --bogus
check_rc "--help" 0 macos_sign_notarize_main --help

CROW_VERSION="0.0.0-test"
check_rc "missing archive" 1 macos_sign_notarize_main --archive "$TMP/nope.tar.gz"

# Valid unsigned tree so we can hit require_secrets vs --skip-signing.
mkdir -p "$TMP/bin" "$TMP/unsigned-src/crow-0.0.0-test" "$TMP/unsigned-out" \
  "$TMP/Crow.app/Contents/MacOS"
printf 'payload\n' > "$TMP/unsigned-src/crow-0.0.0-test/README"
cp "$TMP/thin64" "$TMP/unsigned-src/crow-0.0.0-test/crow"
cp "$TMP/thin64" "$TMP/Crow.app/Contents/MacOS/Crow"
COPYFILE_DISABLE=1 tar -czf \
  "$TMP/unsigned-out/crow-0.0.0-test-macos-universal.tar.gz" \
  -C "$TMP/unsigned-src" "crow-0.0.0-test"
UNSIGNED_ARCHIVE="$TMP/unsigned-out/crow-0.0.0-test-macos-universal.tar.gz"

unset APPLE_DEVELOPER_SIGNING_KEY_CERT RM_APPLE_DEVELOPER_SIGNING_KEY_CERT \
  DEVELOPER_CERTIFICATE_BASE64 CSC_KEY_PASSWORD DEVELOPER_CERTIFICATE_PASSWORD \
  CROW_ALLOW_UNSIGNED
check_rc "valid archive still fails without secrets or skip-signing" 1 \
  macos_sign_notarize_main --archive "$UNSIGNED_ARCHIVE"

cat > "$TMP/bin/ditto" <<'SH'
#!/usr/bin/env bash
dest="${!#}"
printf 'fake-zip\n' > "$dest"
SH
chmod +x "$TMP/bin/ditto"
DITTO_BIN="$TMP/bin/ditto"

cat > "$TMP/bin/codesign-fail" <<'SH'
#!/usr/bin/env bash
echo "codesign $*" >> "${CROW_FAKE_LOG:?}"
exit 99
SH
chmod +x "$TMP/bin/codesign-fail"
CODESIGN_BIN="$TMP/bin/codesign-fail"
export CROW_FAKE_LOG="$TMP/skip-signing-codesign.log"
: > "$CROW_FAKE_LOG"

check_rc "--skip-signing with no secrets" 0 \
  macos_sign_notarize_main --skip-signing \
  --archive "$UNSIGNED_ARCHIVE" --app "$TMP/Crow.app"
check "unsigned tar.gz present" "1" \
  "$( [ -f "$TMP/unsigned-out/crow-0.0.0-test-macos-universal.tar.gz" ] && echo 1 || echo 0 )"
check "unsigned tar.gz sha256 present" "1" \
  "$( [ -f "$TMP/unsigned-out/crow-0.0.0-test-macos-universal.tar.gz.sha256" ] && echo 1 || echo 0 )"
check "unsigned zip present" "1" \
  "$( [ -f "$TMP/unsigned-out/crow-0.0.0-test-macos-universal.zip" ] && echo 1 || echo 0 )"
check "unsigned app zip present" "1" \
  "$( [ -f "$TMP/unsigned-out/Crow-0.0.0-test-macos.app.zip" ] && echo 1 || echo 0 )"
check "unsigned app zip sha256 present" "1" \
  "$( [ -f "$TMP/unsigned-out/Crow-0.0.0-test-macos.app.zip.sha256" ] && echo 1 || echo 0 )"
check "skip-signing did not invoke codesign" "0" \
  "$( [ -s "$CROW_FAKE_LOG" ] && echo 1 || echo 0 )"

# Restore the test EXIT trap — main() installs cleanup_keychain on EXIT.
true
cleanup_keychain
trap 'rm -rf "$TMP"' EXIT

rm -f "$TMP/unsigned-out/"*.zip "$TMP/unsigned-out/"*.sha256
CROW_ALLOW_UNSIGNED=1
check_rc "CROW_ALLOW_UNSIGNED=1 without --skip-signing" 0 \
  macos_sign_notarize_main --archive "$UNSIGNED_ARCHIVE" --app "$TMP/Crow.app"
check "env unsigned zip present" "1" \
  "$( [ -f "$TMP/unsigned-out/crow-0.0.0-test-macos-universal.zip" ] && echo 1 || echo 0 )"
unset CROW_ALLOW_UNSIGNED
true
cleanup_keychain
trap 'rm -rf "$TMP"' EXIT

echo "cleanup_keychain"
KEYCHAIN_PATH="$TMP/fake.keychain-db"
ORIGINAL_KEYCHAINS="/tmp/login.keychain-db"
P12_PATH="$TMP/gone.p12"
P8_PATH="$TMP/gone.p8"
WORK_DIR="$TMP/work-should-stay"  # parent TMP is the test dir; use a child
mkdir -p "$WORK_DIR" "$TMP/bin"
printf 'x' > "$P12_PATH"
printf 'x' > "$P8_PATH"
touch "$KEYCHAIN_PATH"

cat > "$TMP/bin/security" <<'SH'
#!/usr/bin/env bash
echo "security $*" >> "${CROW_FAKE_LOG:?}"
exit 0
SH
chmod +x "$TMP/bin/security"
SECURITY_BIN="$TMP/bin/security"
export CROW_FAKE_LOG="$TMP/security.log"
: > "$CROW_FAKE_LOG"

# cleanup_keychain returns the incoming $? — call it from a successful
# context so a leftover KEYCHAIN_PATH cannot fail the test via `return $rc`.
true
cleanup_keychain
check "deleted p12" "0" "$( [ -f "$TMP/gone.p12" ] && echo 1 || echo 0 )"
check "deleted p8" "0" "$( [ -f "$TMP/gone.p8" ] && echo 1 || echo 0 )"
check "cleared KEYCHAIN_PATH" "" "$KEYCHAIN_PATH"
if grep -q "delete-keychain" "$CROW_FAKE_LOG"; then check "invoked delete-keychain" "0" "0"; else check "invoked delete-keychain" "0" "1"; fi
if grep -q "list-keychains -d user -s /tmp/login.keychain-db" "$CROW_FAKE_LOG"; then check "restored original keychain list" "0" "0"; else check "restored original keychain list" "0" "1"; fi

echo "sign_tree (mocked codesign)"
ENTITLEMENTS="$ROOT_DIR/Crow.entitlements"
mkdir -p "$TMP/sign-tree"
cp "$TMP/thin64" "$TMP/sign-tree/crow"
cat > "$TMP/bin/codesign" <<'SH'
#!/usr/bin/env bash
echo "codesign $*" >> "${CROW_FAKE_LOG:?}"
exit 0
SH
chmod +x "$TMP/bin/codesign"
CODESIGN_BIN="$TMP/bin/codesign"
KEYCHAIN_PATH="/tmp/crow-signing.keychain-db"
export CROW_FAKE_LOG="$TMP/codesign.log"
: > "$CROW_FAKE_LOG"
sign_tree "$TMP/sign-tree" "Developer ID Application: Test (ABCD)"
if grep -q -- "--options runtime" "$CROW_FAKE_LOG"; then check "hardened runtime" "0" "0"; else check "hardened runtime" "0" "1"; fi
if grep -q -- "--timestamp" "$CROW_FAKE_LOG"; then check "secure timestamp" "0" "0"; else check "secure timestamp" "0" "1"; fi
if grep -q -- "--identifier com.corveil.crow.cli" "$CROW_FAKE_LOG"; then check "bundle identifier for crow CLI" "0" "0"; else check "bundle identifier for crow CLI" "0" "1"; fi
if grep -q -- "--keychain /tmp/crow-signing.keychain-db" "$CROW_FAKE_LOG"; then check "signs with ephemeral keychain" "0" "0"; else check "signs with ephemeral keychain" "0" "1"; fi

echo "codesign_identifier"
check "Crow.app" "com.corveil.crow" "$(codesign_identifier /tmp/Crow.app)"
check "Crow binary" "com.corveil.crow" "$(codesign_identifier /tmp/Contents/MacOS/Crow)"
check "crow CLI" "com.corveil.crow.cli" "$(codesign_identifier /tmp/crow)"
check "crowd" "com.corveil.crowd" "$(codesign_identifier /tmp/crowd)"
check "crowd sidecar triple" "com.corveil.crowd" "$(codesign_identifier /tmp/Contents/MacOS/crowd-aarch64-apple-darwin)"
check "crow sidecar triple" "com.corveil.crow.cli" "$(codesign_identifier /tmp/crow-x86_64-apple-darwin)"
check "universal sidecar" "com.corveil.crowd" "$(codesign_identifier /tmp/crowd-universal-apple-darwin)"
check "unknown macho" "com.corveil.crow.helper" "$(codesign_identifier /tmp/helper)"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: $fail  passed: $pass"
  exit 1
fi
echo "PASSED: $pass"
