#!/usr/bin/env bash
#
# Run the `crowd` daemon for local development, serving the web UI live from the
# source folder — edit index.html/app.css/app.js, then just refresh the browser.
#
# By default this builds `crowd` once and runs a stable daemon that a browser,
# the `crow` CLI, or the desktop app can attach to. Pass `--watch` to also
# rebuild + restart `crowd` whenever a Swift source changes.
#
# Note: Swift can't be hot-swapped into a running process, so `--watch` tears
# down and respawns the daemon on every change — the same "the server restarts"
# tradeoff as the Tauri dev loop. Prefer the default (no --watch) when you want a
# daemon that stays up across edits. Note that `make run` spawns its `crowd`
# sidecar serving the *frozen* bundle-baked web assets (no live reload), so this
# script is what you want when you need live-from-source web editing.
#
# Always binds 127.0.0.1 (loopback only) — front it with an HTTPS reverse proxy
# for remote access. Env overrides: CROW_HTTP_PORT (8787),
# CROW_SOCKET (~/.local/share/crow/crow.sock),
# CROW_DEV_ROOT (defaults to the app's devroot pointer, else the current dir).
set -euo pipefail
cd "$(dirname "$0")/.."

WATCH=0
for arg in "$@"; do
  case "$arg" in
    -w|--watch) WATCH=1 ;;
    -h|--help)
      echo "Usage: $(basename "$0") [--watch]"
      echo "  -w, --watch   Rebuild + restart crowd on Swift source changes"
      echo "                (default: build once, run a stable daemon; web stays live)"
      exit 0 ;;
    *) echo "[crowd-dev] unknown argument: $arg (try --help)" >&2; exit 2 ;;
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
WEBDIR="$(pwd)/Packages/CrowDaemon/Sources/CrowDaemon/Resources/web"
WATCH_PATHS=(Packages/CrowDaemon Packages/CrowEngine Packages/CrowProvider Packages/CrowClaude Packages/CrowTerminal Packages/CrowCore Packages/CrowIPC Packages/CrowGit Packages/CrowPersistence Sources/crowd)

START_CMD=(.build/debug/crowd --host "$HOST" --http-port "$PORT" --socket "$SOCK" --web-dir "$WEBDIR")

echo "[crowd-dev] ${START_CMD[*]}"
echo "[crowd-dev] http://$HOST:$PORT  · socket $SOCK · devRoot $DEVROOT · web live from $WEBDIR"

# Default: build once, then run a stable daemon. Web assets are still served
# live from source, so UI edits need only a browser refresh — no restart.
if [[ "$WATCH" -eq 0 ]]; then
  swift build --product crowd
  exec "${START_CMD[@]}"
fi

# --watch: rebuild + restart crowd on Swift changes. Uses `watchexec` if
# installed (fastest); otherwise falls back to a portable mtime poll loop.
echo "[crowd-dev] --watch: rebuild + restart on *.swift change"
if command -v watchexec >/dev/null 2>&1; then
  WATCH_ARGS=()
  for w in "${WATCH_PATHS[@]}"; do WATCH_ARGS+=(-w "$w"); done
  # Pass START_CMD as positional args so array quoting survives — a devRoot or
  # socket path with spaces/metacharacters must not word-split or get evaluated
  # (review). watchexec needs a shell for the `&&`, so route through `sh -c`.
  exec watchexec -r -e swift "${WATCH_ARGS[@]}" -- \
    sh -c 'swift build --product crowd && exec "$@"' sh "${START_CMD[@]}"
fi

echo "[crowd-dev] poll mode (install 'watchexec' for instant restarts: brew install watchexec)"
PID=""
cleanup() { if [ -n "$PID" ]; then kill "$PID" 2>/dev/null || true; fi; exit 0; }
trap cleanup INT TERM

# stat(1) differs across platforms: BSD/macOS uses `-f`, GNU/Linux uses `-c`.
if stat -f '%m' . >/dev/null 2>&1; then
  snapshot() { find "${WATCH_PATHS[@]}" -name '*.swift' -type f -exec stat -f '%m %N' {} + 2>/dev/null | sort; }
else
  snapshot() { find "${WATCH_PATHS[@]}" -name '*.swift' -type f -exec stat -c '%Y %n' {} + 2>/dev/null | sort; }
fi

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
