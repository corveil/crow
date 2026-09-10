# 0025 — Auto-download the corveil CLI from corveil-releases

- **Status:** Accepted
- **Date:** 2026-09-10
- **Deciders:** @dhilgaertner

## Context

The `corveil` CLI was a manually managed artifact: an operator cloned
`corveil/corveil`, built `out/corveil-<os>-<arch>`, and pointed Crow at it via
`defaults.binaries["corveil"]`. Crow only (re)created the `.claude/bin/corveil`
symlink to whatever path was configured. Linked binaries drifted silently —
months and dozens of releases behind — and a daemon restart did not self-heal.

Prebuilt binaries already ship from the public [`corveil/corveil-releases`](https://github.com/corveil/corveil-releases)
repo (`checksums.txt` plus darwin/linux amd64/arm64). No private-repo auth and
no source-build step are required. The mirror can trail source tags by about a
day; that is acceptable for "roughly current," not a Crow-side problem.

Crow already had a periodic GitHub check (`crow version` / CROW-938), a
post-download verify (`crow corveil verify`), skill reinstall, and an
Application Support directory.

## Decision

1. **Opt-in config.** `defaults.corveilAutoUpdate` (bool, default **off**) and
   `defaults.corveilVersion` (`"latest"` or a `vX.Y.Z` pin). Exposed via
   `crow defaults get/set` and Settings → General.
2. **Operator path wins.** Auto-manage runs only when the configured
   `binaries["corveil"]` is unset or already points into
   `~/Library/Application Support/crow/bin/corveil/`. A source-build path is
   never overwritten.
3. **Download, verify, link.** Resolve host `os/arch`, fetch the matching
   asset from `corveil/corveil-releases` over HTTPS (unauthenticated), verify
   SHA-256 against `checksums.txt`, run `corveil --version`, store under a
   versioned managed dir, atomically repoint `.claude/bin/corveil`, reinstall
   skills, and keep one previous version for rollback. Darwin downloads get
   `com.apple.quarantine` stripped. Failures log a warning and keep last-good;
   startup never fails.
4. **Cadence.** Check at daemon start and on the existing
   `versionUpdate.intervalHours` loop. Enabling via `crow defaults set` kicks a
   check immediately. The symlink is hot-swapped; no `crowd` restart is required
   for a successful auto-update.

## Consequences

Operators can stay current without a Go toolchain. Developers with a local
`out/` build keep using it. The `-releases` lag vs source tags remains a
publish-cadence issue, not Crow's. Quarantine stripping is a pragmatic
workaround until `-releases` artifacts are notarized.

## Alternatives considered

- **Default on.** Would surprise existing source-build workflows; opt-in
  first, reconsider once the path is proven.
- **Build from `corveil/corveil` source.** Needs a Go toolchain and private-repo
  auth; binaries already exist.
- **Require a daemon restart after swap.** Unnecessary: the PATH prepend
  resolves the symlink, and skills are reinstalled in place.

## References

- Ticket: https://github.com/corveil/crow/issues/1210
- Related ADRs: [0012](./0012-tests-never-touch-live-data.md) (tests inject a
  temp managed root), [0016](./0016-cli-control-plane-parity.md)
- Code: `Packages/CrowEngine/Sources/CrowEngine/CorveilAutoUpdate.swift`,
  `Packages/CrowDaemon/Sources/CrowDaemon/CorveilAutoUpdateService.swift`
