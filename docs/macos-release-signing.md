# Signed + notarized macOS releases

Official `v*` GitHub Releases of `crow` and `crowd` are signed with a
**Developer ID Application** certificate and notarized with `notarytool`. Local
`make daemon` builds stay unsigned — you do not need an Apple certificate to
develop.

See [ADR 0021](adr/0021-signed-notarized-macos-releases.md) for the CLI
decisions (standalone `crowd`, zip-not-dmg, GitHub-hosted runner until a
native-host runner exists) and [ADR 0024](adr/0024-tauri-sidecar-app.md) for
the Tauri `Crow.app` sidecar + staple.

## Human prerequisites (not automatable)

A worker cannot provision any of these. The Apple account holder sets them up
and stores them as GitHub Actions **repository or org secrets**. Crow's
Developer Program membership must be in good standing (agreement accepted) or
every darwin cut fails — the same failure that blocked
[socketzero#717](https://github.com/radiusmethod/socketzero/issues/717).

| Secret | Contents |
|---|---|
| `APPLE_DEVELOPER_SIGNING_KEY_CERT` | Developer ID Application `.p12`, **base64**. `base64 -i developer-id.p12 \| pbcopy` |
| `CSC_KEY_PASSWORD` | Password that unlocks that `.p12` |
| `APPLE_API_KEY` | App Store Connect AuthKey `.p8` (PEM or base64). Prefer base64: `base64 -i AuthKey_XXXXXXXXXX.p8 \| pbcopy` |
| `APPLE_API_KEY_ID` | The key's Key ID (10 characters) |
| `APPLE_API_ISSUER` | Issuer ID (UUID) from App Store Connect → Users and Access → Integrations → Issuer ID |

Aliases accepted by `scripts/macos-sign-notarize.sh` so a socketzero-shaped
or pre-#939 secret set still works:

- cert: `RM_APPLE_DEVELOPER_SIGNING_KEY_CERT`, `DEVELOPER_CERTIFICATE_BASE64`
- password: `DEVELOPER_CERTIFICATE_PASSWORD`
- key: `APPLE_API_KEY_P8_BASE64`
- issuer: `APPLE_API_ISSUER_ID`

Optional: `DEVELOPER_ID_APPLICATION` (`Developer ID Application: Name (TEAMID)`).
When unset, the identity is read from the imported cert.

Create the API key under App Store Connect → Users and Access → Integrations
→ Team Keys, with at least **Developer** access so it can submit for
notarization. Restrict it to the Crow app if App Store Connect lets you.

## What the workflow does

On a `v*` tag (and on `workflow_dispatch`):

1. `scripts/package-release.sh` builds universal `crow` + `crowd`, smoke-tests
   them, and writes `crow-<version>-macos-universal.tar.gz`.
2. `scripts/package-app.sh --universal` stages those binaries as Tauri
   sidecars, runs `tauri build`, copies SwiftPM `.bundle` resources into
   `Crow.app/Contents/Resources`, and writes `release-app/Crow.app`.
3. `scripts/macos-sign-notarize.sh` unpacks the CLI tarball, imports the `.p12`
   into an **ephemeral keychain**, signs every Mach-O with hardened runtime +
   timestamp + `Crow.entitlements`, re-packs the tarball, writes a zip, and
   submits the zip to `xcrun notarytool submit --wait`. It then signs the
   `.app` inside-out (sidecars, then the bundle — identifier `com.corveil.crow`;
   CLI `crow` is `com.corveil.crow.cli`), notarizes a zip of it, **staples**
   `Crow.app`, and re-zips to `Crow-<version>-macos.app.zip`.
4. The keychain (and the decoded `.p12` / `.p8`) are deleted in an `EXIT`
   trap — including on failure. The Developer ID cert never enters the login
   keychain.
5. Both CLI archives, the stapled `.app` zip, and their `.sha256` files are
   attached to the GitHub Release.

A CLI zip cannot be stapled. Gatekeeper looks up the notarization ticket online
by CDHash when a quarantined binary is launched; that is the documented path for
CLI zip distributions. The `.app` **is** stapled, so it verifies offline.

If any signing/notarization secret is missing, the job **fails** rather than
publishing an unsigned build. Local `make daemon` / `make app CONFIG=release`
stay unsigned.

## Runner

Default `runs-on` is GitHub-hosted `macos-15`. To move the job onto the
native-host runner (the Mac that hosts Colima, **outside** the Linux VM):

1. Provision the runner through `corveil/corveil-ci`
   (`make install-signing-runner` — see that repo's
   `docs/macos-signing-runner.md`).
2. Set repository variable `CROW_SIGNING_RUNS_ON` to:

   ```json
   ["self-hosted", "macOS", "signing"]
   ```

No workflow change. `setup-xcode` is skipped on self-hosted; Xcode CLT is a
runner prerequisite.

## Local dry-run

With a `.p12` in env, you can sign without submitting to Apple:

```bash
export CROW_VERSION=0.2.0
bash scripts/package-release.sh
bash scripts/package-app.sh --universal
APPLE_DEVELOPER_SIGNING_KEY_CERT="$(base64 -i developer-id.p12)" \
  CSC_KEY_PASSWORD='...' \
  bash scripts/macos-sign-notarize.sh --skip-notarize
```

## Verify a downloaded release

```bash
shasum -a 256 -c crow-<version>-macos-universal.tar.gz.sha256
tar -xzf crow-<version>-macos-universal.tar.gz
codesign --verify --strict --verbose=2 crow-<version>/crow crow-<version>/crowd
spctl --assess --type execute --verbose=4 crow-<version>/crowd
```

`spctl` needs the binary to still carry Gatekeeper quarantine (a browser
download) and a network path to Apple's notary service. `codesign --verify`
is the offline check.

## What this does not cover

- A Homebrew cask (including putting `crow` on `PATH` via drag-to-Applications).
- Linux binaries (no Gatekeeper; unsigned is fine).

The Tauri `Crow.app` **is** a release artifact as of CROW-1189 / [ADR 0024](adr/0024-tauri-sidecar-app.md): `crowd` is bundled as a sidecar, SwiftPM `.bundle` resources sit in `Contents/Resources`, and the `.app` is notarized and stapled. The CLI tarball remains the install path for `crow` on `PATH` and for `crow autostart`.
