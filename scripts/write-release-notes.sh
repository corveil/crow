#!/usr/bin/env bash
# Write GitHub Release notes for a Crow tag cut.
#
# Kept as a real script (not a YAML heredoc) so ATX headings sit at column 0.
# GitHub markdown only treats `##` as a heading with 0–3 leading spaces;
# YAML-indented heredocs in release.yml would emit ~10 spaces and hide the
# unsigned warning (CROW-1199 review).
#
# Usage:
#   CROW_VERSION=0.2.0-rc.1 bash scripts/write-release-notes.sh --output PATH [--unsigned]
#   --repository owner/repo   default: $GITHUB_REPOSITORY
#
# bash 3.2 compatible (macOS /bin/bash).
set -euo pipefail

WRITE_NOTES_SCRIPT="${BASH_SOURCE[0]}"

write_release_notes_usage() {
  sed -n '2,14p' "$WRITE_NOTES_SCRIPT" | sed -e 's/^# //' -e 's/^#//'
}

write_release_notes_main() {
  local output="" unsigned=0 repository=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        output=$2
        shift 2
        ;;
      --unsigned)
        unsigned=1
        shift
        ;;
      --repository)
        repository=$2
        shift 2
        ;;
      --help|-h)
        write_release_notes_usage
        return 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        write_release_notes_usage >&2
        return 2
        ;;
    esac
  done

  if [ -z "${CROW_VERSION:-}" ]; then
    echo "ERROR: CROW_VERSION is required" >&2
    return 1
  fi
  if [ -z "$output" ]; then
    echo "ERROR: --output PATH is required" >&2
    return 1
  fi
  if [ -z "$repository" ]; then
    repository="${GITHUB_REPOSITORY:-corveil/crow}"
  fi

  {
  if [ "$unsigned" -eq 1 ]; then
    cat <<EOF
## Unsigned prerelease

**This build is NOT signed and NOT notarized.** Apple Developer enrollment is pending (CROW-1199). A browser download is Gatekeeper-quarantined.

Clear quarantine before first launch:

\`\`\`bash
xattr -dr com.apple.quarantine crow-${CROW_VERSION}-macos-universal.tar.gz
xattr -dr com.apple.quarantine Crow-${CROW_VERSION}-macos.app.zip
# after extract / unzip:
xattr -dr com.apple.quarantine ~/.local/lib/crow-${CROW_VERSION}
xattr -dr com.apple.quarantine /Applications/Crow.app
\`\`\`

Or right-click **Crow.app** → Open (and confirm). Do not treat this cut as a production release.

EOF
  fi
  cat <<EOF
## Install

Download \`crow-${CROW_VERSION}-macos-universal.tar.gz\` (or the \`.zip\`) and its checksum file, verify the archive, extract it, and symlink the binaries into your \`PATH\`. Keep the extracted directory intact — \`crowd\` needs the \`.bundle\` resources next to the binaries.

\`\`\`bash
shasum -a 256 -c crow-${CROW_VERSION}-macos-universal.tar.gz.sha256
mkdir -p ~/.local/lib ~/.local/bin
tar -xzf crow-${CROW_VERSION}-macos-universal.tar.gz -C ~/.local/lib
ln -sf ~/.local/lib/crow-${CROW_VERSION}/crow ~/.local/bin/crow
ln -sf ~/.local/lib/crow-${CROW_VERSION}/crowd ~/.local/bin/crowd
\`\`\`

Unzip \`Crow-${CROW_VERSION}-macos.app.zip\` and drag **Crow.app** to \`/Applications\`. Double-clicking it starts a bundled \`crowd\` (or reuses one already listening on \`:8787\`) and opens the web UI. Quitting the window only SIGTERMs a crowd **this app spawned** — an autostart / \`make daemon-run\` daemon is left up.
EOF
  if [ "$unsigned" -eq 1 ]; then
    cat <<EOF

These binaries are **unsigned**. See the warning above.

Point \`crow autostart install --binary\` at the extracted **CLI** \`crowd\` (not the sidecar inside Crow.app):

\`\`\`bash
crow autostart install --binary ~/.local/lib/crow-${CROW_VERSION}/crowd
\`\`\`
EOF
  else
    cat <<EOF

The \`.app\` is **signed, notarized, and stapled**. The CLI zip cannot be stapled (Gatekeeper looks up that ticket online); the \`.app\` carries the ticket on disk.

These binaries are **signed and notarized** (Developer ID Application + notarytool). A browser download still applies Gatekeeper quarantine; first launch contacts Apple to look up the notarization ticket — you should **not** need \`xattr -d com.apple.quarantine\`.

Point \`crow autostart install --binary\` at the extracted **CLI** \`crowd\` (not the sidecar inside Crow.app) so launchd runs the signed standalone daemon:

\`\`\`bash
crow autostart install --binary ~/.local/lib/crow-${CROW_VERSION}/crowd
\`\`\`
EOF
  fi
  cat <<EOF

To build from source instead: \`make daemon CONFIG=release && make install CONFIG=release\` (unsigned CLI) or \`make app CONFIG=release\` (unsigned Crow.app). Signing details: [docs/macos-release-signing.md](https://github.com/${repository}/blob/main/docs/macos-release-signing.md).
EOF
  } > "$output"
}

# Sourced by write-release-notes_test.sh; skip main in that case.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  write_release_notes_main "$@"
fi
