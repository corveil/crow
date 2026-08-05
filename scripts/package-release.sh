#!/usr/bin/env bash
# Build universal crow + crowd release binaries and pack them into a tarball.
#
# Requires CROW_VERSION (from the git tag). Writes:
#   crow-${CROW_VERSION}-macos-universal.tar.gz
#   crow-${CROW_VERSION}-macos-universal.tar.gz.sha256
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -z "${CROW_VERSION:-}" ]; then
  echo "ERROR: CROW_VERSION is required" >&2
  exit 1
fi

cd "$ROOT_DIR"

STAGING_DIR="$ROOT_DIR/release-staging"
cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

bash scripts/generate-build-info.sh

# crow and crowd are the only two products; --product is single-valued in SwiftPM.
swift build -c release --arch arm64 --arch x86_64

if [ -f .build/apple/Products/Release/crow ]; then
  BUILD_DIR=".build/apple/Products/Release"
else
  BUILD_DIR=".build/release"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

for binary in crow crowd; do
  cp "$BUILD_DIR/$binary" "$STAGING_DIR/$binary"
  archs="$(lipo -archs "$STAGING_DIR/$binary")"
  for arch in arm64 x86_64; do
    case " $archs " in
      *" $arch "*) ;;
      *) echo "ERROR: $binary is missing $arch (got: $archs)" >&2; exit 1 ;;
    esac
  done
  echo "$binary: $archs"
done

ARCHIVE="crow-${CROW_VERSION}-macos-universal.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGING_DIR" crow crowd
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

echo "Created $ARCHIVE and $ARCHIVE.sha256"
