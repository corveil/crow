#!/usr/bin/env bash
# Stage crowd/crow + SwiftPM resource bundles for a Tauri `externalBin` build.
#
# Copies the release (or --config) Swift binaries into
#   crow-desktop/src-tauri/binaries/{crowd,crow}-$TRIPLE
# so `bundle.externalBin` can find them, and copies `*.bundle` into
#   crow-desktop/src-tauri/sidecar-resources/
# so package-app.sh can drop them in Crow.app/Contents/Resources.
#
# Flags:
#   --from DIR     Swift products dir (default: .build/universal/release after
#                  package-release.sh, else .build/apple/Products/Release, else
#                  .build/release)
#   --universal    also write *-universal-apple-darwin (and both thin names)
#                  so `tauri build --target universal-apple-darwin` succeeds
#   --help
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DESKTOP_TAURI="$ROOT_DIR/crow-desktop/src-tauri"
BINARIES_DIR="$DESKTOP_TAURI/binaries"
RESOURCES_DIR="$DESKTOP_TAURI/sidecar-resources"

FROM_DIR=""
UNIVERSAL=0

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed -e 's/^# //' -e 's/^#//'
}

host_triple() {
  # rustc 1.84+ ; fall back to rustc -Vv for older toolchains.
  if rustc --print host-tuple >/dev/null 2>&1; then
    rustc --print host-tuple
    return 0
  fi
  rustc -Vv | awk '/^host:/{print $2; exit}'
}

resolve_build_dir() {
  if [ -n "$FROM_DIR" ]; then
    printf '%s' "$FROM_DIR"
    return 0
  fi
  if [ -f "$ROOT_DIR/.build/universal/release/crowd" ]; then
    printf '%s' "$ROOT_DIR/.build/universal/release"
    return 0
  fi
  # Legacy XCBuild layout from `swift build --arch arm64 --arch x86_64`.
  if [ -f "$ROOT_DIR/.build/apple/Products/Release/crowd" ]; then
    printf '%s' "$ROOT_DIR/.build/apple/Products/Release"
    return 0
  fi
  if [ -f "$ROOT_DIR/.build/release/crowd" ]; then
    printf '%s' "$ROOT_DIR/.build/release"
    return 0
  fi
  echo "ERROR: no release crowd found. Run 'make daemon CONFIG=release' or pass --from DIR." >&2
  return 1
}

stage_binary() {
  local src=$1 name=$2 dest_dir=$3 triple=$4
  local dest="$dest_dir/${name}-${triple}"
  cp "$src" "$dest"
  chmod +x "$dest"
  echo "    $name -> $dest"
}

prepare_desktop_sidecar_main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --from)
        FROM_DIR=$2
        shift 2
        ;;
      --universal)
        UNIVERSAL=1
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

  local build_dir
  build_dir="$(resolve_build_dir)"
  if [ ! -x "$build_dir/crowd" ]; then
    echo "ERROR: crowd is not executable at $build_dir/crowd" >&2
    return 1
  fi
  if [ ! -x "$build_dir/crow" ]; then
    echo "ERROR: crow is not executable at $build_dir/crow" >&2
    return 1
  fi

  mkdir -p "$BINARIES_DIR"
  # Drop previous staged copies so a host-arch leftover cannot shadow a
  # universal name (or vice versa) on the next build.
  find "$BINARIES_DIR" -type f ! -name '.gitkeep' -delete
  rm -rf "$RESOURCES_DIR"
  mkdir -p "$RESOURCES_DIR"

  echo "==> Staging sidecars from $build_dir"
  if [ "$UNIVERSAL" -eq 1 ]; then
    for triple in aarch64-apple-darwin x86_64-apple-darwin universal-apple-darwin; do
      stage_binary "$build_dir/crowd" crowd "$BINARIES_DIR" "$triple"
      stage_binary "$build_dir/crow" crow "$BINARIES_DIR" "$triple"
    done
  else
    local triple
    triple="$(host_triple)"
    if [ -z "$triple" ]; then
      echo "ERROR: could not determine rustc host triple" >&2
      return 1
    fi
    stage_binary "$build_dir/crowd" crowd "$BINARIES_DIR" "$triple"
    stage_binary "$build_dir/crow" crow "$BINARIES_DIR" "$triple"
  fi

  shopt -s nullglob
  local bundles=("$build_dir"/*.bundle)
  if ((${#bundles[@]} == 0)); then
    echo "ERROR: no resource bundles found in $build_dir" >&2
    echo "  crowd serves the web UI from CrowDaemon_CrowDaemon.bundle; without it the window 404s." >&2
    return 1
  fi
  cp -R "${bundles[@]}" "$RESOURCES_DIR"/
  for bundle in "${bundles[@]}"; do
    echo "    resource $(basename "$bundle")"
  done

  echo "==> Sidecars staged in $BINARIES_DIR"
}

# Sourced by prepare-desktop-sidecar_test.sh; skip main in that case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  prepare_desktop_sidecar_main "$@"
fi
