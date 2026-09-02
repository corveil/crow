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
#   crow-${CROW_VERSION}-macos-universal.zip.sha256
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
#
# Flags:
#   --archive PATH        tarball to sign (default: crow-$CROW_VERSION-macos-universal.tar.gz)
#   --skip-notarize       sign + pack only (local testing; still needs the .p12)
#   --help
#
# If every signing and notarization secret is unset, the script does not fail:
# it packs an unsigned zip next to the tarball (SIGN_MODE=unsigned) so a v*
# tag can still attach binaries while the Apple Developer Program (DUNS) is
# pending. Partial secrets still fail closed. Once the five GitHub secrets
# are present, this is the signed + notarized path again — no workflow flip.
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

SKIP_NOTARIZE=0
ARCHIVE=""
# signed | unsigned — set by require_secrets.
SIGN_MODE=""

# Set by prepare_keychain; consumed by cleanup_keychain.
KEYCHAIN_PATH=""
KEYCHAIN_PASSWORD=""
P12_PATH=""
P8_PATH=""
ORIGINAL_KEYCHAINS=""
WORK_DIR=""

usage() {
  sed -n '2,39p' "$SIGN_SCRIPT" | sed -e 's/^# //' -e 's/^#//'
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

# Mach-O (thin or universal), by magic bytes so this works on Linux CI
# without cctools. MH_MAGIC / MH_CIGAM for 32/64-bit either endian; FAT_MAGIC.
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
  local f base id count=0
  if [ ! -f "$ENTITLEMENTS" ]; then
    echo "ERROR: entitlements file not found at $ENTITLEMENTS" >&2
    return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Identifier is basename-only. Today's tree is crow + crowd plus resource
    # bundles with no Mach-O; if a future bundle ships embedded binaries this
    # will collide on duplicate names and should switch to a path-relative id.
    base="$(basename "$f")"
    case "$base" in
      crow)  id="com.corveil.crow" ;;
      crowd) id="com.corveil.crowd" ;;
      *)     id="com.corveil.crow.$base" ;;
    esac
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

write_github_signed_output() {
  local signed=$1
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "signed=$signed" >> "$GITHUB_OUTPUT"
  fi
}

