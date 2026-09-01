# 0007 — Swift CI runs on Linux, not macOS

- **Status:** Accepted
- **Date:** 2026-07-10
- **Deciders:** @dhilgaertner

## Context

PR CI (`ci.yml`) and the per-`main`-push cache warm (`cache-warm.yml`) ran on `macos-15` with Xcode 16, purely to get a Swift toolchain. macOS GitHub Actions minutes are billed at ~10× Linux, so every PR and every push to `main` paid the macOS premium for Swift work that is mostly Foundation-only. Crow is [web-app-first over a headless daemon](https://github.com/corveil/crow/issues/581), and #118 already began shifting macOS-only cost toward the release pipeline; issue [#647](https://github.com/corveil/crow/issues/647) finishes the job for day-to-day CI.

Constraint on the current tree when this ADR was written: the daemon Linux build ([#645](https://github.com/corveil/crow/issues/645)) was **not merged**, so there was no `crowd` product. The root `Package.swift` was `platforms: [.macOS(.v14)]` and its only executables were the AppKit GUI (`Crow`/`CrowApp`) and the `crow` CLI. A root `swift build` therefore compiled the GUI and could not run on Linux. However, 10 of the 13 sub-packages (`CrowCore`, `CrowIPC`, `CrowClaude`, `CrowCodex`, `CrowCursor`, `CrowGit`, `CrowOpenCode`, `CrowPersistence`, `CrowProvider`, `CrowCLI`) are Foundation-only — they import only Foundation / ArgumentParser / each other, with Darwin↔Glibc socket code already `#if canImport`-guarded — and depend on nothing that reaches AppKit.

## Decision

PR CI and cache-warm run on `[self-hosted, Linux]` (Colima) inside the official `swift:6.1` container (bumpable to match local dev), with no Xcode. They `swift build` + `swift test` an **explicit allow-list** of Linux-compilable packages via `--package-path`, plus a root build of the `crowd` and `crow` executables (CROW-645). Do not loop over `Packages/*/` — that would pull in packages not yet ready for Linux. `release.yml` stays on macOS — it is the only workflow that needs Apple signing/notarization (ADR 0021) and the only place `CrowTelemetry`'s full test suite is compiled. macOS jobs use the native-host runner `[self-hosted, macOS, signing]`; there is no GitHub-hosted `macos-*` or `ubuntu-latest` fallback.

## Consequences

- PRs and `main` pushes no longer burn macOS minutes; the only residual macOS cost is `release.yml`, which fires on `v*` tags (infrequent).
- **The GUI half of the tree (`Crow`/`CrowApp`, `CrowUI`) and `CrowTelemetry` are no longer compiled on PRs** — a change that breaks them passes PR CI and only fails when a release tag is pushed. This is the accepted trade-off for the minute savings.
- **Amended 2026-08-07 (CROW-645, PR #948):** `CrowTerminal` and `CrowDaemon` now compile on every PR, and the Linux lane builds + links the root `crowd`/`crow` products (`swift build --product crowd` / `--product crow` with no `--package-path`). `CrowTerminal`'s pure `SmartDetect` tests run on Linux; tmux integration tests still run only on macOS in `release.yml`. The root `crowd`/`crow` binaries are linked but not executed in CI — runtime smoke (socket RPC, web UI assets) remains a manual or follow-up step.
- **The root `CrowTests` suite moves from every-PR to release-tag time.** Those tests `@testable import Crow`, and the root `Crow` target imports `CrowTerminal` (AppKit), so they cannot run in the Linux PR lane. They exercise root-target business logic (IssueTracker, Job decisions, Scaffolder, SessionService, …), not just GUI, so to avoid dropping that coverage entirely they now run in `release.yml`'s macOS `test` job at tag time — not on every PR. A logic regression there is caught at release, not on the PR that introduces it.
- **Amended 2026-08-28 (CROW-1150, ADR 0021):** `release.yml` now actually signs and notarizes the `crow`/`crowd` CLI artifacts (that claim was aspirational after #939 shipped unsigned tarballs). The macOS-only GUI named in the original decision (`Crow`/`CrowApp`, `CrowUI`) was removed in ADR 0010; the remaining macOS-only compile in this workflow is `CrowTelemetry` plus the full package test sweep.
- **Amended 2026-08-31 (CROW-1150):** GitHub-hosted `macos-15` / `ubuntu-latest` are gone. Linux jobs land on Colima (`[self-hosted, Linux]`); macOS jobs (release Test + Sign, CI Desktop) land on the native-host `macos-signing` runner. A missing runner queues; it does not spend GitHub minutes.

- The Linux allow-list in `ci.yml`/`cache-warm.yml` must be updated by hand when a new Linux-compilable package is added. This is deliberate: a glob would silently try to build a new macOS-only package on Linux and turn CI red.
- Only the SwiftPM dependency cache (`~/.cache/org.swift.swiftpm`) is retained, not compiled `.build` products, so each Linux run recompiles the packages from scratch. Acceptable given each package builds under its own `Packages/$pkg/.build`.
- `CrowTelemetry` (Apple `Network.framework`) is excluded because it does not compile on Linux, and nothing in the allow-list depends on it. It *does* have a test target — 5 test files, ~1,500 executable lines — so unlike the note originally recorded here, excluding it does cost test coverage on PRs; those tests run only in `release.yml`. (Corrected 2026-07-30 while adding coverage measurement, CROW-928.)

## Alternatives considered

- **Flip `runs-on` to `ubuntu-latest` and keep the root `swift build`** — fails: the root build compiles the AppKit GUI, which does not exist on Linux.
- **Keep a thin macOS `swift build` job to preserve GUI compile coverage on PRs** — still pays macOS minutes on every PR, defeating the ticket's goal; rejected in favor of release-time GUI verification.
- **swiftly-installed toolchain instead of the container** — mirrors local dev, but adds a network install on every run; the pinned container is more reproducible and matches #584's Linux check.
- **Port `CrowTelemetry`/the GUI to Linux now** — out of scope; that is #645's domain, not a CI change.

## References

- PR: https://github.com/corveil/crow/pull/651 (issue #647)
- PR: https://github.com/corveil/crow/pull/948 (issue #645 — Linux `crowd`/`crow` build lane; amends this ADR)
- Related ADRs: [0006](./0006-universal-macos-binary.md), [0021](./0021-signed-notarized-macos-releases.md)
- Code: `.github/workflows/ci.yml`, `.github/workflows/cache-warm.yml`, `.github/workflows/release.yml`, `scripts/generate-build-info.sh`
