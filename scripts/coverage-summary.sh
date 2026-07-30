#!/usr/bin/env bash
# Collect Swift test coverage into one repo-wide summary (CROW-928).
#
# `swift test --enable-code-coverage` leaves an llvm-cov export at
# Packages/<Pkg>/.build/<triple>/debug/codecov/<Pkg>.json. This gathers whatever
# exports are on disk, merges them (scripts/coverage-summary.swift does the
# arithmetic — read its header for the two ways this can silently go wrong), and
# writes coverage-summary.json + coverage-summary.md into the output directory.
#
# It reports on exactly the packages that were tested, so the numbers differ by
# lane on purpose: the Linux PR lane covers the 12 packages in ci.yml's
# LINUX_PACKAGES allow-list (~36% of the tree), while release.yml's macOS job
# is the only place all 17 are measured — see docs/adr/0007-linux-ci-swift.md.
# It does not run the tests itself; `make coverage` is the local front door.
#
#   bash scripts/coverage-summary.sh [OUT_DIR]     # default: coverage/
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT_DIR="${1:-coverage}"

# Pin the depth so this can only match Packages/<Pkg>/.build/<triple>/debug/
# codecov/<file>.json. `find` does not follow the .build/debug symlink, so each
# export is seen once. LC_ALL=C keeps the ordering (and therefore the output)
# identical across machines.
REPORTS=()
while IFS= read -r report; do
  REPORTS+=("$report")
done < <(find Packages -mindepth 6 -maxdepth 6 -type f \
              -path 'Packages/*/.build/*/debug/codecov/*.json' | LC_ALL=C sort)

if [ ${#REPORTS[@]} -eq 0 ]; then
  echo "ERROR: no coverage exports found under Packages/*/.build/*/debug/codecov/." >&2
  echo "       Run the suites with coverage instrumentation first, e.g. 'make coverage'" >&2
  echo "       or 'swift test --enable-code-coverage --package-path Packages/<Pkg>'." >&2
  exit 1
fi

echo "==> Merging ${#REPORTS[@]} coverage export(s) into $OUT_DIR/"

# Compile the merger rather than running it through `swift`'s interpreter mode:
# both work, but an explicit swiftc build behaves identically on macOS and inside
# the Linux swift container and surfaces compile errors plainly. The toolchain is
# already present in every lane that could have produced the exports above, so
# this adds a dependency on nothing new.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

swiftc -O -o "$WORK_DIR/coverage-summary" "$ROOT/scripts/coverage-summary.swift"
"$WORK_DIR/coverage-summary" "$ROOT" "$OUT_DIR" "${REPORTS[@]}"
