#!/usr/bin/env bash
# Build universal crow + crowd release binaries and pack them into a tarball.
#
# Requires CROW_VERSION (from the git tag). Writes:
#   crow-${CROW_VERSION}-macos-universal.tar.gz
#   crow-${CROW_VERSION}-macos-universal.tar.gz.sha256
#
# The archive contains a versioned directory with the binaries and the SwiftPM
# resource bundles crowd needs at runtime (CrowDaemon web assets, CrowTerminal
# tmux/xterm resources).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -z "${CROW_VERSION:-}" ]; then
  echo "ERROR: CROW_VERSION is required" >&2
  exit 1
fi

cd "$ROOT_DIR"

PACKAGE_DIR="crow-${CROW_VERSION}"
STAGING_ROOT="$ROOT_DIR/release-staging"
STAGING_DIR="$STAGING_ROOT/$PACKAGE_DIR"
cleanup() {
  rm -rf "$STAGING_ROOT"
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

rm -rf "$STAGING_ROOT"
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

shopt -s nullglob
bundles=("$BUILD_DIR"/*.bundle)
if ((${#bundles[@]} == 0)); then
  echo "ERROR: no resource bundles found in $BUILD_DIR" >&2
  exit 1
fi
cp -R "${bundles[@]}" "$STAGING_DIR"/
for bundle in "${bundles[@]}"; do
  echo "Bundled resource: $(basename "$bundle")"
done

# Smoke-test the staged artifact outside the build tree.
SMOKE_SOCKET="$(mktemp -u "${TMPDIR:-/tmp}/crow-release-smoke.XXXXXX.sock")"
SMOKE_PORT=$((18000 + RANDOM % 1000))
(
  cd "$STAGING_DIR"
  ./crow --version >/dev/null

  ./crowd --socket-path "$SMOKE_SOCKET" --host 127.0.0.1 --http-port "$SMOKE_PORT" &
  crowd_pid=$!
  trap 'kill "$crowd_pid" 2>/dev/null; wait "$crowd_pid" 2>/dev/null; rm -f "$SMOKE_SOCKET"' EXIT

  for _ in $(seq 1 60); do
    if curl -sf "http://127.0.0.1:${SMOKE_PORT}/version.json" >/dev/null; then
      curl -sf "http://127.0.0.1:${SMOKE_PORT}/version.json"
      curl -sf -o /dev/null "http://127.0.0.1:${SMOKE_PORT}/"
      exit 0
    fi
    sleep 0.5
  done
  echo "ERROR: crowd smoke test timed out waiting for http://127.0.0.1:${SMOKE_PORT}" >&2
  exit 1
)

ARCHIVE="crow-${CROW_VERSION}-macos-universal.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$STAGING_ROOT" "$PACKAGE_DIR"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

echo "Created $ARCHIVE and $ARCHIVE.sha256"
