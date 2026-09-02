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
cleanup_staging() {
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -rf "$STAGING_ROOT"
  else
    echo "Keeping $STAGING_ROOT for inspection after failure (exit $rc)" >&2
  fi
}
trap cleanup_staging EXIT

bash scripts/generate-build-info.sh

# Dual-arch `swift build --arch arm64 --arch x86_64` fails on Xcode 16.4 /
# GitHub-hosted macos-15 (missing target configuration for UnixSignals /
# ServiceLifecycle / _RopeModule; duplicate DependencyMetadataFileList).
# Build each slice and lipo — still a universal binary (ADR 0006).
for arch in arm64 x86_64; do
  echo "==> swift build -c release --arch $arch"
  swift build -c release --arch "$arch"
done

release_dir_for_arch() {
  local arch=$1 d
  for d in \
    ".build/${arch}-apple-macosx/release" \
    ".build/${arch}-apple-macosx/Release"; do
    if [ -f "$d/crow" ] && [ -f "$d/crowd" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  echo "ERROR: no release dir for $arch (looked under .build/${arch}-apple-macosx/)" >&2
  find .build -name crow -type f 2>/dev/null | head -20 >&2 || true
  return 1
}

ARM_DIR="$(release_dir_for_arch arm64)"
X86_DIR="$(release_dir_for_arch x86_64)"
BUILD_DIR="$ARM_DIR"

rm -rf "$STAGING_ROOT"
mkdir -p "$STAGING_DIR"

for binary in crow crowd; do
  lipo -create "$ARM_DIR/$binary" "$X86_DIR/$binary" -output "$STAGING_DIR/$binary"
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

SMOKE_SOCKET="${TMPDIR:-/tmp}/crow-release-smoke-$$.sock"
SMOKE_PORT=$((18000 + RANDOM % 1000))

# Smoke-test the staged artifact outside the build tree. `crow --version` always
# runs; the `crowd` half runs only in CI — App Support paths are not relocatable
# on macOS via HOME, so a local crowd smoke test would touch the developer's
# live store even with --dev-root pointed at scratch.
(
  cd "$STAGING_DIR"
  ./crow --version >/dev/null

  if [ -z "${GITHUB_ACTIONS:-}" ]; then
    echo "Skipping crowd smoke test outside CI (App Support is not relocatable on macOS)" >&2
    exit 0
  fi

  SMOKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/crow-release-smoke-home.XXXXXX")"
  crowd_pid=""
  trap 'if [ -n "$crowd_pid" ]; then kill "$crowd_pid" 2>/dev/null; wait "$crowd_pid" 2>/dev/null; fi; rm -rf "$SMOKE_HOME" "$SMOKE_SOCKET"' EXIT

  HOME="$SMOKE_HOME" ./crowd \
    --dev-root "$SMOKE_HOME/devroot" \
    --socket-path "$SMOKE_SOCKET" \
    --host 127.0.0.1 \
    --http-port "$SMOKE_PORT" &
  crowd_pid=$!

  ready=0
  for _ in $(seq 1 60); do
    if curl -sf -o /dev/null "http://127.0.0.1:${SMOKE_PORT}/auth/check"; then
      ready=1
      break
    fi
    sleep 0.5
  done
  if [ "$ready" -ne 1 ]; then
    echo "ERROR: crowd did not become ready on http://127.0.0.1:${SMOKE_PORT} (/auth/check)" >&2
    exit 1
  fi

  if ! curl -sf "http://127.0.0.1:${SMOKE_PORT}/version.json" | grep -q '"version"'; then
    echo "ERROR: bundle-backed /version.json missing or invalid (CrowDaemon resource bundle?)" >&2
    exit 1
  fi

  if ! curl -sf -o /dev/null "http://127.0.0.1:${SMOKE_PORT}/"; then
    echo "ERROR: bundle-backed / (index.html) missing (CrowDaemon resource bundle?)" >&2
    exit 1
  fi
)

ARCHIVE="crow-${CROW_VERSION}-macos-universal.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$STAGING_ROOT" "$PACKAGE_DIR"
shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

echo "Created $ARCHIVE and $ARCHIVE.sha256"
