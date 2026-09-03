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
#
# Universal binaries are produced by building each arch with the native SwiftPM
# build system and lipo-ing the products. Passing two `--arch` flags on one
# `swift build` switches onto XCBuild, which on Xcode 16.4 fails for
# swift-service-lifecycle / swift-collections (CROW-1192).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# lipo-d products + copied resource bundles. prepare-desktop-sidecar.sh looks
# here before the legacy XCBuild path (.build/apple/Products/Release).
UNIVERSAL_PRODUCTS_DIR=".build/universal/release"
LIPO_BIN="${LIPO_BIN:-lipo}"

# Native SwiftPM (one --arch) layout. Dual --arch uses XCBuild under
# .build/apple/Products/Release, which we deliberately do not use (CROW-1192).
arch_products_dir() {
  printf '.build/%s-apple-macosx/release' "$1"
}

thin_product_path() {
  local arch=$1 name=$2
  printf '%s/%s' "$(arch_products_dir "$arch")" "$name"
}

# Single-arch native release build. Call once per arch — never pass two --arch
# flags to the same swift build (that is the XCBuild trigger).
swift_build_release_arch() {
  local arch=$1
  case "$arch" in
    arm64|x86_64) ;;
    *) echo "ERROR: unsupported arch: $arch" >&2; return 1 ;;
  esac
  echo "==> swift build -c release --arch $arch"
  swift build -c release --arch "$arch"
}

lipo_create_universal() {
  local name=$1 dest=$2
  local arm x86
  arm="$(thin_product_path arm64 "$name")"
  x86="$(thin_product_path x86_64 "$name")"
  if [ ! -f "$arm" ]; then
    echo "ERROR: missing $arm (arm64 release build did not produce $name)" >&2
    return 1
  fi
  if [ ! -f "$x86" ]; then
    echo "ERROR: missing $x86 (x86_64 release build did not produce $name)" >&2
    return 1
  fi
  "$LIPO_BIN" -create -output "$dest" "$arm" "$x86"
}

require_universal_archs() {
  local binary=$1
  local archs
  archs="$("$LIPO_BIN" -archs "$binary")"
  for arch in arm64 x86_64; do
    case " $archs " in
      *" $arch "*) ;;
      *) echo "ERROR: $binary is missing $arch (got: $archs)" >&2; return 1 ;;
    esac
  done
  echo "$binary: $archs"
}

copy_release_bundles() {
  local dest=$1
  local src
  local nullglob_was_set=0
  src="$(arch_products_dir arm64)"
  # Bundles are data (web UI, xterm assets), not Mach-O; either thin products
  # dir is fine. Prefer arm64 because GitHub-hosted macos-15 is Apple Silicon.
  shopt -q nullglob && nullglob_was_set=1
  shopt -s nullglob
  local bundles=("$src"/*.bundle)
  if [ "$nullglob_was_set" -eq 0 ]; then
    shopt -u nullglob
  fi
  if ((${#bundles[@]} == 0)); then
    echo "ERROR: no resource bundles found in $src" >&2
    return 1
  fi
  cp -R "${bundles[@]}" "$dest"/
  for bundle in "${bundles[@]}"; do
    echo "Bundled resource: $(basename "$bundle")"
  done
}

build_universal_products() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: universal macOS binaries require Darwin (lipo)" >&2
    return 1
  fi

  swift_build_release_arch arm64
  swift_build_release_arch x86_64

  mkdir -p "$UNIVERSAL_PRODUCTS_DIR"
  for binary in crow crowd; do
    lipo_create_universal "$binary" "$UNIVERSAL_PRODUCTS_DIR/$binary"
    require_universal_archs "$UNIVERSAL_PRODUCTS_DIR/$binary"
  done
  copy_release_bundles "$UNIVERSAL_PRODUCTS_DIR"
}

package_release_main() {
  if [ -z "${CROW_VERSION:-}" ]; then
    echo "ERROR: CROW_VERSION is required" >&2
    return 1
  fi

  cd "$ROOT_DIR"

  local PACKAGE_DIR="crow-${CROW_VERSION}"
  local STAGING_ROOT="$ROOT_DIR/release-staging"
  local STAGING_DIR="$STAGING_ROOT/$PACKAGE_DIR"
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

  build_universal_products

  local BUILD_DIR="$UNIVERSAL_PRODUCTS_DIR"

  rm -rf "$STAGING_ROOT"
  mkdir -p "$STAGING_DIR"

  local binary
  for binary in crow crowd; do
    cp "$BUILD_DIR/$binary" "$STAGING_DIR/$binary"
    require_universal_archs "$STAGING_DIR/$binary"
  done

  shopt -s nullglob
  local bundles=("$BUILD_DIR"/*.bundle)
  if ((${#bundles[@]} == 0)); then
    echo "ERROR: no resource bundles found in $BUILD_DIR" >&2
    return 1
  fi
  cp -R "${bundles[@]}" "$STAGING_DIR"/

  local SMOKE_SOCKET="${TMPDIR:-/tmp}/crow-release-smoke-$$.sock"
  local SMOKE_PORT=$((18000 + RANDOM % 1000))

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

  local ARCHIVE="crow-${CROW_VERSION}-macos-universal.tar.gz"
  COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$STAGING_ROOT" "$PACKAGE_DIR"
  shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256"

  echo "Created $ARCHIVE and $ARCHIVE.sha256"
}

# Sourced by package-release_test.sh; skip main in that case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  package_release_main "$@"
fi
