# 0024 — Crow.app ships crowd as a Tauri sidecar

- **Status:** Accepted
- **Date:** 2026-09-02
- **Deciders:** @dhilgaertner

## Context

The Tauri desktop window already spawned `crowd` in **dev**: `make run` execs
`.build/debug/crowd` (or reuses `127.0.0.1:8787`) and points WKWebView at it.
Release builds did not bundle that binary — `crowd_bin()` was hardcoded to the
debug path, `make app` was `cargo build` (a naked `Crow` binary, not an `.app`),
and `tauri.conf.json` had no `externalBin`. [ADR 0021](./0021-signed-notarized-macos-releases.md)
left `.app` / `.dmg` out of the signed-CLI cut for this reason.

`crowd` still has to run **outside** the `.app` too: `crow autostart` execs it
directly via launchd, so that copy must stay signed standalone (ADR 0021).
The `.app` is packaging, not a new engine ([ADR 0009](./0009-crowd-sole-authority-clients-only.md)).

## Decision

1. **Release `Crow.app` bundles `crowd` (and `crow`) as Tauri `externalBin`
   sidecars.** Debug `make run` / `make app` stay on `.build/debug/crowd` and
   `CROWD_BIN`. `bundle.externalBin` is an overlay (`tauri.sidecar.conf.json`)
   applied only by `tauri build`, so `cargo build` in the PR desktop lane does
   not require staged sidecars.
2. **SwiftPM `.bundle` resources land in `Contents/Resources`.** `Bundle.module`
   for a sidecar whose executable sits in `Contents/MacOS` resolves through
   the parent `.app`; without CrowDaemon's web assets the window comes up and
   the UI 404s. They are copied after `tauri build` (Tauri resource globs skip
   directories, and a `.bundle` is a directory).
3. **Lifecycle is unchanged.** Reuse a listening crowd (launchd / `make
   daemon-run`); only SIGTERM a crowd **this window spawned**. The `.app` is
   not the only way `crowd` runs.
4. **Codesign identifiers stay distinct.** The `.app` is `com.corveil.crow`
   (the Tauri identifier). Standalone / sidecar `crowd` stays
   `com.corveil.crowd`. The CLI `crow` binary is `com.corveil.crow.cli` so the
   two products in one GitHub Release do not share an id. Nested Mach-Os are
   signed inside-out, no `--deep`.
5. **Notarize and staple the `.app`.** The CLI zip still cannot be stapled
   (ADR 0021). A zip of the `.app` is the GitHub asset; after `notarytool
   submit --wait` we `stapler staple Crow.app` and re-zip. Local
   `make app CONFIG=release` stays unsigned. Missing Apple secrets still fail the
   `v*` job closed rather than publishing an unsigned "release".

## Consequences

- A double-clickable `Crow.app` is a release artifact next to the CLI tarball.
  Drag-to-Applications does **not** put `crow` on `PATH` (cask / symlink
  follow-up).
- `make app CONFIG=release` is `tauri build`, not `cargo build --release`.
  Debug `make app` is still the naked binary.
- Sidecar filenames keep the target triple (`crowd-aarch64-apple-darwin`) so
  they do not collide with the Tauri executable `Crow` on case-insensitive
  APFS. `crowd_bin()` prefers that name, then unsuffixed `crowd`.
- The Homebrew cask and "CLI-only install" remain valid; this does not replace
  them.

## Alternatives considered

- **Put `externalBin` in the default `tauri.conf.json`.** Rejected: `cargo
  build` (debug `make run`, the PR desktop lane) would fail unless sidecar
  files were staged, coupling a Rust compile to a Swift release build.
- **Let Tauri copy `.bundle` dirs via `bundle.resources`.** Rejected: the
  resource glob iterator skips directories, so the web UI would 404.
- **Sign only the `.app` and leave standalone `crowd` unsigned.** Rejected
  in ADR 0021: launchd execs `crowd` directly.
- **Make the `.app` the only way `crowd` runs.** Rejected: autostart, `make
  daemon-run`, and the CLI tarball stay first-class.
- **Ship a `.dmg` as the only desktop artifact.** Deferred; a stapled zip of
  the `.app` is enough and matches the CLI's extract-and-run shape. A cask
  can add a dmg later.

## References

- Issue: https://github.com/corveil/crow/issues/1189
- Related ADRs: [0009](./0009-crowd-sole-authority-clients-only.md),
  [0010](./0010-retire-the-macos-app.md),
  [0021](./0021-signed-notarized-macos-releases.md)
- Code: `crow-desktop/src-tauri/src/lib.rs` (`crowd_bin`),
  `crow-desktop/src-tauri/tauri.sidecar.conf.json`,
  `scripts/prepare-desktop-sidecar.sh`, `scripts/package-app.sh`,
  `scripts/macos-sign-notarize.sh`
