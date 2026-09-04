#!/usr/bin/env bash
# Sign every Mach-O in a Crow release tree, pack a zip, and notarize it.
#
# Input: the unsigned tarball from scripts/package-release.sh
#   crow-${CROW_VERSION}-macos-universal.tar.gz
#
# Output (overwrites the tarball; adds a zip):
#   crow-${CROW_VERSION}-macos-universal.tar.gz
#   crow-${CROW_VERSION}-macos-universal.tar.gz.sha256
#   crow-${CROW_VERSION}-macos-universal.zip          (the notarized container)
#   Crow-${CROW_VERSION}-macos.app.zip             (stapled .app; optional)
#   Crow-${CROW_VERSION}-macos.app.zip.sha256
#
# Required env (aliases accepted; see first_set):
#   APPLE_DEVELOPER_SIGNING_KEY_CERT  base64-encoded Developer ID .p12
#   CSC_KEY_PASSWORD                  password for that .p12
#   APPLE_API_KEY                     App Store Connect AuthKey .p8 (PEM or base64)
#   APPLE_API_KEY_ID
#   APPLE_API_ISSUER
#
# Optional:
#   DEVELOPER_ID_APPLICATION          codesign identity; discovered from the
#                                     imported cert when unset
#   CROW_VERSION                      required (from the git tag / workflow)
#   CROW_ALLOW_UNSIGNED               if 1 or true, same as --skip-signing
#
# Flags:
#   --archive PATH        tarball to sign (default: crow-$CROW_VERSION-macos-universal.tar.gz)
#   --app PATH            Crow.app to sign, notarize, and staple (default:
#                         $ROOT_DIR/release-app/Crow.app when that directory exists)
#   --skip-notarize       sign + pack only (local testing); still requires the .p12
#   --skip-signing        do not codesign, notarize, or staple; re-pack the
#                         unsigned tree to the usual output paths (CROW-1199)
#   --help
#
# The Developer ID cert is imported into an ephemeral keychain that this script
# deletes on EXIT — including on failure. It never touches the login keychain.
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SIGN_SCRIPT="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SIGN_SCRIPT")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT_DIR/Crow.entitlements}"

CODESIGN_BIN="${CODESIGN_BIN:-codesign}"
SECURITY_BIN="${SECURITY_BIN:-security}"
XCRUN_BIN="${XCRUN_BIN:-xcrun}"
DITTO_BIN="${DITTO_BIN:-ditto}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
STAPLER_BIN="${STAPLER_BIN:-stapler}"

SKIP_NOTARIZE=0
SKIP_SIGNING=0
ARCHIVE=""
APP_BUNDLE=""

# Set by prepare_keychain; consumed by cleanup_keychain.
KEYCHAIN_PATH=""
KEYCHAIN_PASSWORD=""
P12_PATH=""
P8_PATH=""
ORIGINAL_KEYCHAINS=""
WORK_DIR=""

usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SIGN_SCRIPT"
}

allow_unsigned_from_env() {
  case "${CROW_ALLOW_UNSIGNED:-}" in
    1|true|TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

# Print the first non-empty argument. Used so the workflow can accept both
# socketzero-style names and the retired Crow secret names.
first_set() {
  local val
  for val in "$@"; do
    if [ -n "$val" ]; then
      printf '%s' "$val"
      return 0
    fi
  done
  return 1
}

# If the blob looks like a PEM, write it as-is; otherwise treat it as base64.
# GitHub secrets mangle PEM newlines; base64 is the reliable form.
decode_maybe_base64() {
  local blob=$1 dest=$2
  if printf '%s' "$blob" | grep -q 'BEGIN '; then
    printf '%s\n' "$blob" > "$dest"
    return 0
  fi
  printf '%s' "$blob" | base64 --decode > "$dest"
}

# Strip a Tauri sidecar target-triple suffix so Contents/MacOS/crowd-aarch64-apple-darwin
# codesigns as com.corveil.crowd — the same id as the standalone CLI copy (ADR 0021).
# The .app itself stays com.corveil.crow; the CLI crow binary uses com.corveil.crow.cli
# so the two products in one release do not share a codesign identifier (CROW-1189).
sidecar_basename() {
  local base
  base="$(basename "$1")"
  # ${var%suffix} is prefix-greedy on the right; strip the known triples only.
  case "$base" in
    *-aarch64-apple-darwin)   printf '%s' "${base%-aarch64-apple-darwin}" ;;
    *-x86_64-apple-darwin)     printf '%s' "${base%-x86_64-apple-darwin}" ;;
    *-universal-apple-darwin) printf '%s' "${base%-universal-apple-darwin}" ;;
    *)                        printf '%s' "$base" ;;
  esac
}

