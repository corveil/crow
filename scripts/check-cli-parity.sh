#!/usr/bin/env bash
# CLI control-plane parity gate, RPC half (CROW-807 / ADR 0016).
#
# Asserts that the set of registered JSON-RPC methods equals the set enumerated
# in the checked-in parity ledger. A new RPC method that nobody ledgered — and
# therefore nobody decided whether to give a `crow` verb — fails this check.
#
#   - daemon handlers → Packages/CrowDaemon/Sources/CrowDaemon/*RPCHandlers.swift
#     (`RPCHandlers.swift` is the assembler; each verb group is its own file.
#      The glob is load-bearing: a group that doesn't match it is invisible to
#      this gate. Support files — `*RPCSupport.swift`, `RPCWebSocketHandler.swift`,
#      `RPCDispatcher.swift`, `RPCLanePolicy.swift` — deliberately do not match.)
#   - engine handlers → Packages/CrowEngine/Sources/CrowEngine/EngineRouter.swift
#     (the daemon router is built with `fallback: makeEngineRouter(ctx)`, so the
#      live surface is the union of the two dictionaries)
#   - the ledger      → Packages/CrowCore/Sources/CrowCore/Parity/ParityLedger.swift
#
# `CrowDaemonTests/RPCLedgerParityTests` makes the same assertion against the
# real `CommandRouter.methodNames`, which is authoritative. This script exists
# because CrowDaemon depends on the Darwin-only CrowTelemetry and so cannot run
# in the Linux PR lane (see ci.yml's LINUX_PACKAGES) — text is the only way to
# get this check onto every pull request.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON_DIR="$ROOT/Packages/CrowDaemon/Sources/CrowDaemon"
ENGINE="$ROOT/Packages/CrowEngine/Sources/CrowEngine/EngineRouter.swift"
LEDGER="$ROOT/Packages/CrowCore/Sources/CrowCore/Parity/ParityLedger.swift"

if [ ! -d "$DAEMON_DIR" ]; then
  echo "check-cli-parity: missing $DAEMON_DIR" >&2
  exit 1
fi
for f in "$ENGINE" "$LEDGER"; do
  if [ ! -f "$f" ]; then
    echo "check-cli-parity: missing $f" >&2
    exit 1
  fi
done

# bash 3.2 compatible (macOS /bin/bash). `nullglob` so a stale glob becomes an
# empty array rather than a literal `*RPCHandlers.swift` path that grep would
# treat as a missing file with a confusing error.
shopt -s nullglob
DAEMON_FILES=("$DAEMON_DIR"/*RPCHandlers.swift)
shopt -u nullglob

# Vacuity: if the glob stops matching the extracted groups, EngineRouter.swift
# alone still has enough methods to clear MIN_METHODS below, and the ledger
# comparison would silently ignore every daemon verb. Fail loudly instead.
MIN_DAEMON_FILES=8
if [ "${#DAEMON_FILES[@]}" -lt "$MIN_DAEMON_FILES" ]; then
  echo "check-cli-parity: only ${#DAEMON_FILES[@]} *RPCHandlers.swift files under $DAEMON_DIR (expected >= $MIN_DAEMON_FILES)." >&2
  echo "The daemon-handler glob has probably gone stale — registrations live in" >&2
  echo "Packages/CrowDaemon/Sources/CrowDaemon/*RPCHandlers.swift (CROW-1134)." >&2
  exit 1
fi

# A handler registration is a dictionary key whose value opens a closure:
#     "job-add": { params in            (daemon)
#     "set-goal": { @Sendable _ in      (engine)
#     "job-list": { _ in [:] },         (hypothetical one-liner)
# Requiring the `{ … in` opener is what keeps plain data dictionaries inside
# handler bodies (`"checks": .string(…)`) out of the result. Deliberately not
# anchored at end-of-line: a handler whose body starts on the same line is still
# a handler, and anchoring here silently hid one from the gate.
HANDLER_RE='^[[:space:]]+"[a-z0-9-]+": \{ (@Sendable )?[A-Za-z_][A-Za-z0-9_]* in([[:space:]]|$)'

registered_methods() {
  grep -hoE "$HANDLER_RE" "${DAEMON_FILES[@]}" "$ENGINE" \
    | sed -E 's/^[[:space:]]*"([a-z0-9-]+)".*/\1/' \
    | sort -u
}

# Ledger rows are `.read("method", …)` / `.write("method", …)`. A row with a long
# exemption reason wraps, putting the method literal on its own line, so the
# array body is flattened to one line before matching — otherwise a reformatted
# row would silently drop out of the comparison and weaken the gate. Scoped to
# the `rpcMethods` array so `configFields` below it can never contribute.
ledger_methods() {
  awk '/^    public static let rpcMethods/ { inside = 1 }
       inside                             { print }
       inside && /^    \]$/               { exit }' "$LEDGER" \
    | tr '\n' ' ' \
    | grep -oE '\.(read|write)\([[:space:]]*"[a-z0-9-]+"' \
    | sed -E 's/.*"([a-z0-9-]+)".*/\1/' \
    | sort -u
}

# Vacuity guard: if a router refactor stops matching HANDLER_RE the diff would
# silently agree with an equally-empty ledger. The surface only ever grows, so a
# floor well under today's count still catches a regex that has gone blind.
MIN_METHODS=60
count="$(registered_methods | wc -l | tr -d ' ')"
if [ "$count" -lt "$MIN_METHODS" ]; then
  echo "check-cli-parity: only $count RPC methods extracted (expected >= $MIN_METHODS)." >&2
  echo "The handler-registration regex has probably gone stale — check that" >&2
  echo "*RPCHandlers.swift / EngineRouter.swift still register handlers as" >&2
  echo '    "method-name": { params in' >&2
  exit 1
fi

# mktemp, not a fixed path: a predictable name in a shared /tmp is a symlink
# footgun on a multi-user box, and this script is meant to be run locally too.
DIFF_OUT="$(mktemp "${TMPDIR:-/tmp}/cli-parity.XXXXXX")"
trap 'rm -f "$DIFF_OUT"' EXIT

if ! diff -u <(registered_methods) <(ledger_methods) > "$DIFF_OUT" 2>&1; then
  echo "MISMATCH: registered RPC methods vs ParityLedger.rpcMethods" >&2
  echo "  (- registered but not ledgered, + ledgered but not registered)" >&2
  tail -n +3 "$DIFF_OUT" >&2
  echo "" >&2
  echo "Add a row to ParityLedger.rpcMethods for each new method: either" >&2
  echo '  .write("your-method", cli: "your verb")   — it has a crow verb, or' >&2
  echo '  .write("your-method", noCLI: "why not, and the ticket that closes it")' >&2
  exit 1
fi

echo "CLI/RPC parity: registered methods match the ledger ($count methods)"
