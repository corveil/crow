# 0021 — Signed + notarized macOS CLI releases

- **Status:** Accepted
- **Date:** 2026-08-28
- **Deciders:** @dhilgaertner

## Context

GitHub release tarballs of `crow` and `crowd` were unsigned after the SwiftUI
`.app` was retired ([ADR 0010](./0010-retire-the-macos-app.md), #939). A browser
download applies Gatekeeper quarantine, so first launch hits the "unidentified
developer" wall unless the user runs `xattr -d com.apple.quarantine`. Official
releases should be Gatekeeper-clean.

Crow is a native Swift CLI + daemon, not Electron, so we borrow
radiusmethod/socketzero's *secret + notarytool* shape (Developer ID `.p12` +
App Store Connect API key), not its electron-builder mechanics. The old
`scripts/sign-and-notarize.sh` signed a `.app`/`dmg` with Apple-ID +
app-specific-password auth; that bundle no longer exists, and API-key auth is
the non-interactive path notarytool wants in CI.

`codesign` / `notarytool` / `stapler` are macOS-only. Colima Linux self-hosted
runners cannot run this job. A native-host macOS runner was registered and
tried; GitHub-hosted `macos-15` is the pin instead because this repo is
public and standard hosted minutes (including macOS) are free.

## Decision

1. **Sign `crow` and `crowd` standalone**, with hardened runtime, a secure
   timestamp, and `Crow.entitlements`. `crowd` is launched by launchd
   (`crow autostart`) from a path the user chooses, so it cannot ride along
   inside a `.app` signature. Resource bundles next to the binaries are data;
   Mach-O files in the tree are signed individually (inside-out, no `--deep`).
2. **Notarize a zip** of the versioned directory via `xcrun notarytool submit
   --wait` using an App Store Connect API key (issuer / key-id / `.p8`). The
   zip is the notarized container; a `.tar.gz` of the same signed tree is also
   published so existing install instructions keep working. A zip cannot be
   stapled — Gatekeeper looks up the ticket online by CDHash, which is the
   documented path for CLI zip distributions.
3. **No `.app` / `.dmg` in this cut.** The SwiftUI app is gone (ADR 0010). The
   Tauri desktop window does not yet bundle `crowd` as a sidecar (roadmap on
   `crow-desktop/README.md`). Shipping an empty shell would not close
   Gatekeeper for the daemon. A Homebrew cask is a follow-up.
4. **Ephemeral keychain per job.** The `.p12` is imported into a throwaway
   keychain, used, and deleted in a `trap` / `always()` cleanup. The Developer
   ID cert never lands in the host login keychain, including on a self-hosted
   runner.
5. **Runner: GitHub-hosted `macos-15`.** Test, Sign, and CI Desktop use
   `macos-15`; Shell Lint / PR CI / cache-warm use `ubuntu-latest`. Standard
   hosted minutes are free on this public repo, so there is no
   `CROW_SIGNING_RUNS_ON` self-hosted switch. `setup-xcode` pins Xcode 16.

## Consequences

- A `v*` tag cut fails closed if signing/notarization secrets are missing —
  we do not publish an unsigned build as a "release".
- Local `make daemon` / `scripts/package-release.sh` stay unsigned; only the
  GitHub release artifacts are signed. Developers still do not need an Apple
  certificate.
- The Apple Developer Program membership must stay in good standing
  (accepted agreement). An expired agreement fails every darwin cut, which is
  how socketzero's builds were blocked (socketzero#717).
- GitHub-hosted macOS minutes do not bill on this public repo. Private-repo
  10× macOS accounting does not apply.
- `crow autostart install --binary` already takes a path — point it at the
  signed `crowd` from the extracted release directory. No new install verb.

## Alternatives considered

- **Sign only a future Tauri `.app` and leave `crowd` unsigned** — rejected:
  launchd execs `crowd` directly, and that is the binary Gatekeeper assesses
  at login.
- **Default `runs-on` to `[self-hosted, macOS, signing]`** — rejected:
  `corveil/crow` is public, so GitHub-hosted `macos-15` is free. A native-host
  runner was registered and jobs did land on it, but the org runner group
  had to allow public repositories first, and Colima still cannot run
  `codesign`/`notarytool`. Hosted is simpler.
- **`.dmg` as the only artifact, so we can staple** — rejected for CLI UX
  (the install path is extract-and-symlink, not drag-to-Applications). The
  notarized zip is sufficient while online; a dmg returns if we ship a
  `.app`.
- **`gon` / `quill` as a wrapper** — rejected for v1: they wrap the same
  notarytool API-key flow and add a dependency. Revisit if the script grows
  another product (the Tauri bundle).
- **Apple ID + app-specific password** (the retired script) — rejected:
  API keys are the CI-friendly, revocable path socketzero uses.

## References

- Issue: https://github.com/corveil/crow/issues/1150
- Related ADRs: [0007](./0007-linux-ci-swift.md), [0010](./0010-retire-the-macos-app.md)
- Code: `scripts/macos-sign-notarize.sh`, `.github/workflows/release.yml`,
  `docs/macos-release-signing.md`
- Companion: `corveil/corveil-ci` host signing-runner converge