codesign_identifier() {
  local path=$1 base
  base="$(sidecar_basename "$path")"
  case "$base" in
    Crow.app|Crow) printf '%s' "com.corveil.crow" ;;
    crow)          printf '%s' "com.corveil.crow.cli" ;;
    crowd)         printf '%s' "com.corveil.crowd" ;;
    *)             printf '%s' "com.corveil.crow.$base" ;;
  esac
}
is_macho() {
  local path=$1
  [ -f "$path" ] || return 1
  python3 - "$path" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as fh:
    magic = fh.read(4)
sys.exit(0 if magic in (
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
) else 1)
PY
}

list_machos() {
  local tree=$1 f
  # find -print0 / read -d is bash 3.2-safe and handles spaces.
  find "$tree" -type f -print0 | while IFS= read -r -d '' f; do
    if is_macho "$f"; then
      printf '%s\n' "$f"
    fi
  done
}

codesign_identity() {
  if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
    printf '%s' "$DEVELOPER_ID_APPLICATION"
    return 0
  fi
  "$SECURITY_BIN" find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | awk -F'"' '/Developer ID Application/{print $2; exit}'
}

prepare_keychain() {
  local cert_b64=$1 cert_password=$2
  local tmp
  tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  KEYCHAIN_PATH="$tmp/crow-signing-$$.keychain-db"
  KEYCHAIN_PASSWORD="$("$OPENSSL_BIN" rand -hex 16)"
  P12_PATH="$tmp/crow-signing-$$.p12"

  decode_maybe_base64 "$cert_b64" "$P12_PATH"
  chmod 600 "$P12_PATH"

  ORIGINAL_KEYCHAINS=$("$SECURITY_BIN" list-keychains -d user | tr -d '"')

  "$SECURITY_BIN" create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  "$SECURITY_BIN" set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
  "$SECURITY_BIN" unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
  "$SECURITY_BIN" import "$P12_PATH" \
    -P "$cert_password" \
    -A \
    -t cert \
    -f pkcs12 \
    -k "$KEYCHAIN_PATH"
  "$SECURITY_BIN" set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" >/dev/null
  # Prepend the ephemeral keychain without dropping the caller's search list
  # (needed so `security` itself still works). Word-splitting of
  # ORIGINAL_KEYCHAINS is intentional — each line is one keychain path.
  # shellcheck disable=SC2086
  "$SECURITY_BIN" list-keychains -d user -s "$KEYCHAIN_PATH" $ORIGINAL_KEYCHAINS

  rm -f "$P12_PATH"
  P12_PATH=""
}

