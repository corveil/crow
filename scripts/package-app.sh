#!/usr/bin/env bash
# Build Crow.app with crowd (and crow) bundled as Tauri sidecars.
#
# Requires a prior Swift release build (`make daemon CONFIG=release` or
# scripts/package-release.sh). Writes:
#   release-app/Crow.app
# and, when CROW_VERSION is set:
#   Crow-${CROW_VERSION}-macos.app.zip
#   Crow-${CROW_VERSION}-macos.app.zip.sha256
#
# Flags:
#   --universal    fat Crow.app (aarch64 + x86_64); needs both rustc targets
#   --from DIR      passed through to prepare-desktop-sidecar.sh
#   --help
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
DESKTOP_DIR="$ROOT_DIR/crow-desktop"
TAURI_DIR="$DESKTOP_DIR/src-tauri"
APP_STAGING="$ROOT_DIR/release-app"

UNIVERSAL=0
FROM_DIR=""

usage() {
  sed -n '2,16p' "${BASH_SOURCE[0]}" | sed -e 's/^# //' -e 's/^#//'
}

cargo_env() {
  # Same PATH pin as the Makefile: a Rosetta shell can shadow arm64 rustc.
  PATH="/opt/homebrew/bin:${HOME}/.cargo/bin:${PATH}"
  export PATH
}

find_built_app() {
  local target=$1
  local p
  if [ -n "$target" ]; then
    p="$TAURI_DIR/target/${target}/release/bundle/macos/Crow.app"
    if [ -d "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  fi
  p="$TAURI_DIR/target/release/bundle/macos/Crow.app"
  if [ -d "$p" ]; then
    printf '%s' "$p"
    return 0
  fi
  echo "ERROR: Crow.app not found under $TAURI_DIR/target" >&2
  return 1
}

copy_resource_bundles() {
  local app=$1
  local src="$TAURI_DIR/sidecar-resources"
  local dest="$app/Contents/Resources"
  mkdir -p "$dest"
  shopt -s nullglob
  local bundles=("$src"/*.bundle)
  if ((${#bundles[@]} == 0)); then
    echo "ERROR: no .bundle resources staged in $src" >&2
    return 1
  fi
  cp -R "${bundles[@]}" "$dest"/
  for bundle in "${bundles[@]}"; do
    echo "    Resources/$(basename "$bundle")"
  done
}

package_app_main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --universal)
        UNIVERSAL=1
        shift
        ;;
      --from)
        FROM_DIR=$2
        shift 2
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

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: Crow.app is macOS-only" >&2
    return 1
  fi

  cargo_env

  command -v cargo >/dev/null 2>&1 || {
    echo "ERROR: cargo (Rust) not found. Install from https://rustup.rs" >&2
    return 1
  }
  command -v npm >/dev/null 2>&1 || {
    echo "ERROR: npm not found. The Tauri CLI is installed from crow-desktop/package.json." >&2
    return 1
  }

  local prepare_cmd=("$SCRIPT_DIR/prepare-desktop-sidecar.sh")
  if [ "$UNIVERSAL" -eq 1 ]; then
    prepare_cmd+=(--universal)
  fi
  if [ -n "$FROM_DIR" ]; then
    prepare_cmd+=(--from "$FROM_DIR")
  fi
  bash "${prepare_cmd[@]}"

  echo "==> npm ci (Tauri CLI)"
  (cd "$DESKTOP_DIR" && npm ci --no-audit --no-fund)

  local tauri_args=(build --bundles app --config src-tauri/tauri.sidecar.conf.json)
  local rust_target=""
  if [ "$UNIVERSAL" -eq 1 ]; then
    rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
    tauri_args+=(--target universal-apple-darwin)
    rust_target="universal-apple-darwin"
  fi

  if [ -n "${CROW_VERSION:-}" ]; then
    tauri_args+=(--config "{\"version\":\"${CROW_VERSION}\"}")
  fi

  echo "==> tauri ${tauri_args[*]}"
  (cd "$DESKTOP_DIR" && npx tauri "${tauri_args[@]}")

  local built
  built="$(find_built_app "$rust_target")"
  echo "==> Copying SwiftPM resource bundles into Contents/Resources"
  copy_resource_bundles "$built"

  rm -rf "$APP_STAGING"
  mkdir -p "$APP_STAGING"
  cp -R "$built" "$APP_STAGING/Crow.app"
  echo "    $APP_STAGING/Crow.app"

  if [ -n "${CROW_VERSION:-}" ]; then
    local zip_name="$ROOT_DIR/Crow-${CROW_VERSION}-macos.app.zip"
    rm -f "$zip_name"
    COPYFILE_DISABLE=1 ditto -c -k --keepParent "$APP_STAGING/Crow.app" "$zip_name"
    shasum -a 256 "$zip_name" > "$zip_name.sha256"
    echo "    $zip_name"
  fi

  echo "==> Done"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  package_app_main "$@"
fi
