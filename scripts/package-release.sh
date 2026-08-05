#!/usr/bin/env bash
# Build universal crow + crowd release binaries and pack them into a tarball.
#
# Requires CROW_VERSION (from the git tag). Writes:
#   crow-${CROW_VERSION}-macos-universal.tar.gz
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -z "${CROW_VERSION:-}" ]; then
  echo "ERROR: CROW_VERSION is required" >&2
  exit 1
fi

cd "$ROOT_DIR"

bash scripts/generate-build-info.sh

swift build -c release --arch arm64 --arch x86_64 --product crow --product crowd

if [ -f .build/apple/Products/Release/crow ]; then
  BUILD_DIR=".build/apple/Products/Release"
else
  BUILD_DIR=".build/release"
fi

STAGING_DIR="$ROOT_DIR/release-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

for binary in crow crowd; do
  cp "$BUILD_DIR/$binary" "$STAGING_DIR/$binary"
  lipo -info "$STAGING_DIR/$binary"
done

ARCHIVE="crow-${CROW_VERSION}-macos-universal.tar.gz"
tar -czf "$ARCHIVE" -C "$STAGING_DIR" crow crowd
rm -rf "$STAGING_DIR"

echo "Created $ARCHIVE"
