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

`codesign` / `notarytool` / `stapler` are macOS-only. The org's self-hosted
runners live inside a Colima Linux VM and cannot run this job. The Mac that
hosts Colima can, if a second runner is registered on the host OS.

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
5. **Runner: native-host self-hosted only.** `runs-on: [self-hosted, macOS, signing]`
   for Test + Sign, `[self-hosted, Linux]` for Shell Lint. There is **no**
   GitHub-hosted `macos-*` fallback — those minutes are the cost this pipeline
   exists to avoid. The runner lives on the Mac that hosts Colima (host OS,
   outside the Linux VM) and is labelled `signing`. Linux jobs stay on the
   Colima runners. GitHub-hosted images are not used.

## Consequences

- A `v*` tag cut fails closed if signing/notarization secrets are missing —
  we do not publish an unsigned build as a "release".
- Local `make daemon` / `scripts/package-release.sh` stay unsigned; only the
  GitHub release artifacts are signed. Developers still do not need an Apple
  certificate.
- The Apple Developer Program membership must stay in good standing
  (accepted agreement). An expired agreement fails every darwin cut, which is
  how socketzero's builds were blocked (socketzero#717).
- GitHub-hosted `macos-*` is not used. A missing or offline `macos-signing`
  runner queues the job instead of silently spending GitHub macOS minutes.
- `crow autostart install --binary` already takes a path — point it at the
  signed `crowd` from the extracted release directory. No new install verb.

## Alternatives considered

- **Sign only a future Tauri `.app` and leave `crowd` unsigned** — rejected:
  launchd execs `crowd` directly, and that is the binary Gatekeeper assesses
  at login.
- **GitHub-hosted `macos-15` as the default until a native runner exists** —
  rejected after the first probe: those minutes are unaffordable. The job
  queues on `[self-hosted, macOS, signing]` instead of falling back.
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
