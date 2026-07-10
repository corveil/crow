# 0007 — Swift CI runs on Linux, not macOS

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** @dhilgaertner

## Context

PR CI (`ci.yml`) and the per-`main`-push cache warm (`cache-warm.yml`) ran on `macos-15` with Xcode 16, purely to get a Swift toolchain. macOS GitHub Actions minutes are billed at ~10× Linux, so every PR and every push to `main` paid the macOS premium for Swift work that is mostly Foundation-only. Crow is [web-app-first over a headless daemon](https://github.com/radiusmethod/crow/issues/581), and #118 already began shifting macOS-only cost toward the release pipeline; issue [#647](https://github.com/radiusmethod/crow/issues/647) finishes the job for day-to-day CI.

Constraint on the current tree: the daemon Linux build ([#645](https://github.com/radiusmethod/crow/issues/645)) is **not merged**, so there is no `crowd` product here. The root `Package.swift` is `platforms: [.macOS(.v14)]` and its only executables are the AppKit GUI (`Crow`/`CrowApp`) and the `crow` CLI. A root `swift build` therefore compiles the GUI and cannot run on Linux. However, 10 of the 13 sub-packages (`CrowCore`, `CrowIPC`, `CrowClaude`, `CrowCodex`, `CrowCursor`, `CrowGit`, `CrowOpenCode`, `CrowPersistence`, `CrowProvider`, `CrowCLI`) are Foundation-only — they import only Foundation / ArgumentParser / each other, with Darwin↔Glibc socket code already `#if canImport`-guarded — and depend on nothing that reaches AppKit.

## Decision

PR CI and cache-warm run on `ubuntu-latest` inside the official `swift:6` container (pinned `swift:6.1`, bumpable to match local dev's 6.3.x), with no Xcode. They `swift build` + `swift test` an **explicit allow-list** of the 10 Linux-compilable packages via `--package-path`, never a root build or `Packages/*/` glob. `release.yml` stays on `macos-15` — it is the only workflow that needs Apple signing/notarization and the only place the macOS-only code (root GUI, `CrowUI`, `CrowTerminal`, and `CrowTelemetry`'s `Network.framework` receiver) is compiled.

## Consequences

- PRs and `main` pushes no longer burn macOS minutes; the only residual macOS cost is `release.yml`, which fires on `v*` tags (infrequent).
- **The GUI half of the tree (`Crow`/`CrowApp`, `CrowUI`, `CrowTerminal`) and `CrowTelemetry` are no longer compiled on PRs** — a change that breaks them passes PR CI and only fails when a release tag is pushed. This is the accepted trade-off for the minute savings; revisit once #645 makes a Linux-native daemon the build target and more of the tree becomes Linux-buildable.
- **The root `CrowTests` suite moves from every-PR to release-tag time.** Those tests `@testable import Crow`, and the root `Crow` target imports `CrowTerminal` (AppKit), so they cannot run in the Linux PR lane. They exercise root-target business logic (IssueTracker, Job decisions, Scaffolder, SessionService, …), not just GUI, so to avoid dropping that coverage entirely they now run in `release.yml`'s macOS `test` job at tag time — not on every PR. A logic regression there is caught at release, not on the PR that introduces it.
- The Linux allow-list in `ci.yml`/`cache-warm.yml` must be updated by hand when a new Linux-compilable package is added. This is deliberate: a glob would silently try to build a new macOS-only package on Linux and turn CI red.
- Only the SwiftPM dependency cache (`~/.cache/org.swift.swiftpm`) is retained, not compiled `.build` products, so each Linux run recompiles the packages from scratch. Acceptable given each package builds under its own `Packages/$pkg/.build`.
- `CrowTelemetry` (Apple `Network.framework`) is excluded; it has no test target and nothing in the allow-list depends on it, so excluding it costs no test coverage.

## Alternatives considered

- **Flip `runs-on` to `ubuntu-latest` and keep the root `swift build`** — fails: the root build compiles the AppKit GUI, which does not exist on Linux.
- **Keep a thin macOS `swift build` job to preserve GUI compile coverage on PRs** — still pays macOS minutes on every PR, defeating the ticket's goal; rejected in favor of release-time GUI verification.
- **swiftly-installed toolchain instead of the container** — mirrors local dev, but adds a network install on every run; the pinned container is more reproducible and matches #584's Linux check.
- **Port `CrowTelemetry`/the GUI to Linux now** — out of scope; that is #645's domain, not a CI change.

## References

- PR: https://github.com/radiusmethod/crow/pull/651 (issue #647)
- Related ADRs: [0006](./0006-universal-macos-binary.md)
- Code: `.github/workflows/ci.yml`, `.github/workflows/cache-warm.yml`, `.github/workflows/release.yml`, `scripts/generate-build-info.sh`