write_release_body() {
  local signed=$1 version=$2 dest=$3
  if [ "$signed" = "true" ]; then
    cat > "$dest" <<EOF
## Install

Download \`crow-${version}-macos-universal.tar.gz\` (or the \`.zip\`) and its checksum file, verify the archive, extract it, and symlink the binaries into your \`PATH\`. Keep the extracted directory intact — \`crowd\` needs the \`.bundle\` resources next to the binaries.

\`\`\`bash
shasum -a 256 -c crow-${version}-macos-universal.tar.gz.sha256
mkdir -p ~/.local/lib ~/.local/bin
tar -xzf crow-${version}-macos-universal.tar.gz -C ~/.local/lib
ln -sf ~/.local/lib/crow-${version}/crow ~/.local/bin/crow
ln -sf ~/.local/lib/crow-${version}/crowd ~/.local/bin/crowd
\`\`\`

These binaries are **signed and notarized** (Developer ID Application + notarytool). A browser download still applies Gatekeeper quarantine; first launch contacts Apple to look up the notarization ticket — you should **not** need \`xattr -d com.apple.quarantine\`.

Point \`crow autostart install --binary\` at the extracted \`crowd\` so launchd runs the signed daemon:

\`\`\`bash
crow autostart install --binary ~/.local/lib/crow-${version}/crowd
\`\`\`

To build from source instead: \`make daemon CONFIG=release && make install CONFIG=release\` (unsigned; fine for local use). Signing details: [docs/macos-release-signing.md](https://github.com/corveil/crow/blob/main/docs/macos-release-signing.md).
EOF
  else
    cat > "$dest" <<EOF
## Install (unsigned)

These binaries are **not signed or notarized**. The Apple Developer Program enrollment (DUNS) is still pending; once the GitHub signing secrets are set, the same workflow signs and notarizes automatically.

A browser download applies Gatekeeper quarantine. Clear it after extracting:

\`\`\`bash
shasum -a 256 -c crow-${version}-macos-universal.tar.gz.sha256
mkdir -p ~/.local/lib ~/.local/bin
tar -xzf crow-${version}-macos-universal.tar.gz -C ~/.local/lib
ln -sf ~/.local/lib/crow-${version}/crow ~/.local/bin/crow
ln -sf ~/.local/lib/crow-${version}/crowd ~/.local/bin/crowd
xattr -d com.apple.quarantine ~/.local/lib/crow-${version}/crow ~/.local/lib/crow-${version}/crowd
\`\`\`

Keep the extracted directory intact — \`crowd\` needs the \`.bundle\` resources next to the binaries.

\`\`\`bash
crow autostart install --binary ~/.local/lib/crow-${version}/crowd
\`\`\`

To build from source instead: \`make daemon CONFIG=release && make install CONFIG=release\`.
EOF
  fi
}

require_secrets() {
  local cert password notary_key notary_id notary_issuer
  cert="$(first_set \
    "${APPLE_DEVELOPER_SIGNING_KEY_CERT:-}" \
    "${RM_APPLE_DEVELOPER_SIGNING_KEY_CERT:-}" \
    "${DEVELOPER_CERTIFICATE_BASE64:-}" || true)"
  password="$(first_set \
    "${CSC_KEY_PASSWORD:-}" \
    "${DEVELOPER_CERTIFICATE_PASSWORD:-}" || true)"
  notary_key="$(first_set \
    "${APPLE_API_KEY:-}" \
    "${APPLE_API_KEY_P8_BASE64:-}" || true)"
  notary_id="$(first_set "${APPLE_API_KEY_ID:-}" || true)"
  notary_issuer="$(first_set \
    "${APPLE_API_ISSUER:-}" \
    "${APPLE_API_ISSUER_ID:-}" || true)"

  local have_cert=0 have_notary=0
  if [ -n "$cert" ] && [ -n "$password" ]; then
    have_cert=1
  fi
  if [ -n "$notary_key" ] && [ -n "$notary_id" ] && [ -n "$notary_issuer" ]; then
    have_notary=1
  fi

  # Completely unset → unsigned fallback (DUNS pending). --skip-notarize is
  # the local "sign but don't submit" path and still needs the .p12.
  if [ "$have_cert" -eq 0 ] && [ "$have_notary" -eq 0 ]; then
    if [ -n "$cert" ] || [ -n "$password" ] || [ -n "$notary_key" ] || [ -n "$notary_id" ] || [ -n "$notary_issuer" ]; then
      echo "ERROR: signing/notarization secrets are only partially set." >&2
      echo "  Set all five (see docs/macos-release-signing.md) or leave them all unset" >&2
      echo "  to publish an unsigned tarball until Apple enrollment completes." >&2
      return 1
    fi
    if [ "$SKIP_NOTARIZE" -eq 1 ]; then
      echo "ERROR: signing secrets missing." >&2
      echo "  --skip-notarize still needs APPLE_DEVELOPER_SIGNING_KEY_CERT and CSC_KEY_PASSWORD." >&2
      return 1
    fi
    SIGN_MODE=unsigned
    return 0
  fi

  if [ "$have_cert" -eq 0 ]; then
    echo "ERROR: signing secrets missing." >&2
    echo "  Need APPLE_DEVELOPER_SIGNING_KEY_CERT (base64 .p12) and CSC_KEY_PASSWORD." >&2
    echo "  See docs/macos-release-signing.md." >&2
    return 1
  fi
  SIGN_CERT_B64=$cert
  SIGN_CERT_PASSWORD=$password
  SIGN_MODE=signed

  if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    return 0
  fi
  if [ "$have_notary" -eq 0 ]; then
    echo "ERROR: notarization secrets missing." >&2
    echo "  Need APPLE_API_KEY, APPLE_API_KEY_ID, and APPLE_API_ISSUER." >&2
    echo "  Pass --skip-notarize to sign without submitting." >&2
    echo "  See docs/macos-release-signing.md." >&2
    return 1
  fi
  NOTARY_KEY=$notary_key
  NOTARY_KEY_ID=$notary_id
  NOTARY_ISSUER=$notary_issuer
}

macos_sign_notarize_main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --archive)
        ARCHIVE=$2
        shift 2
        ;;
      --skip-notarize)
        SKIP_NOTARIZE=1
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

  require_secrets

  DEST_DIR="$(cd "$(dirname "$ARCHIVE")" && pwd)"

  if [ "$SIGN_MODE" = "unsigned" ]; then
    echo "==> Apple secrets unset — packing unsigned zip (DUNS pending; not a signed release)"
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crow-sign.XXXXXX")"
    tar -xzf "$ARCHIVE" -C "$WORK_DIR"
    PACKAGE_DIR="crow-${CROW_VERSION}"
    if [ ! -d "$WORK_DIR/$PACKAGE_DIR" ]; then
      echo "ERROR: expected $PACKAGE_DIR/ inside the archive" >&2
      rm -rf "$WORK_DIR"
      WORK_DIR=""
      return 1
    fi
    ZIP_PATH="$DEST_DIR/crow-${CROW_VERSION}-macos-universal.zip"
    rm -f "$ZIP_PATH"
    "$DITTO_BIN" -c -k --keepParent "$WORK_DIR/$PACKAGE_DIR" "$ZIP_PATH"
    shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"
    echo "    $ARCHIVE (unsigned, from package-release.sh)"
    echo "    $ZIP_PATH (unsigned)"
    rm -rf "$WORK_DIR"
    WORK_DIR=""
    write_github_signed_output false
    write_release_body false "$CROW_VERSION" "$DEST_DIR/release-body.md"
    echo "==> Done (unsigned)"
    return 0
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
  pack_signed "$WORK_DIR" "$PACKAGE_DIR" "$DEST_DIR" "$CROW_VERSION"

  if [ "$SKIP_NOTARIZE" -eq 1 ]; then
    echo "==> Skipping notarization (--skip-notarize)"
  else
    ZIP_PATH="$DEST_DIR/crow-${CROW_VERSION}-macos-universal.zip"
    notarize_zip "$ZIP_PATH" "$NOTARY_KEY" "$NOTARY_KEY_ID" "$NOTARY_ISSUER"
  fi

  write_github_signed_output true
  write_release_body true "$CROW_VERSION" "$DEST_DIR/release-body.md"
  echo "==> Done"
}

# Sourced by macos-sign-notarize_test.sh; skip main in that case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  macos_sign_notarize_main "$@"
fi
