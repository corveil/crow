#!/usr/bin/env bash
#
# Run the `crowd` daemon for local development, serving the *frozen* web UI baked
# into crowd's resource bundle at build time — the same asset source as `make
# run`'s sidecar. Web UI edits (`index.html`/`app.css`/the classic client scripts) require a rebuild to
# be picked up; there is no live-from-source refresh loop.
#
# By default this builds `crowd` once and runs a stable daemon that a browser,
# the `crow` CLI, or the desktop app can attach to. Pass `--watch` to also
# rebuild + restart `crowd` whenever a Swift source or web asset changes.
#
# Note: Swift can't be hot-swapped into a running process, so `--watch` tears
# down and respawns the daemon on every change — the same "the server restarts"
# tradeoff as the Tauri dev loop. Prefer the default (no --watch) when you want a
# daemon that stays up across edits.
#
# Always binds 127.0.0.1 (loopback only) — front it with an HTTPS reverse proxy
# for remote access. Env overrides: CROW_HTTP_PORT (8787),
# CROW_SOCKET (~/.local/share/crow/crow.sock),
# CROW_DEV_ROOT (defaults to the app's devroot pointer, else the current dir),
# CROW_WEB_DIR (unset — set it to serve the web UI live from that on-disk
# directory instead of the frozen bundle; the crowd child inherits it).
set -euo pipefail
cd "$(dirname "$0")/.."

WATCH=0
for arg in "$@"; do
  case "$arg" in
    -w|--watch) WATCH=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--watch]"
      echo "  -w, --watch   Rebuild + restart crowd on Swift or web-asset changes"
      echo "                (default: build once, run a stable daemon)"
      exit 0 ;;
    *) echo "[daemon-run] unknown argument: $arg (try --help)" >&2; exit 2 ;;
  esac
done

HOST="127.0.0.1"   # loopback only; use a reverse proxy for remote access
PORT="${CROW_HTTP_PORT:-8787}"
SOCK="${CROW_SOCKET:-$HOME/.local/share/crow/crow.sock}"
SOCK="${SOCK/#\~/$HOME}"   # expand a leading ~ (a quoted CROW_SOCKET override won't be tilde-expanded by the shell)
if [[ -n "${CROW_DEV_ROOT:-}" ]]; then
  DEVROOT="$CROW_DEV_ROOT"
elif [[ -f "$HOME/Library/Application Support/crow/devroot" ]]; then
  DEVROOT="$(tr -d '[:space:]' < "$HOME/Library/Application Support/crow/devroot")"
else
  DEVROOT="$(pwd)"
fi
WATCH_PATHS=(Packages/CrowDaemon Packages/CrowEngine Packages/CrowProvider Packages/CrowClaude Packages/CrowTerminal Packages/CrowCore Packages/CrowIPC Packages/CrowGit Packages/CrowPersistence Sources/crowd)

# No --web-dir: serve the frozen web assets baked into crowd's resource bundle.
START_CMD=(.build/debug/crowd --host "$HOST" --http-port "$PORT" --socket "$SOCK")

echo "[daemon-run] ${START_CMD[*]}"
echo "[daemon-run] http://$HOST:$PORT  · socket $SOCK · devRoot $DEVROOT · web from compiled bundle"

# Default: build once, then run a stable daemon serving the frozen bundle-baked
# web assets. UI edits need a rebuild to show up (same as `make run`).
if [[ "$WATCH" -eq 0 ]]; then
  swift build --product crowd
  exec "${START_CMD[@]}"
fi

# --watch: rebuild + restart crowd on Swift *or* web-asset changes. A rebuild
# re-copies Resources/web into the bundle (Package.swift `.copy("Resources/web")`)
# and StaticAssets reads it per request, so a browser refresh shows web edits —
# the frozen-asset equivalent of the old live reload. Uses `watchexec` if
# installed (fastest); otherwise falls back to a portable mtime poll loop.
echo "[daemon-run] --watch: rebuild + restart on *.swift or Resources/web change"
if command -v watchexec >/dev/null 2>&1; then
  WATCH_ARGS=()
  for w in "${WATCH_PATHS[@]}"; do WATCH_ARGS+=(-w "$w"); done
  # Pass START_CMD as positional args so array quoting survives — a devRoot or
  # socket path with spaces/metacharacters must not word-split or get evaluated
  # (review). watchexec needs a shell for the `&&`, so route through `sh -c`.
  # Ignore web-tests/ so its *.test.js / package.json don't trigger rebuilds —
  # only shipped assets under Resources/web should, matching the poll filter.
  exec watchexec -r -e swift,js,css,html,svg,json -i '**/web-tests/**' "${WATCH_ARGS[@]}" -- \
    sh -c 'swift build --product crowd && exec "$@"' sh "${START_CMD[@]}"
fi

echo "[daemon-run] poll mode (install 'watchexec' for instant restarts: brew install watchexec)"
PID=""
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi; exit 0; }
trap cleanup INT TERM

# stat(1) differs across platforms: BSD/macOS uses `-f`, GNU/Linux uses `-c`.
# Watch Swift sources plus everything under Resources/web (any extension).
if stat -f '%m' . >/dev/null 2>&1; then
  snapshot() { find "${WATCH_PATHS[@]}" \( -name '*.swift' -o -path '*/Resources/web/*' \) -type f -exec stat -f '%m %N' {} + 2>/dev/null | sort; }
else
  snapshot() { find "${WATCH_PATHS[@]}" \( -name '*.swift' -o -path '*/Resources/web/*' \) -type f -exec stat -c '%Y %n' {} + 2>/dev/null | sort; }
fi

last=""
while true; do
  cur="$(snapshot)"
  if [ "$cur" != "$last" ]; then
    last="$cur"
    if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; fi
    if swift build --product crowd; then
      "${START_CMD[@]}" &
      PID=$!
      echo "[daemon-run] (re)started crowd pid=$PID"
    else
      echo "[daemon-run] build failed — fix and save to retry"
    fi
  fi
  sleep 1
done
