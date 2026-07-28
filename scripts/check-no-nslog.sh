#!/usr/bin/env bash
# Guard: NSLog() is banned outside CrowLog.swift (CROW-874).
#
# NSLog funnels into CoreFoundation's `_logToStderr`, which calls writev(2) on
# the controlling tty. When that tty's output queue is full and nobody is
# draining it (Ctrl-S, a stopped terminal, an unread pane), writev blocks in the
# kernel with no timeout. crowd's RPC handlers hop to the MainActor, so one such
# call inside MainActor.run stalls every other MainActor-bound RPC until the tty
# drains — a `sample` of a wedged daemon caught exactly that, with
# `crow reload-tmux-config` hanging and `open-terminal` timing out behind it.
#
# CrowLog.info()/error() mirror to os_log on the calling thread (a bounded
# memcpy into this process's trace buffer, which cannot block) and enqueue onto
# a bounded backlog that a dedicated thread drains. A wedged sink costs dropped
# lines, not a dead daemon.
#
# Second reason: NSLog treats its first argument as a printf format string. Most
# converted call sites passed interpolated, externally-influenced text (branch
# names, PR titles, raw `gh` stderr, user paths) there, where a stray % reads
# garbage varargs. `CrowLog.info(_ message: String)` makes that impossible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SINK="Packages/CrowCore/Sources/CrowCore/CrowLog.swift"

# Match `NSLog(` with the paren so prose mentioning NSLog stays legal. The sink
# itself is exempt (its doc comment explains what it replaced), as are tests and
# vendored checkouts under .build.
hits="$(grep -rn --include='*.swift' 'NSLog(' Packages Sources \
        | grep -v '/\.build/' \
        | grep -v '/Tests/' \
        | grep -v "^${SINK}:" || true)"

if [ -n "$hits" ]; then
  count="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  echo "ERROR: $count NSLog() call(s) outside $SINK (CROW-874)." >&2
  echo "       Use CrowLog.info(\"…\") or CrowLog.error(\"…\") instead." >&2
  echo >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi

echo "✓ no NSLog() outside $SINK"
