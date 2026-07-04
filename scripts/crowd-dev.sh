#!/usr/bin/env bash
#
# Dev hot-reload for the `crowd` daemon.
#
# - Web UI files (index.html/app.css/app.js) are served live from the source
#   folder via `--web-dir`, so editing them needs only a browser refresh — no
#   rebuild, no restart.
# - Swift changes can't be hot-swapped into a running binary, so this watches
#   the daemon's Swift sources and rebuilds + restarts `crowd` on change.
#
# Uses `watchexec` if installed (fastest); otherwise falls back to a portable
# mtime poll loop. Install the fast path with: brew install watchexec
#
# Env overrides: CROW_HTTP_PORT (8787), CROW_SOCKET ($TMPDIR/crowd.sock),
# CROW_DEV_ROOT (repo cwd).
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${CROW_HTTP_PORT:-8787}"
SOCK="${CROW_SOCKET:-${TMPDIR:-/tmp/}crowd.sock}"
DEVROOT="${CROW_DEV_ROOT:-$(pwd)}"
WEBDIR="$(pwd)/Packages/CrowDaemon/Sources/CrowDaemon/Resources/web"
WATCH=(Packages/CrowDaemon Packages/CrowTerminal Packages/CrowCore Packages/CrowIPC Packages/CrowGit Packages/CrowPersistence Sources/crowd)

START_CMD=(.build/debug/crowd --http-port "$PORT" --socket "$SOCK" --dev-root "$DEVROOT" --web-dir "$WEBDIR")

echo "[crowd-dev] http://127.0.0.1:$PORT  · socket $SOCK · web live from $WEBDIR"

if command -v watchexec >/dev/null 2>&1; then
  echo "[crowd-dev] watchexec: rebuild + restart on *.swift change"
  WATCH_ARGS=()
  for w in "${WATCH[@]}"; do WATCH_ARGS+=(-w "$w"); done
  exec watchexec -r -e swift "${WATCH_ARGS[@]}" -- \
    "swift build --product crowd && ${START_CMD[*]}"
fi

echo "[crowd-dev] poll mode (install 'watchexec' for instant restarts)"
PID=""
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi; exit 0; }
trap cleanup INT TERM

# macOS `stat -f`; on Linux swap to `stat -c '%Y %n'`.
snapshot() { find "${WATCH[@]}" -name '*.swift' -type f -exec stat -f '%m %N' {} + 2>/dev/null | sort; }

last=""
while true; do
  cur="$(snapshot)"
  if [ "$cur" != "$last" ]; then
    last="$cur"
    if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi
    if swift build --product crowd; then
      "${START_CMD[@]}" &
      PID=$!
      echo "[crowd-dev] (re)started crowd pid=$PID"
    else
      echo "[crowd-dev] build failed — fix and save to retry"
    fi
  fi
  sleep 1
done