cleanup_keychain() {
  local rc=$?
  if [ -n "$KEYCHAIN_PATH" ]; then
    # Restore the original search list before deleting, so a leftover
    # reference cannot point at a missing file on the next job.
    if [ -n "$ORIGINAL_KEYCHAINS" ]; then
      # shellcheck disable=SC2086
      "$SECURITY_BIN" list-keychains -d user -s $ORIGINAL_KEYCHAINS >/dev/null 2>&1 || true
    fi
    "$SECURITY_BIN" delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
    rm -f "$KEYCHAIN_PATH"
    KEYCHAIN_PATH=""
  fi
  rm -f "$P12_PATH" "$P8_PATH"
  P12_PATH=""
  P8_PATH=""
  if [ -n "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
    WORK_DIR=""
  fi
  return "$rc"
}

sign_tree() {
  local tree=$1 identity=$2
  local f id count=0
  if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: entitlements file not found at $ENTITLEMENTS" >&2
    return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    id="$(codesign_identifier "$f")"
    echo "    signing $f ($id)"
    "$CODESIGN_BIN" --force --options runtime --timestamp \
      --sign "$identity" \
      --keychain "$KEYCHAIN_PATH" \
      --entitlements "$ENTITLEMENTS" \
      --identifier "$id" \
      "$f"
    "$CODESIGN_BIN" --verify --strict --verbose=2 "$f"
    count=$((count + 1))
  done <<EOF
$(list_machos "$tree")
EOF
  if [ "$count" -lt 1 ]; then
    echo "ERROR: no Mach-O files found under $tree" >&2
    return 1
  fi
  echo "    signed $count Mach-O file(s)"
}

pack_signed() {
  local tree_parent=$1 package_dir=$2 dest_dir=$3 version=$4
  local tar_name zip_name
  tar_name="$dest_dir/crow-${version}-macos-universal.tar.gz"
  zip_name="$dest_dir/crow-${version}-macos-universal.zip"

  COPYFILE_DISABLE=1 tar -czf "$tar_name" -C "$tree_parent" "$package_dir"
  shasum -a 256 "$tar_name" > "$tar_name.sha256"

  rm -f "$zip_name"
  "$DITTO_BIN" -c -k --keepParent "$tree_parent/$package_dir" "$zip_name"
  shasum -a 256 "$zip_name" > "$zip_name.sha256"

  echo "    $tar_name"
  echo "    $zip_name"
}

write_api_key() {
  local blob=$1
  local tmp
  tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  P8_PATH="$tmp/AuthKey_$$.p8"
  decode_maybe_base64 "$blob" "$P8_PATH"
  chmod 600 "$P8_PATH"
}

notarize_zip() {
  local zip_path=$1 key_blob=$2 key_id=$3 issuer=$4
  write_api_key "$key_blob"
  echo "==> Submitting $zip_path to notarytool..."
  "$XCRUN_BIN" notarytool submit "$zip_path" \
    --key "$P8_PATH" \
    --key-id "$key_id" \
    --issuer "$issuer" \
    --wait \
    --timeout 1800
  # A zip cannot be stapled. Gatekeeper looks up the ticket by CDHash.
  echo "    notarization accepted (ticket is server-side; zip is not stapleable)"
  rm -f "$P8_PATH"
  P8_PATH=""
}

# Inside-out: nested Mach-Os (sidecars) first, then the .app bundle itself.
# Never --deep (ADR 0021). The bundle identifier is com.corveil.crow — the same
# as tauri.conf.json `identifier`. Sidecar crowd keeps com.corveil.crowd so
# launchd can still exec the standalone CLI copy.
sign_app() {
  local app=$1 identity=$2
  if [ ! -d "$app" ]; then
    echo "ERROR: Crow.app not found at $app" >&2
    return 1
  fi
  echo "==> Signing $app"
  sign_tree "$app" "$identity"
  echo "    signing bundle $(codesign_identifier "$app")"
  "$CODESIGN_BIN" --force --options runtime --timestamp \
    --sign "$identity" \
    --keychain "$KEYCHAIN_PATH" \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$(codesign_identifier "$app")" \
    "$app"
  "$CODESIGN_BIN" --verify --strict --verbose=2 "$app"
}

pack_app_zip() {
  local app=$1 dest_zip=$2
  rm -f "$dest_zip"
  "$DITTO_BIN" -c -k --keepParent "$app" "$dest_zip"
  shasum -a 256 "$dest_zip" > "$dest_zip.sha256"
  echo "    $dest_zip"
}

# Notarize a zip of the .app, staple the .app (unlike the CLI zip), re-zip.
notarize_and_staple_app() {
  local app=$1 dest_zip=$2 key_blob=$3 key_id=$4 issuer=$5
  pack_app_zip "$app" "$dest_zip"
  write_api_key "$key_blob"
  echo "==> Submitting $dest_zip to notarytool..."
  "$XCRUN_BIN" notarytool submit "$dest_zip" \
    --key "$P8_PATH" \
    --key-id "$key_id" \
    --issuer "$issuer" \
    --wait \
    --timeout 1800
  rm -f "$P8_PATH"
  P8_PATH=""
  echo "==> Stapling $app"
  "$XCRUN_BIN" "$STAPLER_BIN" staple "$app"
  pack_app_zip "$app" "$dest_zip"
}

require_secrets() {
  local cert password
  cert="$(first_set \
    "${APPLE_DEVELOPER_SIGNING_KEY_CERT:-}" \
    "${RM_APPLE_DEVELOPER_SIGNING_KEY_CERT:-}" \
    "${DEVELOPER_CERTIFICATE_BASE64:-}" || true)"
  password="$(first_set \
    "${CSC_KEY_PASSWORD:-}" \
    "${DEVELOPER_CERTIFICATE_PASSWORD:-}" || true)"
  if [ -z "$cert" ] || [ -z "$password" ]; then
    echo "ERROR: signing secrets missing." >&2
    echo "  Need APPLE_DEVELOPER_SIGNING_KEY_CERT (base64 .p12) and CSC_KEY_PASSWORD." >&2
    echo "  Pass --skip-signing (or CROW_ALLOW_UNSIGNED=1) to re-pack unsigned artifacts." >&2
    echo "  The GitHub Release unsigned path also needs vars.CROW_ALLOW_UNSIGNED_RELEASE=true." >&2
    echo "  See docs/macos-release-signing.md." >&2
    return 1
  fi
  SIGN_CERT_B64=$cert
  SIGN_CERT_PASSWORD=$password

  if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    return 0
  fi
  NOTARY_KEY="$(first_set \
    "${APPLE_API_KEY:-}" \
    "${APPLE_API_KEY_P8_BASE64:-}" || true)"
  NOTARY_KEY_ID="$(first_set "${APPLE_API_KEY_ID:-}" || true)"
  NOTARY_ISSUER="$(first_set \
    "${APPLE_API_ISSUER:-}" \
    "${APPLE_API_ISSUER_ID:-}" || true)"
  if [ -z "$NOTARY_KEY" ] || [ -z "$NOTARY_KEY_ID" ] || [ -z "$NOTARY_ISSUER" ]; then
    echo "ERROR: notarization secrets missing." >&2
    echo "  Need APPLE_API_KEY, APPLE_API_KEY_ID, and APPLE_API_ISSUER." >&2
    echo "  Pass --skip-notarize to sign without submitting." >&2
    echo "  See docs/macos-release-signing.md." >&2
    return 1
  fi
}

macos_sign_notarize_main() {
  SKIP_NOTARIZE=0
  SKIP_SIGNING=0
  ARCHIVE=""
  APP_BUNDLE=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --archive)
        ARCHIVE=$2
        shift 2
        ;;
      --app)
        APP_BUNDLE=$2
        shift 2
        ;;
      --skip-notarize)
        SKIP_NOTARIZE=1
        shift
        ;;
      --skip-signing)
        SKIP_SIGNING=1
        shift
        ;;
      --help|-h)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage >&2
        return 2
        ;;
    esac
  done

  if allow_unsigned_from_env; then
    SKIP_SIGNING=1
  fi

  if [ -z "${CROW_VERSION:-}" ]; then
    echo "ERROR: CROW_VERSION is required" >&2
    return 1
  fi

  if [ -z "$ARCHIVE" ]; then
    ARCHIVE="$ROOT_DIR/crow-${CROW_VERSION}-macos-universal.tar.gz"
  fi
  if [ ! -f "$ARCHIVE" ]; then
    echo "ERROR: archive not found: $ARCHIVE" >&2
    echo "Run scripts/package-release.sh first." >&2
    return 1
  fi

  if [ "$SKIP_SIGNING" -eq 1 ]; then
    echo "==> UNSIGNED: skipping codesign, notarize, and staple (--skip-signing / CROW_ALLOW_UNSIGNED)"
    echo "    Artifacts will be Gatekeeper-quarantined. Recipients must run:"
    echo "      xattr -dr com.apple.quarantine <path>"
    echo "    or right-click → Open. See ADR 0021 / CROW-1199."
  else
    require_secrets
  fi

  trap cleanup_keychain EXIT

  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crow-sign.XXXXXX")"
  echo "==> Extracting $ARCHIVE"
  tar -xzf "$ARCHIVE" -C "$WORK_DIR"
  PACKAGE_DIR="crow-${CROW_VERSION}"
  if [ ! -d "$WORK_DIR/$PACKAGE_DIR" ]; then
    echo "ERROR: expected $PACKAGE_DIR/ inside the archive" >&2
    return 1
  fi

  DEST_DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"

  if [ "$SKIP_SIGNING" -eq 0 ]; then
    echo "==> Importing Developer ID cert into ephemeral keychain"
    prepare_keychain "$SIGN_CERT_B64" "$SIGN_CERT_PASSWORD"

    IDENTITY="$(codesign_identity)"
    if [ -z "$IDENTITY" ]; then
      echo "ERROR: no Developer ID Application identity in the imported keychain" >&2
      "$SECURITY_BIN" find-identity -v -p codesigning "$KEYCHAIN_PATH" >&2 || true
      return 1
    fi
    echo "    identity: $IDENTITY"

    echo "==> Signing Mach-O files"
    sign_tree "$WORK_DIR/$PACKAGE_DIR" "$IDENTITY"

    echo "==> Packing signed archives"
  else
    echo "==> Packing UNSIGNED archives"
  fi
  pack_signed "$WORK_DIR" "$PACKAGE_DIR" "$DEST_DIR" "$CROW_VERSION"

  if [ "$SKIP_SIGNING" -eq 1 ]; then
    echo "==> Skipping notarization (unsigned)"
  elif [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "==> Skipping notarization (--skip-notarize)"
  else
    ZIP_PATH="$DEST_DIR/crow-${CROW_VERSION}-macos-universal.zip"
    notarize_zip "$ZIP_PATH" "$NOTARY_KEY" "$NOTARY_KEY_ID" "$NOTARY_ISSUER"
  fi

  if [ -z "$APP_BUNDLE" ] && [ -d "$ROOT_DIR/release-app/Crow.app" ]; then
    APP_BUNDLE="$ROOT_DIR/release-app/Crow.app"
  fi
  if [ -n "$APP_BUNDLE" ]; then
    if [ ! -d "$APP_BUNDLE" ]; then
      echo "ERROR: Crow.app not found at $APP_BUNDLE" >&2
      return 1
    fi
    APP_ZIP="$DEST_DIR/Crow-${CROW_VERSION}-macos.app.zip"
    if [ "$SKIP_SIGNING" -eq 1 ]; then
      echo "==> Packing UNSIGNED Crow.app zip"
      pack_app_zip "$APP_BUNDLE" "$APP_ZIP"
    else
      sign_app "$APP_BUNDLE" "$IDENTITY"
      if [ "$SKIP_NOTARIZE" -eq 1 ]; then
        echo "==> Packing unsigned-skip app zip (signed locally, not notarized)"
        pack_app_zip "$APP_BUNDLE" "$APP_ZIP"
      else
        notarize_and_staple_app "$APP_BUNDLE" "$APP_ZIP" "$NOTARY_KEY" "$NOTARY_KEY_ID" "$NOTARY_ISSUER"
      fi
    fi
  fi

  echo "==> Done"
}

# Sourced by macos-sign-notarize_test.sh; skip main in that case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  macos_sign_notarize_main "$@"
fi
