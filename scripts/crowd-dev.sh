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
# Env overrides: CROW_HTTP_PORT (8787), CROW_SOCKET (~/.local/share/crow/crow.sock),
# CROW_DEV_ROOT (defaults to ~/Library/Application Support/crow/devroot, same as the app).
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${CROW_HTTP_HOST:-127.0.0.1}"
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
WEBDIR="$(pwd)/Packages/CrowDaemon/Sources/CrowDaemon/Resources/web"
WATCH=(Packages/CrowDaemon Packages/CrowEngine Packages/CrowProvider Packages/CrowClaude Packages/CrowTerminal Packages/CrowCore Packages/CrowIPC Packages/CrowGit Packages/CrowPersistence Sources/crowd)

START_CMD=(.build/debug/crowd --host "$HOST" --http-port "$PORT" --socket "$SOCK" --web-dir "$WEBDIR")

echo "[crowd-dev] ${START_CMD[*]}"
echo "[crowd-dev] http://$HOST:$PORT  · socket $SOCK · devRoot $DEVROOT · web live from $WEBDIR"

if command -v watchexec >/dev/null 2>&1; then
  echo "[crowd-dev] watchexec: rebuild + restart on *.swift change"
  WATCH_ARGS=()
  for w in "${WATCH[@]}"; do WATCH_ARGS+=(-w "$w"); done
  # Pass START_CMD as positional args so array quoting survives — a devRoot or
  # socket path with spaces/metacharacters must not word-split or get evaluated
  # (review). watchexec needs a shell for the `&&`, so route through `sh -c`.
  exec watchexec -r -e swift "${WATCH_ARGS[@]}" -- \
    sh -c 'swift build --product crowd && exec "$@"' sh "${START_CMD[@]}"
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
