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

1. **Config, default on.** `defaults.corveilAutoUpdate` (bool, default **on**; a
   missing key decodes as on) and `defaults.corveilVersion` (`"latest"` or a
   `vX.Y.Z` pin). Exposed via `crow defaults get/set` and Settings → General. An
   explicit `false` stays off. CROW-1210 shipped this off so source-build
   workflows were not surprised; CROW-1229 flipped it after a live fetch of
   `corveil-darwin-arm64` from `corveil/corveil-releases` v0.4.41 checksum-verified,
   ran `corveil --version`, and hot-swapped the symlink.
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

Fresh Crow installs get a `corveil` CLI without pointing `binaries["corveil"]`
at a build. Developers with a local `out/` build keep using it. Operators who
do not want downloads pass `--corveil-auto-update false`. The `-releases` lag
vs source tags remains a publish-cadence issue, not Crow's. Quarantine
stripping is a pragmatic workaround until `-releases` artifacts are notarized.

## Alternatives considered

- **Default off (CROW-1210).** Shipped first so existing source-build workflows
  were unchanged until an operator opted in. Reconsidered once the download
  path was proven; CROW-1229 made on the default. Operator `binaries["corveil"]`
  still wins.
- **Build from `corveil/corveil` source.** Needs a Go toolchain and private-repo
  auth; binaries already exist.
- **Require a daemon restart after swap.** Unnecessary: the PATH prepend
  resolves the symlink, and skills are reinstalled in place.

## References

- Ticket: https://github.com/corveil/crow/issues/1210
- Follow-up (default on): https://github.com/corveil/crow/issues/1229
- Related ADRs: [0012](./0012-tests-never-touch-live-data.md) (tests inject a
  temp managed root), [0016](./0016-cli-control-plane-parity.md)
- Code: `Packages/CrowEngine/Sources/CrowEngine/CorveilAutoUpdate.swift`,
  `Packages/CrowDaemon/Sources/CrowDaemon/CorveilAutoUpdateService.swift`
